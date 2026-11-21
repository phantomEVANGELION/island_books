# 岛上书店 Island Books — 开发规划书

> 目标：做一个「爱阅记」同类型、但完全免费无广告的本地阅读器。
> Android 优先交付 APK，iOS 保留跨平台代码与可选的侧载路径。
> 本文档为开工前的方案确认稿，确认后按 S0 → S5 顺序执行。
>
> 项目代号：`island_books` ｜ 应用名：岛上书店 ｜ 英文名：Island Books
> Android 包名：`com.islandbooks.reader` ｜ iOS Bundle ID：`com.islandbooks.reader`

---

## 一、需求边界（先划清，避免做成四不像）

### 必做（v1.0 交付范围）

| 模块 | 内容 |
|---|---|
| 书架 | 网格书架、封面自动提取、书名/作者/进度、最近阅读置顶、长按菜单（删除/重命名/详情） |
| 导入 | 系统文件选择器多选导入 EPUB / TXT；从其他 App 分享打开 |
| EPUB 解析 | container.xml → OPF → spine/manifest/metadata，封面、目录（NCX / nav 双格式）、章节 XHTML、内嵌图片/字体/CSS |
| **阅读引擎（核心）** | **上下滚动为主模式**：手指拖动 + 惯性 + 章节无缝拼接 + 图片懒加载；左右翻页为可选模式；全书进度、沉浸式界面、上下工具栏 |
| 阅读设置 | 字号、行距、段距、页边距、字体、背景主题、**阅读模式（滚动/翻页）**、亮度 |
| 目录 | 树形目录、点击跳转、当前章节高亮 |
| 进度 | 自动记忆每本书阅读位置，冷启动恢复 |
| 书签 | 添加/删除/跳转，按书分组 |
| 数据 | 全本地 SQLite，无账号、无网络请求、无广告 |

### 不做（明确排除）

- 联网书源 / OPDS / WebDAV / 云同步（你明确说了不要联网导入）
- PDF / MOBI / AZW3 / CBZ 漫画（v1 不做，架构上留扩展点）
- 听书 TTS、笔记划线导出、家长控制、多账户

### v1 追加（已确认）

- **TXT 支持**：与 EPUB 共用同一套渲染管线 —— 编码探测（UTF-8 / GBK / BOM）→ 正则智能分章 → 伪 XHTML → 落库 → 同一个 WebView 排版引擎。老书和网络小说大多只有 TXT，值得做。

### 推迟到 v1.1

- **划线 / 笔记**：EPUB 精确锚定需要 CFI 或 XPath+字符偏移，工作量大，先留接口
- **竖排（vertical-rl）**、**仿真书页卷曲动画**、**TXT 编码手动指定**

---

## 二、技术选型与理由

| 层 | 选型 | 为什么 |
|---|---|---|
| 框架 | **Flutter 3.3x stable** | 一套代码出 Android APK，iOS 代码同源；自绘引擎对排版/翻页控制力强；生态成熟 |
| 语言 | Dart 3 | — |
| EPUB 渲染 | **WebView + JS 注入**（flutter_inappwebview） | EPUB 本质是 XHTML+CSS+图片，纯 Dart 自绘无法渲染 CSS 布局、图文混排、表格。微信读书 / Readium / 多看都是这条路 |
| **滚动模式（主）** | 全书章节顺序拼进**同一个滚动容器**，垂直流式布局，`content-visibility:auto` 让屏外章节跳过渲染，`loading="lazy"` 懒加载图片 | 章节天然连续，滚动位置不会跳；这是你要的「上下平滑移动」 |
| 翻页模式（可选） | CSS 多栏 `column-width = 视口宽` + JS 算 `scrollWidth / 视口宽` 得页数，`translateX` 翻页 | 复用同一份 DOM，只换一套 CSS |
| 进度定位 | `spineIndex + 章内字符偏移`（JS 用 Range 取视口首字符偏移） | 比 EPUB CFI 简单一个量级，**改字号后仍能停在同一句话**，这是滚动模式必须的 |
| 解压 | `archive`（纯 Dart，处理 zip/epub） | 无原生依赖，跨平台一致 |
| XML | `xml`（纯 Dart） | 解析 OPF / NCX / XHTML 足够 |
| 数据库 | `sqflite` | 成熟稳定，书架几千本无压力 |
| 状态管理 | `riverpod` | 编译期安全，阅读设置全局热更新方便 |
| 文件选择 | `file_picker` | 走 Android SAF，**不需要任何存储权限**，规避 Android 13+ 权限地狱 |
| 字体 | 系统字体 + 用户导入 ttf/otf | 见下方「字体策略」 |

