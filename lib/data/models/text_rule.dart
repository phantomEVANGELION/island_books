/// 临时修改规则（可逆，只改显示文本，不碰原文件）。
///
/// scope 决定替换范围：
/// - here：仅替换长按的那一处（按 spine + block 定位）
/// - chapter：替换所在章节内所有匹配
/// - book：替换全书所有匹配
class TextRule {
  final int? id;
  final int bookId;
  final String fromText;
  final String toText;
  final String scope;

  /// here/chapter 时需要；book 时为 null
  final int? spineIndex;

  /// 长按词所在段落在章节内的序号（here 时用于精确定位）
  final int? blockIndex;

  final bool enabled;
  final int createdAt;

  const TextRule({
    this.id,
    required this.bookId,
    required this.fromText,
    required this.toText,
    this.scope = 'book',
    this.spineIndex,
    this.blockIndex,
    this.enabled = true,
    required this.createdAt,
  });

  factory TextRule.fromMap(Map<String, Object?> m) => TextRule(
        id: m['id'] as int?,
        bookId: (m['book_id'] as int?) ?? 0,
        fromText: (m['from_text'] as String?) ?? '',
        toText: (m['to_text'] as String?) ?? '',
        scope: (m['scope'] as String?) ?? 'book',
        spineIndex: (m['spine_index'] as int?) ?? 0,
        blockIndex: (m['block_index'] as int?) ?? 0,
        enabled: ((m['enabled'] as int?) ?? 1) != 0,
        createdAt: (m['created_at'] as int?) ?? 0,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'book_id': bookId,
        'from_text': fromText,
        'to_text': toText,
        'scope': scope,
        'spine_index': spineIndex,
        'block_index': blockIndex,
        'enabled': enabled ? 1 : 0,
        'created_at': createdAt,
      };

  String get scopeLabel => switch (scope) {
        'here' => '仅此处',
        'chapter' => '本章节',
        _ => '全书',
      };
}
