import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/book.dart';
import '../../data/models/book_group.dart';
import '../../data/repositories/book_repository.dart';
import '../../services/import/import_service.dart';
import '../../services/lan/lan_server.dart';
import '../../services/render/image_size.dart';
import '../detail/book_detail_page.dart';
import '../detail/group_detail_page.dart';
import '../reader/reader_page.dart';
import '../../widgets/file_import_icon.dart';

/// 书架。带 groupId 时表示进到了某个分组内部。
class BookshelfPage extends StatefulWidget {
  final int? groupId;
  final String? groupName;

  const BookshelfPage({super.key, this.groupId, this.groupName});

  bool get isRoot => groupId == null;

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  final _repo = BookRepository();
  final _lan = LanServer();

  List<BookGroup> _childGroups = [];
  List<Book> _books = [];
  List<Book> _recent = [];
  bool _loading = true;
  bool _importing = false;

  /// list / grid
  String _viewMode = 'list';
  bool _showRecent = true;

  /// recent（最近阅读）/ name（文件名）/ manual（手动拖动）
  String _sortMode = 'recent';

  /// 手动排序是否处于编辑态。true 显示拖动把手 + 「完成」按钮，
  /// 点「完成」退出编辑态、回到普通浏览界面（手动顺序仍保留）。
  bool _manualEditing = false;

  /// 顶层书架的自定义名字（长按标题可改）
  String _rootName = '书架';

  /// 当前分组名：长按改名后要能立刻反映到标题上，
  /// widget.groupName 是构造参数改不了，所以单独存一份
  String? _groupName;

