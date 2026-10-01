# Linux Init Tool 1.0.0

可反复打开的 Debian / Ubuntu 初始化管理菜单。启动只检查状态；每项操作独立，选择并确认后才修改系统。
首次显示和每次返回主菜单都会清屏，将标题放在终端顶部；操作结果保留到按回车返回。非交互输出和 dumb 终端不发送清屏控制序列。

## 入口与项目结构

发布到现有 Cloudflare Pages 项目后：

```bash
bash <(curl -fsSL https://install.dry.li/init)
```

需要交互终端、Bash，以及下载入口所需的 curl。root 直接执行；普通用户需要已配置的 sudo。
脚本将已解析的函数和配置写入私有临时目录，再用 sudo 执行这个副本，不重新下载，不依赖原 stdin 或已消费的 `/dev/fd` 管道。
没有 sudo 时明确要求以 root 登录。运行中的工具用 `/run/linux-init.lock` 防止并发实例。

项目文件：

- `linux-init/linux-init.sh`：唯一对外发布的 Bash 脚本。
- `linux-init/test-linux-init.sh`：隔离回归测试，不发布。
- `linux-init/README.md`：使用、恢复与验收说明，不发布。
- `_redirects`：`/init /linux-init/linux-init.sh 200`，内部重写并返回脚本文本。
- `build-pages.sh`：沿用发布白名单，将脚本复制到 `dist/linux-init/linux-init.sh`；保留 `/snell-alpine`。
- 根 `README.md`：入口和脚本索引。

仍使用 `sh build-pages.sh` 构建、`dist` 作为 Pages 输出目录。这里只准备仓库文件，不自动推送或部署。

## 填写预置公钥

修改 `linux-init/linux-init.sh` 顶部：

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
| 3 关闭 SSH 密码登录 | 开启公钥、禁止 SSH 密码/键盘交互和 root SSH | 至少一个满足全部条件的非 root 管理员，标准可验证 SSH 配置和活动 systemd 服务；确认默认 No |
| 4 基础环境初始化 | 更新软件索引、安装缺少的基础包、设 UTC，之后可选 full-upgrade | apt 可用；开始默认 Yes，升级默认 Yes，均可拒绝 |
| 5 查看状态 | 系统、登录用户、sudo 组、公钥数量、sshd 最终配置、包和管理员前置条件 | 只读查询；缺少 sshd 时显示 unknown |
| 0 退出 | 关闭菜单 | 无 |

普通用户按 `/etc/login.defs` 的 `UID_MIN`/`UID_MAX` 范围和 `/etc/shells` 中有效 shell 筛选，排除 root 和 nologin/false 等账号。
用户列表描述“正常登录账号类型”，不意味着每个账号都未锁定；加固会进一步检查 shadow 锁定、密码过期和账号到期状态。
非标准 UID 的管理员暂不自动列入；请先人工核对，不会把系统账号自动当作管理员。

已存在用户会显示 home、shell、sudo、key 数量，不重复创建；普通用户可以在此补 sudo。
`sudo` 一栏表示 sudo 组成员；加固还会验证 `visudo -c` 和实际 `sudo -l -U` 中的常规完整管理员权限。
不会写 NOPASSWD。新加入的组在该用户重新登录后生效。
若创建用户时 `passwd` 失败，保留已创建账号，并提示用 `passwd <user>` 重试；不会删除账号。

公钥授权创建 `.ssh` 700 / `authorized_keys` 600，设置用户 uid/gid，保留已有 key。
预置整个批次先经 `ssh-keygen` 验证再写入；相同“类型 + 公钥数据”即使注释不同也不重复追加。
已有带 options 的合法公钥会计入状态；但受限公钥（如 `from=`、`command=`、`restrict`）不能单独作为管理员安全登录依据。
遇到符号链接或 authorized_keys 硬链接会拒绝写入；不接管其特殊布局。

## SSH 防锁死和恢复

加固用户必须同时满足：

1. 非 root 普通登录账号。
2. 属于 sudo 组、sudo 配置语法正确，并具有常规 `(ALL : ALL) ALL` 或 `(ALL) ALL` 管理权限。
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
- 无活动 `ssh.service` / `sshd.service`，不支持 reload，或服务启动参数/环境文件不能对应到默认 sshd 配置。
- 公钥算法不允许候选管理员的 key，或任何语法/最终值检查失败。

支持常规 `/usr/sbin/sshd -D [$SSHD_OPTS]` systemd 服务；只接受空 SSHD_OPTS 环境文件。
非 systemd LXC 仍可使用用户、公钥、基础初始化和查看状态，但菜单 3 会拒绝执行。不会猜测 reload 命令。

每次真正改 SSH 前，在 `/var/backups/linux-init/ssh-<UTC时间>-<随机后缀>/` 保存主配置和原托管 drop-in（若存在），并记录原文件是否存在。
流程：原配置 `sshd -t` → 备份 → 原子替换 drop-in → `sshd -t` → 全局 `sshd -T` 和 root/候选用户 `sshd -T -C` → 四项及 key 可用性正确 → reload → 活动服务和最终值再次校验。
语法/最终值失败会恢复且不 reload；reload 或后续检查失败会恢复并 reload 原配置。
退出、INT、TERM、HUP 时会回滚尚未完成的事务；不会主动 restart SSH 或终止当前连接。

`sshd -T` 是磁盘配置经 OpenSSH 解析后的值，不是运行中进程的内存快照；服务检查和 reload 之后的真实新连接验证仍必需。
已满足四项目标时显示已禁用并返回，不重复备份、写文件或 reload。已禁用密码但其他目标未满足时，仍需完整检查和确认。

