/// User-local (private) app entries loaded from `$XDG_CONFIG_HOME/maprisma-settings/local-apps.json`.
///
/// Kept outside the public catalog so private repos and machine-specific apps stay local while
/// getting the same install/update/bar-icon integration as built-in apps.
library;

import 'dart:convert';
import 'dart:io';

import 'catalog.dart';
import 'paths.dart';

const _maxLocalAppsBytes = 256 * 1024;
final _validId = RegExp(r'^[a-z][a-z0-9_-]{0,47}$');
final _validRepo = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final _validSlug = RegExp(r'^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$');
final _validAppId = RegExp(r'^[A-Za-z0-9._-]+$');

/// Loads valid local app definitions from [paths.localAppsFile].
///
/// Missing, unreadable, oversized, or malformed files return an empty list without throwing so
/// core startup never breaks. Entries whose id collides with a built-in app (or an earlier local
/// entry) are skipped.
List<AppEntry> loadLocalCatalog(Paths paths, {void Function(String message)? onWarning}) {
  final file = File(paths.localAppsFile);
  if (!file.existsSync()) return const [];
  String raw;
  try {
    if (file.lengthSync() > _maxLocalAppsBytes) {
      onWarning?.call('local-apps.json exceeds $_maxLocalAppsBytes bytes and was ignored');
      return const [];
    }
    raw = file.readAsStringSync();
  } on FileSystemException catch (e) {
    onWarning?.call('local-apps.json could not be read: ${e.message}');
    return const [];
  }

  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    onWarning?.call('local-apps.json is not valid JSON: ${e.message}');
    return const [];
  }

  final List<Object?> items;
  if (decoded is List) {
    items = decoded;
  } else if (decoded is Map && decoded['apps'] is List) {
    items = decoded['apps'] as List;
  } else {
    onWarning?.call('local-apps.json must be a JSON array or {"apps": [...]}');
    return const [];
  }

  final reservedIds = <String>{
    selfApp,
    legacySelfAppId,
    ...appIdAliases.keys,
    for (final a in builtinCatalog) a.id,
  };
  final out = <AppEntry>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map) {
      onWarning?.call('local-apps.json[$i]: expected an object');
      continue;
    }
    try {
      final entry = parseLocalAppEntry(item.cast<String, dynamic>(), paths);
      if (!reservedIds.add(entry.id)) {
        onWarning?.call('local-apps.json[$i]: duplicate or reserved id "${entry.id}" skipped');
        continue;
      }
      out.add(entry);
    } on FormatException catch (e) {
      onWarning?.call('local-apps.json[$i]: ${e.message}');
    }
  }
  return out;
}

/// Parses one JSON object into an [AppEntry], validating templates against [paths].
AppEntry parseLocalAppEntry(Map<String, dynamic> map, Paths paths) {
  final id = _reqString(map, 'id');
  if (!_validId.hasMatch(id)) {
    throw FormatException('invalid id "$id"');
  }
  final name = _reqString(map, 'name');
  final repo = _reqString(map, 'repo');
  if (!_validRepo.hasMatch(repo)) {
    throw FormatException('invalid repo "$repo"');
  }
  final github = _optString(map, 'github');
  if (github != null && !_validSlug.hasMatch(github)) {
    throw FormatException('invalid github slug "$github"');
  }

  final preset = _optString(map, 'preset');
  final AppEntry entry;
  switch (preset) {
    case 'rust_applet':
      entry = _parseRustApplet(map, id: id, name: name, repo: repo, github: github);
    case 'rust_standalone':
      entry = _parseRustStandalone(map, id: id, name: name, repo: repo, github: github);
    case null || '' || 'custom':
      entry = _parseCustom(map, id: id, name: name, repo: repo, github: github);
    default:
      throw FormatException('unknown preset "$preset"');
  }
  _validateTemplates(entry, paths);
  return entry;
}

AppEntry _parseRustApplet(
  Map<String, dynamic> map, {
  required String id,
  required String name,
  required String repo,
  required String? github,
}) {
  final suffix = _reqString(map, 'suffix');
  if (!_validAppId.hasMatch(suffix)) throw FormatException('invalid suffix "$suffix"');
  final binary = _reqString(map, 'binary');
  if (!_validRepo.hasMatch(binary)) throw FormatException('invalid binary "$binary"');
  final scripts = _stringList(map['scripts']);
  final morePaths = _parseInstalledPaths(map['morePaths']);
  final data = _parseDataPaths(map['data']);
  final runtime = _parseRuntimePaths(map['runtime']);
  final units = _parseUnits(map['units']);
  final moreProcesses = _parseProcesses(map['moreProcesses']);
  final desktops = _parseDesktops(map['desktops']);

  return buildRustAppletEntry(
    id: id,
    name: name,
    repo: repo,
    suffix: suffix,
    binary: binary,
    scripts: scripts,
    github: github,
    appIcon: _optString(map, 'appIcon'),
    morePaths: morePaths,
    data: data,
    runtime: runtime,
    units: units,
    iconNote: _optString(map, 'iconNote'),
    cosmicIconBuiltIn: map['cosmicIconBuiltIn'] == true,
    desktops: desktops,
    moreProcesses: moreProcesses,
    note: _optString(map, 'note'),
  );
}

