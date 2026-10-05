# 图标与 favicon

dry.li 使用绿色 S3 图标，提供 SVG、PNG 和 ICO 格式。所有图像均为透明背景。

强调色为 `#31721E`。浅色版主体为 `#171816`，深色版主体为 `#F3F2EE`。
SVG 使用原始 RGB 百分比 `rgb(19.2%,44.7%,11.8%)`，PNG 和 ICO 使用对应的 8-bit RGB `(49, 114, 30)`。

## 文件索引

| 目录 | SVG | PNG | ICO |
| --- | --- | --- | --- |
| [默认](../public/assets/) | `logo.svg`，跟随系统深浅色模式 | `favicon-16x16.png`、`favicon-32x32.png`，浅色版 | `favicon.ico`，浅色版 |
| [浅色](../public/assets/light/) | `logo.svg`，固定浅色版 | `favicon-16x16.png`、`favicon-32x32.png` | `favicon.ico` |
| [深色](../public/assets/dark/) | `logo.svg`，固定深色版 | `favicon-16x16.png`、`favicon-32x32.png` | `favicon.ico` |

SVG 使用 `viewBox="0 0 64 64"`，可按需要缩放。每个 ICO 包含 16、32、48、64px 四个尺寸。
PNG 和 ICO 配色固定，不会自动随系统主题变化。

## 网站引用

资源与网站在同一个域名时，在 HTML 的 `<head>` 中添加：

```html
<link rel="icon" href="/assets/favicon.ico" sizes="16x16 32x32 48x48 64x64">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/light/favicon-32x32.png" media="(prefers-color-scheme: light)">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/dark/favicon-32x32.png" media="(prefers-color-scheme: dark)">
<link rel="icon" type="image/svg+xml" href="/assets/logo.svg">
```

网站有独立主题开关时，选择 `/assets/light/logo.svg` 或 `/assets/dark/logo.svg` 与网站当前主题保持一致。
若资源托管在其他域名，将路径替换为对应的完整 HTTPS 地址。

## 更新资源

替换 `public/assets/` 中的对应文件即可，保持默认、浅色和深色三组资源一致。
