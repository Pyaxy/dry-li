#!/usr/bin/env bash
# Repeatable Debian/Ubuntu administration menu. No changes until an action is selected.
set -Eeuo pipefail

# Configuration: put one complete public key on each line. Never put private keys here.
DEFAULT_SSH_PUBLIC_KEYS=(
    # "ssh-ed25519 AAAA... user@example"
)
VERSION="1.1.0"
BASIC_PACKAGES=(sudo curl ca-certificates git vim htop unzip)
SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_DROPIN="/etc/ssh/sshd_config.d/00-key-only.conf"
SSH_ENV_FILES=(/etc/default/ssh /etc/sysconfig/sshd)
BACKUP_ROOT="/var/backups/linux-init"
SSH_CONTEXT=${SSH_CONNECTION:-}
WORK_DIR=""
SSH_BACKUP=""
SSH_CANDIDATE=""
SSH_TRANSACTION=0
SSH_PREVIOUS_EXISTS=0
SSH_RELOAD_ATTEMPTED=0
SSH_ROLLBACK_FAILED=0
SSH_SERVICE=""
SSH_SOCKET=""
SSH_RUNTIME_DIR="/run/sshd"
SSH_MIGRATION_NEEDED=0
SSH_MODE_CHANGED=0
SSH_RUNTIME_STATE=""
SSH_ORIGINAL_SERVICE_ACTIVE=""
SSH_ORIGINAL_SERVICE_ENABLED=""
SSH_ORIGINAL_SOCKET_ACTIVE=""
SSH_ORIGINAL_SOCKET_ENABLED=""
SSHD=""
OS_NAME="unknown"
UID_MIN=1000
UID_MAX=60000
COLOR=""
RESET=""

say() { printf '%s\n' "$*"; }
warn() { printf '提示: %s\n' "$*" >&2; }
ask() { read -r -p "$1" "$2"; }
confirm() {
    local answer
    ask "$1" answer || return 1
    case "${answer:-$2}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
pause() { local answer; ask '按回车返回菜单…' answer || true; }

write_elevated_script() {
    # Serialize the already parsed program, not the original stdin or /dev/fd pipe.
    # This also preserves locally edited preset keys with bash <(curl ...).
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        declare -p DEFAULT_SSH_PUBLIC_KEYS VERSION BASIC_PACKAGES SSHD_CONFIG SSH_DROPIN_DIR SSH_DROPIN SSH_ENV_FILES BACKUP_ROOT SSH_CONTEXT
        declare -p WORK_DIR SSH_BACKUP SSH_CANDIDATE SSH_TRANSACTION SSH_PREVIOUS_EXISTS SSH_RELOAD_ATTEMPTED SSH_ROLLBACK_FAILED SSH_SERVICE SSHD OS_NAME UID_MIN UID_MAX COLOR RESET
        declare -p SSH_SOCKET SSH_RUNTIME_DIR SSH_MIGRATION_NEEDED SSH_MODE_CHANGED SSH_RUNTIME_STATE SSH_ORIGINAL_SERVICE_ACTIVE SSH_ORIGINAL_SERVICE_ENABLED SSH_ORIGINAL_SOCKET_ACTIVE SSH_ORIGINAL_SOCKET_ENABLED
        declare -f
        printf '\nmain "$@"\n'
    } > "$1"
}
require_root() {
    (( EUID == 0 )) && return 0
    command -v sudo >/dev/null 2>&1 || { warn '需要 root；当前系统没有 sudo。请以 root 运行。'; return 1; }
    local staging status=0
    staging=$(mktemp -d) || return 1
    chmod 700 "$staging" || { rm -rf -- "$staging"; return 1; }
    if ! write_elevated_script "$staging/init.sh"; then rm -rf -- "$staging"; return 1; fi
    say '正在通过 sudo 获取管理权限…'
    sudo /bin/bash "$staging/init.sh" || status=$?
    rm -rf -- "$staging"
    exit "$status"
}

detect_os() {
    [[ -r /etc/os-release ]] || { warn '无法读取 /etc/os-release。'; return 1; }
    local ID='' VERSION_ID='' PRETTY_NAME=''
    # Trusted operating-system metadata.
    # shellcheck source=/dev/null
    . /etc/os-release
    case "$ID:$VERSION_ID" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
        *) warn "仅支持 Debian 12/13、Ubuntu 22.04/24.04/26.04（当前 $ID ${VERSION_ID}）。"; return 1 ;;
    esac
    case "$(uname -m)" in x86_64|aarch64|amd64|arm64) ;; *) warn '仅支持 amd64 / arm64。'; return 1 ;; esac
    command -v apt-get >/dev/null 2>&1 || return 1
    OS_NAME=${PRETTY_NAME:-$ID $VERSION_ID}
    UID_MIN=$(awk '$1 == "UID_MIN" {print $2; exit}' /etc/login.defs)
    UID_MAX=$(awk '$1 == "UID_MAX" {print $2; exit}' /etc/login.defs)
    UID_MIN=${UID_MIN:-1000}; UID_MAX=${UID_MAX:-60000}
    [[ $UID_MIN =~ ^[0-9]+$ && $UID_MAX =~ ^[0-9]+$ ]] || return 1
    if [[ -x /usr/sbin/sshd ]]; then SSHD=/usr/sbin/sshd; else SSHD=$(command -v sshd || true); fi
}

