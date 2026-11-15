/// Ask AI rules, shared by every Maprisma app (docs/ask-ai-rules.md): the `ask_ai` key of
/// `maprisma-ai/settings.json` (level, actions, sources, folders, data) and the log of what Ask AI
/// changed, `$XDG_STATE_HOME/maprisma-ai/actions.jsonl`. Only Settings writes `ask_ai`; every app
/// reads it and enforces it in its own core.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../paths.dart';
import 'posix.dart';
import 'shared_helper.dart';

/// Overall level: actions allowed by the switches (each with its review), or answers only.
const askAiLevels = ['review', 'answers'];

/// One switchable thing on the AI page.
typedef AskAiItem = ({String id, String app, String label});

/// Every action Ask AI can run (docs/ask-ai-rules.md); the page lists them in this order.
const List<AskAiItem> askAiActions = [
  (id: 'launcher.install', app: 'launcher', label: 'Install apps'),
  (id: 'launcher.remove', app: 'launcher', label: 'Uninstall apps'),
  (id: 'launcher.update', app: 'launcher', label: 'Update apps'),
  (id: 'launcher.update_system', app: 'launcher', label: 'Update the system'),
  (id: 'launcher.hide', app: 'launcher', label: 'Hide and unhide apps'),
  (id: 'launcher.shortcuts', app: 'launcher', label: 'Change keyboard shortcuts'),
  (id: 'theme.apply', app: 'theme', label: 'Apply a theme or wallpaper'),
  (id: 'theme.install', app: 'theme', label: 'Install themes from the catalog'),
  (id: 'theme.edit', app: 'theme', label: 'Create and save custom themes'),
  (id: 'theme.generate', app: 'theme', label: 'Generate pictures'),
  (id: 'theme.wallpapers', app: 'theme', label: 'Add wallpapers'),
  (id: 'settings.updates', app: 'settings', label: 'Update Maprisma apps'),
  (id: 'mail.draft', app: 'mail', label: 'Write drafts and accept AI changes'),
  (id: 'mail.label', app: 'mail', label: 'Add and remove labels'),
  (id: 'mail.archive', app: 'mail', label: 'Archive and unarchive'),
  (id: 'mail.flags', app: 'mail', label: 'Mark read and star'),
  (id: 'mail.move', app: 'mail', label: 'Move to folders'),
  (id: 'mail.trash', app: 'mail', label: 'Move to trash and mark as spam'),
  (id: 'mail.event', app: 'mail', label: 'Create calendar events'),
  (id: 'mail.reminder', app: 'mail', label: 'Create reminders'),
];

/// What an app may send to the AI helper (docs/ask-ai-rules.md, data ids): every Ask AI call of
/// the app, answers too, whatever the level is.
const List<AskAiItem> askAiData = [
  (id: 'mail.online', app: 'mail', label: 'Use online AI helpers'),
  (id: 'mail.attachments', app: 'mail', label: 'Send the text of attachments you pick'),
  (id: 'mail.tone_samples', app: 'mail', label: 'Send the sent-mail snippets you reviewed to refine your tone'),
];

/// Ids that are off unless switched on: only a stored `true` allows them, a missing id is off and a
/// reset leaves them off (docs/ask-ai-rules.md, Uwe 2026-11-15).
const Set<String> askAiDefaultOff = {'mail.move', 'mail.trash', 'mail.attachments'};

/// Whether a stored switch allows [id]: `false` is off; missing is on, except for [askAiDefaultOff].
bool askAiSwitchOn(Map<String, bool> stored, String id) =>
    askAiDefaultOff.contains(id) ? stored[id] == true : stored[id] != false;

