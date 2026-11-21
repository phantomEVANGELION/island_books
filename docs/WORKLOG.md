# 岛上书店 · 工作日志 / 开发交接文档

> **这份文档的用途**：让任何一个新接手的 agent（或人）只读这一份 md，就能完整理解项目、
> 继续改代码、重新出包。
>
> **维护约定**：
> - 每次改代码，必须在文末「修改日志」追加一条，写清 **目的** 和 **改动位置**。
> - 改了架构、数据表、通信协议这类结构性内容，要同步更新对应章节，不能只写日志。
>
> **最后更新**：2026-11-18

---

## 0. 快速上手（新 agent 先读这段）

```bash
cd D:/develop_new/island_books/src
./build.sh debug            # 编译 Android debug 包（环境变量已在脚本里处理好）
```

**三个必须知道的约束**（不知道会浪费大量时间）：

1. **默认不开代理**，所以构建走国内镜像：pub 用 `pub.flutter-io.cn`，
   Gradle 用阿里云源（配置在 `~/.gradle/init.gradle`）。
   **需要直连时跟主人说一声，他会开梯子**，然后 `NO_MIRROR=1 ./build.sh` 即可切回官方源。
   什么时候需要直连：镜像上找不到某个依赖版本（pub 404 / Gradle Could not resolve）、
   或者要拉 CocoaPods 之类的东西。
2. 这台机器**用户名是中文「无名客」**，`PUB_CACHE` 必须指向英文路径（脚本里已设 `D:\develop\pub_cache`），
   否则 CMake/ninja 编 C++ 时报「文件名、目录名或卷标语法不正确」。
3. 项目路径本身含中文的风险已通过 `android.overridePathCheck=true` 绕过。

**改动阅读器代码后，必须意识到有两份副本**：`assets/reader/*`（源）和
每本书目录下的 `<bookDir>/reader.js|css`（副本）。App 启动时由
`BookshelfPage._syncAllReaderAssets()` 全量覆盖，所以改完要重新装包并**冷启动一次**才会生效。

---

## 1. 项目速览

| 项 | 值 |
|---|---|
| 名称 | 岛上书店 / `island_books` |
| 类型 | 本地 EPUB / TXT 阅读器，纯离线，无账号无网络 |
| 技术栈 | Flutter + 原生 WebView 渲染正文（排版全部由注入的 CSS/JS 负责） |
| 版本 | `1.0.0+1`（`pubspec.yaml`） |
| Flutter | **3.47.9 stable**，Dart 3.13.7，revision `c197ca5199e9ee5661e865596c9c07294dfab51c` |
| Android 包名 | `com.islandbooks.island_books` |
| iOS Bundle ID | `com.islandbooks.islandBooks`（Sideloadly 签名后会加后缀，实际装成 `...islandBooks.A22544WJTK`） |
| iOS 最低版本 | 15.0（`ios/Runner.xcodeproj` 的 `IPHONEOS_DEPLOYMENT_TARGET`） |
| 代码规模 | Dart 约 4455 行；reader.js 1148 行；reader.css 739 行 |
| 资源 | 3 个中文字体共 41MB，位于 `assets/fonts/` |

### 为什么用 WebView 而不是纯 Flutter 排版

中文长文排版（首行缩进、避头尾、行距、分页锚点）用 Flutter 的 `Text` 很难做到和纸书一致，
而且**改字号时保持阅读位置**在 Flutter 里几乎无解。用 HTML 后：改 CSS 变量即可实时重排，
位置靠 DOM 锚点计算。代价是要处理 WebView 的平台差异（见第 10 节）。

---

## 2. 目录结构

```
island_books/
├── build.sh                     # Android 构建脚本（封装了三个环境变量陷阱）
├── pubspec.yaml                 # 依赖与资源声明
├── assets/
│   ├── reader/
│   │   ├── reader.js            # 阅读引擎（核心，1148 行）
│   │   └── reader.css           # 阅读样式（739 行）
│   └── fonts/                   # NotoSerifSC / HanyiSentyTang / SentyWEN2017
├── lib/
│   ├── main.dart                # 入口，只做 runApp
│   ├── app.dart                 # MaterialApp，固定浅色主题
│   ├── core/theme/app_theme.dart        # 配色 AppColors / 阅读主题 ReaderTheme / kSerifFamily
│   ├── core/utils/natural_sort.dart     # 「第2卷」<「第10卷」的自然排序
│   ├── data/
│   │   ├── db/app_database.dart         # SQLite 建表与迁移（version 4）
│   │   ├── models/                      # Book / Chapter / Bookmark / BookGroup / ReadingProgress / ReaderConfig(遗留未用)
│   │   └── repositories/book_repository.dart  # 所有 DB 读写
│   ├── features/
│   │   ├── bookshelf/bookshelf_page.dart      # 书架（1744 行，最复杂的 UI 文件）
│   │   └── reader/
│   │       ├── reader_page.dart               # 阅读页（317 行，WebView 容器 + 通信）
│   │       └── image_viewer_page.dart         # 插图全屏查看（缩放/平移）
│   └── services/
│       ├── epub/epub_parser.dart              # OPF/NCX 解析
│       ├── epub/epub_extractor.dart           # 解压 + 封面提取
│       ├── import/import_service.dart         # 导入编排
│       ├── lan/lan_server.dart                # 局域网传书（HttpServer）
│       └── render/
│           ├── reader_html_builder.dart       # 生成 index.html（关键）
│           └── font_service.dart              # 字体分发 + @font-face 生成
├── ios/                         # iOS 工程（已做适配，见第 10、11 节）
├── android/                     # Android 工程
└── docs/
    ├── IOS_BUILD.md             # iOS 构建与分发的详细说明
    └── WORKLOG.md               # 本文档
```

