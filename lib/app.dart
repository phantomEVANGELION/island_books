import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'features/bookshelf/bookshelf_page.dart';

class IslandBooksApp extends StatelessWidget {
  const IslandBooksApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '岛上书店',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const BookshelfPage(),
    );
  }
}
