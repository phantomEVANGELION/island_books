import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_paths.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 预热沙盒路径：库里存的是绝对路径，iOS 重装后容器 UUID 会变
  await AppPaths.init();
  runApp(const IslandBooksApp());
}
