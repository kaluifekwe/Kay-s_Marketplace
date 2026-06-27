import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class AppImage extends StatelessWidget {
  final String? source;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? errorWidget;

  const AppImage({
    super.key,
    this.source,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorWidget,
  });

  @override
  Widget build(BuildContext context) {
    if (source == null || source!.isEmpty) {
      return _fallback();
    }

    if (source!.startsWith('http://') || source!.startsWith('https://')) {
      // Cached to disk so the same image isn't re-downloaded on every
      // rebuild/scroll — important on metered/slow Nigerian mobile data.
      return CachedNetworkImage(
        imageUrl: source!,
        width: width,
        height: height,
        fit: fit,
        fadeInDuration: Duration.zero,
        placeholder: (context, url) => Container(
          width: width,
          height: height,
          color: Colors.grey[100],
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.grey[400],
              ),
            ),
          ),
        ),
        errorWidget: (_, __, ___) => _fallback(),
      );
    }

    return Image.file(
      File(source!),
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, __, ___) => _fallback(),
    );
  }

  Widget _fallback() {
    return errorWidget ??
        Container(
          width: width,
          height: height,
          color: Colors.grey[200],
          child: const Icon(Icons.inventory_2, size: 40, color: Colors.grey),
        );
  }
}