---

## 3. 运行架构

```
┌──────────────────────────── Flutter ────────────────────────────┐
│ BookshelfPage (书架)                                             │
│   ├─ BookRepository ──> SQLite (island_books.db)                │
│   ├─ ImportService ──> EpubParser → EpubExtractor →             │
│   │                     ReaderHtmlBuilder → <docs>/books/<id>/  │
│   └─ LanServer (HttpServer:8080) ──> 电脑浏览器拖 epub            │
│                                                                  │
│ ReaderPage (阅读页)                                              │
│   ├─ WebViewController ──> <bookDir>/index.html                 │
│   │     └─ reader.css + reader.js + OEBPS/ 图片                  │
│   └─ JavaScriptChannel "IslandReaderChannel" <──> reader.js     │
└──────────────────────────────────────────────────────────────────┘
```

### 启动流程

1. `main()` → `WidgetsFlutterBinding.ensureInitialized()` → `runApp(IslandBooksApp)`
2. `BookshelfPage.initState()` 里并发做两件事：
   - `_syncAllReaderAssets()`：把 `assets/reader/*` 覆盖到**所有**书目录（这是修 bug 的关键，见第 13 节坑 1）
   - `_load()`：查库、算分组树、取最近阅读
3. 点开一本书 → `ReaderPage._boot()`：
   - 检查 `<bookDir>/index.html` 是否存在
   - `_syncReaderAssets()` 再覆盖一次（保险）
   - `_initWebView()` → 加载页面 → 页面 `init()` 完成后回调 `onReady`
   - `onReady` 时 Flutter 侧做三件事：`_restoreProgress()`、`_loadBookmarks()`、`_injectFonts()`

### 数据存放位置

| 平台 | 根目录 | 说明 |
|---|---|---|
| Android | `/data/data/com.islandbooks.island_books/app_flutter/` | `getApplicationDocumentsDirectory()` |
| iOS | `<App沙盒>/Documents/` | 同上，且因 `UIFileSharingEnabled` 会在「文件」App 里可见 |

```
<docs>/
├── books/<bookId>/          # 一本书一个目录
│   ├── index.html           # 所有章节拼成的单页
│   ├── reader.css / reader.js   # 引擎副本（每次启动被覆盖）
│   ├── cover.jpg            # 封面（有则）
│   └── OEBPS/...            # 解压出来的原始资源（图片、书内 css）
├── fonts/                   # 3 个内置字体（41MB，全局共享一份）
└── covers/                  # 用户自定义封面
```

> `bookId` 是 `DateTime.now().microsecondsSinceEpoch`，纯数字，避免中文路径问题。

---

## 4. 数据层

### 4.1 SQLite 表结构（`lib/data/db/app_database.dart`，version 4）

**books**

| 列 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK | 自增 |
| title / author | TEXT | |
| cover_path | TEXT | 封面文件绝对路径，可空 |
| file_path | TEXT | **原始导入文件的路径**。iOS 上指向系统临时目录，会被清理，目前只作记录不参与阅读 |
| book_dir | TEXT | 解压目录绝对路径，阅读只认这个 |
| format | TEXT | `epub`（TXT 也走同一套，存为 epub 结构） |
| file_size / chapter_count | INTEGER | |
| added_at / last_read_at | INTEGER | 毫秒时间戳 |
| progress_percent | REAL | 冗余字段，书架显示用 |
| current_chapter | INTEGER | spine 序号 |
| group_id | INTEGER | NULL = 顶层书架 |
| sort_order | INTEGER | 手动拖动排序用，初始值 = added_at |

**chapters**：`book_id, spine_index, title, href, level, char_count`，索引 `(book_id, spine_index)`

**reading_progress**：`book_id PK, spine_index, char_offset, percent, updated_at`
> 一本书只有一行，是「最后阅读位置」的唯一真相来源。

**bookmarks**：`id, book_id, spine_index, char_offset, chapter_title, excerpt, percent, created_at`

**groups**：`id, name, parent_id, sort_order, created_at, cover_path`（支持多级）

**迁移策略**：全部用 `ALTER TABLE ADD COLUMN` 增量，**从不删表**，保证老用户数据不丢。
加新字段时记得同时在 `_onCreate` 和 `_onUpgrade` 里都加。

### 4.2 BookRepository 方法（`lib/data/repositories/book_repository.dart`）

| 分类 | 方法 |
|---|---|
| 书 | `listBooks({groupId, sort})`、`listRecentBooks`、`getBook`、`insertBook`、`renameBook`、`moveBookToGroup`、`deleteBook`、`updateSortOrders`、`setBookCover` |
| 章节 | `insertChapters`、`getChapters` |
| 进度 | `saveProgress({bookId, spineIndex, charOffset, percent})`、`getProgress(bookId)` |
| 书签 | `listBookmarks`、`addBookmark`、`deleteBookmark`、`findBookmarkNear` |
| 分组 | `listGroups`、`createGroup`、`renameGroup`、`deleteGroup`、`setGroupCover` |