  /// 多选编辑模式
  bool _selectMode = false;
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _groupName = widget.groupName;
    _restorePrefs();
    _load();
    _syncAllReaderAssets();
    _runBackgroundFixes();
  }

  /// 首屏之后的修补任务：串行跑，避免同时读写同一批 index.html
  Future<void> _runBackgroundFixes() async {
    await _backfillWordCount();
    await _patchLegacyHtml();
  }

  /// 老书的 index.html 是旧版生成的（图片没写宽高比），打开时图片加载会把正文顶下去。
  /// 这里直接读书目录里已经解压好的图片来补 —— 不需要原始 epub
  /// （很多老书导入后源文件早就没了，走 epub 重建那条路会永远跳过它们）。
  Future<void> _patchLegacyHtml() async {
    try {
      final books = await _repo.listBooks();
      for (final b in books) {
        if (b.id == null) continue;
        final htmlFile = File(p.join(b.bookDir, 'index.html'));
        if (!await htmlFile.exists()) continue;
        final html = await htmlFile.readAsString();
        // 只补「还没写宽高比」的图。
        // 不能整本判断（以前写的是 contains('data-ar="1') 就跳过）——
        // 那样一本书里只要有 1 张图成功、其余失败，整本就被跳过，漏的图永远补不上。
        final hasBare =
            RegExp(r'<img\b(?![^>]*\bdata-ar=)[^>]*>', caseSensitive: false).hasMatch(html);
        if (!hasBare) continue;

        // 1. 先把需要的图片尺寸量出来（只读文件头，不整张解码）
        final srcs = RegExp(r'''<img\b[^>]*\bsrc\s*=\s*"([^"]*)"''', caseSensitive: false)
            .allMatches(html)
            .map((m) => m.group(1)!)
            .toSet();
        final sizes = <String, (int, int)>{};
        for (final rel in srcs) {
          final imgFile = File(p.join(b.bookDir, rel));
          if (!await imgFile.exists()) continue;
          try {
            final total = await imgFile.length();
            final raf = await imgFile.open();
            final head = await raf.read(total > 262144 ? 262144 : total);
            await raf.close();
            final size = ImageSizes.detect(head);
            if (size != null) sizes[rel] = size;
          } catch (_) {}
        }
        if (sizes.isEmpty) continue;

        // 2. 回写 img 标签
        final patched = html.replaceAllMapped(
          RegExp(r'<img\b[^>]*>', caseSensitive: false),
          (m) {
            final tag = m.group(0)!;
            if (tag.contains('data-ar=')) return tag;
            final sm = RegExp(r'''src\s*=\s*"([^"]*)"''', caseSensitive: false).firstMatch(tag);
            if (sm == null) return tag;
            final size = sizes[sm.group(1)!];
            if (size == null) return tag;
            final decl = 'width:min(100%,${size.$1}px);aspect-ratio:${size.$1}/${size.$2}';
            // 先清掉历史重复注入的碎片（早期版本没打标记，每次启动都往 style 里追加一遍）
            var out = tag.replaceAll(
              RegExp(r'\s*width:min\([^)]*\);\s*aspect-ratio:[\d.]+/[\d.]+;?'),
              '',
            );
            if (RegExp(r'''style\s*=\s*"[^"]*"''', caseSensitive: false).hasMatch(out)) {
              out = out.replaceFirstMapped(
                RegExp(r'''style\s*=\s*"([^"]*)"''', caseSensitive: false),
                (mm) => 'style="${mm.group(1)};$decl"',
              );
            } else {
              out = out.replaceFirstMapped(
                RegExp(r'(\s*/)?>$'),
                (mm) => ' style="$decl"${mm.group(1) ?? ''}>',
              );
            }
            // 无论走哪个分支都打标记，保证下次不会再处理这张图
            return out.replaceFirst(RegExp(r'<img\b', caseSensitive: false), '<img data-ar="1"');
          },
        );
        await htmlFile.writeAsString(patched, flush: true);
      }
    } catch (_) {}
  }

  /// 老版本导入的书没有字数（当时没统计），这里用已生成的 index.html 回填一次。
  Future<void> _backfillWordCount() async {
    var fixed = 0;
    try {
      final books = await _repo.listBooks();
      for (final b in books) {
        if (b.wordCount > 0 || b.id == null) continue;
        final f = File(p.join(b.bookDir, 'index.html'));
        if (!await f.exists()) continue;
        final html = await f.readAsString();
        var s = html
            .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ')
            .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
            .replaceAll(RegExp(r'<[^>]*>'), '');
        s = s.replaceAll(RegExp(r'\s+'), '');
        if (s.isNotEmpty) {
          await _repo.setBookWordCount(b.id!, s.length);
          fixed++;
        }
      }
    } catch (_) {}
    if (fixed > 0 && mounted) _load();
  }

  /// 启动时把所有书的 reader.js / reader.css 更新到最新。
  ///
  /// 之前只在「打开某本书」时同步，导致没打开过的旧书一直跑老引擎——
  /// 那些书里的书签手势、点击翻页开关、进度恢复全是旧逻辑，
  /// 表现就是「改了代码但问题依旧」。
  Future<void> _syncAllReaderAssets() async {
    try {
      final js = await rootBundle.loadString('assets/reader/reader.js');
      final css = await rootBundle.loadString('assets/reader/reader.css');
      final books = await _repo.listBooks();

      var updated = 0;
      for (final b in books) {
        try {
          final jsFile = File(p.join(b.bookDir, 'reader.js'));
          final cssFile = File(p.join(b.bookDir, 'reader.css'));

          // 分别判断：只改 CSS 时 js 大小不变，
          // 如果只看 js 就 continue，CSS 的改动永远同步不进去。
          final jsUpToDate =
              await jsFile.exists() && await jsFile.length() == js.length;
          final cssUpToDate =
              await cssFile.exists() && await cssFile.length() == css.length;
          if (jsUpToDate && cssUpToDate) continue;

          if (!jsUpToDate) {
            if (await jsFile.exists()) await jsFile.delete();
            await jsFile.writeAsString(js, flush: true);
          }
          if (!cssUpToDate) {
            if (await cssFile.exists()) await cssFile.delete();
            await cssFile.writeAsString(css, flush: true);
          }

          updated++;
        } catch (_) {
          // 单本失败不影响其他书
        }
      }
      if (updated > 0) {
        debugPrint('[sync] 批量更新 $updated 本书的阅读引擎');
      }
    } catch (e) {
      debugPrint('[sync] 批量更新失败: $e');
    }
  }

  Future<void> _restorePrefs() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _viewMode = sp.getString('shelf.viewMode') ?? 'list';
      _showRecent = sp.getBool('shelf.showRecent') ?? true;
      _sortMode = sp.getString('shelf.sort.${widget.groupId ?? 'root'}') ?? 'recent';
      _rootName = sp.getString('shelf.rootName') ?? '书架';
    });
    _load();
  }

  Future<void> _savePrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('shelf.viewMode', _viewMode);
    await sp.setBool('shelf.showRecent', _showRecent);
    await sp.setString('shelf.sort.${widget.groupId ?? 'root'}', _sortMode);
  }

  Future<void> _load() async {
    final allGroups = await _repo.listGroups(sort: _sortMode);
    final children = allGroups.where((g) => g.parentId == widget.groupId).toList();

    final books = await _repo.listBooks(
      groupId: widget.groupId,
      rootOnly: widget.isRoot,
      sort: _sortMode,
    );

    List<Book> recent = [];
    if (widget.isRoot && _showRecent) {
      recent = await _repo.listRecentBooks(limit: 12);
    }

    if (!mounted) return;
    setState(() {
      _childGroups = children;
      _books = books;
      _recent = recent;
      _loading = false;
    });
  }

  // ==================================================================
  // 导入
  // ==================================================================

  Future<void> _import() async {
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub', 'txt'],
      );
    } catch (e) {
      _toast('打开文件选择器失败：$e');
      return;
    }
    if (files.isEmpty) return;

    setState(() => _importing = true);
    final service = ImportService(_repo);
    var okCount = 0;
    final errors = <String>[];

    for (final f in files) {
      final path = f.path;
      if (path == null) {
        errors.add('${f.name}：无法读取文件');
        continue;
      }
      final r = await service.importEpub(File(path));
      if (r.ok) {
        okCount++;
      } else {
        errors.add('${f.name}：${r.error}');
      }
    }

    await _load();
    if (!mounted) return;
    setState(() => _importing = false);

    if (errors.isNotEmpty) {
      _toast(errors.join('\n'));
    } else if (okCount > 0) {
      _toast('已导入 $okCount 本');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ==================================================================
  // 分组操作
  // ==================================================================

  Future<void> _createGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '比如：无职转生',
            helperText: '同一部作品的多卷 epub 可以放进一个分组',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    await _repo.createGroup(name, parentId: widget.groupId);
    await _load();
  }

  Future<void> _showGroupMenu(BookGroup group) async {
    final action = await _bottomSheet([
      _SheetItem('更换封面', Icons.image_outlined, 'cover'),
      _SheetItem('重命名', Icons.drive_file_rename_outline, 'rename'),
      _SheetItem('删除分组', Icons.delete_outline, 'delete', danger: true),
    ], title: group.name);

    if (!mounted || action == null) return;

    if (action == 'cover') {
      await _changeCover(group: group);
    } else if (action == 'rename') {
      final controller = TextEditingController(text: group.name);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重命名分组'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty && group.id != null) {
        await _repo.renameGroup(group.id!, name);
        await _load();
      }
    } else if (action == 'delete' && group.id != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除分组？'),
          content: const Text('组里的书和子分组会移到上一层，不会被删除。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
          ],
        ),
      );
      if (ok == true) {
        await _repo.deleteGroup(group.id!);
        await _load();
      }
    }
  }

  // ==================================================================
  // 封面
  // ==================================================================

  /// 从相册选一张图当封面。book / group 二选一。
  Future<void> _changeCover({Book? book, BookGroup? group}) async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1400,
        imageQuality: 88,
      );
    } catch (e) {
      _toast('打开相册失败：$e');
      return;
    }
    if (picked == null) return;

    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'covers'));
      if (!await dir.exists()) await dir.create(recursive: true);

      final stamp = DateTime.now().millisecondsSinceEpoch;
      final key = book?.id ?? group?.id ?? 0;
      final dest = File(p.join(dir.path, 'c${key}_$stamp.jpg'));
      await dest.writeAsBytes(await File(picked.path).readAsBytes(), flush: false);

      if (book?.id != null) {
        await _repo.setBookCover(book!.id!, dest.path);
      } else if (group?.id != null) {
        await _repo.setGroupCover(group!.id!, dest.path);
      }
      await _load();
      _toast('封面已更换');
    } catch (e) {
      _toast('设置封面失败：$e');
    }
  }

  // ==================================================================
  // 多选编辑
  // ==================================================================

  void _enterSelect(Book book) {
    if (book.id == null) return;
    setState(() {
      _selectMode = true;
      _selected.add(book.id!);
    });
  }

  void _toggleSelect(Book book) {
    if (book.id == null) return;
    setState(() {
      if (_selected.contains(book.id)) {
        _selected.remove(book.id);
      } else {
        _selected.add(book.id!);
      }
      if (_selected.isEmpty) _selectMode = false;
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  void _selectAll() {
    setState(() {
      final ids = _books.map((b) => b.id).whereType<int>().toSet();
      if (_selected.length == ids.length) {
        _selected.clear();
        _selectMode = false;
      } else {
        _selected
          ..clear()
          ..addAll(ids);
        _selectMode = ids.isNotEmpty;
      }
    });
  }

  Future<void> _batchMove() async {
    if (_selected.isEmpty) return;
    final target = await _pickGroup();
    if (target == null) return;
    for (final id in _selected) {
      await _repo.moveBookToGroup(id, target.$1);
    }
    final n = _selected.length;
    _exitSelect();
    await _load();
    _toast('已把 $n 本移到${target.$2.replaceAll('已移到', '')}');
  }

  Future<void> _batchDelete() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除这 $n 本书？'),
        content: const Text('书和阅读记录都会被删除，无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selected.toList();
    _exitSelect();
    for (final id in ids) {
      await _repo.deleteBook(id);
    }
    await _load();
    _toast('已删除 $n 本');
  }

  Future<void> _renameSelected() async {
    if (_selected.length != 1) return;
    final id = _selected.first;
    final book = _books.firstWhere((b) => b.id == id, orElse: () => _books.first);
    final controller = TextEditingController(text: book.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _repo.renameBook(id, name);
    _exitSelect();
    await _load();
  }

  // ==================================================================
  // 书籍操作
  // ==================================================================

  /// 点书名/进度等非封面区域：直接开始阅读（原来的行为）
  /// [from] 是封面的屏幕位置，用来做「封面飞入并翻开」的过场
  Future<void> _openBook(Book book, {Rect? from}) async {
    if (!mounted) return;
    // 直接进阅读页，不过场动画：点开就是上次的位置
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ReaderPage(book: book),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    _load();
  }

  /// 点封面：进入书籍详情
  Future<void> _openBookDetail(Book book) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BookDetailPage(book: book)),
    );
    _load();
  }

  /// 点分组非封面区域：直接进入分组（原来的行为）
  Future<void> _openGroup(BookGroup g) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookshelfPage(groupId: g.id, groupName: g.name),
      ),
    );
    _load();
  }

  /// 点分组封面：进入分组详情
  Future<void> _openGroupDetail(BookGroup g) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => GroupDetailPage(group: g)),
    );
    _load();
  }

  Future<void> _showBookMenu(Book book) async {
    final action = await _bottomSheet([
      _SheetItem('更换封面', Icons.image_outlined, 'cover'),
      _SheetItem('移动到分组', Icons.drive_file_move_outline, 'move'),
      _SheetItem('重命名', Icons.drive_file_rename_outline, 'rename'),
      _SheetItem('删除', Icons.delete_outline, 'delete', danger: true),
    ], title: book.title);

    if (!mounted || action == null) return;

    if (action == 'cover') {
      await _changeCover(book: book);
    } else if (action == 'move') {
      final target = await _pickGroup();
      if (target != null && book.id != null) {
        await _repo.moveBookToGroup(book.id!, target.$1);
        await _load();
        _toast(target.$2);
      }
    } else if (action == 'rename') {
      final controller = TextEditingController(text: book.title);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重命名'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty) {
        await _repo.renameBook(book.id!, name);
        await _load();
      }
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除这本书？'),
          content: const Text('书和阅读记录都会被删除，无法恢复。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (ok == true && book.id != null) {
        await _repo.deleteBook(book.id!);
        await _load();
      }
    }
  }

  /// 树形分组选择器。返回 (目标分组 id, 提示文案)；id 为 null 表示顶层书架
  Future<(int?, String)?> _pickGroup() async {
    final all = await _repo.listGroups();
    if (!mounted) return null;

    return showModalBottomSheet<(int?, String)>(
      context: context,
      backgroundColor: AppColors.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (ctx2, scrollController) {
          final rows = <Widget>[];
          rows.add(const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text('移动到分组', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ));

          void addLevel(int? parentId, int depth) {
            final children = all.where((g) => g.parentId == parentId).toList();
            for (final g in children) {
              rows.add(InkWell(
                onTap: () => Navigator.pop(ctx, (g.id, '已移到「${g.name}」')),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.0 + depth * 22, 13, 20, 13),
                  child: Row(
                    children: [
                      Icon(
                        (g.childGroupCount > 0) ? Icons.folder_open : Icons.folder_outlined,
                        size: 19,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(g.name, style: const TextStyle(fontSize: 14)),
                      ),
                      Text('${g.bookCount} 本',
                          style: const TextStyle(fontSize: 12, color: AppColors.ink2)),
                    ],
                  ),
                ),
              ));
              addLevel(g.id, depth + 1);
            }
          }

          rows.add(InkWell(
            onTap: () => Navigator.pop(ctx, (null, '已移回顶层书架')),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(20, 13, 20, 13),
              child: Row(
                children: [
                  Icon(Icons.home_outlined, size: 19, color: AppColors.ink2),
                  SizedBox(width: 10),
                  Text('顶层书架', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ));
          addLevel(null, 0);

          if (all.isEmpty) {
            rows.add(const Padding(
              padding: EdgeInsets.fromLTRB(20, 24, 20, 24),
              child: Text('还没有分组。先关掉这个窗口，点右上角「新建分组」。',
                  style: TextStyle(fontSize: 13, color: AppColors.ink2)),
            ));
          }

          return ListView(
            controller: scrollController,
            children: rows,
          );
        },
      ),
    );
  }

  // ==================================================================
  // 底部菜单
  // ==================================================================

  Future<String?> _bottomSheet(List<_SheetItem> items, {String? title}) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            for (final it in items)
              ListTile(
                leading: Icon(it.icon, color: it.danger ? Colors.red : null),
                title: Text(
                  it.label,
                  style: it.danger ? const TextStyle(color: Colors.red) : null,
                ),
                onTap: () => Navigator.pop(ctx, it.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ==================================================================
  // WiFi 传书
  // ==================================================================

  /// 收到电脑传来的文件：先落临时文件，走正常导入流程，再清理
  Future<void> _onLanUpload(String name, List<int> bytes) async {
    final tmpDir = await getTemporaryDirectory();
    final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final tmp = File(p.join(tmpDir.path, safeName));
    try {
      await tmp.writeAsBytes(bytes, flush: false);
      final r = await ImportService(_repo).importEpub(tmp);
      if (r.ok) {
        await _load();
      } else {
        throw Exception(r.error ?? '导入失败');
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  Future<void> _showLanDialog() async {
    var ip = _lan.isRunning ? await LanServer.localIp() : null;
    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('WiFi 传书'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_lan.isRunning)
                const Text(
                  '手机和电脑连同一个 WiFi。开启后，在电脑浏览器打开显示的地址，'
                  '把 epub 拖进去就会自动导入到书架。',
                  style: TextStyle(fontSize: 13, height: 1.7),
                )
              else ...[
                const Text('在电脑浏览器打开：', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                SelectableText(
                  'http://${ip ?? '?'}:${_lan.port}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '已收到 ${_lan.receivedCount} 个文件',
                  style: const TextStyle(fontSize: 12, color: AppColors.ink2),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
            if (!_lan.isRunning)
              FilledButton(
                onPressed: () async {
                  ip = await _lan.start(onUpload: _onLanUpload);
                  setDlg(() {});
                },
                child: const Text('开启服务'),
              )
            else
              TextButton(
                onPressed: () async {
                  await _lan.stop();
                  setDlg(() {});
                },
                child: const Text('停止服务', style: TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
    );
  }

  // ==================================================================
  // 布局设置
  // ==================================================================

  Future<void> _showLayoutSettings() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('首页布局', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              SwitchListTile(
                title: const Text('显示「最近阅读」'),
                subtitle: const Text('顶部横向滑动的封面区'),
                value: _showRecent,
                onChanged: (v) {
                  setSheetState(() => _showRecent = v);
                  setState(() {});
                  _savePrefs();
                  _load();
                },
              ),
              ListTile(
                title: const Text('排列方式', maxLines: 1, softWrap: false),
                subtitle: Text(_viewMode == 'list' ? '列表（一本书一行）' : '网格（三列封面）'),
                trailing: SegmentedButton<String>(
                  // 关掉选中对勾：勾图标会让选中段变宽，
                  // 「文件名」被选中时整组按钮撑宽，把左边「排序方式」挤出显示区
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  segments: const [
                    ButtonSegment(value: 'list', icon: Icon(Icons.view_list_outlined)),
                    ButtonSegment(value: 'grid', icon: Icon(Icons.grid_view_outlined)),
                  ],
                  selected: {_viewMode},
                  onSelectionChanged: (s) {
                    setSheetState(() => _viewMode = s.first);
                    setState(() {});
                    _savePrefs();
                  },
                ),
              ),
              ListTile(
                title: const Text('排序方式', maxLines: 1, softWrap: false),
                trailing: SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  segments: const [
                    ButtonSegment(value: 'recent', label: Text('最近')),
                    ButtonSegment(value: 'name', label: Text('文件名')),
                    ButtonSegment(value: 'manual', label: Text('手动')),
                  ],
                  selected: {_sortMode},
                  onSelectionChanged: (s) {
                    setSheetState(() => _sortMode = s.first);
                    // 选手动排序就进入编辑态；选其它方式退出编辑态
                    _manualEditing = s.first == 'manual';
                    setState(() {});
                    _savePrefs();
                    _load();
                  },
                ),
              ),
              if (_sortMode == 'manual')
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    '长按书籍调整顺序',
                    style: TextStyle(fontSize: 12, color: AppColors.ink2),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.wifi, size: 20),
                title: const Text('WiFi 传书'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showLanDialog();
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  // ==================================================================
  // 构建
  // ==================================================================

  @override
  Widget build(BuildContext context) {
    // 手动排序模式走独立布局：ReorderableListView 必须是滚动主体，
    // 塞进 CustomScrollView 的 sliver 里手势会被外层滚动拦截
    if (_sortMode == 'manual' &&
        _viewMode == 'list' &&
        !_loading &&
        !_isEmpty &&
        _manualEditing) {
      return _buildManualSortView();
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            RefreshIndicator(
              color: AppColors.accent,
              onRefresh: _load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _buildHeader()),
                  if (_loading)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator(color: AppColors.accent)),
                    )
                  else ...[
                    if (widget.isRoot && _showRecent && _recent.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _RecentStrip(
                          books: _recent,
                          onTap: (b, r) => _openBook(b, from: r),
                        ),
                      ),
                    if (_isEmpty)
                      SliverFillRemaining(hasScrollBody: false, child: _buildEmpty())
                    else if (_viewMode == 'list')
                      _buildListSliver()
                    else
                      _buildGridSliver(),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 40)),
                ],
              ),
            ),
            if (_selectMode)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBatchBar(),
              ),
            if (_importing)
              Container(
                color: Colors.black26,
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 22),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppColors.accent),
                      SizedBox(height: 14),
                      Text('正在导入…', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool get _isEmpty => _childGroups.isEmpty && _books.isEmpty;

  /// 手动排序：分组 + 书籍都放进一个 ReorderableListView，右侧拖动把手。
  ///
  /// 分组整体排在书籍上方，两者各自成段排序、不允许跨段交换。
  /// 每行不注册长按（长按手势会吃掉 ReorderableListView 的拖动），
  /// 拖动只能从右侧把手发起，点击其他区域正常打开。
  Widget _buildManualSortView() {
    final groupCount = _childGroups.length;
    final totalCount = groupCount + _books.length;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ReorderableListView.builder(
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildManualSortHeader(),
              if (widget.isRoot && _showRecent && _recent.isNotEmpty)
                _RecentStrip(books: _recent, onTap: (b, r) => _openBook(b, from: r)),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 6, 20, 2),
                child: Text(
                  '按住右侧把手拖动排序',
                  style: TextStyle(fontSize: 12, color: AppColors.ink2),
                ),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
          itemCount: totalCount,
          onReorder: _onReorder,
          buildDefaultDragHandles: false,
          itemBuilder: (ctx, i) {
            if (i < groupCount) {
              final g = _childGroups[i];
              return _GroupRow(
                key: ValueKey('group_${g.id}'),
                group: g,
                onTap: () => _openGroup(g),
                onCoverTap: () => _openGroupDetail(g),
                onLongPress: () => _showGroupMenu(g),
                trailing: _dragHandle(i),
              );
            }
            final b = _books[i - groupCount];
            return _BookRow(
              key: ValueKey('book_${b.id}'),
              book: b,
              onTap: () => _openBook(b),
              onCoverTap: () => _openBookDetail(b),
              onOpen: (r) => _openBook(b, from: r),
              trailing: _dragHandle(i),
            );
          },
        ),
      ),
    );
  }

  /// 手动排序顶栏：书架/分组标题 + 「完成」按钮
  Widget _buildManualSortHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _groupName ?? _rootName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.4,
                fontFamily: kSerifFamily,
                color: AppColors.ink,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _manualEditing = false),
            child: const Text(
              '完成',
              style: TextStyle(fontSize: 16, color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
  }

  /// 右侧拖动把手
  Widget _dragHandle(int index) {
    return ReorderableDragStartListener(
      index: index,
      child: const Padding(
        padding: EdgeInsets.fromLTRB(8, 26, 2, 26),
        child: Icon(Icons.drag_handle, size: 22, color: AppColors.ink2),
      ),
    );
  }

  /// 拖动结束：本地换位 + 落库。
  /// 分组和书籍各自成段（分组在前、书籍在后），不允许跨段交换。
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final groupCount = _childGroups.length;
    final totalCount = groupCount + _books.length;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= totalCount) return;

    final oldIsGroup = oldIndex < groupCount;
    final newIsGroup = newIndex < groupCount;
    // 跨段拖动：直接忽略，item 回到原位
    if (oldIsGroup != newIsGroup) return;

    setState(() {
      if (oldIsGroup) {
        final g = _childGroups.removeAt(oldIndex);
        _childGroups.insert(newIndex, g);
      } else {
        final b = _books.removeAt(oldIndex - groupCount);
        _books.insert(newIndex - groupCount, b);
      }
    });

    if (oldIsGroup) {
      final ids = _childGroups.map((g) => g.id).whereType<int>().toList();
      await _repo.updateGroupSortOrders(ids);
    } else {
      final ids = _books.map((b) => b.id).whereType<int>().toList();
      await _repo.updateSortOrders(ids);
    }
  }

  Widget _buildBatchBar() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        boxShadow: [
          BoxShadow(color: Color(0x1A000000), blurRadius: 14, offset: Offset(0, -2)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              if (_selected.length == 1)
                _barBtn(Icons.drive_file_rename_outline, '重命名', _renameSelected),
              _barBtn(Icons.drive_file_move_outline, '移动到分组', _batchMove),
              _barBtn(Icons.delete_outline, '删除', _batchDelete, danger: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barBtn(IconData icon, String label, VoidCallback onTap, {bool danger = false}) {
    final color = danger ? Colors.red : AppColors.ink;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  /// 头部操作按钮：图标 + 中文标签，一眼知道点哪个
  Widget _headerAction(Widget icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(height: 1),
            Text(label,
                style: const TextStyle(fontSize: 10, color: AppColors.ink2)),
          ],
        ),
      ),
    );
  }

  /// 长按标题改名：顶层存 SharedPreferences，分组写数据库
  Future<void> _renameShelf() async {
    final current = _groupName ?? _rootName;
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名书架'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新的名字'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (!mounted || name == null || name.isEmpty) return;

    if (widget.isRoot) {
      setState(() => _rootName = name);
      final sp = await SharedPreferences.getInstance();
      await sp.setString('shelf.rootName', name);
    } else if (widget.groupId != null) {
      await _repo.renameGroup(widget.groupId!, name);
      setState(() => _groupName = name);
      await _load();
    }
  }


  Widget _buildHeader() {
    if (_selectMode) {
      final all = _books.length;
      final allSelected = _selected.length == all && all > 0;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '已选 ${_selected.length} 项',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ),
            TextButton(
              onPressed: _selectAll,
              child: Text(allSelected ? '取消全选' : '全选'),
            ),
            TextButton(
              onPressed: _exitSelect,
              child: const Text('完成'),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!widget.isRoot)
            Padding(
              padding: const EdgeInsets.only(right: 2, bottom: 4),
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.chevron_left),
                color: AppColors.ink,
                visualDensity: VisualDensity.compact,
              ),
            ),
          Expanded(
            child: GestureDetector(
              onLongPress: _renameShelf,
              behavior: HitTestBehavior.opaque,
              child: Text(
                _groupName ?? _rootName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                  fontFamily: kSerifFamily,
                  color: AppColors.ink,
                ),
              ),
            ),
          ),
          _headerAction(const Icon(Icons.collections_bookmark_outlined, size: 21, color: AppColors.ink), '分组', _createGroup),
          _headerAction(FileImportIcon(size: 21, color: AppColors.ink), '导入', _import),
          _headerAction(const Icon(Icons.more_horiz, size: 21, color: AppColors.ink), '设置', _showLayoutSettings),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 50),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_outlined,
                size: 54, color: AppColors.accent.withValues(alpha: 0.45)),
            const SizedBox(height: 18),
            Text(
              widget.isRoot ? '书架还是空的' : '这个分组还没有书',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              '点右上角的 + 导入 epub / txt\n同一部作品的多卷，可以先建分组再放进去',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, height: 1.7, color: AppColors.ink2.withValues(alpha: 0.9)),
            ),
            const SizedBox(height: 22),
            FilledButton.tonal(
              onPressed: _import,
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent.withValues(alpha: 0.12)),
              child: const Text('导入书籍', style: TextStyle(color: AppColors.accent)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListSliver() {
    final groupRows = <Widget>[
      for (final g in _childGroups)
        _GroupRow(
          group: g,
          onTap: () => _openGroup(g),
          onCoverTap: () => _openGroupDetail(g),
          onLongPress: () => _showGroupMenu(g),
        ),
    ];

    // 手动排序模式在 build() 里已经单独走了 _buildManualSortView，
    // 这里只处理普通列表（长按进入多选）
    final children = <Widget>[
      ...groupRows,
      for (final b in _books)
        _BookRow(
          book: b,
          selectMode: _selectMode,
          selected: _selected.contains(b.id),
          onTap: () => _selectMode ? _toggleSelect(b) : _openBook(b),
          onCoverTap: _selectMode ? null : () => _openBookDetail(b),
          onOpen: _selectMode ? null : (r) => _openBook(b, from: r),
          onLongPress: () => _selectMode ? _toggleSelect(b) : _enterSelect(b),
        ),
    ];

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList(delegate: SliverChildListDelegate(children)),
    );
  }

  Widget _buildGridSliver() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          for (final g in _childGroups)
            _GroupRow(
              group: g,
              onTap: () => _openGroup(g),
              onCoverTap: () => _openGroupDetail(g),
              onLongPress: () => _showGroupMenu(g),
            ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 15,
              mainAxisSpacing: 20,
              // 用固定高度而不是宽高比：宽高比在不同屏宽下会算错，
              // 之前 0.50 就导致书名第二行被挤出 14px
              mainAxisExtent: 226,
            ),
            itemCount: _books.length,
            itemBuilder: (context, i) => _BookCard(
              book: _books[i],
              selectMode: _selectMode,
              selected: _selected.contains(_books[i].id),
              onTap: () => _selectMode ? _toggleSelect(_books[i]) : _openBook(_books[i]),
              onCoverTap: _selectMode ? null : () => _openBookDetail(_books[i]),
              onOpen: _selectMode ? null : (r) => _openBook(_books[i], from: r),
              onLongPress: () =>
                  _selectMode ? _toggleSelect(_books[i]) : _enterSelect(_books[i]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ======================================================================
// 组件
// ======================================================================

class _SheetItem {
  final String label;
  final IconData icon;
  final String value;
  final bool danger;
  const _SheetItem(this.label, this.icon, this.value, {this.danger = false});
}

/// 顶部「最近阅读」横滑区
class _RecentStrip extends StatelessWidget {
  final List<Book> books;
  final void Function(Book book, Rect? from) onTap;

  const _RecentStrip({required this.books, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 6, 20, 12),
          child: Text(
            '最近阅读',
            style: TextStyle(fontSize: 13, color: AppColors.ink2, letterSpacing: 0.5),
          ),
        ),
        SizedBox(
          height: 88,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: books.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final b = books[i];
              return Builder(builder: (ctx) {
                return GestureDetector(
                  onTap: () {
                    final box = ctx.findRenderObject() as RenderBox?;
                    Rect? r;
                    if (box != null && box.hasSize) {
                      final o = box.localToGlobal(Offset.zero);
                      r = Rect.fromLTWH(o.dx, o.dy, box.size.width, box.size.height);
                    }
                    onTap(b, r);
                  },
                  child: SizedBox(
                    width: 56,
                    child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              color: const Color(0xFFE8E4DC),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0x263C3228),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: _cover(b),
                          ),
                        ),
                        // 不显示书名，改用底部一条细进度线区分阅读状态
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(6),
                            ),
                            child: LinearProgressIndicator(
                              value: b.progressPercent.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: Colors.black.withValues(alpha: 0.18),
                              valueColor: const AlwaysStoppedAnimation(Color(0xFFE8D9BE)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
              });
            },
          ),
        ),
        const SizedBox(height: 16),
        const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.line),
        const SizedBox(height: 6),
      ],
    );
  }

  static Widget _cover(Book b) {
    final path = b.coverPath;
    if (path == null || path.isEmpty) return _ph(b.title);
    final f = File(path);
    if (!f.existsSync()) return _ph(b.title);
    return Image.file(f, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _ph(b.title));
  }

  static Widget _ph(String title) => Center(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            title,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11, height: 1.4, color: AppColors.ink2, fontFamily: kSerifFamily),
          ),
        ),
      );
}