AppEntry _parseRustStandalone(
  Map<String, dynamic> map, {
  required String id,
  required String name,
  required String repo,
  required String? github,
}) {
  final binary = _reqString(map, 'binary');
  if (!_validRepo.hasMatch(binary)) throw FormatException('invalid binary "$binary"');
  final appId = _reqString(map, 'appId');
  if (!_validAppId.hasMatch(appId)) throw FormatException('invalid appId "$appId"');
  final hasTray = map['hasTray'] != false;
  final trayBinary = _optString(map, 'trayBinary') ?? '$binary-tray';
  if (hasTray && !_validRepo.hasMatch(trayBinary)) {
    throw FormatException('invalid trayBinary "$trayBinary"');
  }
  final kdeId = _optString(map, 'kdeId') ?? binary;
  final iconName = _optString(map, 'iconName') ?? '$appId-symbolic';
  final appIcon = _optString(map, 'appIcon') ?? iconName;
  final open = _stringList(map['open'], fallback: ['{bin}/$binary']);
  final install = _stringList(map['install'], fallback: const ['./install.sh']);
  final desktops = _parseDesktops(map['desktops']);
  final morePaths = _parseInstalledPaths(map['morePaths']);
  final data = _parseDataPaths(map['data']);
  final runtime = _parseRuntimePaths(map['runtime']);
  final units = _parseUnits(map['units']);
  final moreProcesses = _parseProcesses(map['moreProcesses']);
  final postSteps = _stringList(map['postSteps'], fallback: const ['gtk-update-icon-cache', 'update-desktop-database']);
  final prereqs = map.containsKey('prerequisites')
      ? _parsePrerequisites(map['prerequisites'])
      : const [
          Prerequisite('cargo'),
          Prerequisite('gtk-update-icon-cache', optional: true),
          Prerequisite('update-desktop-database', optional: true),
        ];

  return AppEntry(
    id: id,
    name: name,
    kind: _optString(map, 'kind') ?? 'rust',
    appIcon: appIcon,
    desktops: desktops,
    open: open,
    inputs: [Input(repo, github: github)],
    components: [
      Component(
        id: 'main',
        name: name,
        repo: repo,
        install: install,
        prerequisites: prereqs,
        paths: [
          InstalledPath('{bin}/$binary', PathKind.executable, key: true),
          if (hasTray) InstalledPath('{bin}/$trayBinary', PathKind.executable),
          InstalledPath('{icons}/$iconName.svg', PathKind.file),
          InstalledPath('{apps}/$appId.desktop', PathKind.file),
          if (hasTray) InstalledPath('{autostart}/$appId.Tray.desktop', PathKind.file),
          ...morePaths,
        ],
      ),
    ],
    data: data,
    runtime: runtime,
    units: units,
    processes: [
      ProcessMatch(MatchKind.exe, '{bin}/$binary'),
      if (hasTray) ProcessMatch(MatchKind.exe, '{bin}/$trayBinary'),
      ...moreProcesses,
    ],
    bar: hasTray
        ? BarIcon(
            kdeId: kdeId,
            kdeAutostart: '{autostart}/$appId.Tray.desktop',
            kdeTrayExe: '{bin}/$trayBinary',
            iconName: iconName,
            kdeIconName: _optString(map, 'kdeIconName'),
            iconNote: _optString(map, 'iconNote'),
          )
        : const BarIcon(),
    postSteps: postSteps,
    note: _optString(map, 'note'),
  );
}

