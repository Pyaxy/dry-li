# dry.li

<img src="./public/assets/favicon.svg" width="48" height="48" alt="dry.li 图标">

个人维护的 Linux 安装与运维脚本，以及 dry.li 的图标和静态资源。

## 脚本

| 项目 | 用途 | 版本 | 文档 |
| --- | --- | --- | --- |
| [Linux Init](./public/linux-init/linux-init.sh) | Debian / Ubuntu 交互式初始化管理菜单 | 1.2.0 | [使用说明](./docs/linux-init.md) |
| [Snell Alpine](./public/snell-alpine/snell-alpine-lowspace.sh) | Alpine Linux 下安装与管理 Snell + ShadowTLS | 1.3.2 | [使用说明](./docs/snell-alpine.md) |

### Linux Init

支持创建用户、配置 sudo、管理 SSH 公钥、关闭 SSH 密码登录、初始化基础环境和查看系统状态。各项功能可独立执行，菜单可重复打开。

适用于 Debian 12/13、Ubuntu 22.04/24.04/26.04，支持 amd64 和 arm64。需要交互终端；普通用户运行时通过 sudo 提权。

```bash
bash <(curl -fsSL https://install.dry.li/init)
```

关闭 SSH 密码登录前，请先在新终端确认普通用户的公钥登录和 sudo 可用，并保留原 SSH 会话。配置、恢复和兼容性边界见 [使用说明](./docs/linux-init.md)。

### Snell Alpine

面向 Alpine Linux 的 Snell + ShadowTLS 管理脚本，支持 Snell v4/v5/v6 多通道、ShadowTLS 配置、OpenRC 服务管理和运行状态检查，适合磁盘空间有限的环境。

在 Alpine 服务器上以 root 运行：

```sh
sh -c "$(curl -fsSL https://install.dry.li/snell-alpine)"
```

已配置 sudo 的普通用户：

```sh
sudo sh -c "$(curl -fsSL https://install.dry.li/snell-alpine)"
```

如缺少 curl，可先以 root 安装：

```sh
apk add --no-cache curl ca-certificates
```

安装要求、配置方式和卸载行为见 [使用说明](./docs/snell-alpine.md)。

## 图标与静态资源

[assets](./public/assets/) 收录 dry.li 的 SVG 图标、深浅色版本、PNG 和 ICO favicon。

- [图标集合](./public/assets/icons/)
- [图标对比图](./public/assets/previews/comparison.svg)
- [文件索引与引用方法](./docs/assets.md)