/// Install sources of the Launcher's Ask AI.
const List<AskAiItem> askAiSources = [
  (id: 'pacman', app: 'launcher', label: 'Official repositories (pacman)'),
  (id: 'aur', app: 'launcher', label: 'AUR'),
  (id: 'flatpak', app: 'launcher', label: 'Flatpak'),
  (id: 'apt', app: 'launcher', label: 'apt'),
  (id: 'dnf', app: 'launcher', label: 'dnf'),
  (id: 'zypper', app: 'launcher', label: 'zypper'),
  (id: 'snap', app: 'launcher', label: 'Snap'),
  (id: 'github', app: 'launcher', label: 'GitHub releases'),
  (id: 'local', app: 'launcher', label: 'AppImages in Downloads'),
];

/// Folders Ask AI may look into.
const List<AskAiItem> askAiFolders = [
  (id: 'downloads', app: 'launcher', label: 'Downloads (AppImages to install)'),
];

/// Steps that only answer (no switch; listed so the page shows the whole picture).
const List<AskAiItem> askAiAnswers = [
  (id: 'launcher.answers', app: 'launcher', label: 'Suggest and explain apps'),
  (id: 'theme.answers', app: 'theme', label: 'Suggest themes and wallpapers'),
  (id: 'notifier.check', app: 'notifier', label: 'Check a crash notification'),
  (id: 'playground.chat', app: 'playground', label: 'Chat'),
  (id: 'mail.answers', app: 'mail', label: 'Summaries, reply and rewrite suggestions, questions about a thread'),
];

final _id = RegExp(r'^[a-z][a-z0-9_.]{0,63}$');

/// The `ask_ai` object as stored (unknown ids kept); defaults when missing or invalid.
typedef AskAiRuleSet = ({
  String level,
  Map<String, bool> actions,
  Map<String, bool> sources,
  Map<String, bool> folders,
  Map<String, bool> data,
  bool broken,
});

/// Every data id off: what an unreadable file or an `ask_ai` that isn't an object means for data
/// (restrictive; the level alone wouldn't stop answers from sending).
Map<String, bool> _allDataOff() => {for (final i in askAiData) i.id: false};

AskAiRuleSet readAskAiRules(Paths paths) {
  // An existing file that can't be read, or an ask_ai that isn't an object: restrictive.
  if (sharedFileBroken(paths)) {
    return (level: 'answers', actions: {}, sources: {}, folders: {}, data: _allDataOff(), broken: true);
  }
  final whole = readSharedObject(paths);
  // Missing = defaults; present but not an object (null too) = restrictive (contract).
  if (whole == null || !whole.containsKey('ask_ai')) {
    return (level: 'review', actions: {}, sources: {}, folders: {}, data: {}, broken: false);
  }
  final raw = whole['ask_ai'];
  if (raw is! Map) return (level: 'answers', actions: {}, sources: {}, folders: {}, data: _allDataOff(), broken: true);
  var broken = false;
  // Malformed values are restrictive (docs/ask-ai-rules.md): a map that isn't an object switches
  // all of its kind off, a known id with a non-boolean value is off.
  Map<String, bool> map(String key, List<AskAiItem> known) {
    if (!raw.containsKey(key)) return {};
    final v = raw[key];
    if (v is! Map) {
      broken = true;
      return {for (final i in known) i.id: false};
    }
    final out = <String, bool>{};
    for (final e in v.entries) {
      if (e.key is! String || !_id.hasMatch(e.key as String)) continue;
      if (e.value is bool) {
        out[e.key as String] = e.value as bool;
      } else if (known.any((i) => i.id == e.key)) {
        broken = true;
        out[e.key as String] = false;
      }
    }
    return out;
  }

  final level = raw['level'];
  final actions = map('actions', askAiActions), sources = map('sources', askAiSources), folders = map('folders', askAiFolders);
  final data = map('data', askAiData);
  final hasLevel = raw.containsKey('level');
  if (hasLevel && !askAiLevels.contains(level)) broken = true;
  return (
    level: !hasLevel ? 'review' : (askAiLevels.contains(level) ? level as String : 'answers'),
    actions: actions,
    sources: sources,
    folders: folders,
    data: data,
    broken: broken,
  );
}

