import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../models/book.dart';
import '../models/book_group.dart';
import '../models/bookmark.dart';
import '../models/chapter.dart';
import '../models/text_rule.dart';
import '../../core/utils/natural_sort.dart';

/// 书籍、分组、书签的读写。
class BookRepository {
  // ==================================================================
  // 书籍
  // ==================================================================

  /// 书架列表。
  /// [groupId] 为 null 且 [rootOnly] 为 true 时，只返回顶层（未分组）的书。
  /// [sort]：recent（最近阅读）/ name（文件名）/ manual（手动）
  Future<List<Book>> listBooks({
    int? groupId,
    bool rootOnly = false,
    String sort = 'recent',
  }) async {
    final db = await AppDatabase.instance;
    String? where;
    List<Object?>? args;
    if (rootOnly) {
      where = 'group_id IS NULL';
    } else if (groupId != null) {
      where = 'group_id = ?';
      args = [groupId];
    }

    final orderBy = switch (sort) {
      // 手动排序：拖过之后按 sort_order，没拖过的按导入时间垫底
      'manual' => 'sort_order ASC, added_at ASC',
      _ => 'COALESCE(last_read_at, 0) DESC, added_at DESC',
    };

    // 文件名排序不能用 SQL：字典序会把 10 排到 2 前面。
    // 先按导入时间取出来，再用自然排序重排。
    if (sort == 'name') {
      final rows = await db.query(
        'books',
        where: where,
        whereArgs: args,
        orderBy: 'added_at ASC',
      );
      final list = rows.map(Book.fromMap).toList();
      list.sort((a, b) => naturalCompare(a.title, b.title));
      return list;
    }

    final rows = await db.query(
      'books',
      where: where,
      whereArgs: args,
      orderBy: orderBy,
    );
    return rows.map(Book.fromMap).toList();
  }