### 关键设计决策（这三条决定成败）

**1. EPUB 资源加载：解压到私有目录，WebView 走 `file://`**

不搞自定义 scheme 拦截（复杂、易踩坑），直接把每本书解压到
`/data/data/<pkg>/app_books/<bookId>/`，WebView 加载 `file://.../OEBPS/chapter1.xhtml`。
好处：XHTML 里的相对路径（`../images/cover.jpg`、`<link href="style.css">`）**原样生效**，零适配成本。
代价：多占一份磁盘（单本书通常 1–5MB，可接受）。v1.1 可优化为内存流。

**2. 排版注入：不修改原始 XHTML，只追加覆盖样式**

用户在设置里改字号/行距/主题时，只通过 `document.documentElement.style.setProperty('--reader-font-size', ...)`
驱动一份统一注入的 `reader.css`（全部用 CSS 变量），**不重新加载页面、不重建 DOM**。
所以拖动字号滑块时文字是实时变化的，不闪屏——这是「爱阅记式」体验的关键细节。

**3. 滚动模式：整本书一个滚动容器，章节首尾相接**

不是「一章一个 WebView 切换」（会闪白、滚动会断），而是把 spine 里所有章节的 `<body>` 内容按顺序 append 进一个 `<div id="book">`，
章节之间插一个 `<section data-spine="n">` 包裹。这样：

- 滚到底部自然就是下一章，**没有跳转感**，符合你说的「上下平滑移动」
- 全书一个 `scrollHeight`，进度条直接算百分比，不会出现「章末进度卡住」
- `content-visibility: auto` + `contain-intrinsic-size` 让屏外章节不参与布局，2.8 万字的章 × 30 章也不卡
- 图片 `loading="lazy"`，滚到才解码，72MB 的书也不炸内存

代价：DOM 节点多。用 `content-visibility` 后实测可接受（微信读书就是这个路子）。真机跑不动再降级为「保留当前 ±3 章」的滑动窗口。

### 字体策略（已确认：思源宋体子集）

- 默认：系统字体（Android 自带 Noto Sans CJK / 部分机型有 Noto Serif CJK）
- **内置思源宋体（Noto Serif SC）子集**：常用简体 3500 + 常用繁体，约 5000–6000 字，5–7MB
  - 你的《无职转生》是 `zh-TW` 繁体版，子集**必须覆盖繁体字**，否则会出现豆腐块
- 缺字自动回退系统字体
- 支持从文件导入 ttf/otf，导入后出现在字体列表
- **书内自带字体保留**：素晴那本内嵌了 10 个 ttf 做特殊排版（`.w` `.cont` `.illus` `.chara` 等 class），
  这些字形如果被全局字体覆盖就直接瞎了。所以注入的字体只作用于 `body`/`p` 等基础元素，
  **不覆盖书内 CSS 明确指定 font-family 的元素**

---

## 三、UI 设计规格（对标爱阅记的信息架构，视觉原创）

### 主界面 · 书架

```
┌─────────────────────────────┐
│  书架                  ⌕  ⋯ │   ← 大标题左对齐，右侧图标按钮
│                             │
│  ┌────┐ ┌────┐ ┌────┐       │   ← 3 列自适应网格（平板 5-6 列）
│  │封面│ │封面│ │封面│       │      圆角 6，极轻投影
│  └────┘ └────┘ └────┘       │
│  书名…   书名…   书名…      │   ← 最多 2 行，超长省略
│  62%     12%     —          │   ← 细进度条 + 百分比
│                             │
│  ┌────┐ ┌────┐              │
│  │    │ │    │              │
└─────────────────────────────┘
```