/// The decision every app makes (here for Settings' own AI updates and the page's summary).
bool askAiAllowed(Paths paths, String action, {String? source}) {
  final r = readAskAiRules(paths);
  return r.level != 'answers' &&
      askAiSwitchOn(r.actions, action) &&
      (source == null || askAiSwitchOn(r.sources, source)) &&
      (source != 'local' || askAiSwitchOn(r.folders, 'downloads'));
}

/// May the app send this data to the AI helper (any level, answers too).
bool askAiDataAllowed(Paths paths, String id) => askAiSwitchOn(readAskAiRules(paths).data, id);

/// Changes one switch (`kind` actions/sources/folders/data) or the level, keeping every other key.
void writeAskAiRule(Paths paths, {String? level, String? kind, String? id, bool? on}) {
  if (level != null) {
    if (!askAiLevels.contains(level)) throw ArgumentError.value(level, 'level');
  }
  if (kind != null) {
    final known = switch (kind) {
      'actions' => askAiActions,
      'sources' => askAiSources,
      'folders' => askAiFolders,
      'data' => askAiData,
      _ => throw ArgumentError.value(kind, 'kind'),
    };
    if (id == null || !known.any((i) => i.id == id) || on == null) throw ArgumentError.value(id, 'id');
  }
  updateSharedObject(paths, (whole) {
    final raw = whole['ask_ai'];
    if (whole.containsKey('ask_ai') && raw is! Map) {
      throw FileSystemException('The rules must be reset first', sharedAiFile(paths));
    }
    final next = <String, dynamic>{...?raw as Map<String, dynamic>?};
    if (level != null) next['level'] = level;
    if (kind != null) {
      final entries = next[kind];
      if (next.containsKey(kind) && entries is! Map) {
        throw FileSystemException('The rules must be reset first', sharedAiFile(paths));
      }
      next[kind] = <String, dynamic>{...?entries as Map<String, dynamic>?, id!: on};
    }
    whole['ask_ai'] = next;
  });
}

/// Resets the rules to the defaults (the page's answer to a broken file): writes a fresh file that
/// keeps nothing of the unreadable one except what can't be lost (helper → auto).
void resetAskAiRules(Paths paths) {
  updateSharedObject(paths, (whole) {
    // default-off ids (askAiDefaultOff) stay off: missing means off for them
    whole['ask_ai'] = {'level': 'review', 'actions': {}, 'sources': {}, 'folders': {}, 'data': {}};
  }, reset: true);
}

// ---------------------------------------------------------------- the log

const askAiLogMax = 1000, askAiLogKeep = 500, askAiLogBytes = 1 << 20;

String askAiLogFile(Paths paths) => p.join(paths.state, sharedAiDir, 'actions.jsonl');

String askAiLogLock(Paths paths) => p.join(paths.state, sharedAiDir, 'actions.lock');

