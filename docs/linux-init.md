# Linux Init Tool 1.3.0

可反复打开的 Debian / Ubuntu / Alpine 初始化管理菜单。启动只检查状态；每项操作独立，选择并确认后才修改系统。
支持清屏的终端在首次显示和每次返回主页时将标题放到顶部；只清理当前屏幕，保留滚动历史。操作结果保留到按 Enter 返回。

## 显示与终端适配

- 主页显示版本、系统、主机、当前用户、时区和 SSH 登录摘要，菜单按“用户与 SSH”“系统与状态”分组。
- 常见 24 行终端使用紧凑布局；窗口达到 30 行时显示菜单说明。分隔线按窗口列数收窄，上限 60 列。
- 状态页统一分区和缩进；已满足、未满足、未知等状态都有文字说明，颜色仅辅助阅读。
- 青色用于标题/步骤，绿色用于完成/已满足/恢复成功，黄色用于提示，红色用于错误，较淡文字用于辅助说明。
- 通过 `tput` 检测终端颜色和清屏能力，不假定所有终端都支持 ANSI。不足 8 色、`TERM=dumb`、未知/空 TERM、缺少 tput 时使用纯文本；不支持清屏时按普通文本输出。
- 设置 `NO_COLOR`（包括空值）可关闭工具颜色，例如 `NO_COLOR=1 bash <(curl -fsSL https://dry.li/init)`；该偏好会保留到 sudo 提权副本中。
- 标准输出/错误输出重定向时，对应流不含工具生成的颜色控制序列。主程序仍要求交互终端，不能通过管道无人值守运行。
- apt/apk、passwd、sshd 等外部命令保留原始输出；上述配色和 NO_COLOR 适配针对工具自身的输出。

## 入口与项目结构

发布到现有 Cloudflare Pages 项目后：

```bash
bash <(curl -fsSL https://dry.li/init)
```

需要交互终端、Bash，以及下载入口所需的 curl。root 直接执行；普通用户需要已配置的 sudo。
脚本将已解析的函数和配置写入私有临时目录，再用 sudo 执行这个副本，不重新下载，不依赖原 stdin 或已消费的 `/dev/fd` 管道。
没有 sudo 时明确要求以 root 登录。运行中的工具用 `/run/linux-init.lock` 防止并发实例。

Alpine 默认登录 shell 为 ash，脚本仍依赖 Bash。首次以 root 执行：

```sh
apk add --no-cache bash curl ca-certificates
bash -c 'bash <(curl -fsSL https://dry.li/init)'
```

已配置真实 sudo 的普通用户可运行第二行，脚本会请求 sudo 密码。只有 doas 时首次请以 root 运行。
不能用 `sh` 执行本脚本；也不要用 `curl | bash`，交互输入需要保留给终端。

项目文件：

- `public/linux-init/linux-init.sh`：Linux Init 对外发布的 Bash 脚本。
- `tests/test-linux-init.sh`：隔离回归测试，不发布。
- `tests/test-linux-init-alpine.sh`：仅限一次性 Alpine Docker 容器的真实用户和 SSH 登录测试，不发布。
- `docs/linux-init.md`：使用、恢复与验收说明，不发布。
- `public/_redirects`：`/init /linux-init/linux-init.sh 200`，内部重写并返回脚本文本。
- `build-pages.sh`：将整个 `public/` 复制到 `dist/`；保留 `/init` 和 `/snell-alpine`。
- 根 `README.md`：入口和脚本索引。

仍使用 `sh build-pages.sh` 构建、`dist` 作为 Pages 输出目录。这里只准备仓库文件，不自动推送或部署。

## 填写预置公钥

修改 `public/linux-init/linux-init.sh` 顶部：

```bash
DEFAULT_SSH_PUBLIC_KEYS=(
    "ssh-ed25519 AAAA... user@example"
    "ssh-rsa AAAA... another@example"
)
```

示例中的 `AAAA...` 必须替换成完整真实公钥。默认数组为空，选择预置授权会提示尚未配置。
也可以不填数组，使用菜单手动粘贴一整行。只支持普通公钥，不能放私钥或证书。
支持 ed25519、RSA、NIST ECDSA，以及 OpenSSH 安全密钥 `sk-ssh-ed25519` / `sk-ecdsa` 类型。
公钥是公开数据，填写后会随脚本公开发布。

## 菜单与前置条件

