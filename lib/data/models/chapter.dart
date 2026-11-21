/// 章节：对应 EPUB spine 里的一项。
class Chapter {
  final int? id;
  final int bookId;

  /// 在 spine 里的顺序，从 0 开始。滚动模式下靠它定位章节。
  final int spineIndex;

  final String title;

  /// 相对 OPF 目录的路径，例如 "Text/chapter01.xhtml"
  final String href;

  /// 目录层级（NCX 嵌套深度），0 为顶层
  final int level;

  /// 正文字符数，用于估算进度
  final int charCount;

  const Chapter({
    this.id,
    required this.bookId,
    required this.spineIndex,
    required this.title,
    required this.href,
    this.level = 0,
    this.charCount = 0,
  });

  factory Chapter.fromMap(Map<String, Object?> m) => Chapter(
        id: m['id'] as int?,
        bookId: (m['book_id'] as int?) ?? 0,
        spineIndex: (m['spine_index'] as int?) ?? 0,
        title: (m['title'] as String?) ?? '',
        href: (m['href'] as String?) ?? '',
        level: (m['level'] as int?) ?? 0,
        charCount: (m['char_count'] as int?) ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'book_id': bookId,
        'spine_index': spineIndex,
        'title': title,
        'href': href,
        'level': level,
        'char_count': charCount,
      };
}
