# 图标资源

| 目录 | 图标 |
| --- | --- |
| [d-p](./d-p/) | 绿色几何图标 |
| [d-dot](./d-dot/) | D· 字母图标 |
| [p-dot](./p-dot/) | P· 字母图标 |

## D· / P·

`d-dot/`：D·，`p-dot/`：P·。两者共享圆点大小与基线。P 保留正常粗体轮廓与自然宽高比，未横向拉伸。
默认强调色 #31721E；只有圆点使用强调色。

每个站点目录的 logo.svg：透明、无框，主体跟随系统主题。
light/ 与 dark/：固定配色版本。
- logo.svg：主页推荐，无框；紧凑 viewBox，D 宽高比 1.6，P 宽高比 1.44。
- logo-badge.svg：圆角实底，适合头像或独立入口。
- logo-outline.svg：细描边备用，不建议用作小尺寸 favicon。
- logo-full.svg / logo-badge-full.svg：整枚深绿的对照版本。
- favicon.svg / favicon.ico / favicon-16x16.png / favicon-32x32.png：圆角底。

浅色主页主体 #11110F，深色主页主体 #F3F2EE。
圆角底采用相反的主体 / 底色关系，让独立标记边界明确。
ICO 含 16 / 32 / 48 / 64 像素。根目录 favicon 默认为浅色版。
PNG / ICO 不会自动跟随主题，应由网站主题开关选用 light/ 或 dark/。
logo.svg 以 height:24px; width:auto; 放在主页导航中即可；圆角底版本可用 40px 或 48px 正方形。