| 菜单 | 行为 | 前置条件 |
| --- | --- | --- |
| 1 创建用户 / 补 sudo | 默认用户名 `ppy`；新建 `/home/<user>`、`/bin/bash`，调用 `passwd`；默认授予 sudo | root 权限、有效用户名；同名 home 不能预先存在 |
| 2 SSH Key 授权 | 选择普通登录用户；可选显示 root；预置所有 key 或手动粘贴 | 至少一个普通登录用户、`ssh-keygen`、真实 home、非链接 key 路径 |
| 3 关闭 SSH 密码登录 | 开启公钥、禁止 SSH 密码/键盘交互和 root SSH；标准 systemd socket 模式迁移为服务模式，Alpine 使用 OpenRC reload | 至少一个满足全部条件的非 root 管理员，标准 OpenSSH 配置和 systemd/OpenRC 服务，22 端口监听；`ss` 可核对进程；确认默认 No |
| 4 基础环境初始化 | 更新软件索引、安装缺少的基础包、设 UTC，之后可选当前发行版软件包升级 | apt/apk 可用；开始默认 Yes，升级默认 Yes，均可拒绝 |
| 5 查看状态 | 系统、登录用户、sudo 组、公钥数量、SSH 模式/服务/socket/22 监听进程、sshd 最终配置、包和管理员前置条件 | 只读查询；缺少 sshd 时显示 unknown |
| 0 退出 | 关闭菜单 | 无 |

普通用户按 `/etc/login.defs` 的 `UID_MIN`/`UID_MAX` 范围和 `/etc/shells` 中有效 shell 筛选；文件或值缺失时使用 1000–60000（兼容最小 Alpine），排除 root 和 nologin/false 等账号。
用户列表描述“正常登录账号类型”，不意味着每个账号都未锁定；加固会进一步检查 shadow 锁定、密码过期和账号到期状态。
非标准 UID 的管理员暂不自动列入；请先人工核对，不会把系统账号自动当作管理员。

已存在用户会显示 home、shell、sudo、key 数量，不重复创建；普通用户可以在此补 sudo。
Debian/Ubuntu 的 `sudo` 一栏表示 sudo 组成员；加固还会验证 `visudo -c` 和实际 `sudo -l -U` 中的常规完整管理员权限。
Alpine 使用 BusyBox `adduser -D` 创建用户、`passwd` 设置密码、`addgroup <user> wheel` 添加组。
Alpine 的 wheel 组本身不代表 sudo 已授权：工具安装真实 sudo，写入 `/etc/sudoers.d/linux-init-<user>`，仅向该用户授予 `ALL=(ALL:ALL) ALL`，权限 0440。
写入前后校验 sudo 配置及实际授权；失败恢复原授权文件，不覆盖非托管的同名文件，不启用整个 wheel 组。
状态页在 Alpine 上显示实际 sudo 策略检查结果。检测到 `doas-sudo-shim` 时要求人工处理冲突，不自动移除 doas 或改写 doas 策略。
不会写 NOPASSWD。新加入的组在该用户重新登录后生效。
若创建用户时 `passwd` 失败，保留已创建账号，并提示用 `passwd <user>` 重试；不会删除账号。

公钥授权创建 `.ssh` 700 / `authorized_keys` 600，设置用户 uid/gid，保留已有 key。
预置整个批次先经 `ssh-keygen` 验证再写入；相同“类型 + 公钥数据”即使注释不同也不重复追加。
已有带 options 的合法公钥会计入状态；但受限公钥（如 `from=`、`command=`、`restrict`）不能单独作为管理员安全登录依据。
遇到符号链接或 authorized_keys 硬链接会拒绝写入；不接管其特殊布局。

## SSH 防锁死和恢复

加固用户必须同时满足：

1. 非 root 普通登录账号。
2. Debian/Ubuntu 属于 sudo 组；所有平台均要求 sudo 配置语法正确，并具有常规 `(ALL : ALL) ALL` 或 `(ALL) ALL` 管理权限。
3. Linux 本地密码已设置，账号未锁定/到期，密码未到期，确保后续 sudo 可用。
4. 标准 `~/.ssh/authorized_keys` 至少有一个有效、无 options 限制的普通公钥。
5. key 文件及祖先路径属于用户或 root，不可被组/其他用户写入，不含符号链接。
6. 加固后的 sshd 公钥算法和 RSA 最低长度允许该用户至少一个 key。

