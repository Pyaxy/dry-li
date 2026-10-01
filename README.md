# Scripts

个人维护的安装和运维脚本集合。

## 脚本

| 目录 | 用途 | 当前版本 |
| --- | --- | --- |
| [snell-alpine](./snell-alpine/) | Alpine Linux 低空间环境下安装和管理 Snell + ShadowTLS | 1.3.2 |
| [linux-init](./linux-init/) | Debian / Ubuntu 可重复运行的交互式初始化管理菜单 | 1.2.0 |

各脚本的安装方法、兼容范围和注意事项请查看对应目录中的 README。

## Linux 初始化管理菜单

```bash
bash <(curl -fsSL https://install.dry.li/init)
```

支持 Debian 12/13、Ubuntu 22.04/24.04/26.04，amd64/arm64。普通用户会自动通过 sudo 提权。
每项功能独立执行；关闭 SSH 密码登录需要普通 sudo 管理员、有效公钥、安全权限和可用本地密码。
使用前先用新终端验证普通用户公钥登录和 sudo，操作后保留原 SSH 会话再验证。
配置、回滚和隔离测试方式见 [Linux Init README](./linux-init/README.md)。

## 一键运行 Snell Alpine

在 Alpine 服务器上，以 root 用户复制执行：

```sh
sh -c "$(curl -fsSL https://install.dry.li/snell-alpine)"
```

普通用户（已配置 sudo）使用：

```sh
sudo sh -c "$(curl -fsSL https://install.dry.li/snell-alpine)"
```

若提示 `curl: not found`，先以 root 执行 `apk add --no-cache curl ca-certificates`。运行后按菜单选择安装或管理功能，详细说明见 [Snell Alpine README](./snell-alpine/README.md)。
