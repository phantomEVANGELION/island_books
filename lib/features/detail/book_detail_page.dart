import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/book.dart';
import '../../data/repositories/book_repository.dart';
import '../reader/reader_page.dart';
import 'cover_actions.dart';
import 'detail_widgets.dart';

/// 书籍详情页：点书架上的单本书封面进入。
///
/// 左上角是当前封面（点它可换封面 / 保存封面），右侧是书名、作者、字数与进度；
/// 下面是简介和一组书目信息，底部是继续阅读。
class BookDetailPage extends StatefulWidget {
  final Book book;

  const BookDetailPage({super.key, required this.book});

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  final _repo = BookRepository();
  late Book _book = widget.book;
  bool _descExpanded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final id = _book.id;
    if (id == null) return;
    final fresh = await _repo.getBook(id);
    if (fresh != null && mounted) setState(() => _book = fresh);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ---------------------------------------------------------------- 操作

  Future<void> _onCoverTap() async {
    final action = await showCoverSheet(context);
    if (!mounted || action == null) return;

    if (action == 'replace') {
      final path = await CoverActions.pickFromGallery(_book.id ?? 0);
      if (path == null || !mounted) return;
      if (_book.id != null) {
        await _repo.setBookCover(_book.id!, path);
        setState(() => _book = _book.copyWith(coverPath: path));
        _toast('封面已更换');
      }
    } else if (action == 'save') {
      final path = _book.coverPath;
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        _toast('这本书还没有封面');
        return;
      }
      final ok = await CoverActions.saveAs(path, _book.title);
      _toast(ok ? '封面已保存' : '已取消');
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _book.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '书名'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || _book.id == null) return;
    await _repo.renameBook(_book.id!, name);
    if (!mounted) return;
    setState(() => _book = _book.copyWith(title: name));
    _toast('已重命名');
  }

  Future<void> _openReader() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReaderPage(book: _book)),
    );
    // 阅读时长是在阅读页 dispose 里异步落库的，这里稍等一下再读，否则拿到的是旧值
    await Future.delayed(const Duration(milliseconds: 350));
    await _refresh();
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          detailBlurBackground(_book.coverPath),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
              children: [
                detailTopBar(context),
                const SizedBox(height: 10),
                _header(),
                if (_book.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _descBlock(),
                ],
                const SizedBox(height: 18),
                _infoBlock(),
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _openReader,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      _book.progressPercent > 0.001 ? '继续阅读' : '开始阅读',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        detailCover(coverPath: _book.coverPath, onTap: _onCoverTap),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        _book.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kSerifFamily,
                          fontSize: 19,
                          height: 1.32,
                          fontWeight: FontWeight.w600,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: _rename,
                      child: const Padding(
                        padding: EdgeInsets.only(top: 3, left: 2),
                        child: Icon(Icons.edit_outlined, size: 16, color: AppColors.ink2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.person_outline, size: 14, color: AppColors.ink2),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _book.author.isEmpty ? '佚名' : _book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: AppColors.ink2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${_book.wordLabel} · ${_book.progressLabel}',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.ink2),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _descBlock() {
    final text = _book.description.trim();
    return GestureDetector(
      onTap: () => setState(() => _descExpanded = !_descExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            maxLines: _descExpanded ? null : 4,
            overflow: _descExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, height: 1.65, color: AppColors.ink2),
          ),
          const SizedBox(height: 6),
          Text(
            _descExpanded ? '收起' : '展开',
            style: const TextStyle(fontSize: 12.5, color: AppColors.accent),
          ),
        ],
      ),
    );
  }

  Widget _infoBlock() {
    return detailInfoCard([
      detailRow('书籍类型', _book.format.toUpperCase()),
      detailRow('章节数量', '${_book.chapterCount} 章'),
      detailRow('文件大小', fmtSize(_book.fileSize)),
      detailRow('累计阅读', _book.readTimeLabel),
      detailRow('导入日期', fmtDate(_book.addedAt)),
      detailRow('最近阅读', _book.lastReadAt == null ? '还没读过' : fmtDate(_book.lastReadAt!)),
    ]);
  }
}
