import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

import 'font_deobfuscator.dart';

/// EPUB 解析结果：只有「书的结构」，不含文件内容。
class EpubPackage {
  final String title;
  final String author;
  final String language;

  /// 封面图片在 zip 里的条目名（已解析成实际名），可能为 null
  final String? coverEntry;

  /// OPF 文件在 zip 里的路径，例如 "OEBPS/content.opf"
  final String opfPath;

  /// OPF 所在目录，例如 "OEBPS"（可能为空串）
  final String opfDir;

  final List<EpubChapterInfo> chapters;

  /// 书内样式表（相对 OPF 目录）
  final List<String> cssHrefs;

  /// 需要解压出来的 zip 条目集合。
  /// 关键：只包含 manifest 引用到的文件 —— 有些书会塞几十 MB 的垃圾
  /// （《无职转生》里就有 20 个 62MB 的 data_*.bin），不筛会把硬盘吃光。
  final Set<String> neededEntries;

  /// 有 DRM 加密时不允许阅读
  final bool hasDrm;

  /// 被「字体混淆」加密的条目 → 算法 URI。
  /// 这些文件解压时要先还原，否则 @font-face 加载不了、只能回落系统字体。
  final Map<String, String> obfuscatedFonts;

  /// OPF 里的 unique-identifier（还原字体要用它算 key）
  final String uniqueIdentifier;

  /// 书籍简介（dc:description，已去掉 HTML 标签、压缩空白，可能为空）
  final String description;

  const EpubPackage({
    required this.title,
    required this.author,
    required this.language,
    required this.coverEntry,
    required this.opfPath,
    required this.opfDir,
    required this.chapters,
    required this.cssHrefs,
    required this.neededEntries,
    required this.hasDrm,
    this.obfuscatedFonts = const {},
    this.uniqueIdentifier = '',
    this.description = '',
  });
}

class EpubChapterInfo {
  final int spineIndex;

  /// 相对 OPF 目录，例如 "Text/chapter01.xhtml"
  final String href;

  final String title;
  final int level;
  final int charCount;

  const EpubChapterInfo({
    required this.spineIndex,
    required this.href,
    required this.title,
    this.level = 0,
    this.charCount = 0,
  });
}

class EpubParseException implements Exception {
  final String message;
  EpubParseException(this.message);
  @override
  String toString() => message;
}

/// EPUB 解析器。
///
/// 从真实书籍里踩出来的四个坑，这里全部处理：
/// 1. OPF 里的路径可能被 URL 编码（`%20`），zip 里是原始名 → [_EntryIndex]
/// 2. metadata 可能全空（书名作者都没有）→ 三级兜底
/// 3. zip 里可能有大量未被引用的垃圾文件 → [neededEntries] 白名单
/// 4. NCX 的 navPoint 在 navMap 里面，不是根节点直接子元素 → 从 navMap 开始递归
class EpubParser {
  static EpubPackage parse(Archive archive, {String? fallbackTitle}) {
    final index = _EntryIndex(archive);

    // ---- 1. container.xml 找 OPF
    final containerEntry = index.find('META-INF/container.xml');
    if (containerEntry == null) {
      throw EpubParseException('不是有效的 EPUB：缺少 META-INF/container.xml');
    }
    final containerXml = _readText(archive, containerEntry);
    final opfPath = _findOpfPath(containerXml, index);
    if (opfPath == null) {
      throw EpubParseException('找不到 OPF 文件（container.xml 里的 rootfile 无效）');
    }

    final opfEntry = index.find(opfPath);
    if (opfEntry == null) {
      throw EpubParseException('OPF 文件不存在：$opfPath');
    }
    final opfDoc = XmlDocument.parse(_readText(archive, opfEntry));

    final opfDir = _dirOf(opfPath);

    // ---- 2. DRM / 字体混淆检测
    // 注意：META-INF/encryption.xml 存在 ≠ 有 DRM。
    // EPUB 规范允许用它声明「字体混淆」（IDPF / Adobe 两种算法），
    // 这类书正文完全可读，只是内嵌字体被做了简单 XOR —— 这也是为什么
    // Boox、爱阅记能正常打开它们。只有出现字体混淆之外的算法
    // （Readium LCP、Adobe ADEPT 等）才是真正加了版权保护。
    final encName = index.find('META-INF/encryption.xml');
    final encInfo = encName == null ? <String, String>{} : _parseEncryption(archive, encName);
    final obfuscatedFonts = <String, String>{
      for (final e in encInfo.entries)
        if (FontDeobfuscator.isFontObfuscation(e.value)) e.key: e.value,
    };
    final hasDrm = encName != null &&
        (encInfo.isEmpty || encInfo.keys.any((k) => !obfuscatedFonts.containsKey(k)));

    // unique-identifier：还原字体混淆要用它算 key
    // 必须按 localName 找 —— 标签是 <dc:identifier>，findAllElements('identifier') 匹配不到
    var uniqueIdentifier = '';
    final uidId = opfDoc.rootElement.getAttribute('unique-identifier');
    final idEls = opfDoc.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'identifier')
        .toList();
    if (uidId != null) {
      for (final el in idEls) {
        if (el.getAttribute('id') == uidId) {
          uniqueIdentifier = el.innerText.trim();
          break;
        }
      }
    }
    if (uniqueIdentifier.isEmpty && idEls.isNotEmpty) {
      // 退而求其次：挑一个像 uuid 的，实在没有就用第一个
      final texts = idEls.map((e) => e.innerText.trim()).where((t) => t.isNotEmpty).toList();
      uniqueIdentifier = texts.firstWhere(
        (t) => t.toLowerCase().contains('uuid'),
        orElse: () => texts.isEmpty ? '' : texts.first,
      );
    }

