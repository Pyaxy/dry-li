# 图标与 favicon

资源来自 `dry-li-finalists-vectors.zip`。压缩包内的 40 个图标 SVG 和 1 张对比图均原样保留，只调整存放目录。
浅色版本使用深色图形，适合浅色背景；深色版本使用浅色图形，适合深色背景。

## 原始图标

| 目录 | 款式 | 文件名前缀 |
| --- | --- | --- |
| [s3-reference](../public/assets/icons/s3-reference/) | S3 原方向，默认款 | `dry-li-s3-reference` |
| [s3-ridge](../public/assets/icons/s3-ridge/) | M1 原峰 | `dry-li-s3-ridge` |
| [mountain-offset](../public/assets/icons/mountain-offset/) | M2 偏峰 | `dry-li-mountain-offset` |
| [mountain-cut](../public/assets/icons/mountain-cut/) | M3 切峰 | `dry-li-mountain-cut` |
| [mountain-double](../public/assets/icons/mountain-double/) | M4 双峰 | `dry-li-mountain-double` |

每组均含 8 个文件：默认 64px SVG、红色点缀 64px SVG，以及浅色/深色各 16、32、64px SVG。
原始文件名保持不变。所有文件使用 `viewBox="0 0 64 64"`，可按需要缩放。

[查看原始对比图](../public/assets/previews/comparison.svg)。

## 默认 favicon

| 发布路径 | 内容 |
| --- | --- |
| `/assets/favicon.svg` | 原样复制 S3 原方向默认 SVG |
| `/assets/favicon-dark.svg` | 原样复制 S3 原方向深色 64px SVG |
| `/assets/favicon.ico` | 从默认 SVG 导出的透明背景 ICO，含 16、32、48px |
| `/assets/favicon-32.png` | 从默认 SVG 导出的 32px PNG |

PNG 和 ICO 为确定性格式转换，没有重新绘制或改变原始图形。
`public/_redirects` 为 `/favicon.svg` 和 `/favicon.ico` 提供短入口，实际资源仍存放在 `assets/`。

网站与资源在同一个域名时，可在 HTML 的 `<head>` 中添加：

```html
<link rel="icon" href="/assets/favicon.ico" sizes="16x16 32x32 48x48">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml" media="(prefers-color-scheme: light)">
<link rel="icon" href="/assets/favicon-dark.svg" type="image/svg+xml" media="(prefers-color-scheme: dark)">
```

若网站与资源域名不同，将 `href` 改为资源所在域名的完整 HTTPS 地址。
这些资源会随同一 Pages 项目发布；哪个域名绑定这个项目，哪个域名就能提供这些路径。

## 新增和更新

- 新图标放进 `public/assets/icons/`，其他公开资源也放在 `public/assets/` 下。
- 不需要修改 `build-pages.sh`；提交、推送并部署成功后即可访问。
- 更换默认款时，同步替换两个默认 SVG 和导出的 PNG/ICO，保持对外路径不变。
- 不要将说明、测试、私钥或其他不应公开的文件放进 `public/`。
