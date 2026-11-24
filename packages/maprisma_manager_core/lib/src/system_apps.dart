/// Installed non-Maprisma apps: desktop entries, Flatpaks, Snaps, AppImages and web apps,
/// with package facts, update checks, autostart toggling, launching, and managed update /
/// reinstall / uninstall jobs.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'applications.dart';
import 'bar_cosmic.dart' show atomicWrite;
import 'catalog.dart';
import 'context.dart';
import 'core.dart' show fetchInterval;
import 'icons.dart' show currentIconTheme;
import 'jobs.dart' show JobLog, pacmanLockFile;
import 'run.dart' show isExecutableFile;
import 'sysproc.dart' show procStat;
import 'translations.dart';

const _maxDesktopBytes = 256 * 1024;
const _maxDescBytes = 256 * 1024;
const _pkexecWait = Duration(minutes: 5);

final _pkgRe = RegExp(r'^[A-Za-z0-9@._+:-]{1,200}$');
final _flatpakIdRe = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$');
final _updateLineRe = RegExp(r'^([A-Za-z0-9@._+-]{1,128}) (\S{1,64}) -> (\S{1,64})$');
final _ownerLineRe = RegExp(r'^(/.{1,1024}) is owned by ([A-Za-z0-9@._+-]{1,128}) \S{1,64}$');
final _flatpakUpdateRe = RegExp(r'^([A-Za-z][A-Za-z0-9_.-]{2,254})\t(\S{0,64})$');
final _httpUrlRe = RegExp(r'^https?://[^\s\x00-\x1f\x7f]+$');

const _webAppBrowsers = {
  'google-chrome': 'Chrome',
  'google-chrome-stable': 'Chrome',
  'chrome': 'Chrome',
  'chromium': 'Chromium',
  'brave': 'Brave',
  'brave-browser': 'Brave',
  'microsoft-edge': 'Edge',
  'microsoft-edge-stable': 'Edge',
  'vivaldi': 'Vivaldi',
  'vivaldi-stable': 'Vivaldi',
};

const _browserAppsPages = {
  'Chrome': 'chrome://apps',
  'Chromium': 'chrome://apps',
  'Brave': 'brave://apps',
  'Edge': 'edge://apps',
  'Vivaldi': 'vivaldi://apps',
};

const _terminalLaunchers = {
  'xdg-terminal-exec',
  'foot',
  'footclient',
  'alacritty',
  'kitty',
  'ghostty',
  'wezterm',
  'xterm',
  'ptyxis',
  'kgx',
  'gnome-terminal',
  'gnome-terminal-server',
  'konsole',
  'cosmic-term',
};

const _terminals = [
  ('xdg-terminal-exec', <String>[]),
  ('cosmic-term', ['--']),
  ('ghostty', ['-e']),
  ('kitty', <String>[]),
  ('alacritty', ['-e']),
  ('foot', <String>[]),
  ('konsole', ['-e']),
  ('ptyxis', ['--']),
  ('kgx', ['--']),
  ('gnome-terminal', ['--']),
  ('wezterm', ['start', '--']),
  ('xfce4-terminal', ['-x']),
  ('xterm', ['-e']),
];

const _sharedProcs = {'sh', 'bash', 'zsh', 'fish', 'dash', 'env', 'flatpak', 'gtk-launch', 'python', 'python3', 'java', 'node'};

bool validSystemPackage(String name) => _pkgRe.hasMatch(name) && !name.startsWith('-');

/// Whether a desktop entry / package / program belongs to Maprisma (shown on the Maprisma Apps
/// page instead of the non-Maprisma Apps page).
bool isMaprismaApp({
  required String desktopId,
  String? desktopFile,
  String? packageName,
  String? programPath,
  Set<String> catalogDesktopFiles = const {},
}) {
  final id = desktopId.toLowerCase();
  if (id.startsWith('com.maprisma.') || id.startsWith('io.github.ubruckhaus.')) return true;
  if (desktopFile != null && catalogDesktopFiles.contains(desktopFile)) return true;
  if (packageName != null) {
    final pkg = packageName.toLowerCase();
    if (pkg == 'maprisma' || pkg == 'maprisma-bin' || pkg.startsWith('maprisma-') || pkg.startsWith('cosmic-maprisma-')) {
      return true;
    }
  }
  if (programPath != null && programPath.isNotEmpty) {
    final norm = programPath.toLowerCase();
    if (norm.contains('/usr/lib/maprisma/') || norm == '/usr/bin/maprisma') return true;
    final base = p.basename(norm);
    if (base == 'maprisma' || base.startsWith('maprisma-') || base.startsWith('cosmic-maprisma-')) return true;
  }
  return false;
}

