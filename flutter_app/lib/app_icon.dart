import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// An app's icon from the SVG or bitmap file the core found (`icon.file`); a symbolic SVG is drawn
/// in the text colour (as the panel draws it). A neutral glyph otherwise.
class AppIcon extends StatelessWidget {
  const AppIcon(this.file, {super.key, this.size = 32, this.symbolic = false, this.dim = false});
  final String? file;
  final double size;
  final bool symbolic;

  /// Not installed: drawn paler.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(Icons.widgets_outlined, size: size * .8, color: scheme.onSurfaceVariant);
    final path = file;
    Widget child;
    if (path == null || !File(path).existsSync()) {
      child = fallback;
    } else if (path.toLowerCase().endsWith('.svg')) {
      child = SvgPicture.file(
        File(path),
        width: symbolic ? size * .78 : size,
        height: symbolic ? size * .78 : size,
        colorFilter: symbolic ? ColorFilter.mode(scheme.onSurface, BlendMode.srcIn) : null,
        placeholderBuilder: (_) => SizedBox(width: size, height: size),
      );
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
