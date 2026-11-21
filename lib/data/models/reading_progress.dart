/// 阅读进度：用「章节序号 + 章内字符偏移」定位，不用 EPUB CFI。
///
/// 为什么不走 CFI：CFI 要解析 `epubcfi(/6/4!/4/2/2:5)` 这类路径，
/// 实现复杂且各书兼容性参差。而「第几章的第几个字」对滚动模式足够精确，
/// 且**改字号后仍能停在同一句话**——这是滚动阅读最关键的体验。
class ReadingProgress {
  final int bookId;
  final int spineIndex;

  /// 章内字符偏移（相对该章节正文的第一个字符）
  final int charOffset;

  /// 全书百分比 0.0 ~ 1.0
  final double percent;

  final int updatedAt;

  const ReadingProgress({
    required this.bookId,
    required this.spineIndex,
    required this.charOffset,
    required this.percent,
    required this.updatedAt,
  });

  factory ReadingProgress.fromMap(Map<String, Object?> m) => ReadingProgress(
        bookId: (m['book_id'] as int?) ?? 0,
        spineIndex: (m['spine_index'] as int?) ?? 0,
        charOffset: (m['char_offset'] as int?) ?? 0,
        percent: (m['percent'] as num?)?.toDouble() ?? 0,
        updatedAt: (m['updated_at'] as int?) ?? 0,
      );

  Map<String, Object?> toMap() => {
        'book_id': bookId,
        'spine_index': spineIndex,
        'char_offset': charOffset,
        'percent': percent,
        'updated_at': updatedAt,
      };
}
