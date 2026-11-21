import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 内置字体的分发。
///
/// 为什么复制到应用文档目录而不是直接让 WebView 读 assets：
/// WebView 加载的是 bookDir/index.html，用 file:// 访问 assets 需要
/// allowFileAccessFromFileURLs，而该开关在新版 Android 默认关闭且
/// webview_flutter 没有稳定暴露。复制到文档目录后可以用**相对路径**
/// `../../fonts/xxx` 引用，同源、无权限问题。
class FontService {
  static const List<_FontDef> fonts = [
    _FontDef('ReaderSerif', 'assets/fonts/NotoSerifSC-Regular.otf', 'NotoSerifSC-Regular.otf'),
    _FontDef('ReaderTang', 'assets/fonts/HanyiSentyTang.ttf', 'HanyiSentyTang.ttf'),
    _FontDef('ReaderWen', 'assets/fonts/SentyWEN2017.ttf', 'SentyWEN2017.ttf'),
  ];

  static Directory? _cache;

  static Future<Directory> ensure() async {
    if (_cache != null) return _cache!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'fonts'));
    if (!await dir.exists()) await dir.create(recursive: true);

    for (final f in fonts) {
      final target = File(p.join(dir.path, f.fileName));
      var needCopy = true;
      if (await target.exists()) {
        // 上次可能复制中断，太小就重来
        needCopy = (await target.length()) < 1000000;
      }
      if (needCopy) {
        try {
          final data = await rootBundle.load(f.asset);
          await target.writeAsBytes(data.buffer.asUint8List(), flush: false);
        } catch (_) {
          // 字体缺失不影响正文阅读，只是回落到系统字体
        }
      }
    }
    _cache = dir;
    return dir;
  }

  /// 生成 @font-face 片段。
  /// index.html 位于 <docs>/books/<id>/，字体位于 <docs>/fonts/，
  /// 所以相对路径是 ../../fonts/
  static Future<String> buildCss() async {
    final dir = await ensure();
    final buf = StringBuffer();
    for (final f in fonts) {
      if (await File(p.join(dir.path, f.fileName)).exists()) {
        buf.writeln(
          "@font-face{font-family:'${f.family}';src:url('../../fonts/${f.fileName}');font-display:swap;}",
        );
      }
    }
    return buf.toString();
  }
}

class _FontDef {
  final String family;
  final String asset;
  final String fileName;
  const _FontDef(this.family, this.asset, this.fileName);
}
