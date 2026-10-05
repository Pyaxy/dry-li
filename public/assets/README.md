# dry.li · S3

强调色：RGB (0.192, 0.447, 0.118)，8-bit RGB (49, 114, 30)，HEX #31721E。
SVG 保留原始 RGB 百分比，PNG / ICO 按 8-bit 量化。
主体：浅色模式 #171816，深色模式 #F3F2EE。所有图像背景透明。

- 根目录 logo.svg：按系统浅色 / 深色模式自动切换主体颜色。
- 根目录 favicon.ico、favicon-16x16.png、favicon-32x32.png：默认浅色版。
- light/ 与 dark/：独立固定配色版本，均包含 logo.svg 和上述三个 favicon 文件。
- favicon.ico：包含 16、32、48、64 像素四个尺寸。
- PNG 和 ICO 本身不会自动变色；网站应按主题选择对应目录。

网站跟随系统主题时，favicon 可这样引用：

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/light/favicon-32x32.png" media="(prefers-color-scheme: light)">
<link rel="icon" type="image/png" sizes="32x32" href="/dark/favicon-32x32.png" media="(prefers-color-scheme: dark)">
<link rel="icon" type="image/svg+xml" href="/logo.svg">
```

若网站有自己的主题开关，应使用 light/logo.svg 或 dark/logo.svg 与网站当前主题一致。
