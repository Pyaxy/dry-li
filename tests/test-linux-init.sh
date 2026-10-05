#!/usr/bin/env bash
# Safe isolated tests: source functions, mock administration, use only a temp tree.
# Literal shadow hashes/systemd variables and globals used by sourced functions.
# shellcheck disable=SC2016,SC2034
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT_PATH="$SCRIPT_DIR/../public/linux-init/linux-init.sh"
# shellcheck source=../public/linux-init/linux-init.sh
source "$SCRIPT_PATH"
TEST_ROOT=$(mktemp -d)
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
TEST_COMPLETED=0
test_cleanup() {
    local status=$?
    rm -rf -- "$TEST_ROOT"
    if (( TEST_COMPLETED != 1 )); then
        printf 'FAIL: test suite did not reach completion.\n' >&2
        exit 1
    fi
    exit "$status"
}
trap test_cleanup EXIT
WORK_DIR="$TEST_ROOT/work"
SSHD_CONFIG="$TEST_ROOT/ssh/sshd_config"
SSH_DROPIN_DIR="$TEST_ROOT/ssh/sshd_config.d"
SSH_DROPIN="$SSH_DROPIN_DIR/00-key-only.conf"
SSH_ENV_FILES=("$TEST_ROOT/default-ssh")
BACKUP_ROOT="$TEST_ROOT/backups"
SSH_RUNTIME_DIR="$TEST_ROOT/run/sshd"
mkdir -p "$WORK_DIR" "$SSH_DROPIN_DIR" "$TEST_ROOT/home/ppy" "$TEST_ROOT/home/admin"
SSHD=$(command -v sshd || true)
[[ -n $SSHD ]] || SSHD=/usr/sbin/sshd
[[ -x $SSHD ]] || { printf 'Tests need OpenSSH server (only -t/-T, never started).\n' >&2; exit 1; }
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/host"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key1"
ssh-keygen -q -t rsa -b 2048 -N '' -f "$TEST_ROOT/key2"
KEY1=$(cat "$TEST_ROOT/key1.pub")
KEY2=$(cat "$TEST_ROOT/key2.pub")
FAKE_UID=$(command id -u)
PASSWD_FIXTURE="$TEST_ROOT/passwd"
SHADOW_FIXTURE="$TEST_ROOT/shadow"
LOG="$TEST_ROOT/actions"
: > "$LOG"
SUDO_MEMBER=yes
RELOAD_FAIL=0
SYNTAX_FAIL=0
SUDO_POLICY_OK=yes
FAKE_ENVIRONMENT_FILES=''
FAKE_TRIGGERED_BY=''
FAKE_SOCKETS=''
FAKE_SOCKET_ACTIVE=no
FAKE_SOCKET_ENABLED=enabled
FAKE_LISTENER_OWNER=sshd
FAKE_SERVICE_ACTIVE=yes
RELOAD_EXIT=0
RELOAD_PERSISTENT_FAILURE=0
RELOAD_DELAYED_EXIT=0
RELOAD_LOST_LISTENER=0