`deleteBook` 会同时删目录（`book_dir` 整个 `Directory.delete(recursive: true)`），
`groups` 删除时子书/子分组如何处理见实现。

---

## 5. 导入管线

```
FilePicker.pickFiles(epub/txt)
  └─ ImportService.importEpub(File)
       ├─ ZipDecoder().decodeBytes()            // archive 包，纯 Dart
       ├─ EpubParser.parse()                    // 读 META-INF/container.xml → OPF → spine/manifest/NCX
       │    └─ 产出 EpubPackage{title, author, chapters[], cssHrefs[], opfDir, hasDrm}
       ├─ EpubExtractor.extract()               // 解压全部资源到 <bookDir>/OEBPS...
       ├─ EpubExtractor.extractCover()          // 找封面图另存为 cover.jpg
       ├─ ReaderHtmlBuilder.build()             // 生成 index.html（见第 6 节）
       └─ repo.insertBook() + insertChapters()
```

**TXT 也走这条路**：先被包装成最小的 epub 结构（单章），再进同一条管线。

**DRM 检测**：`pkg.hasDrm` 为真直接拒绝导入并提示。

**路径重写**（`ReaderHtmlBuilder._rewriteUrls`）：章节里的 `src/href` 是相对**章节所在目录**的，
内联进根目录的 index.html 后会失效，所以逐章用 `p.posix.normalize(p.posix.join(chapterDir, value))`
重算成相对书籍根目录的路径；`http/https/data/#/javascript/mailto` 开头的一律跳过。

---

## 6. 阅读引擎（核心，改 bug 大多在这里）

### 6.1 index.html 的结构

所有章节拼成**一个页面**（滚动模式要求章节首尾相接，一章一个 WebView 会闪白）：

```html
<div id="book">
  <section class="ch" data-spine="0" data-title="第一章">...</section>
  <section class="ch" data-spine="1" data-title="第二章">...</section>
  ...
</div>

<div id="hud" class="hud hidden">        <!-- 工具栏：顶部条 + 底部条 -->
<div class="toc-mask hidden" id="tocMask"> <!-- 目录遮罩 -->
<aside class="toc hidden" id="toc">       <!-- 目录抽屉（含「书签」Tab） -->
<div id="panel" class="panel hidden">     <!-- 设置面板：字号/字体/主题/行距/段距/边距/翻页开关 -->
<script id="toc-data" type="application/json">[...]</script>
<script src="reader.js"></script>
```

**为什么章节用 `<section>` 而不是分页**：`data-spine` 是定位的坐标系原点，
所有「恢复到第几章第几个字」都靠它。

### 6.2 reader.css 的关键规则（改动前务必理解）

| 规则 | 作用 / 为什么这么写 |
|---|---|
| `html, body { overflow-x: hidden !important }` | 禁掉横向拖动。**只给 html 加不够**，真正溢出的是 body |
| `#book, #book * { box-sizing: border-box }` + `#book * { max-width: 100% }` | 书自带 CSS 常用「固定宽度 + 大左内边距」，content-box 下会顶出屏幕，底部冒出横向滚动条 |
| `::-webkit-scrollbar { width:0; height:0; display:none }` | 隐藏原生滚动条（阅读器不需要可见滚动条） |
| `html { overflow-anchor: none }` | 关掉浏览器滚动锚定，否则改字号时浏览器会自己调 scrollTop，跟手动恢复打架 |
| `.hud { pointer-events: none }` + `.hud > * { pointer-events: auto }` | HUD 是全屏 fixed 层，本身必须穿透 |
| `.hud.hidden { opacity: 0; pointer-events: none }` | **隐藏时必须同时禁点击**，否则透明层仍盖住正文，点底部会命中进度滑块（历史 bug） |
| `.font-btn[aria-pressed="true"] { box-shadow: inset 0 0 0 2px }` | 用 inset 而不是 outline，因为 `.font-row` 有 `overflow-x:auto`，outline 会被裁掉 |
| `.panel-row + .panel-row { margin-top: 14px }` | 字号行和字体行之间的呼吸感 |
| 所有可调项走 CSS 变量 `--r-*` | JS 只改变量 → 实时重排，不重载页面 |

主题用 `html[data-theme="..."]` 切换 5 套变量：`paper / sepia / green / night / black`。

### 6.3 reader.js 模块划分

| 分区 | 行号 | 内容 |
|---|---|---|
| 通信 | 24 | `notifyFlutter(name, data)`，兼容 `IslandReaderChannel` 和 `flutter_inappwebview` 两套 |
| 持久化 | 39 | `localStorage["island.reader.cfg"]` 存 `state`（字号/字体/主题等） |
| 应用样式 | 50 | `apply({keepPosition})` 把 state 写成 CSS 变量 |
| **锚点** | 75–218 | `sectionOf / captureAnchor / caretAt / scanTextFrom / restoreAnchor` |
| 进度 | 219–278 | `currentSection / updateProgress / savePosition` |
| 跳转 | 279–342 | `scrollToPercent / restoreProgress / jumpToSection` |
| HUD | 343–473 | `ensureDom / showHud / hideHud / setPanel / toggleHud` |
| 点击分区 | 474–566 | `handleTap` |
| 工具栏交互 | 579 | 字号加减、字体切换、主题、滑块 |
| 目录抽屉 | 590–667 | `buildToc / openToc / closeToc / markTocActive` |
| 书签 | 684–947 | `toggleBookmark / renderBookmarks / jumpToOffset / excerptAt` |
| 设置面板 | 974 | 显隐与模式（font / theme 两组行） |
| 长按图片 | 1028 | 通过 `elementFromPoint` 找 `img`，回调 Flutter |
| 初始化 | 1089 | `init()` |

