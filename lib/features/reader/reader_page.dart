import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'image_viewer_page.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
// iOS 侧要用 WebKitLoadFileParams 指定沙盒读权限目录。
// 这个包只带 darwin 原生实现，在 Android 上不会注册，Dart 代码可以照常编译。
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/book.dart';
import '../../data/models/bookmark.dart';
import '../../data/models/text_rule.dart';
import '../../data/repositories/book_repository.dart';
import '../../services/render/font_service.dart';
import '../../services/render/text_edit_service.dart';

/// 阅读页：本质是一个全屏 WebView，排版全部由注入的 reader.css / reader.js 负责。
///
/// Flutter 这边只做三件事：给容器、收进度、处理返回。
class ReaderPage extends StatefulWidget {
  final Book book;

  const ReaderPage({super.key, required this.book});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  final _repo = BookRepository();

  /// 本次进入阅读页的开始时间（用于累计阅读时长）
  DateTime? _readStart;
  WebViewController? _controller;
  bool _error = false;
  String? _errorMsg;
  double _brightness = 1.0;
  String _chapterName = '';
  bool _chromeVisible = false;
  bool _selVisible = false;
  /// 正文的字号 / 行距（由 WebView 同步上来，用来算书籍名栏该多高）
  double _readerFontSize = 18;
  /// 实测「上一行字形底 → 下一行字形顶」的间距
  double _readerLineGap = 6;
  String _themeId = 'paper';

  String get _htmlPath => p.join(widget.book.bookDir, 'index.html');

