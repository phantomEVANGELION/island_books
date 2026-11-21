import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 封面相关的两个动作：从相册替换、把当前封面另存出去。
/// 书籍详情页和分组详情页共用。
class CoverActions {
  /// 从相册选图并落盘到应用目录，返回新封面的绝对路径；用户取消返回 null。
  static Future<String?> pickFromGallery(int key) async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1400,
        imageQuality: 88,
      );
    } catch (e) {
      debugPrint('pick cover failed: $e');
      return null;
    }
    if (picked == null) return null;

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'covers'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = File(p.join(dir.path, 'c${key}_$stamp.jpg'));
    await dest.writeAsBytes(await File(picked.path).readAsBytes(), flush: false);
    return dest.path;
  }

  /// 把封面另存到用户选择的位置。返回 true 表示已保存。
  static Future<bool> saveAs(String coverPath, String baseName) async {
    final f = File(coverPath);
    if (!f.existsSync()) return false;
    final bytes = await f.readAsBytes();
    final safeName = baseName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final ext = p.extension(coverPath).isEmpty ? '.jpg' : p.extension(coverPath);
    final target = await FilePicker.saveFile(
      dialogTitle: '保存封面',
      fileName: '${safeName.isEmpty ? 'cover' : safeName}$ext',
      bytes: bytes,
      type: FileType.image,
    );
    return target != null;
  }
}
