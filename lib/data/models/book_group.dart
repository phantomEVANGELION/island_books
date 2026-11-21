/// 分组（相当于文件夹）。
///
/// 场景：《无职转生》有 24 个 epub，都属于同一部作品。
/// 导入后在书架顶层只想看到「无职转生」这一项，点进去才是 24 个分卷。
/// parentId 为 null 表示挂在顶层书架下，支持多级嵌套。
class BookGroup {
  final int? id;
  final String name;
  final int? parentId;
  final int sortOrder;
  final int createdAt;

  /// 运行时统计，不入库
  final int bookCount;
  final int childGroupCount;

  /// 组内书籍最近一次阅读时间（聚合字段，不入库）。null 表示组内没读过书。
  final int? lastReadAt;

  /// 分组封面：默认取组内第一本书的封面，用户也可以自定义
  final String? coverPath;

  /// 组内书籍字数合计（聚合字段，不入库）
  final int wordCount;

  /// 组内书籍累计阅读时长（秒，聚合字段）
  final int readSeconds;

  /// 组内书籍平均阅读进度 0~1（聚合字段）
  final double progressPercent;

  const BookGroup({
    this.id,
    required this.name,
    this.parentId,
    this.sortOrder = 0,
    this.createdAt = 0,
    this.bookCount = 0,
    this.childGroupCount = 0,
    this.lastReadAt,
    this.coverPath,
    this.wordCount = 0,
    this.readSeconds = 0,
    this.progressPercent = 0,
  });

  factory BookGroup.fromMap(Map<String, Object?> m) => BookGroup(
        id: m['id'] as int?,
        name: (m['name'] as String?) ?? '未命名',
        parentId: m['parent_id'] as int?,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        createdAt: (m['created_at'] as int?) ?? 0,
        bookCount: (m['book_count'] as int?) ?? 0,
        childGroupCount: (m['child_count'] as int?) ?? 0,
        lastReadAt: m['last_read_at'] as int?,
        coverPath: m['cover_path'] as String?,
        wordCount: (m['word_count'] as int?) ?? 0,
        readSeconds: (m['read_seconds'] as int?) ?? 0,
        progressPercent: (m['progress_percent'] as num?)?.toDouble() ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'parent_id': parentId,
        'sort_order': sortOrder,
        'created_at': createdAt,
      };

  BookGroup copyWith({
    int? id,
    String? name,
    int? parentId,
    bool clearParent = false,
    int? sortOrder,
    int? createdAt,
    int? bookCount,
    int? childGroupCount,
    int? lastReadAt,
    String? coverPath,
    int? wordCount,
    int? readSeconds,
    double? progressPercent,
  }) =>
      BookGroup(
        id: id ?? this.id,
        name: name ?? this.name,
        parentId: clearParent ? null : (parentId ?? this.parentId),
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
        bookCount: bookCount ?? this.bookCount,
        childGroupCount: childGroupCount ?? this.childGroupCount,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        coverPath: coverPath ?? this.coverPath,
        wordCount: wordCount ?? this.wordCount,
        readSeconds: readSeconds ?? this.readSeconds,
        progressPercent: progressPercent ?? this.progressPercent,
      );

  /// 字数显示：5.40 万字 / 8200 字 / —
  String get wordLabel {
    if (wordCount <= 0) return '—';
    if (wordCount >= 10000) return '${(wordCount / 10000).toStringAsFixed(2)} 万字';
    return '$wordCount 字';
  }

  /// 累计阅读时长
  String get readTimeLabel {
    if (readSeconds < 60) return readSeconds <= 0 ? '未读' : '$readSeconds 秒';
    final m = readSeconds ~/ 60;
    if (m < 60) return '$m 分 ${readSeconds % 60} 秒';
    final h = m ~/ 60;
    return '$h 小时 ${m % 60} 分';
  }

  String get progressLabel => '${(progressPercent * 100).toStringAsFixed(2)}%';
}
