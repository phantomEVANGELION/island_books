import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'epub_parser.dart';
import 'font_deobfuscator.dart';

/// 把 EPUB 里「被 manifest 引用到的文件」解压到书籍目录。
///
/// 不整包解压是刻意的：有些 epub 塞了大量垃圾数据（《无职转生》02 里
/// 有 20 个 `extra/data_*.bin`，合计 62MB），只解压白名单能把 69MB 压到 8MB。
class EpubExtractor {
  /// 返回实际写出的文件数
  static Future<int> extract(
    Archive archive,
    EpubPackage pkg,
    Directory targetDir,
  ) async {
    var count = 0;
    for (final name in pkg.neededEntries) {
      final file = archive.findFile(name);
      if (file == null || !file.isFile) continue;

      final safe = _safePath(name);
      if (safe == null) continue;

      final out = File('${targetDir.path}/$safe');
      try {
        await out.parent.create(recursive: true);
        final data = file.content;
        var bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);

        // 被「字体混淆」的字体先还原，否则 @font-face 加载不了、只能回落系统字体。
        // 只有解出来确实是合法字体才替换 —— 解错就写原样，宁可回落也别写坏文件。
        final alg = pkg.obfuscatedFonts[name];
        if (alg != null) {
          final fixed = FontDeobfuscator.deobfuscate(bytes, alg, pkg.uniqueIdentifier);
          if (FontDeobfuscator.looksLikeFont(fixed)) bytes = fixed;
        }

        await out.writeAsBytes(bytes, flush: false);
        count++;
      } catch (_) {
        // 单个文件失败不影响整本书
      }
    }
    return count;
  }

  /// 单独抽出封面，方便书架直接加载
  static Future<String?> extractCover(
    Archive archive,
    EpubPackage pkg,
    Directory targetDir,
  ) async {
    final entry = pkg.coverEntry;
    if (entry == null) return null;
    final file = archive.findFile(entry);
    if (file == null) return null;

    final ext = _extOf(entry);
    final out = File('${targetDir.path}/cover$ext');
    try {
      final data = file.content;
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      await out.writeAsBytes(bytes, flush: false);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// zip 里的路径可能含 Windows 不允许的字符，也可能有 `../` 越界
  static String? _safePath(String name) {
    var p = name.replaceAll('\\', '/');
    // 防目录穿越
    if (p.contains('..')) {
      final parts = <String>[];
      for (final seg in p.split('/')) {
        if (seg == '..') {
          if (parts.isNotEmpty) parts.removeLast();
        } else if (seg != '.' && seg.isNotEmpty) {
          parts.add(seg);
        }
      }
      p = parts.join('/');
    }
    // Windows 非法字符替换
    p = p.replaceAll(RegExp(r'[:*?"<>|]'), '_');
    // 去掉盘符前缀之类
    if (p.startsWith('/')) p = p.substring(1);
    if (p.isEmpty) return null;
    return p;
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0) return '.jpg';
    return path.substring(i).toLowerCase();
  }
}
