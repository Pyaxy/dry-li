# 图标与 favicon

图标按款式存放在 `assets/`，各系列包含 SVG、PNG、ICO 及深浅色版本。

## 系列

| 目录 | 图标 | 特征 |
| --- | --- | --- |
| [d-p](../public/assets/d-p/) | 绿色几何图标 | 方形轮廓与斜向强调色 |
| [d-dot](../public/assets/d-dot/) | D· | 粗体 D 与绿色圆点 |
| [p-dot](../public/assets/p-dot/) | P· | 粗体 P 与绿色圆点 |

各系列的 `logo.svg` 跟随系统深浅色模式；`light/` 和 `dark/` 提供固定配色版本。
默认 PNG、ICO 以及 D· / P· 的默认 `favicon.svg` 为浅色版本。

## D· / P· 文件

每个字母系列的根目录包含 `logo.svg`、`favicon.svg`、`favicon.ico`、`favicon-16x16.png` 和 `favicon-32x32.png`。

`light/` 与 `dark/` 中还提供以下 SVG 款式：

| 文件 | 用途 |
| --- | --- |
| `logo.svg` | 无框字母标记，适合导航栏 |
| `logo-badge.svg` | 圆角实底，适合头像和独立入口 |
| `logo-outline.svg` | 细描边版本 |
| `logo-full.svg` | 整枚深绿的无框版本 |
| `logo-badge-full.svg` | 整枚深绿的圆角版本 |
| `favicon.svg` | 圆角实底 favicon |

PNG 提供 16px 和 32px 两种尺寸，每个 ICO 包含 16、32、48、64px 四种尺寸。
无框 D· 的宽高比为 1.6，P· 为 1.44；引用时使用 `height` 和 `width: auto` 保持比例。

几何系列的配色和格式说明见 [d-p 资源说明](../public/assets/d-p/README.md)。

## 网站引用

以 D· 为例，资源与网站在同一个域名时，在 HTML 的 `<head>` 中添加：

```html
<link rel="icon" href="/assets/d-dot/favicon.ico" sizes="16x16 32x32 48x48 64x64">
<link rel="icon" type="image/svg+xml" href="/assets/d-dot/light/favicon.svg" media="(prefers-color-scheme: light)">
<link rel="icon" type="image/svg+xml" href="/assets/d-dot/dark/favicon.svg" media="(prefers-color-scheme: dark)">
```

导航栏标记可使用：

```html
<img src="/assets/d-dot/logo.svg" alt="dry.li" style="height: 24px; width: auto;">
```

使用 P· 时将路径中的 `d-dot` 换成 `p-dot`。
网站有独立主题开关时，根据当前主题选择 `light/` 或 `dark/` 中的文件。
若资源托管在其他域名，将路径替换为对应的完整 HTTPS 地址。