user_exists() { getent passwd "$1" >/dev/null; }
user_home() { getent passwd "$1" | cut -d: -f6; }
user_has_sudo() { id -nG "$1" | tr ' ' '\n' | grep -x sudo >/dev/null; }
sudo_label() { if user_has_sudo "$1"; then printf yes; else printf no; fi; }
list_login_users() {
    local name _password uid _gid _gecos home shell
    while IFS=: read -r name _password uid _gid _gecos home shell; do
        [[ $uid =~ ^[0-9]+$ ]] || continue
        (( uid >= UID_MIN && uid <= UID_MAX )) || continue
        [[ $name != root && $home == /* && -x $shell ]] || continue
        case "$shell" in */nologin|*/false|*/sync|*/shutdown|*/halt) continue ;; esac
        grep -Fxq -- "$shell" /etc/shells || continue
        printf '%s\n' "$name"
    done < <(getent passwd)
}

# Extract identity even from existing authorized_keys lines with quoted options.
key_identity() {
    printf '%s\n' "$1" | awk '{for (i=1;i<NF;i++) if ($i ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/) {print $i " " $(i+1); exit}}'
}
valid_public_key() {
    local line=$1 identity
    [[ $line != *$'\n'* && $line != *$'\r'* ]] || return 1
    identity=$(key_identity "$line")
    [[ -n $identity ]] || return 1
    # Decode and verify the actual key blob, rather than accepting a prefix alone.
    printf '%s\n' "$line" > "$WORK_DIR/key-check" || return 1
    ssh-keygen -lf "$WORK_DIR/key-check" >/dev/null 2>&1
}
plain_public_key() {
    local type blob rest
    read -r type blob rest <<< "$1"
    [[ "$type $blob" == "$(key_identity "$1")" ]] && valid_public_key "$1"
}
key_allowed_by_sshd() {
    local line=$1 config=$2 type _blob _comment algorithms bits minimum
    plain_public_key "$line" || return 1
    read -r type _blob _comment <<< "$line"
    algorithms=",$(config_value "$config" pubkeyacceptedalgorithms),"
    if [[ $type == ssh-rsa ]]; then
        case "$algorithms" in *,rsa-sha2-512,*|*,rsa-sha2-256,*|*,ssh-rsa,*) ;; *) return 1 ;; esac
        bits=$(ssh-keygen -lf "$WORK_DIR/key-check" | awk '{print $1; exit}') || return 1
        minimum=$(config_value "$config" requiredrsasize); minimum=${minimum:-1024}
        [[ $bits =~ ^[0-9]+$ && $minimum =~ ^[0-9]+$ ]] && (( bits >= minimum ))
    else
        [[ $algorithms == *",$type,"* ]]
    fi
}
count_authorized_keys() {
    local home file line count=0
    home=$(user_home "$1"); file="$home/.ssh/authorized_keys"
    if [[ -f $file && -r $file ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            [[ ! $line =~ ^[[:space:]]*(#|$) ]] || continue
            if valid_public_key "$line"; then count=$((count + 1)); fi
        done < "$file"
    fi
    printf '%s\n' "$count"
}

# Conservative StrictModes check, including every ancestor and symlinks.
safe_key_path() {
    local path=$1 uid=$2 metadata owner mode
    while [[ $path != / ]]; do
        [[ -e $path && ! -L $path ]] || return 1
        metadata=$(stat -c '%u %a' -- "$path") || return 1
        read -r owner mode <<< "$metadata"
        [[ $owner == 0 || $owner == "$uid" ]] || return 1
        (( (8#$mode & 8#022) == 0 )) || return 1
        path=$(dirname -- "$path")
    done
}
account_password_ready() {
    local _name hash last _min max _warning _inactive expire today
    IFS=: read -r _name hash last _min max _warning _inactive expire < <(getent shadow "$1") || return 1
    case "$hash" in ''|'!'*|'*'*) return 1 ;; esac
    today=$(( $(date +%s) / 86400 ))
    [[ -z $expire ]] || { [[ $expire =~ ^[0-9]+$ ]] && (( expire > today )); } || return 1
    [[ $last =~ ^[0-9]+$ ]] && (( last > 0 )) || return 1
    if [[ -n $max && $max != -1 ]]; then
        [[ $max =~ ^[0-9]+$ ]] && (( last + max > today )) || return 1
    fi
}
admin_ready() {
    local user=$1 home line
    user_has_sudo "$user" && account_password_ready "$user" || return 1
    command -v sudo >/dev/null && command -v visudo >/dev/null || return 1
    LC_ALL=C visudo -c >/dev/null 2>&1 || return 1
    LC_ALL=C sudo -l -U "$user" 2>/dev/null | grep -E '\(ALL( : ALL)?\) ALL[[:space:]]*$' >/dev/null || return 1
    home=$(user_home "$user")
    safe_key_path "$home/.ssh/authorized_keys" "$(id -u "$user")" || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        # Restricted/certificate/from=/command= entries are counted in status,
        # but are not proof of a general administrator login.
        if plain_public_key "$line"; then return 0; fi
    done < "$home/.ssh/authorized_keys"
    return 1
}
check_ssh_hardening_readiness() {
    local user
    READY_USERS=()
    while IFS= read -r user; do
        if admin_ready "$user"; then READY_USERS+=("$user"); fi
    done < <(list_login_users)
    (( ${#READY_USERS[@]} > 0 ))
}

package_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == 'install ok installed' ]]; }
install_packages() {
    local package missing=()
    for package in "$@"; do
        if ! package_installed "$package"; then missing+=("$package"); fi
    done
    if (( ${#missing[@]} )); then
        apt-get update && apt-get install -y "${missing[@]}" || return 1
    fi
}
grant_sudo() {
    local user=$1
    if user_has_sudo "$user"; then say "$user 已属于 sudo 组。"; return 0; fi
    install_packages sudo || return 1
    getent group sudo >/dev/null || { warn '缺少 sudo 组，请检查 sudo 安装。'; return 1; }
    usermod -aG sudo "$user" || return 1
    say "$user 已加入 sudo 组；新登录后生效，sudo 使用该用户的 Linux 密码。"
}
show_user() {
    local user=$1
    say "User: $user"
    say "Home: $(user_home "$user")"
    say "Shell: $(getent passwd "$user" | cut -d: -f7)"
    say "Sudo: $(sudo_label "$user")"
    say "SSH keys: $(count_authorized_keys "$user")"
}
create_user() {
    local user choice
    ask '请输入用户名 [ppy]: ' user || return 0
    user=${user:-ppy}
    [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { warn '用户名须以小写字母/下划线开头，最多 32 位，只含小写字母、数字、_、-。'; return 0; }
    if user_exists "$user"; then
        say "User $user already exists."
        show_user "$user"
        if ! list_login_users | grep -Fx -- "$user" >/dev/null; then
            warn '这是 root 或系统/不可登录用户，不提供 sudo 管理。'; return 0
        fi
        say '1) 授予 sudo 权限'; say '2) 不修改'; say '0) 返回'
        ask '请选择: ' choice || return 0
        [[ $choice != 1 ]] || grant_sudo "$user"
        return 0
    fi
    [[ ! -e /home/$user && ! -L /home/$user ]] || { warn '同名 home 路径已存在，拒绝使用。'; return 0; }
    install_packages sudo || return 1
    useradd -m -d "/home/$user" -s /bin/bash "$user" || return 1
    say '请设置用户的 Linux 密码（供 sudo / Console 使用）：'
    if ! passwd "$user"; then
        warn "密码未设置成功；用户已保留，请用 passwd $user 重试。SSH 加固会拒绝这个账号。"
        show_user "$user"; return 0
    fi
    if confirm '是否授予该用户 sudo 权限？ [Y/n] ' y; then grant_sudo "$user" || return 1; fi
    say "User $user created successfully."
    show_user "$user"
}

select_key_user() {
    local user choice i=1 users=()
    while IFS= read -r user; do users+=("$user"); done < <(list_login_users)
    if (( ${#users[@]} == 0 )); then
        warn '没有普通登录用户，请先创建用户。'; return 1
    fi
    if confirm '显示 root 用户？ [y/N] ' n; then users+=(root); fi
    say '请选择要授权 SSH Key 的用户：'
    for user in "${users[@]}"; do say "$i) $user"; i=$((i + 1)); done
    say '0) 返回'
    ask '请选择: ' choice || return 1
    [[ $choice =~ ^[0-9]{1,4}$ ]] || return 1
    choice=$((10#$choice))
    (( choice >= 1 && choice <= ${#users[@]} )) || return 1
    SELECTED_USER=${users[$((choice - 1))]}
}
append_keys() {
    local user=$1 home sshdir file line key identity existing found lastbyte
    shift
    home=$(user_home "$user"); sshdir="$home/.ssh"; file="$sshdir/authorized_keys"
    [[ -d $home && ! -L $home && ! -L $sshdir && ! -L $file ]] || { warn 'home/key 路径缺失或包含符号链接，拒绝写入。'; return 1; }
    [[ ! -e $sshdir || -d $sshdir ]] && [[ ! -e $file || -f $file ]] || return 1
    [[ ! -f $file || $(stat -c %h "$file") == 1 ]] || { warn 'authorized_keys 存在硬链接，拒绝写入。'; return 1; }
    # Validate the entire batch before touching the destination.
    for key in "$@"; do plain_public_key "$key" || { warn '无效的 SSH 公钥；未写入任何 key。'; return 1; }; done
    mkdir -p -- "$sshdir" || return 1
    touch -- "$file" || return 1
    chmod 700 "$sshdir" && chmod 600 "$file" || return 1
    chown "$(id -u "$user"):$(id -g "$user")" "$sshdir" "$file" || return 1
    for key in "$@"; do
        identity=$(key_identity "$key"); found=0
        while IFS= read -r line || [[ -n $line ]]; do
            [[ ! $line =~ ^[[:space:]]*(#|$) ]] || continue
            existing=$(key_identity "$line")
            if [[ $identity == "$existing" ]]; then found=1; break; fi
        done < "$file"
        if (( ! found )); then
            # Preserve an existing final line without a newline.
            if [[ -s $file ]]; then
                lastbyte=$(tail -c 1 -- "$file" | od -An -tu1 | tr -d ' \n')
                [[ $lastbyte == 10 ]] || printf '\n' >> "$file" || return 1
            fi
            printf '%s\n' "$key" >> "$file" || return 1
        fi
    done
}
authorize_ssh_key() {
    local choice key
    command -v ssh-keygen >/dev/null || { warn '需要 ssh-keygen（openssh-client）；请先安装。'; return 0; }
    select_key_user || return 0
    say '1) 使用脚本预置 SSH Key'; say '2) 手动粘贴 SSH Public Key'; say '0) 返回'
    ask '请选择: ' choice || return 0
    case "$choice" in
        1) (( ${#DEFAULT_SSH_PUBLIC_KEYS[@]} )) || { warn '尚未填写 DEFAULT_SSH_PUBLIC_KEYS。'; return 0; }
           append_keys "$SELECTED_USER" "${DEFAULT_SSH_PUBLIC_KEYS[@]}" || return 1 ;;
        2) ask '请粘贴一整行 SSH public key: ' key || return 0
           append_keys "$SELECTED_USER" "$key" || return 1 ;;
        *) return 0 ;;
    esac
    say "SSH Key authorization completed for $SELECTED_USER."
    say "Authorized keys: $(count_authorized_keys "$SELECTED_USER")"
    say "Sudo: $(sudo_label "$SELECTED_USER")"
}

get_effective_sshd_config() {
    [[ -n $SSHD ]] || { warn '未安装 openssh-server，SSH 状态未知。'; return 1; }
    "$SSHD" -T -f "$SSHD_CONFIG" "$@"
}
config_value() { printf '%s\n' "$1" | awk -v key="$2" '$1 == key {$1=""; sub(/^ /, ""); print; exit}'; }
show_ssh_values() {
    local config=$1 key label
    for key in pubkeyauthentication passwordauthentication kbdinteractiveauthentication permitrootlogin; do
        case "$key" in
            pubkeyauthentication) label=PubkeyAuthentication ;;
            passwordauthentication) label=PasswordAuthentication ;;
            kbdinteractiveauthentication) label=KbdInteractiveAuthentication ;;
            permitrootlogin) label=PermitRootLogin ;;
        esac
        say "$label: $(config_value "$config" "$key")"
    done
}
key_only_values() {
    local config=$1 key expected actual failed=0
    for key in pubkeyauthentication passwordauthentication kbdinteractiveauthentication permitrootlogin; do
        expected=no; [[ $key != pubkeyauthentication ]] || expected=yes
        actual=$(config_value "$config" "$key")
        if [[ $actual != "$expected" ]]; then warn "$key 未生效：${actual:-unknown}，预期 $expected"; failed=1; fi
    done
    (( failed == 0 ))
}

# Only the standard, globally included Debian/Ubuntu layout can be modified.
# Complex access policies need an operator audit, not an optimistic -T check.
check_supported_ssh_layout() {
    local file config
    [[ -f $SSHD_CONFIG && ! -L $SSHD_CONFIG ]] || return 1
    [[ -d $SSH_DROPIN_DIR && ! -L $SSH_DROPIN_DIR ]] || return 1
    if ! awk -v include="$SSH_DROPIN_DIR/*.conf" '
        /^[[:space:]]*(#|$)/ {next}
        {ok=(tolower($1)=="include" && $2==include && NF==2); exit}
        END {exit !ok}
    ' "$SSHD_CONFIG"; then
        warn '主配置的首条指令不是标准 drop-in Include；请人工确认优先级，脚本不修改主配置。'; return 1
    fi
    for file in "$SSHD_CONFIG" "$SSH_DROPIN_DIR"/*.conf; do
        [[ -e $file ]] || continue
        [[ -f $file && ! -L $file ]] || { warn "不支持的配置路径: $file"; return 1; }
        if awk -v main="$SSHD_CONFIG" -v include="$SSH_DROPIN_DIR/*.conf" '
            /^[[:space:]]*(#|$)/ {next}
            {k=tolower($1); if(k=="match" || k=="allowusers" || k=="denyusers" || k=="allowgroups" || k=="denygroups" || (k=="include" && (FILENAME!=main || $2!=include || NF!=2))) found=1}
            END {exit !found}
        ' "$file"; then
            warn "需人工审查访问限制 / Match / 嵌套 Include: $file"; return 1
        fi
    done
    config=$(get_effective_sshd_config) || return 1
    [[ $(config_value "$config" authenticationmethods) == any || $(config_value "$config" authenticationmethods) == publickey ]] || { warn 'AuthenticationMethods 要求额外认证，拒绝加固。'; return 1; }
    case " $(config_value "$config" authorizedkeysfile) " in
        *' .ssh/authorized_keys '*) ;;
        *) warn 'sshd 未使用标准 authorized_keys 路径。'; return 1 ;;
    esac
    [[ $(config_value "$config" chrootdirectory) == none && $(config_value "$config" forcecommand) == none ]] || { warn '存在 ChrootDirectory / ForceCommand，拒绝加固。'; return 1; }
    case "$(config_value "$config" revokedkeys)" in
        ''|none) ;;
        *) warn '存在公钥吊销列表，需人工检查。'; return 1 ;;
    esac
    case "$(config_value "$config" pubkeyauthoptions)" in
        ''|none) ;;
        *) warn '存在额外公钥认证要求，需人工检查。'; return 1 ;;
    esac
}
# Read explicit is-active/is-enabled results: their nonzero inactive/disabled
# exit codes are expected, but transitional or unrecognized states are not.
ssh_active_state() {
    local state
    state=$(systemctl is-active "$1" 2>/dev/null) || true
    case "$state" in active|inactive|failed|unknown) printf '%s\n' "$state" ;; *) return 1 ;; esac
}
ssh_enabled_state() {
    local state
    state=$(systemctl is-enabled "$1" 2>/dev/null) || true
    case "$state" in enabled|enabled-runtime|disabled|masked|masked-runtime|static|alias|not-found) printf '%s\n' "$state" ;; *) return 1 ;; esac
}
ssh_port22_listeners() {
    local listeners
    command -v ss >/dev/null || { warn '需要 ss（iproute2）核对 22 端口。'; return 1; }
    listeners=$(ss -H -lntp) || { warn '无法查询 TCP 监听进程。'; return 1; }
    awk '$1=="LISTEN" && $4 ~ /:22$/ {print}' <<< "$listeners"
}
check_sshd_listener_ownership() {
    local pid listeners line found=0
    pid=$(systemctl show "$SSH_SERVICE" -p MainPID --value) || return 1
    [[ $pid =~ ^[1-9][0-9]{0,9}$ ]] || { warn '无法确认 SSH 主进程 PID。'; return 1; }
    listeners=$(ssh_port22_listeners) || return 1
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        [[ $line == *"pid=$pid,"* && $line == *'("sshd",'* && $line != *'pid=1,'* ]] || {
            warn '22 端口未由 SSH 主进程独立监听（可能仍由 socket / 其他进程持有）。'; return 1;
        }
        found=1
    done <<< "$listeners"
    (( found )) || { warn '22 端口没有可确认的 sshd LISTEN。'; return 1; }
}
check_ssh_stop_policy() {
    local property value argv
    [[ $(systemctl show "$SSH_SERVICE" -p KillMode --value) == process ]] || {
        warn 'SSH KillMode 不是 process，停止服务可能断开当前会话；拒绝迁移。'; return 1;
    }
    [[ $(systemctl show "$SSH_SERVICE" -p SendSIGHUP --value) == no ]] || { warn 'SSH SendSIGHUP 不是 no，停止可能向已有会话发送 HUP。'; return 1; }
    value=$(systemctl show "$SSH_SERVICE" -p KillSignal --value) || return 1
    case "$value" in 15|SIGTERM) ;; *) warn 'SSH 停止信号不是 SIGTERM，拒绝迁移。'; return 1 ;; esac
    for property in ExecStop ExecStopPost; do
        value=$(systemctl show "$SSH_SERVICE" -p "$property" --value) || return 1
        [[ -z $value ]] || { warn "SSH 存在自定义 ${property}，不能保证保留会话。"; return 1; }
    done
    value=$(systemctl show "$SSH_SERVICE" -p ExecStartPre --value) || return 1
    argv=${value#*argv[]=}; argv=${argv%% ;*}
    case "$argv" in ''|'/usr/sbin/sshd -t') ;; *) warn 'SSH 存在非标准 ExecStartPre，拒绝自动启动。'; return 1 ;; esac
    [[ -z $(systemctl show "$SSH_SERVICE" -p ExecStartPost --value) ]] || { warn 'SSH 存在自定义 ExecStartPost，拒绝自动启动。'; return 1; }
}
check_ssh_reload_mode() {
    local triggers sockets unit property dependencies service_active service_enabled socket_active=unknown socket_enabled=not-found config listen mapping line
    SSH_MIGRATION_NEEDED=0
    SSH_SOCKET=''
    triggers=$(systemctl show "$SSH_SERVICE" -p TriggeredBy --value) || return 1
    sockets=$(systemctl show "$SSH_SERVICE" -p Sockets --value) || return 1
    [[ -z $sockets ]] || { warn "SSH 服务有显式 Sockets=${sockets}，需人工审查。"; return 1; }
    for unit in $triggers; do
        case "$unit" in ssh.socket|sshd.socket) ;; *) warn "未知 SSH 触发单元: $unit"; return 1 ;; esac
    done
    # ssh.socket and sshd.socket may be aliases: retain the canonical unit ID.
    for unit in ssh.socket sshd.socket; do
        [[ $(systemctl show "$unit" -p LoadState --value) == loaded ]] || continue
        mapping=$(systemctl show "$unit" -p Id --value) || return 1
        [[ $mapping == ssh.socket || $mapping == sshd.socket ]] || return 1
        [[ -z $SSH_SOCKET || $SSH_SOCKET == "$mapping" ]] || { warn '检测到多个 SSH socket，需人工审查。'; return 1; }
        SSH_SOCKET=$mapping
    done
    service_active=$(ssh_active_state "$SSH_SERVICE") || return 1
    service_enabled=$(ssh_enabled_state "$SSH_SERVICE") || return 1
    if [[ -n $SSH_SOCKET ]]; then
        socket_active=$(ssh_active_state "$SSH_SOCKET") || { warn 'SSH socket 状态不稳定。'; return 1; }
        socket_enabled=$(ssh_enabled_state "$SSH_SOCKET") || return 1
        case "$socket_enabled" in enabled|enabled-runtime) SSH_MIGRATION_NEEDED=1 ;; esac
        [[ $socket_active != active ]] || SSH_MIGRATION_NEEDED=1
    fi
    SSH_RUNTIME_STATE="$SSH_SERVICE:$service_active:$service_enabled:$SSH_SOCKET:$socket_active:$socket_enabled"
    if (( SSH_MIGRATION_NEEDED )); then
        check_ssh_stop_policy || return 1
        case "$service_enabled" in enabled|enabled-runtime|disabled) ;; *) warn 'SSH 服务开机状态不能安全恢复，拒绝迁移。'; return 1 ;; esac
        case "$socket_enabled" in enabled|enabled-runtime|disabled) ;; *) warn 'SSH socket 开机状态不能安全恢复，拒绝迁移。'; return 1 ;; esac
        # Starting a service with explicit socket dependencies could reactivate it.
        for property in Requires Wants BindsTo; do
            dependencies=$(systemctl show "$SSH_SERVICE" -p "$property" --value) || return 1
            [[ $dependencies != *'.socket'* ]] || { warn "SSH $property 包含 socket 依赖，拒绝迁移。"; return 1; }
        done
        [[ $(systemctl show "$SSH_SOCKET" -p Accept --value) == no ]] || { warn '仅支持 Accept=no 的标准 SSH socket。'; return 1; }
        mapping=$(systemctl show "$SSH_SOCKET" -p Triggers --value) || return 1
        [[ $mapping == "$SSH_SERVICE" ]] || { warn 'SSH socket 的 Service 映射非标准，拒绝迁移。'; return 1; }
        for property in ExecStartPre ExecStartPost ExecStopPre ExecStopPost; do
            [[ -z $(systemctl show "$SSH_SOCKET" -p "$property" --value) ]] || { warn "SSH socket 存在 $property 钩子，拒绝迁移。"; return 1; }
        done
        listen=$(systemctl show "$SSH_SOCKET" -p Listen --value) || return 1
        case "$listen" in '[::]:22 (Stream)'|'0.0.0.0:22 (Stream)'|'[::]:22 (Stream) 0.0.0.0:22 (Stream)'|'0.0.0.0:22 (Stream) [::]:22 (Stream)') ;;
            *) warn "SSH socket 不是标准 22 端口全地址监听: $listen"; return 1 ;;
        esac
        config=$(get_effective_sshd_config) || return 1
        [[ $(awk '$1=="port" {print $2}' <<< "$config") == 22 && $(config_value "$config" addressfamily) == any ]] || {
            warn 'sshd 端口 / 地址族与标准 socket 不匹配，拒绝迁移。'; return 1;
        }
        listen=$(awk '$1=="listenaddress" {print $2}' <<< "$config")
        [[ $listen == $'[::]:22\n0.0.0.0:22' || $listen == $'0.0.0.0:22\n[::]:22' ]] || {
            warn 'sshd ListenAddress 非标准全地址监听，拒绝迁移。'; return 1;
        }
        [[ $service_active == active || $socket_active == active ]] || { warn 'SSH 服务和 socket 均未运行。'; return 1; }
        if [[ $socket_active == active ]]; then
            listen=$(ssh_port22_listeners) || return 1
            [[ -n $listen ]] || { warn '迁移前 22 端口没有 LISTEN。'; return 1; }
            while IFS= read -r line; do
                [[ $line == *'pid=1,'* ]] || { warn '活动 SSH socket 没有持有 22 端口，拒绝迁移。'; return 1; }
            done <<< "$listen"
        else
            check_sshd_listener_ownership || return 1
        fi
    else
        [[ $service_active == active ]] || { warn 'SSH 服务未运行。'; return 1; }
        [[ $(systemctl show "$SSH_SERVICE" -p CanReload --value) == yes ]] || { warn 'SSH 服务不支持 reload。'; return 1; }
        check_sshd_listener_ownership || return 1
    fi
}
find_ssh_service() {
    local service start argv environment file token allowed environment_files tokens=()
    command -v systemctl >/dev/null || { warn '无 systemd，SSH 加固仅支持可确认的 systemd reload。'; return 1; }
    SSH_SERVICE=''
    for service in ssh.service sshd.service; do
        if [[ $(systemctl show "$service" -p LoadState --value) == loaded ]]; then
            SSH_SERVICE=$(systemctl show "$service" -p Id --value) || return 1
            break
        fi
    done
    [[ -n $SSH_SERVICE ]] || { warn '没有已加载的 ssh.service / sshd.service。'; return 1; }
    case "$SSH_SERVICE" in ssh.service|sshd.service) ;; *) warn 'SSH 服务 Id 非标准。'; return 1 ;; esac
    start=$(systemctl show "$SSH_SERVICE" -p ExecStart --value) || return 1
    argv=${start#*argv[]=}; argv=${argv%% ;*}
    # systemd expands this literal variable at service start; do not expand it here.
    # shellcheck disable=SC2016
    case "$argv" in
        '/usr/sbin/sshd -D'|'/usr/sbin/sshd -D $SSHD_OPTS') ;;
        *) warn "SSH 服务启动参数非标准，无法证明 -T 对应实际服务: $start"; return 1 ;;
    esac
    environment=$(systemctl show "$SSH_SERVICE" -p Environment --value) || return 1
    [[ -z $environment ]] || { warn 'SSH 服务有自定义 Environment，需人工审查。'; return 1; }
    environment_files=$(systemctl show "$SSH_SERVICE" -p EnvironmentFiles --value) || return 1
    if [[ -n $environment_files ]]; then
        read -r -a tokens <<< "$environment_files"
        for token in "${tokens[@]}"; do
            case "$token" in '(ignore_errors=yes)'|'(ignore_errors=no)') continue ;; esac
            allowed=0
            for file in "${SSH_ENV_FILES[@]}"; do
                if [[ $token == "$file" ]]; then allowed=1; break; fi
            done
            (( allowed )) || { warn "SSH 服务使用自定义环境文件，需人工审查: $token"; return 1; }
        done
    fi
    # Never source a service environment file. Accept only empty SSHD_OPTS.
    for file in "${SSH_ENV_FILES[@]}"; do
        [[ -f $file ]] || continue
        if ! awk '/^[[:space:]]*(#|$)/ {next} /^[[:space:]]*SSHD_OPTS[[:space:]]*=[[:space:]]*(""|'"''"')?[[:space:]]*(#.*)?$/ {next} {exit 1}' "$file"; then
            warn "SSH 环境文件不是空 SSHD_OPTS 配置，需人工审查: $file"; return 1
        fi
    done
    check_ssh_reload_mode
}
report_ssh_conflicts() {
    warn '可能冲突的文件/指令（未 reload）：'
    grep -nEi '^[[:space:]]*(Include|Match|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin)' "$SSHD_CONFIG" "$SSH_DROPIN_DIR"/*.conf >&2 || true
}
ssh_service_step() {
    local label=$1
    shift
    "$@" || { warn "SSH 服务操作失败: ${label}；这是服务/监听应用失败，不代表 sshd_config 语法错误。"; return 1; }
}
check_ssh_service_health() {
    local _attempt state
    # ExecReload/start can return before a subsequent daemon failure.
    for _attempt in 1 2 3; do
        sleep 1
        systemctl is-active --quiet "$SSH_SERVICE" || { warn "$SSH_SERVICE 未保持 active。"; return 1; }
        if (( SSH_MODE_CHANGED )); then
            [[ $(ssh_enabled_state "$SSH_SERVICE") == enabled ]] || { warn 'SSH 服务未永久启用。'; return 1; }
        fi
        if [[ -n $SSH_SOCKET ]]; then
            state=$(ssh_active_state "$SSH_SOCKET") || return 1
            [[ $state == inactive || $state == failed ]] || { warn 'SSH socket 仍在运行。'; return 1; }
            state=$(ssh_enabled_state "$SSH_SOCKET") || return 1
            case "$state" in disabled|masked|masked-runtime) ;; *) warn 'SSH socket 仍启用。'; return 1 ;; esac
        fi
        check_sshd_listener_ownership || return 1
    done
}
apply_ssh_configuration() {
    # The candidate has already passed -t/-T/-C. Never HUP a socket listener.
    SSH_RELOAD_ATTEMPTED=1
    if (( SSH_MIGRATION_NEEDED )); then
        SSH_MODE_CHANGED=1 # Set BEFORE the first potentially partial mutation.
        ssh_service_step "停止 $SSH_SOCKET" systemctl stop "$SSH_SOCKET" || return 1
        ssh_service_step "禁用 $SSH_SOCKET" systemctl disable "$SSH_SOCKET" || return 1
        if [[ $SSH_ORIGINAL_SOCKET_ENABLED == enabled-runtime ]]; then
            ssh_service_step "禁用临时 $SSH_SOCKET" systemctl disable --runtime "$SSH_SOCKET" || return 1
        fi
        # start on an already active service is a no-op. With KillMode=process,
        # stopping only the listener preserves established sshd session children.
        ssh_service_step "停止 $SSH_SERVICE 监听主进程" systemctl stop "$SSH_SERVICE" || return 1
        ssh_service_step "清除 $SSH_SERVICE 失败状态" systemctl reset-failed "$SSH_SERVICE" || return 1
        ssh_service_step "启用 $SSH_SERVICE" systemctl enable "$SSH_SERVICE" || return 1
        ssh_service_step "启动 $SSH_SERVICE" systemctl start "$SSH_SERVICE" || return 1
    else
        ssh_service_step "reload $SSH_SERVICE" systemctl reload "$SSH_SERVICE" || return 1
    fi
    check_ssh_service_health
}
restore_ssh_enabled_state() {
    local unit=$1 state=$2
    systemctl disable "$unit" || return 1
    systemctl disable --runtime "$unit" || return 1
    case "$state" in
        enabled) systemctl enable "$unit" ;;
        enabled-runtime) systemctl enable --runtime "$unit" ;;
        disabled) return 0 ;;
        *) return 1 ;;
    esac
}
prepare_ssh_runtime_dir() {
    # A failed/stopped unit can have removed RuntimeDirectory before rollback -t.
    # This is recovery only: the original -t gate is NEVER bypassed.
    [[ ! -L $SSH_RUNTIME_DIR ]] || return 1
    [[ -d $SSH_RUNTIME_DIR ]] || install -d -o root -g root -m 0755 "$SSH_RUNTIME_DIR"
}
restore_ssh_runtime() {
    local failed=0 listeners _attempt unit state
    if (( SSH_MODE_CHANGED )); then
        # Revalidate the stop policy rather than risking killing session children.
        check_ssh_stop_policy || return 1
        systemctl stop "$SSH_SOCKET" || return 1
        systemctl stop "$SSH_SERVICE" || return 1
        prepare_ssh_runtime_dir && "$SSHD" -t -f "$SSHD_CONFIG" || return 1
        restore_ssh_enabled_state "$SSH_SOCKET" "$SSH_ORIGINAL_SOCKET_ENABLED" || failed=1
        restore_ssh_enabled_state "$SSH_SERVICE" "$SSH_ORIGINAL_SERVICE_ENABLED" || failed=1
        systemctl reset-failed "$SSH_SERVICE" || failed=1
        if [[ $SSH_ORIGINAL_SOCKET_ACTIVE == active ]]; then
            systemctl start "$SSH_SOCKET" || failed=1
        fi
        if [[ $SSH_ORIGINAL_SERVICE_ACTIVE == active ]]; then
            systemctl start "$SSH_SERVICE" || failed=1
        fi
        [[ $(ssh_enabled_state "$SSH_SOCKET") == "$SSH_ORIGINAL_SOCKET_ENABLED" ]] || failed=1
        [[ $(ssh_enabled_state "$SSH_SERVICE") == "$SSH_ORIGINAL_SERVICE_ENABLED" ]] || failed=1
        for _attempt in 1 2 3; do
            sleep 1
            if [[ $SSH_ORIGINAL_SERVICE_ACTIVE == active ]]; then
                systemctl is-active --quiet "$SSH_SERVICE" || failed=1
            fi
            if [[ $SSH_ORIGINAL_SOCKET_ACTIVE == active ]]; then
                systemctl is-active --quiet "$SSH_SOCKET" || failed=1
                listeners=$(ssh_port22_listeners) || return 1
                [[ -n $listeners && $listeners == *'pid=1,'* ]] || failed=1
            else
                [[ $(ssh_active_state "$SSH_SOCKET") != active ]] || failed=1
                check_sshd_listener_ownership || failed=1
            fi
        done
        (( failed == 0 ))
    else
        # If SIGHUP made the listener exit, reload cannot recover it. A fresh
        # start recreates systemd RuntimeDirectory and preserves session children.
        prepare_ssh_runtime_dir && "$SSHD" -t -f "$SSHD_CONFIG" || return 1
        # A socket may have been enabled by another operator while applying.
        # Recovery must not repeat the very socket/SIGHUP failure we avoid.
        for unit in ssh.socket sshd.socket; do
            [[ $(systemctl show "$unit" -p LoadState --value) == loaded ]] || continue
            state=$(ssh_active_state "$unit") || return 1
            [[ $state == inactive || $state == failed ]] || { warn '恢复时发现 SSH socket 已启动，拒绝发送 HUP。'; return 1; }
        done
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            check_sshd_listener_ownership || return 1
            systemctl reload "$SSH_SERVICE" || return 1
        else
            check_ssh_stop_policy || return 1
            systemctl reset-failed "$SSH_SERVICE" && systemctl start "$SSH_SERVICE" || return 1
        fi
        check_ssh_service_health
    fi
}
rollback_ssh() {
    # Failure is terminal for this transaction. main/EXIT must not retry it.
    (( SSH_ROLLBACK_FAILED == 0 )) || return 1
    (( SSH_TRANSACTION )) || return 0
    local restore
    SSH_ROLLBACK_FAILED=1
    if (( SSH_PREVIOUS_EXISTS )); then
        restore=$(mktemp "${SSH_DROPIN}.restore.XXXXXX") || { warn "无法创建恢复文件，保留当前会话，备份: $SSH_BACKUP"; return 1; }
        if ! { cp -p -- "$SSH_BACKUP/00-key-only.conf" "$restore" && mv -f -- "$restore" "$SSH_DROPIN"; }; then
            rm -f -- "$restore"
            warn "SSH drop-in 恢复失败，保留当前会话，备份: $SSH_BACKUP"; return 1
        fi
    else
        rm -f -- "$SSH_DROPIN" || { warn "SSH drop-in 恢复失败，备份: $SSH_BACKUP"; return 1; }
    fi
    SSH_TRANSACTION=0
    warn '已恢复 SSH drop-in。'
    if (( SSH_RELOAD_ATTEMPTED )); then
        if restore_ssh_runtime; then
            warn '已恢复原 SSH 启动模式和 22 端口监听；请另开终端验证登录。'
        else
            warn "配置已恢复，但 SSH 服务/监听恢复验证失败！不要关闭当前会话；请用 Console 或当前 root 会话排查。备份: $SSH_BACKUP"
            warn '请检查 systemctl status ssh.service ssh.socket、journalctl -u ssh.service 和 ss -lntp。'
            show_ssh_runtime_status >&2
            return 1
        fi
    fi
    SSH_MODE_CHANGED=0
    SSH_ROLLBACK_FAILED=0
}
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    rollback_ssh || status=1
    [[ -z $SSH_CANDIDATE ]] || rm -f -- "$SSH_CANDIDATE"
    [[ -z $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
    exit "$status"
}
verify_key_only() {
    local config user connection client _clientport server serverport context keysfile line found
    config=$(get_effective_sshd_config) || return 1
    key_only_values "$config" || return 1
    client=127.0.0.1; server=127.0.0.1; serverport=22
    if [[ -n $SSH_CONTEXT ]]; then read -r client _clientport server serverport <<< "$SSH_CONTEXT"; fi
    for user in root "${READY_USERS[@]}"; do
        context="user=$user,host=$client,addr=$client,laddr=$server,lport=$serverport"
        connection=$(get_effective_sshd_config -C "$context") || return 1
        key_only_values "$connection" || return 1
        keysfile=$(config_value "$connection" authorizedkeysfile)
        case " $keysfile " in *' .ssh/authorized_keys '*) ;; *) warn "未使用标准 authorized_keys: $user"; return 1 ;; esac
        if [[ $user != root ]]; then
            found=0
            while IFS= read -r line || [[ -n $line ]]; do
                if key_allowed_by_sshd "$line" "$connection"; then found=1; break; fi
            done < "$(user_home "$user")/.ssh/authorized_keys"
            (( found )) || { warn "$user 没有符合 sshd 公钥算法 / RSA 长度要求的普通公钥。"; return 1; }
        fi
    done
}
disable_ssh_password_auth() {
    local config user planned_state
    # Syntax is the first gate, before account checks, backups or unit changes.
    if [[ -z $SSHD ]] || ! "$SSHD" -t -f "$SSHD_CONFIG"; then
        warn '原始 SSH 配置验证失败，未修改配置或服务。'; return 1
    fi
    config=$(get_effective_sshd_config) || return 0
    if [[ $(config_value "$config" passwordauthentication) == no ]]; then
        say 'SSH password authentication is already disabled.'
        show_ssh_values "$config"
        if key_only_values "$config" 2>/dev/null && find_ssh_service && (( ! SSH_MIGRATION_NEEDED )); then
            say '四项设置及服务监听均已满足；未重复修改。'; return 0
        fi
        warn '认证目标或 SSH 启动模式仍需处理，将按完整前置检查执行。'
    fi
    if ! check_ssh_hardening_readiness; then
        warn 'Cannot disable SSH password authentication.'
        warn '没有非 root 管理员同时满足：sudo、未过期的本地密码、安全权限、公钥。'
        say '请先创建用户、设置 Linux 密码、授予 sudo 并授权 SSH Key。'; return 0
    fi
    check_supported_ssh_layout && find_ssh_service || return 0
    planned_state=$SSH_RUNTIME_STATE
    say '以下普通管理员已配置公钥：'
    for user in "${READY_USERS[@]}"; do say "- $user (sudo: yes, keys: $(count_authorized_keys "$user"))"; done
    say '此操作禁止 root SSH、SSH 密码和键盘交互认证，保留 Linux 本地密码。'
    if (( SSH_MIGRATION_NEEDED )); then
        say "检测到 SSH socket 已启用/运行，将停止并禁用 ${SSH_SOCKET}，切换到 ${SSH_SERVICE}（仅停止监听主进程，保留已有会话）。"
    else
        say "当前为传统服务模式，将校验后 reload ${SSH_SERVICE}。"
    fi
    say '请先在新终端实际验证普通用户公钥登录和 sudo，再返回此处确认。'
    confirm '已完成新终端验证，继续关闭 SSH 密码登录？ [y/N] ' n || return 0
    # Recheck account state immediately before the transaction.
    check_ssh_hardening_readiness || { warn '前置状态发生变化，取消。'; return 0; }
    # The operator may have changed service state during new-terminal verification.
    find_ssh_service || return 0
    [[ $SSH_RUNTIME_STATE == "$planned_state" ]] || { warn 'SSH 启动状态在确认期间变化，请重新选择操作并确认。'; return 0; }
    "$SSHD" -t -f "$SSHD_CONFIG" || { warn '确认后配置验证失败，未修改。'; return 1; }
    [[ ! -L $SSH_DROPIN && ( ! -e $SSH_DROPIN || -f $SSH_DROPIN ) ]] || return 1
    mkdir -p -- "$BACKUP_ROOT" && chmod 700 "$BACKUP_ROOT" || return 1
    SSH_BACKUP=$(mktemp -d "$BACKUP_ROOT/ssh-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || return 1
    cp -p -- "$SSHD_CONFIG" "$SSH_BACKUP/sshd_config" || return 1
    SSH_PREVIOUS_EXISTS=0; SSH_RELOAD_ATTEMPTED=0; SSH_ROLLBACK_FAILED=0; SSH_MODE_CHANGED=0
    SSH_ORIGINAL_SERVICE_ACTIVE=$(ssh_active_state "$SSH_SERVICE") || return 1
    SSH_ORIGINAL_SERVICE_ENABLED=$(ssh_enabled_state "$SSH_SERVICE") || return 1
    SSH_ORIGINAL_SOCKET_ACTIVE=unknown; SSH_ORIGINAL_SOCKET_ENABLED=not-found
    if [[ -n $SSH_SOCKET ]]; then
        SSH_ORIGINAL_SOCKET_ACTIVE=$(ssh_active_state "$SSH_SOCKET") || return 1
        SSH_ORIGINAL_SOCKET_ENABLED=$(ssh_enabled_state "$SSH_SOCKET") || return 1
    fi
    [[ "$SSH_SERVICE:$SSH_ORIGINAL_SERVICE_ACTIVE:$SSH_ORIGINAL_SERVICE_ENABLED:$SSH_SOCKET:$SSH_ORIGINAL_SOCKET_ACTIVE:$SSH_ORIGINAL_SOCKET_ENABLED" == "$planned_state" ]] || { warn '备份时 SSH 启动状态变化，未修改。'; return 1; }
    printf 'Service=%s\nServiceActive=%s\nServiceEnabled=%s\nSocket=%s\nSocketActive=%s\nSocketEnabled=%s\n' "$SSH_SERVICE" "$SSH_ORIGINAL_SERVICE_ACTIVE" "$SSH_ORIGINAL_SERVICE_ENABLED" "$SSH_SOCKET" "$SSH_ORIGINAL_SOCKET_ACTIVE" "$SSH_ORIGINAL_SOCKET_ENABLED" > "$SSH_BACKUP/service-state" || return 1
    if [[ -e $SSH_DROPIN ]]; then
        cp -p -- "$SSH_DROPIN" "$SSH_BACKUP/00-key-only.conf" || return 1
        SSH_PREVIOUS_EXISTS=1
    fi
    printf '%s\n' "$SSH_PREVIOUS_EXISTS" > "$SSH_BACKUP/previous-exists" || return 1
    SSH_CANDIDATE=$(mktemp "${SSH_DROPIN}.new.XXXXXX") || return 1
    if ! {
        printf '%s\n' '# Managed by Linux Init Tool' 'PubkeyAuthentication yes' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' > "$SSH_CANDIDATE" &&
        chmod 644 "$SSH_CANDIDATE" && chown root:root "$SSH_CANDIDATE"
    }; then
        rm -f -- "$SSH_CANDIDATE"; SSH_CANDIDATE=''; return 1
    fi
    SSH_TRANSACTION=1
    mv -f -- "$SSH_CANDIDATE" "$SSH_DROPIN" || { rollback_ssh; return 1; }
    SSH_CANDIDATE=''
    if ! "$SSHD" -t -f "$SSHD_CONFIG"; then rollback_ssh; return 1; fi
    if ! verify_key_only; then report_ssh_conflicts; rollback_ssh; return 1; fi
    if ! check_ssh_reload_mode; then rollback_ssh; return 1; fi
    if [[ $SSH_RUNTIME_STATE != "$planned_state" ]]; then warn 'SSH 启动状态发生变化，取消应用。'; rollback_ssh; return 1; fi
    if ! apply_ssh_configuration || ! verify_key_only; then rollback_ssh; return 1; fi
    SSH_TRANSACTION=0
    SSH_MODE_CHANGED=0
    say "SSH 配置已生效。备份: $SSH_BACKUP"
    config=$(get_effective_sshd_config) || return 1
    show_ssh_values "$config"
    show_ssh_runtime_status
    say 'Current SSH session has not been terminated.'
    say 'Before closing it, open a NEW terminal and verify key-based login works.'
}

get_timezone() {
    local zone
    zone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [[ -z $zone && -r /etc/timezone ]]; then zone=$(cat /etc/timezone); fi
    printf '%s\n' "${zone:-unknown}"
}
configure_timezone() {
    if command -v timedatectl >/dev/null && timedatectl set-timezone UTC; then return 0; fi
    [[ -f /usr/share/zoneinfo/UTC ]] || return 1
    warn 'timedatectl 不可用，使用 tzdata 文件方式设置 UTC（适用于非 systemd/LXC）。'
    local backup
    mkdir -p "$BACKUP_ROOT" && chmod 700 "$BACKUP_ROOT" || return 1
    backup=$(mktemp -d "$BACKUP_ROOT/timezone-XXXXXX") || return 1
    cp -a /etc/localtime "$backup/" || return 1
    [[ ! -e /etc/timezone ]] || cp -p /etc/timezone "$backup/" || return 1
    ln -sfn /usr/share/zoneinfo/UTC /etc/localtime || return 1
    printf 'UTC\n' > /etc/timezone || return 1
}
basic_init() {
    local package missing=()
    say '将执行：apt update、安装缺少的基础包、设置 UTC；之后可选 full-upgrade。'
    say "基础包: ${BASIC_PACKAGES[*]}"
    confirm '继续？ [Y/n] ' y || return 0
    apt-get update || return 1
    for package in "${BASIC_PACKAGES[@]}"; do
        if ! package_installed "$package"; then missing+=("$package"); fi
    done
    if (( ${#missing[@]} )); then apt-get install -y "${missing[@]}" || return 1; fi
    configure_timezone || return 1
    if confirm 'Run full system upgrade? [Y/n] ' y; then
        say '升级可能触发发行版包维护脚本，请留意 apt 输出；工具不会主动重启。'
        apt-get full-upgrade -y || return 1
    fi
    if [[ -e /var/run/reboot-required ]]; then say 'Reboot required.'; else say 'Reboot not required.'; fi
}
show_ssh_runtime_status() {
    local unit service='' socket='' service_state=unknown socket_state=unknown enabled=unknown listeners owner=none mode=unknown
    if command -v systemctl >/dev/null; then
        for unit in ssh.service sshd.service; do
            if [[ $(systemctl show "$unit" -p LoadState --value 2>/dev/null) == loaded ]]; then service=$unit; break; fi
        done
        for unit in ssh.socket sshd.socket; do
            if [[ $(systemctl show "$unit" -p LoadState --value 2>/dev/null) == loaded ]]; then socket=$unit; break; fi
        done
        if [[ -n $service ]]; then service_state=$(ssh_active_state "$service") || service_state=unknown; mode=service; fi
        if [[ -n $socket ]]; then
            socket_state=$(ssh_active_state "$socket") || socket_state=unknown
            enabled=$(ssh_enabled_state "$socket") || enabled=unknown
            [[ $socket_state != active ]] || mode='socket-activated'
        else
            socket_state=not-found; enabled=not-found
        fi
    fi
    if listeners=$(ssh_port22_listeners 2>/dev/null); then
        if [[ -n $listeners ]]; then
            owner=other
            if [[ $listeners == *'("sshd",'* ]]; then owner=sshd; fi
            if [[ $listeners == *'pid=1,'* ]]; then
                mode='socket-activated'
                if [[ $owner == sshd ]]; then owner='systemd + sshd'; else owner=systemd; fi
            fi
        fi
    else owner=unknown
    fi
    say "Mode: $mode"; say "Service: $service_state${service:+ ($service)}"
    say "Socket: $socket_state${socket:+ ($socket)}, enabled: $enabled"
    say "Port 22 listener: $owner"
}
show_status() {
    local user config package admin=no key=no safe=no
    say ''; say 'System'; say '------'
    say "OS: $OS_NAME"; say "Kernel: $(uname -r)"
    say "Architecture: $(dpkg --print-architecture)"; say "Timezone: $(get_timezone)"
    say ''; say 'Users (普通登录用户，按 login.defs UID 范围和登录 shell 筛选)'; say '-----'
    say "root    sudo=n/a   ssh_keys=$(count_authorized_keys root)"
    while IFS= read -r user; do
        say "$user    sudo=$(sudo_label "$user")   ssh_keys=$(count_authorized_keys "$user")"
        if user_has_sudo "$user"; then admin=yes; fi
        if (( $(count_authorized_keys "$user") > 0 )); then key=yes; fi
    done < <(list_login_users)
    say ''; say 'SSH (磁盘配置经 sshd -T 解析；不等于实际登录验证)'; say '---'
    show_ssh_runtime_status
    if config=$(get_effective_sshd_config); then show_ssh_values "$config"; else say 'unknown'; fi
    say ''; say 'Packages'; say '--------'
    for package in "${BASIC_PACKAGES[@]}"; do
        if package_installed "$package"; then say "$package: installed"; else say "$package: missing"; fi
    done
    if check_ssh_hardening_readiness; then safe=yes; fi
    say ''; say 'Initialization readiness'; say '------------------------'
    say "Non-root sudo member: $admin"; say "SSH key configured: $key"
    say "Administrator prerequisites: $safe"
    say 'SSH 加固还需检查配置结构、服务、sshd -t/-T，并确认新终端实际登录。'
}
clear_menu_screen() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
        printf '\033[2J\033[H'
    fi
}
show_menu() {
    local config password=unknown rootlogin=unknown users key_hint='' hard_hint
    clear_menu_screen
    users=$(list_login_users)
    [[ -n $users ]] || key_hint=' [需要先创建普通用户]'
    hard_hint=' [需要 sudo + 有效公钥 + 可用本地密码]'
    if check_ssh_hardening_readiness; then hard_hint=' [前置用户条件满足，仍需验证 SSH]'; fi
    if config=$(get_effective_sshd_config 2>/dev/null); then
        password=$(config_value "$config" passwordauthentication)
        rootlogin=$(config_value "$config" permitrootlogin)
    fi
    printf '%s╭──────────────────────────────╮\n│        Linux Init Tool       │\n╰──────────────────────────────╯%s\n' "$COLOR" "$RESET"
    say "System: $OS_NAME | Host: $(hostname)"
    say "Current user: $(id -un) | Timezone: $(get_timezone)"
    say "SSH password login: $password | Root SSH: $rootlogin"
    say '1) 创建用户 / 补 sudo 权限'
    say "2) SSH Key 授权$key_hint"
    say "3) 关闭 SSH 密码登录$hard_hint"
    say '4) 基础环境初始化'; say '5) 查看当前状态'; say '0) 退出'
}
main() {
    local choice
    [[ -t 0 && -t 1 ]] || { warn '需要交互终端；请使用 bash <(curl -fsSL https://install.dry.li/init)。'; return 1; }
    require_root || return 1
    detect_os || return 1
    umask 077
    WORK_DIR=$(mktemp -d) || return 1
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    command -v flock >/dev/null || { warn '缺少 flock（util-linux）。'; return 1; }
    exec 9>/run/linux-init.lock
    flock -n 9 || { warn '另一个 Linux Init 正在运行，请稍后再试。'; return 1; }
    if [[ ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then COLOR=$'\033[0;36m'; RESET=$'\033[0m'; fi
    while true; do
        show_menu
        ask '请选择操作: ' choice || break
        case "$choice" in
            1) if ! create_user; then warn '用户操作失败，请检查上方错误。'; fi ;;
            2) if ! authorize_ssh_key; then warn '授权操作失败，请检查上方错误。'; fi ;;
            3) if ! disable_ssh_password_auth; then rollback_ssh || return 1; warn 'SSH 操作失败，请保留当前会话并检查上方错误。'; fi ;;
            4) if ! basic_init; then warn '基础初始化中断，请检查上方错误；可重新运行。'; fi ;;
            5) show_status ;;
            0) break ;;
            *) warn '请输入菜单中的编号。'; pause; continue ;;
        esac
        pause
    done
}

# Allows isolated tests to source functions without running the live menu.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
