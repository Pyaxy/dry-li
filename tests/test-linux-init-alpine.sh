#!/usr/bin/env bash
# Integration test: MUTATES users, sudo, timezone and SSH in a disposable container.
# Run only in a fresh Alpine Docker container with /workspace mounted read-only.
# shellcheck disable=SC2034
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
[[ ${LINUX_INIT_CONTAINER_TEST:-} == 1 && -f /.dockerenv && -f /etc/alpine-release && $EUID == 0 ]] || {
    printf 'Refusing: requires an explicitly enabled disposable Alpine Docker container.\n' >&2
    exit 1
}
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=../public/linux-init/linux-init.sh
source "$SCRIPT_DIR/../public/linux-init/linux-init.sh"
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'PASS: %s\n' "$*"; }
detect_os
[[ $OS_FAMILY == alpine && $SERVICE_MANAGER == openrc && $ADMIN_GROUP == wheel ]] || die 'platform detection'
[[ $SSH_RUNTIME_DIR == /var/empty && $UID_MIN == 1000 ]] || die 'Alpine defaults'
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
getent passwd init_test >/dev/null && die 'requires fresh container'

# Only replace the interactive password reader; actual users/groups/policies/keys
# and OpenSSH operations below are real and confined to this container.
passwd() { printf '%s:container-test-password\n' "$1" | chpasswd; }
create_user <<< $'init_test\ny'
[[ $(getent passwd init_test | cut -d: -f6,7) == /home/init_test:/bin/bash ]] || die 'user home/shell'
id -nG init_test | tr ' ' '\n' | grep -qx wheel || die 'wheel membership'
sudo_policy_ready init_test || die 'effective sudo policy'
[[ $(stat -c %a /etc/sudoers.d/linux-init-init_test) == 440 ]] || die 'sudo file mode'
cp /etc/sudoers.d/linux-init-init_test "$WORK_DIR/sudo-before"
create_user <<< $'init_test\n1'
cmp "$WORK_DIR/sudo-before" /etc/sudoers.d/linux-init-init_test || die 'repeat user action rewrote policy'
adduser -D other_wheel
addgroup other_wheel wheel
if sudo_policy_ready other_wheel; then die 'grant leaked to other wheel member'; fi
ok 'real BusyBox user creation, password, wheel, scoped sudo and repeated action'

# Reproduce a pre-existing key-only login account with a locked local password,
# then repair it through the menu without recreating the user or changing sudo.
command passwd -l init_test
if account_password_ready init_test; then die 'locked local password reported ready'; fi
create_user <<< $'init_test\n2'
account_password_ready init_test || die 'menu did not repair existing password'
cmp "$WORK_DIR/sudo-before" /etc/sudoers.d/linux-init-init_test || die 'password action changed sudo policy'
ok 'existing account local password setup through menu, sudo policy preserved'

ssh-keygen -q -t ed25519 -N '' -f "$WORK_DIR/client"
key=$(cat "$WORK_DIR/client.pub")
append_keys init_test "$key"
append_keys init_test "$key"
[[ $(count_authorized_keys init_test) == 1 ]] || die 'key deduplication'
admin_ready init_test || die 'admin readiness'

mkdir -p /run/openrc
touch /run/openrc/softlevel
rc-update add sshd default
rc-service sshd start
find_ssh_service || die 'OpenRC discovery'
SSH_OPTIONS=(-i "$WORK_DIR/client" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
ssh "${SSH_OPTIONS[@]}" -o BatchMode=yes init_test@127.0.0.1 id >/dev/null || die 'initial key login'
# This live session must survive the configuration reload.
ssh "${SSH_OPTIONS[@]}" -o BatchMode=yes init_test@127.0.0.1 \
    'echo ready; while [ ! -f /tmp/init-session-release ]; do sleep 1; done; echo survived' > "$WORK_DIR/session" &
session_pid=$!
for attempt in 1 2 3 4 5; do
    grep -qx ready "$WORK_DIR/session" && break
    sleep 1
done
grep -qx ready "$WORK_DIR/session" || die 'persistent session did not open'
disable_ssh_password_auth <<< y
key_only_values "$(get_effective_sshd_config)" || die 'effective hardening values'
check_ssh_service_health || die 'listener health'
ssh "${SSH_OPTIONS[@]}" -o BatchMode=yes init_test@127.0.0.1 id >/dev/null || die 'new key login'
printf 'container-test-password\n' | ssh "${SSH_OPTIONS[@]}" init_test@127.0.0.1 \
    'sudo -S -p "" id -u' > "$WORK_DIR/sudo-login"
grep -qx 0 "$WORK_DIR/sudo-login" || die 'password-protected sudo after hardening'
if sshpass -p container-test-password ssh "${SSH_OPTIONS[@]}" -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password init_test@127.0.0.1 true; then die 'password login remains allowed'; fi
mkdir -p /root/.ssh
printf '%s\n' "$key" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
if ssh "${SSH_OPTIONS[@]}" -o BatchMode=yes root@127.0.0.1 true; then die 'root SSH remains allowed'; fi
touch /tmp/init-session-release
wait "$session_pid"
grep -qx survived "$WORK_DIR/session" || die 'existing session disconnected'
ok 'real OpenRC reload: existing session survives, new key + sudo works, password/root login denied'

before=$(sha256sum "$SSH_DROPIN")
disable_ssh_password_auth <<< y
[[ $(sha256sum "$SSH_DROPIN") == "$before" ]] || die 'repeat hardening rewrote config'
show_status > "$WORK_DIR/status"
grep -q 'Manager: openrc' "$WORK_DIR/status" || die 'status manager'
grep -q 'Port 22 listener: sshd' "$WORK_DIR/status" || die 'status listener'
if LC_ALL=C grep -q $'\033' "$WORK_DIR/status"; then die 'redirected status contains color'; fi
[[ ! -e /run/sshd ]] || die 'created Debian runtime directory'
ok 'idempotence, Alpine status and plain-text output'

# A minimal Alpine install need not have either timezone file.
rm -f /etc/localtime /etc/timezone
configure_timezone
[[ $(get_timezone) == UTC && -f /etc/localtime ]] || die 'minimal-install timezone'
ok 'timezone setup without pre-existing localtime'
printf '\nAlpine container integration passed.\n'
