import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../data/models/chapter.dart';
import '../epub/epub_parser.dart';
import 'font_service.dart';
import 'image_size.dart';

/// 生成阅读用的单页 HTML。
///
/// 为什么要把所有章节拼成一个 HTML：滚动模式要求章节首尾相接，
/// 一章一个 WebView 会在切换时闪白、滚动位置断裂。
///
/// 关键难点：章节里的 `../Images/a.jpg` 是相对**章节所在目录**的，
/// 内联到根目录的 index.html 后路径就错了。所以这里逐章把
/// src / href 重写成「相对书籍根目录」的路径。
class ReaderHtmlBuilder {
  static Future<File> build({
    required Archive archive,
    required EpubPackage pkg,
    required Directory bookDir,
    required List<Chapter> chapters,
    required String bookTitle,
  }) async {
    // 1. 把引擎资源拷到书目录（每个书目录一份，方便调试）
    final css = await rootBundle.loadString('assets/reader/reader.css');
    final js = await rootBundle.loadString('assets/reader/reader.js');
    await File(p.join(bookDir.path, 'reader.css')).writeAsString(css);
    await File(p.join(bookDir.path, 'reader.js')).writeAsString(js);

    // 2. 逐章拼 section
    final sections = StringBuffer();
    final tocItems = <Map<String, Object?>>[];

    // zip 条目索引：给 <img> 预置宽高比要用（见 _injectImageSizes）
    final entries = <String, ArchiveFile>{};
    for (final f in archive.files) {
      entries[f.name] = f;
    }

    for (final ch in chapters) {
      final raw = _readChapter(archive, pkg, ch.href);
      if (raw == null) continue;

      final body = _extractBody(raw);
      if (body.trim().isEmpty) continue;

      // 章节所在目录（相对书籍根目录），用于重写相对路径
      final chapterDir = p.posix.dirname(p.posix.join(pkg.opfDir, ch.href));
      final fixed = _rewriteUrls(body, chapterDir);
      // 给图片预置宽高比：图片还没加载时页面高度就是正确的，
      // 恢复阅读位置时不用等图片，打开就是目标位置（视觉上和原生阅读器一样快）
      final sized = _injectImageSizes(fixed, entries);

      sections.write('<section class="ch" data-spine="${ch.spineIndex}" '
          'data-title="${_escAttr(ch.title)}">$sized</section>\n');

      if (ch.title.isNotEmpty) {
        tocItems.add({'s': ch.spineIndex, 't': ch.title, 'l': ch.level});
      }
    }

    // 3. 书内样式表（每本书文件名都不一样，必须动态列）
    final cssLinks = pkg.cssHrefs
        .map((h) => p.posix.normalize(p.posix.join(pkg.opfDir, h)))
        .map((h) => '<link rel="stylesheet" href="${_escAttr(h)}">')
        .join('\n');

    final tocJson = jsonEncode(tocItems).replaceAll('</', '<\\/');

    // 内置字体的 @font-face（复制到共享目录后用相对路径引用）
    final fontCss = await FontService.buildCss();

    final html = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<title>${_escHtml(bookTitle)}</title>
$cssLinks
<style>
$fontCss</style>
<link rel="stylesheet" href="reader.css">
</head>
<body>
<div id="book">$sections</div>

<div id="hud" class="hud hidden">
  <div class="hud-bar">
    <button id="btnBack">‹</button>
    <span id="hudTitle">${_escHtml(bookTitle)}</span>
    <button id="btnMenu">⋯</button>
  </div>
  <div class="hud-bottom">
    <div class="hud-nav">
      <button id="btnPrevCh">上一章</button>
      <input type="range" id="progress" min="0" max="1000" value="0">
      <button id="btnNextCh">下一章</button>
    </div>
    <div class="hud-row"><span id="hudPercent">0%</span></div>
    <div class="hud-actions">
      <button id="btnToc">目录</button>
      <button id="btnFont">字体</button>
      <button id="btnTheme">主题</button>
      <button id="btnFunc">功能</button>
    </div>
  </div>
</div>

<div class="toc-mask hidden" id="tocMask"></div>
<aside class="toc hidden" id="toc">
  <div class="toc-head">
    <div class="toc-tabs">
      <button class="toc-tab active" data-tab="toc">目录</button>
      <button class="toc-tab" data-tab="bm">书签</button>
    </div>
  </div>
  <div class="toc-list" id="tocList"></div>
  <div class="bm-list" id="bmList" style="display:none"></div>
</aside>

<div id="panel" class="panel hidden" data-mode="font">
  <div class="panel-handle"></div>
  <div class="panel-row" data-row="font">
    <span class="panel-label">字号</span>
    <button class="step" data-k="fontSize" data-d="-1">A−</button>
    <span class="panel-val" id="vFontSize">18</span>
    <button class="step" data-k="fontSize" data-d="1">A+</button>
  </div>
  <div class="panel-row" data-row="font">
    <span class="panel-label">字体</span>
    <div class="font-row">
      <button class="font-btn" data-font="" aria-pressed="true">默认</button>
      <button class="font-btn" data-font="'ReaderSerif', 'Noto Serif SC', serif">宋体</button>
      <button class="font-btn" data-font="'ReaderSans', 'Noto Sans SC', sans-serif">黑体</button>
      <button class="font-btn" data-font="'ReaderTang', serif">闲情</button>
      <button class="font-btn" data-font="'ReaderWen', serif">文楷</button>
    </div>
  </div>
  <div class="panel-row themes" data-row="theme">
    <span class="panel-label">主题</span>
    <button class="theme" data-t="paper" style="background:#FAF8F3;color:#2B2B2B">纸白</button>
    <button class="theme" data-t="sepia" style="background:#F5E9D3;color:#3A2E20">米黄</button>
    <button class="theme" data-t="green" style="background:#CCE8CF;color:#22301F">护眼</button>
    <button class="theme" data-t="night" style="background:#1C1C1E;color:#C8C8C8">夜间</button>
    <button class="theme" data-t="black" style="background:#000000;color:#9A9A9A">纯黑</button>
  </div>
  <div class="panel-row" data-row="theme">
    <span class="panel-label">行距</span>
    <button class="step" data-k="lineHeight" data-d="-1">−</button>
    <input type="range" class="slider" data-k="lineHeight" min="12" max="26" value="18">
    <button class="step" data-k="lineHeight" data-d="1">+</button>
  </div>
  <div class="panel-row" data-row="theme">
    <span class="panel-label">段距</span>
    <button class="step" data-k="paraSpacing" data-d="-1">−</button>
    <input type="range" class="slider" data-k="paraSpacing" min="0" max="20" value="8">
    <button class="step" data-k="paraSpacing" data-d="1">+</button>
  </div>
  <div class="panel-row" data-row="theme">
    <span class="panel-label">边距</span>
    <button class="step" data-k="pageMargin" data-d="-1">−</button>
    <input type="range" class="slider" data-k="pageMargin" min="8" max="48" value="20">
    <button class="step" data-k="pageMargin" data-d="1">+</button>
  </div>
  <div class="panel-row" data-row="func">
    <span class="panel-label">翻页方式</span>
    <div class="chip-row">
      <button class="chip" data-page="scroll" aria-pressed="true">滑动翻页</button>
      <button class="chip" data-page="tap" aria-pressed="false">点击翻页</button>
    </div>
  </div>
  <div class="panel-row" data-row="func">
    <span class="panel-label">繁简转化</span>
    <div class="chip-row">
      <button class="chip" data-convert="origin" aria-pressed="true">与原文一致</button>
      <button class="chip" data-convert="simp" aria-pressed="false">转为简体</button>
      <button class="chip" data-convert="trad" aria-pressed="false">轉為繁體</button>
    </div>
  </div>
</div>

<script id="toc-data" type="application/json">$tocJson</script>
<script src="reader.js"></script>
</body>
</html>
''';

    final out = File(p.join(bookDir.path, 'index.html'));
    await out.writeAsString(html, encoding: utf8);
    return out;
  }

  static String? _readChapter(Archive archive, EpubPackage pkg, String href) {
    final full = p.posix.normalize(p.posix.join(pkg.opfDir, href));
    var f = archive.findFile(full);
    if (f == null) {
      // 路径可能被 URL 编码
      try {
        f = archive.findFile(Uri.decodeComponent(full));
      } catch (_) {}
    }
    if (f == null) return null;
    final data = f.content;
    if (data is List<int>) {
      var bytes = data;
      if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        bytes = bytes.sublist(3);
      }
      return utf8.decode(bytes, allowMalformed: true);
    }
    return null;
  }

  static String _extractBody(String xhtml) {
    final m = RegExp(r'<body[^>]*>([\s\S]*?)</body>', caseSensitive: false).firstMatch(xhtml);
    if (m != null) return m.group(1)!;
    // 没有 body 标签就整段返回（去掉 xml 声明和 doctype）
    return xhtml
        .replaceAll(RegExp(r'<\?xml[\s\S]*?\?>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<!DOCTYPE[\s\S]*?>', caseSensitive: false), '');
  }

  /// 把 src / href 的相对路径重写成相对书籍根目录
  static String _rewriteUrls(String html, String chapterDir) {
    return html.replaceAllMapped(
      RegExp(r'''(src|href)\s*=\s*"([^"]*)"''', caseSensitive: false),
      (m) {
        final attr = m.group(1)!;
        final value = m.group(2)!;
        if (value.isEmpty ||
            value.startsWith('http://') ||
            value.startsWith('https://') ||
            value.startsWith('data:') ||
            value.startsWith('#') ||
            value.startsWith('javascript:') ||
            value.startsWith('mailto:')) {
          return m.group(0)!;
        }
        final resolved = p.posix.normalize(p.posix.join(chapterDir, value));
        // 越界到书籍根目录之外就放弃重写
        if (resolved.startsWith('..')) return m.group(0)!;
        return '$attr="$resolved"';
      },
    );
  }

  /// 给每个 <img> 写死「宽度上限 + 宽高比」。
  ///
  /// 图片没加载时浏览器不知道它多高，整章高度就会偏小，
  /// 恢复阅读位置只能等图片加载完才知道该滚到哪 —— 这就是「打开慢」的根源。
  /// 预置 aspect-ratio 之后，布局在图片解码前就已经稳定，可以立刻定位。
  static String _injectImageSizes(String html, Map<String, ArchiveFile> entries) {
    if (!html.contains('<img')) return html;
    return html.replaceAllMapped(
      RegExp(r'<img\b[^>]*>', caseSensitive: false),
      (m) {
        final tag = m.group(0)!;
        if (tag.contains('data-ar=')) return tag;
        final sm = RegExp(r'''src\s*=\s*"([^"]*)"''', caseSensitive: false).firstMatch(tag);
        if (sm == null) return tag;
        final file = entries[sm.group(1)!];
        if (file == null) return tag;
        final size = ImageSizes.detect(file.content);
        if (size == null) return tag;

        final w = size.$1;
        final h = size.$2;
        final decl = 'width:min(100%,${w}px);aspect-ratio:$w/$h';

        if (RegExp(r'''style\s*=\s*"[^"]*"''', caseSensitive: false).hasMatch(tag)) {
          // 有 style 也要打 data-ar 标记：否则后台补丁会认为这张图「还没处理」，
          // 每次启动都再追加一遍 aspect-ratio
          return tag
              .replaceFirstMapped(
                RegExp(r'''style\s*=\s*"([^"]*)"''', caseSensitive: false),
                (mm) => 'style="${mm.group(1)};$decl"',
              )
              .replaceFirst(RegExp(r'<img\b', caseSensitive: false), '<img data-ar="1"');
        }
        return tag.replaceFirstMapped(
          RegExp(r'(\s*/)?>$'),
          (mm) => ' style="$decl" data-ar="1"${mm.group(1) ?? ''}>',
        );
      },
    );
  }

  static String _escAttr(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
