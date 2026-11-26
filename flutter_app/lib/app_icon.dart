import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// An app's icon from the SVG or bitmap file the core found (`icon.file`); a symbolic SVG is drawn
/// in the text colour (as the panel draws it). A neutral glyph otherwise.
class AppIcon extends StatelessWidget {
  const AppIcon(this.file, {super.key, this.size = 32, this.symbolic = false, this.dim = false, this.cacheKey});
  final String? file;
  final double size;
  final bool symbolic;

  /// Not installed: drawn paler.
  final bool dim;

  /// When set (e.g. a file SHA), SVG bytes are read directly from disk so overwritten icons
  /// never get stuck on a stale `flutter_svg` file cache entry.
  final String? cacheKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(Icons.widgets_outlined, size: size * .8, color: scheme.onSurfaceVariant);
    final path = file;
    Widget child;
    if (path == null || !File(path).existsSync()) {
      child = fallback;
    } else if (path.toLowerCase().endsWith('.svg')) {
      final svgSize = symbolic ? size * .78 : size;
      final filter = symbolic ? ColorFilter.mode(scheme.onSurface, BlendMode.srcIn) : null;
      if (cacheKey != null) {
        try {
          final bytes = File(path).readAsBytesSync();
          child = bytes.isEmpty
              ? fallback
              : SvgPicture.memory(
                  bytes,
                  key: ValueKey('$path#$cacheKey'),
                  width: svgSize,
                  height: svgSize,
                  colorFilter: filter,
                  placeholderBuilder: (_) => SizedBox(width: size, height: size),
                );
        } on FileSystemException {
          child = fallback;
        }
      } else {
        child = SvgPicture.file(
          File(path),
          width: svgSize,
          height: svgSize,
          colorFilter: filter,
          placeholderBuilder: (_) => SizedBox(width: size, height: size),
        );
      }
    } else {
      child = Image.file(
        File(path),
        width: size,
        height: size,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Center(child: Opacity(opacity: dim ? .45 : 1, child: child)),
    );
  }
}