### 6.4 位置锚定与恢复（最容易改坏的地方）

**存位置**：滚动时 `updateProgress()` 取「视口顶部第一行文字」，用 `TreeWalker` 遍历文本节点
累加字符数，得到 `(spineIndex, charOffset)`，再算 `percent`，通过 `onProgress` 发给 Flutter 落库。

**恢复位置**：`restoreProgress(spine, offset, percent)`
1. 先 `jumpToOffset(spine, offset)`：找到该 section 的第 offset 个字符，用 `Range.getBoundingClientRect()`
   算出绝对 Y，`window.scrollTo(0, absTop - 90)`
2. 等 `#book img` 全部 load（最多等 1.5s，防止图片撑高页面导致位置偏）
3. 700ms 后再校正一次
4. `percent` 只在 spine/offset 缺失时兜底

**关键保护**：`var restoring = false` —— 恢复过程中 `savePosition()` 直接 return，
否则会把「恢复瞬间的错误位置」存进库，导致**每次打开都漂移**（历史 bug，见第 13 节）。

### 6.5 点击分区与手势

`handleTap(x, y)` 的判断顺序：

1. 500ms 内刚显隐过 HUD → 忽略（防抖，否则状态反复横跳）
2. `elementFromPoint` 命中 `.hud/.panel/.toc/.toc-mask` → 忽略
3. HUD 开着 → 点正文就收起（连面板一起）
4. 最右 12% → 完全忽略（留给系统返回手势）
5. **`tapToTurn === false` 时**：只要 `y < innerHeight - 150` 就 `showHud()` 然后 return
   —— 即「关掉点击翻页后，点哪里都只呼出工具栏，不跳页」。底部 150px 是工具栏地盘，点了不响应
6. `tapToTurn === true` 时：左 1/3 上翻、右 1/3 下翻、中间呼出 HUD

**书签手势**：从屏幕右侧 55%~88% 起手、向左滑超过 `max(28, min(56, w*0.08))` px、
垂直位移 < 水平位移 0.8 倍、时长 < 800ms → 加书签（再滑一次删）。

### 6.6 设置项

`DEFAULTS = { fontSize:18, lineHeight:1.8, paraSpacing:0.8, pageMargin:20, theme:'paper', tapToTurn:true, fontFamily:'' }`

存在 `localStorage["island.reader.cfg"]`，**所有书共用一个 key**（因为书都用同一个 origin）。
阅读位置**不存这里**（历史 bug：共用 key 会导致换书跳到上一本书的位置），位置只走 SQLite。

---

## 7. Flutter ↔ JS 通信协议

通道名固定：**`IslandReaderChannel`**，消息体一律 `JSON.stringify({name, data})`。

### JS → Flutter（`reader_page.dart::_handleMessage`）

| name | data | 触发时机 | Flutter 处理 |
|---|---|---|---|
| `onReady` | `{}` | 页面 init 完成 | 恢复进度 + 推书签 + 注入字体 |
| `onProgress` | `{spine, offset, percent}` | 滚动停下 | `repo.saveProgress()` 落库 |
| `onBack` | `{}` | 点 HUD 返回键 | `Navigator.maybePop()` |
| `onAddBookmark` | `{spine, offset, title, excerpt, percent}` | 滑动手势加书签 | 写库后回推全量书签 |
| `onRemoveBookmark` | `{id}` 或 `{spine, offset}` | 再滑一次 | 删库后回推 |
| `onImageLongPress` | `{src}` | 长按插图 | 打开 `ImageViewerPage` |

### Flutter → JS（`window.IslandReader.*`）

| 方法 | 用途 |
|---|---|
| `setConfig(cfg)` | 应用设置（字号/主题/字体…） |
| `getPosition()` | 取当前位置（备用） |
| `jumpTo(spine)` | 跳到某章 |
| `scrollToPercent(p)` | 按百分比跳（兜底用） |
| `restoreProgress(spine, offset, percent)` | **主恢复入口** |
| `setBookmarks(list)` | 全量覆盖书签 |
| `toggleBookmark()` | 触发书签手势逻辑 |

> 改协议时两边必须同步改，且注意 `_handleMessage` 里是 `if/else if` 链，
> 新增分支不要漏掉 `data is Map` 的类型判断。

---

## 8. 字体系统

`lib/services/render/font_service.dart`

| family | 文件 | 面板上的名字 |
|---|---|---|
| `ReaderSerif` | `NotoSerifSC-Regular.otf` (24MB) | 宋体 |
| `ReaderTang` | `HanyiSentyTang.ttf` (12MB) | 闲情 |
| `ReaderWen` | `SentyWEN2017.ttf` (5.6MB) | 文楷 |

