import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用沙盒路径。
///
/// iOS 的 Documents 路径里带一个**安装 UUID**：
/// `/var/mobile/Containers/Data/Application/<UUID>/Documents/...`
/// 每次重装 / 更新 app，这个 UUID 都可能变。数据库里如果存的是绝对路径，
/// 重装后所有书都会显示「书籍文件缺失」——文件其实还在，只是路径对不上了。
///
/// 所以统一按「当前沙盒 + books/<目录名>」重新拼，数据库里存什么都不怕。
class AppPaths {
  AppPaths._();

  /// 缓存的 Documents 目录（main 里预热，避免每次同步读取都 await）
  static String docsDir = '';

  static Future<void> init() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      docsDir = d.path;
    } catch (_) {
      // 拿不到就退回原值，行为跟修复前一致
    }
  }

  /// 把数据库里存的路径解析成**当前**沙盒里可用的路径。
  /// 数据库里可能存的是旧容器的绝对路径（`/var/.../Documents/books/xxx/...`）
  /// 或相对路径（`books/xxx/...`），统一按 `books/` 之后的部分重新拼。
  static String resolve(String stored) {
    if (stored.isEmpty || docsDir.isEmpty) return stored;
    final norm = stored.replaceAll('\\', '/');

    // 相对写法：books/xxx/...
    if (norm.startsWith('books/')) return p.join(docsDir, norm);

    // 绝对写法：取 /books/ 之后的部分（保留 books/xxx/... 结构）
    const marker = '/books/';
    final idx = norm.indexOf(marker);
    if (idx >= 0) return p.join(docsDir, norm.substring(idx + 1));

    // 不在 books 目录下（例如自定义封面可能存在别处）：保持原样
    return stored;
  }

  /// 书籍目录（等价于 resolve，语义更明确）
  static String resolveBookDir(String stored) => resolve(stored);
}
