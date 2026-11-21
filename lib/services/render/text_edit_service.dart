import 'dart:io';
import 'package:path/path.dart' as p;

import '../../data/models/book.dart';

/// 永久修改阅读文本：直接读写书目录下的 index.html。
///
/// index.html 是所有章节拼成的单页，结构为
/// `<section class="ch" data-spine="N" data-title="...">...</section>`。
/// 只有重新导入书才会重建 index.html，所以改这里是最简单可靠的永久修改方式。
///
/// 定位坐标与 reader.js 保持一致：
/// - spine：章节序号（section 的 data-spine）
/// - blockIndex：段落在章节内的序号（顶层块级元素，从 0 开始）
/// - 词偏移：词在段落纯文本里的起始字符下标
class TextEditService {
  static const Set<String> _blockTags = {
    'div', 'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'blockquote', 'li', 'section', 'table', 'ul', 'ol',
    'pre', 'figure', 'figcaption', 'dl', 'dt', 'dd', 'center',
  };

  static String _htmlPath(Book book) => p.join(book.bookDir, 'index.html');

  // ==================================================================
  // 对外操作
  // ==================================================================

  /// 替换全书 / 本章节：对目标 section 的正文做纯文本级全局替换。
  /// [scope]：'book' 全书，'chapter' 仅 [spine] 章节。
  static Future<bool> replaceAll({
    required Book book,
    required String scope,
    required int spine,
    required String from,
    required String to,
  }) async {
    if (from.isEmpty) return false;
    final html = await _read(book);
    if (html == null) return false;

    final out = StringBuffer();
    var last = 0;
    for (final m in _sectionRe.allMatches(html)) {
      out.write(html.substring(last, m.start));
      final sSpine = int.parse(m.group(2)!);
      var inner = m.group(3)!;
      if (scope == 'book' || sSpine == spine) {
        inner = inner.replaceAll(from, to);
      }
      out.write('${m.group(1)}$inner${m.group(4)}');
      last = m.end;
    }
    out.write(html.substring(last));
    return _write(book, out.toString());
  }

  /// 仅替换此处：定位 spine + blockIndex + 段落内词偏移，替换长按的那一个词。
  static Future<bool> replaceHere({
    required Book book,
    required int spine,
    required int blockIndex,
    required int wordOffsetInPara,
    required String from,
    required String to,
  }) async {
    if (from.isEmpty) return false;
    final html = await _read(book);
    if (html == null) return false;

    // 仅替换此处：定位到段落后，替换段落内 from 的第一次出现。
    // 不用字符偏移定位——HTML 实体（&nbsp; 等）会让 JS 的纯文本偏移和源码偏移不一致。
    final result = _editBlock(
      html,
      spine,
      blockIndex,
      (block) => block.contains(from) ? block.replaceFirst(from, to) : block,
    );
    if (result == null) return false;
    return _write(book, result);
  }

  /// 删除段落：删除 spine 章节的第 blockIndex 个顶层块级元素。
  static Future<bool> deleteParagraph({
    required Book book,
    required int spine,
    required int blockIndex,
  }) async {
    final html = await _read(book);
    if (html == null) return false;
    final result = _editBlock(html, spine, blockIndex, (_) => '');
    if (result == null) return false;
    return _write(book, result);
  }

  // ==================================================================
  // 内部
  // ==================================================================

  static final RegExp _sectionRe = RegExp(
    r'(<section class="ch" data-spine="(\d+)"[^>]*>)([\s\S]*?)(</section>)',
  );

  static Future<String?> _read(Book book) async {
    try {
      final f = File(_htmlPath(book));
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _write(Book book, String html) async {
    try {
      await File(_htmlPath(book)).writeAsString(html, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 对 spine 章节的第 blockIndex 个块级元素执行 [edit]，返回改后的完整 html。
  /// 没找到则返回 null。
  static String? _editBlock(
    String html,
    int spine,
    int blockIndex,
    String Function(String block) edit,
  ) {
    for (final m in _sectionRe.allMatches(html)) {
      final sSpine = int.parse(m.group(2)!);
      if (sSpine != spine) continue;

      final inner = m.group(3)!;
      final blocks = _splitBlocks(inner);
      if (blockIndex < 0 || blockIndex >= blocks.length) return null;

      final edited = edit(blocks[blockIndex].html);
      blocks[blockIndex] =
          (html: edited, start: blocks[blockIndex].start, end: blocks[blockIndex].end);

      final buf = StringBuffer();
      for (final b in blocks) {
        buf.write(b.html);
      }
      // m.start / m.end 是整个 section 匹配的边界；group(1) 开标签、group(4) 闭标签
      return html.substring(0, m.start) +
          m.group(1)! +
          buf.toString() +
          m.group(4)! +
          html.substring(m.end);
    }
    return null;
  }

  /// 顶层块级元素：直接作为 section 子元素的块级标签。
  /// 返回它们在 [html] 中的位置与 HTML 片段。
  static List<({String html, int start, int end})> _splitBlocks(String html) {
    final blocks = <({String html, int start, int end})>[];
    final tagRe = RegExp(r'</?[a-zA-Z][a-zA-Z0-9:-]*\b[^>]*>');

    var depth = 0;
    var start = -1;

    for (final m in tagRe.allMatches(html)) {
      final raw = m.group(0)!;
      final isClose = raw.startsWith('</');
      final isSelfClose = raw.endsWith('/>');
      final tag = raw
          .replaceFirst(RegExp(r'^</?'), '')
          .split(RegExp(r'[\s>]'))
          .first
          .toLowerCase();

      if (!_blockTags.contains(tag)) continue;

      if (!isClose && !isSelfClose) {
        if (depth == 0) {
          if (start >= 0) blocks.add((html: html.substring(start, m.start), start: start, end: m.start));
          start = m.start;
        }
        depth++;
      } else if (isClose) {
        if (depth > 0) depth--;
        if (depth == 0 && start >= 0) {
          blocks.add((html: html.substring(start, m.end), start: start, end: m.end));
          start = -1;
        }
      }
    }
    if (start >= 0) {
      blocks.add((html: html.substring(start), start: start, end: html.length));
    }
    return blocks;
  }
}