选择菜单 3 后会显示候选管理员，并要求先在新终端实际验证公钥登录和 sudo，再输入 `y`。
脚本无法证明客户端持有私钥，也不能代替真实连接验证。

仅写 `/etc/ssh/sshd_config.d/00-key-only.conf`：

```text
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

主配置不被 sed 修改。只接受第一条有效指令就是标准 drop-in Include 的布局，避免全局设置抢先生效。
OpenSSH 多数配置采用 first obtained value wins，因此 `00` 通常会先于 `50-cloud-init.conf`，但仍以实际 `sshd -T` 校验结果为准，而不依赖文件名假设。
规则依据：[OpenSSH sshd_config 手册](https://man.openbsd.org/sshd_config)。

遇到下列情形保守拒绝，不自动重写现有策略：

- 主配置未提前 Include drop-in，配置路径是链接，嵌套/自定义 Include。
- 任意 `Match`、`AllowUsers`/`DenyUsers`、`AllowGroups`/`DenyGroups`。
- 自定义 AuthorizedKeysFile、额外 AuthenticationMethods、ForceCommand、Chroot、吊销列表或公钥附加认证要求。
- 服务启动参数/环境文件不能对应默认 sshd 配置；Debian/Ubuntu 无 systemd，或 Alpine 无 OpenRC。
- 未知触发单元、显式 `Sockets=`，或不能确认 22 端口所属进程。
- 迁移时 `KillMode` 不是 `process`、`SendSIGHUP` 不是 `no`、停止信号非 SIGTERM、存在自定义启停钩子/要求 socket 的依赖（服务仅允许标准 `sshd -t` 启动检查）。
- socket 使用 `Accept=yes`、非标准服务映射或非标准 22 端口全地址监听；sshd 的 Port / ListenAddress / AddressFamily 不匹配。
- 公钥算法不允许候选管理员的 key，或任何语法/最终值检查失败。

### Debian/Ubuntu 服务应用与 socket 迁移

菜单 3 **首先执行 `sshd -t`**；失败就返回错误，不创建备份、不写配置、不修改服务，也不会为绕过检查自动补 `/run/sshd`。
普通服务模式检查 SSH 主进程独立持有 22 端口后使用 `systemctl reload ssh.service`（或实际 `sshd.service`）。
`TriggeredBy` 仅是关联信息：socket 已停止且禁用/屏蔽，不会仅因残留关联拒绝加固。

对已启用或运行的标准 `ssh.socket` / `sshd.socket`，菜单 3 会在确认前明确说明迁移方案，确认默认 No。
配置验证成功后统一转为传统服务模式，**不向 socket 模式服务发送 HUP/reload**：

1. 记录服务与 socket 的 active/enabled 状态并备份配置。
2. 原子写入 drop-in，再执行 `sshd -t`、全局 `sshd -T`、root/候选用户 `sshd -T -C` 和公钥算法校验。
3. 再次核对运行模式未在确认期间变化。
4. stop + disable socket（含原先 enabled-runtime 的临时启用）。
5. stop 服务监听主进程；reset-failed；enable + start 服务。
6. 连续三次、间隔一秒确认服务 active、socket inactive/disabled、**22 端口所有监听均由该 sshd 主进程独立持有**，再次校验认证设置。

已运行服务上的 start 是无操作，因此需要步骤 5 的 stop 才能释放继承的监听描述符，让新配置在新主进程中生效。
只在确认 `KillMode=process`、无额外停止钩子、`SendSIGHUP=no` 的单元上这样做：停止信号仅发送给监听主进程，保留已有 SSH 会话子进程。不会对会话或整个控制组执行 kill。
存在短暂的新连接监听空窗；当前会话保留，完成后必须另开终端验证普通用户公钥登录和 sudo。
依据：[systemd KillMode / SendSIGHUP](https://manpages.debian.org/trixie/systemd/systemd.kill.5.en.html)。
该路径针对已报告的 [Debian 13/LXC socket reload 绑定失败](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1128329)，服务启动/绑定/健康检查失败会报告为服务应用失败，不归类为 sshd_config 语法错误。
自定义端口、地址、启动方式需人工核对；工具不猜测监听配置或重写 systemd 单元。
非 systemd LXC 仍可使用用户、公钥、基础初始化和查看状态。

### Alpine / OpenRC 服务应用

Alpine 按独立服务路径处理，不调用 systemctl、不迁移 socket：

1. 首先执行 `sshd -t`；失败时不创建目录、不修改配置或服务。
2. 只接受标准 OpenSSH `sshd` 服务；通过 apk 核对 `/etc/init.d/sshd` 归属、内容和权限未被修改。`/etc/conf.d/sshd` 只允许默认配置路径、空启动选项和默认密钥生成开关；额外 runlevel 配置或自定义参数需要人工审查，不 source 这些文件。
3. 检查 OpenRC 服务 active，`/run/sshd.pid` 对应实际 `/usr/sbin/sshd`，且 22 端口由该主进程独立监听。自定义 PID 路径、PAM/Kerberos sshd 变体、Dropbear 暂不自动处理。
4. 在用户确认新终端登录后，按相同事务流程备份、写入 drop-in、检查 `-t/-T/-C`，再执行 `rc-service sshd reload`。不会 stop/restart SSH，也不修改现有 runlevel 注册。
5. 连续检查服务和监听，提醒另开终端验证公钥登录及 sudo。失败恢复配置；主进程仍正常时重载原配置，已退出且 22 端口空闲时清除 OpenRC 陈旧状态（zap）并 start，避免向现有会话发送停止信号。无法确认恢复成功时清晰报警并停止菜单。

Alpine 的 privilege separation 目录是软件包提供的 `/var/empty`，不创建 Debian 的 `/run/sshd`。`sshd_config.d` 的提前 Include 可以沿用，但仍逐次检查实际布局和最终值。
首次安装服务由管理员完成，例如使用 Alpine 的 `setup-sshd` 选择 OpenSSH；基础初始化只补齐检查依赖，不自动替换或启动另一套 SSH 服务。
依据：[Alpine 用户与权限](https://wiki.alpinelinux.org/wiki/Setting_up_a_new_user)、[Alpine OpenSSH 服务脚本](https://raw.githubusercontent.com/alpinelinux/aports/3.24-stable/main/openssh/sshd.initd)、[OpenSSH 打包配置](https://raw.githubusercontent.com/alpinelinux/aports/3.24-stable/main/openssh/APKBUILD)。

### 备份和失败恢复

每次真正改 SSH 前，在 `/var/backups/linux-init/ssh-<UTC时间>-<随机后缀>/` 保存：

- `sshd_config`：主配置快照（工具不会修改该文件）。
- `00-key-only.conf`：原托管 drop-in，原文件存在时保存。
- `previous-exists`：原 drop-in 是否存在。
- `service-state`：实际服务/socket 名称以及迁移前 active/enabled 状态，仅作记录，不作为脚本执行。

语法/最终值失败在任何服务操作前恢复 drop-in。
迁移中任何步骤失败，恢复原 drop-in、原服务/socket 开机启用状态和原活动模式，再核对 22 端口。
原来只有 socket 活动时可恢复为 systemd 监听 22、等待新连接激活服务；不会发送 HUP。
普通 reload 失败时，若服务仍活动且独立持有监听端口，reload 恢复后的配置；若监听主进程已退出，则安全校验停止策略后 reset-failed + start。
恢复中若停止/失败服务导致 `/run/sshd` 被清理，可仅在恢复流程中重建这个非链接目录，再执行 `sshd -t`；这不绕过操作入口的首次语法校验。

恢复失败会显示备份位置和当前模式/监听状态，要求保留会话，用 Console 或当前 root 会话检查日志，并停止菜单。
失败是事务终止状态，main/EXIT 不重复恢复或刷屏。EXIT、INT、TERM、HUP 会回滚未完成事务；断电/SIGKILL 无法触发 trap。

下列手动恢复命令针对 Debian/Ubuntu；保留当前会话，以 root 执行，先换成实际备份路径：

```bash
backup='/var/backups/linux-init/ssh-实际时间和后缀'
cat "$backup/service-state"
if [ "$(cat "$backup/previous-exists")" = 1 ]; then
    cp -p "$backup/00-key-only.conf" /etc/ssh/sshd_config.d/00-key-only.conf