    // ---- 3. manifest
    final manifest = <String, _ManifestItem>{};
    for (final el in opfDoc.findAllElements('item')) {
      final id = el.getAttribute('id');
      final href = el.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = _ManifestItem(
        id: id,
        href: href,
        mediaType: el.getAttribute('media-type') ?? '',
        properties: el.getAttribute('properties') ?? '',
      );
    }

    // ---- 4. spine
    final spineIds = <String>[];
    for (final el in opfDoc.findAllElements('itemref')) {
      final idref = el.getAttribute('idref');
      if (idref != null) spineIds.add(idref);
    }

    // ---- 5. metadata（书名作者可能全空，必须兜底）
    var title = _firstText(opfDoc, 'title');
    var author = _firstText(opfDoc, 'creator');
    final language = _firstText(opfDoc, 'language');
    final description = _cleanDescription(_firstText(opfDoc, 'description'));

    // ---- 6. 目录：EPUB3 nav.xhtml 优先，EPUB2 NCX 兜底
    final toc = <String, _TocEntry>{};
    final navItem = manifest.values.where((m) => m.properties.contains('nav')).firstOrNull;
    final ncxItem = manifest.values
        .where((m) => m.mediaType == 'application/x-dtbncx+xml')
        .firstOrNull;

    if (navItem != null) {
      _parseNav(archive, index, opfDir, navItem.href, toc);
    }
    if (toc.isEmpty && ncxItem != null) {
      _parseNcx(archive, index, opfDir, ncxItem.href, toc);
    }

    // ---- 7. 组装章节
    final chapters = <EpubChapterInfo>[];
    for (var i = 0; i < spineIds.length; i++) {
      final item = manifest[spineIds[i]];
      if (item == null) continue;
      // 只收 XHTML 文档
      if (!_isDocument(item.mediaType, item.href)) continue;

      final key = _normalizeHref(item.href);
      final tocEntry = toc[key];
      final chapterTitle = tocEntry?.title ?? '';
      // 顺便统计这一章的正文字数（详情页要显示总字数，导入时算一次最省事）
      var charCount = 0;
      final entry = index.find(_joinPath(opfDir, item.href));
      if (entry != null) {
        try {
          charCount = _countChars(_readText(archive, entry));
        } catch (_) {}
      }
      chapters.add(EpubChapterInfo(
        spineIndex: i,
        href: item.href,
        title: chapterTitle,
        level: tocEntry?.level ?? 0,
        charCount: charCount,
      ));
    }

