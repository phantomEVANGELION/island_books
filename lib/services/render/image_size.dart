import 'dart:convert';

/// 从图片字节里读宽高（只解析文件头，不解码像素）。
///
/// 用途：给 <img> 预置 aspect-ratio，让图片还没下载时页面高度就是正确的 ——
/// 恢复阅读位置不用等图片、也不会因为图片加载把正文顶下去。
class ImageSizes {
  const ImageSizes._();

  static (int, int)? detect(List<int> b) {
    final png = _png(b);
    if (png != null) return png;
    final jpg = _jpeg(b);
    if (jpg != null) return jpg;
    final gif = _gif(b);
    if (gif != null) return gif;
    final webp = _webp(b);
    if (webp != null) return webp;
    return _svg(b);
  }

  static (int, int)? _png(List<int> b) {
    if (b.length < 24) return null;
    if (b[0] != 0x89 || b[1] != 0x50 || b[2] != 0x4E || b[3] != 0x47) return null;
    final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    return (w > 0 && h > 0) ? (w, h) : null;
  }

  static (int, int)? _jpeg(List<int> b) {
    if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      if (len <= 0) return null;
      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (i + 8 >= b.length) return null;
        final h = (b[i + 5] << 8) | b[i + 6];
        final w = (b[i + 7] << 8) | b[i + 8];
        return (w > 0 && h > 0) ? (w, h) : null;
      }
      i += 2 + len;
    }
    return null;
  }

  static (int, int)? _gif(List<int> b) {
    if (b.length < 10) return null;
    if (b[0] != 0x47 || b[1] != 0x49 || b[2] != 0x46) return null;
    final w = b[6] | (b[7] << 8);
    final h = b[8] | (b[9] << 8);
    return (w > 0 && h > 0) ? (w, h) : null;
  }

  /// WebP 分三种：有损(VP8 ) / 无损(VP8L) / 扩展(VP8X)
  static (int, int)? _webp(List<int> b) {
    if (b.length < 30) return null;
    if (b[0] != 0x52 || b[1] != 0x49 || b[2] != 0x46 || b[3] != 0x46) return null;
    if (b[8] != 0x57 || b[9] != 0x45 || b[10] != 0x42 || b[11] != 0x50) return null;
    final kind = String.fromCharCodes(b.sublist(12, 16));
    if (kind == 'VP8 ') {
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      final w = (b[26] | (b[27] << 8)) & 0x3FFF;
      final h = (b[28] | (b[29] << 8)) & 0x3FFF;
      return (w > 0 && h > 0) ? (w, h) : null;
    }
    if (kind == 'VP8L') {
      if (b[20] != 0x2F) return null;
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      final w = (bits & 0x3FFF) + 1;
      final h = ((bits >> 14) & 0x3FFF) + 1;
      return (w > 0 && h > 0) ? (w, h) : null;
    }
    if (kind == 'VP8X') {
      final w = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
      final h = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
      return (w > 0 && h > 0) ? (w, h) : null;
    }
    return null;
  }

  /// SVG：读 viewBox，退而求其次读 width/height 属性
  static (int, int)? _svg(List<int> b) {
    if (b.length < 16) return null;
    final head = utf8.decode(b.sublist(0, b.length > 2048 ? 2048 : b.length),
        allowMalformed: true);
    if (!head.contains('<svg')) return null;
    final vb = RegExp(
      r'''viewBox\s*=\s*["']\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)''',
      caseSensitive: false,
    ).firstMatch(head);
    if (vb != null) {
      final w = double.tryParse(vb.group(1)!);
      final h = double.tryParse(vb.group(2)!);
      if (w != null && h != null && w > 0 && h > 0) return (w.round(), h.round());
    }
    final wm = RegExp(r'''<svg[^>]*\bwidth\s*=\s*["']([\d.]+)''', caseSensitive: false)
        .firstMatch(head);
    final hm = RegExp(r'''<svg[^>]*\bheight\s*=\s*["']([\d.]+)''', caseSensitive: false)
        .firstMatch(head);
    final w = double.tryParse(wm?.group(1) ?? '');
    final h = double.tryParse(hm?.group(1) ?? '');
    if (w != null && h != null && w > 0 && h > 0) return (w.round(), h.round());
    return null;
  }
}