else
    rm -f /etc/ssh/sshd_config.d/00-key-only.conf
fi
install -d -o root -g root -m 0755 /run/sshd
/usr/sbin/sshd -t
systemctl status ssh.service ssh.socket --no-pager -l
ss -lntp
journalctl -u ssh.service -n 60 --no-pager
```

`sshd -t` 失败时先修复，不能继续应用。
根据 `service-state` 和当前实际监听模式决定恢复方式，不要盲目 reload：

- 原为 socket 模式：核对 `KillMode=process` 等条件后停止服务监听主进程，恢复 socket 原启用状态，启动 socket；原服务 active 时再 start 服务。
- 原为传统服务模式且服务 failed/inactive：reset-failed + start 服务；仍活动且独立持有 22 端口时才 reload。
- 原启用状态为 enabled-runtime 时使用 `enable --runtime`，原为 disabled 时不要永久 enable。

恢复后核对 22 LISTEN 并另开新终端验证；不要把备份主配置盲目写回，也不要执行会杀死整个 SSH 控制组的停止操作。
运行目录缺失可能是服务失败后的清理结果，不一定是最初失败原因。

Alpine 恢复同一份 drop-in 备份后，先运行 `/usr/sbin/sshd -t`、`rc-service sshd status` 和 `ss -lntp`。
服务仍活动且由 sshd 独占监听时才执行 `rc-service sshd reload`；主进程已退出时先排查启动日志、端口和 PID，再决定 start。不要套用上述 systemctl 或 `/run/sshd` 命令。

### 状态与重复运行

状态页只读显示 Mode（service / socket-activated）、Service、Socket（含 enabled 状态）、Port 22 listener（sshd / systemd / 两者 / other / none / unknown），以及四项认证配置。
同时显示 Manager（systemd / openrc）；Alpine 的 Socket 为 not-applicable，并显示 OpenRC runlevel 中的开机启动注册状态。
`sshd -T` 是磁盘配置解析结果，不是进程内存快照，也不能代替真实新连接验证。
四项认证设置和传统服务监听均满足时不重复备份、写入或 reload；已经 key-only 但仍使用 socket 的机器，仍按完整检查及确认流程迁移。

## 基础环境与兼容范围

- Debian 12/13、Ubuntu 22.04/24.04/26.04、Alpine 3.x 稳定版，amd64/arm64；其他系统/版本和 Alpine edge/testing 直接拒绝。Debian/Ubuntu 使用发行版的 Bash、GNU 工具和 apt；Alpine 使用 Bash、BusyBox、musl getent 和 apk，不要求安装 shadow 来创建用户。
- VPS、独服、KVM/PVE VM、常规 LXC；以实际系统能力为准，不探测厂商，不处理 qemu-guest-agent。
- 基础包：sudo、curl、ca-certificates、git、vim、htop、unzip。Alpine 另补 bash、openssh-keygen、iproute2-ss、tzdata、ncurses，支持公钥校验、监听检查和颜色显示。最小系统缺少 `ss` 时可先运行菜单 4。只安装缺失包，不静默启用/更换软件仓库；sudo 等包需要当前稳定版 community 仓库。
- Debian/Ubuntu 可选 `apt-get full-upgrade`；Alpine 可选 `apk upgrade`，只升级当前已配置仓库的软件包，不修改仓库地址或跨发行版升级。
- systemd 优先 `timedatectl set-timezone UTC`；Alpine 及其他不可用场景先补齐 tzdata，备份已有 localtime/timezone 后设置 UTC，兼容最小安装尚无 `/etc/localtime`。
- 不改变 hostname、DNS、网络、防火墙、Docker、RTC 策略，不安装 guest agent，不主动 reboot。
- SSH 禁用只影响 SSH 认证，保留 root/普通用户 Linux 密码与账号、Console 登录和 sudo 密码认证。
- apt/apk 升级时发行版包维护脚本可能自行 reload/restart 服务或询问配置保留选项；请留意输出。工具本身不另行修改 SSH 配置。
- Debian/Ubuntu 按 `/var/run/reboot-required` 提示重启标记；没有标记不证明无需重启。Alpine 没有统一的该标记，升级后提示人工检查重启需求。
- Alpine 适配以持久化安装和常规 LXC 为目标；diskless/data 模式的 `lbu` 持久化需管理员单独处理，工具不自动提交 overlay，也不保证这些模式下重启后保留更改。

## 测试与上线前验收

本地隔离测试（不需要 sudo）：

```bash
bash -n public/linux-init/linux-init.sh
bash tests/test-linux-init.sh
shellcheck -x public/linux-init/linux-init.sh tests/test-linux-init*.sh build-pages.sh
sh build-pages.sh
```

隔离测试只 source 函数，使用临时用户/配置数据和模拟管理命令。
公钥校验及 `sshd -t/-T/-C` 使用真实 OpenSSH，仅读取临时配置/host key，不启动 daemon，不修改宿主机 SSH。
覆盖 root-only、用户筛选、已有用户补 sudo、key 去重/损坏数据/权限/链接、锁定/到期/sudo 策略、Include/cloud-init 冲突、Match/服务参数拒绝、公钥算法拒绝、socket/service 迁移（同时活动、仅 socket 活动、仅启用、runtime 启用、sshd 别名）、逐步骤失败及原模式回滚、不安全停止策略/端口/地址拒绝、状态页、确认期间启动方式变化、首次及候选语法失败、reload 失败/延迟退出/恢复失败去重、TERM 回滚、process-substitution 重建，以及基础安装/升级确认。
测试脚本和 README 位于 `public/` 外，不进入 `dist/`。

OpenRC 隔离用例另覆盖自定义脚本/参数/runlevel 配置/PID 拒绝、候选语法失败、reload 失败、主进程退出后的恢复、终止回滚去重和 apk 分支。

一次性 Alpine 容器验收（**会修改容器内账号、sudo、SSH 和时区，禁止在生产机直接运行测试文件**）：

```sh
docker run --rm -v "$PWD:/workspace:ro" -e LINUX_INIT_CONTAINER_TEST=1 alpine:3.22 sh -c '
  apk add --no-cache bash openssh openrc sudo iproute2-ss tzdata ncurses sshpass &&
  bash /workspace/tests/test-linux-init-alpine.sh