手动恢复时保留当前会话，以 root 执行，先把路径换成本次实际备份目录：

```bash
backup='/var/backups/linux-init/ssh-实际时间和后缀'
if [ "$(cat "$backup/previous-exists")" = 1 ]; then
    cp -p "$backup/00-key-only.conf" /etc/ssh/sshd_config.d/00-key-only.conf
else
    rm -f /etc/ssh/sshd_config.d/00-key-only.conf
fi
/usr/sbin/sshd -t && systemctl reload ssh.service
# 如果实际活动服务名是 sshd.service，上一行改用该名称。
```

不用把备份主配置写回，因为工具从未修改它。断电、SIGKILL 无法触发 Bash trap，仍须依靠保留的会话/Console 和备份人工恢复。
自动回滚若恢复文件或 reload 失败，会明确提示，并停止菜单；不要关闭当前连接。

## 基础环境与兼容范围

- Debian 12/13、Ubuntu 22.04/24.04/26.04，amd64/arm64；其他系统/版本直接拒绝。依赖发行版的 Bash、GNU coreutils、getent、shadow、util-linux 和 apt。
- VPS、独服、KVM/PVE VM、常规 LXC；以实际系统能力为准，不探测厂商，不处理 qemu-guest-agent。
- 基础包：sudo、curl、ca-certificates、git、vim、htop、unzip。只安装尚未安装的包；可选 full-upgrade 会正常升级已安装包。
- 优先 `timedatectl set-timezone UTC`；不可用时备份 localtime/timezone，用现有 tzdata 文件设置 UTC，适用于部分 LXC。
- 不改变 hostname、DNS、网络、防火墙、Docker、RTC 策略，不安装 guest agent，不主动 reboot。
- SSH 禁用只影响 SSH 认证，保留 root/普通用户 Linux 密码与账号、Console 登录和 sudo 密码认证。
- apt full-upgrade 的发行版包维护脚本可能自行 reload/restart 服务或询问配置保留选项；请留意 apt 输出。工具本身不另行修改 SSH 配置。
- 最后按 `/var/run/reboot-required` 提示是否需要重启。没有该标记只是“未检测到标记”，尤其在 Debian 不等同于无需重启的完整证明。

## 测试与上线前验收

本地隔离测试（不需要 sudo）：

```bash
bash -n linux-init/linux-init.sh
bash linux-init/test-linux-init.sh
shellcheck -x linux-init/linux-init.sh linux-init/test-linux-init.sh build-pages.sh
sh build-pages.sh
```

隔离测试只 source 函数，使用临时用户/配置数据和模拟管理命令。
公钥校验及 `sshd -t/-T/-C` 使用真实 OpenSSH，仅读取临时配置/host key，不启动 daemon，不修改宿主机 SSH。
覆盖 root-only、用户筛选、已有用户补 sudo、key 去重/损坏数据/权限/链接、锁定/到期/sudo 策略、Include/cloud-init 冲突、Match/服务参数拒绝、公钥算法拒绝、语法失败、reload 失败、TERM 回滚、process-substitution 重建，以及基础安装/升级确认。
测试脚本和 README 不在 dist 白名单内，Snell 脚本内容保持不变。

当前已在本地 macOS 的 Bash 和 OpenSSH 上运行隔离测试及 ShellCheck；**未完成各 Debian/Ubuntu 版本/架构的真实 VM 安装、systemd reload 和新连接登录验收**。
上述版本列表是实现支持范围，不能据此视为全部已实机验证。

上线前用可销毁、有 Console 的 VM 做矩阵验收，避免在当前生产机上跑修改 SSH 的自动测试：

1. 至少 Debian 13、Ubuntu 24.04；再覆盖 Debian 12、Ubuntu 22.04/26.04，amd64/arm64 和有/无 systemd 的 LXC。
2. 只有 root：菜单 2 和 3 拒绝；菜单 1 创建账号并交互设置密码。
3. 普通用户无 sudo/key：补 sudo → 授权 → 在新终端 `ssh -i <私钥> ppy@<测试机>`，确认 `sudo -v`。
4. 保留旧连接，在菜单 3 确认。新连接公钥应成功；密码、keyboard-interactive 和 root SSH 应拒绝；Console 的 root 密码和用户 sudo 密码应继续有效。
5. 加入 `50-cloud-init.conf` 的 PasswordAuthentication yes，验证工具最终值仍正确；加入更早冲突、Match 或自定义服务选项，验证工具拒绝且不 reload。
6. 模拟配置错误、reload 失败、中途 TERM，核对备份、回滚、服务和原会话。
7. 以普通用户实际执行 `bash <(cat linux-init/linux-init.sh)`，验证 sudo 提权和返回菜单；重复新增相同 key、已有用户、加固和基础初始化，验证幂等。
8. 在测试机拒绝 full-upgrade，检查只执行更新索引、补包和 UTC；允许升级时检查结果和重启标记，确认没有自动 reboot。

## 典型流程

- 全新机器只有 root：创建用户 → SSH Key 授权 → **新终端验证公钥登录和 sudo** → 关闭 SSH 密码登录 → 基础初始化。
- 已有普通用户：如有必要在菜单 1 补 sudo/用 `passwd <user>` 修复本地密码 → 直接授权 → 新终端验证 → 关闭密码。
- 已初始化：重新运行，查看状态或新增用户/key；满足目标的 SSH 配置不重复修改。
- 任意顺序：可先执行基础初始化；未满足用户条件的授权/加固只说明原因并返回菜单，不强制串行跑全部步骤。
