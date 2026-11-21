import 'dart:convert';

/// 阅读设置。所有字段最终都会变成注入 WebView 的 CSS 变量。
class ReaderConfig {
  /// 字号 px，12 ~ 34
  final double fontSize;

  /// 行距倍数，1.2 ~ 2.6
  final double lineHeight;

  /// 段间距 em，0 ~ 2.0
  final double paraSpacing;

  /// 左右页边距 px，8 ~ 48
  final double pageMargin;

  /// 字体族名，空字符串表示系统默认
  final String fontFamily;

  /// paper / sepia / green / night / black
  final String themeId;

  /// scroll（上下滚动，默认） / page（左右翻页）
  final String mode;

  /// 屏幕亮度 0.2 ~ 1.0
  final double brightness;

  const ReaderConfig({
    this.fontSize = 18,
    this.lineHeight = 1.8,
    this.paraSpacing = 0.8,
    this.pageMargin = 20,
    this.fontFamily = '',
    this.themeId = 'paper',
    this.mode = 'scroll',
    this.brightness = 1.0,
  });

  static const ReaderConfig defaults = ReaderConfig();

  factory ReaderConfig.fromJson(Map<String, Object?> m) => ReaderConfig(
        fontSize: (m['fontSize'] as num?)?.toDouble() ?? 18,
        lineHeight: (m['lineHeight'] as num?)?.toDouble() ?? 1.8,
        paraSpacing: (m['paraSpacing'] as num?)?.toDouble() ?? 0.8,
        pageMargin: (m['pageMargin'] as num?)?.toDouble() ?? 20,
        fontFamily: (m['fontFamily'] as String?) ?? '',
        themeId: (m['themeId'] as String?) ?? 'paper',
        mode: (m['mode'] as String?) ?? 'scroll',
        brightness: (m['brightness'] as num?)?.toDouble() ?? 1.0,
      );

  Map<String, Object?> toJson() => {
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'paraSpacing': paraSpacing,
        'pageMargin': pageMargin,
        'fontFamily': fontFamily,
        'themeId': themeId,
        'mode': mode,
        'brightness': brightness,
      };

  String encode() => jsonEncode(toJson());

  static ReaderConfig decode(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      return ReaderConfig.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      return defaults;
    }
  }

  /// 转成注入 WebView 的 CSS 变量表
  Map<String, String> toCssVars() => {
        '--r-font-size': '${fontSize}px',
        '--r-line-height': '$lineHeight',
        '--r-para-gap': '${paraSpacing}em',
        '--r-margin': '${pageMargin}px',
        if (fontFamily.isNotEmpty) '--r-font': fontFamily,
      };

  ReaderConfig copyWith({
    double? fontSize,
    double? lineHeight,
    double? paraSpacing,
    double? pageMargin,
    String? fontFamily,
    String? themeId,
    String? mode,
    double? brightness,
  }) =>
      ReaderConfig(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        paraSpacing: paraSpacing ?? this.paraSpacing,
        pageMargin: pageMargin ?? this.pageMargin,
        fontFamily: fontFamily ?? this.fontFamily,
        themeId: themeId ?? this.themeId,
        mode: mode ?? this.mode,
        brightness: brightness ?? this.brightness,
      );
}
