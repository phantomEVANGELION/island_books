/// 自然排序：让「第2卷」排在「第10卷」前面。
///
/// SQLite 的 ORDER BY 是字典序，`10` 会排在 `2` 前面，
/// 所以文件名排序不能交给数据库，得在 Dart 侧做。
///
/// 规则：把字符串切成「数字段」和「文字段」交替的片段，
/// 数字段按数值比，文字段按字典序比。
int naturalCompare(String a, String b) {
  final ra = _split(a);
  final rb = _split(b);
  final n = ra.length < rb.length ? ra.length : rb.length;

  for (var i = 0; i < n; i++) {
    final x = ra[i];
    final y = rb[i];
    final nx = int.tryParse(x);
    final ny = int.tryParse(y);

    int c;
    if (nx != null && ny != null) {
      c = nx.compareTo(ny);
    } else {
      c = x.toLowerCase().compareTo(y.toLowerCase());
    }
    if (c != 0) return c;
  }
  return ra.length.compareTo(rb.length);
}

List<String> _split(String s) {
  final out = <String>[];
  final re = RegExp(r'\d+|\D+');
  for (final m in re.allMatches(s)) {
    final t = m.group(0);
    if (t != null && t.isNotEmpty) out.add(t);
  }
  return out;
}