/// 分组行（文件夹）
class _GroupRow extends StatelessWidget {
  final BookGroup group;
  final VoidCallback onTap;

  /// 点封面 → 分组详情；点其他地方还是原来的「进入分组」
  final VoidCallback? onCoverTap;
  final VoidCallback onLongPress;

  /// 手动排序模式下放拖动把手
  final Widget? trailing;

  const _GroupRow({
    super.key,
    required this.group,
    required this.onTap,
    this.onCoverTap,
    required this.onLongPress,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (group.bookCount > 0) '${group.bookCount} 本',
      if (group.childGroupCount > 0) '${group.childGroupCount} 个分组',
      if (group.bookCount == 0 && group.childGroupCount == 0) '空',
    ];
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            GestureDetector(
              onTap: onCoverTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(width: 68, height: 92, child: _buildCover()),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    group.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    parts.join(' · '),
                    style: const TextStyle(fontSize: 12, color: AppColors.ink2),
                  ),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else
              const Icon(Icons.chevron_right, size: 20, color: AppColors.ink2),
          ],
        ),
      ),
    );
  }

  /// 有自定义封面（或组内第一本书的封面）就显示图，否则用文件夹图标
  Widget _buildCover() {
    final path = group.coverPath;
    if (path != null && path.isNotEmpty) {
      final f = File(path);
      if (f.existsSync()) {
        return Image.file(
          f,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _folderIcon(),
        );
      }
    }
    return _folderIcon();
  }

  Widget _folderIcon() => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE9E3D8), Color(0xFFDDD4C4)],
          ),
        ),
        child: const Icon(Icons.folder_rounded, color: AppColors.accent, size: 24),
      );
}

