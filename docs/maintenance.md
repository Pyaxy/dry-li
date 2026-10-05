# 仓库维护

## 目录

```text
public/                     # 对外发布的脚本和静态资源
  _redirects                # 短链接映射
  assets/                   # 图标和 favicon
  linux-init/               # Linux Init 脚本
  snell-alpine/             # Snell Alpine 脚本
docs/                       # 项目文档
tests/                      # 验证脚本
build-pages.sh              # 将 public/ 复制到 dist/
```

`public/` 是发布目录，其中的文件路径对应站点路径。文档、测试和 Git 元数据不进入发布产物。

## Cloudflare Pages

| 设置 | 值 |
| --- | --- |
| Root directory | 留空 |
| Build command | `sh build-pages.sh` |
| Build output directory | `dist` |

`build-pages.sh` 清理并重建 `dist/`，然后完整复制 `public/`。

## 添加和更新文件

公开脚本放在 `public/<工具名>/`，图标和其他静态资源放在 `public/assets/`。
构建脚本会自动包含新增文件，无需逐个登记。

短链接定义在 `public/_redirects`。例如：

```text
/init /linux-init/linux-init.sh 200
```

更新脚本时保留文件名；部署完成后，同一个入口返回更新后的内容。
README 和测试留在 `public/` 外。默认图标的维护方法见 [资源说明](./assets.md)。

## 本地验证

从仓库根目录执行：

```sh
sh -n build-pages.sh
sh -n public/snell-alpine/snell-alpine-lowspace.sh
sh -n tests/test-snell-binary.sh
bash -n public/linux-init/linux-init.sh
bash tests/test-linux-init.sh
sh build-pages.sh
```

Linux Init 测试使用临时数据和模拟管理命令，不修改本机账号或服务。
Snell 二进制测试需要 Alpine，运行方法见 [Snell Alpine 使用说明](./snell-alpine.md)。
