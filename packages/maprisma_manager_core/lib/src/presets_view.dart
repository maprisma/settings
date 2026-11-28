import 'dart:convert';

import 'context.dart';
import 'theme_view.dart';
import 'translations.dart';

/// The Presets page: workspace presets, app presets and saved presets managed through
/// `maprisma-theme-core call <method> [<json>]`. Reuses [ThemeViewService.binary] for locating
/// Maprisma Theme's core binary; nothing of Theme's own config files is written directly here.
final class PresetsViewService {
  PresetsViewService(this.ctx, this.themeView);
  final Ctx ctx;
  final ThemeViewService themeView;

  static const presetNames = [
    'side-by-side',
    'stacked',
    'master-left',
    'master-right',
    'columns',
    'grid',
    'floating',
    'scrolling',
    'none',
  ];
  static const workspaceModes = ['tiled', 'floating', 'default'];
  static const bulkActions = ['reset_all', 'remove_all'];
  static const restoreActions = ['ask', 'move', 'close', 'keep'];
  static const assignParts = ['theme', 'wallpaper', 'both'];

  Set<String>? _caps;

  String _need() => themeView.binary() ?? (throw RouteError('not_installed', tr('Maprisma Theme is not installed')));

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 20),
  ]) async {
    final args = <String>[
      _need(),
      'call',
      method,
      if (params != null && params.isNotEmpty) jsonEncode(params),
    ];
    final r = await ctx.runner.run(args, timeout: timeout);
    Object? v;
    try {
      v = jsonDecode(r.stdout.trim().split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => ''));
    } on FormatException {
      v = null;
    }
    if (v is Map<String, dynamic>) {
      final error = v['error'];
      if (error is String) {
        if (error == 'bad_args' || error == 'not_allowed') {
          throw RouteError('too_old', tr('Update Maprisma Theme to manage presets here'));
        }
        throw RouteError(error, v['message'] is String ? v['message'] as String : null);
      }
      if (r.ok) return v;
    }
    if (r.code == 124) throw RouteError('timeout', tr('Maprisma Theme took too long'));
    throw RouteError('failed', r.stderr.trim().isEmpty ? trf('exit {0}', [r.code]) : r.stderr.trim().split('\n').first);
  }

  Future<bool> _canTile() async {
    if (_caps == null) {
      final info = await _call('desktop.info');
      _caps = {for (final c in (info['caps'] as List?) ?? const []) if (c is String) c};
    }
    return _caps!.contains('tiling');
  }

  Future<({bool applied, String? error})> _maybeApplyTiling() async {
    if (!await _canTile()) return (applied: false, error: null);
    try {
      await _call('workspaces.apply', null, const Duration(seconds: 30));
      return (applied: true, error: null);
    } on RouteError catch (e) {
      return (applied: false, error: e.message ?? e.code);
    }
  }

  int _intRange(Map<String, dynamic> p, String key, int min, int max) {
    final v = p[key];
    if (v is! int || v < min || v > max) throw RouteError('bad_params', key);
    return v;
  }

  bool _boolParam(Map<String, dynamic> p, String key) {
    final v = p[key];
    if (v is! bool) throw RouteError('bad_params', key);
    return v;
  }

  String _nonEmptyStr(Map<String, dynamic> p, String key, {int maxLen = 255}) {
    final v = p[key];
    if (v is! String || v.trim().isEmpty || v.length > maxLen || v.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw RouteError('bad_params', key);
    }
    return v;
  }

  /// `presets.load`: compact single call loading desktop capabilities, saved presets, themes,
  /// and (when supported) workspace state and workspace looks.
  Future<Map<String, dynamic>> load() async {
    final desktop = await _call('desktop.info');
    final caps = {for (final c in (desktop['caps'] as List?) ?? const []) if (c is String) c};
    _caps = caps;
    final hasWorkspaces = caps.contains('workspaces');
    final results = await Future.wait<Map<String, dynamic>?>([
      _call('presets.list'),
      _call('themes.list'),
      if (hasWorkspaces) _call('workspaces.get') else Future.value(null),
      if (hasWorkspaces) _call('workspaces.looks') else Future.value(null),
    ]);
    final presetsList = results[0]!;
    final themesList = results[1]!;
    final wsGet = results[2];
    final wsLooks = results[3];
    return {
      'desktop': desktop,
      'state': wsGet?['state'],
      'looks': wsLooks,
      'presets': presetsList['presets'] is List ? presetsList['presets'] : const [],
      'themes': themesList['themes'] is List ? themesList['themes'] : const [],
    };
  }

  /// `presets.set`: validates and forwards workspace/default/tiling settings to `workspaces.set`,
  /// and applies tiling immediately when `apply == true` and the desktop supports tiling.
  Future<Map<String, dynamic>> set(Map<String, dynamic> params) async {
    final out = <String, dynamic>{};
    if (params.containsKey('active')) out['active'] = _boolParam(params, 'active');
    if (params.containsKey('autoMoveOnRestore')) out['autoMoveOnRestore'] = _boolParam(params, 'autoMoveOnRestore');
    if (params.containsKey('maxWindows')) out['maxWindows'] = _intRange(params, 'maxWindows', 1, 4);
    if (params.containsKey('workspace')) out['workspace'] = _intRange(params, 'workspace', 1, 10);
    if (params.containsKey('limit')) {
      final v = params['limit'];
      if (v != null && (v is! int || v < 1 || v > 4)) throw RouteError('bad_params', 'limit');
      out['limit'] = v;
    }
    if (params.containsKey('mode')) {
      final v = params['mode'];
      if (v != null && (v is! String || !workspaceModes.contains(v))) throw RouteError('bad_params', 'mode');
      out['mode'] = v;
    }
    if (params.containsKey('preset')) {
      final v = params['preset'];
      if (v != null && (v is! String || !presetNames.contains(v))) throw RouteError('bad_params', 'preset');
      out['preset'] = v;
    }
    if (params.containsKey('defaultLimit')) out['defaultLimit'] = _intRange(params, 'defaultLimit', 1, 4);
    if (params.containsKey('defaultMode')) {
      final v = params['defaultMode'];
      if (v != null && (v is! String || !workspaceModes.contains(v))) throw RouteError('bad_params', 'defaultMode');
      out['defaultMode'] = v;
    }
    if (params.containsKey('defaultPreset')) {
      final v = params['defaultPreset'];
      if (v != null && (v is! String || !presetNames.contains(v))) throw RouteError('bad_params', 'defaultPreset');
      out['defaultPreset'] = v;
    }
    if (params.containsKey('split')) {
      final v = params['split'];
      if (v != null) {
        if (v is! num || !v.isFinite || v < 0.2 || v > 0.8) throw RouteError('bad_params', 'split');
        out['split'] = (v.toDouble() * 100).round() / 100;
      } else {
        out['split'] = null;
      }
    }
    if (!params.containsKey('workspace') &&
        (params.containsKey('limit') || params.containsKey('mode') || params.containsKey('preset'))) {
      throw RouteError('bad_params', 'workspace');
    }
    if (!params.containsKey('defaultLimit') &&
        (params.containsKey('defaultMode') || params.containsKey('defaultPreset'))) {
      throw RouteError('bad_params', 'defaultLimit');
    }
    final apply = params.containsKey('apply') ? _boolParam(params, 'apply') : false;
    if (out.isEmpty) throw RouteError('bad_params', 'params');
    final r = await _call('workspaces.set', out);
    if (apply) {
      final t = await _maybeApplyTiling();
      return {...r, 'applied': t.applied, if (t.error != null) 'apply_error': t.error};
    }
    return r;
  }

  /// `presets.bulk`: `reset_all` or `remove_all` across all workspaces (+ tiling apply if supported).
  Future<Map<String, dynamic>> bulk(Map<String, dynamic> params) async {
    final action = params['action'];
    if (action is! String || !bulkActions.contains(action)) throw RouteError('bad_params', 'action');
    final r = await _call('workspaces.bulk', {'action': action});
    final t = await _maybeApplyTiling();
    return {...r, 'applied': t.applied, if (t.error != null) 'apply_error': t.error};
  }

  /// `presets.reset`: clears all workspace presets and app presets (+ tiling apply if supported).
  Future<Map<String, dynamic>> reset() async {
    final r = await _call('workspaces.reset');
    final t = await _maybeApplyTiling();
    return {...r, 'applied': t.applied, if (t.error != null) 'apply_error': t.error};
  }

  /// `presets.apply_tiling`: applies current workspace layouts/presets to the window manager.
  Future<Map<String, dynamic>> applyTiling() => _call('workspaces.apply', null, const Duration(seconds: 30));

  /// `presets.undo`: undoes the last workspace / app-preset change (across CLI invocations).
  /// On desktops with `presetLayouts` (Hyprland), Theme's `workspaces.undo` already re-applies
  /// tiling, so a second `workspaces.apply` is skipped.
  Future<Map<String, dynamic>> undo() async {
    final r = await _call('workspaces.undo');
    if (await _canTile()) {
      if (_caps!.contains('presetLayouts')) {
        return {...r, 'undone': true, 'applied': true};
      }
      final t = await _maybeApplyTiling();
      return {...r, 'undone': true, 'applied': t.applied, if (t.error != null) 'apply_error': t.error};
    }
    return {...r, 'undone': true, 'applied': false};
  }

  /// `presets.app_launchers`: installed desktop launchers for the App Presets picker.
  Future<Map<String, dynamic>> appLaunchers() => _call('apppresets.launchers');

  /// `presets.app_add`: adds a launcher `desktop_id` to a workspace's App Preset.
  Future<Map<String, dynamic>> appAdd(Map<String, dynamic> params) {
    final ws = _intRange(params, 'workspace', 1, 10);
    final id = _nonEmptyStr(params, 'desktop_id');
    return _call('apppresets.add', {'workspace': ws, 'desktop_id': id});
  }

  /// `presets.app_save`: snapshots open windows on `workspace` as its App Preset.
  Future<Map<String, dynamic>> appSave(Map<String, dynamic> params) {
    final ws = _intRange(params, 'workspace', 1, 10);
    return _call('apppresets.save', {'workspace': ws});
  }

  /// `presets.app_remove`: removes one app (`index`) or the entire App Preset for `workspace`.
  Future<Map<String, dynamic>> appRemove(Map<String, dynamic> params) {
    final ws = _intRange(params, 'workspace', 1, 10);
    final out = <String, dynamic>{'workspace': ws};
    if (params.containsKey('index')) {
      final i = params['index'];
      if (i is! int || i < 0) throw RouteError('bad_params', 'index');
      out['index'] = i;
    }
    return _call('apppresets.remove', out);
  }

  /// `presets.app_remove_all`: removes all saved App Presets.
  Future<Map<String, dynamic>> appRemoveAll() => _call('apppresets.remove_all');

  /// `presets.app_autostart`: toggles session autostart for a workspace's App Preset.
  Future<Map<String, dynamic>> appAutostart(Map<String, dynamic> params) {
    final ws = _intRange(params, 'workspace', 1, 10);
    final enabled = _boolParam(params, 'enabled');
    return _call('apppresets.autostart', {'workspace': ws, 'enabled': enabled});
  }

  /// `presets.app_restore`: restores a workspace's App Preset (conflict action: ask/move/close/keep).
  Future<Map<String, dynamic>> appRestore(Map<String, dynamic> params) {
    final ws = _intRange(params, 'workspace', 1, 10);
    final out = <String, dynamic>{'workspace': ws};
    if (params.containsKey('action')) {
      final action = params['action'];
      if (action is! String || !restoreActions.contains(action)) throw RouteError('bad_params', 'action');
      out['action'] = action;
    }
    return _call('apppresets.restore', out, const Duration(seconds: 60));
  }

  /// `presets.saved_save`: saves the current theme/wallpaper/font (and optionally workspaces).
  Future<Map<String, dynamic>> savedSave(Map<String, dynamic> params) {
    final name = _nonEmptyStr(params, 'name', maxLen: 60);
    final out = <String, dynamic>{'name': name};
    if (params.containsKey('includeWorkspaces')) {
      out['includeWorkspaces'] = _boolParam(params, 'includeWorkspaces');
    }
    return _call('presets.save', out);
  }

  /// `presets.saved_apply`: applies a saved preset by `name`.
  Future<Map<String, dynamic>> savedApply(Map<String, dynamic> params) {
    final name = _nonEmptyStr(params, 'name', maxLen: 60);
    final out = <String, dynamic>{'name': name};
    if (params.containsKey('confirmed')) {
      out['confirmed'] = _boolParam(params, 'confirmed');
    }
    return _call('presets.apply', out, const Duration(seconds: 120));
  }

  /// `presets.saved_delete`: deletes a saved preset by `name`.
  Future<Map<String, dynamic>> savedDelete(Map<String, dynamic> params) {
    final name = _nonEmptyStr(params, 'name', maxLen: 60);
    return _call('presets.delete', {'name': name});
  }

  /// `presets.saved_assign`: assigns a saved preset's theme/wallpaper to one or more workspaces.
  Future<Map<String, dynamic>> savedAssign(Map<String, dynamic> params) {
    final name = _nonEmptyStr(params, 'name', maxLen: 60);
    final raw = params['workspaces'];
    if (raw is! List || raw.isEmpty || raw.any((w) => w is! int || w < 1 || w > 10)) {
      throw RouteError('bad_params', 'workspaces');
    }
    final out = <String, dynamic>{
      'name': name,
      'workspaces': raw.cast<int>(),
    };
    if (params.containsKey('part')) {
      final part = params['part'];
      if (part is! String || !assignParts.contains(part)) throw RouteError('bad_params', 'part');
      out['part'] = part;
    }
    return _call('presets.assign', out, const Duration(seconds: 60));
  }
}