/// Appends one entry under the log's lock (docs/ask-ai-rules.md: lock first, then open the data
/// file; trim to the newest [askAiLogKeep] above [askAiLogMax]). A failure never stops a step.
void appendAskAiLog(Paths paths,
    {required String op, required String app, required String action, required String target, required String result}) {
  final path = askAiLogFile(paths);
  try {
    final dir = Directory(p.dirname(path))..createSync(recursive: true);
    // a real folder of the user (no link), else nothing is logged
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) != FileSystemEntityType.directory ||
        Posix.instance.ownerOf(dir.path, follow: false) != Posix.instance.uid) {
      return;
    }
    chmodPath(dir.path, 0x1c0);
    Posix.instance.withFlock(askAiLogLock(paths), () {
      if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.link) return;
      final entry = {
        'time': DateTime.now().toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
        'op': op,
        'app': app,
        'action': action,
        'target': target.length > 200 ? target.substring(0, 200) : target,
        'result': result,
      };
      if (!Posix.instance.appendPrivate(path, utf8.encode('${jsonEncode(entry)}\n'))) return;
      final tail = Posix.instance.readOwnedTail(path, askAiLogBytes);
      if (tail == null) return;
      var content = utf8.decode(tail.$1, allowMalformed: true);
      if (tail.$2 > askAiLogBytes) content = content.substring(content.indexOf('\n') + 1);
      final lines = content.split('\n');
      final complete = lines.sublist(0, lines.length - 1);
      if (complete.length > askAiLogMax || tail.$2 > askAiLogBytes) {
        final keep = complete.length > askAiLogKeep ? complete.sublist(complete.length - askAiLogKeep) : complete;
        final tmp = File(p.join(dir.path, '.actions.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp'));
        if (!Posix.instance.writeNewPrivate(tmp.path, utf8.encode('${keep.join('\n')}\n'))) return;
        try { tmp.renameSync(path); } finally { if (tmp.existsSync()) tmp.deleteSync(); }
      }
    });
  } on Object {
    // a record only
  }
}

/// The newest [limit] entries, newest first (malformed lines skipped).
List<Map<String, dynamic>> readAskAiLog(Paths paths, {int limit = 100}) {
  final path = askAiLogFile(paths);
  if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return [];
  final out = <Map<String, dynamic>>[];
  // at most the last MiB; the first (possibly cut) and an unterminated last line are skipped
  final tail = Posix.instance.readOwnedTail(path, askAiLogBytes);
  if (tail == null) return [];
  var text = utf8.decode(tail.$1, allowMalformed: true);
  if (tail.$2 > askAiLogBytes) text = text.substring(text.indexOf('\n') + 1);
  final lines = text.split('\n')..removeLast();
  for (final line in lines.reversed) {
    try {
      final v = jsonDecode(line);
      if (v is Map<String, dynamic> && v['time'] is String && v['app'] is String && v['action'] is String) out.add(v);
    } on FormatException {
      continue;
    }
    if (out.length >= limit) break;
  }
  return out;
}

/// Empties the log (under its lock).
void clearAskAiLog(Paths paths) {
  final path = askAiLogFile(paths);
  final dir = p.dirname(path);
  if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.directory ||
      Posix.instance.ownerOf(dir, follow: false) != Posix.instance.uid) {
    return;
  }
  Posix.instance.withFlock(askAiLogLock(paths), () => Posix.instance.clearPrivate(path));
}

// ---------------------------------------------------------------- Mail installed?

/// Whether Maprisma Mail is installed (docs/ask-ai-rules.md, "Showing Mail's part"): the first
/// `com.maprisma.Mail.desktop` in `$XDG_DATA_HOME/applications`, then `$XDG_DATA_DIRS/*/applications`
/// (default /usr/local/share:/usr/share, under [Paths.root]), whose `Exec` program (first word, `~`
/// and variables not expanded; a bare name is looked up in PATH; links resolved) is an executable
/// file with `bin/omamail` and `lib/libapp.so` next to it. Nothing is started.
bool mailInstalled(Paths paths, Map<String, String> environment) {
  final dataDirs = (environment['XDG_DATA_DIRS'] ?? '').split(':').where((d) => d.isNotEmpty && p.isAbsolute(d)).toList();
  final dirs = [
    paths.apps,
    for (final d in dataDirs.isEmpty ? ['/usr/local/share', '/usr/share'] : dataDirs) paths.sys(p.join(d, 'applications')),
  ];
  for (final dir in dirs) {
    final desktop = File(p.join(dir, 'com.maprisma.Mail.desktop'));
    String text;
    try {
      if (!desktop.existsSync()) continue;
      text = desktop.readAsStringSync();
    } on Object {
      continue;
    }
    // the first file found is the one the desktop uses (XDG: the user's hides the system's)
    return _mailBundle(_execProgram(text), environment);
  }
  return false;
}