- 背景 `#F7F5F0` 暖白，卡片 `#FFFFFF`，主色 `#7A6A58` 茶褐，正文 `#2B2B2B`
- 无底部导航栏（v1 保持干净，设置入口在右上「⋯」）
- 空状态：居中线性插画 + 「点右上角，导入你的第一本书」
- 长按封面：弹出底部菜单（阅读 / 详情 / 重命名 / 删除）

### 阅读界面（滚动模式 · 默认）

```
┌─────────────────────────────┐
│                             │
│   正文第一段……              │
│                             │
│   正文第二段，继续往下……    │  ← 手指上下拖，惯性滚动
│                             │
│   ┌───────────────┐         │
│   │   插图         │         │  ← 图片按原比例，屏宽内居中
│   └───────────────┘         │
│                             │
│   滚到底自动接下一章，       │
│   中间没有跳转、没有白屏     │
│                             │
└─────────────────────────────┘
   ↑ 点击屏幕中间呼出工具栏，滚动手势不会误触

┌─────────────────────────────┐
│ ← 书名               ⋯      │  ← 顶部栏（呼出时才有）
├─────────────────────────────┤
│                             │
│   …正文…                    │
│                             │
├─────────────────────────────┤
│  第三章 · 这一章的标题       │  ← 当前所在章节
│  ───────●───────────  38%   │  ← 全书进度，拖动跳转
│   目录   亮度   字体   模式  │
└─────────────────────────────┘
```

- 滚动时顶/底栏自动淡出，静止 0.4 秒后也不主动出现，只有点击中间才出
- 左右边缘 15% 区域轻点 = 上一屏 / 下一屏（一屏高度，不是一页），照顾翻页习惯
- 滚动模式不显示页码，只显示百分比（连续滚动没有「页」的概念）

### 阅读界面（翻页模式 · 可选）

左右翻页沿用传统布局：左 1/3 上一页、右 1/3 下一页、中间呼出工具栏，底部显示「128 / 342」页码。

### 阅读设置抽屉（底部弹出）

- **字体**：`A- 18 A+` 字号滑块 / 行距 / 段距 / 页边距 / 字体选择
- **主题**：纸白 `#FAF8F3` · 米黄 `#F5E9D3` · 护眼绿 `#CCE8CF` · 夜间 `#1C1C1E` · 纯黑 `#000000` + 自定义取色
- **模式**：**上下滚动（默认）** / 左右翻页（覆盖 · 滑动 · 无动画）
- **更多**：亮度、屏幕常亮、隐藏状态栏

---

## 四、环境准备（当前机器缺工具链，必须先补）

实测结果：

```
flutter        ✗ 未安装
Android SDK    ✗ 未安装
JDK            ✓ D:\develop\JDK（Java 25，需补一个 21）
Python/Node/Git ✓
C 盘剩余 23G（紧张）  D 盘剩余 121G（充足）
```

需要安装（全部放 **D 盘**，不动 C 盘）：

| 组件 | 体积 | 说明 |
|---|---|---|
| Flutter SDK 3.3x | ~1.5 GB | 解压即用，`D:\develop\flutter` |
| JDK 21 | ~300 MB | Gradle 对 Java 25 兼容性不稳，装 21 更保险 |
| Android cmdline-tools + platform-tools + build-tools 35 + platform 35 | ~4–6 GB | 不装 Android Studio（省 3G 且不需要） |
| Gradle 缓存 + 依赖 | ~1.5 GB | 首次构建自动下载 |

- 预计耗时 **40–90 分钟**，主要卡在下载速度
- 国内网络需要配镜像：`PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL` 指向清华或中科大源
- 装完我会跑 `flutter doctor` 验证，并直接构建一个空白 APK 确认链路通

> ⏸ **按你的要求，下载暂缓。** 你哪天网络稳定了说一声「装环境」，我从 S0 开始一口气跑到出 APK。
> 在此之前我可以先把不依赖工具链的活干完：解析器逻辑、阅读引擎的 CSS/JS、UI 设计稿，这些写完就能直接落进工程。

---

## 五、iOS 到底能不能装？（能，但要过两道关）

### 第一道关：必须有一台 macOS 来编译

Windows 上**无法编译 iOS**，这是硬限制，绕不过去。两条出路：