**为什么复制到文档目录**：WebView 加载 `<bookDir>/index.html`，用 `file://` 直接读 `assets/`
需要 `allowFileAccessFromFileURLs`（新版 Android 默认关闭且插件不暴露）。复制到
`<docs>/fonts/` 后，用相对路径 `../../fonts/xxx.ttf` 引用，同源无权限问题。

**注入方式**：运行时 `runJavaScript` 往 `head` 插一个 `<style id="islandFonts">`，
而不是写进 index.html —— 这样**老书不用重新导入**也能用上新字体。

**踩过的坑**：早期「文楷」指向一个已被删除的字体文件，`@font-face` 加载失败后静默回落系统衬线体，
表现为「根本不是文楷」。排查这类问题要看 Network 里 ttf 请求是否 200。

---

## 9. 书架功能（`bookshelf_page.dart`）

- **视图**：列表 / 网格切换；分组可逐级进入
- **排序**：最近阅读 / 文件名（自然排序，`第2卷` < `第10卷`）/ 手动拖动
- **最近阅读**：顶部横排
- **导入**：`FilePicker` 多选 epub/txt
- **长按菜单**：改名、换封面、移动到分组、删除
- **多选模式**：批量移动 / 删除
- **分组**：新建、重命名、换封面、删除
- **换封面**：`ImagePicker` 从相册选，压到 1400px、质量 88，存 `<docs>/covers/`
- **局域网传书**：`LanServer` 在 8080 起 HttpServer，电脑浏览器拖文件 → `_onLanUpload`
- **布局设置**：列表/网格、每行数量等

> 这个文件 1744 行，改之前先搜方法名定位，别整篇读。

---

## 10. 平台差异（Android vs iOS）

| 点 | Android | iOS |
|---|---|---|
| **WebView 加载书籍** | `controller.loadFile(htmlPath)`（file:// + allowFileAccess） | `controller.platform.loadFileWithParams(WebKitLoadFileParams(absoluteFilePath: html, readAccessPath: <docs>))` |
| 为什么不一样 | Android WebView 默认允许 file:// 读同域资源 | **WKWebView 会拒绝 file:// 页面的所有子资源**（CSS/JS/图片/字体）。必须用 `loadFileURL:allowingReadAccessTo:`，且读权限目录要覆盖 `books/` 和 `fonts/`，所以授权到 `<docs>` 根 |
| 字体相对路径 | `../../fonts/x.ttf` | 同（因为 readAccessPath 已覆盖 `<docs>`） |
| 相册选图 | 无需声明 | 必须 `NSPhotoLibraryUsageDescription`，否则闪退 |
| 局域网服务 | 无需声明 | 必须 `NSLocalNetworkUsageDescription`（iOS 14+） |
| 返回键 | 系统返回键（`PopScope`/默认行为） | 无硬件返回键，靠 HUD 左上角 `onBack`；侧滑返回由 Flutter 路由提供 |
| 衬线字体 | `fontFamily: 'serif'` 可用（映射 Noto Serif） | **不认通用族名**，会静默回落黑体 → 用 `kSerifFamily`（iOS 取 `Songti SC`） |
| 状态栏 | `SafeArea(top: false)` + HTML 里 `env(safe-area-inset-top)` | 同；HTML 已带 `viewport-fit=cover` |
| 文件可见性 | 沙盒私有 | `UIFileSharingEnabled` 使 Documents 在「文件」App 可见 |

**`kSerifFamily` 定义在 `lib/core/theme/app_theme.dart`**，是 `final`（依赖 `Platform.isIOS`），
用到它的 `TextStyle` 不能写 `const`。

---

## 11. 构建与部署

### 11.1 Android 本地构建

```bash
cd D:/develop_new/island_books/src
./build.sh debug      # 或 ./build.sh release
```

脚本内部已处理：PATH 加 flutter、ANDROID_HOME、`PUB_HOSTED_URL` 镜像、
`PUB_CACHE=D:\develop\pub_cache`。产物在 `build/app/outputs/flutter-apk/app-debug.apk`。

**切直连**（已开代理时）：

```bash
NO_MIRROR=1 ./build.sh debug
```

会同时跳过 pub 镜像和 `~/.gradle/init.gradle` 里的阿里云源。镜像缺包时用这个排查。

> **冷构建偶发失败**：项目换目录后第一次构建（依赖需要重新解析）有概率在
> `assembleDebug` 阶段失败，报错通常指向某个镜像仓库超时。**直接重跑一次即可**，
> 第二次一般 70 秒内完成。这不是代码问题，别去改配置。

> debug 包 225MB（含调试符号与三套 ABI），release 会小很多。

### 11.2 连接手机（无线 ADB）—— 最容易卡住的一步

**这台机器的 5037 端口被某个杀不掉的进程占用**，所以所有 adb 命令都要带 `-P 5038`。

### 为什么「一直连不上」——先看这一条

这个环境里**每执行一条命令都是一个新 shell，adb daemon 会跟着 shell 一起被杀掉**。
于是上一条命令里 `connect` 成功的设备，下一条命令里 `adb devices` 就是空的，
表现就是「明明连上了，下一条又说找不到设备」。

