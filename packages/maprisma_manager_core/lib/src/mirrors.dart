import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'translations.dart';

/// The Optimize page's Rank mirrors (`mirrors.*`): CachyOS's `cachyos-rate-mirrors` tests the
/// Arch and CachyOS mirrors (rate-mirrors) and writes the fastest first into
/// /etc/pacman.d/{mirrorlist,cachyos-mirrorlist,cachyos-v3-mirrorlist,cachyos-v4-mirrorlist},
/// keeping the lists before as `<file>-backup`. Its timer `cachyos-rate-mirrors.timer` does the
/// same about every ten days.
///
/// Ranking needs root: it runs detached as `pkexec /usr/bin/cachyos-rate-mirrors` (polkit's
/// agent asks for the password) with its output in the state folder, so the page can follow it
/// with `mirrors.get`. The timer and the backups go through polkit too (systemctl, pkexec).
final class MirrorsService {
  MirrorsService(this.ctx, this.startDetached);

  final Ctx ctx;
  final Future<bool> Function(String exe, [List<String> args]) startDetached;

  static const tool = 'cachyos-rate-mirrors', timer = 'cachyos-rate-mirrors.timer';
  static const _polkit = Duration(minutes: 2);

  /// The lists the page shows: [id, file] (the v3/v4 lists are copies of the CachyOS one).
  static const lists = [('arch', 'mirrorlist'), ('cachyos', 'cachyos-mirrorlist')];

  /// Every list the tool writes and backs up.
  static const allFiles = ['mirrorlist', 'cachyos-mirrorlist', 'cachyos-v3-mirrorlist', 'cachyos-v4-mirrorlist'];

  String get pacmanDir => p.join(ctx.paths.root, 'etc', 'pacman.d');
  String get _stateDir => p.join(ctx.paths.state, 'maprisma-settings', 'mirrors');
  File get _log => File(p.join(_stateDir, 'rank.log'));
  File get _exit => File(p.join(_stateDir, 'rank.exit'));
  File get _pid => File(p.join(_stateDir, 'rank.pid'));
  File get _started => File(p.join(_stateDir, 'rank.started'));

  /// `mirrors.get`: is the tool there, the timer, the lists and the last or running ranking.
  Future<Map<String, dynamic>> get() async {
    final available = ctx.runner.which(tool) != null && ctx.runner.which('rate-mirrors') != null;
    return {
      'available': available,
      'pkexec': ctx.runner.which('pkexec') != null,
      'timer': available ? await _timer() : null,
      'lists': [for (final (id, file) in lists) _list(id, file)],
      'backups': allFiles.every((f) => File(p.join(pacmanDir, '$f-backup')).existsSync()),
      'run': _run(),
    };
  }