  /// 手动排序：按传入的书 id 顺序重写 sort_order
  Future<void> updateSortOrders(List<int> orderedBookIds) async {
    final db = await AppDatabase.instance;
    final batch = db.batch();
    for (var i = 0; i < orderedBookIds.length; i++) {
      batch.update(
        'books',
        {'sort_order': i},
        where: 'id = ?',
        whereArgs: [orderedBookIds[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  /// 最近读过的书（首页顶部横滑区）
  Future<List<Book>> listRecentBooks({int limit = 10}) async {
    final db = await AppDatabase.instance;
    final rows = await db.query(
      'books',
      where: 'last_read_at IS NOT NULL',
      orderBy: 'last_read_at DESC',
      limit: limit,
    );
    return rows.map(Book.fromMap).toList();
  }

  Future<Book?> getBook(int id) async {
    final db = await AppDatabase.instance;
    final rows = await db.query('books', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Book.fromMap(rows.first);
  }

  /// 分组和书共用一个递增序号空间。
  /// 取两张表的最大值 +1，保证新建的分组/书都排在最后，
  /// 同时分组可以被拖到书的下面（不再受「分组必须在前」的限制）。
  Future<int> nextSortOrder() async {
    final db = await AppDatabase.instance;
    final rows = await db.rawQuery(
      'SELECT MAX(m) AS m FROM ('
      'SELECT sort_order AS m FROM groups UNION ALL '
      'SELECT sort_order AS m FROM books'
      ')',
    );
    final v = rows.isEmpty ? null : rows.first['m'];
    return ((v as num?)?.toInt() ?? 0) + 1;
  }

  Future<int> insertBook(Book book) async {
    final db = await AppDatabase.instance;
    final map = book.toMap();
    // 新书默认排序值是 0，放进共用空间会跑到最前面 —— 改成排到最后
    if (book.sortOrder == 0) map['sort_order'] = await nextSortOrder();
    return db.insert('books', map);
  }

  Future<void> insertChapters(List<Chapter> chapters) async {
    final db = await AppDatabase.instance;
    final batch = db.batch();
    for (final c in chapters) {
      batch.insert('chapters', c.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<List<Chapter>> getChapters(int bookId) async {
    final db = await AppDatabase.instance;
    final rows = await db.query(
      'chapters',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'spine_index ASC',
    );
    return rows.map(Chapter.fromMap).toList();
  }

  Future<void> renameBook(int bookId, String title) async {
    final db = await AppDatabase.instance;
    await db.update('books', {'title': title}, where: 'id = ?', whereArgs: [bookId]);
  }

  /// 把书移动到某个分组。[groupId] 传 null 表示移回顶层书架。
  Future<void> moveBookToGroup(int bookId, int? groupId) async {
    final db = await AppDatabase.instance;
    await db.update(
      'books',
      {'group_id': groupId},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// 删除书：数据库记录 + 磁盘目录一起清
  Future<void> deleteBook(int bookId) async {
    final db = await AppDatabase.instance;
    final book = await getBook(bookId);
    await db.delete('books', where: 'id = ?', whereArgs: [bookId]);
    await db.delete('chapters', where: 'book_id = ?', whereArgs: [bookId]);
    await db.delete('reading_progress', where: 'book_id = ?', whereArgs: [bookId]);
    await db.delete('bookmarks', where: 'book_id = ?', whereArgs: [bookId]);

    if (book != null && book.bookDir.isNotEmpty) {
      try {
        final dir = Directory(book.bookDir);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        // 磁盘清理失败不影响书架
      }
    }
  }

  // ==================================================================
  // 分组
  // ==================================================================

  /// 全部分组，附带「直接包含几本书」「有几个子分组」以及封面。
  /// 封面优先用自定义的，没有就取组内第一本书的封面。
  Future<List<BookGroup>> listGroups({String sort = 'manual'}) async {
    final db = await AppDatabase.instance;
    final rows = await db.rawQuery('''
      SELECT g.*,
        (SELECT COUNT(*) FROM books b WHERE b.group_id = g.id) AS book_count,
        (SELECT COUNT(*) FROM groups c WHERE c.parent_id = g.id) AS child_count,
        (SELECT MAX(b2.last_read_at) FROM books b2 WHERE b2.group_id = g.id) AS last_read_at,
        (SELECT COALESCE(SUM(b3.word_count), 0) FROM books b3 WHERE b3.group_id = g.id) AS word_count,
        (SELECT COALESCE(SUM(b4.read_seconds), 0) FROM books b4 WHERE b4.group_id = g.id) AS read_seconds,
        (SELECT COALESCE(AVG(b5.progress_percent), 0) FROM books b5 WHERE b5.group_id = g.id) AS progress_percent,
        COALESCE(
          g.cover_path,
          (SELECT b2.cover_path FROM books b2
             WHERE b2.group_id = g.id
               AND b2.cover_path IS NOT NULL
               AND b2.cover_path <> ''
             ORDER BY b2.added_at ASC LIMIT 1)
        ) AS cover_path
      FROM groups g
      ORDER BY g.sort_order ASC, g.created_at ASC
    ''');
    final list = rows.map(BookGroup.fromMap).toList();

    // 文件名排序：SQL 字典序会把「第10卷」排到「第2卷」前面，改用自然排序
    if (sort == 'name') {
      list.sort((a, b) => naturalCompare(a.name, b.name));
    } else if (sort == 'recent') {
      // 最近阅读：按组内书籍最近一次阅读时间倒序，没读过的垫底
      list.sort((a, b) => (b.lastReadAt ?? 0).compareTo(a.lastReadAt ?? 0));
    }
    return list;
  }

  /// 手动排序：按传入的分组 id 顺序重写 sort_order
  Future<void> updateGroupSortOrders(List<int> orderedGroupIds) async {
    final db = await AppDatabase.instance;
    final batch = db.batch();
    for (var i = 0; i < orderedGroupIds.length; i++) {
      batch.update(
        'groups',
        {'sort_order': i},
        where: 'id = ?',
        whereArgs: [orderedGroupIds[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> setGroupCover(int groupId, String? path) async {
    final db = await AppDatabase.instance;
    await db.update('groups', {'cover_path': path}, where: 'id = ?', whereArgs: [groupId]);
  }

  /// 取单个分组（带聚合统计），用于分组详情页
  Future<BookGroup?> getGroup(int groupId) async {
    final list = await listGroups();
    for (final g in list) {
      if (g.id == groupId) return g;
    }
    return null;
  }

  /// 累加阅读时长（秒）
  Future<void> addReadSeconds(int bookId, int seconds) async {
    if (seconds <= 0) return;
    final db = await AppDatabase.instance;
    await db.rawUpdate(
      'UPDATE books SET read_seconds = read_seconds + ? WHERE id = ?',
      [seconds, bookId],
    );
  }

  Future<void> setBookCover(int bookId, String? path) async {
    final db = await AppDatabase.instance;
    await db.update('books', {'cover_path': path}, where: 'id = ?', whereArgs: [bookId]);
  }

  /// 回填老书的字数（老版本导入时没统计）
  Future<void> setBookWordCount(int bookId, int count) async {
    final db = await AppDatabase.instance;
    await db.update('books', {'word_count': count}, where: 'id = ?', whereArgs: [bookId]);
  }

  Future<int> createGroup(String name, {int? parentId}) async {
    final db = await AppDatabase.instance;
    return db.insert('groups', {
      'name': name,
      'parent_id': parentId,
      // 用共用序号空间，新分组排在最后（而不是永远跑到第一个）
      'sort_order': await nextSortOrder(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> renameGroup(int groupId, String name) async {
    final db = await AppDatabase.instance;
    await db.update('groups', {'name': name}, where: 'id = ?', whereArgs: [groupId]);
  }

  /// 删分组：子分组和书都上移到父级，不连坐删除
  Future<void> deleteGroup(int groupId) async {
    final db = await AppDatabase.instance;
    final rows = await db.query('groups', where: 'id = ?', whereArgs: [groupId], limit: 1);
    if (rows.isEmpty) return;
    final parentId = rows.first['parent_id'] as int?;

    await db.update(
      'groups',
      {'parent_id': parentId},
      where: 'parent_id = ?',
      whereArgs: [groupId],
    );
    await db.update(
      'books',
      {'group_id': parentId},
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    await db.delete('groups', where: 'id = ?', whereArgs: [groupId]);
  }

  // ==================================================================
  // 阅读进度
  // ==================================================================

  Future<void> saveProgress({
    required int bookId,
    required int spineIndex,
    required int charOffset,
    required double percent,
  }) async {
    final db = await AppDatabase.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'reading_progress',
      {
        'book_id': bookId,
        'spine_index': spineIndex,
        'char_offset': charOffset,
        'percent': percent,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.update(
      'books',
      {
        'progress_percent': percent,
        'current_chapter': spineIndex,
        'last_read_at': now,
      },
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  Future<Map<String, Object?>?> getProgress(int bookId) async {
    final db = await AppDatabase.instance;
    final rows = await db.query(
      'reading_progress',
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // ==================================================================
  // 书签
  // ==================================================================

  Future<int> addBookmark(Bookmark bookmark) async {
    final db = await AppDatabase.instance;
    return db.insert('bookmarks', bookmark.toMap());
  }

  Future<List<Bookmark>> listBookmarks(int bookId) async {
    final db = await AppDatabase.instance;
    final rows = await db.query(
      'bookmarks',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at DESC',
    );
    return rows.map(Bookmark.fromMap).toList();
  }

  Future<void> deleteBookmark(int bookmarkId) async {
    final db = await AppDatabase.instance;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [bookmarkId]);
  }

  /// 找「当前位置附近」的书签。
  /// 用于实现「右滑一次加书签、再滑一次删书签」：
  /// 同一章内偏移相差 800 字以内算同一个位置。
  Future<Bookmark?> findBookmarkNear(
    int bookId,
    int spineIndex,
    int charOffset, {
    int tolerance = 800,
  }) async {
    final db = await AppDatabase.instance;
    final rows = await db.query(
      'bookmarks',
      where: 'book_id = ? AND spine_index = ? AND char_offset BETWEEN ? AND ?',
      whereArgs: [bookId, spineIndex, charOffset - tolerance, charOffset + tolerance],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Bookmark.fromMap(rows.first);
  }

  // ==================================================================
  // 临时修改规则
  // ==================================================================

  Future<List<TextRule>> listTextRules(int bookId, {bool onlyEnabled = false}) async {
    final db = await AppDatabase.instance;
    final rows = await db.query(
      'text_rules',
      where: onlyEnabled ? 'book_id = ? AND enabled = 1' : 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at ASC',
    );
    return rows.map(TextRule.fromMap).toList();
  }

  Future<int> addTextRule(TextRule rule) async {
    final db = await AppDatabase.instance;
    return db.insert('text_rules', rule.toMap());
  }

  Future<void> setTextRuleEnabled(int ruleId, bool enabled) async {
    final db = await AppDatabase.instance;
    await db.update(
      'text_rules',
      {'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [ruleId],
    );
  }

  Future<void> deleteTextRule(int ruleId) async {
    final db = await AppDatabase.instance;
    await db.delete('text_rules', where: 'id = ?', whereArgs: [ruleId]);
  }
}
