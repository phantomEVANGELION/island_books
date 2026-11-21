import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:island_books/services/epub/epub_parser.dart';
import 'package:island_books/services/epub/font_deobfuscator.dart';

/// 用一本真实的「Adobe 字体混淆」epub 做回归测试。
/// 样本不存在时自动跳过（换机器跑不会失败）。
const _sample = r'D:\春物\我的青春恋爱物语果然有问题 01.epub';

Archive? _load() {
  final file = File(_sample);
  if (!file.existsSync()) return null;
  return ZipDecoder().decodeBytes(file.readAsBytesSync());
}

void main() {
  test('只有字体混淆的 epub 不应该被判成 DRM', () {
    final archive = _load();
    if (archive == null) {
      markTestSkipped('样本不存在: $_sample');
      return;
    }
    final pkg = EpubParser.parse(archive, fallbackTitle: '春物 01');
    // ignore: avoid_print
    print('title=${pkg.title} chapters=${pkg.chapters.length} drm=${pkg.hasDrm} '
        'fonts=${pkg.obfuscatedFonts.length} uid=${pkg.uniqueIdentifier}');
    expect(pkg.hasDrm, isFalse, reason: '只有字体混淆不应该算 DRM');
    expect(pkg.chapters.length, greaterThan(0));
    expect(pkg.obfuscatedFonts, isNotEmpty);
  });

  test('Adobe 字体混淆能还原成合法字体', () {
    final archive = _load();
    if (archive == null) {
      markTestSkipped('样本不存在: $_sample');
      return;
    }
    final pkg = EpubParser.parse(archive, fallbackTitle: '春物 01');
    final name = pkg.obfuscatedFonts.keys.firstWhere(
      (k) => k.toLowerCase().endsWith('.ttf'),
      orElse: () => '',
    );
    expect(name, isNotEmpty, reason: '应该有被混淆的 ttf');

    final raw = archive.findFile(name)!.content;
    final rawList = List<int>.from(raw);
    final fixed = FontDeobfuscator.deobfuscate(
      rawList,
      pkg.obfuscatedFonts[name]!,
      pkg.uniqueIdentifier,
    );
    // ignore: avoid_print
    print('font=$name raw=${FontDeobfuscator.looksLikeFont(rawList)} '
        'fixed=${FontDeobfuscator.looksLikeFont(fixed)} '
        'head=${fixed.take(4).toList()}');
    expect(FontDeobfuscator.looksLikeFont(rawList), isFalse, reason: '原文应该是混淆过的');
    expect(FontDeobfuscator.looksLikeFont(fixed), isTrue, reason: '还原后应该是合法字体');
  });
}
