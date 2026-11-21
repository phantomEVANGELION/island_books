import 'dart:io';

import 'package:flutter/material.dart';

/// 配色取自书架原型的暖白纸感
class AppColors {
  static const bg = Color(0xFFF7F5F0);
  static const card = Color(0xFFFFFFFF);
  static const ink = Color(0xFF2B2B2B);
  static const ink2 = Color(0xFF8A8378);
  static const accent = Color(0xFF7A6A58);
  static const line = Color(0x1F2B2B2B);
}

/// 衬线字体族名。
///
/// Android 认识 'serif' 这个通用族名（映射到 Noto Serif），iOS 不认识 ——
/// 在 iOS 上传 'serif' 会静默回落到系统无衬线体（PingFang SC），
/// 书架上那些本该有衬线味道的书名就变成了黑体。
/// iOS 上直接用系统自带的宋体。
final String kSerifFamily = Platform.isIOS ? 'Songti SC' : 'serif';

/// 阅读主题（与 reader.css 里的 CSS 变量保持一致）
class ReaderTheme {
  final String id;
  final String name;
  final Color bg;
  final Color fg;

  const ReaderTheme(this.id, this.name, this.bg, this.fg);

  static const List<ReaderTheme> all = [
    ReaderTheme('paper', '纸白', Color(0xFFFAF8F3), Color(0xFF2B2B2B)),
    ReaderTheme('sepia', '米黄', Color(0xFFF5E9D3), Color(0xFF3A2E20)),
    ReaderTheme('green', '护眼', Color(0xFFCCE8CF), Color(0xFF22301F)),
    ReaderTheme('night', '夜间', Color(0xFF1C1C1E), Color(0xFFC8C8C8)),
    ReaderTheme('black', '纯黑', Color(0xFF000000), Color(0xFF9A9A9A)),
  ];

  static ReaderTheme byId(String id) =>
      all.firstWhere((t) => t.id == id, orElse: () => all.first);
}

ThemeData buildAppTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      surface: AppColors.bg,
    ),
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    ),
  );
}
