import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 本地数据库。全本地，无账号、无网络。
///
/// v1 → v2：
///   - 新增 groups 表（多级分组/文件夹）
///   - books 加 group_id（NULL 表示直接放在顶层书架）
///   - bookmarks 加 percent（书签要显示所在百分比，参考爱阅记）
class AppDatabase {
  static Database? _db;

  static Future<Database> get instance async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'island_books.db');
    _db = await openDatabase(
      path,
      version: 6,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
    return _db!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        author TEXT NOT NULL DEFAULT '',
        cover_path TEXT,
        file_path TEXT NOT NULL,
        book_dir TEXT NOT NULL,
        format TEXT NOT NULL DEFAULT 'epub',
        file_size INTEGER NOT NULL DEFAULT 0,
        chapter_count INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL,
        last_read_at INTEGER,
        progress_percent REAL NOT NULL DEFAULT 0,
        current_chapter INTEGER NOT NULL DEFAULT 0,
        group_id INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0,
        description TEXT NOT NULL DEFAULT '',
        word_count INTEGER NOT NULL DEFAULT 0,
        read_seconds INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE chapters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        spine_index INTEGER NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        href TEXT NOT NULL,
        level INTEGER NOT NULL DEFAULT 0,
        char_count INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_chapters_book ON chapters(book_id, spine_index)');

    await db.execute('''
      CREATE TABLE reading_progress (
        book_id INTEGER PRIMARY KEY,
        spine_index INTEGER NOT NULL DEFAULT 0,
        char_offset INTEGER NOT NULL DEFAULT 0,
        percent REAL NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE bookmarks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        spine_index INTEGER NOT NULL,
        char_offset INTEGER NOT NULL,
        chapter_title TEXT NOT NULL DEFAULT '',
        excerpt TEXT NOT NULL DEFAULT '',
        percent REAL NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_bookmarks_book ON bookmarks(book_id)');

    await _createGroups(db);
    await _createTextRules(db);
  }

  static Future<void> _createGroups(Database db) async {
    await db.execute('''
      CREATE TABLE groups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        parent_id INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        cover_path TEXT
      )
    ''');
    await db.execute('CREATE INDEX idx_groups_parent ON groups(parent_id)');
  }

  static Future<void> _createTextRules(Database db) async {
    await db.execute('''
      CREATE TABLE text_rules (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        from_text TEXT NOT NULL,
        to_text TEXT NOT NULL DEFAULT '',
        scope TEXT NOT NULL DEFAULT 'book',
        spine_index INTEGER,
        block_index INTEGER,
        enabled INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_text_rules_book ON text_rules(book_id)');
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      // 老用户的书籍数据必须保留，只做增量
      final cols = await db.rawQuery('PRAGMA table_info(books)');
      if (!cols.any((c) => c['name'] == 'group_id')) {
        await db.execute('ALTER TABLE books ADD COLUMN group_id INTEGER');
      }

      final bcols = await db.rawQuery('PRAGMA table_info(bookmarks)');
      if (!bcols.any((c) => c['name'] == 'percent')) {
        await db.execute('ALTER TABLE bookmarks ADD COLUMN percent REAL NOT NULL DEFAULT 0');
      }

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='groups'",
      );
      if (tables.isEmpty) {
        await _createGroups(db);
      }
    }

    if (oldV < 3) {
      // 分组支持自定义封面
      final gcols = await db.rawQuery('PRAGMA table_info(groups)');
      if (!gcols.any((c) => c['name'] == 'cover_path')) {
        await db.execute('ALTER TABLE groups ADD COLUMN cover_path TEXT');
      }
    }

    if (oldV < 4) {
      // 分组内手动排序
      final bcols = await db.rawQuery('PRAGMA table_info(books)');
      if (!bcols.any((c) => c['name'] == 'sort_order')) {
        await db.execute('ALTER TABLE books ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0');
        // 老数据按导入顺序初始化，保证第一次手动排序时顺序是稳定的
        await db.execute('UPDATE books SET sort_order = added_at WHERE sort_order = 0');
      }
    }

    if (oldV < 5) {
      // 临时修改规则
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='text_rules'",
      );
      if (tables.isEmpty) {
        await _createTextRules(db);
      }
    }

    if (oldV < 6) {
      // 书籍详情：简介 / 字数 / 累计阅读时长
      final bcols = await db.rawQuery('PRAGMA table_info(books)');
      Future<void> addCol(String name, String ddl) async {
        if (!bcols.any((c) => c['name'] == name)) {
          await db.execute('ALTER TABLE books ADD COLUMN $ddl');
        }
      }

      await addCol('description', "description TEXT NOT NULL DEFAULT ''");
      await addCol('word_count', 'word_count INTEGER NOT NULL DEFAULT 0');
      await addCol('read_seconds', 'read_seconds INTEGER NOT NULL DEFAULT 0');

      // 老书没有字数：用章节字数汇总回填（chapters 表导入时已经算过 char_count）
      await db.execute('''
        UPDATE books SET word_count = COALESCE(
          (SELECT SUM(char_count) FROM chapters WHERE chapters.book_id = books.id), 0
        ) WHERE word_count = 0
      ''');
    }
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
