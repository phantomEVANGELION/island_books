import 'dart:io';

import 'package:flutter/material.dart';

/// 全屏图片查看器：双指缩放、拖动平移、双击放大/还原。
///
/// 阅读时长按正文里的插图会打开这里。
/// 图片路径来自 WebView 的 img.src（file:// 开头，指向解压后的 epub 目录）。
class ImageViewerPage extends StatefulWidget {
  final String imageUrl;

  const ImageViewerPage({super.key, required this.imageUrl});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final scaled = _transform.value.getMaxScaleOnAxis() > 1.2;
    _transform.value = scaled
        ? Matrix4.identity()
        : (Matrix4.identity()..scale(2.5));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onDoubleTap: _toggleZoom,
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 8,
                // 边界留白必须为 0：留白会让图片在原始尺寸时也能拖动，
                // 露出黑边。设为 0 后，只有放大到超出视口才能平移。
                boundaryMargin: EdgeInsets.zero,
                child: Center(child: _buildImage()),
              ),
            ),
          ),

          // 关闭
          Positioned(
            top: MediaQuery.of(context).padding.top + 6,
            right: 6,
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black45,
              ),
            ),
          ),

          // 底部提示（放大后自动淡出）
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 18,
            child: const IgnorePointer(
              child: Center(
                child: Text(
                  '双指缩放 · 拖动查看 · 双击放大',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 加载图片。
  ///
  /// 用 BoxFit.scaleDown 而不是 contain：contain 会把小图放大到撑满屏幕，
  /// 看细节时反而更糊。scaleDown 只缩不放——
  /// 大图缩到适应屏幕，小图保持原始像素尺寸。
  Widget _buildImage() {
    final uri = Uri.tryParse(widget.imageUrl);

    if (uri != null && uri.scheme == 'file') {
      try {
        return Image.file(
          File(uri.toFilePath()),
          fit: BoxFit.scaleDown,
          errorBuilder: (_, __, ___) => const _LoadError(),
        );
      } catch (_) {
        return const _LoadError();
      }
    }

    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return Image.network(
        widget.imageUrl,
        fit: BoxFit.scaleDown,
        errorBuilder: (_, __, ___) => const _LoadError(),
      );
    }

    return const _LoadError();
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, color: Colors.white38, size: 48),
        SizedBox(height: 12),
        Text('图片加载失败', style: TextStyle(color: Colors.white54, fontSize: 13)),
      ],
    );
  }
}