# No actual user, group, package, ownership or service mutations are permitted.
getent() {
    local file
    case "$1" in passwd) file=$PASSWD_FIXTURE ;; shadow) file=$SHADOW_FIXTURE ;; group) printf 'sudo:x:27:ppy\n'; return 0 ;; *) return 1 ;; esac
    if [[ $# == 1 ]]; then cat "$file"; else awk -F: -v user="$2" '$1==user {print; found=1} END {exit !found}' "$file"; fi
}
id() {
    case "$1" in
        -u) printf '%s\n' "$FAKE_UID" ;;
        -g) command id -g ;;
        -nG) if [[ $SUDO_MEMBER == yes ]]; then printf 'ppy sudo\n'; else printf 'ppy\n'; fi ;;
        *) command id "$@" ;;
    esac
}
chown() { printf 'chown %s\n' "$*" >> "$LOG"; }
useradd() { printf 'useradd %s\n' "$*" >> "$LOG"; }
usermod() { printf 'usermod %s\n' "$*" >> "$LOG"; }
passwd() { printf 'passwd %s\n' "$*" >> "$LOG"; }
apt-get() { printf 'apt-get %s\n' "$*" >> "$LOG"; }
sudo() {
    [[ $1 == -l ]] || { printf 'Unexpected sudo!\n' >&2; return 1; }
    [[ $SUDO_POLICY_OK == yes ]] || return 1
    printf 'User ppy may run the following commands:\n    (ALL : ALL) ALL\n'
}
visudo() { [[ $SUDO_POLICY_OK == yes ]]; }
# BSD stat compatibility for the tests, leaving production code GNU/Linux native.
stat() {
    local format=$2 path=${!#} bsd
    # The temporary root lives below a shared /tmp on macOS. Simulate the
    # normal root-owned /home ancestors, while checking real fixture permissions.
    if [[ $path == /private/tmp || $path == /tmp || $path == /private ]]; then
        [[ $format != '%u %a' ]] || { printf '0 755\n'; return; }
    fi
    if command stat -c "$format" "$path" 2>/dev/null; then return; fi
    case "$format" in '%u %a') bsd='%u %Lp' ;; %h) bsd='%l' ;; *) return 1 ;; esac
    command stat -f "$bsd" "$path"
}
systemctl() {
    local unit=${!#} state command_line="$*"
    case "$1" in
        is-active)
            case "$unit" in
                *.socket) if [[ $FAKE_SOCKET_ACTIVE == yes ]]; then state=active; else state=inactive; fi ;;
                *.service) if [[ $FAKE_SERVICE_ACTIVE == yes ]]; then state=active; else state=inactive; fi ;;
                *) state=unknown ;;
            esac
            [[ $2 == --quiet ]] || printf '%s\n' "$state"
            [[ $state == active ]] || return 3 ;;
        is-enabled)
            case "$unit" in *.socket) state=$FAKE_SOCKET_ENABLED ;; *.service) state=$FAKE_SERVICE_ENABLED ;; *) state=not-found ;; esac
            printf '%s\n' "$state"
            [[ $state == enabled || $state == enabled-runtime ]] || return 1 ;;
        reload|stop|disable|enable|reset-failed|start)
            printf '%s\n' "$command_line" >> "$LOG"
            if [[ $command_line == "$FAIL_SERVICE_STEP" ]]; then FAIL_SERVICE_STEP=''; return 1; fi
            [[ $command_line != "$FAIL_PERSISTENT_STEP" ]] || return 1
            case "$1" in
                reload)
                    if (( RELOAD_EXIT )); then FAKE_SERVICE_ACTIVE=no; rm -rf "$SSH_RUNTIME_DIR"; return 1; fi
                    if (( RELOAD_PERSISTENT_FAILURE )); then return 1; fi
                    if (( RELOAD_FAIL )); then RELOAD_FAIL=0; return 1; fi ;;
                stop)
                    case "$unit" in *.socket) FAKE_SOCKET_ACTIVE=no ;; *.service) FAKE_SERVICE_ACTIVE=no; rm -rf "$SSH_RUNTIME_DIR" ;; esac ;;
                disable) case "$unit" in *.socket) FAKE_SOCKET_ENABLED=disabled ;; *.service) FAKE_SERVICE_ENABLED=disabled ;; esac ;;
                enable)
                    state=enabled; [[ $2 != --runtime ]] || state='enabled-runtime'
                    case "$unit" in *.socket) FAKE_SOCKET_ENABLED=$state ;; *.service) FAKE_SERVICE_ENABLED=$state ;; esac ;;
                start)
                    case "$unit" in
                        *.socket) FAKE_SOCKET_ACTIVE=yes ;;
                        *.service) FAKE_SERVICE_ACTIVE=yes; mkdir -p "$SSH_RUNTIME_DIR"; RELOAD_DELAYED_EXIT=0 ;;
                    esac ;;
            esac
            case "$FAKE_SOCKET_ACTIVE:$FAKE_SERVICE_ACTIVE" in
                yes:yes) FAKE_LISTENER_OWNER=shared ;;
                yes:no) FAKE_LISTENER_OWNER=systemd ;;
                no:yes) FAKE_LISTENER_OWNER=sshd ;;
                no:no) FAKE_LISTENER_OWNER=missing ;;
            esac
            if [[ $1 == start && $unit == *.service && -n $FAULT_AFTER_START ]]; then
                case "$FAULT_AFTER_START" in owner) FAKE_LISTENER_OWNER=missing ;; service) FAKE_SERVICE_ACTIVE=no ;; esac
                FAULT_AFTER_START=''
            fi ;;
        show) case "$*" in
            *LoadState*)
                if [[ $2 == *.socket && ( $2 == sshd.socket || $FAKE_NO_SOCKET == yes ) ]] || [[ $2 == ssh.service && $FAKE_SERVICE_ID == sshd.service ]]; then
                    printf 'not-found\n'
                else printf 'loaded\n'; fi ;;
            *' -p Id '*) if [[ $2 == *.service ]]; then printf '%s\n' "$FAKE_SERVICE_ID"; else printf '%s\n' "$2"; fi ;;
            *MainPID*) if [[ $FAKE_SERVICE_ACTIVE == yes ]]; then printf '4321\n'; else printf '0\n'; fi ;;
            *TriggeredBy*) printf '%s\n' "$FAKE_TRIGGERED_BY" ;;
            *Sockets*) printf '%s\n' "$FAKE_SOCKETS" ;;
            *ExecStartPre*) if [[ $2 == *.service ]]; then printf '{ path=/usr/sbin/sshd ; argv[]=/usr/sbin/sshd -t ; ignore_errors=no ; }\n'; else printf '\n'; fi ;;
            *ExecStartPost*) printf '%s\n' "$FAKE_START_HOOK" ;;
            *ExecStart*) printf '{ path=/usr/sbin/sshd ; argv[]=/usr/sbin/sshd -D $SSHD_OPTS ; ignore_errors=no ; }\n' ;;
            *EnvironmentFiles*) printf '%s\n' "$FAKE_ENVIRONMENT_FILES" ;;
            *Environment*) printf '\n' ;;
            *CanReload*) printf 'yes\n' ;;
            *KillMode*) printf '%s\n' "$FAKE_KILL_MODE" ;;
            *SendSIGHUP*) printf '%s\n' "$FAKE_SEND_HUP" ;;
            *KillSignal*) printf '15\n' ;;
            *ExecStop*) printf '%s\n' "$FAKE_STOP_HOOK" ;;
            *Requires*|*Wants*|*BindsTo*) printf '%s\n' "$FAKE_DEPENDENCIES" ;;
            *Accept*) printf 'no\n' ;;
            *Listen*) printf '%s\n' "$FAKE_SOCKET_LISTEN" ;;
            *' -p Triggers '*) printf '%s\n' "$FAKE_SERVICE_ID" ;;
            *) printf 'Unexpected show property: %s\n' "$*" >&2; return 1 ;;
        esac ;;
        *) printf 'Unexpected service command!\n' >&2; return 1 ;;
    esac
}
install() {
    [[ ${!#} == "$SSH_RUNTIME_DIR" ]] || { printf 'Unexpected install!\n' >&2; return 1; }
    mkdir -p "$SSH_RUNTIME_DIR"
}
ss() {
    case "$FAKE_LISTENER_OWNER" in
        sshd) printf 'LISTEN 0 128 *:22 *:* users:(("sshd",pid=4321,fd=3))\n' ;;
        shared) printf 'LISTEN 0 128 *:22 *:* users:(("sshd",pid=4321,fd=3),("systemd",pid=1,fd=87))\n' ;;
        systemd) printf 'LISTEN 0 128 *:22 *:* users:(("systemd",pid=1,fd=87))\n' ;;
        wrongport) printf 'LISTEN 0 128 *:443 *:* users:(("sshd",pid=4321,fd=3))\n' ;;
        missing) printf 'LISTEN 0 128 *:443 *:* users:(("caddy",pid=3758,fd=6))\n' ;;
        error) return 1 ;;
    esac
}
sleep() {
    # Simulate a daemon failing after systemctl reload already returned success.
    if (( RELOAD_DELAYED_EXIT )); then FAKE_SERVICE_ACTIVE=no; fi
    if (( RELOAD_LOST_LISTENER )); then FAKE_LISTENER_OWNER=missing; fi
} # No wall-clock waits in mocked service-health sampling.
# Count validation failures without touching the actual daemon.
real_sshd=$SSHD
sshd_test() {
    if [[ $1 == -t && ! -d $SSH_RUNTIME_DIR ]]; then printf 'Missing privilege separation directory: /run/sshd\n' >&2; return 1; fi
    if [[ $1 == -t && -f $SSH_DROPIN ]] && grep -q 'PasswordAuthentication no' "$SSH_DROPIN" && (( SYNTAX_FAIL )); then return 1; fi
    "$real_sshd" "$@"
}
SSHD=sshd_test