**唯一的解法：把 `connect` 和真正要执行的命令写在同一条命令里。**

```bash
export PATH="$PATH:/d/develop/android-sdk/platform-tools"; export MSYS_NO_PATHCONV=1
adb -P 5038 connect 10.136.63.59:46141 >/dev/null 2>&1
adb -P 5038 -s 10.136.63.59:46141 shell getprop ro.product.model
```

### 完整流程（2026-11-19 实测通过）

手机：设置 → 开发者选项 → 无线调试

```bash
export PATH="$PATH:/d/develop/android-sdk/platform-tools"
export MSYS_NO_PATHCONV=1          # 防止 Git Bash 把 /sdcard/... 转成 Windows 路径

IP=10.136.63.59                    # 无线调试主页显示的 IP
PAIR_PORT=37193                    # 「使用配对码配对设备」弹窗里的端口
CONN_PORT=46141                    # 无线调试主页显示的端口
CODE=798947                        # 6 位配对码

# ① 先试直连（这台电脑配对过的话，可能一步就成）
adb -P 5038 connect $IP:$CONN_PORT

# ② 失败再配对（配对码只在弹窗打开期间有效，且只能用一次）
adb -P 5038 pair $IP:$PAIR_PORT $CODE

# ③ 再连
adb -P 5038 connect $IP:$CONN_PORT

# ④ 确认：状态必须是 device
adb -P 5038 devices
```

### 失败症状对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| `unknown host service` / `adb server version doesn't match` | 5037 被别的程序占用 | 所有命令加 `-P 5038` |
| `failed to connect to ...` | 还没配对，或端口填错 | 先 `pair`；注意配对端口 ≠ 连接端口 |
| `protocol fault (couldn't read status)` | 把**连接端口**当成配对端口用了 | 换成弹窗里显示的那个端口 |
| `adb devices` 显示 `offline` / `unauthorized` | 手机没点「允许 USB 调试」 | 看手机弹窗，勾「始终允许」 |
| 上一条能连、下一条 `device not found` | daemon 随上一条 shell 退出了 | 把 connect 和业务命令写在一起 |
| `devices` 空且 `mdns services` 也空 | 无线调试没开，或不在同一网段 | 检查 WiFi；IP 变了要重新取 |

> **端口和 IP 每次都会变**：手机关掉再开无线调试，连接端口就换了；换 WiFi/热点 IP 也会换。
> 配对记录是持久的（写进手机），所以**只需要重新 `connect`，不用重新配对**。
> 最近两次成功的地址：`10.136.63.59:46141`（11-19）、`10.130.106.71:38171`（11-16）。

其他常用：

```bash
adb -P 5038 -s <dev> logcat -c                                  # 清日志
adb -P 5038 -s <dev> logcat -d | grep "\[sync\]"                # 看引擎同步日志
adb -P 5038 -s <dev> shell input tap X Y                        # 模拟点击
adb -P 5038 -s <dev> exec-out screencap -p > /d/develop/s.png   # 截图
adb -P 5038 -s <dev> shell run-as com.islandbooks.island_books sh -c '...'  # 看沙盒文件
```

> 屏幕物理分辨率 1440×3200，CSS 像素 384×837（devicePixelRatio 3.75）。
> 截图里估坐标要乘 3.75。

### 11.3 iOS 构建与分发（实际走过的路径）

详细版见 `docs/IOS_BUILD.md`，这里只记结论。

**已经跑通的方案：朋友在 Mac 上出未签名 ipa → 用户在自己 Windows 上用 Sideloadly 签**

```bash
# 朋友（Mac，不需要 Apple ID）
flutter pub get
flutter build ios --release --no-codesign
cd build/ios/iphoneos
mkdir -p Payload && cp -r Runner.app Payload/
zip -r island_books.ipa Payload
```

```text
# 用户（Windows）
Sideloadly 安装位置：D:\develop\Sideloadly\sideloadly.exe
① 手机 USB 连电脑，点「信任此电脑」
② 手机开「开发者模式」（设置 → 隐私与安全性 → 开发者模式 → 重启）
③ 拖入 ipa，填自己的 Apple ID（开了双重验证要用 App 专用密码）
④ Start
⑤ 手机：设置 → 通用 → VPN与设备管理 → 开发者 App → 信任
```

**实测信息（2026-11-17）**

| 项 | 值 |
|---|---|
| 手机 | 凤凰院凶真的 iPhone，`iPhone18,2`，iOS 26.5.1 |
| UDID | `00008150-0012290E0183C01C` |
| 签名后 Bundle ID | `com.islandbooks.islandBooks.A22544WJTK`（自动 Bundle ID 加的后缀） |
| 签名账号 | `phantomvangelion@outlook.com` |
| 有效期 | **7 天**，到期用 Sideloadly 重签一次，数据不丢 |
| Sideloadly 日志 | `D:\develop\Sideloadly\sideloadlydaemon.log`（能看到设备、安装记录、Bundle ID） |

**不需要 UDID 的方案**：TestFlight（需要朋友的付费账号）。**只有 Ad Hoc 才需要登记 UDID。**

**坑**：给 `sideloadly.exe` 传中文路径的 ipa 作为命令行参数会**直接崩退**，必须手动拖入窗口。