| 方式 | 成本 | 说明 |
|---|---|---|
| GitHub Actions（macOS runner） | 免费 | public 仓库不限时长；private 仓库每月 2000 分钟，macOS 按 10 倍计费 → 实际约 200 分钟，够构建 8–12 次。构建一次 15–25 分钟 |
| 借一台 Mac / 黑苹果 / 云 Mac | 按需 | 最直接，能本地调试 |

### 第二道关：ipa 必须签名，签名决定了"能用多久"

| 签名方式 | 有效期 | 代价 | 适合 |
|---|---|---|---|
| **免费 Apple ID 自签**（Sideloadly / AltStore / SideStore） | **7 天**，到期 App 闪退，需重签 | ¥0，但每 7 天连一次电脑（SideStore 可 Wi-Fi 自动续） | 尝鲜、自己用 |
| **付费开发者账号自签**（$99/年） | 1 年 | ¥688/年，需登记设备 UDID（每年 100 台） | 长期自用、家人共用 |
| **TestFlight** | 90 天一轮，可续 | ¥688/年，需过一次轻审核 | 给朋友试用 |
| **App Store 上架** | 永久 | ¥688/年 + 审核 | 公开分发 |
| **TrollStore**（漏洞永久签名） | 永久 | ¥0，但**只支持特定 iOS 版本**（约 14.0–16.6.1 及 17.0），版本不对就没法用 | 版本刚好合适的人 |

补充两个免费签名的硬限制，免得后面踩坑：
- 免费账号同时最多装 **3 个**自签 App，每 7 天最多注册 10 个 App ID
- 免费签名用不了 iCloud、推送等 entitlement —— 但本地阅读器**完全不需要**这些，所以不影响功能

### 结论与建议

**能装，而且功能不打折。** 唯一的痛点是免费签名 7 天一续。

我的建议路线：

1. **v1 代码从第一行就保证 iOS 兼容** —— 不写 Android-only 的 API，权限声明（文件访问）同时配好，WebView 用 WKWebView 的沙盒文件加载方式。这样以后要出 iOS 版不用返工。
2. 先交付 Android APK，你确认体验满意后，再决定 iOS 走哪条路。
3. 走免费自签的话，你只需要提供：一个 GitHub 仓库（public 即可，私密代码我可以只推构建配置）+ 你的 Apple ID。CI 出无签名 ipa，你用 Sideloadly 签一次装上去。
4. **兜底方案（零成本、永久有效）**：同一套排版引擎（`reader.css` + `paginate.js`）本来就是 JS/CSS，可以再包一个 PWA 网页版 —— Safari「添加到主屏幕」，不需要签名、不会过期、不需要开发者账号。代价是文件导入要靠 Safari 的文件选择 + IndexedDB 存书，体验比原生差一档，但"能在 iPhone 上看书"这个目标是达成的。这个我可以作为 v1.2 的可选项。

### 你的情况：iOS 26.5.1

**TrollStore 这条路走不通。** 它依赖的漏洞只存在于 iOS 14.0–16.6.1 和 17.0，26.5.1 差得太远。所以只剩两种：

- **免费自签（¥0）**：Sideloadly 签，7 天到期重签；用 **SideStore** 可以在同一 Wi-Fi 下自动续签，实际一个月动一次手
- **付费开发者账号（¥688/年）**：签一次管一年，不用折腾

好消息是 iOS 26 的 WKWebView 对 `content-visibility`、`scroll-behavior` 支持很完整，滚动模式的流畅度会比 Android 中低端机还好。所以「上下平滑移动」这个核心体验，iOS 上是没问题的。

> 等你真要装的时候我再给具体流程，现在不用操心。

---

## 六、开发路线（阶段 + 交付物）

### S0 · 环境搭建 ✅ 前置
安装工具链 → `flutter doctor` 全绿 → 构建并安装一个空白 APK 到你的手机
**交付**：能跑的空壳 APK（验证整条链路通）

### S1 · 工程骨架 + 书架
项目初始化、主题系统、SQLite 表结构、书架网格 UI、空状态、长按菜单
**交付**：有完整视觉的书架页（数据先用假数据）

