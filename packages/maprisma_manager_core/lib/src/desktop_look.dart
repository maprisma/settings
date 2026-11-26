import 'package:maprisma_core_kit/desktop.dart' as kit;

import 'catalog_model.dart' show DesktopId;
import 'context.dart';

/// `desktop.look`: the desktop's palette, window corners, dark-mode flag, and fonts,
/// delegated to `maprisma_core_kit/desktop.dart` using [ctx]'s paths, runner, and clock.
Future<Map<String, dynamic>> desktopLook(Ctx ctx) => kit.readDesktopLook(
  desktop: _desktop(ctx.desktop),
  paths: _paths(ctx),
  hypr: _hyprFor(ctx),
  gtk: _gtkFor(ctx),
);

/// The desktop's interface and monospace font families (`{ui, mono}`).
Future<Map<String, String>> desktopFonts(Ctx ctx) => kit.readDesktopFonts(
  desktop: _desktop(ctx.desktop),
  paths: _paths(ctx),
  gtk: _gtkFor(ctx),
);

/// Hyprland's window corner rounding (`decoration:rounding`), cached per [ctx] for 30 s.
Future<int?> hyprRounding(Ctx ctx) => _hyprFor(ctx).read();

kit.DesktopId _desktop(DesktopId id) => switch (id) {
  DesktopId.cosmic => kit.DesktopId.cosmic,
  DesktopId.kde => kit.DesktopId.kde,
  DesktopId.hyprland => kit.DesktopId.hyprland,
  DesktopId.other => kit.DesktopId.other,
};

kit.LookPaths _paths(Ctx ctx) => kit.LookPaths(
  config: ctx.paths.config,
  state: ctx.paths.state,
  root: ctx.paths.root,
);

kit.DesktopCommandRun _run(Ctx ctx, String program) => (args, timeout) async {
  final r = await ctx.runner.run([program, ...args], timeout: timeout);
  return r.ok ? r.stdout : null;
};

final _gtkCache = Expando<kit.GtkFonts>('gtkFonts');
final _hyprCache = Expando<kit.HyprRounding>('hyprRounding');

kit.GtkFonts _gtkFor(Ctx ctx) =>
    _gtkCache[ctx] ??= kit.GtkFonts(run: _run(ctx, 'gsettings'), clock: ctx.clock);

kit.HyprRounding _hyprFor(Ctx ctx) =>
    _hyprCache[ctx] ??= kit.HyprRounding(run: _run(ctx, 'hyprctl'), clock: ctx.clock);