AppEntry _parseCustom(
  Map<String, dynamic> map, {
  required String id,
  required String name,
  required String repo,
  required String? github,
}) {
  final rawPaths = _parseInstalledPaths(map['paths']);
  if (rawPaths.isEmpty) throw const FormatException('custom entry requires at least one item in "paths"');
  final hasKey = rawPaths.any((ip) => ip.key);
  final paths = hasKey
      ? rawPaths
      : [
          InstalledPath(rawPaths.first.path, rawPaths.first.kind,
              target: rawPaths.first.target, part: rawPaths.first.part, key: true, note: rawPaths.first.note),
          ...rawPaths.skip(1),
        ];
  if (paths.where((ip) => ip.key).length != 1) {
    throw const FormatException('custom entry must have exactly one key path');
  }
  final install = _stringList(map['install'], fallback: const ['./install.sh']);
  if (install.isEmpty) throw const FormatException('"install" command must not be empty');
  final open = _stringList(map['open']);
  final desktops = _parseDesktops(map['desktops']);
  final prereqs = _parsePrerequisites(map['prerequisites']);
  final data = _parseDataPaths(map['data']);
  final runtime = _parseRuntimePaths(map['runtime']);
  final units = _parseUnits(map['units']);
  final processes = _parseProcesses(map['processes']);
  final bar = _parseBarIcon(map['bar']);
  final postSteps = _stringList(map['postSteps']);

  return AppEntry(
    id: id,
    name: name,
    kind: _optString(map, 'kind') ?? 'rust',
    appIcon: _optString(map, 'appIcon'),
    desktops: desktops,
    open: open,
    inputs: [Input(repo, github: github)],
    components: [
      Component(
        id: 'main',
        name: name,
        repo: repo,
        install: install,
        prerequisites: prereqs,
        paths: paths,
      ),
    ],
    data: data,
    runtime: runtime,
    units: units,
    processes: processes,
    bar: bar,
    postSteps: postSteps,
    note: _optString(map, 'note'),
  );
}

void _validateTemplates(AppEntry a, Paths paths) {
  final templates = <String>[
    for (final c in a.components) ...[
      for (final ip in c.paths) ip.path,
      for (final ip in c.paths) ?ip.target,
    ],
    for (final d in a.data) d.path,
    for (final r in a.runtime) r.path,
    for (final u in a.units) u.fileTemplate,
    for (final m in a.processes) m.path,
    ?a.bar.cosmicAppletExe,
    ?a.bar.kdeAutostart,
    ?a.bar.kdeTrayExe,
    for (final arg in a.open ?? const <String>[])
      if (arg.contains('{')) arg,
  ];
  for (final t in templates) {
    try {
      paths.expand(t);
    } on ArgumentError catch (e) {
      throw FormatException('invalid path template "$t": ${e.message}');
    }
  }
}

String _reqString(Map<String, dynamic> map, String key) {
  final v = map[key];
  if (v is! String || v.trim().isEmpty) throw FormatException('missing "$key"');
  return v.trim();
}

String? _optString(Map<String, dynamic> map, String key) {
  final v = map[key];
  if (v == null) return null;
  if (v is! String) throw FormatException('"$key" must be a string');
  final t = v.trim();
  return t.isEmpty ? null : t;
}

List<String> _stringList(Object? raw, {List<String> fallback = const []}) {
  if (raw == null) return fallback;
  if (raw is! List) throw const FormatException('expected a list of strings');
  return [
    for (final e in raw)
      if (e is String) e else throw const FormatException('expected a string element'),
  ];
}

Set<DesktopId> _parseDesktops(Object? raw) {
  if (raw == null) return const {DesktopId.cosmic, DesktopId.kde, DesktopId.hyprland, DesktopId.other};
  final list = _stringList(raw);
  if (list.isEmpty) throw const FormatException('"desktops" must not be empty');
  final out = <DesktopId>{};
  for (final d in list) {
    switch (d.toLowerCase()) {
      case 'cosmic':
        out.add(DesktopId.cosmic);
      case 'kde':
        out.add(DesktopId.kde);
      case 'hyprland':
        out.add(DesktopId.hyprland);
      case 'other':
        out.add(DesktopId.other);
      default:
        throw FormatException('unknown desktop "$d"');
    }
  }
  return out;
}

List<InstalledPath> _parseInstalledPaths(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) throw const FormatException('expected a list of paths');
  return [
    for (final e in raw)
      if (e is String)
        InstalledPath(e, PathKind.file)
      else if (e is Map)
        _parseOneInstalledPath(e.cast<String, dynamic>())
      else
        throw const FormatException('path entry must be a string or object'),
  ];
}

InstalledPath _parseOneInstalledPath(Map<String, dynamic> m) {
  final path = _reqString(m, 'path');
  final kindName = (_optString(m, 'kind') ?? 'file').toLowerCase();
  final kind = switch (kindName) {
    'file' => PathKind.file,
    'executable' => PathKind.executable,
    'dir' => PathKind.dir,
    'link' => PathKind.link,
    _ => throw FormatException('unknown path kind "$kindName"'),
  };
  return InstalledPath(
    path,
    kind,
    target: _optString(m, 'target'),
    part: _optString(m, 'part') ?? 'main',
    key: m['key'] == true,
    note: _optString(m, 'note'),
  );
}

