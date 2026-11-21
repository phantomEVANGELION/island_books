/// 书签。
///
/// 定位方式和阅读进度一致：章节序号 + 章内字符偏移。
/// excerpt 存添加时屏幕上那几段文字，用于在书签列表里一眼认出位置。
class Bookmark {
  final int? id;
  final int bookId;
  final int spineIndex;
  final int charOffset;
  final String chapterTitle;
  final String excerpt;

  /// 全书百分比，书签列表右下角显示（参考爱阅记）
  final double percent;
  final int createdAt;

  const Bookmark({
    this.id,
    required this.bookId,
    required this.spineIndex,
    required this.charOffset,
    this.chapterTitle = '',
    this.excerpt = '',
    this.percent = 0,
    required this.createdAt,
  });

  factory Bookmark.fromMap(Map<String, Object?> m) => Bookmark(
        id: m['id'] as int?,
        bookId: (m['book_id'] as int?) ?? 0,
        spineIndex: (m['spine_index'] as int?) ?? 0,
        charOffset: (m['char_offset'] as int?) ?? 0,
        chapterTitle: (m['chapter_title'] as String?) ?? '',
        excerpt: (m['excerpt'] as String?) ?? '',
        percent: (m['percent'] as num?)?.toDouble() ?? 0,
        createdAt: (m['created_at'] as int?) ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'book_id': bookId,
        'spine_index': spineIndex,
        'char_offset': charOffset,
        'chapter_title': chapterTitle,
        'excerpt': excerpt,
        'percent': percent,
        'created_at': createdAt,
      };

  String get percentLabel => '${(percent * 100).toStringAsFixed(2)}%';
}
