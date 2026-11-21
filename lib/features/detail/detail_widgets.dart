import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

// ======================================================================
// 详情页共用的小部件（书籍详情 / 分组详情）
// ======================================================================

/// 点封面弹出的操作菜单。返回 'replace' / 'save' / null。
Future<String?> showCoverSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: AppColors.ink),
            title: const Text('更换封面', style: TextStyle(color: AppColors.ink)),
            onTap: () => Navigator.pop(ctx, 'replace'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined, color: AppColors.ink),
            title: const Text('保存封面到本地', style: TextStyle(color: AppColors.ink)),
            onTap: () => Navigator.pop(ctx, 'save'),
          ),
          ListTile(
            leading: const Icon(Icons.close, color: AppColors.ink2),
            title: const Text('取消', style: TextStyle(color: AppColors.ink2)),
            onTap: () => Navigator.pop(ctx),
          ),
        ],
      ),
    ),
  );
}

/// 顶部虚化封面背景：模糊的大图往下渐隐成页面底色。
Widget detailBlurBackground(String? coverPath, {double height = 380}) {
  final ok = coverPath != null && coverPath.isNotEmpty && File(coverPath).existsSync();
  if (!ok) return const SizedBox.shrink();
  return Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: height,
    child: IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 32, sigmaY: 32),
            child: Image.file(
              File(coverPath!),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.bg.withValues(alpha: 0.28),
                  AppColors.bg.withValues(alpha: 0.70),
                  AppColors.bg,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 左上角封面（可点，点开是换封面/保存封面）
Widget detailCover({
  required String? coverPath,
  required VoidCallback onTap,
  Widget? fallback,
  double width = 96,
  double height = 136,
}) {
  final ok = coverPath != null && coverPath.isNotEmpty && File(coverPath).existsSync();
  return GestureDetector(
    onTap: onTap,
    child: Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ok
            ? Image.file(
                File(coverPath!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback ?? _coverPlaceholder(),
              )
            : (fallback ?? _coverPlaceholder()),
      ),
    ),
  );
}

Widget _coverPlaceholder() => Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFE9E3D8), Color(0xFFDDD4C4)],
        ),
      ),
      child: const Icon(Icons.menu_book_rounded, color: AppColors.accent, size: 30),
    );

/// 白色圆角信息卡；子项之间自动加分隔线。
Widget detailInfoCard(List<Widget> rows) {
  final children = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    children.add(rows[i]);
    if (i != rows.length - 1) {
      children.add(const Divider(height: 1, thickness: 0.5, color: AppColors.line, indent: 14));
    }
  }
  return Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(children: children),
  );
}

/// 信息卡里的一行：左标签右值。
/// 注意别用 Spacer —— 它会把右侧值挤到最小宽度，日期这类长文本就会被折成两行。
Widget detailRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    child: Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 14, color: AppColors.ink)),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: AppColors.ink2),
          ),
        ),
      ],
    ),
  );
}

/// 详情页顶部返回栏
Widget detailTopBar(BuildContext context, {String? title, VoidCallback? onBack}) {
  return Row(
    children: [
      IconButton(
        onPressed: onBack ?? () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.arrow_back_ios_new, size: 19, color: AppColors.ink),
        splashRadius: 22,
      ),
      if (title != null)
        Expanded(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
        ),
      if (title != null) const SizedBox(width: 44),
    ],
  );
}

String fmtDate(int ms) {
  if (ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}年${d.month}月${d.day}日 ${two(d.hour)}:${two(d.minute)}';
}

String fmtSize(int bytes) {
  if (bytes <= 0) return '—';
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