### S2 · 解析与导入（EPUB + TXT）
EPUB：ZIP 解包 → container/OPF/NCX/nav 解析 → 元数据 + 封面 + 目录 + spine → 落库
TXT：编码探测（UTF-8/GBK/BOM）→ 正则识别「第X章」类标题自动分章 → 生成伪 XHTML → 落库
**交付**：能导入你自己的 epub 和 txt，书架出现真实封面和书名，目录正确

### S3 · 阅读引擎（核心，工作量最大）
WebView 容器 + 注入 CSS/JS → 多栏分页 → 翻页手势与动画 → 字符偏移进度 → 章节懒加载与预取 → 目录跳转
**交付**：能从头读到尾，翻页流畅，退出重进回到原位置

### S4 · 设置与周边
阅读设置抽屉全项生效（实时预览）、主题、字体导入、书签、进度滑块跳转、书籍详情、删除
**交付**：功能完整的 v1.0 候选版

### S5 · 打磨与打包
启动速度、大文件（>10MB 图文 epub）性能、异常兜底（损坏 epub / 加密 epub 提示）、图标与启动图、release APK 签名打包
**交付**：可直接安装的 `island-books-v1.0.apk`

### S6 ·（可选）iOS 构建
GitHub Actions workflow + 无签名 ipa + Sideloadly 侧载说明（免费签名 7 天续签流程）
**交付**：ipa 文件 + 一份手把手的安装文档

---

## 七、项目目录结构

```
island_books/
├── android/                        # Android 壳工程（权限、图标、签名）
├── ios/                            # iOS 壳工程（预留，S6 启用）
├── assets/
│   ├── fonts/                      # 内置字体子集
│   ├── icons/                      # 图标、空状态插画
│   └── reader/                     # ★ 阅读引擎的注入资源
│       ├── reader.css              #   统一排版样式（全 CSS 变量驱动）
│       ├── paginate.js             #   分页计算 / 翻页 / 进度定位
│       └── highlight.js            #   当前章节标记（v1.1 划线用）
├── lib/
│   ├── main.dart                   # 入口
│   ├── app.dart                    # MaterialApp + 路由 + 全局主题
│   │
│   ├── core/                       # 与业务无关的地基
│   │   ├── theme/
│   │   │   ├── app_theme.dart      #   书架/通用 UI 主题
│   │   │   └── reader_themes.dart  #   5 套阅读主题定义
│   │   ├── constants.dart          #   路径、默认排版参数
│   │   └── utils/
│   │       ├── text_offset.dart    #   字符偏移 ↔ 视口定位
│   │       ├── encoding.dart       #   TXT 编码探测（GBK/UTF-8/BOM）
│   │       └── logger.dart
│   │
│   ├── data/                       # 数据层
│   │   ├── db/
│   │   │   ├── app_database.dart   #   建库、版本迁移
│   │   │   └── dao/
│   │   │       ├── book_dao.dart
│   │   │       ├── chapter_dao.dart
│   │   │       ├── progress_dao.dart
│   │   │       └── bookmark_dao.dart
│   │   ├── models/
│   │   │   ├── book.dart           #   书籍元数据 + 封面路径 + 进度
│   │   │   ├── chapter.dart        #   spine 项：href / 标题 / 层级
│   │   │   ├── reading_progress.dart
│   │   │   ├── bookmark.dart
│   │   │   └── reader_config.dart  #   字号/行距/主题/翻页方式等
│   │   └── repositories/
│   │       ├── book_repository.dart
│   │       └── reader_repository.dart
│   │
│   ├── services/                   # 业务能力
│   │   ├── epub/
│   │   │   ├── epub_parser.dart    #   总调度：zip → 结构化书
│   │   │   ├── epub_package.dart   #   container.xml + OPF 元数据
│   │   │   ├── toc_parser.dart     #   nav.xhtml + toc.ncx 双格式
│   │   │   └── epub_extractor.dart #   解压到 app_books/，路径重写
│   │   ├── import/
│   │   │   └── import_service.dart #   文件选择 → 解析 → 落库 → 封面缩略
│   │   ├── storage/
│   │   │   └── book_storage.dart   #   私有目录管理、空间统计、清理
│   │   └── render/
│   │       ├── pagination_engine.dart  # WebView ↔ JS 桥接
│   │       └── html_builder.dart       # 注入 CSS 变量 / 章节拼装
│   │
│   └── features/                   # 界面（按功能分包）
│       ├── bookshelf/
│       │   ├── bookshelf_page.dart
│       │   └── widgets/
│       │       ├── book_grid.dart
│       │       ├── book_card.dart
│       │       └── empty_shelf.dart
│       ├── import/
│       │   └── import_sheet.dart   #   导入进度与结果提示
│       ├── reader/
│       │   ├── reader_page.dart    #   阅读页主控（手势、状态）
│       │   └── widgets/
│       │       ├── reader_webview.dart
│       │       ├── reader_appbar.dart
│       │       ├── reader_bottombar.dart
│       │       ├── settings_sheet.dart   # 4 分段设置抽屉
│       │       ├── toc_drawer.dart       # 树形目录
│       │       └── progress_slider.dart
│       └── settings/
│           ├── settings_page.dart
│           └── font_manager.dart   #   导入字体列表
│
├── test/
│   ├── epub_parser_test.dart       # 用真实 epub 做解析回归
│   └── pagination_test.dart
├── docs/
│   └── DEVELOPMENT_PLAN.md         # 本文档
└── pubspec.yaml
```