/// 书籍行（一本书一行）
class _BookRow extends StatelessWidget {
  final Book book;
  final bool selectMode;
  final bool selected;
  final VoidCallback onTap;

  /// 点封面 → 书籍详情；点其他地方直接开始阅读
  final VoidCallback? onCoverTap;

  /// 直接阅读时传入封面的屏幕矩形，用于「封面飞入翻开」的过场
  final void Function(Rect from)? onOpen;
  final VoidCallback? onLongPress;

  /// 手动排序模式下放拖动把手
  final Widget? trailing;

  const _BookRow({
    super.key,
    required this.book,
    this.selectMode = false,
    this.selected = false,
    required this.onTap,
    this.onCoverTap,
    this.onOpen,
    this.onLongPress,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        if (onOpen != null) {
          final box = context.findRenderObject() as RenderBox?;
          if (box != null && box.hasSize) {
            final o = box.localToGlobal(Offset.zero);
            // 行内左侧 76×110 是封面
            onOpen!(Rect.fromLTWH(o.dx + 4, o.dy + 10, 76, 110));
            return;
          }
        }
        onTap();
      },
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onCoverTap,
              child: SizedBox(
                width: 76,
                height: 110,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Container(color: const Color(0xFFE8E4DC), child: _cover()),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, height: 1.35, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    book.author.isEmpty ? '未知作者' : book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppColors.ink2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _metaLine(book),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.ink2),
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(1.5),
                    child: LinearProgressIndicator(
                      value: book.progressPercent.clamp(0.0, 1.0),
                      minHeight: 2.5,
                      backgroundColor: AppColors.accent.withValues(alpha: 0.15),
                      valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                    ),
                  ),
                ],
              ),
            ),
            if (selectMode) ...[
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 26),
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 22,
                  color: selected
                      ? AppColors.accent
                      : AppColors.ink2.withValues(alpha: 0.35),
                ),
              ),
            ],
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }

  Widget _cover() {
    final path = book.coverPath;
    if (path == null || path.isEmpty) return _ph();
    final f = File(path);
    if (!f.existsSync()) return _ph();
    return Image.file(f,
        fit: BoxFit.cover, width: double.infinity, errorBuilder: (_, __, ___) => _ph());
  }

  Widget _ph() => Center(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text(
            book.title,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 9, height: 1.3, color: AppColors.ink2, fontFamily: kSerifFamily),
          ),
        ),
      );
}

