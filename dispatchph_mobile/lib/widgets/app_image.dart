import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class AppImage extends StatelessWidget {
  final String? source;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? errorWidget;

  /// When set, request a resized thumbnail (this logical width) instead of the
  /// full-resolution photo. For Supabase Storage images this hits the image
  /// transform endpoint, so the feed/cart download small thumbnails instead of
  /// multi-MB originals — a big win on slow Nigerian networks. Leave null on
  /// full-screen views (e.g. the product page) to get the original.
  final int? thumbWidth;

  const AppImage({
    super.key,
    this.source,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorWidget,
    this.thumbWidth,
  });

  /// Rewrite a Supabase Storage public URL to its image-transform endpoint at
  /// [thumbWidth]. Non-Supabase or already-transformed URLs are returned as-is.
  String _resolvedUrl() {
    final url = source!;
    if (thumbWidth == null) return url;
    const objectPath = '/storage/v1/object/public/';
    if (!url.contains(objectPath) || url.contains('/render/image/')) return url;
    final rendered = url.replaceFirst(objectPath, '/storage/v1/render/image/public/');
    final sep = rendered.contains('?') ? '&' : '?';
    return '$rendered${sep}width=$thumbWidth&quality=70';
  }

  @override
  Widget build(BuildContext context) {
    if (source == null || source!.isEmpty) {
      return _fallback();
    }

    if (source!.startsWith('http://') || source!.startsWith('https://')) {
      // Decode at (roughly) display resolution to cut memory + decode time,
      // scaled for the device's pixel ratio so it still looks crisp.
      final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
      final memWidth = thumbWidth == null ? null : (thumbWidth! * dpr).round();
      // Cached to disk so the same image isn't re-downloaded on every
      // rebuild/scroll — important on metered/slow Nigerian mobile data.
      return CachedNetworkImage(
        imageUrl: _resolvedUrl(),
        width: width,
        height: height,
        fit: fit,
        memCacheWidth: memWidth,
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
