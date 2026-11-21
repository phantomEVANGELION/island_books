import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/book_group.dart';
import '../../data/repositories/book_repository.dart';
import '../bookshelf/bookshelf_page.dart';
import 'cover_actions.dart';
import 'detail_widgets.dart';

/// 分组详情页：点书架上的分组封面进入。
class GroupDetailPage extends StatefulWidget {
  final BookGroup group;

  const GroupDetailPage({super.key, required this.group});

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> {
  final _repo = BookRepository();
  late BookGroup _group = widget.group;
  List<BookGroup> _allGroups = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final id = _group.id;
    if (id == null) return;
    final g = await _repo.getGroup(id);
    final all = await _repo.listGroups();
    if (!mounted) return;
    setState(() {
      if (g != null) _group = g;
      _allGroups = all;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  String get _parentLabel {
    if (_group.parentId == null) return '顶层书架';
    for (final g in _allGroups) {
      if (g.id == _group.parentId) return g.name;
    }
    return '顶层书架';
  }

  // ---------------------------------------------------------------- 操作

  Future<void> _onCoverTap() async {
    final action = await showCoverSheet(context);
    if (!mounted || action == null) return;

    if (action == 'replace') {
      final path = await CoverActions.pickFromGallery(_group.id ?? 0);
      if (path == null || !mounted) return;
      if (_group.id != null) {
        await _repo.setGroupCover(_group.id!, path);
        setState(() => _group = _group.copyWith(coverPath: path));
        _toast('封面已更换');
      }
    } else if (action == 'save') {
      final path = _group.coverPath;
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        _toast('这个分组还没有封面');
        return;
      }
      final ok = await CoverActions.saveAs(path, _group.name);
      _toast(ok ? '封面已保存' : '已取消');
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _group.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '分组名'),
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
    if (name == null || name.isEmpty || _group.id == null) return;
    await _repo.renameGroup(_group.id!, name);
    if (!mounted) return;
    setState(() => _group = _group.copyWith(name: name));
    _toast('已重命名');
  }

  Future<void> _openGroup() async {
    final id = _group.id;
    if (id == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookshelfPage(groupId: id, groupName: _group.name),
      ),
    );
    await _refresh();
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          detailBlurBackground(_group.coverPath),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
              children: [
                detailTopBar(context, title: '分组详情'),
                const SizedBox(height: 12),
                _headerCard(),
                const SizedBox(height: 14),
                detailInfoCard([
                  detailRow('分组所属', _parentLabel),
                  detailRow('书籍数量', '${_group.bookCount}'),
                  detailRow('子分组数量', '${_group.childGroupCount}'),
                ]),
                const SizedBox(height: 14),
                detailInfoCard([
                  detailRow('创建日期', fmtDate(_group.createdAt)),
                  detailRow(
                    '最近阅读',
                    _group.lastReadAt == null ? '还没读过' : fmtDate(_group.lastReadAt!),
                  ),
                ]),
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _openGroup,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text(
                      '进入分组',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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

  Widget _headerCard() {
    final stats = <String>[
      if (_group.wordCount > 0) _group.wordLabel,
      if (_group.readSeconds > 0) '已读 ${_group.readTimeLabel}',
      if (_group.bookCount > 0) _group.progressLabel,
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          detailCover(
            coverPath: _group.coverPath,
            onTap: _onCoverTap,
            width: 78,
            height: 108,
            fallback: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFE9E3D8), Color(0xFFDDD4C4)],
                ),
              ),
              child: const Icon(Icons.folder_rounded, color: AppColors.accent, size: 28),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _group.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: kSerifFamily,
                            fontSize: 18,
                            height: 1.3,
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
                          child: Icon(Icons.edit_outlined, size: 15, color: AppColors.ink2),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    stats.isEmpty ? '空分组' : stats.join(' · '),
                    style: const TextStyle(fontSize: 12.5, color: AppColors.ink2),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