String _metaLine(Book b) {
  final bits = <String>[];
  bits.add(b.progressPercent > 0.001 ? b.progressLabel : '未读');
  if (b.lastReadAt != null) bits.add(_relativeTime(b.lastReadAt!));
  bits.add('${b.chapterCount} 章');
  return bits.join(' · ');
}

String _relativeTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()} 个月前';
  return '${(diff.inDays / 365).floor()} 年前';
}

/// 网格模式的书卡片（用 mainAxisExtent 定高，不会溢出）
class _BookCard extends StatelessWidget {
  final Book book;
  final bool selectMode;
  final bool selected;
  final VoidCallback onTap;

  /// 点封面 → 书籍详情；点书名/进度区直接阅读
  final VoidCallback? onCoverTap;

  /// 直接阅读时传入封面的屏幕矩形，用于「封面飞入翻开」的过场
  final void Function(Rect from)? onOpen;
  final VoidCallback onLongPress;

  const _BookCard({
    required this.book,
    this.selectMode = false,
    this.selected = false,
    required this.onTap,
    this.onCoverTap,
    this.onOpen,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (onOpen != null) {
          final box = context.findRenderObject() as RenderBox?;
          if (box != null && box.hasSize) {
            final o = box.localToGlobal(Offset.zero);
            // 封面上部 2/3 是封面区
            onOpen!(Rect.fromLTWH(o.dx, o.dy, box.size.width, box.size.height * 0.64));
            return;
          }
        }
        onTap();
      },
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: onCoverTap,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        color: const Color(0xFFE8E4DC),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0x213C3228),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _cover(),
                    ),
                  ),
                ),
                if (selectMode)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: Color(0x33000000), blurRadius: 4),
                        ],
                      ),
                      child: Icon(
                        selected ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 22,
                        color: selected ? AppColors.accent : AppColors.ink2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 9),
          SizedBox(
            height: 37,
            child: Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, height: 1.42, color: AppColors.ink),
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(book.progressLabel,
                  style: const TextStyle(fontSize: 11, color: AppColors.ink2)),
              const SizedBox(width: 6),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(1),
                  child: LinearProgressIndicator(
                    value: book.progressPercent.clamp(0.0, 1.0),
                    minHeight: 2.5,
                    backgroundColor: AppColors.accent.withValues(alpha: 0.16),
                    valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cover() {
    final path = book.coverPath;
    if (path == null || path.isEmpty) return _ph();
    final f = File(path);
    if (!f.existsSync()) return _ph();
    return Image.file(f,
        fit: BoxFit.cover, width: double.infinity, errorBuilder: (_, __, ___) => _ph());
  }

  Widget _ph() => Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            book.title,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, height: 1.5, color: AppColors.ink2, fontFamily: kSerifFamily),
          ),
        ),
      );
}