'
```

不发布容器端口；测试通过回环 SSH 连接核对真实用户创建、密码 sudo、同组其他用户未获授权、公钥去重、OpenRC reload、旧会话保留、新连接公钥成功、密码/root SSH 拒绝、状态和重复运行。
当前已完成 macOS 隔离回归及 Alpine 3.22、3.24 arm64 容器验收；**未完成各 Debian/Ubuntu 版本/架构的真实 VM/LXC 安装、systemd 迁移/reload，以及 Alpine 全部版本/架构的验收**。
上述版本列表是实现支持范围，不能据此视为全部已实机验证。

上线前用可销毁、有 Console 的 VM 做矩阵验收，避免在当前生产机上跑修改 SSH 的自动测试：

1. 至少 Debian 13、Ubuntu 24.04；再覆盖 Debian 12、Ubuntu 22.04/26.04，amd64/arm64 和有/无 systemd 的 LXC。
2. 只有 root：菜单 2 和 3 拒绝；菜单 1 创建账号并交互设置密码。
3. 普通用户无 sudo/key：补 sudo → 授权 → 在新终端 `ssh -i <私钥> ppy@<测试机>`，确认 `sudo -v`。
4. 保留旧连接，在菜单 3 确认。新连接公钥应成功；密码、keyboard-interactive 和 root SSH 应拒绝；Console 的 root 密码和用户 sudo 密码应继续有效。
5. 加入 `50-cloud-init.conf` 的 PasswordAuthentication yes，验证工具最终值仍正确；加入更早冲突、Match 或自定义服务选项，验证工具拒绝且不 reload。
6. Debian 13/LXC 使用 ssh.socket + ssh.service 同时活动，确认加固走无 HUP 的迁移路径、旧会话保留、服务 active、socket inactive/disabled、22 由 sshd 持有；再验证 socket-only 和 Ubuntu。
7. 模拟配置错误、迁移逐步失败、reload 失败、中途 TERM，核对备份、原服务/socket 状态回滚和原会话。
8. 以普通用户实际执行 `bash <(cat public/linux-init/linux-init.sh)`，验证 sudo 提权和返回菜单；重复新增相同 key、已有用户、加固和基础初始化，验证幂等。
9. 在测试机拒绝 full-upgrade，检查只执行更新索引、补包和 UTC；允许升级时检查结果和重启标记，确认没有自动 reboot。

## 典型流程

- 全新机器只有 root：创建用户 → SSH Key 授权 → **新终端验证公钥登录和 sudo** → 关闭 SSH 密码登录 → 基础初始化。
- 已有普通用户：如有必要在菜单 1 补 sudo/用 `passwd <user>` 修复本地密码 → 直接授权 → 新终端验证 → 关闭密码。
- 已初始化：重新运行，查看状态或新增用户/key；满足目标的 SSH 配置不重复修改。
- 任意顺序：可先执行基础初始化；未满足用户条件的授权/加固只说明原因并返回菜单，不强制串行跑全部步骤。