**iTunes 不用装**：`Apple Mobile Device Support` 已存在（驱动+服务），Sideloadly 只依赖它。

---

## 12. 调试手册

### 12.1 调 WebView 里的 JS（最强手段）

```bash
export PATH="$PATH:/d/develop/android-sdk/platform-tools"
adb -P 5038 connect <ip>:<port>
adb -P 5038 -s <dev> shell cat /proc/net/unix | grep -o "webview_devtools_remote_[0-9]*" | sort -u
adb -P 5038 -s <dev> forward tcp:9222 localabstract:webview_devtools_remote_<pid>
```

然后可用现成脚本（放在 `D:/develop_new/island_books/debug/`）：

| 脚本 | 用途 |
|---|---|
| `cdp.js "<js表达式>"` | 在页面里执行一段 JS 并打印结果 |
| `tap.js X Y` | 用 CDP 派发一次触摸并读状态 |
| `probe.js` | 监听 console / 异常，同时触发一次点击 |

> 注意：`adb forward` 会随 daemon 退出失效，**connect + forward + node 必须写在同一条命令里**。

**用它能查的东西**：`document.body.scrollWidth`（横向溢出）、`elementFromPoint(x,y)`（点击落点）、
`getComputedStyle`（真实渲染值）、`.hud` 的 class 状态。

### 12.2 读日志

```bash
adb -P 5038 -s <dev> logcat -d | grep "\[sync\]"     # 引擎同步
adb -P 5038 -s <dev> logcat -d | grep -i chromium    # WebView
```

### 12.3 一个反直觉的教训

**不能靠截图取色判断工具栏是否显示** —— `.hud` 的背景色和纸张色是同一个 `#FAF8F3`。
必须查 `document.querySelector('.hud').className`。

---

## 13. 踩过的坑（改代码前先看这里，能省几小时）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 「改了代码但手机上没效果」 | `_syncAllReaderAssets()` 只比较 `reader.js` 长度，只改 CSS 时直接 `continue`，CSS 永远同步不进手机 | 改成 js/css **分别**判断、分别写入 |
| 2 | 打开任意书都跳到 64~72%，再点会抖 | 恢复时先 `scrollTo(0,0)` 做「归零校准」，画面闪到封面；且 `scrollToPercent` 在图片加载前算错 `scrollHeight`，错误位置又被存回库，形成累积漂移 | 去掉归零；改用 spine+charOffset 锚点；加 `restoring` 标志禁止恢复期间存位置；等图片 load 后再定位 |
| 3 | 点屏幕下方冒蓝条并跳页 | `.hud.hidden` 只设了 `opacity:0`，透明全屏层仍可点，命中了进度滑块 | `.hud.hidden { pointer-events:none }` + `.hud.hidden > * { pointer-events:none }` |
| 4 | 字体选中框上方显示不全 | 用 `outline`（向外扩），被 `.font-row` 的 `overflow-x:auto` 裁掉 | 改 `inset box-shadow` |
| 5 | 5 个字体按钮放不下，「文楷」被截一半 | padding 太大 | `.font-btn` padding 从 `7px 13px` 改 `7px 9px` |
| 6 | 字号 >18 时能左右拖动，底部还有横条 | 书自带 CSS 给章标题「固定宽度 + 48px 左内边距」，content-box 下顶出屏幕 | `box-sizing:border-box` + `#book * { max-width:100% }` + html/body 都禁 `overflow-x` + 隐藏滚动条 |
| 7 | iOS 上阅读器白屏/无样式 | `loadRequest(Uri.file())` 在 WKWebView 里拒绝所有 file:// 子资源 | 改 `loadFileWithParams` + `readAccessPath=<docs>` |
| 8 | iOS 上字体全不生效 | `loadFile` 默认只授权 index.html 所在目录，`../../fonts/` 在沙盒外 | 同上，把读权限放大到 `<docs>` |
| 9 | iOS 书架标题变黑体 | iOS 不认 `fontFamily: 'serif'` 通用族名 | 引入 `kSerifFamily`（iOS → `Songti SC`） |
| 10 | 「文楷」根本不是文楷 | 指向了已删除的字体文件，`@font-face` 静默失败回落系统衬线体 | 换成真实字体文件，并检查 ttf 请求是否 200 |
| 11 | `flutter test` 报错 | 模板残留 `test/widget_test.dart` 引用了不存在的 `MyApp` | 删除该文件 |
| 12 | Sideloadly 启动即崩 | 命令行传了中文路径的 ipa | 手动拖入 |

---

## 14. 修改日志

> 格式：`日期 | 目的 | 改动位置`
> 新的写在最上面。

### 2026-11-19 · 补全无线 ADB 连接文档（另一次 agent 连不上的复盘）

- **目的**：别的 agent 接手时连不上手机，说明原文档没把最关键的一点讲透 ——
  adb daemon 会随每条命令的 shell 一起退出，导致「上一条连上、下一条就没了」。
- **改动位置**：`docs/WORKLOG.md` 第 11.2 节
  - 新增「为什么一直连不上」小节 + 一条命令内完成 connect 的模板
  - 新增 2026-11-19 实测通过的完整命令块（含 IP/配对端口/连接端口变量）
  - 新增「失败症状对照表」6 条
  - 补充「配对记录持久，重开无线调试只需重新 connect」