/// The first word of the [Desktop Entry] group's Exec (double quotes and backslash escapes removed).
String? _execProgram(String desktopText) {
  var inEntry = false;
  for (final raw in desktopText.split('\n')) {
    final l = raw.trim();
    if (l.startsWith('[')) {
      inEntry = l == '[Desktop Entry]';
      continue;
    }
    if (!inEntry || !l.startsWith('Exec')) continue;
    final eq = l.indexOf('=');
    if (eq < 0 || l.substring(0, eq).trim() != 'Exec') continue;
    final v = l.substring(eq + 1).trim();
    if (v.isEmpty) return null;
    if (v.startsWith('"')) {
      final out = StringBuffer();
      for (var i = 1; i < v.length; i++) {
        final c = v[i];
        if (c == '\\' && i + 1 < v.length) {
          out.write(v[++i]);
        } else if (c == '"') {
          return out.toString();
        } else {
          out.write(c);
        }
      }
      return null; // unterminated quote
    }
    return v.split(RegExp(r'\s+')).first;
  }
  return null;
}

bool _mailBundle(String? program, Map<String, String> environment) {
  if (program == null || program.isEmpty) return false;
  final candidates = program.contains('/')
      ? [if (p.isAbsolute(program)) program]
      : [
          for (final d in (environment['PATH'] ?? '').split(':'))
            if (d.isNotEmpty && p.isAbsolute(d)) p.join(d, program),
        ];
  for (final c in candidates) {
    try {
      if (FileSystemEntity.typeSync(c) != FileSystemEntityType.file) continue;
      final real = File(c).resolveSymbolicLinksSync();
      final stat = File(real).statSync();
      if (stat.type != FileSystemEntityType.file || stat.mode & 0x49 == 0) continue;
      final dir = p.dirname(real);
      return FileSystemEntity.typeSync(p.join(dir, 'bin/omamail')) == FileSystemEntityType.file &&
          FileSystemEntity.typeSync(p.join(dir, 'lib/libapp.so')) == FileSystemEntityType.file;
    } on Object {
      continue;
    }
  }
  return false;
}

/// `ai.rules`: the stored rules, what each switch means, and the effective state per item. Mail's
/// items (actions, data, answers) are left out while Mail isn't installed ([mailInstalled]); their
/// stored switches are kept.
Map<String, dynamic> askAiRulesView(Paths paths, {Map<String, String> environment = const {}}) {
  final r = readAskAiRules(paths);
  final mail = mailInstalled(paths, environment);
  bool shown(AskAiItem i) => i.app != 'mail' || mail;
  List<Map<String, dynamic>> items(List<AskAiItem> list, Map<String, bool> stored, String kind) => [
        for (final i in list.where(shown))
          {
            'id': i.id,
            'app': i.app,
            'label': i.label,
            'on': askAiSwitchOn(stored, i.id),
            'default_off': askAiDefaultOff.contains(i.id),
            // data ids apply whatever the level is
            'effective': (kind == 'data' || r.level != 'answers') && askAiSwitchOn(stored, i.id) &&
                (kind != 'sources' || askAiSwitchOn(r.actions, 'launcher.install')) &&
                (kind != 'sources' || i.id != 'local' || askAiSwitchOn(r.folders, 'downloads')),
          },
      ];
  return {
    'level': r.level,
    'broken': r.broken,
    'answers_only_error': sharedFileBroken(paths) ||
        (readSharedObject(paths)?.containsKey('ask_ai') == true && readSharedObject(paths)?['ask_ai'] is! Map),
    'actions': items(askAiActions, r.actions, 'actions'),
    'sources': items(askAiSources, r.sources, 'sources'),
    'folders': items(askAiFolders, r.folders, 'folders'),
    'data': items(askAiData, r.data, 'data'),
    'answers': [for (final i in askAiAnswers.where(shown)) {'id': i.id, 'app': i.app, 'label': i.label}],
    'mail_installed': mail,
  };
}