ok() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3 ($1 != $2)"; }
reset_config() {
    rm -f "$SSH_DROPIN" "$SSH_DROPIN_DIR"/*.conf
    printf 'Include %s/*.conf\nHostKey %s/host\nPidFile %s/pid\nUsePAM no\n' "$SSH_DROPIN_DIR" "$TEST_ROOT" "$TEST_ROOT" > "$SSHD_CONFIG"
    printf 'PasswordAuthentication yes\n' > "$SSH_DROPIN_DIR/50-cloud-init.conf"
    : > "$LOG"
    SSH_TRANSACTION=0; SSH_RELOAD_ATTEMPTED=0; SSH_ROLLBACK_FAILED=0; SYNTAX_FAIL=0; RELOAD_FAIL=0
    RELOAD_EXIT=0; RELOAD_PERSISTENT_FAILURE=0; RELOAD_DELAYED_EXIT=0; RELOAD_LOST_LISTENER=0
    FAKE_TRIGGERED_BY=''; FAKE_SOCKETS=''; FAKE_SOCKET_ACTIVE=no; FAKE_SERVICE_ACTIVE=yes
    FAKE_SOCKET_ENABLED=disabled; FAKE_LISTENER_OWNER=sshd
    FAKE_SERVICE_ENABLED=enabled; FAKE_KILL_MODE=process; FAKE_SEND_HUP=no; FAKE_STOP_HOOK=''; FAKE_DEPENDENCIES=''; FAKE_START_HOOK=''
    FAKE_SOCKET_LISTEN='[::]:22 (Stream)'; FAIL_SERVICE_STEP=''; FAIL_PERSISTENT_STEP=''; FAULT_AFTER_START=''; SSH_MODE_CHANGED=0
    FAKE_SERVICE_ID=ssh.service; FAKE_NO_SOCKET=no
    mkdir -p "$SSH_RUNTIME_DIR"
}
set_users() {
    printf 'root:x:0:0:root:%s:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\nppy:x:1000:1000::%s:/bin/bash\nadmin:x:1001:1001::%s:/bin/bash\nservice:x:1002:1002::/srv/service:/bin/false\n' "$TEST_ROOT/root" "$TEST_ROOT/home/ppy" "$TEST_ROOT/home/admin" > "$PASSWD_FIXTURE"
    printf 'ppy:$6$fixture:20000:0:99999:7:::\nadmin:!:20000:0:99999:7:::\n' > "$SHADOW_FIXTURE"
}

reset_config
set_users
assert_eq "$(list_login_users)" $'ppy\nadmin' 'exclude system/root/nologin users'
ok 'login-user discovery'
if ! valid_public_key "$KEY1" || ! valid_public_key "$KEY2"; then fail 'real valid keys rejected'; fi
if valid_public_key 'ssh-ed25519 AAAA fake'; then fail 'invalid blob accepted'; fi
if plain_public_key "command=\"false\" $KEY1"; then fail 'restricted key accepted as admin key'; fi
ok 'real key blob validation and restricted-key rejection'

append_keys ppy "$KEY1" "$KEY2"
append_keys ppy "$(key_identity "$KEY1") changed-comment"
assert_eq "$(count_authorized_keys ppy)" 2 'duplicate key/comment dedupe'
assert_eq "$(stat -c '%u %a' "$TEST_ROOT/home/ppy/.ssh")" "$FAKE_UID 700" 'ssh directory permission'
assert_eq "$(stat -c '%u %a' "$TEST_ROOT/home/ppy/.ssh/authorized_keys")" "$FAKE_UID 600" 'key file permission'
ok 'key append idempotence and permissions'
printf '%s' "$KEY1" > "$TEST_ROOT/home/admin/old-keys"
mkdir -p "$TEST_ROOT/home/admin/.ssh"
cp "$TEST_ROOT/home/admin/old-keys" "$TEST_ROOT/home/admin/.ssh/authorized_keys"
append_keys admin "$KEY2"
assert_eq "$(count_authorized_keys admin)" 2 'preserve final line without newline'
if append_keys ppy "$KEY1" 'ssh-rsa invalid'; then fail 'invalid batch accepted'; fi
assert_eq "$(count_authorized_keys ppy)" 2 'invalid batch changed keys'
rm "$TEST_ROOT/home/admin/.ssh/authorized_keys"
ln -s "$TEST_ROOT/home/admin/old-keys" "$TEST_ROOT/home/admin/.ssh/authorized_keys"
if append_keys admin "$KEY2"; then fail 'symlink accepted'; fi
ok 'existing key preservation, invalid batch, symlink protection'

check_ssh_hardening_readiness || fail 'valid admin rejected'
SUDO_MEMBER=no
if check_ssh_hardening_readiness; then fail 'non-sudo user passed'; fi
SUDO_MEMBER=yes
SUDO_POLICY_OK=no
if check_ssh_hardening_readiness; then fail 'broken sudo policy passed'; fi
SUDO_POLICY_OK=yes
cp "$SHADOW_FIXTURE" "$TEST_ROOT/shadow-backup"
printf 'ppy:!:20000:0:99999:7:::\n' > "$SHADOW_FIXTURE"
if check_ssh_hardening_readiness; then fail 'locked user passed'; fi
printf 'ppy:$6$fixture:20000:0:99999:7::1:\n' > "$SHADOW_FIXTURE"
if check_ssh_hardening_readiness; then fail 'expired user passed'; fi
cp "$TEST_ROOT/shadow-backup" "$SHADOW_FIXTURE"
chmod 666 "$TEST_ROOT/home/ppy/.ssh/authorized_keys"
if check_ssh_hardening_readiness; then fail 'unsafe permissions passed'; fi
chmod 600 "$TEST_ROOT/home/ppy/.ssh/authorized_keys"
ok 'administrator prerequisites: sudo policy, shadow state, StrictModes'

cp "$PASSWD_FIXTURE" "$TEST_ROOT/passwd-backup"
head -n 1 "$TEST_ROOT/passwd-backup" > "$PASSWD_FIXTURE"
: > "$LOG"
authorize_ssh_key >/dev/null 2>&1
disable_ssh_password_auth >/dev/null 2>&1
[[ ! -s $LOG && ! -f $SSH_DROPIN ]] || fail 'root-only machine modified by guarded actions'
cp "$TEST_ROOT/passwd-backup" "$PASSWD_FIXTURE"
ok 'root-only machine: key authorization and hardening safely return'

# Existing-user branch does not recreate users; supplemental sudo is available.
: > "$LOG"
create_user <<< $'ppy\n2' >/dev/null
[[ ! -s $LOG ]] || fail 'existing user changed'
SUDO_MEMBER=no
package_installed() { return 0; }
create_user <<< $'ppy\n1' >/dev/null
[[ $(cat "$LOG") == 'usermod -aG sudo ppy' ]] || fail 'supplemental sudo grant'
SUDO_MEMBER=yes
ok 'existing user and supplemental sudo'

reset_config
printf 'SSHD_OPTS=\n' > "${SSH_ENV_FILES[0]}"
check_supported_ssh_layout || fail 'standard include rejected'
find_ssh_service || fail 'standard service rejected'
FAKE_ENVIRONMENT_FILES="${SSH_ENV_FILES[0]} (ignore_errors=yes)"
find_ssh_service || fail 'standard environment file rejected'
FAKE_ENVIRONMENT_FILES='/custom/sshd-env (ignore_errors=yes)'
if find_ssh_service; then fail 'custom environment file accepted'; fi
FAKE_ENVIRONMENT_FILES=''
printf '\nMatch User ppy\n PasswordAuthentication yes\n' >> "$SSH_DROPIN_DIR/50-cloud-init.conf"
if check_supported_ssh_layout; then fail 'Match accepted'; fi
reset_config
printf 'PasswordAuthentication yes\nInclude %s/*.conf\nHostKey %s/host\n' "$SSH_DROPIN_DIR" "$TEST_ROOT" > "$SSHD_CONFIG"
if check_supported_ssh_layout; then fail 'late Include accepted'; fi
printf '# comment-only\n' > "$SSHD_CONFIG"
if check_supported_ssh_layout; then fail 'missing Include accepted'; fi
reset_config
printf 'SSHD_OPTS="-o PasswordAuthentication=yes"\n' > "${SSH_ENV_FILES[0]}"
if find_ssh_service; then fail 'custom service options accepted'; fi
rm "${SSH_ENV_FILES[0]}"
ok 'configuration precedence, Match and service-option refusal'

reset_config
FAKE_SOCKETS=custom-ssh.socket
disable_ssh_password_auth <<< y >/dev/null 2>&1
[[ ! -f $SSH_DROPIN && ! -s $LOG ]] || fail 'custom socket wrote or reloaded'
ok 'custom explicit Sockets refuses before writes'

reset_config
FAKE_TRIGGERED_BY=ssh.socket
FAKE_SOCKET_ENABLED=disabled
find_ssh_service || fail 'inactive disabled socket relationship blocked classic daemon'
ok 'inactive disabled socket metadata permits independently listening daemon'

for owner_case in systemd shared missing error wrongport; do
    reset_config
    FAKE_TRIGGERED_BY=ssh.socket
    FAKE_SOCKET_ENABLED=disabled
    FAKE_LISTENER_OWNER=$owner_case
    disable_ssh_password_auth <<< y >/dev/null 2>&1
    [[ ! -f $SSH_DROPIN && ! -s $LOG ]] || fail "listener owner $owner_case wrote or reloaded"
done
ok 'listener ownership: systemd, shared, missing or query error refuses before writes'

reset_config
(
    confirm() { FAKE_SOCKET_ACTIVE=yes; return 0; }
    disable_ssh_password_auth >/dev/null 2>&1
)
[[ ! -f $SSH_DROPIN && ! -s $LOG ]] || fail 'socket activated during confirmation was not caught'
ok 'socket activated during operator verification: recheck before writes'

# Exercise Debian 13/LXC socket -> service conversion, never a live systemd.
for mode_case in both socket-only enabled-inactive runtime-enabled alias-service; do
    reset_config
    FAKE_TRIGGERED_BY=ssh.socket
    FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
    case "$mode_case" in
        socket-only) FAKE_SERVICE_ACTIVE=no; FAKE_SERVICE_ENABLED=disabled; FAKE_LISTENER_OWNER=systemd ;;
        enabled-inactive) FAKE_SOCKET_ACTIVE=no; FAKE_LISTENER_OWNER=sshd ;;
        runtime-enabled) FAKE_SOCKET_ENABLED='enabled-runtime'; FAKE_SERVICE_ENABLED='enabled-runtime' ;;
        alias-service) FAKE_SERVICE_ID=sshd.service ;;
    esac
    show_ssh_runtime_status > "$TEST_ROOT/status"
    if [[ $FAKE_SOCKET_ACTIVE == yes ]]; then grep -q 'Mode: socket-activated' "$TEST_ROOT/status" || fail 'socket status mode'; fi
    disable_ssh_password_auth <<< y > "$TEST_ROOT/migration-output" 2>&1 || { cat "$TEST_ROOT/migration-output"; fail "migration $mode_case failed"; }
    assert_eq "$FAKE_SERVICE_ACTIVE" yes 'migration service not active'
    assert_eq "$FAKE_SERVICE_ENABLED" enabled 'migration service not enabled'
    assert_eq "$FAKE_SOCKET_ACTIVE" no 'migration socket not stopped'
    assert_eq "$FAKE_SOCKET_ENABLED" disabled 'migration socket not disabled'
    assert_eq "$FAKE_LISTENER_OWNER" sshd 'migration listener not sshd'
    [[ -f $SSH_BACKUP/service-state ]] || fail 'missing unit-state backup'
    if grep -q '^reload ' "$LOG"; then fail "migration $mode_case sent HUP"; fi
    grep -q "^stop $FAKE_SERVICE_ID" "$LOG" || fail 'active service was not stopped before fresh start'
    grep -q 'Mode: service' "$TEST_ROOT/migration-output" || fail 'final service mode not shown'
    key_only_values "$(get_effective_sshd_config)" || fail 'migration lost auth settings'
    cp "$LOG" "$TEST_ROOT/migrated-actions"
    disable_ssh_password_auth <<< y >/dev/null
    cmp "$LOG" "$TEST_ROOT/migrated-actions" || fail 'migrated action not idempotent'
done
ok 'socket migration: both active, socket-only, enabled inactive, runtime enabled, sshd alias; no HUP'

# Already hardened socket installations must still migrate after confirmation.
reset_config
FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
printf 'PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > "$SSH_DROPIN"
disable_ssh_password_auth <<< n >/dev/null
[[ ! -s $LOG ]] || fail 'cancelled migration changed units'
disable_ssh_password_auth <<< y >/dev/null
assert_eq "$FAKE_SOCKET_ACTIVE" no 'already hardened socket skipped migration'
ok 'already key-only socket still requires confirmation and migrates'

for unsafe_case in kill-mode hup hook start-hook dependency socket-port sshd-port sshd-address missing-listener; do
    reset_config
    FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
    case "$unsafe_case" in
        kill-mode) FAKE_KILL_MODE=control-group ;;
        hup) FAKE_SEND_HUP=yes ;;
        hook) FAKE_STOP_HOOK='/usr/bin/custom-stop' ;;
        start-hook) FAKE_START_HOOK='/usr/bin/custom-start' ;;
        dependency) FAKE_DEPENDENCIES=ssh.socket ;;
        socket-port) FAKE_SOCKET_LISTEN='[::]:2222 (Stream)' ;;
        sshd-port) printf 'Port 2222\n' >> "$SSHD_CONFIG" ;;
        sshd-address) printf 'ListenAddress 127.0.0.1\n' >> "$SSHD_CONFIG" ;;
        missing-listener) FAKE_LISTENER_OWNER=missing ;;
    esac
    disable_ssh_password_auth <<< y >/dev/null 2>&1
    [[ ! -f $SSH_DROPIN && ! -s $LOG ]] || fail "unsafe migration $unsafe_case changed host"
done
ok 'migration refuses unsafe stop policy, hooks, dependencies and nonstandard listening'

reset_config
FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
printf 'InvalidSSHDirective yes\n' >> "$SSHD_CONFIG"
if disable_ssh_password_auth <<< y > "$TEST_ROOT/failure-output" 2>&1; then fail 'original syntax failure returned success'; fi
[[ ! -f $SSH_DROPIN && ! -s $LOG ]] || fail 'original syntax failure touched configuration/units'
reset_config
FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
rm -rf "$SSH_RUNTIME_DIR"
if disable_ssh_password_auth <<< y > "$TEST_ROOT/failure-output" 2>&1; then fail 'missing runtime directory bypassed syntax gate'; fi
[[ ! -d $SSH_RUNTIME_DIR && ! -f $SSH_DROPIN && ! -s $LOG ]] || fail 'initial -t failure was bypassed'
reset_config
FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
SYNTAX_FAIL=1
if disable_ssh_password_auth <<< y >/dev/null 2>&1; then fail 'candidate syntax failure succeeded'; fi
[[ ! -f $SSH_DROPIN ]] || fail 'candidate syntax failure retained dropin'
if grep -qE '^(stop|disable|enable|start|reset-failed|reload) ' "$LOG"; then fail 'candidate syntax failure touched units'; fi
ok 'original/candidate -t gates forbid all service changes, including missing runtime directory'

# One failure at each mutation step must restore config AND original unit states.
for fault in 'stop ssh.socket' 'disable ssh.socket' 'stop ssh.service' 'reset-failed ssh.service' 'enable ssh.service' 'start ssh.service' owner service; do
    reset_config
    FAKE_TRIGGERED_BY=ssh.socket
    FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
    printf 'PasswordAuthentication yes\n' > "$SSH_DROPIN"
    cp "$SSH_DROPIN" "$TEST_ROOT/old-dropin"
    case "$fault" in owner|service) FAULT_AFTER_START=$fault ;; *) FAIL_SERVICE_STEP=$fault ;; esac
    if disable_ssh_password_auth <<< y > "$TEST_ROOT/failure-output" 2>&1; then fail "migration fault $fault reported success"; fi
    cmp "$SSH_DROPIN" "$TEST_ROOT/old-dropin" || fail "migration fault $fault lost config"
    assert_eq "$FAKE_SERVICE_ACTIVE" yes 'rollback service activity'
    assert_eq "$FAKE_SERVICE_ENABLED" enabled 'rollback service enable state'
    assert_eq "$FAKE_SOCKET_ACTIVE" yes 'rollback socket activity'
    assert_eq "$FAKE_SOCKET_ENABLED" enabled 'rollback socket enable state'
    assert_eq "$SSH_ROLLBACK_FAILED" 0 "migration fault $fault recovery failed"
    [[ $FAKE_LISTENER_OWNER == shared ]] || fail 'rollback did not restore port 22'
    if grep -q '^reload ' "$LOG"; then fail "migration fault $fault reloads socket service"; fi
    cp "$LOG" "$TEST_ROOT/restored-actions"
    rollback_ssh >/dev/null
    cmp "$LOG" "$TEST_ROOT/restored-actions" || fail 'rollback retried after restoration'
done
ok 'each migration step/health failure restores original config, enabled states and socket listener without HUP'

for recovery_case in socket-only enabled-inactive runtime-enabled; do
    reset_config
    FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
    case "$recovery_case" in
        socket-only) FAKE_SERVICE_ACTIVE=no; FAKE_SERVICE_ENABLED=disabled; FAKE_LISTENER_OWNER=systemd ;;
        enabled-inactive) FAKE_SOCKET_ACTIVE=no; FAKE_LISTENER_OWNER=sshd ;;
        runtime-enabled) FAKE_SOCKET_ENABLED='enabled-runtime'; FAKE_SERVICE_ENABLED='enabled-runtime' ;;
    esac
    expected_service_active=$FAKE_SERVICE_ACTIVE; expected_service_enabled=$FAKE_SERVICE_ENABLED
    expected_socket_active=$FAKE_SOCKET_ACTIVE; expected_socket_enabled=$FAKE_SOCKET_ENABLED
    FAIL_SERVICE_STEP='start ssh.service'
    if disable_ssh_password_auth <<< y >/dev/null 2>&1; then fail 'fault returned success'; fi
    assert_eq "$FAKE_SERVICE_ACTIVE" "$expected_service_active" 'restore original service activity'
    assert_eq "$FAKE_SERVICE_ENABLED" "$expected_service_enabled" 'restore original service enable state'
    assert_eq "$FAKE_SOCKET_ACTIVE" "$expected_socket_active" 'restore original socket activity'
    assert_eq "$FAKE_SOCKET_ENABLED" "$expected_socket_enabled" 'restore original socket enable state'
    assert_eq "$SSH_ROLLBACK_FAILED" 0 'restore variant failed'
    [[ ! -f $SSH_DROPIN ]] || fail 'new dropin not deleted'
done
ok 'rollback preserves socket-only, inactive enabled and runtime-enabled original modes'

reset_config
FAKE_SOCKET_ACTIVE=yes; FAKE_SOCKET_ENABLED=enabled; FAKE_LISTENER_OWNER=shared
FAIL_PERSISTENT_STEP='start ssh.service'
if disable_ssh_password_auth <<< y > "$TEST_ROOT/failure-output" 2>&1; then fail 'persistent migration failure returned success'; fi
assert_eq "$SSH_ROLLBACK_FAILED" 1 'terminal migration recovery failure not flagged'
assert_eq "$FAKE_SOCKET_ACTIVE" yes 'recovery did not restore socket listener despite dead service'
grep -q 'Port 22 listener: systemd' "$TEST_ROOT/failure-output" || fail 'failed recovery omitted final listener report'
cp "$LOG" "$TEST_ROOT/failed-actions"
rollback_ssh >> "$TEST_ROOT/failure-output" 2>&1 || true
rollback_ssh >> "$TEST_ROOT/failure-output" 2>&1 || true
cmp "$LOG" "$TEST_ROOT/failed-actions" || fail 'terminal migration rollback repeated'
assert_eq "$(grep -c '已恢复 SSH drop-in' "$TEST_ROOT/failure-output")" 1 'migration recovery duplicate warnings'
ok 'persistent recovery failure reports remaining 22 listener and never loops'

reset_config
FAKE_NO_SOCKET=yes
find_ssh_service || fail 'classic service without socket unit rejected'
show_ssh_runtime_status > "$TEST_ROOT/status"
grep -q 'Mode: service' "$TEST_ROOT/status" || fail 'classic mode missing'
grep -q 'Socket: not-found' "$TEST_ROOT/status" || fail 'missing socket status wrong'
grep -q 'Port 22 listener: sshd' "$TEST_ROOT/status" || fail 'sshd listener status missing'
ok 'readonly status and classic service without socket unit'

reset_config
SUDO_MEMBER=no
disable_ssh_password_auth >/dev/null
[[ ! -f $SSH_DROPIN && ! -s $LOG ]] || fail 'unsafe hardening modified system'
SUDO_MEMBER=yes
ok 'no ready admin: no write, no reload'

reset_config
disable_ssh_password_auth <<< y >/dev/null
config=$(get_effective_sshd_config)
key_only_values "$config" || fail 'hardening did not win over cloud-init'
assert_eq "$(grep -c '^reload ' "$LOG")" 1 'reload once'
cp "$SSH_DROPIN" "$TEST_ROOT/hardened"
disable_ssh_password_auth <<< y >/dev/null
cmp "$SSH_DROPIN" "$TEST_ROOT/hardened" || fail 'idempotent hardening rewrote file'
assert_eq "$(grep -c '^reload ' "$LOG")" 1 'idempotent hardening reloaded'
ok 'real sshd -t/-T, cloud-init priority, successful reload, repeated action'

reset_config
SYNTAX_FAIL=1
if disable_ssh_password_auth <<< y >/dev/null 2>&1; then fail 'syntax failure reported success'; fi
if [[ -f $SSH_DROPIN ]] || grep -q '^reload ' "$LOG"; then fail 'syntax failure did not restore before reload'; fi
assert_eq "$SSH_TRANSACTION" 0 'transaction after syntax failure'
ok 'syntax failure: restore newly created drop-in, no reload'

reset_config
printf 'PasswordAuthentication yes\n' > "$SSH_DROPIN"
cp "$SSH_DROPIN" "$TEST_ROOT/old-dropin"
RELOAD_FAIL=1
if disable_ssh_password_auth <<< y >/dev/null 2>&1; then fail 'reload failure reported success'; fi
cmp "$SSH_DROPIN" "$TEST_ROOT/old-dropin" || fail 'reload failure did not restore existing drop-in'
assert_eq "$(grep -c '^reload ' "$LOG")" 2 'failed reload followed by restore reload'
ok 'reload failure: restore prior content and reload restored config'

for exit_case in immediate delayed; do
    reset_config
    printf 'PasswordAuthentication yes\n' > "$SSH_DROPIN"
    cp "$SSH_DROPIN" "$TEST_ROOT/old-dropin"
    case "$exit_case" in immediate) RELOAD_EXIT=1 ;; delayed) RELOAD_DELAYED_EXIT=1 ;; esac
    if disable_ssh_password_auth <<< y > "$TEST_ROOT/failure-output" 2>&1; then fail 'dead daemon reported success'; fi
    # main and EXIT both call rollback again, but recovery must not loop.
    rollback_ssh >> "$TEST_ROOT/failure-output" 2>&1 || true
    rollback_ssh >> "$TEST_ROOT/failure-output" 2>&1 || true
    cmp "$SSH_DROPIN" "$TEST_ROOT/old-dropin" || fail 'dead daemon did not restore file'
    assert_eq "$(grep -c '^reload ' "$LOG")" 1 'dead daemon received another reload'
    assert_eq "$(grep -c '已恢复 SSH drop-in' "$TEST_ROOT/failure-output")" 1 'duplicate restore warning'
    if grep -q 'Missing privilege separation directory' "$TEST_ROOT/failure-output"; then fail 'validated stopped daemon with missing runtime dir'; fi
    assert_eq "$SSH_ROLLBACK_FAILED" 0 'dead service was not recovered'
    assert_eq "$FAKE_SERVICE_ACTIVE" yes 'restored service not active'
    assert_eq "$(grep -c '^start ssh.service' "$LOG")" 1 'dead service not started'
done
ok 'daemon exits on/after reload: restore once, no inactive reload or repeated rollback'

reset_config
RELOAD_PERSISTENT_FAILURE=1
if disable_ssh_password_auth <<< y > "$TEST_ROOT/failure-output" 2>&1; then fail 'persistent reload failure reported success'; fi
rollback_ssh >> "$TEST_ROOT/failure-output" 2>&1 || true
rollback_ssh >> "$TEST_ROOT/failure-output" 2>&1 || true
assert_eq "$(grep -c '^reload ' "$LOG")" 2 'persistent failure retried recovery'
assert_eq "$(grep -c '已恢复 SSH drop-in' "$TEST_ROOT/failure-output")" 1 'persistent failure repeated restore'
ok 'restore reload fails: terminal failure, no retries from main/EXIT'

reset_config
printf 'PasswordAuthentication yes\n' > "$SSH_DROPIN"
cp "$SSH_DROPIN" "$TEST_ROOT/old-dropin"
RELOAD_LOST_LISTENER=1
if disable_ssh_password_auth <<< y > "$TEST_ROOT/failure-output" 2>&1; then fail 'active service without listener reported success'; fi
cmp "$SSH_DROPIN" "$TEST_ROOT/old-dropin" || fail 'listener loss did not restore file'
assert_eq "$SSH_ROLLBACK_FAILED" 1 'missing-listener recovery was reported successful'
ok 'active service without SSH listener: failure and file rollback'

reset_config
printf 'PasswordAuthentication yes\n' > "$SSH_DROPIN_DIR/00-before.conf"
if disable_ssh_password_auth <<< y >/dev/null 2>&1; then fail 'precedence conflict reported success'; fi
if [[ -f $SSH_DROPIN ]] || grep -q '^reload ' "$LOG"; then fail 'effective-value failure reloaded or retained file'; fi
ok 'effective-value conflict: rollback without reload'

reset_config
printf 'PubkeyAcceptedAlgorithms ecdsa-sha2-nistp256\n' >> "$SSHD_CONFIG"
if disable_ssh_password_auth <<< y >/dev/null 2>&1; then fail 'unusable algorithm reported success'; fi
if [[ -f $SSH_DROPIN ]] || grep -q '^reload ' "$LOG"; then fail 'algorithm refusal did not roll back'; fi
ok 'unusable public-key algorithm: rollback without reload'

reset_config
SSH_BACKUP=$(mktemp -d "$BACKUP_ROOT/interruption-XXXXXX")
SSH_PREVIOUS_EXISTS=0; SSH_TRANSACTION=1; SSH_RELOAD_ATTEMPTED=0
printf 'PasswordAuthentication no\n' > "$SSH_DROPIN"
rollback_ssh >/dev/null 2>&1
[[ ! -f $SSH_DROPIN ]] || fail 'pending transaction not rolled back'
ok 'pending transaction rollback (same handler used on EXIT/INT/TERM/HUP)'

# Exercise snapshot reconstruction from an actual /dev/fd process-substitution
# input. No sudo is run: root transport is tested independently of privileges.
sed '$d' "$SCRIPT_PATH" > "$TEST_ROOT/snapshot-source"
cat >> "$TEST_ROOT/snapshot-source" <<'SNAPSHOT'
DEFAULT_SSH_PUBLIC_KEYS=("ssh-ed25519 fixture")
main() {
    [[ ${DEFAULT_SSH_PUBLIC_KEYS[0]} == 'ssh-ed25519 fixture' ]] || return 1
    [[ $(type -t create_user) == function ]] || return 1
    printf 'snapshot-ok\n'
}
write_elevated_script "$1"
bash "$1"
SNAPSHOT
assert_eq "$(bash <(cat "$TEST_ROOT/snapshot-source") "$TEST_ROOT/elevated.sh")" snapshot-ok 'process-substitution snapshot'
ok 'process-substitution snapshot preserves functions and preset keys'

# Real signal/EXIT cleanup in a separate shell, without signaling this test runner.
cat > "$TEST_ROOT/signal-test" <<'SIGNAL'
set -Eeuo pipefail
source "$1"
WORK_DIR=$(mktemp -d)
SSH_DROPIN="$2/signal-dropin.conf"
SSH_TRANSACTION=1
SSH_PREVIOUS_EXISTS=0
SSH_RELOAD_ATTEMPTED=0
trap cleanup EXIT
trap 'exit 143' TERM
printf 'PasswordAuthentication no\n' > "$SSH_DROPIN"
kill -TERM $$
SIGNAL
if bash "$TEST_ROOT/signal-test" "$SCRIPT_PATH" "$TEST_ROOT" >/dev/null 2>&1; then fail 'signal returned success'; fi
[[ ! -f $TEST_ROOT/signal-dropin.conf ]] || fail 'signal did not roll back'
ok 'actual TERM invokes EXIT rollback'

(
    package_installed() { case "$1" in sudo|curl) return 0 ;; *) return 1 ;; esac; }
    configure_timezone() { printf 'timezone UTC\n' >> "$LOG"; }
    : > "$LOG"
    basic_init <<< $'y\nn' >/dev/null
    grep -qx 'apt-get update' "$LOG" || fail 'base init missing update'
    grep -qx 'apt-get install -y ca-certificates git vim htop unzip' "$LOG" || fail 'base init package list'
    if grep -q 'full-upgrade' "$LOG"; then fail 'declined upgrade executed'; fi
    : > "$LOG"
    basic_init <<< $'y\n' >/dev/null
    grep -qx 'apt-get full-upgrade -y' "$LOG" || fail 'default upgrade not executed'
    : > "$LOG"
    basic_init <<< n >/dev/null
    [[ ! -s $LOG ]] || fail 'cancelled base init executed'
)
ok 'base init: missing packages only, optional/default upgrade, cancel'
printf '\nAll isolated tests passed. No daemon was started or host configuration modified.\n'
TEST_COMPLETED=1