- **验证**：本次实际连接成功（`10.136.63.59:46141`，Xiaomi 2410DPN6CC / Android 16）

### 2026-11-18 · 修正「代理」相关说明 + 加直连开关

- **目的**：之前误判为「这台机器访问不了 Google」，实际是**默认没开代理**，
  主人随时可以开。为避免以后照文档走弯路，修正说明并加一个切换开关。
- **改动位置**：
  - `build.sh`：新增 `NO_MIRROR=1` 分支（跳过 pub 镜像变量），并在头部注释写清何时需要开代理
  - `~/.gradle/init.gradle`：顶部加 `if (System.getenv('NO_MIRROR') == '1') return`，
    直连时自动跳过阿里云源（备份在同目录 `init.gradle.bak`）
  - `docs/WORKLOG.md`：第 0 节、11.1 节同步更新
- **验证**：默认镜像模式构建通过（首次冷构建因镜像超时失败一次，重跑 69.7s 成功）

### 2026-11-18 · 项目归档重组（路径变更）

- **目的**：项目文件散落在 `D:\develop` 各处（源码、备份、原型、调试脚本、构建日志混在一起），
  统一归口到 `D:\develop_new\island_books\`，并清掉临时产物。
- **改动位置**：
  - 源码：`D:\develop\projects\island_books` → `D:\develop_new\island_books\src`
  - 备份：→ `D:\develop_new\island_books\backups\island_books_20261118_1902`
  - iOS 交接包：→ `D:\develop_new\island_books\dist\island_books_ios.zip`
  - 调试脚本：→ `D:\develop_new\island_books\debug\`（cdp.js / tap.js / probe.js）
  - 图标源稿：→ `D:\develop_new\island_books\assets-source\icon-drafts`
  - HTML 原型：→ `prototype\`、`prototype-mushoku\`
  - 原型构建脚本：→ `tools\`
  - 规划书：→ `src\docs\DEVELOPMENT_PLAN.md`
  - 已删除：旧源码目录（含 2.3G build 缓存）、b43~b47.log、check.css、ui.xml、
    grid.png/grid2.png、dl 里的 Sideloadly 安装包
- **注意**：Flutter SDK / Android SDK / pub_cache / Sideloadly 仍在 `D:\develop\` 下，**未移动**。
  `build.sh` 里的 `PUB_CACHE=D:\develop\pub_cache` 因此无需改动。
- **验证**：新位置 `flutter pub get` + `flutter analyze` 通过（0 error），D 盘可用空间 74.9G → 77.2G

### 2026-11-18 · 建立工作日志 + 全量备份

- **目的**：主人要求在做新一轮优化前留好备份，并建立一份能让其他 agent 接手的详细文档。
- **改动位置**：
  - 备份：`D:/develop_new/island_books/backups/island_books_20261118_1902`（101 个文件，42.8MB，
    已排除 `build/`、`.dart_tool/`、`.idea/`、本机路径文件）
  - 新增 `docs/WORKLOG.md`（本文档）
- **代码未改动**。

### 2026-11-16 · iOS 适配审查与修复

- **目的**：让项目能在 iOS 上编译并真正可用。
- **改动位置**：
  - `lib/features/reader/reader_page.dart`：iOS 改用 `loadFileWithParams(WebKitLoadFileParams(...))`，
    读权限放大到文档根目录（原来用 `loadRequest`，会导致子资源全部加载失败）
  - `pubspec.yaml`：新增直接依赖 `webview_flutter_wkwebview: ^3.27.2`
  - `ios/Runner/Info.plist`：加 `NSPhotoLibraryUsageDescription`、`NSLocalNetworkUsageDescription`、
    `ITSAppUsesNonExemptEncryption=false`；`CFBundleDisplayName` 改「岛上书店」；
    移除无接收逻辑的 `CFBundleDocumentTypes`
  - `lib/core/theme/app_theme.dart`：新增 `kSerifFamily`
  - `lib/features/bookshelf/bookshelf_page.dart`：4 处 `fontFamily:'serif'` → `kSerifFamily`
  - `test/widget_test.dart`：删除
  - `lib/services/import/import_service.dart`：删无用 import
  - `docs/IOS_BUILD.md`：重写为完整构建与分发说明
- **验证**：`flutter analyze` 零 error；Android 包编译并真机回归通过

### 2026-11-16 · 底部横向滚动条（横向溢出）修复

- **目的**：字号放大后阅读页能左右拖动，且屏幕底部出现一条贯穿全宽的横条。
- **改动位置**：`assets/reader/reader.css`
  - `html, body { overflow-x: hidden !important; max-width: 100% !important }`
  - `#book, #book * { box-sizing: border-box }`、`#book * { max-width: 100% !important }`
  - `html/body/#book` 的 `::-webkit-scrollbar { width:0; height:0; display:none }`
  - 撤销误加的 `#progress { display: none }`
- **验证**：字号 28/30px 下 `body.scrollWidth == clientWidth == 384`，截图确认底部无横条

### 2026-11-16 · 引擎同步逻辑修复

- **目的**：解决「改了 CSS 但手机上没变化」。
- **改动位置**：`lib/features/bookshelf/bookshelf_page.dart::_syncAllReaderAssets()`
  —— js/css 分别比较长度、分别写入，任一变化才写。