  Future<Map<String, dynamic>?> _timer() async {
    if (ctx.runner.which('systemctl') == null) return null;
    final r = await ctx.runner.run(
      ['systemctl', 'show', timer, '--timestamp=unix', '-p', 'UnitFileState', '-p', 'ActiveState', '-p', 'NextElapseUSecRealtime', '-p', 'LastTriggerUSec'],
      timeout: const Duration(seconds: 5),
    );
    if (!r.ok) return null;
    final v = {
      for (final l in r.stdout.split('\n'))
        if (l.contains('=')) l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1).trim(),
    };
    if ((v['UnitFileState'] ?? '').isEmpty) return null;
    return {
      'enabled': v['UnitFileState'] == 'enabled',
      'active': v['ActiveState'] == 'active',
      'next': _unix(v['NextElapseUSecRealtime']),
      'last': _unix(v['LastTriggerUSec']),
    };
  }

  /// `@1795819962` → ISO time; empty or 0 → null.
  static String? _unix(String? v) {
    final s = int.tryParse((v ?? '').replaceFirst('@', ''));
    if (s == null || s <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(s * 1000).toIso8601String();
  }

  Map<String, dynamic> _list(String id, String name) {
    final f = File(p.join(pacmanDir, name));
    if (!f.existsSync()) return {'id': id, 'file': f.path, 'exists': false};
    List<String> lines;
    try {
      lines = f.readAsLinesSync();
    } on FileSystemException {
      return {'id': id, 'file': f.path, 'exists': true, 'readable': false};
    }
    final servers = <String>[];
    String? ranked;
    for (final l in lines) {
      final t = l.trim();
      if (t.startsWith('Server')) {
        final url = t.substring(t.indexOf('=') + 1).trim();
        servers.add(Uri.tryParse(url)?.host ?? url);
      } else if (ranked == null && t.startsWith('# FINISHED AT:')) {
        ranked = t.substring('# FINISHED AT:'.length).trim();
      }
    }
    final when = ranked == null ? null : DateTime.tryParse(ranked.replaceFirst(' ', 'T').replaceFirst(RegExp(r'\.\d+'), '').replaceFirst(' ', ''));
    return {
      'id': id,
      'file': f.path,
      'exists': true,
      'readable': true,
      'servers': servers.length,
      'top': servers.take(5).toList(),
      // rate-mirrors' header; a list it didn't write (the package's) has none: its file time.
      'ranked': (when ?? f.lastModifiedSync()).toLocal().toIso8601String(),
      'byTool': when != null,
    };
  }

  /// The ranking started from this page: running, its output's last lines, how it ended.
  Map<String, dynamic>? _run() {
    if (!_started.existsSync()) return null;
    final pid = int.tryParse(_read(_pid).trim());
    final exitText = _read(_exit).trim();
    final code = int.tryParse(exitText);
    final started = DateTime.tryParse(_read(_started).trim());
    // Before the shell wrote its pid (just started) it counts as running too.
    final fresh = started != null && ctx.clock().difference(started) < const Duration(seconds: 15);
    final running = code == null && (pid == null ? fresh : Directory(p.join(ctx.paths.proc, '$pid')).existsSync());
    final log = _read(_log).replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '');
    final tail = log.split('\n').map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty).toList();
    return {
      'started': _read(_started).trim(),
      'running': running,
      'code': code,
      // pkexec: 126 the dialog was closed, 127 not allowed.
      'outcome': running
          ? 'running'
          : code == null
              ? 'gone'
              : code == 0
                  ? 'done'
                  : code == 126 || code == 127
                      ? 'cancelled'
                      : 'failed',
      'lines': tail.length > 12 ? tail.sublist(tail.length - 12) : tail,
    };
  }

  static String _read(File f) {
    try {
      return f.existsSync() ? f.readAsStringSync() : '';
    } on FileSystemException {
      return '';
    }
  }

  void _needTool() {
    if (ctx.runner.which(tool) == null || ctx.runner.which('rate-mirrors') == null) {
      throw RouteError('unavailable', trf('{0} is missing', [tool]));
    }
    if (ctx.runner.which('pkexec') == null) throw RouteError('unavailable', trf('{0} is missing', ['pkexec']));
  }

  /// `mirrors.rank`: starts the ranking (one at a time); `mirrors.get` follows it.
  Future<Map<String, dynamic>> rank() async {
    _needTool();
    if (_run()?['running'] == true) throw RouteError('busy', tr('the mirrors are being ranked already'));
    final sh = ctx.runner.which('sh');
    if (sh == null) throw RouteError('unavailable', trf('{0} is missing', ['sh']));
    Directory(_stateDir).createSync(recursive: true);
    for (final f in [_log, _exit, _pid]) {
      if (f.existsSync()) f.deleteSync();
    }
    _started.writeAsStringSync(ctx.clock().toIso8601String());
    // $1 pkexec, $2 the tool, $3 log, $4 exit file, $5 pid file.
    const script = r'echo $$ > "$5"; "$1" "$2" > "$3" 2>&1; echo $? > "$4"';
    final ok = await startDetached(sh, ['-c', script, 'sh', ctx.runner.which('pkexec')!, ctx.runner.which(tool)!, _log.path, _exit.path, _pid.path]);
    if (!ok) {
      _started.deleteSync();
      throw RouteError('failed', trf('could not start {0}', [tool]));
    }
    return {'started': true};
  }

  /// `mirrors.set_timer` {on}: the automatic ranking (systemctl enable/disable --now; polkit asks).
  Future<Map<String, dynamic>> setTimer(Map<String, dynamic> params) async {
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    if (ctx.runner.which('systemctl') == null) throw RouteError('unavailable', trf('{0} is missing', ['systemctl']));
    final r = await ctx.runner.run(['systemctl', on ? 'enable' : 'disable', '--now', timer], timeout: _polkit);
    if (!r.ok) throw _failed(r.code, r.stderr);
    return {'enabled': on};
  }

  /// `mirrors.restore`: the lists before the last ranking back (`<file>-backup`; pkexec asks).
  /// The current lists become the backups, so a second restore undoes the first.
  Future<Map<String, dynamic>> restore() async {
    _needTool();
    if (_run()?['running'] == true) throw RouteError('busy', tr('the mirrors are being ranked already'));
    for (final f in allFiles) {
      if (!File(p.join(pacmanDir, '$f-backup')).existsSync()) throw RouteError('no_backup', trf('{0} is missing', ['$f-backup']));
    }
    const script = r'''set -e
cd "$1"; shift
for f in "$@"; do
  install -m 0644 "$f-backup" "$f.maprisma-swap"
  install -m 0644 "$f" "$f-backup"
  mv -f "$f.maprisma-swap" "$f"
done''';
    final r = await ctx.runner.run([ctx.runner.which('pkexec')!, '/bin/sh', '-c', script, 'sh', pacmanDir, ...allFiles], timeout: _polkit);
    if (!r.ok) throw _failed(r.code, r.stderr);
    return {'restored': true};
  }

  static RouteError _failed(int code, String stderr) {
    if (code == 126 || code == 127) return RouteError('cancelled', tr('the password dialog was closed'));
    final why = stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? '';
    return RouteError(code == 124 ? 'timeout' : 'failed', why.isEmpty ? trf('exit {0}', [code]) : why);
  }
}
