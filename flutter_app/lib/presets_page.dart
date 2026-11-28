import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;
import 'package:maprisma_ui/settings.dart';

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'theme.dart';

/// All 9 Workspace Presets layout identifiers in UI order.
const presetLayoutNames = [
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

/// Presets that let windows move freely without a tiling window limit.
const freePresetNames = ['floating', 'scrolling'];

/// Presets that support a split ratio divider.
const splitPresetNames = ['master-left', 'master-right', 'side-by-side', 'stacked', 'columns'];

/// COSMIC/KDE workspace modes.
const desktopModeNames = ['tiled', 'floating', 'default'];

/// Compatible tiling presets for each window limit (`1..4`).
const tilingPresetsByCap = <int, List<String>>{
  1: ['side-by-side'],
  2: ['side-by-side', 'stacked'],
  3: ['columns', 'master-left', 'master-right'],
  4: ['columns', 'master-left', 'master-right', 'grid'],
};

const _previewGap = 0.035;
const _splitMin = 0.20;
const _splitMax = 0.80;
const _columnsSplitMax = 0.60;
const _groups = [(1, 5), (6, 10)];

/// Built-in default tiling preset for a window limit [cap].
String builtinDefaultPreset(int cap) => switch (cap) {
  2 => 'side-by-side',
  3 => 'master-left',
  4 => 'grid',
  _ => 'side-by-side',
};

/// Whether [preset] is active (not dimmed) for window limit [cap].
bool isPresetCompatibleWithCap(String preset, int cap) {
  if (preset == 'none' || preset == 'default' || freePresetNames.contains(preset)) return true;
  if (preset == 'tiled') return cap >= 1;
  final allowed = tilingPresetsByCap[cap];
  return allowed != null && allowed.contains(preset);
}

/// Whether [preset] with window limit [cap] exposes a split ratio slider.
bool presetHasSplit(String preset, int cap) {
  if (preset == 'columns') return cap == 3;
  return splitPresetNames.contains(preset) && cap >= 2;
}

/// Allowed `(min, max)` split ratio range for [preset].
(double, double) presetSplitRange(String preset) =>
    preset == 'columns' ? (_splitMin, _columnsSplitMax) : (_splitMin, _splitMax);

/// Normalized `0..1` window rectangles for [preset] with [count] windows.
/// Supports all 9 Workspace Presets plus COSMIC/KDE `tiled` / `default` autotile modes.
List<Rect> presetRects(String preset, int count, {double? split, double aspect = 16 / 9}) {
  if (preset == 'tiled' || preset == 'default') return _autotileRects(count, aspect: aspect);
  const g = _previewGap;
  const half = (1 - 3 * g) / 2;

  if (preset == 'floating') {
    if (count <= 0) return const [];
    return const [
      Rect.fromLTWH(0.08, 0.12, 0.5, 0.5),
      Rect.fromLTWH(0.3, 0.28, 0.5, 0.5),
      Rect.fromLTWH(0.5, 0.08, 0.42, 0.42),
    ];
  }
  if (preset == 'scrolling') {
    if (count <= 0) return const [];
    return const [
      Rect.fromLTWH(g, g, 0.42, 1 - 2 * g),
      Rect.fromLTWH(2 * g + 0.42, g, 0.42, 1 - 2 * g),
      Rect.fromLTWH(3 * g + 0.84, g, 0.42, 1 - 2 * g),
    ];
  }
  if (preset == 'none') {
    if (count <= 0) return const [];
    return const [
      Rect.fromLTWH(g, g, half, 1 - 2 * g),
      Rect.fromLTWH(2 * g + half, g, half, half),
      Rect.fromLTWH(2 * g + half, 2 * g + half, half, half),
    ];
  }
  if (count <= 0) return const [];
  if (count == 1) return const [Rect.fromLTWH(g, g, 1 - 2 * g, 1 - 2 * g)];

  final share = split == null || split.isNaN ? 0.5 : split.clamp(_splitMin, _splitMax);
  final first = (1 - 3 * g) * share;
  final second = (1 - 3 * g) - first;

  List<Rect> column(double x, double w, int n) {
    final h = (1 - (n + 1) * g) / n;
    return [for (var i = 0; i < n; i++) Rect.fromLTWH(x, g + i * (h + g), w, h)];
  }

  return switch (preset) {
    'side-by-side' => [
      Rect.fromLTWH(g, g, first, 1 - 2 * g),
      Rect.fromLTWH(2 * g + first, g, second, 1 - 2 * g),
    ],
    'stacked' => [
      Rect.fromLTWH(g, g, 1 - 2 * g, first),
      Rect.fromLTWH(g, 2 * g + first, 1 - 2 * g, second),
    ],
    'master-left' => [
      Rect.fromLTWH(g, g, first, 1 - 2 * g),
      ...column(2 * g + first, second, math.max(1, count - 1)),
    ],
    'master-right' => [
      ...column(g, second, math.max(1, count - 1)),
      Rect.fromLTWH(2 * g + second, g, first, 1 - 2 * g),
    ],
    'columns' => () {
      final n = math.max(2, count);
      if (n == 3 && split != null && !split.isNaN) {
        const part = 1 - 4 * g;
        final mid = part * split.clamp(_splitMin, _columnsSplitMax);
        final side = (part - mid) / 2;
        return [
          Rect.fromLTWH(g, g, side, 1 - 2 * g),
          Rect.fromLTWH(2 * g + side, g, mid, 1 - 2 * g),
          Rect.fromLTWH(3 * g + side + mid, g, side, 1 - 2 * g),
        ];
      }
      final w = (1 - (n + 1) * g) / n;
      return [for (var i = 0; i < n; i++) Rect.fromLTWH(g + i * (w + g), g, w, 1 - 2 * g)];
    }(),
    'grid' => const [
      Rect.fromLTWH(g, g, half, half),
      Rect.fromLTWH(2 * g + half, g, half, half),
      Rect.fromLTWH(g, 2 * g + half, half, half),
      Rect.fromLTWH(2 * g + half, 2 * g + half, half, half),
    ],
    _ => const [
      Rect.fromLTWH(g, g, half, 1 - 2 * g),
      Rect.fromLTWH(2 * g + half, g, half, half),
      Rect.fromLTWH(2 * g + half, 2 * g + half, half, half),
    ],
  };
}

List<Rect> _autotileRects(int count, {double aspect = 16 / 9}) {
  final n = count.clamp(0, 8);
  if (n == 0) return const [];
  final cells = <Rect>[const Rect.fromLTWH(0, 0, 1, 1)];
  for (var i = 1; i < n; i++) {
    final last = cells.removeLast();
    if (last.width * aspect >= last.height) {
      cells.addAll([
        Rect.fromLTWH(last.left, last.top, last.width / 2, last.height),
        Rect.fromLTWH(last.left + last.width / 2, last.top, last.width / 2, last.height),
      ]);
    } else {
      cells.addAll([
        Rect.fromLTWH(last.left, last.top, last.width, last.height / 2),
        Rect.fromLTWH(last.left, last.top + last.height / 2, last.width, last.height / 2),
      ]);
    }
  }
  const g = _previewGap;
  return [
    for (final c in cells)
      Rect.fromLTRB(
        c.left + (c.left <= 0.0001 ? g : g / 2),
        c.top + (c.top <= 0.0001 ? g : g / 2),
        c.right - (c.right >= 0.9999 ? g : g / 2),
        c.bottom - (c.bottom >= 0.9999 ? g : g / 2),
      ),
  ];
}

/// Human-readable label for a Workspace Preset or COSMIC/KDE mode.
String presetLabel(String preset) => switch (preset) {
  'side-by-side' => tr('Side by Side'),
  'stacked' => tr('Stacked'),
  'master-left' => tr('Master Left'),
  'master-right' => tr('Master Right'),
  'columns' => tr('Columns'),
  'grid' => tr('Grid'),
  'floating' => tr('Floating'),
  'scrolling' => tr('Scrolling'),
  'tiled' => tr('Tiled'),
  'none' || 'default' => tr('Native'),
  _ => preset,
};

/// The Presets page in Maprisma Settings: manages Workspace Presets, App Presets,
/// and Save/Load Presets via Maprisma Theme's core (`presets.*` routes).
class PresetsPage extends StatefulWidget {
  const PresetsPage({super.key, required this.core, this.onShowApps});
  final CoreCall core;

  /// Navigates to the Maprisma Apps page when Maprisma Theme is not installed.
  final VoidCallback? onShowApps;

  @override
  State<PresetsPage> createState() => _PresetsPageState();
}

class _PresetsPageState extends State<PresetsPage> {
  Map<String, dynamic>? data;
  ServiceError? problem;
  bool busy = false;
  bool canUndo = false;
  bool _chosenOnce = false;

  /// 0 = Workspaces, 1 = App Presets, 2 = Save/Load Presets
  int tab = 0;
  int group = 0;

  /// 0 = All Workspaces (Workspaces tab only), 1..10 = Workspace N
  int selected = 1;

  /// Pending App Preset restore conflict ({workspace, conflict_count}).
  Map<String, dynamic>? conflict;

  /// Live slider value while dragging split ratio.
  double? _draftSplit;

  bool includeWorkspaces = true;
  final nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  // --- desktop capability & state helpers --------------------------------------------------

  Map<String, dynamic> get desktop => (data?['desktop'] as Map?)?.cast<String, dynamic>() ?? const {};
  Set<String> get caps => {for (final c in (desktop['caps'] as List?) ?? const []) if (c is String) c};
  bool can(String cap) => caps.contains(cap);
  String get desktopName {
    final n = desktop['name'];
    return n is String && n.isNotEmpty ? n : tr('this desktop');
  }

  bool get hasWorkspaces => can('workspaces');
  bool get hasAppPresets => hasWorkspaces && can('windows');
  bool get hasTiling => can('tiling');
  bool get hasPresetLayouts => can('presetLayouts');
  bool get hasSplits => can('splits');
  bool get canSaveWorkspaces => hasWorkspaces && hasTiling && can('windows');

  Map<String, dynamic> get wsState => (data?['state'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get wsLooksRoot => (data?['looks'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get wsLooks => (wsLooksRoot['workspaces'] as Map?)?.cast<String, dynamic>() ?? const {};
  List<Map<String, dynamic>> get savedPresets => [
    for (final p in (data?['presets'] as List?) ?? const [])
      if (p is Map) p.cast<String, dynamic>(),
  ];
  List<Map<String, dynamic>> get themes => [
    for (final t in (data?['themes'] as List?) ?? const [])
      if (t is Map) t.cast<String, dynamic>(),
  ];

  int? get activeWorkspace {
    final a = wsLooksRoot['active_workspace'];
    return a is int && a >= 1 && a <= 10 ? a : null;
  }

  Map get wsCaps => wsState['workspaceCaps'] as Map? ?? const {};
  Map get wsModes => wsState['workspaceModes'] as Map? ?? const {};
  Map get wsPresets => wsState['workspacePresets'] as Map? ?? const {};
  Map get wsSplits => wsState['workspaceSplits'] as Map? ?? const {};
  Map get defaultModes => wsState['defaultModes'] as Map? ?? const {};
  Map get defaultPresets => wsState['defaultPresets'] as Map? ?? const {};
  Map get wsLayouts => wsState['workspaceLayouts'] as Map? ?? const {};
  int get globalCap => wsState['maxWindows'] is int ? wsState['maxWindows'] as int : 2;

  int groupOf(int ws) => ws <= _groups[0].$2 ? 0 : 1;
  int currentWs() => tab == 1 && selected <= 0 ? _groups[group].$1 : selected;

  int limitOf(int ws) => ws == 0 ? globalCap : (wsCaps['$ws'] is int ? wsCaps['$ws'] as int : globalCap);

  String modeOf(int ws) {
    if (ws > 0 && wsModes['$ws'] is String) return wsModes['$ws'] as String;
    final fallback = defaultModes['${limitOf(ws)}'];
    return fallback is String ? fallback : 'default';
  }

  String presetOf(int ws) {
    final cap = limitOf(ws);
    if (ws > 0 && wsPresets['$ws'] is String) return wsPresets['$ws'] as String;
    if (ws > 0 && wsModes['$ws'] is String) {
      return switch (wsModes['$ws']) {
        'floating' => 'floating',
        'default' => 'none',
        _ => builtinDefaultPreset(cap),
      };
    }
    final defP = defaultPresets['$cap'];
    if (defP is String) return defP;
    final defM = defaultModes['$cap'];
    if (defM is String) {
      return switch (defM) {
        'floating' => 'floating',
        'default' => 'none',
        _ => builtinDefaultPreset(cap),
      };
    }
    return builtinDefaultPreset(cap);
  }

  double? splitOf(int ws) {
    final raw = ws > 0 ? wsSplits['$ws'] : null;
    if (raw is num && raw.isFinite) return raw.toDouble();
    final def = wsState['defaultSplit'];
    if (def is num && def.isFinite) return def.toDouble();
    return null;
  }

  List<String> appsOf(int ws) => [
    for (final a in ((wsLayouts['$ws'] as Map?)?['apps'] as List?) ?? const [])
      if (a is String) a,
  ];

  String layoutKeyOf(int ws) => hasPresetLayouts ? presetOf(ws) : modeOf(ws);

  String wsTitle(int ws) => ws == 0 ? tr('All Workspaces') : trf('Workspace {0}', [ws]);
  String windowsLabel(int n) => n == 1 ? trf('{0} window', [n]) : trf('{0} windows', [n]);

  String wsSummary(int ws) {
    if (tab == 1) {
      final apps = appsOf(ws);
      if (!wsLayouts.containsKey('$ws')) return tr('No App Preset');
      var text = apps.isEmpty
          ? tr('App Preset')
          : (apps.length == 1 ? trf('{0} app saved', [apps.length]) : trf('{0} apps saved', [apps.length]));
      if ((wsLayouts['$ws'] as Map?)?['autostart'] == true) text += tr(' · Autostart on');
      return text;
    }
    if (ws == 0) return trf('Default: {0}', [windowsLabel(globalCap)]);
    return trf('Max {0} · {1}', [limitOf(ws), presetLabel(layoutKeyOf(ws))]);
  }

  String? themeName(String? slug) {
    if (slug == null) return null;
    for (final t in themes) {
      if (t['slug'] == slug) return '${t['name'] ?? slug}';
    }
    return null;
  }

  // --- core calls --------------------------------------------------------------------------

  Future<void> load() async {
    try {
      final r = await widget.core('presets.load');
      if (!mounted) return;
      setState(() {
        data = r;
        problem = null;
        _draftSplit = null;
        if (!_chosenOnce) {
          _chosenOnce = true;
          final a = activeWorkspace;
          if (a != null) {
            selected = a;
            group = groupOf(a);
          }
          if (!hasWorkspaces) tab = 2;
        }
      });
    } on ServiceError catch (e) {
      if (!mounted) return;
      if (data != null) {
        tellOn(this, failure(e));
      } else {
        setState(() => problem = e);
      }
    }
  }

  Future<Map<String, dynamic>?> _runAction(
    String route,
    Map<String, dynamic> params, {
    String? done,
    bool undoable = false,
    bool reloadAfter = true,
  }) async {
    if (busy) return null;
    setState(() => busy = true);
    Map<String, dynamic>? result;
    try {
      result = await widget.core(route, params);
      if (mounted) {
        if (undoable) setState(() => canUndo = true);
        if (done != null) tellOn(this, done);
      }
      if (reloadAfter && mounted) await load();
    } on ServiceError catch (e) {
      if (mounted) tellOn(this, failure(e));
      if (reloadAfter && mounted) await load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
    return result;
  }

  Future<void> _undo() async {
    if (busy || !canUndo) return;
    setState(() => busy = true);
    try {
      await widget.core('presets.undo');
      if (mounted) {
        setState(() => canUndo = false);
        tellOn(this, tr('Undone'));
      }
      if (mounted) await load();
    } on ServiceError catch (e) {
      if (mounted) {
        if (e.code == 'not_found') setState(() => canUndo = false);
        tellOn(this, failure(e));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _openThemeApp() async {
    try {
      await widget.core('apps.open', {'id': 'theme'});
    } on ServiceError catch (e) {
      tellOn(this, failure(e));
    }
  }

  Future<bool> _confirm(String title, String body, {String? actionLabel, bool destructive = false}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
          FilledButton(
            key: const ValueKey('presets-confirm'),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(c).colorScheme.error,
                    foregroundColor: Theme.of(c).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(c, true),
            child: Text(actionLabel ?? tr('Confirm')),
          ),
        ],
      ),
    );
    return result == true;
  }

  // --- workspace actions -------------------------------------------------------------------

  Future<void> _setLimit(int ws, int cap) async {
    if (ws == 0) {
      await _runAction(
        'presets.set',
        {'maxWindows': cap, 'apply': true},
        done: trf('Default: {0}', [windowsLabel(cap)]),
        undoable: true,
      );
    } else {
      await _runAction(
        'presets.set',
        {'workspace': ws, 'limit': cap, 'apply': true},
        done: trf('Workspace {0}: {1}', [ws, windowsLabel(cap)]),
        undoable: true,
      );
    }
  }

  Future<void> _pickPreset(int ws, String preset) async {
    if (ws == 0) {
      final own = defaultPresets['$globalCap'] as String?;
      final next = own == preset ? null : preset;
      await _runAction(
        'presets.set',
        {'defaultLimit': globalCap, 'defaultPreset': next, 'apply': true},
        done: trf('Default: {0}', [presetLabel(next ?? builtinDefaultPreset(globalCap))]),
        undoable: true,
      );
    } else {
      final own = wsPresets['$ws'] as String?;
      final next = own == preset ? null : preset;
      await _runAction(
        'presets.set',
        {'workspace': ws, 'preset': next, 'apply': true},
        done: trf('Workspace {0}: {1}', [ws, next == null ? tr('Default') : presetLabel(next)]),
        undoable: true,
      );
    }
  }

  Future<void> _pickMode(int ws, String mode) async {
    if (ws == 0) {
      final own = defaultModes['$globalCap'] as String?;
      final next = own == mode ? null : mode;
      await _runAction(
        'presets.set',
        {'defaultLimit': globalCap, 'defaultMode': next, 'apply': true},
        done: trf('Default: {0}', [next == null ? tr('Native') : presetLabel(next)]),
        undoable: true,
      );
    } else {
      final own = wsModes['$ws'] as String?;
      final next = own == mode ? null : mode;
      await _runAction(
        'presets.set',
        {'workspace': ws, 'mode': next, 'apply': true},
        done: trf('Workspace {0}: {1}', [ws, next == null ? tr('Default') : presetLabel(next)]),
        undoable: true,
      );
    }
  }

  Future<void> _setSplit(int ws, double? ratio) async {
    final params = <String, dynamic>{
      if (ws > 0) 'workspace': ws,
      'split': ratio,
      'apply': true,
    };
    await _runAction(
      'presets.set',
      params,
      done: ratio == null ? tr('Even split') : trf('Split: {0} %', [(ratio * 100).round()]),
      undoable: true,
    );
  }

  // --- app preset actions ------------------------------------------------------------------

  Future<void> _addApp(int ws) async {
    if (busy) return;
    setState(() => busy = true);
    Map<String, dynamic>? result;
    try {
      result = await widget.core('presets.app_launchers');
    } on ServiceError catch (e) {
      if (mounted) tellOn(this, failure(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (result == null || !mounted) return;
    final launchers = [
      for (final l in (result['launchers'] as List?) ?? const [])
        if (l is Map) l.cast<String, dynamic>(),
    ];
    var query = '';
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) {
          final q = query.toLowerCase();
          final matches = [
            for (final l in launchers)
              if (q.isEmpty || '${l['name']} ${l['desktop_id']}'.toLowerCase().contains(q)) l,
          ];
          return AlertDialog(
            title: Text(trf('Add app to Workspace {0}', [ws])),
            content: SizedBox(
              width: 440,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('presets-launcher-search'),
                    autofocus: true,
                    decoration: InputDecoration(hintText: tr('Search apps'), prefixIcon: const Icon(Icons.search)),
                    onChanged: (v) => update(() => query = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: matches.isEmpty
                        ? Center(child: Text(tr('No installed apps found.')))
                        : ListView.builder(
                            itemCount: matches.length,
                            itemBuilder: (_, i) {
                              final l = matches[i];
                              final id = '${l['desktop_id']}';
                              return ListTile(
                                key: ValueKey('presets-launcher-$id'),
                                dense: true,
                                leading: const Icon(Icons.apps),
                                title: Text('${l['name']}'),
                                subtitle: Text(id),
                                onTap: () => Navigator.pop(c, id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Cancel')))],
          );
        },
      ),
    );
    if (picked != null && mounted) {
      await _runAction(
        'presets.app_add',
        {'workspace': ws, 'desktop_id': picked},
        done: trf('Added {0} to Workspace {1}', [picked, ws]),
        undoable: true,
      );
    }
  }

  Future<void> _restoreApps(int ws, [String? choice]) async {
    if (busy) return;
    final how = choice ?? (wsState['autoMoveOnRestore'] == true ? 'move' : 'ask');
    setState(() {
      busy = true;
      conflict = null;
    });
    Map<String, dynamic>? result;
    try {
      result = await widget.core('presets.app_restore', {'workspace': ws, 'action': how});
    } on ServiceError catch (e) {
      if (mounted) tellOn(this, failure(e));
      if (mounted) await load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (result == null || !mounted) return;
    if (result['status'] == 'conflict') {
      setState(() => conflict = {...result!, 'workspace': ws});
      return;
    }
    final failed = ((result['failed'] as List?) ?? const []).join(', ');
    final launched = ((result['launched'] as List?) ?? const []).join(', ');
    final msg = failed.isNotEmpty
        ? (launched.isNotEmpty ? trf('Launched: {0} · Could not restore: {1}', [launched, failed]) : trf('Could not restore: {0}', [failed]))
        : launched.isNotEmpty
        ? trf('Launched: {0}', [launched])
        : tr('Action completed.');
    tellOn(this, msg);
    await load();
  }

  // --- saved preset actions ----------------------------------------------------------------

  Future<void> _saveCurrentPreset() async {
    final text = nameController.text.trim();
    if (text.isEmpty || busy) return;
    final exists = savedPresets.any((p) => '${p['name']}'.toLowerCase() == text.toLowerCase());
    if (exists &&
        !await _confirm(
          trf('Replace “{0}”?', [text]),
          tr('A preset with this name already exists.'),
          actionLabel: tr('Replace'),
        )) {
      return;
    }
    final r = await _runAction(
      'presets.saved_save',
      {'name': text, 'includeWorkspaces': includeWorkspaces && canSaveWorkspaces},
      done: trf('Saved preset “{0}”', [text]),
    );
    if (r != null && mounted) nameController.clear();
  }

  Future<void> _applySavedPreset(Map<String, dynamic> p) async {
    final ws = p['workspaces'] as Map?;
    if (ws != null) {
      final appKeys = ((ws['workspaceLayouts'] as Map?)?.keys ?? const []).map((k) => '$k').toList()..sort();
      final body = appKeys.isNotEmpty
          ? trf('Missing apps on workspaces {0} start; other windows there move to a free workspace.', [appKeys.join(', ')])
          : tr('This will overwrite your current workspace presets and apply the saved theme.');
      if (!await _confirm(trf('Apply “{0}”?', [p['name']]), body, actionLabel: tr('Apply'))) return;
    }
    await _runAction(
      'presets.saved_apply',
      {'name': p['name'], 'confirmed': ws != null},
      done: tr('Preset applied'),
      undoable: ws != null,
    );
  }

  Future<void> _assignSavedPreset(Map<String, dynamic> p) async {
    final hasTheme = themeName(p['theme'] as String?) != null;
    final options = <(String, String)>[
      ('theme', tr('Theme')),
      if (hasTheme && p['wallpaper'] != null) ('wallpaper', tr('Wallpaper')),
      if (hasTheme && p['wallpaper'] != null) ('both', tr('Theme + wallpaper')),
    ];
    var part = options.first.$1;
    final chosenWs = await showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(tr('Assign to workspace')),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButton<String>(
                  key: const ValueKey('presets-assign-part'),
                  isExpanded: true,
                  value: part,
                  items: [for (final (v, l) in options) DropdownMenuItem(value: v, child: Text(l))],
                  onChanged: (v) => update(() => part = v!),
                ),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 5,
                  shrinkWrap: true,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 1.5,
                  children: [
                    for (var w = 1; w <= 10; w++)
                      OutlinedButton(
                        key: ValueKey('presets-assign-ws-$w'),
                        style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: () => Navigator.pop(c, w),
                        child: Text('$w'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Cancel')))],
        ),
      ),
    );
    if (chosenWs == null || !mounted) return;
    await _runAction(
      'presets.saved_assign',
      {'name': p['name'], 'part': part, 'workspaces': [chosenWs]},
      done: trf('Workspace {0} assigned: {1}', [chosenWs, p['name']]),
    );
  }

  Future<void> _deleteSavedPreset(Map<String, dynamic> p) async {
    if (!await _confirm(
      trf('Delete preset “{0}”?', [p['name']]),
      tr('This removes the saved preset from the list.'),
      actionLabel: tr('Delete'),
      destructive: true,
    )) {
      return;
    }
    await _runAction(
      'presets.saved_delete',
      {'name': p['name']},
      done: trf('Deleted preset “{0}”', [p['name']]),
    );
  }

  // --- UI builders -------------------------------------------------------------------------

  List<Widget> _actions() => [
    if (busy)
      const Padding(
        padding: EdgeInsets.only(right: 8),
        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    if (canUndo)
      IconButton(
        key: const ValueKey('presets-undo'),
        tooltip: tr('Undo'),
        onPressed: busy ? null : _undo,
        icon: const Icon(Icons.undo),
      ),
    IconButton(
      key: const ValueKey('presets-reload'),
      tooltip: tr('Reload'),
      onPressed: busy ? null : load,
      icon: const Icon(Icons.refresh),
    ),
    TextButton(
      key: const ValueKey('presets-more'),
      onPressed: _openThemeApp,
      child: Text(tr('More in Maprisma Theme…')),
    ),
  ];

  Widget _problemCard(ServiceError e) {
    final missing = e.code == 'not_installed';
    return SettingsSection(
      children: [
        SettingsItem(
          leading: const Icon(Icons.view_quilt_outlined),
          title: missing
              ? tr('Maprisma Theme is not installed')
              : e.code == 'too_old'
              ? tr('Update Maprisma Theme to manage presets here')
              : failure(e),
          description: missing
              ? tr('Workspace presets, app presets and saved presets are managed here once Maprisma Theme is installed.')
              : null,
          trailing: missing
              ? OutlinedButton(
                  key: const ValueKey('presets-install'),
                  onPressed: widget.onShowApps,
                  child: Text(tr('Install it on the Apps page')),
                )
              : OutlinedButton(
                  key: const ValueKey('presets-retry'),
                  onPressed: load,
                  child: Text(tr('Try again')),
                ),
        ),
      ],
    );
  }

  Widget _tabSelector(int effectiveTab) {
    final segments = <ButtonSegment<int>>[
      if (hasWorkspaces) ButtonSegment(value: 0, icon: const Icon(Icons.grid_view, size: 16), label: Text(tr('Workspaces'))),
      if (hasAppPresets) ButtonSegment(value: 1, icon: const Icon(Icons.apps, size: 16), label: Text(tr('App Presets'))),
      ButtonSegment(value: 2, icon: const Icon(Icons.bookmarks_outlined, size: 16), label: Text(tr('Save/Load Presets'))),
    ];
    if (segments.length <= 1) return const SizedBox.shrink();
    return SegmentedButton<int>(
      key: const ValueKey('presets-tabs'),
      showSelectedIcon: false,
      segments: segments,
      selected: {effectiveTab},
      onSelectionChanged: (s) => setState(() {
        tab = s.first;
        conflict = null;
        _draftSplit = null;
        if (tab == 1 && selected == 0) selected = _groups[group].$1;
      }),
    );
  }

  Widget _workspaceSelector({required bool includeAll}) {
    final scheme = Theme.of(context).colorScheme;
    final c = cornerSizes(context);
    final ids = [
      if (includeAll) 0,
      for (var ws = _groups[group].$1; ws <= _groups[group].$2; ws++) ws,
    ];
    final cur = currentWs();

    return SettingsSection(
      title: tr('Workspace'),
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<int>(
                key: const ValueKey('presets-ws-group'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 0, label: Text(tr('Workspaces 1–5'))),
                  ButtonSegment(value: 1, label: Text(tr('Workspaces 6–10'))),
                ],
                selected: {group},
                onSelectionChanged: (s) => setState(() {
                  group = s.first;
                  if (selected > 0 && (selected < _groups[group].$1 || selected > _groups[group].$2)) {
                    selected = _groups[group].$1;
                    conflict = null;
                    _draftSplit = null;
                  }
                }),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, box) {
                  const gap = 8.0;
                  final cols = box.maxWidth >= 540 ? 3 : 2;
                  final cardW = ((box.maxWidth - gap * (cols - 1)) / cols).floorToDouble();
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final ws in ids)
                        SizedBox(
                          width: cardW,
                          child: _workspaceCard(ws, selected: ws == cur, scheme: scheme, c: c),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _workspaceCard(int ws, {required bool selected, required ColorScheme scheme, required Corners c}) {
    final active = ws > 0 && ws == activeWorkspace;
    final key = layoutKeyOf(ws);
    final dashed = key == 'none' || key == 'default';
    final List<Rect> rects;
    if (tab == 1) {
      final apps = appsOf(ws);
      rects = presetRects(key == 'floating' ? 'floating' : 'tiled', apps.length);
    } else {
      rects = presetRects(key, limitOf(ws), split: hasSplits ? splitOf(ws) : null);
    }

    return Material(
      color: selected ? scheme.surfaceContainerHighest : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(c.control),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('presets-ws-$ws'),
        onTap: () => setState(() {
          this.selected = ws;
          conflict = null;
          _draftSplit = null;
          if (ws > 0) group = groupOf(ws);
        }),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(c.control),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      wsTitle(ws),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: active ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                  ),
                  if (active) Icon(Icons.circle, size: 7, color: scheme.primary),
                ],
              ),
              if (hasTiling) ...[
                const SizedBox(height: 6),
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        painter: _PresetLayoutPainter(
                          fg: scheme.onSurface,
                          accent: scheme.primary,
                          rects: rects,
                          dashed: dashed && tab == 0,
                          deck: ws == 0,
                        ),
                      ),
                      if (rects.isEmpty)
                        Center(child: Text('—', style: TextStyle(color: scheme.onSurfaceVariant))),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                wsSummary(ws),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _limitButtons(int ws, int currentCap) {
    final scheme = Theme.of(context).colorScheme;
    final c = cornerSizes(context);
    return Row(
      children: [
        for (var n = 1; n <= 4; n++) ...[
          if (n > 1) const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              key: ValueKey('presets-limit-$n'),
              onPressed: busy ? null : () => _setLimit(ws, n),
              style: OutlinedButton.styleFrom(
                foregroundColor: currentCap == n ? scheme.onPrimary : scheme.onSurface,
                backgroundColor: currentCap == n ? scheme.primary : null,
                side: BorderSide(color: currentCap == n ? scheme.primary : scheme.outlineVariant),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(c.control)),
              ),
              child: Text('$n'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _presetGrid(int ws, int cap, String? ownChosen) {
    final scheme = Theme.of(context).colorScheme;
    final c = cornerSizes(context);
    final tilingPresets = ['side-by-side', 'stacked', 'master-left', 'master-right', 'columns', 'grid'];
    final freeAndNative = ['floating', 'scrolling', 'none'];
    final effective = presetOf(ws);
    final split = hasSplits ? splitOf(ws) : null;

    Widget tile(String preset) {
      final compatible = isPresetCompatibleWithCap(preset, cap);
      final chosen = ownChosen == preset;
      final inherited = ownChosen == null && effective == preset;
      final isDashed = preset == 'none';
      final previewCount = preset == 'grid'
          ? 4
          : (preset == 'master-left' || preset == 'master-right' || preset == 'columns')
          ? math.max(cap, 3)
          : math.max(cap, 2);

      return Opacity(
        opacity: compatible ? 1.0 : 0.42,
        child: Material(
          color: chosen
              ? scheme.surfaceContainerHighest
              : inherited
              ? scheme.surfaceContainerHigh
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(c.control),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('presets-preset-$preset'),
            onTap: busy || !compatible ? null : () => _pickPreset(ws, preset),
            child: Container(
              width: 112,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(c.control),
                border: Border.all(
                  color: chosen
                      ? scheme.primary
                      : inherited
                      ? scheme.primary.withValues(alpha: 0.45)
                      : scheme.outlineVariant,
                  width: chosen ? 1.5 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CustomPaint(
                      painter: _PresetLayoutPainter(
                        fg: scheme.onSurface,
                        accent: scheme.primary,
                        rects: presetRects(preset, previewCount, split: chosen || inherited ? split : null),
                        dashed: isDashed,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    presetLabel(preset),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: chosen ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Tiling layouts'), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final p in tilingPresets) tile(p)]),
        const SizedBox(height: 12),
        Text(tr('Free & native modes'), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final p in freeAndNative) tile(p)]),
      ],
    );
  }

  Widget _modeGrid(int ws, int cap, String? ownChosen) {
    final scheme = Theme.of(context).colorScheme;
    final c = cornerSizes(context);
    final effective = modeOf(ws);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final mode in desktopModeNames)
          Material(
            color: ownChosen == mode
                ? scheme.surfaceContainerHighest
                : ownChosen == null && effective == mode
                ? scheme.surfaceContainerHigh
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(c.control),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('presets-mode-$mode'),
              onTap: busy ? null : () => _pickMode(ws, mode),
              child: Container(
                width: 124,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(c.control),
                  border: Border.all(
                    color: ownChosen == mode
                        ? scheme.primary
                        : ownChosen == null && effective == mode
                        ? scheme.primary.withValues(alpha: 0.45)
                        : scheme.outlineVariant,
                    width: ownChosen == mode ? 1.5 : 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: CustomPaint(
                        painter: _PresetLayoutPainter(
                          fg: scheme.onSurface,
                          accent: scheme.primary,
                          rects: presetRects(mode, mode == 'default' ? math.max(cap, 3) : cap),
                          dashed: mode == 'default',
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      presetLabel(mode),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: ownChosen == mode ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _splitSection(int ws, String preset, int cap) {
    final (minSplit, maxSplit) = presetSplitRange(preset);
    final evenDefault = preset == 'columns' ? 0.33 : 0.50;
    final current = (_draftSplit ?? splitOf(ws) ?? evenDefault).clamp(minSplit, maxSplit);
    final pct = (current * 100).round();

    return SettingsSection(
      title: tr('Split ratio'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Slider(
                  key: const ValueKey('presets-split-slider'),
                  value: current,
                  min: minSplit,
                  max: maxSplit,
                  divisions: ((maxSplit - minSplit) * 100).round(),
                  label: '$pct %',
                  onChanged: busy ? null : (v) => setState(() => _draftSplit = (v * 100).round() / 100),
                  onChangeEnd: busy
                      ? null
                      : (v) {
                          final rounded = (v * 100).round() / 100;
                          setState(() => _draftSplit = null);
                          unawaited(_setSplit(ws, rounded));
                        },
                ),
              ),
              SizedBox(
                width: 48,
                child: Text('$pct %', textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodyMedium),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const ValueKey('presets-split-even'),
                onPressed: busy ? null : () => _setSplit(ws, null),
                child: Text(tr('Even split')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _workspacesTab() {
    final ws = selected;
    final cap = limitOf(ws);
    final effectiveP = presetOf(ws);
    final scheme = Theme.of(context).colorScheme;

    return [
      if (can('windows') && hasTiling)
        SettingsSection(
          children: [
            SettingsToggle(
              key: const ValueKey('presets-tiling-active'),
              title: tr('Tiling active'),
              description: tr('Window limits with overflow to the next workspace with room'),
              value: wsState['active'] == true,
              onChanged: busy
                  ? null
                  : (v) => _runAction(
                        'presets.set',
                        {'active': v, 'apply': true},
                        done: v ? tr('Tiling active') : tr('Tiling off'),
                        undoable: true,
                      ),
            ),
          ],
        ),
      _workspaceSelector(includeAll: true),
      if (ws == 0) ...[
        if (can('windows'))
          SettingsSection(
            title: tr('Default window limit (all workspaces)'),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: _limitButtons(0, globalCap),
              ),
            ],
          ),
        if (hasTiling)
          SettingsSection(
            title: tr('Default layout preset'),
            note: trf('For {0} on workspaces without a layout of their own. Click again to remove it.', [windowsLabel(globalCap)]),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: hasPresetLayouts
                    ? _presetGrid(0, globalCap, defaultPresets['$globalCap'] as String?)
                    : _modeGrid(0, globalCap, defaultModes['$globalCap'] as String?),
              ),
            ],
          ),
        if (hasSplits && hasPresetLayouts && presetHasSplit(effectiveP, globalCap)) _splitSection(0, effectiveP, globalCap),
        if (hasTiling && can('windows'))
          SettingsSection(
            title: tr('Preset & App Preset management (all workspaces)'),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('presets-bulk-reset'),
                      onPressed: busy
                          ? null
                          : () => _runAction(
                                'presets.bulk',
                                {'action': 'reset_all'},
                                done: tr('All workspaces reset to the default'),
                                undoable: true,
                              ),
                      icon: const Icon(Icons.undo, size: 16),
                      label: Text(tr('Reset All to Default')),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('presets-bulk-remove'),
                      onPressed: busy
                          ? null
                          : () => _runAction(
                                'presets.bulk',
                                {'action': 'remove_all'},
                                done: tr('All workspaces Native'),
                                undoable: true,
                              ),
                      icon: const Icon(Icons.layers_clear_outlined, size: 16),
                      label: Text(tr('Remove All Presets')),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('presets-bulk-clear'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                        side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
                      ),
                      onPressed: busy
                          ? null
                          : () async {
                              if (await _confirm(
                                tr('Clear All Presets & App Presets?'),
                                tr('Clear all workspace layouts, limits, saved apps and autostart settings.'),
                                actionLabel: tr('Delete'),
                                destructive: true,
                              )) {
                                await _runAction('presets.reset', const {}, done: tr('Everything cleared'), undoable: true);
                              }
                            },
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: Text(tr('Clear All Presets & App Presets')),
                    ),
                  ],
                ),
              ),
            ],
          ),
      ] else ...[
        if (can('windows'))
          SettingsSection(
            title: trf('Window limit · Workspace {0}', [ws]),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _limitButtons(ws, cap),
                    if (wsCaps.containsKey('$ws')) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        key: const ValueKey('presets-limit-reset'),
                        onPressed: busy
                            ? null
                            : () => _runAction(
                                  'presets.set',
                                  {'workspace': ws, 'limit': null, 'apply': true},
                                  done: trf('Workspace {0}: default limit', [ws]),
                                  undoable: true,
                                ),
                        icon: const Icon(Icons.undo, size: 16),
                        label: Text(trf('Reset Limit to Default ({0})', [globalCap])),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        if (hasTiling)
          SettingsSection(
            title: trf('Layout preset · Workspace {0}', [ws]),
            note: (hasPresetLayouts ? wsPresets['$ws'] : wsModes['$ws']) != null
                ? tr('Click the selected layout again or reset to use the default.')
                : trf('Uses the default for {0}: {1}.', [windowsLabel(cap), presetLabel(layoutKeyOf(ws))]),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasPresetLayouts)
                      _presetGrid(ws, cap, wsPresets['$ws'] as String?)
                    else
                      _modeGrid(ws, cap, wsModes['$ws'] as String?),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const ValueKey('presets-ws-reset'),
                      onPressed: busy
                          ? null
                          : () => _runAction(
                                'presets.set',
                                {
                                  'workspace': ws,
                                  if (hasPresetLayouts) 'preset': null,
                                  'mode': null,
                                  if (can('windows')) 'limit': null,
                                  if (hasSplits) 'split': null,
                                  'apply': true,
                                },
                                done: trf('Workspace {0} reset to the default', [ws]),
                                undoable: true,
                              ),
                      icon: const Icon(Icons.undo, size: 16),
                      label: Text(tr('Reset Workspace to Default')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        if (hasSplits && hasPresetLayouts && presetHasSplit(effectiveP, cap)) _splitSection(ws, effectiveP, cap),
      ],
    ];
  }

  Widget _conflictCard(int ws) {
    final scheme = Theme.of(context).colorScheme;
    final c = cornerSizes(context);
    return Container(
      key: const ValueKey('presets-conflict'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(c.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            trf('Workspace {0} has {1} open window(s) not in this preset.', [ws, conflict!['conflict_count']]),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            tr('How would you like to handle them before restoring?'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                key: const ValueKey('presets-conflict-move'),
                onPressed: busy ? null : () => _restoreApps(ws, 'move'),
                child: Text(tr('Move Conflicting Windows')),
              ),
              OutlinedButton(
                key: const ValueKey('presets-conflict-close'),
                onPressed: busy ? null : () => _restoreApps(ws, 'close'),
                child: Text(tr('Close')),
              ),
              OutlinedButton(
                key: const ValueKey('presets-conflict-keep'),
                onPressed: busy ? null : () => _restoreApps(ws, 'keep'),
                child: Text(tr('Keep')),
              ),
              TextButton(
                key: const ValueKey('presets-conflict-cancel'),
                onPressed: () => setState(() => conflict = null),
                child: Text(tr('Cancel')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _appPresetsTab() {
    final ws = currentWs();
    final layout = wsLayouts['$ws'] as Map?;
    final apps = appsOf(ws);
    final scheme = Theme.of(context).colorScheme;

    return [
      _workspaceSelector(includeAll: false),
      SettingsSection(
        title: layout == null
            ? trf('Workspace {0} · No App Preset saved yet', [ws])
            : trf('App Preset · Workspace {0}', [ws]),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (apps.isNotEmpty) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < apps.length; i++)
                        InputChip(
                          key: ValueKey('presets-app-chip-$i'),
                          avatar: const Icon(Icons.apps, size: 16),
                          label: Text(apps[i].replaceAll(RegExp(r'\.desktop$'), '')),
                          deleteButtonTooltipMessage: trf('Remove {0} from the App Preset', [apps[i]]),
                          deleteIcon: Icon(Icons.close, key: ValueKey('presets-app-remove-$i'), size: 16),
                          onDeleted: busy
                              ? null
                              : () => _runAction(
                                    'presets.app_remove',
                                    {'workspace': ws, 'index': i},
                                    done: trf('Removed {0} from the App Preset', [apps[i]]),
                                    undoable: true,
                                  ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                if (conflict != null && conflict!['workspace'] == ws) ...[
                  _conflictCard(ws),
                  const SizedBox(height: 12),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('presets-app-save'),
                      onPressed: busy
                          ? null
                          : () => _runAction(
                                'presets.app_save',
                                {'workspace': ws},
                                done: trf('Saved App Preset for Workspace {0}', [ws]),
                                undoable: true,
                              ),
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: Text(tr('Save App Preset')),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('presets-app-add'),
                      onPressed: busy ? null : () => _addApp(ws),
                      icon: const Icon(Icons.add, size: 16),
                      label: Text(tr('Add app…')),
                    ),
                    if (apps.isNotEmpty)
                      OutlinedButton.icon(
                        key: const ValueKey('presets-app-restore'),
                        onPressed: busy ? null : () => _restoreApps(ws),
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: Text(tr('Restore App Preset')),
                      ),
                    if (layout != null)
                      OutlinedButton.icon(
                        key: const ValueKey('presets-app-remove-ws'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.error,
                          side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
                        ),
                        onPressed: busy
                            ? null
                            : () => _runAction(
                                  'presets.app_remove',
                                  {'workspace': ws},
                                  done: trf('Removed the App Preset of Workspace {0}', [ws]),
                                  undoable: true,
                                ),
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: Text(tr('Remove App Preset')),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (layout != null)
            SettingsToggle(
              key: const ValueKey('presets-app-autostart'),
              title: tr('Autostart on session startup'),
              description: tr('Automatically launch saved apps on startup'),
              value: layout['autostart'] == true,
              onChanged: busy
                  ? null
                  : (v) => _runAction(
                        'presets.app_autostart',
                        {'workspace': ws, 'enabled': v},
                        done: v ? trf('Autostart on for Workspace {0}', [ws]) : trf('Autostart off for Workspace {0}', [ws]),
                        undoable: true,
                      ),
            ),
        ],
      ),
      SettingsSection(
        title: tr('Restore & cleanup'),
        children: [
          SettingsToggle(
            key: const ValueKey('presets-auto-move'),
            title: tr('Auto-move on restore'),
            description: tr('Move existing windows to next free workspace without asking'),
            value: wsState['autoMoveOnRestore'] == true,
            onChanged: busy
                ? null
                : (v) => _runAction(
                      'presets.set',
                      {'autoMoveOnRestore': v},
                      done: v ? tr('Auto-move on restore on') : tr('Auto-move on restore off'),
                      undoable: true,
                    ),
          ),
          SettingsItem(
            title: tr('Remove All App Presets'),
            description: tr('Deletes all saved app presets and autostart settings across all workspaces.'),
            trailing: OutlinedButton.icon(
              key: const ValueKey('presets-app-remove-all'),
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
              ),
              onPressed: busy
                  ? null
                  : () async {
                      if (await _confirm(
                        tr('Remove All App Presets?'),
                        tr('Deletes all saved app presets and autostart settings across all workspaces.'),
                        actionLabel: tr('Delete'),
                        destructive: true,
                      )) {
                        await _runAction('presets.app_remove_all', const {}, done: tr('All App Presets removed'), undoable: true);
                      }
                    },
              icon: const Icon(Icons.delete_outline, size: 16),
              label: Text(tr('Remove All App Presets')),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _savedPresetsTab() {
    final scheme = Theme.of(context).colorScheme;
    final list = savedPresets;

    return [
      if (!hasWorkspaces)
        SettingsSection(
          children: [
            SettingsItem(
              leading: const Icon(Icons.info_outline),
              title: trf('Workspaces are not available on {0} yet.', [desktopName]),
              description: tr('You can still save and apply theme, wallpaper and font presets here.'),
            ),
          ],
        ),
      SettingsSection(
        title: tr('Save current preset'),
        note: tr('Save the current theme, wallpaper and font for later.'),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('presets-save-name'),
                        controller: nameController,
                        maxLength: 60,
                        decoration: InputDecoration(hintText: tr('Preset name'), counterText: ''),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _saveCurrentPreset(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      key: const ValueKey('presets-save-button'),
                      onPressed: busy || nameController.text.trim().isEmpty ? null : _saveCurrentPreset,
                      child: Text(tr('Save current')),
                    ),
                  ],
                ),
                if (canSaveWorkspaces) ...[
                  const SizedBox(height: 6),
                  CheckboxListTile(
                    key: const ValueKey('presets-save-include'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(tr('Include workspace presets and app presets')),
                    value: includeWorkspaces,
                    onChanged: busy ? null : (v) => setState(() => includeWorkspaces = v ?? false),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      SettingsSection(
        title: tr('Saved presets'),
        children: [
          if (list.isEmpty)
            SettingsItem(title: tr('No presets yet.'))
          else
            for (final p in list) _savedPresetItem(p, scheme),
        ],
      ),
    ];
  }

  Widget _savedPresetItem(Map<String, dynamic> p, ColorScheme scheme) {
    final name = '${p['name']}';
    final tName = themeName(p['theme'] as String?);
    final ws = p['workspaces'] as Map?;
    final canApply = ws == null || canSaveWorkspaces;
    final layoutCount = ws == null
        ? 0
        : {
            ...(ws['workspaceCaps'] as Map? ?? const {}).keys,
            ...(ws['workspaceModes'] as Map? ?? const {}).keys,
            ...(ws['workspacePresets'] as Map? ?? const {}).keys,
          }.length;
    final appCount = (ws?['workspaceLayouts'] as Map? ?? const {}).length;

    final parts = [
      tName ?? tr('Theme missing'),
      p['wallpaper'] ?? tr('No wallpaper'),
      p['font'] ?? tr('No font'),
    ].join(' · ');
    final detail = [
      parts,
      if (hasWorkspaces && ws != null) trf('Workspace presets: {0} · App presets: {1}', [layoutCount, appCount]),
      if (!canApply) trf('This preset needs workspace features unavailable on {0}.', [desktopName]),
    ].join('\n');

    return SettingsItem(
      key: ValueKey('presets-saved-$name'),
      title: name,
      description: detail,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canApply)
            OutlinedButton(
              key: ValueKey('presets-saved-apply-$name'),
              onPressed: busy || tName == null ? null : () => _applySavedPreset(p),
              child: Text(tr('Apply')),
            ),
          if (hasWorkspaces)
            IconButton(
              key: ValueKey('presets-saved-assign-$name'),
              tooltip: tr('Assign theme and/or wallpaper to workspace'),
              icon: const Icon(Icons.grid_view),
              onPressed: busy || tName == null ? null : () => _assignSavedPreset(p),
            ),
          IconButton(
            key: ValueKey('presets-saved-delete-$name'),
            tooltip: tr('Delete preset'),
            icon: Icon(Icons.delete_outline, color: scheme.error),
            onPressed: busy ? null : () => _deleteSavedPreset(p),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final e = problem;
    if (d == null) {
      return SettingsPage(
        title: tr('Presets'),
        actions: e == null || e.code == 'not_installed' ? const [] : _actions(),
        children: [
          e != null
              ? _problemCard(e)
              : const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
        ],
      );
    }

    final effectiveTab = !hasWorkspaces || (tab == 1 && !hasAppPresets) ? 2 : tab;
    return SettingsPage(
      title: tr('Presets'),
      actions: _actions(),
      children: [
        if (hasWorkspaces) _tabSelector(effectiveTab),
        if (effectiveTab == 0) ..._workspacesTab(),
        if (effectiveTab == 1) ..._appPresetsTab(),
        if (effectiveTab == 2) ..._savedPresetsTab(),
      ],
    );
  }
}

/// Draws a miniature monitor showing the normalized layout rectangles of a preset or workspace.
class _PresetLayoutPainter extends CustomPainter {
  const _PresetLayoutPainter({
    required this.fg,
    required this.accent,
    required this.rects,
    this.dashed = false,
    this.deck = false,
  });

  final Color fg;
  final Color accent;
  final List<Rect> rects;
  final bool dashed;
  final bool deck;

  @override
  void paint(Canvas canvas, Size size) {
    var width = size.width;
    var height = size.height;
    if (deck) {
      final off = math.max(3.0, height * 0.08);
      for (final (step, alpha) in [(2, 0.35), (1, 0.6)]) {
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(0.5 + step * off, 0.5, width - 1 - 2 * off, height - 1 - 2 * off),
          const Radius.circular(4),
        );
        canvas.drawRRect(r, Paint()..color = accent.withValues(alpha: 0.10 * alpha));
        canvas.drawRRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = accent.withValues(alpha: alpha),
        );
      }
      canvas.translate(0, 2 * off);
      width -= 2 * off;
      height -= 2 * off;
    }

    final screen = RRect.fromRectAndRadius(Rect.fromLTWH(0.5, 0.5, width - 1, height - 1), const Radius.circular(4));
    canvas.drawRRect(screen, Paint()..color = fg.withValues(alpha: 0.06));
    canvas.drawRRect(
      screen,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = fg.withValues(alpha: 0.25),
    );

    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Rect.fromLTWH(1, 1, width - 2, height - 2), const Radius.circular(3)));
    for (final r in rects) {
      final box = RRect.fromRectAndRadius(
        Rect.fromLTWH(r.left * width, r.top * height, r.width * width, r.height * height),
        const Radius.circular(2.5),
      );
      if (dashed) {
        _drawDashedRRect(
          canvas,
          box,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = fg.withValues(alpha: 0.48),
        );
      } else {
        canvas.drawRRect(box, Paint()..color = accent.withValues(alpha: 0.42));
        canvas.drawRRect(
          box,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = accent.withValues(alpha: 0.9),
        );
      }
    }
    canvas.restore();
  }

  void _drawDashedRRect(Canvas canvas, RRect rrect, Paint paint) {
    final path = Path()..addRRect(rrect);
    const dash = 3.0;
    const gap = 2.0;
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final end = math.min(dist + dash, metric.length);
        canvas.drawPath(metric.extractPath(dist, end), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PresetLayoutPainter old) =>
      old.fg != fg ||
      old.accent != accent ||
      old.dashed != dashed ||
      old.deck != deck ||
      old.rects.length != rects.length ||
      old.rects.toString() != rects.toString();
}