  @override
  void initState() {
    super.initState();
    // 阅读页沉浸式：隐藏系统状态栏（时间/信号/电池），由顶部章节名区替代
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addObserver(this);
    _readStart = DateTime.now();
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _flushReadTime();
    } else if (state == AppLifecycleState.resumed) {
      _readStart = DateTime.now();
    }
  }

  /// 把这段阅读时间累加进 books.read_seconds（太短的不记，避免误触把时长刷成天文数字）
  void _flushReadTime() {
    final start = _readStart;
    _readStart = DateTime.now();
    if (start == null) return;
    final secs = DateTime.now().difference(start).inSeconds;
    final id = widget.book.id;
    if (id == null || secs < 3) return;
    _repo.addReadSeconds(id, secs);
  }

  @override
  void dispose() {
    _flushReadTime();
    WidgetsBinding.instance.removeObserver(this);
    // 退出阅读页恢复系统状态栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 打开书时把最新的 reader.js / reader.css 覆盖到书籍目录。
  ///
  /// 这两份文件是导入时复制进 bookDir 的，App 升级后旧书不会自动更新——
  /// 之前所有引擎侧的修复（书签手势、面板分组、上下文提取）对老书全都不生效。
  Future<void> _boot() async {
    if (!File(_htmlPath).existsSync()) {
      setState(() {
        _error = true;
        _errorMsg = '书籍文件缺失，请重新导入';
      });
      return;
    }
    await _syncReaderAssets();
    await _loadReaderFont();
    _initWebView();
    if (mounted) setState(() {});
  }

  /// 把阅读器正文字体加载进 Flutter，供修改面板等 UI 使用（字体与阅读一致）
  Future<void> _loadReaderFont() async {
    try {
      final loader = FontLoader('ReaderSerif')
        ..addFont(rootBundle.load('assets/fonts/NotoSerifSC-Regular.otf'));
      await loader.load();
    } catch (e) {
      debugPrint('[reader] 字体加载失败: $e');
    }
  }

  Future<void> _syncReaderAssets() async {
    try {
      final css = await rootBundle.loadString('assets/reader/reader.css');
      final js = await rootBundle.loadString('assets/reader/reader.js');

      final jsFile = File(p.join(widget.book.bookDir, 'reader.js'));
      final cssFile = File(p.join(widget.book.bookDir, 'reader.css'));

      // 先删再写：直接覆盖时如果旧文件句柄没释放，写入可能静默失败
      if (await jsFile.exists()) await jsFile.delete();
      if (await cssFile.exists()) await cssFile.delete();

      await jsFile.writeAsString(js, flush: true);
      await cssFile.writeAsString(css, flush: true);

      debugPrint('[sync] reader 引擎已更新: js=${js.length} chars');
    } catch (e) {
      // 之前这里静默吞异常，导致旧书一直用老引擎却毫无提示
      debugPrint('[sync] 更新失败: $e');
    }
  }

  Future<void> _initWebView() async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFAF8F3))
      ..addJavaScriptChannel(
        'IslandReaderChannel',
        onMessageReceived: (msg) => _handleMessage(msg.message),
      );

    // iOS 的 loadFile 内部是 loadFileURL:allowingReadAccessTo:，
    // 默认只放行 index.html 所在的那一个目录。而字体放在 <文档>/fonts/，
    // 相对路径 ../../fonts/ 落在授权范围之外，@font-face 会全部加载失败。
    // 这里把读权限显式放大到文档根目录（books/ 和 fonts/ 都在它下面）。
    //
    // 绝对不能用 loadRequest(Uri.file(...))：WKWebView 对 file:// 页面的
    // 子资源（CSS / JS / 图片 / 字体）一律按沙盒拒绝，结果是页面能打开但
    // 没有样式、没有脚本、没有插图，整个阅读器等于废掉。
    _controller = controller;
    if (Platform.isIOS) {
      final docsRoot = p.dirname(p.dirname(widget.book.bookDir));
      controller.platform.loadFileWithParams(
        WebKitLoadFileParams(
          absoluteFilePath: _htmlPath,
          readAccessPath: docsRoot,
        ),
      );
    } else {
      // 注意：这里不能用 loadRequest(Uri.file(...)) 传 fragment ——
      // Android WebView 对 file:// 走 loadUrl 时会收紧权限，直接 ERR_ACCESS_DENIED。
      // 位置改由 onReady 后回注（见 _restoreProgress），首帧前页面保持隐藏。
      controller.loadFile(_htmlPath);
    }
  }

  void _handleMessage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final name = decoded['name'];
      final data = decoded['data'];

      if (name == 'onProgress' && data is Map) {
        _saveProgress(data);
      } else if (name == 'onBack') {
        if (mounted) Navigator.of(context).maybePop();
      } else if (name == 'onReady') {
        _restoreProgress();
        _loadBookmarks();
        _injectFonts();
        _applyTempRules();
        _injectPlatform();
        _syncSafeTop(_chromeVisible);
      } else if (name == 'onChapter' && data is Map) {
        final n = (data['name'] as String?) ?? '';
        if (n != _chapterName && mounted) setState(() => _chapterName = n);
      } else if (name == 'onSelection' && data is Map) {
        final v = (data['visible'] as bool?) ?? false;
        if (v != _selVisible && mounted) setState(() => _selVisible = v);
      } else if (name == 'onLayout' && data is Map) {
        final fs = (data['fontSize'] as num?)?.toDouble();
        final lg = (data['lineGap'] as num?)?.toDouble();
        if (fs != null &&
            lg != null &&
            (fs != _readerFontSize || lg != _readerLineGap) &&
            mounted) {
          setState(() {
            _readerFontSize = fs;
            _readerLineGap = lg;
          });
        }
      } else if (name == 'onChrome' && data is Map) {
        final v = (data['visible'] as bool?) ?? false;
        if (v != _chromeVisible && mounted) {
          setState(() => _chromeVisible = v);
          // 唤出工具栏时恢复系统状态栏（时间/信号/电池），沉浸阅读时再藏回去
          SystemChrome.setEnabledSystemUIMode(
            v ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
          );
          final dark = ReaderTheme.byId(_themeId).bg.computeLuminance() < 0.4;
          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          ));
          // Android WebView 里 env(safe-area-inset-top) 基本返回 0，
          // 所以把状态栏高度直接写进 CSS 变量，让书籍名栏让出这块空间。
          _syncSafeTop(v);
        }
      } else if (name == 'onTheme' && data is Map) {
        final t = (data['theme'] as String?) ?? 'paper';
        if (t != _themeId && mounted) setState(() => _themeId = t);
      } else if (name == 'onAddBookmark' && data is Map) {
        _addBookmark(data);
      } else if (name == 'onRemoveBookmark' && data is Map) {
        _removeBookmark(data);
      } else if (name == 'onImageLongPress' && data is Map) {
        _openImage(data);
      } else if (name == 'onEditText' && data is Map) {
        _onEditText(data);
      } else if (name == 'onCopyText' && data is Map) {
        final text = (data['text'] as String?) ?? '';
        if (text.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: text));
          _toast('已复制');
        }
      } else if (name == 'onTranslateText' && data is Map) {
        final text = (data['text'] as String?) ?? '';
        if (text.isNotEmpty && Platform.isIOS) {
          Clipboard.setData(ClipboardData(text: text));
          _toast('已复制，可在系统翻译中使用');
        }
      }
    } catch (_) {
      // 通信失败不打断阅读
    }
  }

  /// 长按正文插图 → 全屏查看，可双指缩放看细节
  void _openImage(Map data) {
    final src = (data['src'] as String?) ?? '';
    if (src.isEmpty || !mounted) return;
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ImageViewerPage(imageUrl: src),
      ),
    );
  }

  // ==================================================================
  // 文本修改
  // ==================================================================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 1)));
  }

  /// 把系统状态栏高度写进 WebView 的 CSS 变量 --safe-top。
  /// 唤出工具栏（状态栏可见）时用真实高度，沉浸阅读时归零。
  void _syncSafeTop(bool chromeVisible) {
    final h = chromeVisible ? MediaQuery.of(context).viewPadding.top : 0.0;
    _controller?.runJavaScript(
      "document.documentElement.style.setProperty('--safe-top','${h.toStringAsFixed(1)}px');",
    );
  }

  void _onEditText(Map data) {
    final spine = (data['spine'] as num?)?.toInt() ?? 0;
    final blockIndex = (data['blockIndex'] as num?)?.toInt() ?? 0;
    final word = (data['text'] as String?) ?? '';
    final wordOffset = (data['wordOffsetInPara'] as num?)?.toInt() ?? 0;
    if (word.isEmpty) return;
    HapticFeedback.lightImpact();
    _showEditToolbar(spine: spine, blockIndex: blockIndex, word: word, wordOffset: wordOffset);
  }

  void _showEditToolbar({
    required int spine,
    required int blockIndex,
    required String word,
    required int wordOffset,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  // 第一行：处理内容：xx（加粗）
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                    child: Text.rich(
                      TextSpan(children: [
                        const TextSpan(
                          text: '处理内容：',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.ink,
                          ),
                        ),
                        TextSpan(
                          text: word,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.ink,
                          ),
                        ),
                      ]),
                      style: const TextStyle(fontFamily: 'ReaderSerif'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Divider(height: 1),
                  // 第二行：原文替换
                  _sheetAction(ctx, '原文替换', () {
                    Navigator.pop(ctx);
                    Future.delayed(const Duration(milliseconds: 180), () {
                      if (mounted) {
                        _showReplaceDialog(
                          spine: spine,
                          blockIndex: blockIndex,
                          word: word,
                          wordOffset: wordOffset,
                        );
                      }
                    });
                  }),
                  // 第三行：过滤
                  _sheetAction(ctx, '过滤', () {
                    Navigator.pop(ctx);
                    Future.delayed(const Duration(milliseconds: 180), () {
                      if (mounted) {
                        _showFilterDialog(spine: spine, blockIndex: blockIndex, word: word);
                      }
                    });
                  }),
                  // 第四行：过滤管理器
                  _sheetAction(ctx, '过滤管理器', () {
                    Navigator.pop(ctx);
                    Future.delayed(const Duration(milliseconds: 180), () {
                      if (mounted) _showTempRulesSheet();
                    });
                  }),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消',
                    style: TextStyle(
                        fontSize: 16, fontFamily: 'ReaderSerif', color: AppColors.ink)),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _sheetAction(BuildContext ctx, String label, VoidCallback onTap,
      {bool danger = false}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          label,
          textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 16,
          fontFamily: 'ReaderSerif',
          color: danger ? Colors.red : AppColors.ink,
        ),
        ),
      ),
    );
  }

  /// 原文替换对话框（不可逆）
  void _showReplaceDialog({
    required int spine,
    required int blockIndex,
    required String word,
    required int wordOffset,
  }) {
    final ctrl = TextEditingController();
    var scope = 'here';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
          title: const Text('替换内容'),
          contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将「$word」替换为指定的文本',
                  style: const TextStyle(fontSize: 13, color: AppColors.ink2)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '替换为…',
                ),
              ),
              const SizedBox(height: 10),
              Text('留空并确认 = 删除选中内容；替换将修改原文，无法撤销',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _scopeChip(ctx, '仅此处', 'here', scope, (s) => setDlg(() => scope = s)),
                  _scopeChip(ctx, '本章节', 'chapter', scope, (s) => setDlg(() => scope = s)),
                  _scopeChip(ctx, '全书', 'book', scope, (s) => setDlg(() => scope = s)),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final to = ctrl.text;
                final deleting = to.isEmpty;
                Navigator.pop(ctx);
                bool ok;
                if (scope == 'here') {
                  ok = await TextEditService.replaceHere(
                    book: widget.book,
                    spine: spine,
                    blockIndex: blockIndex,
                    wordOffsetInPara: wordOffset,
                    from: word,
                    to: to,
                  );
                } else {
                  ok = await TextEditService.replaceAll(
                    book: widget.book,
                    scope: scope,
                    spine: spine,
                    from: word,
                    to: to,
                  );
                }
                _toast(ok ? (deleting ? '已删除' : '已替换') : '操作失败');
                if (ok) await _reloadBook();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  /// 过滤（临时修改）对话框：只改显示，可逆
  void _showFilterDialog({
    required int spine,
    required int blockIndex,
    required String word,
  }) {
    final ctrl = TextEditingController();
    var scope = 'book';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
          title: const Text('添加过滤'),
          contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将「$word」替换为指定的文本（可逆）',
                  style: const TextStyle(fontSize: 13, color: AppColors.ink2)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '替换为…',
                ),
              ),
              const SizedBox(height: 10),
              const Text('只改显示，原文不动，可在过滤管理器里停用',
                  style: TextStyle(fontSize: 12, color: AppColors.ink2)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _scopeChip(ctx, '仅此处', 'here', scope, (s) => setDlg(() => scope = s)),
                  _scopeChip(ctx, '本章节', 'chapter', scope, (s) => setDlg(() => scope = s)),
                  _scopeChip(ctx, '全书', 'book', scope, (s) => setDlg(() => scope = s)),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                final to = ctrl.text;
                if (to.isEmpty) {
                  _toast('请输入替换文本');
                  return;
                }
                if (widget.book.id == null) return;
                await _repo.addTextRule(TextRule(
                  bookId: widget.book.id!,
                  fromText: word,
                  toText: to,
                  scope: scope,
                  spineIndex: spine,
                  blockIndex: blockIndex,
                  createdAt: DateTime.now().millisecondsSinceEpoch,
                ));
                Navigator.pop(ctx);
                _toast('已添加过滤');
                await _applyTempRules();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scopeChip(BuildContext ctx, String label, String value, String selected,
      ValueChanged<String> onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: value == selected,
      onSelected: (_) => onTap(value),
    );
  }

  Future<void> _showTempRulesSheet() async {
    if (widget.book.id == null) return;
    var allRules = await _repo.listTextRules(widget.book.id!);
    if (!mounted) return;
    var filter = 'all';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final rules = allRules.where((r) {
            if (filter == 'enabled') return r.enabled;
            if (filter == 'disabled') return !r.enabled;
            return true;
          }).toList();
          return Container(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
                  child: Row(
                    children: [
                      const Text('内容过滤管理',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.add, size: 24),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _toast('请长按正文文字后选择「过滤」');
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'all', label: Text('全部')),
                      ButtonSegment(value: 'enabled', label: Text('启用')),
                      ButtonSegment(value: 'disabled', label: Text('禁用')),
                    ],
                    selected: {filter},
                    onSelectionChanged: (s) => setSheet(() => filter = s.first),
                  ),
                ),
                Expanded(
                  child: rules.isEmpty
                      ? const Center(
                          child: Text('暂无过滤规则',
                              style: TextStyle(color: AppColors.ink2)),
                        )
                      : ListView.builder(
                          itemCount: rules.length,
                          itemBuilder: (ctx, i) {
                            final r = rules[i];
                            return Dismissible(
                              key: ValueKey(r.id),
                              direction: DismissDirection.endToStart,
                              onDismissed: (_) async {
                                await _repo.deleteTextRule(r.id!);
                                allRules = await _repo.listTextRules(widget.book.id!);
                                setSheet(() {});
                                _reloadBook();
                              },
                              background: Container(
                                color: Colors.red,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                child: const Icon(Icons.delete, color: Colors.white),
                              ),
                              child: Card(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 4),
                                child: ListTile(
                                  title: Text(
                                    '${r.fromText} → ${r.toText}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(r.scopeLabel),
                                  trailing: Switch(
                                    value: r.enabled,
                                    onChanged: (v) async {
                                      await _repo.setTextRuleEnabled(r.id!, v);
                                      allRules = await _repo.listTextRules(widget.book.id!);
                                      setSheet(() {});
                                      // 停用后已改的 DOM 不会自动还原，必须重载页面
                                      _reloadBook();
                                    },
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 永久修改后重新加载页面（onReady 会自动恢复阅读位置 + 注入字体/临时规则）
  Future<void> _reloadBook() async {
    final c = _controller;
    if (c == null) return;
    if (Platform.isIOS) {
      final docsRoot = p.dirname(p.dirname(widget.book.bookDir));
      await c.platform.loadFileWithParams(
        WebKitLoadFileParams(absoluteFilePath: _htmlPath, readAccessPath: docsRoot),
      );
    } else {
      await c.loadFile(_htmlPath);
    }
  }

  /// 把启用的临时规则注入 JS 应用（只改显示，不动文件）
  Future<void> _applyTempRules() async {
    if (_controller == null || widget.book.id == null) return;
    final rules = await _repo.listTextRules(widget.book.id!, onlyEnabled: true);
    final payload = jsonEncode(rules
        .map((r) => {
              'fromText': r.fromText,
              'toText': r.toText,
              'scope': r.scope,
              'spine': r.spineIndex,
              'blockIndex': r.blockIndex,
            })
        .toList());
    await _controller!.runJavaScript(
      'window.IslandReader && window.IslandReader.applyTempRules($payload);',
    );
  }

  /// 注入平台标识，供 JS 决定是否显示「翻译」（仅 iOS）
  Future<void> _injectPlatform() async {
    if (_controller == null) return;
    await _controller!.runJavaScript('window.__isIOS = ${Platform.isIOS};');
  }

  /// 把书签全量推给 JS。JS 侧加/删书签后也会回调这里，
  /// 落库完再推一次，保证两边状态一致。
  /// 注入内置字体的 @font-face。
  /// 放在运行时注入而不是写进 index.html：这样以前导入的书不用重新导入也能用新字体。
  Future<void> _injectFonts() async {
    if (_controller == null) return;
    try {
      final css = await FontService.buildCss();
      if (css.isEmpty) return;
      final js = '''
(function(){
  var old = document.getElementById('islandFonts');
  if (old) old.remove();
  var s = document.createElement('style');
  s.id = 'islandFonts';
  s.textContent = ${jsonEncode(css)};
  document.head.appendChild(s);
})();
''';
      await _controller!.runJavaScript(js);
    } catch (_) {}
  }

  Future<void> _loadBookmarks() async {
    if (widget.book.id == null || _controller == null) return;
    final list = await _repo.listBookmarks(widget.book.id!);
    final payload = jsonEncode(list
        .map((b) => {
              'id': b.id,
              'spine': b.spineIndex,
              'offset': b.charOffset,
              'title': b.chapterTitle,
              'excerpt': b.excerpt,
              'percent': b.percent,
              'at': b.createdAt,
            })
        .toList());
    await _controller!.runJavaScript(
      'window.IslandReader && window.IslandReader.setBookmarks($payload);',
    );
  }

  Future<void> _addBookmark(Map data) async {
    if (widget.book.id == null) return;
    // 加书签给一次中等强度反馈，手不用看屏幕也知道成了
    HapticFeedback.mediumImpact();
    try {
      await _repo.addBookmark(Bookmark(
        bookId: widget.book.id!,
        spineIndex: (data['spine'] as num?)?.toInt() ?? 0,
        charOffset: (data['offset'] as num?)?.toInt() ?? 0,
        chapterTitle: (data['title'] as String?) ?? '',
        excerpt: (data['excerpt'] as String?) ?? '',
        percent: (data['percent'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await _loadBookmarks();
    } catch (_) {}
  }

  Future<void> _removeBookmark(Map data) async {
    if (widget.book.id == null) return;
    // 删除用更轻的一下，和添加区分开
    HapticFeedback.lightImpact();
    final id = (data['id'] as num?)?.toInt() ?? 0;
    try {
      if (id > 0) {
        await _repo.deleteBookmark(id);
      } else {
        // 临时 id：刚加还没落库就被删了，按位置找
        final found = await _repo.findBookmarkNear(
          widget.book.id!,
          (data['spine'] as num?)?.toInt() ?? 0,
          (data['offset'] as num?)?.toInt() ?? 0,
        );
        if (found?.id != null) await _repo.deleteBookmark(found!.id!);
      }
      await _loadBookmarks();
    } catch (_) {}
  }

  Future<void> _saveProgress(Map data) async {
    if (widget.book.id == null) return;
    try {
      await _repo.saveProgress(
        bookId: widget.book.id!,
        spineIndex: (data['spine'] as num?)?.toInt() ?? 0,
        charOffset: (data['offset'] as num?)?.toInt() ?? 0,
        percent: (data['percent'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {}
  }

  Future<void> _restoreProgress() async {
    if (widget.book.id == null || _controller == null) return;
    final progress = await _repo.getProgress(widget.book.id!);

    final percent = (progress?['percent'] as num?)?.toDouble() ?? 0;
    final spine = (progress?['spine_index'] as num?)?.toInt();
    final offset = (progress?['char_offset'] as num?)?.toInt();

    // 优先用「章节 + 字符偏移」精确恢复，percent 只作兜底。
    // 只按 percent 跳会因为图片未加载完、scrollHeight 偏小，算出错误位置，
    // 再被 savePosition 存进库，形成累积漂移（表现为每次打开跳的位置都不一样）。
    final spineArg = spine?.toString() ?? 'null';
    final offsetArg = offset?.toString() ?? 'null';

    // 第一次打开、没有任何进度：直接让正文可见（否则要等 CSS 的兜底动画）
    if (spine == null && offset == null && percent <= 0) {
      await _controller!.runJavaScript(
        'window.IslandReader && window.IslandReader.reveal();',
      );
      return;
    }

    await _controller!.runJavaScript(
      'window.IslandReader && window.IslandReader.restoreProgress('
      '$spineArg, $offsetArg, $percent);',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ReaderTheme.byId(_themeId);
    // viewPadding 不受「隐藏状态栏」影响，始终是系统状态栏高度，动画距离才稳定
    final statusTop = MediaQuery.of(context).viewPadding.top;
    final chapterH = MediaQuery.of(context).size.height * 0.08;
    // 书籍名栏总高（含状态栏）= 章节名区高 + 一个行间距（实测字形间距）。
    // 这样栏底正好落在「章节名区下沿 + 行间距」处，也就是下一行文字的上沿。
    final barH = chapterH + _readerLineGap;

    return Scaffold(
      backgroundColor: theme.bg,
      body: _error
          ? _buildError()
          : Stack(
              children: [
                if (_controller != null)
                  SafeArea(top: false, child: WebViewWidget(controller: _controller!)),
                // 顶部章节名区：Flutter 层绘制，天然盖在 WebView 合成层之上（WebView 里 fixed 会被滚动正文盖住）
                // 这一栏常驻、不参与动画——唤出工具栏时是下面那栏「盖」下来
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SizedBox(
                    height: MediaQuery.of(context).size.height * 0.08,
                    child: ColoredBox(
                      color: theme.bg,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16, bottom: 5),
                          child: Text(
                            _chapterName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontFamily: 'ReaderSerif',
                              color: theme.fg.withValues(alpha: 0.66),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 书籍名栏：从顶部滑下来盖住章节名区（章节名本身不动，视觉上就是被压住）
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSlide(
                    offset: _chromeVisible ? Offset.zero : const Offset(0, -1),
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    child: Container(
                      height: barH,
                      padding: EdgeInsets.only(top: statusTop),
                      decoration: BoxDecoration(
                        color: theme.bg,
                        border: Border(
                          bottom: BorderSide(
                            color: theme.fg.withValues(alpha: 0.12),
                            width: 0.6,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          _buildBarBtn(Icons.chevron_left, 24, theme, () {
                            _controller?.runJavaScript(
                              'document.getElementById("btnBack").click();',
                            );
                          }),
                          Expanded(
                            child: Text(
                              widget.book.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: theme.fg.withValues(alpha: 0.92),
                              ),
                            ),
                          ),
                          _buildBarBtn(Icons.more_horiz, 24, theme, () {
                            _controller?.runJavaScript(
                              'document.getElementById("btnMenu").click();',
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                ),
                // 选中文字时的「修改」入口：必须画在 Flutter 层，
                // WebView 里的元素会被 WebView 合成层压在正文下面。
                Positioned(
                  top: _chromeVisible
                      ? barH + 6
                      : chapterH + 6,
                  right: 14,
                  child: IgnorePointer(
                    ignoring: !_selVisible,
                    child: AnimatedOpacity(
                      opacity: _selVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 140),
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _selVisible = false);
                          _controller?.runJavaScript(
                            'window.__islandEditSelection && window.__islandEditSelection();',
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF363E4A),
                            borderRadius: BorderRadius.circular(9),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.22),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Text(
                            '修改',
                            style: TextStyle(color: Colors.white, fontSize: 13.5, height: 1.25),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 亮度遮罩（v1 先不做系统亮度调节，用黑色蒙层模拟）
                if (_brightness < 1.0)
                  IgnorePointer(
                    child: Container(color: Colors.black.withValues(alpha: 1 - _brightness)),
                  ),
              ],
            ),
    );
  }

  /// 书籍名栏两侧的图标按钮（‹ 返回 / ⋯ 菜单），点下去转发给 WebView 里的原生按钮。
  Widget _buildBarBtn(IconData icon, double size, ReaderTheme theme, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: double.infinity,
        child: Center(
          child: Icon(icon, size: size, color: theme.fg.withValues(alpha: 0.85)),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_outlined, size: 48, color: AppColors.ink2),
            const SizedBox(height: 16),
            Text(
              _errorMsg ?? '出了点问题',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, height: 1.6, color: AppColors.ink2),
            ),
            const SizedBox(height: 22),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回书架'),
            ),
          ],
        ),
      ),
    );
  }
}