/// Shell-like split for desktop Exec lines (quotes and backslashes).
List<String> splitExec(String text) {
  final out = <String>[];
  final cur = StringBuffer();
  var inWord = false;
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == ' ' || c == '\t' || c == '\n') {
      if (inWord) {
        out.add(cur.toString());
        cur.clear();
        inWord = false;
      }
      i++;
    } else if (c == "'") {
      final end = text.indexOf("'", i + 1);
      if (end < 0) return const [];
      cur.write(text.substring(i + 1, end));
      inWord = true;
      i = end + 1;
    } else if (c == '"') {
      i++;
      var closed = false;
      while (i < text.length) {
        final d = text[i];
        if (d == '"') {
          closed = true;
          i++;
          break;
        }
        if (d == r'\' && i + 1 < text.length && r'$`"\'.contains(text[i + 1])) {
          cur.write(text[i + 1]);
          i += 2;
        } else {
          cur.write(d);
          i++;
        }
      }
      if (!closed) return const [];
      inWord = true;
    } else if (c == r'\' && i + 1 < text.length) {
      cur.write(text[i + 1]);
      inWord = true;
      i += 2;
    } else {
      cur.write(c);
      inWord = true;
      i++;
    }
  }
  if (inWord) out.add(cur.toString());
  return out;
}

String _gShellQuote(String word) => "'${word.replaceAll("'", r"'\''")}'";

/// Expands desktop entry Exec field codes (stripping %f/%F/%u/%U).
List<String>? expandDesktopExec(String exec, {String icon = '', String name = '', String desktopFile = ''}) {
  final out = StringBuffer();
  for (var i = 0; i < exec.length; i++) {
    final c = exec[i];
    if (c != '%' || i + 1 >= exec.length) {
      out.write(c);
      continue;
    }
    final code = exec[++i];
    switch (code) {
      case '%':
        out.write('%');
      case 'i':
        if (icon.isNotEmpty) out.write('--icon ${_gShellQuote(icon)}');
      case 'c':
        out.write(_gShellQuote(name));
      case 'k':
        if (desktopFile.isNotEmpty) out.write(_gShellQuote(desktopFile));
      default:
        break;
    }
  }
  final argv = splitExec(out.toString());
  return argv.isEmpty ? null : argv;
}

/// Parses pacman local db `desc` file (`%KEY%\nvalue\n`).
Map<String, String> parsePacmanDesc(String text) {
  final fields = <String, List<String>>{};
  String? key;
  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('%') && line.endsWith('%') && line.length > 2) {
      key = line.substring(1, line.length - 1);
      fields[key] = [];
    } else if (key != null && line.isNotEmpty) {
      fields[key]!.add(line);
    } else if (line.isEmpty) {
      key = null;
    }
  }
  return {for (final e in fields.entries) e.key: e.value.join('\n')};
}

/// Parses `pacman -Qi` `Required By` field (LC_ALL=C).
List<String> parsePacmanRequiredBy(String text) {
  final out = <String>[];
  var inField = false;
  for (final line in text.split('\n')) {
    if (line.startsWith('Required By')) {
      inField = true;
      final idx = line.indexOf(':');
      if (idx >= 0) out.addAll(line.substring(idx + 1).trim().split(RegExp(r'\s+')));
    } else if (inField && line.startsWith(' ') && !line.contains(' : ')) {
      out.addAll(line.trim().split(RegExp(r'\s+')));
    } else {
      inField = false;
    }
  }
  return [
    for (final name in out)
      if (name.isNotEmpty && name != 'None' && validSystemPackage(name)) name,
  ];
}

/// Parses `checkupdates` / `paru -Qua` / `yay -Qua` output.
Map<String, (String, String)> parseSystemUpdateLines(String text) => {
  for (final line in text.split('\n'))
    if (_updateLineRe.firstMatch(line.trim()) case final m?) m[1]!: (m[2]!, m[3]!),
};

/// Parses `pacman -Qo` output (`<path> is owned by <pkg> <ver>`).
Map<String, String> parsePacmanOwners(String text) => {
  for (final line in text.split('\n'))
    if (_ownerLineRe.firstMatch(line.trim()) case final m?) m[1]!: m[2]!,
};

/// Parses `flatpak list --app --columns=application,version,size,origin,description`.
Map<String, Map<String, String>> parseFlatpakList(String text) => {
  for (final line in text.split('\n'))
    if (line.split('\t') case [final id, final version, final size, final origin, final description, ...]
        when _flatpakIdRe.hasMatch(id.trim()))
      id.trim(): {
        'version': version.trim(),
        'sizeText': size.trim(),
        'remote': origin.trim(),
        'description': description.trim(),
      },
};

/// Parses `flatpak remote-ls --updates --app --columns=application,version`.
Map<String, String> parseFlatpakUpdateLines(String text) => {
  for (final line in text.split('\n'))
    if (_flatpakUpdateRe.firstMatch(line.trimRight()) case final m?) m[1]!: m[2]!,
};

/// Extracts a clean display name and optional version from an AppImage filename stem.
({String name, String version}) parseAppImageFilename(String stem) {
  final cleaned = stem.replaceAll(
    RegExp(r'(?<![^-_ .])(?:x86[-_]64|aarch64|arm64|amd64|armv7l|i[36]86|linux|gnu|appimage)(?=$|[-_ .])', caseSensitive: false),
    '',
  );
  final words = cleaned.split(RegExp(r'[-_ ]+')).where((w) => w.isNotEmpty).toList();
  final verRe = RegExp(r'^v?\d+(?:\.\d+)+(?:[.+~-][A-Za-z0-9.+~-]+)?$', caseSensitive: false);
  var cut = words.length;
  for (var i = 1; i < words.length; i++) {
    if (verRe.hasMatch(words[i])) {
      cut = i;
      break;
    }
  }
  final name = words.take(cut).join(' ').trim();
  final version = cut < words.length ? words[cut].replaceFirst(RegExp(r'^[vV]'), '') : '';
  return (name: name.isEmpty ? stem : name, version: version);
}

/// Moves [path] to XDG Trash (`$XDG_DATA_HOME/Trash`) per the freedesktop Trash spec.
String? moveFileToTrash(String path, Ctx ctx) {
  final trash = p.join(ctx.paths.data, 'Trash');
  final files = Directory(p.join(trash, 'files'))..createSync(recursive: true);
  final info = Directory(p.join(trash, 'info'))..createSync(recursive: true);
  final base = p.basename(path);
  var name = base;
  for (var n = 2;
      File(p.join(info.path, '$name.trashinfo')).existsSync() ||
          FileSystemEntity.typeSync(p.join(files.path, name), followLinks: false) != FileSystemEntityType.notFound;
      n++) {
    name = '$base.$n';
  }
  final now = ctx.clock();
  String two(int v) => '$v'.padLeft(2, '0');
  final date = '${now.year}-${two(now.month)}-${two(now.day)}T${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  final infoFile = File(p.join(info.path, '$name.trashinfo'));
  infoFile.writeAsStringSync('[Trash Info]\nPath=${Uri(path: p.absolute(path)).toString()}\nDeletionDate=$date\n');
  try {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      Link(path).renameSync(p.join(files.path, name));
    } else {
      File(path).renameSync(p.join(files.path, name));
    }
    return p.join(files.path, name);
  } on FileSystemException {
    try {
      if (infoFile.existsSync()) infoFile.deleteSync();
    } on FileSystemException {
      // ignore
    }
    return null;
  }
}

final class _SysJob {
  _SysJob(this.job, this.log);
  final Map<String, dynamic> job;
  final JobLog log;
  final done = Completer<Map<String, dynamic>>();
  String get id => job['id'] as String;
  String get app => job['app'] as String;
  String get kind => job['kind'] as String;
  Process? process;
  bool cancelRequested = false;
  bool committed = false;
  final recent = StringBuffer();

  void remember(List<int> data) {
    final s = utf8.decode(data, allowMalformed: true);
    recent.write(s);
    if (recent.length > 8192) {
      final tail = recent.toString().substring(recent.length - 4096);
      recent
        ..clear()
        ..write(tail);
    }
  }
}

final class _IconIndex {
  _IconIndex(this.ctx) {
    final dataDirs = _iconDataDirs(ctx);
    _bases = [
      p.join(ctx.paths.home, '.icons'),
      for (final d in dataDirs) p.join(d, 'icons'),
    ];
    _pixmaps = [for (final d in dataDirs) p.join(d, 'pixmaps')];
    final theme = currentIconTheme(ctx).name;
    final chain = <String>[];
    void add(String name, int depth) {
      if (depth > 8 || chain.contains(name) || name == 'hicolor') return;
      final index = _readIndex(name);
      if (index == null) return;
      chain.add(name);
      final m = RegExp(r'^Inherits\s*=\s*(.*)$', multiLine: true).firstMatch(index);
      for (final parent in (m?[1] ?? '').split(',')) {
        final t = parent.trim();
        if (t.isNotEmpty) add(t, depth + 1);
      }
    }

    if (theme.isNotEmpty) add(theme, 0);
    chain.add('hicolor');
    _themes = chain;
  }

  final Ctx ctx;
  late final List<String> _bases;
  late final List<String> _pixmaps;
  late final List<String> _themes;
  final _themeCache = <String, Map<String, (int, String)>>{};
  final _lookupCache = <String, String?>{};

  static List<String> _iconDataDirs(Ctx ctx) {
    final envDirs = (ctx.environment['XDG_DATA_DIRS'] ?? '').split(':').where((d) => d.startsWith('/')).toList();
    final system = envDirs.isEmpty ? ['/usr/local/share', '/usr/share'] : envDirs;
    final out = <String>[
      ctx.paths.data,
      p.join(ctx.paths.data, 'flatpak/exports/share'),
      for (final d in system) ctx.paths.sys(d),
      ctx.paths.sys('/var/lib/flatpak/exports/share'),
    ];
    return out.toSet().toList();
  }

  String? _readIndex(String theme) {
    for (final base in _bases) {
      final f = File(p.join(base, theme, 'index.theme'));
      try {
        if (f.existsSync()) return f.readAsStringSync();
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  Map<String, (int, String)> _scanTheme(String theme) => _themeCache.putIfAbsent(theme, () {
    final found = <String, (int, String)>{};
    for (final base in _bases.reversed) {
      final root = Directory(p.join(base, theme));
      if (!root.existsSync()) continue;
      List<FileSystemEntity> files;
      try {
        files = root.listSync(recursive: true, followLinks: true);
      } on FileSystemException {
        continue;
      }
      var walked = 0;
      for (final f in files) {
        if (++walked > 60000) break;
        final file = f.path;
        final ext = p.extension(file).toLowerCase();
        if (ext != '.svg' && ext != '.png') continue;
        final name = p.basenameWithoutExtension(file);
        if (name.endsWith('-symbolic')) continue;
        final rel = p.split(p.relative(file, from: root.path));
        var rank = 0;
        for (final part in rel) {
          if (part.startsWith('scalable')) rank = 10000;
          final size = RegExp(r'^(\d+)(?:x\d+)?(?:@(\d+)x?)?$').firstMatch(part);
          if (size != null && rank < 10000) {
            rank = int.parse(size[1]!) * (int.tryParse(size[2] ?? '') ?? 1);
          }
        }
        if (ext == '.svg' && rank < 10000) rank += 5000;
        final old = found[name];
        if (old == null || rank > old.$1) found[name] = (rank, file);
      }
    }
    return found;
  });

  String? lookup(String icon) {
    if (icon.isEmpty) return null;
    return _lookupCache.putIfAbsent(icon, () {
      if (icon.startsWith('/')) {
        if (FileSystemEntity.isFileSync(icon)) return icon;
        final mapped = ctx.paths.sys(icon);
        return FileSystemEntity.isFileSync(mapped) ? mapped : null;
      }
      if (icon.contains('/') || icon.startsWith('.')) return null;
      var name = icon;
      for (final ext in ['.png', '.svg', '.xpm']) {
        if (name.endsWith(ext)) name = name.substring(0, name.length - ext.length);
      }
      for (final theme in _themes) {
        final hit = _scanTheme(theme)[name];
        if (hit != null) return hit.$2;
      }
      for (final dir in _pixmaps) {
        for (final ext in ['svg', 'png']) {
          final file = p.join(dir, '$name.$ext');
          if (FileSystemEntity.isFileSync(file)) return file;
        }
      }
      return null;
    });
  }
}

/// Service for installed non-Maprisma apps (`system_apps.*` and `system_jobs.*` routes).
final class SystemAppsService {
  SystemAppsService(this.ctx, this._startDetached);
  final Ctx ctx;
  final Future<bool> Function(String exe, List<String> args) _startDetached;

  _IconIndex? _icons;
  String? _pacmanDbStamp;
  Map<String, Map<String, dynamic>> _pacmanDb = const {};

  DateTime? _lastUpdateCheck;
  Map<String, (String, String)> _pacmanUpdates = const {};
  Map<String, (String, String)> _aurUpdates = const {};
  Map<String, String> _flatpakUpdates = const {};

  // Cached last listed apps by id so open / remove_plan / jobs look up consistently.
  Map<String, Map<String, dynamic>> _lastApps = const {};

  // Managed jobs queue (identical shape to JobEngine).
  final Map<String, _SysJob> _jobs = {};
  final Queue<_SysJob> _queue = Queue();
  _SysJob? _running;
  int _seq = 0;

  Set<String> _catalogDesktopFiles() => {
    for (final a in catalog)
      for (final c in a.components)
        for (final path in c.paths)
          if (path.path.endsWith('.desktop')) p.basename(path.path),
  };

  List<String> _appDirs() {
    final envDirs = (ctx.environment['XDG_DATA_DIRS'] ?? '').split(':').where((d) => d.startsWith('/')).toList();
    final system = envDirs.isEmpty ? ['/usr/local/share', '/usr/share'] : envDirs;
    final dirs = <String>[
      ctx.paths.apps,
      p.join(ctx.paths.data, 'flatpak/exports/share/applications'),
      for (final d in system) ctx.paths.sys(p.join(d, 'applications')),
      ctx.paths.sys('/var/lib/flatpak/exports/share/applications'),
      ctx.paths.sys('/var/lib/snapd/desktop/applications'),
    ];
    return dirs.toSet().toList();
  }

  Map<String, Map<String, dynamic>> _readPacmanDb() {
    final root = ctx.paths.sys('/var/lib/pacman/local');
    String stamp;
    try {
      stamp = '${Directory(root).statSync().modified.microsecondsSinceEpoch}';
    } on FileSystemException {
      return const {};
    }
    if (stamp == _pacmanDbStamp) return _pacmanDb;
    final out = <String, Map<String, dynamic>>{};
    List<FileSystemEntity> dirs;
    try {
      dirs = Directory(root).listSync();
    } on FileSystemException {
      dirs = const [];
    }
    for (final d in dirs) {
      final f = File(p.join(d.path, 'desc'));
      if (!f.existsSync()) continue;
      String text;
      try {
        final bytes = f.readAsBytesSync();
        if (bytes.length > _maxDescBytes) continue;
        text = utf8.decode(bytes, allowMalformed: true);
      } on FileSystemException {
        continue;
      }
      final fields = parsePacmanDesc(text);
      final name = fields['NAME'];
      if (name == null || !validSystemPackage(name)) continue;
      out[name] = {
        'name': name,
        'version': fields['VERSION'] ?? '',
        'url': fields['URL'] ?? '',
        'description': fields['DESC'] ?? '',
        'size': ?int.tryParse(fields['SIZE'] ?? ''),
        'installed': ?int.tryParse(fields['INSTALLDATE'] ?? ''),
      };
    }
    _pacmanDbStamp = stamp;
    return _pacmanDb = out;
  }

  List<String> _langChain() {
    final langs = <String>[];
    void add(String raw) {
      final clean = raw.split('.').first.split('@').first;
      if (clean.isNotEmpty && !langs.contains(clean)) langs.add(clean);
      final base = clean.split('_').first;
      if (base.isNotEmpty && !langs.contains(base)) langs.add(base);
    }

    if (currentLanguage != 'en') add(currentLanguage);
    for (final k in ['LC_ALL', 'LC_MESSAGES', 'LANG']) {
      final v = ctx.environment[k];
      if (v != null && v.isNotEmpty && v != 'C' && v != 'POSIX') {
        add(v);
        break;
      }
    }
    return langs;
  }

  static String _unescape(String v) => v.replaceAllMapped(
    RegExp(r'\\(.)'),
    (m) => switch (m[1]) {
      's' => ' ',
      'n' => '\n',
      't' => '\t',
      'r' => '\r',
      _ => m[1]!,
    },
  );

  static String? _locVal(Map<String, String> group, String key, List<String> langs) {
    for (final l in langs) {
      final v = group['$key[$l]'];
      if (v != null && v.isNotEmpty) return _unescape(v);
    }
    final plain = group[key];
    return plain == null || plain.isEmpty ? null : _unescape(plain);
  }

  static Map<String, Map<String, String>> _parseDesktopGroups(String text) {
    final groups = <String, Map<String, String>>{};
    Map<String, String>? current;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('[') && line.endsWith(']') && line.length > 2) {
        current = groups.putIfAbsent(line.substring(1, line.length - 1), () => {});
        continue;
      }
      final eq = line.indexOf('=');
      if (current == null || eq <= 0) continue;
      final k = line.substring(0, eq).trim();
      if (k.isEmpty) continue;
      current.putIfAbsent(k, () => line.substring(eq + 1).trim());
    }
    return groups;
  }

  static bool _isPwa(Map<String, String> entry) {
    if ((entry['StartupWMClass'] ?? '').startsWith('crx_')) return true;
    final exec = entry['Exec'] ?? '';
    final icon = entry['Icon'] ?? '';
    return exec.contains('--app-id=') && icon.startsWith('/') && icon.endsWith('.png');
  }

  static String? _browserWebApp(String exec) {
    final argv = splitExec(exec);
    if (argv.isEmpty || !argv.any((a) => a.startsWith('--app-id='))) return null;
    final first = p.basename(argv.first).toLowerCase();
    if (_terminalLaunchers.contains(first)) return null;
    return _webAppBrowsers[first] ?? 'Browser';
  }

  static String? _webUrl(String exec) {
    final argv = _unwrapEnv(splitExec(exec));
    if (argv.length > 1 && p.basename(argv.first) == 'xdg-open' && _httpUrlRe.hasMatch(argv[1])) {
      return argv[1];
    }
    for (final a in argv) {
      if (a.startsWith('--app=') && _httpUrlRe.hasMatch(a.substring(6))) return a.substring(6);
    }
    return null;
  }

  static List<String> _unwrapEnv(List<String> argv) {
    var i = 0;
    if (argv.isNotEmpty && p.basename(argv.first) == 'env') {
      i = 1;
      while (i < argv.length && (argv[i].contains('=') || argv[i].startsWith('-'))) {
        if (argv[i] == '-u' || argv[i] == '--unset') {
          i += 2;
        } else {
          i++;
        }
      }
    }
    return i < argv.length ? argv.sublist(i) : const [];
  }

  static String? _terminalInnerProgram(List<String> argv) {
    if (argv.isEmpty) return null;
    final first = p.basename(argv.first).toLowerCase();
    if (!_terminalLaunchers.contains(first)) return null;
    for (final flag in ['-e', '--command', '--']) {
      final i = argv.indexOf(flag);
      if (i >= 0 && i + 1 < argv.length) {
        final prog = argv[i + 1];
        if (!_sharedProcs.contains(p.basename(prog).toLowerCase())) return prog;
      }
    }
    return null;
  }

  String? _resolveProgram(String exec) {
    final argv = _unwrapEnv(splitExec(exec));
    if (argv.isEmpty) return null;
    final prog = _terminalInnerProgram(argv) ?? argv.first;
    final found = prog.contains('/') ? (isExecutableFile(prog) ? prog : (isExecutableFile(ctx.paths.sys(prog)) ? ctx.paths.sys(prog) : null)) : ctx.runner.which(prog);
    if (found == null) return null;
    try {
      return File(found).resolveSymbolicLinksSync();
    } on FileSystemException {
      return found;
    }
  }

  bool _execExists(String exec) {
    final argv = _unwrapEnv(splitExec(exec));
    if (argv.isEmpty) return false;
    final prog = argv.first;
    if (prog.contains('/')) return isExecutableFile(prog) || isExecutableFile(ctx.paths.sys(prog));
    return ctx.runner.which(prog) != null;
  }

  /// Reads user's mimeapps.list for default app roles (fast, no subprocess).
  Map<String, List<String>> _defaultRolesByDesktop() {
    final defaults = <String, String>{};
    for (final path in [
      p.join(ctx.paths.config, 'gnome-mimeapps.list'),
      p.join(ctx.paths.config, 'mimeapps.list'),
      p.join(ctx.paths.apps, 'mimeapps.list'),
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      String? section;
      try {
        for (final raw in f.readAsLinesSync()) {
          final line = raw.trim();
          if (line.startsWith('[')) {
            section = line;
          } else if (section == '[Default Applications]' && line.contains('=')) {
            final eq = line.indexOf('=');
            final first = line.substring(eq + 1).split(';').firstWhere((e) => e.trim().isNotEmpty, orElse: () => '').trim();
            if (first.isNotEmpty) defaults.putIfAbsent(line.substring(0, eq).trim(), () => first);
          }
        }
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    final byDesktop = <String, List<String>>{};
    for (final entry in ApplicationsService.roles.entries) {
      for (final mime in entry.value) {
        final d = defaults[mime];
        if (d != null && d.isNotEmpty) {
          final list = byDesktop.putIfAbsent(d, () => []);
          if (!list.contains(entry.key)) list.add(entry.key);
        }
      }
    }
    return byDesktop;
  }

  /// Active autostart desktop file names in `~/.config/autostart`.
  Set<String> _enabledAutostarts() {
    final dir = Directory(ctx.paths.autostart);
    if (!dir.existsSync()) return const {};
    final out = <String>{};
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (!name.endsWith('.desktop')) continue;
        try {
          final e = ApplicationsService.entry(f.readAsStringSync());
          if (e['Hidden'] != 'true' && e['X-GNOME-Autostart-enabled'] != 'false') {
            out.add(name);
          }
        } on Object {
          continue;
        }
      }
    } on FileSystemException {
      // ignore
    }
    return out;
  }

  /// Running executable basenames & cmdline tokens from `ctx.processes()`.
  Set<String> _runningProcessNames() {
    final names = <String>{};
    for (final proc in ctx.processes()) {
      if (proc.exe != null && proc.exe!.isNotEmpty) {
        names.add(p.basename(proc.exe!).toLowerCase());
      }
      for (final arg in proc.argv.take(2)) {
        if (arg.isNotEmpty) names.add(p.basename(arg).toLowerCase());
      }
    }
    return names;
  }

  bool _isRunning(Map<String, dynamic> app, Set<String> procNames) {
    final exec = app['exec'] as String? ?? '';
    final argv = _unwrapEnv(splitExec(exec));
    final termProg = _terminalInnerProgram(argv);
    if (termProg != null) {
      return procNames.contains(p.basename(termProg).toLowerCase());
    }
    if (argv.isNotEmpty) {
      final base = p.basename(argv.first).toLowerCase();
      if (!_sharedProcs.contains(base) && procNames.contains(base)) return true;
    }
    final prog = app['program'] as String?;
    if (prog != null && prog.isNotEmpty) {
      final base = p.basename(prog).toLowerCase();
      if (!_sharedProcs.contains(base) && procNames.contains(base)) return true;
    }
    final wm = (app['startupClass'] as String? ?? '').toLowerCase();
    if (wm.isNotEmpty && !_sharedProcs.contains(wm) && procNames.contains(wm)) return true;
    return false;
  }

  String _unmapSys(String path) {
    if (ctx.paths.root == '/') return path;
    final prefix = ctx.paths.root.endsWith('/') ? ctx.paths.root.substring(0, ctx.paths.root.length - 1) : ctx.paths.root;
    if (path.startsWith('$prefix/')) return path.substring(prefix.length);
    return path;
  }

  /// Looks up a package-manager / helper tool; in a test root (`paths.root != '/'`), never falls
  /// back to the host's `/usr/*` or `/bin/*` binaries so tests stay fast and hermetic.
  String? _whichTool(String name) {
    final t = ctx.runner.which(name);
    if (t == null) return null;
    if (ctx.paths.root != '/' && (t.startsWith('/usr/') || t.startsWith('/bin/'))) return null;
    return t;
  }

  Future<Map<String, String>> _pacmanOwners(Set<String> paths) async {
    if (paths.isEmpty || _whichTool('pacman') == null) return const {};
    final mapped = paths.take(4000).toList();
    final r = await ctx.runner.run(
      ['pacman', '-Qo', '--', ...mapped],
      extraEnv: const {'LC_ALL': 'C'},
      timeout: const Duration(seconds: 20),
    );
    return parsePacmanOwners(r.stdout);
  }

  Future<Set<String>> _pacmanForeign() async {
    if (_whichTool('pacman') == null) return const {};
    final r = await ctx.runner.run(
      ['pacman', '-Qqm'],
      extraEnv: const {'LC_ALL': 'C'},
      timeout: const Duration(seconds: 10),
    );
    if (!r.ok) return const {};
    return {
      for (final line in r.stdout.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    };
  }

  Future<Map<String, Map<String, String>>> _flatpakFacts() async {
    if (_whichTool('flatpak') == null) return const {};
    final r = await ctx.runner.run(
      ['flatpak', 'list', '--app', '--columns=application,version,size,origin,description'],
      extraEnv: const {'LC_ALL': 'C'},
      timeout: const Duration(seconds: 20),
    );
    if (!r.ok) return const {};
    return parseFlatpakList(r.stdout);
  }

  Future<(String, String)?> _fallbackOwner(String path) async {
    if (!p.isAbsolute(path)) return null;
    if (_whichTool('dpkg') != null) {
      final r = await ctx.runner.run(['dpkg', '-S', '--', path], extraEnv: const {'LC_ALL': 'C'}, timeout: const Duration(seconds: 5));
      if (r.ok) {
        final name = r.stdout.trim().split('\n').first.split(':').first.trim();
        if (validSystemPackage(name)) return ('apt', name);
      }
    }
    if (_whichTool('rpm') != null) {
      final r = await ctx.runner.run(['rpm', '-qf', '--queryformat', '%{NAME}\n', '--', path], extraEnv: const {'LC_ALL': 'C'}, timeout: const Duration(seconds: 5));
      if (r.ok) {
        final name = r.stdout.trim().split('\n').first.trim();
        if (validSystemPackage(name) && !name.contains(' ')) {
          return (_whichTool('zypper') != null ? 'zypper' : 'dnf', name);
        }
      }
    }
    return null;
  }

  List<String>? _defaultTerminal() {
    final own = ctx.environment['TERMINAL'] ?? '';
    if (RegExp(r'^[A-Za-z0-9._+-]{1,64}$').hasMatch(own)) {
      final found = ctx.runner.which(own);
      if (found != null) {
        final known = _terminals.where((t) => t.$1 == own).firstOrNull;
        return [found, ...known?.$2 ?? ['-e']];
      }
    }
    for (final (program, follow) in _terminals) {
      final found = ctx.runner.which(program);
      if (found != null) return [found, ...follow];
    }
    return null;
  }

  String? _aurHelper() {
    for (final h in ['paru', 'yay']) {
      if (_whichTool(h) != null) return h;
    }
    return null;
  }

  /// `system_apps.list`: all installed non-Maprisma apps with facts, icons, running/autostart
  /// status, and cached update info.
  Future<Map<String, dynamic>> list() async {
    final langs = _langChain();
    final maprismaFiles = _catalogDesktopFiles();
    final icons = _icons ??= _IconIndex(ctx);
    final rawEntries = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    final seenNames = <String>{};
    final startedPrograms = <String>{};

    for (final dir in _appDirs()) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      List<FileSystemEntity> files;
      try {
        files = d.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entity in files) {
        final path = entity.path;
        final file = p.basename(path);
        if (!file.endsWith('.desktop') || file == '.desktop') continue;
        if (!seenIds.add(file)) continue;
        String text;
        try {
          final bytes = File(path).readAsBytesSync();
          if (bytes.length > _maxDesktopBytes) continue;
          text = utf8.decode(bytes, allowMalformed: true);
        } on FileSystemException {
          continue;
        }
        final groups = _parseDesktopGroups(text);
        final entry = groups['Desktop Entry'];
        if (entry == null) continue;
        if (entry['Type'] != null && entry['Type'] != 'Application') continue;
        if ((entry['Hidden'] ?? '').toLowerCase() == 'true') continue;
        final pwa = _isPwa(entry);
        if ((entry['NoDisplay'] ?? '').toLowerCase() == 'true' && !pwa) continue;

        final desktopId = file.substring(0, file.length - '.desktop'.length);
        final name = _locVal(entry, 'Name', langs);
        final exec = entry['Exec'];
        if (name == null || name.isEmpty || exec == null || exec.isEmpty) continue;
        final tryExec = entry['TryExec'];
        if (tryExec != null && tryExec.isNotEmpty && !_execExists(tryExec)) continue;
        if (!_execExists(exec)) continue;

        final program = _resolveProgram(exec);
        if (isMaprismaApp(
          desktopId: desktopId,
          desktopFile: file,
          programPath: program,
          catalogDesktopFiles: maprismaFiles,
        )) {
          continue;
        }

        final nameKey = name.trim().toLowerCase();
        if (!seenNames.add(nameKey)) continue;
        if (program != null) startedPrograms.add(program);

        final desc = (_locVal(entry, 'Comment', langs) ?? _locVal(entry, 'GenericName', langs) ?? '').trim();
        final iconRaw = entry['Icon'] ?? '';
        final actions = <Map<String, String>>[
          for (final aid in (entry['Actions'] ?? '').split(';').where((s) => s.isNotEmpty))
            if (groups['Desktop Action $aid'] case final g? when (g['Exec'] ?? '').isNotEmpty)
              {'id': aid, 'name': _locVal(g, 'Name', langs) ?? aid},
        ];

        rawEntries.add({
          'id': file,
          'desktopId': desktopId,
          'name': name,
          'description': desc,
          'iconRaw': iconRaw,
          'iconFile': icons.lookup(iconRaw),
          'desktopPath': path,
          'exec': exec.replaceAll(RegExp(r'%[a-zA-Z]'), '').trim(),
          'program': program,
          'terminal': (entry['Terminal'] ?? '').toLowerCase() == 'true',
          'flatpak': (entry['X-Flatpak'] ?? '').isNotEmpty || path.contains('/flatpak/'),
          'flatpakId': (entry['X-Flatpak'] ?? '').isNotEmpty ? entry['X-Flatpak'] : (_flatpakIdRe.hasMatch(desktopId) ? desktopId : null),
          'snap': (entry['X-SnapInstanceName'] ?? '').isNotEmpty || path.contains('/snapd/'),
          'snapName': (entry['X-SnapInstanceName'] ?? '').isNotEmpty ? entry['X-SnapInstanceName'] : (path.contains('/snapd/') ? file.split('_').first : null),
          'pwa': pwa,
          'startupClass': entry['StartupWMClass'] ?? '',
          'actions': actions,
        });
      }
    }

    // Standalone AppImages in ~/Applications and ~/AppImages.
    for (final sub in ['Applications', 'AppImages']) {
      final dir = Directory(p.join(ctx.paths.home, sub));
      if (!dir.existsSync()) continue;
      List<FileSystemEntity> files;
      try {
        files = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final f in files) {
        final path = f.path;
        final base = p.basename(path);
        if (!RegExp(r'\.appimage$', caseSensitive: false).hasMatch(base)) continue;
        if (!isExecutableFile(path)) continue;
        if (startedPrograms.contains(path)) continue;
        final stem = base.substring(0, base.length - p.extension(base).length);
        final parsed = parseAppImageFilename(stem);
        if (isMaprismaApp(desktopId: stem, programPath: path, catalogDesktopFiles: maprismaFiles)) continue;
        if (!seenNames.add(parsed.name.toLowerCase())) continue;
        rawEntries.add({
          'id': 'appimage:$base',
          'desktopId': stem,
          'name': parsed.name,
          'description': base,
          'iconRaw': '',
          'iconFile': null,
          'desktopPath': '',
          'exec': path,
          'program': path,
          'terminal': false,
          'flatpak': false,
          'snap': false,
          'pwa': false,
          'appimage': true,
          'appimageVersion': parsed.version,
          'startupClass': stem,
          'actions': const <Map<String, String>>[],
        });
      }
    }

    // Batch package facts.
    final ownerQueryPaths = <String>{};
    for (final e in rawEntries) {
      if (e['flatpak'] == true || e['snap'] == true || e['appimage'] == true) continue;
      final dp = e['desktopPath'] as String;
      final unmappedDp = _unmapSys(dp);
      if (unmappedDp.startsWith('/usr/')) ownerQueryPaths.add(dp);
      final prog = e['program'] as String?;
      if (prog != null && _unmapSys(prog).startsWith('/usr/')) ownerQueryPaths.add(prog);
    }

    final (owners, foreign, flatpaks) = await (
      _pacmanOwners(ownerQueryPaths),
      _pacmanForeign(),
      _flatpakFacts(),
    ).wait;
    final pacmanDb = _readPacmanDb();
    final procNames = _runningProcessNames();
    final autostarts = _enabledAutostarts();
    final rolesByDesktop = _defaultRolesByDesktop();
    final userAppsDir = ctx.paths.apps;

    final out = <Map<String, dynamic>>[];
    final byId = <String, Map<String, dynamic>>{};

    for (final raw in rawEntries) {
      final id = raw['id'] as String;
      final desktopPath = raw['desktopPath'] as String;
      final exec = raw['exec'] as String;
      final program = raw['program'] as String?;
      final browser = _browserWebApp(exec);
      final webUrl = _webUrl(exec);
      final isAppImage = raw['appimage'] == true || (program != null && program.toLowerCase().endsWith('.appimage'));

      String source;
      String kind;
      String version = '';
      Map<String, dynamic>? pkg;
      int? fileSize;
      int? modified;
      String? website = webUrl;
      Map<String, dynamic>? update;
      bool canReinstall = false;
      bool canUninstall = false;

      if (raw['flatpak'] == true && raw['flatpakId'] is String) {
        final fid = raw['flatpakId'] as String;
        final fp = flatpaks[fid];
        source = 'flatpak';
        kind = 'flatpak';
        version = fp?['version'] ?? '';
        pkg = {'name': fid, ...?fp};
        if (_flatpakUpdates[fid] case final avail?) {
          update = {'installed': version, 'available': avail, 'manager': 'flatpak'};
        }
        canReinstall = true;
        canUninstall = true;
      } else if (raw['snap'] == true && raw['snapName'] is String) {
        final sname = raw['snapName'] as String;
        source = 'snap';
        kind = 'snap';
        pkg = {'name': sname};
        canUninstall = true;
      } else if (browser != null || raw['pwa'] == true || webUrl != null) {
        source = 'webapp';
        kind = 'webapp';
        canUninstall = true;
      } else if (isAppImage) {
        source = 'appimage';
        kind = 'appimage';
        version = (raw['appimageVersion'] as String?) ??
            (program != null ? parseAppImageFilename(p.basenameWithoutExtension(program)).version : '');
        if (program != null) {
          try {
            final st = File(program).statSync();
            fileSize = st.size;
            modified = st.modified.millisecondsSinceEpoch ~/ 1000;
          } on FileSystemException {
            // ignore
          }
        }
        canUninstall = program != null && _isWithinHome(program) || _isUserDesktop(desktopPath, userAppsDir);
      } else {
        // Check pacman owner (desktop file first, then program).
        final owner = owners[desktopPath] ?? owners[_unmapSys(desktopPath)] ?? (program == null ? null : (owners[program] ?? owners[_unmapSys(program)]));
        if (owner != null) {
          if (isMaprismaApp(desktopId: raw['desktopId'] as String, packageName: owner, programPath: program, catalogDesktopFiles: maprismaFiles)) {
            continue;
          }
          final isAur = foreign.contains(owner);
          source = isAur ? 'aur' : 'pacman';
          kind = raw['terminal'] == true ? 'terminal' : 'app';
          final info = pacmanDb[owner];
          version = '${info?['version'] ?? ''}';
          pkg = info ?? {'name': owner};
          if (website == null && info != null && '${info['url']}'.isNotEmpty) {
            website = '${info['url']}';
          }
          if (isAur) {
            if (_aurUpdates[owner] case final u?) {
              update = {'installed': u.$1, 'available': u.$2, 'manager': 'aur'};
            }
          } else {
            if (_pacmanUpdates[owner] case final u?) {
              update = {'installed': u.$1, 'available': u.$2, 'manager': 'pacman'};
            }
          }
          canReinstall = true;
          canUninstall = true;
        } else if (desktopPath.isNotEmpty && _isUserDesktop(desktopPath, userAppsDir)) {
          source = 'local';
          kind = raw['terminal'] == true ? 'terminal' : 'app';
          if (program != null) {
            try {
              final st = File(program).statSync();
              fileSize = st.size;
              modified = st.modified.millisecondsSinceEpoch ~/ 1000;
            } on FileSystemException {
              // ignore
            }
          }
          canUninstall = true;
        } else {
          // Non-Arch distro fallback or unowned system desktop file.
          source = 'pacman';
          kind = raw['terminal'] == true ? 'terminal' : 'app';
          if (_whichTool('pacman') == null && desktopPath.isNotEmpty) {
            final fb = await _fallbackOwner(desktopPath);
            if (fb != null) {
              source = fb.$1;
              pkg = {'name': fb.$2};
              canUninstall = true;
            } else {
              source = 'local';
            }
          } else {
            source = 'local';
          }
        }
      }

      var description = raw['description'] as String;
      if (description.isEmpty && pkg?['description'] is String) {
        description = pkg!['description'] as String;
      }

      final running = _isRunning(raw, procNames);
      final autostartSupported = desktopPath.isNotEmpty && id.endsWith('.desktop');
      final autostart = autostartSupported && autostarts.contains(id);
      final defaultRoles = desktopPath.isEmpty ? const <String>[] : (rolesByDesktop[id] ?? const <String>[]);

      final app = <String, dynamic>{
        'id': id,
        'desktopId': raw['desktopId'],
        'name': raw['name'],
        'description': description,
        'icon': {'file': raw['iconFile'], 'name': raw['iconRaw']},
        'kind': kind,
        'source': source,
        'desktopPath': desktopPath,
        'exec': exec,
        'program': ?program,
        if (version.isNotEmpty) 'version': version,
        'package': ?pkg,
        'fileSize': ?fileSize,
        'modified': ?modified,
        if (website != null && website.isNotEmpty) 'website': website,
        'browser': ?browser,
        'running': running,
        'autostart': autostart,
        'autostartSupported': autostartSupported,
        'defaultRoles': defaultRoles,
        'actions': raw['actions'],
        'update': ?update,
        'canOpen': true,
        'canUpdate': update != null,
        'canReinstall': canReinstall,
        'canUninstall': canUninstall,
      };
      out.add(app);
      byId[id] = app;
    }

    out.sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
    _lastApps = byId;
    return {
      'desktop': ctx.desktop.name,
      'apps': out,
      if (_lastUpdateCheck != null) 'updatesChecked': _lastUpdateCheck!.toUtc().toIso8601String(),
    };
  }

  bool _isUserDesktop(String path, String userAppsDir) {
    if (path.isEmpty) return false;
    try {
      final real = File(path).resolveSymbolicLinksSync();
      final own = Directory(userAppsDir).existsSync() ? Directory(userAppsDir).resolveSymbolicLinksSync() : userAppsDir;
      return p.isWithin(own, real) || p.equals(own, real);
    } on FileSystemException {
      return p.isWithin(userAppsDir, path);
    }
  }

  bool _isWithinHome(String path) {
    try {
      final real = File(path).resolveSymbolicLinksSync();
      final home = Directory(ctx.paths.home).existsSync() ? Directory(ctx.paths.home).resolveSymbolicLinksSync() : ctx.paths.home;
      return p.isWithin(home, real);
    } on FileSystemException {
      return p.isWithin(ctx.paths.home, path);
    }
  }

  /// `system_apps.check_updates` {force?}: checks checkupdates, AUR helper, and flatpak.
  Future<Map<String, dynamic>> checkUpdates({bool force = false}) async {
    final now = ctx.clock();
    if (!force && _lastUpdateCheck != null && now.difference(_lastUpdateCheck!) < fetchInterval) {
      return {
        'checked': false,
        'skipped': 'recent',
        'updates': _pacmanUpdates.length + _aurUpdates.length + _flatpakUpdates.length,
      };
    }

    Future<Map<String, (String, String)>> official() async {
      if (_whichTool('checkupdates') == null) return const {};
      final r = await ctx.runner.run(['checkupdates'], extraEnv: const {'LC_ALL': 'C'}, timeout: const Duration(seconds: 90));
      if (r.code != 0 && r.code != 2) return const {};
      return parseSystemUpdateLines(r.stdout);
    }

    Future<Map<String, (String, String)>> aur() async {
      final helper = _aurHelper();
      if (helper == null) return const {};
      final r = await ctx.runner.run([helper, '-Qua'], extraEnv: const {'LC_ALL': 'C'}, timeout: const Duration(seconds: 90));
      if (r.code != 0 && r.code != 1) return const {};
      return parseSystemUpdateLines(r.stdout);
    }

    Future<Map<String, String>> flatpak() async {
      if (_whichTool('flatpak') == null) return const {};
      final r = await ctx.runner.run(
        ['flatpak', 'remote-ls', '--updates', '--app', '--columns=application,version'],
        extraEnv: const {'LC_ALL': 'C'},
        timeout: const Duration(seconds: 90),
      );
      if (!r.ok) return const {};
      return parseFlatpakUpdateLines(r.stdout);
    }

    final (pac, aurRes, fp) = await (official(), aur(), flatpak()).wait;
    _pacmanUpdates = pac;
    _aurUpdates = aurRes;
    _flatpakUpdates = fp;
    _lastUpdateCheck = now;
    return {
      'checked': true,
      'pacman': pac.length,
      'aur': aurRes.length,
      'flatpak': fp.length,
      'updates': pac.length + aurRes.length + fp.length,
    };
  }

  Future<Map<String, dynamic>> _requireApp(Map<String, dynamic> params) async {
    final id = params['id'];
    if (id is! String || id.isEmpty) throw RouteError('bad_params', 'id');
    if (!_lastApps.containsKey(id)) {
      await list();
    }
    final app = _lastApps[id];
    if (app == null) throw RouteError('not_found', trf('no app {0}', [id]));
    return app;
  }

  /// `system_apps.open` {id, action?}: starts the app or one of its desktop actions.
  Future<Map<String, dynamic>> open(Map<String, dynamic> params) async {
    final app = await _requireApp(params);
    final action = params['action'];
    if (action != null && action is! String) throw RouteError('bad_params', 'action');

    final desktopPath = app['desktopPath'] as String? ?? '';
    List<String>? argv;
    bool terminal = false;
    String? cwd;

    if (desktopPath.isEmpty) {
      final prog = app['program'] as String? ?? app['exec'] as String? ?? '';
      if (prog.isEmpty || !isExecutableFile(prog)) throw RouteError('not_installed', trf('{0} is missing', [prog]));
      argv = [prog];
    } else {
      String text;
      try {
        text = File(desktopPath).readAsStringSync();
      } on FileSystemException {
        throw RouteError('not_installed', trf('{0} is missing', [desktopPath]));
      }
      final groups = _parseDesktopGroups(text);
      final entry = groups['Desktop Entry'];
      if (entry == null) throw RouteError('invalid', desktopPath);
      final group = action == null ? entry : groups['Desktop Action $action'];
      if (group == null) throw RouteError('not_found', 'action $action');
      final rawExec = group['Exec'];
      if (rawExec == null || rawExec.isEmpty) throw RouteError('unavailable', tr('no command to run'));
      argv = expandDesktopExec(
        rawExec,
        icon: entry['Icon'] ?? '',
        name: '${app['name']}',
        desktopFile: desktopPath,
      );
      terminal = (entry['Terminal'] ?? '').toLowerCase() == 'true';
      final rawCwd = entry['Path'];
      if (rawCwd != null && rawCwd.isNotEmpty && Directory(rawCwd).existsSync()) cwd = rawCwd;
    }

    if (argv == null || argv.isEmpty) throw RouteError('unavailable', tr('no command to run'));
    var run = argv;
    if (terminal) {
      final term = _defaultTerminal();
      if (term == null) throw RouteError('unavailable', tr('No terminal found'));
      run = [...term, ...run];
    }

    final exe = run.first.contains('/') ? run.first : (ctx.runner.which(run.first) ?? run.first);
    try {
      await Process.start(
        exe,
        run.sublist(1),
        mode: ProcessStartMode.detached,
        workingDirectory: cwd ?? ctx.paths.home,
        environment: {
          ...ctx.environment,
          if (desktopPath.isNotEmpty) 'GIO_LAUNCHED_DESKTOP_FILE': p.absolute(desktopPath),
        },
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      throw RouteError('internal', trf('could not start {0}: {1}', [exe, e.message]));
    }
    return {'id': app['id'], 'opened': true};
  }

  /// `system_apps.open_url` {url}: opens an http(s) URL in the default browser.
  Future<Map<String, dynamic>> openUrl(Map<String, dynamic> params) async {
    final url = params['url'];
    if (url is! String || !_httpUrlRe.hasMatch(url) || url.startsWith('-')) {
      throw RouteError('bad_params', 'url');
    }
    final open = ctx.runner.which('xdg-open');
    if (open == null) throw RouteError('unavailable', tr('xdg-open is missing'));
    if (!await _startDetached(open, [url])) throw RouteError('internal', tr('could not start xdg-open'));
    return {'url': url, 'opened': true};
  }

  /// `system_apps.autostart` {id, on}: enables or disables startup at login for a desktop app.
  Future<Map<String, dynamic>> setAutostart(Map<String, dynamic> params) async {
    final app = await _requireApp(params);
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    final id = app['id'] as String;
    final desktopPath = app['desktopPath'] as String? ?? '';
    if (desktopPath.isEmpty || !id.endsWith('.desktop') || id.contains('/')) {
      throw RouteError('unavailable', tr('This app has no desktop entry'));
    }
    final target = p.join(ctx.paths.autostart, id);
    if (on) {
      Directory(ctx.paths.autostart).createSync(recursive: true);
      if (File(target).existsSync()) {
        ApplicationsService(ctx).setAutostart({'file': id, 'on': true});
      } else {
        atomicWrite(target, File(desktopPath).readAsStringSync());
      }
    } else {
      if (File(target).existsSync()) {
        File(target).deleteSync();
      }
    }
    return {'id': id, 'autostart': on};
  }

  Future<List<String>> _pacmanNeededBy(String pkg) async {
    if (!validSystemPackage(pkg) || _whichTool('pacman') == null) return const [];
    final r = await ctx.runner.run(['pacman', '-Qi', '--', pkg], extraEnv: const {'LC_ALL': 'C'}, timeout: const Duration(seconds: 10));
    if (!r.ok) return const [];
    return parsePacmanRequiredBy(r.stdout);
  }

  /// `system_apps.remove_plan` {id}: what will be removed and any warnings or blockers.
  Future<Map<String, dynamic>> removePlan(Map<String, dynamic> params) async {
    final app = await _requireApp(params);
    final source = app['source'] as String;
    final pkg = app['package'] as Map?;
    final pkgName = pkg?['name'] as String?;
    final version = '${app['version'] ?? ''}';
    final desktopPath = app['desktopPath'] as String? ?? '';
    final program = app['program'] as String?;
    final defaultRoles = (app['defaultRoles'] as List?)?.cast<String>() ?? const <String>[];
    final browser = app['browser'] as String?;

    if (source == 'webapp' && browser != null) {
      final appsPage = _browserAppsPages[browser];
      return {
        'id': app['id'],
        'kind': 'webapp',
        'what': browser,
        'browserAppsPage': appsPage,
        'blocked': trf(
          '{0} is a web app installed in {1}. Open it in {1} and remove it there ({2}).',
          [app['name'], browser, appsPage ?? tr('its apps page')],
        ),
        'defaultRoles': defaultRoles,
        'needsPassword': false,
        'canDeleteData': false,
        'goes': const [],
      };
    }

    if (source == 'flatpak' && pkgName != null) {
      return {
        'id': app['id'],
        'kind': 'flatpak',
        'manager': 'flatpak',
        'what': pkgName,
        'version': version,
        'defaultRoles': defaultRoles,
        'needsPassword': false,
        'canDeleteData': true,
        'goes': [
          {'path': pkgName, 'kind': 'flatpak', 'version': version},
        ],
        'stays': [
          {'path': '~/.var/app/$pkgName', 'why': tr('app data (kept unless deleted)')},
        ],
      };
    }

    if ((source == 'pacman' || source == 'aur') && pkgName != null) {
      final neededBy = await _pacmanNeededBy(pkgName);
      final blocked = neededBy.isEmpty
          ? null
          : trf('{0} is required by {1}: pacman cannot remove it while those packages stay.', [pkgName, neededBy.join(', ')]);
      return {
        'id': app['id'],
        'kind': 'package',
        'manager': source,
        'what': pkgName,
        'version': version,
        'neededBy': neededBy,
        'blocked': ?blocked,
        'defaultRoles': defaultRoles,
        'needsPassword': true,
        'canDeleteData': false,
        'goes': [
          {'path': pkgName, 'kind': 'package', 'version': version, 'manager': source},
        ],
        'stays': [
          {'path': tr('Your personal settings and files'), 'why': tr('pacman never removes files in your home folder')},
        ],
      };
    }

    if (const {'snap', 'apt', 'dnf', 'zypper'}.contains(source) && pkgName != null) {
      return {
        'id': app['id'],
        'kind': 'package',
        'manager': source,
        'what': pkgName,
        'version': version,
        'defaultRoles': defaultRoles,
        'needsPassword': true,
        'canDeleteData': false,
        'goes': [
          {'path': pkgName, 'kind': 'package', 'version': version, 'manager': source},
        ],
      };
    }

    // Standalone AppImage or user-local desktop file -> Trash.
    final trashPaths = <String>[];
    if (source == 'appimage' && program != null && _isWithinHome(program)) {
      trashPaths.add(program);
    }
    if (desktopPath.isNotEmpty && _isUserDesktop(desktopPath, ctx.paths.apps)) {
      trashPaths.add(desktopPath);
    }
    if (trashPaths.isNotEmpty) {
      return {
        'id': app['id'],
        'kind': 'trash',
        'what': trashPaths.first,
        'paths': trashPaths,
        'defaultRoles': defaultRoles,
        'needsPassword': false,
        'canDeleteData': false,
        'goes': [
          for (final tp in trashPaths) {'path': tp, 'kind': 'file', 'why': tr('moved to Trash')},
        ],
      };
    }

    return {
      'id': app['id'],
      'kind': null,
      'blocked': tr('No package or user file owns this app'),
      'defaultRoles': defaultRoles,
      'needsPassword': false,
      'canDeleteData': false,
      'goes': const [],
    };
  }

  // --- System jobs (`system_jobs.*`) -------------------------------------------------------

  String _safeTool(String name) {
    final t = ctx.runner.which(name);
    if (t == null) throw RouteError('unavailable', trf('{0} is missing', [name]));
    if (ctx.paths.root != '/' && (t.startsWith('/usr/') || t.startsWith('/bin/'))) {
      throw RouteError('unsafe', trf('{0} would be the system\'s ({1}) with a test root ({2}): refused', [name, t, ctx.paths.root]));
    }
    return t;
  }

  /// `system_jobs.start` {app, kind, options?}.
  Future<Map<String, dynamic>> jobStart(Map<String, dynamic> params) async {
    final appId = params['app'];
    final kind = params['kind'];
    final options = params['options'] is Map ? Map<String, dynamic>.from(params['options'] as Map) : <String, dynamic>{};
    if (appId is! String || appId.isEmpty || kind is! String || !const {'update', 'reinstall', 'remove'}.contains(kind)) {
      throw RouteError('bad_params', 'app, kind');
    }

    // Special virtual ids for batched pacman / AUR updates.
    Map<String, dynamic>? app;
    String displayName;
    if (appId == '_pacman_system' && kind == 'update') {
      displayName = tr('System packages');
    } else if (appId == '_aur_all' && kind == 'update') {
      displayName = tr('AUR');
    } else {
      app = await _requireApp({'id': appId});
      displayName = '${app['name']}';
    }

    final id = 'sys-${ctx.clock().millisecondsSinceEpoch}-${++_seq}';
    final logPath = p.join(ctx.paths.managerState, 'system-jobs', '$id.log');
    final jobMap = <String, dynamic>{
      'id': id,
      'app': appId,
      'name': displayName,
      'kind': kind,
      'options': options,
      'state': 'queued',
      'phase': 'queued',
      'cancellable': true,
      'committed': false,
      'result': <String, dynamic>{},
      '_app': ?app,
    };
    final run = _SysJob(jobMap, JobLog(logPath));
    _jobs[id] = run;
    _queue.add(run);
    _pump();
    return _publicJob(run);
  }

  Map<String, dynamic> jobGet(Map<String, dynamic> params) {
    final id = params['id'];
    final run = id is String ? _jobs[id] : null;
    if (run == null) throw RouteError('not_found', 'job $id');
    return _publicJob(run);
  }

  Map<String, dynamic> jobLog(Map<String, dynamic> params) {
    final id = params['id'];
    final from = params['from'] is int ? params['from'] as int : 0;
    final run = id is String ? _jobs[id] : null;
    if (run == null) throw RouteError('not_found', 'job $id');
    final file = File(run.log.path);
    var text = '';
    var next = from;
    if (file.existsSync()) {
      final bytes = file.readAsBytesSync();
      if (from < bytes.length) {
        final slice = bytes.sublist(from, bytes.length > from + 256 * 1024 ? from + 256 * 1024 : bytes.length);
        text = utf8.decode(slice, allowMalformed: true);
        next = from + slice.length;
      }
    }
    return {
      'id': id,
      'text': text,
      'next': next,
      'finished': run.done.isCompleted,
    };
  }

  Map<String, dynamic> jobCancel(Map<String, dynamic> params) {
    final id = params['id'];
    final run = id is String ? _jobs[id] : null;
    if (run == null) throw RouteError('not_found', 'job $id');
    if (run.done.isCompleted) return _publicJob(run);
    if (run.committed) throw RouteError('not_cancellable', tr('It has started changing files'));
    run.cancelRequested = true;
    if (run != _running) {
      _queue.remove(run);
      run.job['state'] = 'cancelled';
      run.job['cancellable'] = false;
      run.job['result'] = {'ok': false, 'code': 'cancelled'};
      run.log.note(tr('Cancelled before starting'));
      run.log.close();
      run.done.complete(run.job['result'] as Map<String, dynamic>);
    } else {
      run.process?.kill(ProcessSignal.sigterm);
    }
    return _publicJob(run);
  }

  Map<String, dynamic> _publicJob(_SysJob r) => {
    for (final e in r.job.entries)
      if (!e.key.startsWith('_')) e.key: e.value,
  };

  void _pump() {
    if (_running != null || _queue.isEmpty) return;
    final next = _queue.removeFirst();
    _running = next;
    unawaited(_execute(next).whenComplete(() {
      _running = null;
      _pump();
    }));
  }

  Future<void> _execute(_SysJob r) async {
    r.job['state'] = 'running';
    r.job['phase'] = 'prepare';
    try {
      final res = await _runJob(r);
      if (r.cancelRequested) {
        r.job['state'] = 'cancelled';
        r.job['cancellable'] = false;
        r.job['result'] = {'ok': false, 'code': 'cancelled'};
      } else {
        r.job['state'] = 'succeeded';
        r.job['phase'] = 'finish';
        r.job['cancellable'] = false;
        r.job['result'] = {'ok': true, ...res};
      }
      // Invalidate caches so list() reflects the change right away.
      _pacmanDbStamp = null;
      if (r.kind == 'update' || r.kind == 'remove') {
        _lastUpdateCheck = null;
        _pacmanUpdates = const {};
        _aurUpdates = const {};
        _flatpakUpdates = const {};
      }
    } on RouteError catch (e) {
      r.log.note('${e.code}: ${e.message ?? ''}');
      r.job['state'] = 'failed';
      r.job['cancellable'] = false;
      r.job['result'] = {'ok': false, 'code': e.code, 'message': e.message ?? e.code};
    } on Object catch (e) {
      r.log.note('$e');
      r.job['state'] = 'failed';
      r.job['cancellable'] = false;
      r.job['result'] = {'ok': false, 'code': 'failed', 'message': '$e'};
    } finally {
      r.log.close();
      if (!r.done.isCompleted) r.done.complete(r.job['result'] as Map<String, dynamic>);
    }
  }

  Future<Map<String, dynamic>> _runJob(_SysJob r) async {
    final options = r.job['options'] as Map<String, dynamic>;
    if (r.app == '_pacman_system' && r.kind == 'update') {
      return _runPacmanTx(r, ['-Syu', '--noconfirm'], tr('updating system packages'));
    }
    if (r.app == '_aur_all' && r.kind == 'update') {
      final helper = _aurHelper();
      if (helper == null) throw RouteError('unavailable', tr('No AUR helper found (paru or yay)'));
      return _openInTerminal(r, '$helper -Sua', const [], tr('Updating AUR packages in terminal'));
    }

    final app = (r.job['_app'] as Map<String, dynamic>?) ?? await _requireApp({'id': r.app});
    final source = app['source'] as String;
    final pkgName = (app['package'] as Map?)?['name'] as String?;

    if (r.kind == 'remove') {
      final plan = await removePlan({'id': r.app});
      if (plan['blocked'] != null) throw RouteError('blocked', '${plan['blocked']}');
      switch (plan['kind']) {
        case 'trash':
          r.committed = true;
          r.job['committed'] = true;
          r.job['cancellable'] = false;
          r.job['phase'] = 'commit';
          final paths = (plan['paths'] as List?)?.cast<String>() ?? [plan['what'] as String];
          final moved = <String>[];
          for (final tp in paths) {
            final dest = moveFileToTrash(tp, ctx);
            if (dest == null) throw RouteError('failed', trf('Could not move {0} to Trash', [tp]));
            r.log.note(trf('Moved {0} to Trash ({1})', [tp, dest]));
            moved.add(dest);
          }
          return {'removed': true, 'trash': moved};
        case 'flatpak':
          final fid = plan['what'] as String;
          if (!_flatpakIdRe.hasMatch(fid)) throw RouteError('bad_params', fid);
          final args = ['uninstall', '-y', '--noninteractive', if (options['delete_data'] == true) '--delete-data', fid];
          await _runStreaming(r, _safeTool('flatpak'), args);
          return {'removed': true};
        case 'package':
          final manager = plan['manager'] as String;
          final what = plan['what'] as String;
          if (!validSystemPackage(what)) throw RouteError('bad_params', what);
          if (manager == 'pacman' || manager == 'aur') {
            return _runPacmanTx(r, ['-Rns', '--noconfirm', '--', what], trf('removing {0}', [what]));
          }
          final cmd = switch (manager) {
            'snap' => ['/usr/bin/snap', 'remove', '--', what],
            'apt' => ['/usr/bin/apt-get', 'remove', '-y', '--', what],
            'dnf' => ['/usr/bin/dnf', 'remove', '-y', '--', what],
            'zypper' => ['/usr/bin/zypper', '--non-interactive', 'remove', '--', what],
            _ => null,
          };
          if (cmd == null) throw RouteError('unavailable', trf('Unsupported package manager: {0}', [manager]));
          return _runPkexecCmd(r, cmd, trf('removing {0}', [what]));
        default:
          throw RouteError('unavailable', tr('This app cannot be uninstalled here'));
      }
    }

    if (r.kind == 'update') {
      if (source == 'flatpak' && pkgName != null && _flatpakIdRe.hasMatch(pkgName)) {
        await _runStreaming(r, _safeTool('flatpak'), ['update', '-y', '--noninteractive', pkgName]);
        return {'updated': true};
      }
      if (source == 'pacman') {
        r.log.note(tr('pacman upgrades all system packages together to avoid partial upgrades'));
        return _runPacmanTx(r, ['-Syu', '--noconfirm'], tr('updating system packages'));
      }
      if (source == 'aur' && pkgName != null && validSystemPackage(pkgName)) {
        final helper = _aurHelper();
        if (helper == null) throw RouteError('unavailable', tr('No AUR helper found (paru or yay)'));
        return _openInTerminal(r, '$helper -S -- "\$1"', [pkgName], trf('Updating {0} in terminal', [pkgName]));
      }
      throw RouteError('unavailable', tr('No update method for this app'));
    }

    if (r.kind == 'reinstall') {
      if (source == 'flatpak' && pkgName != null && _flatpakIdRe.hasMatch(pkgName)) {
        await _runStreaming(r, _safeTool('flatpak'), ['install', '--reinstall', '-y', '--noninteractive', pkgName]);
        return {'reinstalled': true};
      }
      if (source == 'pacman' && pkgName != null && validSystemPackage(pkgName)) {
        return _runPacmanTx(r, ['-S', '--noconfirm', '--', pkgName], trf('reinstalling {0}', [pkgName]));
      }
      if (source == 'aur' && pkgName != null && validSystemPackage(pkgName)) {
        final helper = _aurHelper();
        if (helper == null) throw RouteError('unavailable', tr('No AUR helper found (paru or yay)'));
        return _openInTerminal(r, '$helper -S -- "\$1"', [pkgName], trf('Reinstalling {0} in terminal', [pkgName]));
      }
      throw RouteError('unavailable', tr('This app cannot be reinstalled here'));
    }

    throw RouteError('bad_params', r.kind);
  }

  Future<Map<String, dynamic>> _openInTerminal(_SysJob r, String command, List<String> args, String note) async {
    final term = _defaultTerminal();
    if (term == null) throw RouteError('unavailable', tr('No terminal found'));
    r.job['phase'] = 'commit';
    r.committed = true;
    r.job['committed'] = true;
    r.job['cancellable'] = false;
    final shellCmd = "$command; echo; read -r -p 'Press Enter to close. ' _";
    final full = [...term, 'sh', '-c', shellCmd, 'maprisma-settings', ...args];
    r.log.note('$note: $command ${args.join(' ')}');
    final ok = await _startDetached(full.first, full.sublist(1));
    if (!ok) throw RouteError('failed', tr('Could not open terminal'));
    return {'started_in_terminal': true, 'message': tr('Opened in your terminal')};
  }

  Future<void> _runStreaming(_SysJob r, String exe, List<String> args) async {
    r.job['phase'] = 'commit';
    r.log.note('\$ ${p.basename(exe)} ${args.join(' ')}');
    final Process proc;
    try {
      proc = await Process.start(
        exe,
        args,
        environment: ctx.environment,
        includeParentEnvironment: false,
        workingDirectory: ctx.paths.home,
      );
    } on ProcessException catch (e) {
      throw RouteError('failed', e.message);
    }
    r.process = proc;
    await proc.stdin.close();
    void out(List<int> d) {
      r.log.add(d);
      r.remember(d);
    }

    final outDone = proc.stdout.listen(out).asFuture<void>();
    final errDone = proc.stderr.listen(out).asFuture<void>();
    final code = await proc.exitCode;
    r.process = null;
    try {
      await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // keep what came
    }
    if (r.cancelRequested) return;
    if (code != 0) throw RouteError('failed', trf('{0} failed (exit {1})', [p.basename(exe), code]));
  }

  Future<Map<String, dynamic>> _runPacmanTx(_SysJob r, List<String> args, String what) async {
    final lock = ctx.paths.sys(pacmanLockFile);
    if (FileSystemEntity.typeSync(lock, followLinks: false) != FileSystemEntityType.notFound) {
      throw RouteError('pacman_locked', trf('pacman\'s database is locked ({0}): nothing was changed', [pacmanLockFile]));
    }
    final pacmanExe = _safeTool('pacman');
    final target = ctx.paths.root == '/' ? '/usr/bin/pacman' : pacmanExe;
    return _runPkexecCmd(r, [target, ...args], what);
  }

  Future<Map<String, dynamic>> _runPkexecCmd(_SysJob r, List<String> cmd, String what) async {
    final pk = _safeTool('pkexec');
    r.committed = true;
    r.job['committed'] = true;
    r.job['cancellable'] = false;
    r.job['phase'] = 'commit';
    r.log.note(trf('\$ pkexec {0}   (a password dialog asks for the administrator password)', [cmd.join(' ')]));
    r.recent.clear();
    final Process proc;
    try {
      proc = await Process.start(
        pk,
        cmd,
        environment: ctx.environment,
        includeParentEnvironment: false,
        workingDirectory: ctx.paths.home,
      );
    } on ProcessException catch (e) {
      throw RouteError('failed', trf('pkexec could not start: {0}', [e.message]));
    }
    r.job['pkexec'] = {'pid': proc.pid, 'start': procStat(proc.pid)?.start};
    await proc.stdin.close();
    void out(List<int> d) {
      r.log.add(d);
      r.remember(d);
    }

    final outDone = proc.stdout.listen(out).asFuture<void>();
    final errDone = proc.stderr.listen(out).asFuture<void>();
    var exited = false;
    final codeFut = proc.exitCode.then((c) {
      exited = true;
      return c;
    });
    final until = DateTime.now().add(_pkexecWait);
    var authenticated = false;
    var ended = false;
    String? comm() {
      try {
        return File('/proc/${proc.pid}/comm').readAsStringSync().trim();
      } on FileSystemException {
        return null;
      }
    }

    while (!exited) {
      await Future.any([codeFut, Future<void>.delayed(const Duration(milliseconds: 200))]);
      if (exited) break;
      if (!authenticated) {
        final n = comm();
        if (n != null && n != 'pkexec') {
          authenticated = true;
          r.log.note(trf('authenticated: {0} runs', [n]));
        } else if (DateTime.now().isAfter(until)) {
          if (comm() == 'pkexec') {
            proc.kill(ProcessSignal.sigterm);
            ended = true;
            break;
          }
        }
      }
    }
    final code = await codeFut;
    try {
      await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // ignore
    }
    final effective = ended && !authenticated ? -126 : code;
    r.log.note(trf('pkexec exit code {0}', [effective]));
    if (effective == -126) {
      throw RouteError('auth_timeout', trf('the password dialog was not answered within {0} s: {1} not started; nothing was changed', [_pkexecWait.inSeconds, what]));
    }
    if (effective == 126 || effective == 127) {
      throw RouteError('auth_cancelled', trf('authentication was cancelled or refused (pkexec exit {0}): {1} not started; nothing was changed', [effective, what]));
    }
    if (effective != 0) {
      if (r.recent.toString().contains('unable to lock database')) {
        throw RouteError('pacman_locked', trf('pacman\'s database is locked ({0}): nothing was changed', [pacmanLockFile]));
      }
      throw RouteError('failed', trf('{0} failed (exit {1})', [what, effective]));
    }
    return {'done': true};
  }
}
