#!/usr/bin/env bash
# Repeatable Debian/Ubuntu administration menu. No changes until an action is selected.
set -Eeuo pipefail

# Configuration: put one complete public key on each line. Never put private keys here.
DEFAULT_SSH_PUBLIC_KEYS=(
    # "ssh-ed25519 AAAA... user@example"
)
VERSION="1.0.0"
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
SSH_SERVICE=""
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
        declare -p WORK_DIR SSH_BACKUP SSH_CANDIDATE SSH_TRANSACTION SSH_PREVIOUS_EXISTS SSH_RELOAD_ATTEMPTED SSH_SERVICE SSHD OS_NAME UID_MIN UID_MAX COLOR RESET
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
        *) warn "仅支持 Debian 12/13、Ubuntu 22.04/24.04/26.04（当前 $ID $VERSION_ID）。"; return 1 ;;
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
    local config=$1 key
    for key in pubkeyauthentication passwordauthentication kbdinteractiveauthentication permitrootlogin; do
        say "$key: $(config_value "$config" "$key")"
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
find_ssh_service() {
    local service start argv environment file token allowed environment_files tokens=()
    command -v systemctl >/dev/null || { warn '无 systemd，SSH 加固仅支持可确认的 systemd reload。'; return 1; }
    SSH_SERVICE=''
    for service in ssh.service sshd.service; do
        if systemctl is-active --quiet "$service"; then SSH_SERVICE=$service; break; fi
    done
    [[ -n $SSH_SERVICE ]] || { warn '没有正在运行的 ssh.service / sshd.service。'; return 1; }
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
    [[ $(systemctl show "$SSH_SERVICE" -p CanReload --value) == yes ]] || { warn 'SSH 服务不支持 reload。'; return 1; }
}
report_ssh_conflicts() {
    warn '可能冲突的文件/指令（未 reload）：'
    grep -nEi '^[[:space:]]*(Include|Match|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin)' "$SSHD_CONFIG" "$SSH_DROPIN_DIR"/*.conf >&2 || true
}
rollback_ssh() {
    (( SSH_TRANSACTION )) || return 0
    local restore
    if (( SSH_PREVIOUS_EXISTS )); then
        restore=$(mktemp "${SSH_DROPIN}.restore.XXXXXX") || return 1
        cp -p -- "$SSH_BACKUP/00-key-only.conf" "$restore" && mv -f -- "$restore" "$SSH_DROPIN" || return 1
    else
        rm -f -- "$SSH_DROPIN" || return 1
    fi
    warn '已恢复 SSH drop-in。'
    if (( SSH_RELOAD_ATTEMPTED )); then
        if "$SSHD" -t -f "$SSHD_CONFIG" && systemctl reload "$SSH_SERVICE"; then
            warn '已 reload 恢复后的 SSH 配置。'
        else
            warn "恢复配置已写回，但 reload 失败！保留当前会话，使用备份 $SSH_BACKUP 排查。"; return 1
        fi
    fi
    SSH_TRANSACTION=0
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
    local config user
    config=$(get_effective_sshd_config) || return 0
    if [[ $(config_value "$config" passwordauthentication) == no ]]; then
        say 'SSH password authentication is already disabled.'
        show_ssh_values "$config"
        if key_only_values "$config" 2>/dev/null; then
            say '四项全局设置均已满足；未重复修改（Match / 服务运行状态仍需核对）。'; return 0
        fi
        warn '其余目标项尚未全部满足，将按完整前置检查处理。'
    fi
    if ! check_ssh_hardening_readiness; then
        warn 'Cannot disable SSH password authentication.'
        warn '没有非 root 管理员同时满足：sudo、未过期的本地密码、安全权限、公钥。'
        say '请先创建用户、设置 Linux 密码、授予 sudo 并授权 SSH Key。'; return 0
    fi
    check_supported_ssh_layout && find_ssh_service || return 0
    "$SSHD" -t -f "$SSHD_CONFIG" || { warn '原始 SSH 配置验证失败，未修改。'; return 0; }
    say '以下普通管理员已配置公钥：'
    for user in "${READY_USERS[@]}"; do say "- $user (sudo: yes, keys: $(count_authorized_keys "$user"))"; done
    say '此操作禁止 root SSH、SSH 密码和键盘交互认证，保留 Linux 本地密码。'
    say '请先在新终端实际验证普通用户公钥登录和 sudo，再返回此处确认。'
    confirm '已完成新终端验证，继续关闭 SSH 密码登录？ [y/N] ' n || return 0
    # Recheck account state immediately before the transaction.
    check_ssh_hardening_readiness || { warn '前置状态发生变化，取消。'; return 0; }
    [[ ! -L $SSH_DROPIN && ( ! -e $SSH_DROPIN || -f $SSH_DROPIN ) ]] || return 1
    mkdir -p -- "$BACKUP_ROOT" && chmod 700 "$BACKUP_ROOT" || return 1
    SSH_BACKUP=$(mktemp -d "$BACKUP_ROOT/ssh-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || return 1
    cp -p -- "$SSHD_CONFIG" "$SSH_BACKUP/sshd_config" || return 1
    SSH_PREVIOUS_EXISTS=0; SSH_RELOAD_ATTEMPTED=0
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
    SSH_RELOAD_ATTEMPTED=1
    if ! systemctl reload "$SSH_SERVICE"; then rollback_ssh; return 1; fi
    if ! systemctl is-active --quiet "$SSH_SERVICE" || ! verify_key_only; then rollback_ssh; return 1; fi
    SSH_TRANSACTION=0
    say "SSH 配置已生效。备份: $SSH_BACKUP"
    config=$(get_effective_sshd_config) || return 1
    show_ssh_values "$config"
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