    // 书名兜底：metadata → 目录首个条目 → 文件名
    if (title.isEmpty) {
      // OPF 里没有 dc:title 时，不能拿 TOC 第一项当书名——
      // 第一项往往是「封面」「目录」「书名」这类页面，
      // 之前就因此把书名解析成了「封面」。直接用文件名更靠谱。
      title = fallbackTitle ?? '未命名';
    }
    if (author.isEmpty) author = '';

    // ---- 8. 封面
    final coverEntry = _resolveCover(archive, index, opfDoc, manifest, opfDir, chapters);

    // ---- 9. 需要解压的条目白名单
    final needed = <String>{};
    for (final item in manifest.values) {
      final entry = index.find(_joinPath(opfDir, item.href));
      if (entry != null) needed.add(entry);
    }
    if (coverEntry != null) needed.add(coverEntry);
    // 容器文件本身也带上（调试用，体积可忽略）
    final containerFound = index.find('META-INF/container.xml');
    if (containerFound != null) needed.add(containerFound);

    final cssHrefs = manifest.values
        .where((m) => m.mediaType == 'text/css')
        .map((m) => m.href)
        .toList();

    return EpubPackage(
      title: title,
      author: author,
      language: language,
      coverEntry: coverEntry,
      opfPath: opfPath,
      opfDir: opfDir,
      chapters: chapters,
      cssHrefs: cssHrefs,
      neededEntries: needed,
      hasDrm: hasDrm,
      obfuscatedFonts: obfuscatedFonts,
      uniqueIdentifier: uniqueIdentifier,
      description: description,
    );
  }

  /// dc:description 里经常塞着 HTML 片段甚至整段带标签的文案，
  /// 这里统一去标签、压空白，过长的截断（详情页只展示前几行）。
  static String _cleanDescription(String raw) {
    if (raw.isEmpty) return '';
    var s = raw
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.length > 600) s = '${s.substring(0, 600)}…';
    return s;
  }

  /// 统计一章的正文字数：去掉 script/style/标签与所有空白后的字符数
  static int _countChars(String html) {
    var s = html
        .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
        .replaceAll(RegExp(r'<[^>]*>'), '');
    s = s.replaceAll(RegExp(r'\s+'), '');
    return s.length;
  }

  // ------------------------------------------------------------------
  // container / opf
  // ------------------------------------------------------------------

  static String? _findOpfPath(String containerXml, _EntryIndex index) {
    try {
      final doc = XmlDocument.parse(containerXml);
      for (final el in doc.findAllElements('rootfile')) {
        final p = el.getAttribute('full-path');
        if (p != null && p.isNotEmpty) return p;
      }
    } catch (_) {
      // 容错：正则兜底
    }
    final m = RegExp(r'full-path="([^"]+)"').firstMatch(containerXml);
    return m?.group(1);
  }

  static String _firstText(XmlDocument doc, String localName) {
    for (final el in doc.descendants.whereType<XmlElement>()) {
      if (el.name.local == localName) {
        final t = el.innerText.trim();
        if (t.isNotEmpty) return t;
      }
    }
    return '';
  }

  // ------------------------------------------------------------------
  // 目录
  // ------------------------------------------------------------------

  /// EPUB3 的 nav.xhtml：<nav epub:type="toc"><ol><li><a href>
  static void _parseNav(
    Archive archive,
    _EntryIndex index,
    String opfDir,
    String navHref,
    Map<String, _TocEntry> out,
  ) {
    final entry = index.find(_joinPath(opfDir, navHref));
    if (entry == null) return;
    try {
      final doc = XmlDocument.parse(_readText(archive, entry));
      final navDir = _dirOf(navHref);

      void walk(XmlElement ol, int depth) {
        for (final li in ol.findElements('li')) {
          final a = li.findElements('a').firstOrNull;
          if (a != null) {
            final href = a.getAttribute('href');
            final text = a.innerText.trim();
            if (href != null && text.isNotEmpty) {
              final key = _normalizeHref(_joinPath(navDir, href.split('#').first));
              out.putIfAbsent(key, () => _TocEntry(text, depth));
            }
          }
          final sub = li.findElements('ol').firstOrNull;
          if (sub != null) walk(sub, depth + 1);
        }
      }

      final navs = doc.findAllElements('nav').where((n) {
        final t = n.getAttribute('epub:type') ?? n.getAttribute('type') ?? '';
        return t.contains('toc');
      });
      final nav = navs.isNotEmpty ? navs.first : doc.findAllElements('nav').firstOrNull;
      if (nav == null) return;
      final ol = nav.findElements('ol').firstOrNull ?? nav.descendants.whereType<XmlElement>().where((e) => e.name.local == 'ol').firstOrNull;
      if (ol != null) walk(ol, 0);
    } catch (_) {
      // 目录解析失败不影响正文阅读
    }
  }

  /// EPUB2 的 toc.ncx：注意 navPoint 在 navMap 里面
  static void _parseNcx(
    Archive archive,
    _EntryIndex index,
    String opfDir,
    String ncxHref,
    Map<String, _TocEntry> out,
  ) {
    final entry = index.find(_joinPath(opfDir, ncxHref));
    if (entry == null) return;
    try {
      final doc = XmlDocument.parse(_readText(archive, entry));
      final ncxDir = _dirOf(ncxHref);

      void walk(XmlElement parent, int depth) {
        for (final np in parent.findElements('navPoint')) {
          final label = np.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'text')
              .map((e) => e.innerText.trim())
              .firstOrNull;
          final content = np.findElements('content').firstOrNull;
          final src = content?.getAttribute('src');
          if (label != null && label.isNotEmpty && src != null) {
            final key = _normalizeHref(_joinPath(ncxDir, src.split('#').first));
            out.putIfAbsent(key, () => _TocEntry(label, depth));
          }
          // 递归子层级
          walk(np, depth + 1);
        }
      }

      // 关键：从 navMap 开始，不是从根节点
      final navMap = doc.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'navMap')
          .firstOrNull;
      if (navMap != null) {
        walk(navMap, 0);
      } else {
        walk(doc.rootElement, 0);
      }
    } catch (_) {
      // 忽略
    }
  }

  // ------------------------------------------------------------------
  // 封面
  // ------------------------------------------------------------------

  static String? _resolveCover(
    Archive archive,
    _EntryIndex index,
    XmlDocument opfDoc,
    Map<String, _ManifestItem> manifest,
    String opfDir,
    List<EpubChapterInfo> chapters,
  ) {
    // ① EPUB2 的 <meta name="cover" content="id">
    for (final el in opfDoc.findAllElements('meta')) {
      if ((el.getAttribute('name') ?? '') == 'cover') {
        final id = el.getAttribute('content');
        final item = id == null ? null : manifest[id];
        if (item != null) {
          final e = index.find(_joinPath(opfDir, item.href));
          if (e != null) return e;
        }
      }
    }

    // ② EPUB3 的 properties="cover-image"
    for (final m in manifest.values) {
      if (m.properties.contains('cover-image')) {
        final e = index.find(_joinPath(opfDir, m.href));
        if (e != null) return e;
      }
    }

    // ③ 第一个 spine 文档里的 <img>（很多轻小说这么做）
    if (chapters.isNotEmpty) {
      final first = index.find(_joinPath(opfDir, chapters.first.href));
      if (first != null) {
        final html = _readText(archive, first);
        final m = RegExp(r'<img[^>]+src="([^"]+)"', caseSensitive: false).firstMatch(html);
        if (m != null) {
          final rel = _joinPath(_dirOf(chapters.first.href), m.group(1)!);
          final e = index.find(_joinPath(opfDir, rel));
          if (e != null) return e;
        }
      }
    }

    // ④ manifest 里名字带 cover 的图片（排除 backcover 封底）
    for (final m in manifest.values) {
      final h = m.href.toLowerCase();
      if (h.contains('cover') && !h.contains('back') && _isImage(h)) {
        final e = index.find(_joinPath(opfDir, m.href));
        if (e != null) return e;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------
  // 工具
  // ------------------------------------------------------------------

  static bool _isDocument(String mediaType, String href) {
    if (mediaType.contains('xhtml') || mediaType.contains('html')) return true;
    final h = href.toLowerCase();
    return h.endsWith('.xhtml') || h.endsWith('.html') || h.endsWith('.htm');
  }

  static bool _isImage(String h) =>
      h.endsWith('.jpg') || h.endsWith('.jpeg') || h.endsWith('.png') || h.endsWith('.gif') || h.endsWith('.webp');

  static String _dirOf(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  static String _joinPath(String dir, String href) {
    if (dir.isEmpty) return href;
    if (href.startsWith('/')) return href.substring(1);
    return '$dir/$href';
  }

  /// 统一成「相对 OPF 目录、已解码、无锚点」的 key，用于目录与 spine 匹配
  static String _normalizeHref(String href) {
    var h = href.split('#').first;
    try {
      h = Uri.decodeComponent(h);
    } catch (_) {}
    while (h.startsWith('./')) {
      h = h.substring(2);
    }
    return h;
  }

  /// 解析 encryption.xml：条目名 → 算法 URI。
  /// 标签常带命名空间前缀（`<enc:EncryptionMethod>`），正则必须容忍。
  static Map<String, String> _parseEncryption(Archive archive, String name) {
    final xml = _readText(archive, name);
    final out = <String, String>{};
    final blocks = RegExp(
      r'<(?:[\w.-]+:)?EncryptedData\b[\s\S]*?</(?:[\w.-]+:)?EncryptedData>',
      caseSensitive: false,
    ).allMatches(xml);
    for (final b in blocks) {
      final block = b.group(0)!;
      final alg = RegExp(
        r'''<(?:[\w.-]+:)?EncryptionMethod[^>]*\bAlgorithm\s*=\s*"([^"]*)"''',
        caseSensitive: false,
      ).firstMatch(block)?.group(1);
      final uri = RegExp(
        r'''<(?:[\w.-]+:)?CipherReference[^>]*\bURI\s*=\s*"([^"]*)"''',
        caseSensitive: false,
      ).firstMatch(block)?.group(1);
      if (alg != null && uri != null) out[uri] = alg;
    }
    return out;
  }

  static String _readText(Archive archive, String name) {
    final f = archive.findFile(name);
    if (f == null) return '';
    final data = f.content;
    if (data is List<int>) {
      // 去掉 BOM
      if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
        return utf8.decode(data.sublist(3), allowMalformed: true);
      }
      return utf8.decode(data, allowMalformed: true);
    }
    return '';
  }
}

class _TocEntry {
  final String title;
  final int level;
  const _TocEntry(this.title, this.level);
}

class _ManifestItem {
  final String id;
  final String href;
  final String mediaType;
  final String properties;
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.properties,
  });
}

/// zip 条目索引：解决 OPF 里 `%20` 编码 vs zip 里原始空格名的不匹配问题。
/// 不做这层，每本书都会静默丢几章。
class _EntryIndex {
  final Archive archive;
  final Map<String, String> _byLower = {};

  _EntryIndex(this.archive) {
    for (final f in archive.files) {
      if (!f.isFile) continue;
      _byLower[f.name.toLowerCase()] = f.name;
    }
  }

  /// 依次尝试：原样 → URL 解码 → 忽略大小写
  String? find(String path) {
    final p = path.replaceAll('\\', '/');
    if (_byLower.containsKey(p.toLowerCase())) return _byLower[p.toLowerCase()];

    String decoded = p;
    try {
      decoded = Uri.decodeComponent(p);
    } catch (_) {}
    if (_byLower.containsKey(decoded.toLowerCase())) return _byLower[decoded.toLowerCase()];

    // 再试一次：把空格编码回去
    final encoded = decoded.replaceAll(' ', '%20');
    if (_byLower.containsKey(encoded.toLowerCase())) return _byLower[encoded.toLowerCase()];

    return null;
  }
}