List<DataPath> _parseDataPaths(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) throw const FormatException('"data" must be a list');
  return [
    for (final e in raw)
      if (e is String)
        DataPath(e)
      else if (e is Map)
        DataPath(
          _reqString(e.cast<String, dynamic>(), 'path'),
          sharedWithOmarchy: e['sharedWithOmarchy'] == true,
          keep: e['keep'] == true,
          note: _optString(e.cast<String, dynamic>(), 'note'),
        )
      else
        throw const FormatException('data entry must be a string or object'),
  ];
}

List<RuntimePath> _parseRuntimePaths(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) throw const FormatException('"runtime" must be a list');
  return [
    for (final e in raw)
      if (e is Map)
        RuntimePath(
          _reqString(e.cast<String, dynamic>(), 'path'),
          note: _optString(e.cast<String, dynamic>(), 'note') ?? 'runtime file',
          glob: e['glob'] == true,
          marker: _optString(e.cast<String, dynamic>(), 'marker'),
          stays: _optString(e.cast<String, dynamic>(), 'stays'),
        )
      else
        throw const FormatException('runtime entry must be an object'),
  ];
}

List<UnitRef> _parseUnits(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) throw const FormatException('"units" must be a list');
  return [
    for (final e in raw)
      if (e is String)
        UnitRef(e)
      else if (e is Map)
        UnitRef(
          _reqString(e.cast<String, dynamic>(), 'name'),
          runtime: e['runtime'] == true,
          file: _optString(e.cast<String, dynamic>(), 'file'),
          note: _optString(e.cast<String, dynamic>(), 'note'),
        )
      else
        throw const FormatException('unit entry must be a string or object'),
  ];
}

List<ProcessMatch> _parseProcesses(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) throw const FormatException('"processes" must be a list');
  return [
    for (final e in raw)
      if (e is Map)
        _parseOneProcess(e.cast<String, dynamic>())
      else
        throw const FormatException('process entry must be an object'),
  ];
}

ProcessMatch _parseOneProcess(Map<String, dynamic> m) {
  final kindName = (_optString(m, 'match') ?? _optString(m, 'kind') ?? 'exe');
  final kind = switch (kindName) {
    'exe' => MatchKind.exe,
    'exeUnder' => MatchKind.exeUnder,
    'script' => MatchKind.script,
    'scriptUnder' => MatchKind.scriptUnder,
    'quickshellConfig' => MatchKind.quickshellConfig,
    _ => throw FormatException('unknown process match kind "$kindName"'),
  };
  return ProcessMatch(kind, _reqString(m, 'path'), note: _optString(m, 'note'));
}

List<Prerequisite> _parsePrerequisites(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) throw const FormatException('"prerequisites" must be a list');
  return [
    for (final e in raw)
      if (e is String)
        Prerequisite(e)
      else if (e is Map)
        Prerequisite(
          _reqString(e.cast<String, dynamic>(), 'command'),
          part: _optString(e.cast<String, dynamic>(), 'part'),
          optional: e['optional'] == true,
          note: _optString(e.cast<String, dynamic>(), 'note'),
        )
      else
        throw const FormatException('prerequisite entry must be a string or object'),
  ];
}

BarIcon _parseBarIcon(Object? raw) {
  if (raw == null) return const BarIcon();
  if (raw is! Map) throw const FormatException('"bar" must be an object');
  final m = raw.cast<String, dynamic>();
  final kdeKindName = _optString(m, 'kdeKind') ?? 'tray';
  final kdeKind = switch (kdeKindName) {
    'tray' => KdeBarKind.tray,
    'widgetEntry' => KdeBarKind.widgetEntry,
    _ => throw FormatException('unknown kdeKind "$kdeKindName"'),
  };
  return BarIcon(
    cosmicApplet: _optString(m, 'cosmicApplet'),
    cosmicAppletExe: _optString(m, 'cosmicAppletExe'),
    kdeId: _optString(m, 'kdeId'),
    kdeKind: kdeKind,
    kdeAutostart: _optString(m, 'kdeAutostart'),
    kdeTrayExe: _optString(m, 'kdeTrayExe'),
    kdeTrayArgs: _stringList(m['kdeTrayArgs']),
    iconName: _optString(m, 'iconName'),
    kdeIconName: _optString(m, 'kdeIconName'),
    iconNote: _optString(m, 'iconNote'),
    cosmicIconBuiltIn: m['cosmicIconBuiltIn'] == true,
  );
}