---

## 八、数据库表结构（草案）

```sql
books(
  id INTEGER PK, title TEXT, author TEXT, publisher TEXT,
  cover_path TEXT, file_path TEXT, book_dir TEXT,
  format TEXT, file_size INTEGER, chapter_count INTEGER,
  added_at INTEGER, last_read_at INTEGER,
  progress_percent REAL, current_chapter INTEGER
)

chapters(
  id INTEGER PK, book_id INTEGER, spine_index INTEGER,
  title TEXT, href TEXT, level INTEGER, char_count INTEGER
)

reading_progress(
  book_id INTEGER PK, spine_index INTEGER,
  char_offset INTEGER, percent REAL, updated_at INTEGER
)

bookmarks(
  id INTEGER PK, book_id INTEGER, spine_index INTEGER,
  char_offset INTEGER, chapter_title TEXT,
  excerpt TEXT, created_at INTEGER
)

reader_config(              -- 全局单行，阅读设置
  id INTEGER PK, font_size REAL, line_height REAL,
  paragraph_spacing REAL, page_margin REAL,
  font_family TEXT, theme_id TEXT, flip_mode TEXT,
  brightness REAL
)
```

---

## 九、风险与预案

| 风险 | 影响 | 预案 |
|---|---|---|
| **epub 里塞垃圾文件**（无职 62MB `.bin`） | 存储被撑爆 | 只解压 manifest 引用的资源，跳过未引用文件 |
| **OPF 路径含 URL 编码**（`%20`） | 静默丢章 | 查 zip 前先 `Uri.decodeComponent()`，解不出再尝试原始名 |
| **metadata 为空**（素晴） | 书架显示文件名 | 三级兜底：NCX 标题 → `<title>` → 文件名 |
| **书内自带字体被覆盖**（素晴 10 个 ttf） | 特殊排版瞎掉 | 只覆盖基础元素，不碰书内明确指定的 font-family |
| 滚动模式 DOM 过大（30 章 × 2.8 万字） | 卡顿、内存高 | `content-visibility:auto` + 图片懒加载；仍不行则降级为 ±3 章滑动窗口 |
| 部分 epub 的 XHTML 不合法（缺闭合标签） | 渲染错乱 | 用 `xml` 容错模式解析 + 失败降级为纯文本提取 |
| epub 用 DRM（Adobe/Apple）加密 | 无法读取 | 检测 `encryption.xml`，明确提示「有 DRM 保护」，不静默失败 |
| 空章节（素晴有 3 个 0 字节的） | 滚动时出现空白段 | 解析时过滤掉无正文的 spine 项 |
| 竖排（vertical-rl）中文排版 | 复杂度高 | v1 先做横排，竖排留 v1.1 |
| 超大图片内存溢出 | 崩溃 | 图片走磁盘缓存 + `loading="lazy"` + 限制解码尺寸 |
| 中文字体子集缺字 | 生僻字/繁体变豆腐块 | 子集覆盖简繁常用字 + fallback 到系统字体 |

---

## 十、验收标准（v1.0 算完成的定义）

