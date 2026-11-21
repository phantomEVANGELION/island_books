import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 还原 EPUB 的「字体混淆」。
///
/// 这不是 DRM：出版方只是把内嵌字体文件做了个 XOR，防止别人把字体抠出来商用，
/// 正文一直是明文。两种标准算法：
///
/// - **IDPF**：key = SHA1(unique-identifier 字符串)，前 **1040** 字节与 key 循环 XOR
/// - **Adobe**：key = unique-identifier 里 UUID 的 **16 字节**，前 **1024** 字节 XOR
///
/// 解不开时原样返回（宁可字体加载失败回落系统字体，也不要把文件写坏）。
class FontDeobfuscator {
  const FontDeobfuscator._();

  static const idpfAlgorithm = 'http://www.idpf.org/2008/embedding';
  static const adobeAlgorithm = 'http://ns.adobe.com/pdf/enc#RC';

  static bool isFontObfuscation(String algorithm) =>
      algorithm == idpfAlgorithm || algorithm == adobeAlgorithm;

  /// 按算法还原；不认识的算法原样返回
  static Uint8List deobfuscate(
    List<int> data,
    String algorithm,
    String identifier,
  ) {
    if (algorithm == idpfAlgorithm) return _idpf(data, identifier);
    if (algorithm == adobeAlgorithm) return _adobe(data, identifier);
    return Uint8List.fromList(data);
  }

  /// 解开后是不是一个合法字体（用来兜底：解错了就别写出去）
  static bool looksLikeFont(List<int> b) {
    if (b.length < 4) return false;
    // TrueType: 00 01 00 00
    if (b[0] == 0x00 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00) return true;
    // 'true' / 'OTTO' / 'ttcf' / 'wOFF' / 'wOF2'
    final tag = String.fromCharCodes(b.sublist(0, 4));
    return tag == 'true' || tag == 'OTTO' || tag == 'ttcf' || tag == 'wOFF' || tag == 'wOF2';
  }

  static Uint8List _idpf(List<int> data, String identifier) {
    final key = sha1.convert(utf8.encode(identifier)).bytes;
    return _xor(data, key, 1040);
  }

  static Uint8List _adobe(List<int> data, String identifier) {
    // urn:uuid:fded1e93-f0f7-4d65-9057-7332b688aa0e → 16 字节
    final hex = identifier
        .replaceFirst(RegExp(r'^urn:uuid:', caseSensitive: false), '')
        .replaceAll(RegExp(r'[{}\-]'), '');
    if (hex.length < 32) return Uint8List.fromList(data);
    final key = <int>[];
    for (var i = 0; i < 32; i += 2) {
      final v = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (v == null) return Uint8List.fromList(data);
      key.add(v);
    }
    return _xor(data, key, 1024);
  }

  static Uint8List _xor(List<int> data, List<int> key, int limit) {
    final out = Uint8List.fromList(data);
    if (key.isEmpty) return out;
    final n = out.length < limit ? out.length : limit;
    for (var i = 0; i < n; i++) {
      out[i] ^= key[i % key.length];
    }
    return out;
  }
}
