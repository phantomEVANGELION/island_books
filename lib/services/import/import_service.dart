import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/models/book.dart';
import '../../data/models/chapter.dart';
import '../../data/repositories/book_repository.dart';
import '../epub/epub_extractor.dart';
import '../epub/epub_parser.dart';
import '../render/reader_html_builder.dart';

class ImportResult {
  final Book? book;
  final String? error;
  const ImportResult.success(this.book) : error = null;
  const ImportResult.failure(this.error) : book = null;
  bool get ok => book != null;
}

/// 导入一本书：解析 → 解压 → 落库。
class ImportService {
  final BookRepository repo;
  ImportService(this.repo);

  /// 书籍根目录（应用私有，卸载 App 一起清掉）
  static Future<Directory> booksRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'books'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<ImportResult> importEpub(File src) async {
    final name = p.basenameWithoutExtension(src.path);

    Archive archive;
    try {
      final bytes = await src.readAsBytes();
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      return const ImportResult.failure('文件损坏或不是有效的 EPUB');
    }

    EpubPackage pkg;
    try {
      pkg = EpubParser.parse(archive, fallbackTitle: name);
    } on EpubParseException catch (e) {
      return ImportResult.failure(e.message);
    } catch (e) {
      return ImportResult.failure('解析失败：$e');
    }

    if (pkg.hasDrm) {
      return const ImportResult.failure('这本书有 DRM 版权保护，无法打开');
    }
    if (pkg.chapters.isEmpty) {
      return const ImportResult.failure('这本书里没有可阅读的章节');
    }

    final root = await booksRoot();
    final bookId = DateTime.now().microsecondsSinceEpoch;
    final bookDir = Directory(p.join(root.path, '$bookId'));
    await bookDir.create(recursive: true);

    try {
      await EpubExtractor.extract(archive, pkg, bookDir);
    } catch (e) {
      return ImportResult.failure('解压失败：$e');
    }

    final coverPath = await EpubExtractor.extractCover(archive, pkg, bookDir);

    // 章节对象先建好（bookId 待插入后再补），生成阅读页 HTML 需要它
    final chapterModels = pkg.chapters
        .map((c) => Chapter(
              bookId: 0,
              spineIndex: c.spineIndex,
              title: c.title,
              href: c.href,
              level: c.level,
              charCount: c.charCount,
            ))
        .toList();

    // 生成 index.html：所有章节拼成一个页面，滚动模式才能无缝衔接
    try {
      await ReaderHtmlBuilder.build(
        archive: archive,
        pkg: pkg,
        bookDir: bookDir,
        chapters: chapterModels,
        bookTitle: pkg.title,
      );
    } catch (e) {
      return ImportResult.failure('生成阅读页面失败：$e');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final totalWords = chapterModels.fold<int>(0, (sum, c) => sum + c.charCount);
    final book = Book(
      title: pkg.title,
      author: pkg.author,
      coverPath: coverPath,
      filePath: src.path,
      bookDir: bookDir.path,
      format: 'epub',
      fileSize: await src.length(),
      chapterCount: pkg.chapters.length,
      addedAt: now,
      // 初始手动排序序号 = 导入时间，保证第一次拖动时顺序稳定
      sortOrder: now,
      description: pkg.description,
      wordCount: totalWords,
    );

    final id = await repo.insertBook(book);
    await repo.insertChapters(
      chapterModels
          .map((c) => Chapter(
                bookId: id,
                spineIndex: c.spineIndex,
                title: c.title,
                href: c.href,
                level: c.level,
                charCount: c.charCount,
              ))
          .toList(),
    );

    return ImportResult.success(book.copyWith(id: id));
  }
}