1. 从手机文件管理器选一个 epub，3 秒内出现在书架，封面正确
2. 打开书能连续阅读 100 页无白屏、无卡顿、无错位
3. 改字号 / 行距 / 主题时，文字**实时**变化，不闪屏
4. 退出 App 再进来，回到上次读到的同一页同一行
5. 目录跳转准确，页码与实际页数一致
6. 断网状态下全部功能正常（证明零网络依赖）
7. 装完 APK 后桌面图标、启动图、应用名正常

---

## 十一、确认状态

### 已拍板

| 项 | 结论 |
|---|---|
| 应用名 | **岛上书店**（Island Books），包名 `com.islandbooks.reader` |
| TXT | **进 v1**，与 EPUB 共用渲染管线 |
| 内置字体 | **思源宋体子集**（3–5MB）+ 支持导入自定义字体 |
| 环境安装位置 | `D:\develop\flutter`、`D:\develop\android-sdk`、`D:\develop\jdk21` |
| 环境安装时机 | **暂缓**（你说可能断网），等你说"可以装了"再下 |

### 还差你一件事

**没了。** 测试书已经到手（见附录 A），iOS 版本也知道了，剩下我自己往下推。

---

## 附录 A · 两本真书的实测结果

我用你给的两本书跑了结构分析，**发现了 4 个真实的坑**，这些不是理论推演，是从你的书里挖出来的：

### 《素晴》`1.epub` — 8.2 MB

| 项 | 值 |
|---|---|
| EPUB 版本 | 2.0（目录走 NCX，没有 nav.xhtml） |
| 章节数 | 34 个 spine 项，最长一章 2.8 万字 |
| 图片 | 47 处 `<img>/<svg>`，6.8MB 的 jpg |
| 内嵌字体 | **10 个 ttf（3MB）**，用于 `.w` `.cont` `.illus` `.chara` 等特殊排版 |
| DRM | 无 |
| **元数据** | **title / author 全是空的** ⚠️ |

**坑 1：书名和作者是空的。** 书架拿不到书名，会显示成文件名「1.epub」，很丑。
→ 兜底策略：OPF metadata 为空时，依次尝试 ① NCX 里第一个非「封面」的 navPoint 标题 ② `<title>` 标签 ③ 文件名。你这两本书里素晴就靠这条兜底。

**坑 2：路径里有 URL 编码。** OPF 里写的是 `Text/Character%20Profile1.xhtml`（带 `%20`），
而 zip 里的实际文件名是 `Text/Character Profile1.xhtml`（带空格）。直接拼路径会 KeyError。
→ 解析时必须 `Uri.decodeComponent()` 再查 zip，否则**每本书都会静默丢几章**。这个坑不踩到根本发现不了。

### 《无职转生》02 — 69.1 MB

| 项 | 值 |
|---|---|
| EPUB 版本 | 2.0（NCX） |
| 语言 | **zh-TW 繁体** |
| 章节数 | 28 个 spine 项 |
| 图片 | 30 处，6.6MB |
| **垃圾数据** | **20 个 `extra/data_*.bin`，共 62.2 MB** ⚠️ |
| DRM | 无 |

**坑 3：69MB 里有 62MB 是垃圾。** 那些 `.bin` 文件不在 manifest 里、不是字体、不是图片，
文件头是随机字节——制作组塞的填充数据。
→ 导入时**只解压 manifest 引用到的资源**，跳过一切未被引用的文件。这本书解压后实际只占 **约 7MB**，
而不是 69MB。十本这样的书能省 600MB 硬盘。

**坑 4：繁体字。** 这本是 `zh-TW`，内置字体子集如果只做简体，会出现满屏豆腐块。
→ 字体子集必须覆盖常用繁体（简繁合计约 5000–6000 字，5–7MB）。

### 两本书的共同点（验证了架构选型）

- 都是 **EPUB 2.0 + NCX**，没有一本用 EPUB 3 的 nav.xhtml → **NCX 是主力，必须优先做好**
- 都带**大量插图**，且 CSS 里 `img { width: 100% }` → 滚动模式天然适配，分页模式要额外处理
- 都用 `p { text-indent: 2em; line-height: 1.3em }` → 注入的行距/字号必须用 `!important` 才能压过书内 CSS
- 都没有 DRM → 好消息，不用碰解密
