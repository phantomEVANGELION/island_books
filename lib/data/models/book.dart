/// 一本书的元数据。
/// 只存「书是什么」，不存「书的内容」——内容在磁盘上的解压目录里。
class Book {
  final int? id;
  final String title;
  final String author;
  final String? coverPath;

  /// 原始文件路径（导入时的来源，仅作记录）
  final String filePath;

  /// 解压后的书籍目录，WebView 从这里加载 XHTML 和图片
  final String bookDir;

  /// epub / txt
  final String format;
  final int fileSize;
  final int chapterCount;
  final int addedAt;
  final int? lastReadAt;

  /// 0.0 ~ 1.0
  final double progressPercent;

  /// 当前所在章节的 spine 序号
  final int currentChapter;

  /// 所属分组（文件夹）。null 表示直接放在顶层书架
  final int? groupId;

  /// 分组内手动排序用的序号
  final int sortOrder;

  /// 书籍简介（epub 的 dc:description，可能为空）
  final String description;

  /// 正文总字数（导入时按章节 char_count 汇总）
  final int wordCount;

  /// 累计阅读时长（秒）
  final int readSeconds;

  const Book({
    this.id,
    required this.title,
    this.author = '',
    this.coverPath,
    required this.filePath,
    required this.bookDir,
    this.format = 'epub',
    this.fileSize = 0,
    this.chapterCount = 0,
    required this.addedAt,
    this.lastReadAt,
    this.progressPercent = 0,
    this.currentChapter = 0,
    this.groupId,
    this.sortOrder = 0,
    this.description = '',
    this.wordCount = 0,
    this.readSeconds = 0,
  });

  factory Book.fromMap(Map<String, Object?> m) => Book(
        id: m['id'] as int?,
        title: (m['title'] as String?) ?? '未命名',
        author: (m['author'] as String?) ?? '',
        coverPath: m['cover_path'] as String?,
        filePath: (m['file_path'] as String?) ?? '',
        bookDir: (m['book_dir'] as String?) ?? '',
        format: (m['format'] as String?) ?? 'epub',
        fileSize: (m['file_size'] as int?) ?? 0,
        chapterCount: (m['chapter_count'] as int?) ?? 0,
        addedAt: (m['added_at'] as int?) ?? 0,
        lastReadAt: m['last_read_at'] as int?,
        progressPercent: (m['progress_percent'] as num?)?.toDouble() ?? 0,
        currentChapter: (m['current_chapter'] as int?) ?? 0,
        groupId: m['group_id'] as int?,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        description: (m['description'] as String?) ?? '',
        wordCount: (m['word_count'] as int?) ?? 0,
        readSeconds: (m['read_seconds'] as int?) ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'author': author,
        'cover_path': coverPath,
        'file_path': filePath,
        'book_dir': bookDir,
        'format': format,
        'file_size': fileSize,
        'chapter_count': chapterCount,
        'added_at': addedAt,
        'last_read_at': lastReadAt,
        'progress_percent': progressPercent,
        'current_chapter': currentChapter,
        'group_id': groupId,
        'sort_order': sortOrder,
        'description': description,
        'word_count': wordCount,
        'read_seconds': readSeconds,
      };

  Book copyWith({
    int? id,
    String? title,
    String? author,
    String? coverPath,
    String? filePath,
    String? bookDir,
    String? format,
    int? fileSize,
    int? chapterCount,
    int? addedAt,
    int? lastReadAt,
    double? progressPercent,
    int? currentChapter,
    int? groupId,
    bool clearGroup = false,
    int? sortOrder,
    String? description,
    int? wordCount,
    int? readSeconds,
  }) =>
      Book(
        id: id ?? this.id,
        title: title ?? this.title,
        author: author ?? this.author,
        coverPath: coverPath ?? this.coverPath,
        filePath: filePath ?? this.filePath,
        bookDir: bookDir ?? this.bookDir,
        format: format ?? this.format,
        fileSize: fileSize ?? this.fileSize,
        chapterCount: chapterCount ?? this.chapterCount,
        addedAt: addedAt ?? this.addedAt,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        progressPercent: progressPercent ?? this.progressPercent,
        currentChapter: currentChapter ?? this.currentChapter,
        groupId: clearGroup ? null : (groupId ?? this.groupId),
        sortOrder: sortOrder ?? this.sortOrder,
        description: description ?? this.description,
        wordCount: wordCount ?? this.wordCount,
        readSeconds: readSeconds ?? this.readSeconds,
      );

  /// 阅读百分比显示文本
  String get progressLabel {
    if (progressPercent <= 0.001) return '未读';
    if (progressPercent >= 0.999) return '已读完';
    return '${(progressPercent * 100).round()}%';
  }

  /// 字数显示：3.87 万字 / 8200 字 / —
  String get wordLabel {
    if (wordCount <= 0) return '—';
    if (wordCount >= 10000) return '${(wordCount / 10000).toStringAsFixed(2)} 万字';
    return '$wordCount 字';
  }

  /// 累计阅读时长：1 小时 12 分 / 3 分 20 秒 / 未读
  String get readTimeLabel {
    if (readSeconds < 60) return readSeconds <= 0 ? '未读' : '$readSeconds 秒';
    final m = readSeconds ~/ 60;
    if (m < 60) return '$m 分 ${readSeconds % 60} 秒';
    final h = m ~/ 60;
    return '$h 小时 ${m % 60} 分';
  }
}
