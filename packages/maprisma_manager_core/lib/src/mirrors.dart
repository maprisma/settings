import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'translations.dart';

/// The Optimize page's Rank mirrors (`mirrors.*`) on any Arch-based system, with the first of:
/// - `cachyos`: CachyOS's `cachyos-rate-mirrors` tests the Arch and CachyOS mirrors
///   (rate-mirrors) and writes the fastest first into /etc/pacman.d/{mirrorlist,
///   cachyos-mirrorlist,cachyos-v3-mirrorlist,cachyos-v4-mirrorlist}; its timer is
///   `cachyos-rate-mirrors.timer`.
/// - `rate-mirrors` (Arch extra): the Arch list only; the timer is our own
///   `maprisma-rate-mirrors.timer`, written when it is first switched on.
/// - `reflector` (Arch extra): the Arch list sorted by speed; its own `reflector.timer` (which
///   follows /etc/xdg/reflector/reflector.conf).
/// Every way keeps the lists before as `<file>-backup`.
///
/// Ranking needs root: it runs detached under `pkexec` (polkit's agent asks for the password)
/// with its output in the state folder, so the page can follow it with `mirrors.get`. The
/// timer and the backups go through polkit too (systemctl, pkexec).
final class MirrorsService {
  MirrorsService(this.ctx, this.startDetached);

  final Ctx ctx;
  final Future<bool> Function(String exe, [List<String> args]) startDetached;

  static const tool = 'cachyos-rate-mirrors';

  /// Our service and timer for plain rate-mirrors (no CachyOS).
  static const ownTimer = 'maprisma-rate-mirrors';
  static const _polkit = Duration(minutes: 2);

  /// The lists the page shows: [id, file] (the v3/v4 lists are copies of the CachyOS one).
  static const lists = [('arch', 'mirrorlist'), ('cachyos', 'cachyos-mirrorlist')];

  /// Every list cachyos-rate-mirrors writes and backs up.
  static const allFiles = ['mirrorlist', 'cachyos-mirrorlist', 'cachyos-v3-mirrorlist', 'cachyos-v4-mirrorlist'];

  String get pacmanDir => p.join(ctx.paths.root, 'etc', 'pacman.d');
  String get _unitDir => p.join(ctx.paths.root, 'etc', 'systemd', 'system');
  String get _libDir => p.join(ctx.paths.root, 'usr', 'local', 'lib');
  String get _stateDir => p.join(ctx.paths.state, 'maprisma-settings', 'mirrors');
  File get _log => File(p.join(_stateDir, 'rank.log'));
  File get _exit => File(p.join(_stateDir, 'rank.exit'));
  File get _pid => File(p.join(_stateDir, 'rank.pid'));
  File get _started => File(p.join(_stateDir, 'rank.started'));

  /// The way this system ranks: cachyos, rate-mirrors, reflector, or null (none of them, or
  /// no pacman at all).
  String? get method {
    if (!Directory(pacmanDir).existsSync()) return null;
    if (ctx.runner.which(tool) != null && ctx.runner.which('rate-mirrors') != null) return 'cachyos';
    if (ctx.runner.which('rate-mirrors') != null) return 'rate-mirrors';
    if (ctx.runner.which('reflector') != null) return 'reflector';
    return null;
  }

  static String? timerOf(String? method) => switch (method) {
    'cachyos' => 'cachyos-rate-mirrors.timer',
    'rate-mirrors' => '$ownTimer.timer',
    'reflector' => 'reflector.timer',
    _ => null,
  };

  /// The lists [method] writes (and backs up).
  static List<String> filesOf(String? method) => method == 'cachyos' ? allFiles : const ['mirrorlist'];

  /// `mirrors.get`: the way to rank, the timer, the lists and the last or running ranking.
  Future<Map<String, dynamic>> get() async {
    final how = method;
    return {
      'available': how != null,
      'method': how,
      // No pacman: not an Arch-based system, nothing to rank here.
      'pacman': Directory(pacmanDir).existsSync(),
      'pkexec': ctx.runner.which('pkexec') != null,
      'timer': how == null ? null : await _timer(how),
      'lists': [
        for (final (id, file) in lists)
          if (id == 'arch' || File(p.join(pacmanDir, file)).existsSync()) _list(id, file),
      ],
      'backups': filesOf(how).every((f) => File(p.join(pacmanDir, '$f-backup')).existsSync()),
      'run': _run(),
    };
  }

  Future<Map<String, dynamic>?> _timer(String how) async {
    final timer = timerOf(how)!;
    if (ctx.runner.which('systemctl') == null) return null;
    final r = await ctx.runner.run(
      ['systemctl', 'show', timer, '--timestamp=unix', '-p', 'UnitFileState', '-p', 'ActiveState', '-p', 'NextElapseUSecRealtime', '-p', 'LastTriggerUSec'],
      timeout: const Duration(seconds: 5),
    );
    final v = {
      if (r.ok)
        for (final l in r.stdout.split('\n'))
          if (l.contains('=')) l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1).trim(),
    };
    if ((v['UnitFileState'] ?? '').isEmpty) {
      // Our own timer before it was first switched on: not there yet, so off.
      return how == 'rate-mirrors' ? {'name': timer, 'enabled': false, 'active': false, 'next': null, 'last': null} : null;
    }
    return {
      'name': timer,
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
      // rate-mirrors' header; a list it didn't write (reflector's, the package's): its file time.
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

  String _need() {
    final how = method;
    if (how == null) throw RouteError('unavailable', trf('{0} is missing', ['rate-mirrors / reflector']));
    if (ctx.runner.which('pkexec') == null) throw RouteError('unavailable', trf('{0} is missing', ['pkexec']));
    return how;
  }

  /// Plain rate-mirrors for the Arch list: tested into a temporary file, then installed with the
  /// old list as the backup. $1 the pacman.d folder, $2 rate-mirrors.
  static const rateScript = r'''set -e
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
RATE_MIRRORS_ALLOW_ROOT=true RATE_MIRRORS_PROTOCOL=https "$2" --save "$tmp" arch
grep -q '^Server' "$tmp"
install -m 0644 --backup=simple --suffix=-backup "$tmp" "$1/mirrorlist"
echo "==> Done: $1/mirrorlist"''';

  /// reflector, the 20 fastest of the 30 newest HTTPS mirrors, the same way. $1 pacman.d, $2 reflector.
  static const reflectorScript = r'''set -e
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
"$2" --verbose --protocol https --latest 30 --number 20 --sort rate --save "$tmp"
grep -q '^Server' "$tmp"
install -m 0644 --backup=simple --suffix=-backup "$tmp" "$1/mirrorlist"
echo "==> Done: $1/mirrorlist"''';

  /// `mirrors.rank`: starts the ranking (one at a time); `mirrors.get` follows it.
  Future<Map<String, dynamic>> rank() async {
    final how = _need();
    if (_run()?['running'] == true) throw RouteError('busy', tr('the mirrors are being ranked already'));
    final sh = ctx.runner.which('sh');
    if (sh == null) throw RouteError('unavailable', trf('{0} is missing', ['sh']));
    Directory(_stateDir).createSync(recursive: true);
    for (final f in [_log, _exit, _pid]) {
      if (f.existsSync()) f.deleteSync();
    }
    _started.writeAsStringSync(ctx.clock().toIso8601String());
    final pkexec = ctx.runner.which('pkexec')!;
    final command = switch (how) {
      'cachyos' => [pkexec, ctx.runner.which(tool)!],
      'rate-mirrors' => [pkexec, '/bin/sh', '-c', rateScript, 'sh', pacmanDir, ctx.runner.which('rate-mirrors')!],
      _ => [pkexec, '/bin/sh', '-c', reflectorScript, 'sh', pacmanDir, ctx.runner.which('reflector')!],
    };
    // $1 log, $2 exit file, $3 pid file, then the command.
    const script = r'l="$1"; e="$2"; echo $$ > "$3"; shift 3; "$@" > "$l" 2>&1; echo $? > "$e"';
    final ok = await startDetached(sh, ['-c', script, 'sh', _log.path, _exit.path, _pid.path, ...command]);
    if (!ok) {
      _started.deleteSync();
      throw RouteError('failed', trf('could not start {0}', [how]));
    }
    return {'started': true};
  }

  /// Writes our service, timer and rank script, then enables the timer: $1 unit folder, $2 name,
  /// $3 the rank script, $4 pacman.d, $5 rate-mirrors, $6 the folder for the script.
  static const _ownUnitsScript = r'''set -e
dir="$1"; name="$2"; lib="$6"
mkdir -p "$dir" "$lib"
printf '#!/bin/sh\n%s\n' "$3" > "$lib/$name.sh"
chmod 0755 "$lib/$name.sh"
cat > "$dir/$name.service" <<EOF
[Unit]
Description=Rank the Arch mirrors (Maprisma Settings)
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
Type=oneshot
ExecStart=$lib/$name.sh $4 $5
EOF
cat > "$dir/$name.timer" <<EOF
[Unit]
Description=Rank the Arch mirrors about every ten days (Maprisma Settings)

[Timer]
OnCalendar=*-*-01,11,21 00:00:00
RandomizedDelaySec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF
chmod 0644 "$dir/$name.service" "$dir/$name.timer"
systemctl daemon-reload
systemctl enable --now "$name.timer"''';

  /// `mirrors.set_timer` {on}: the automatic ranking (systemctl enable/disable --now; polkit
  /// asks). Plain rate-mirrors gets our own timer, written when it is switched on.
  Future<Map<String, dynamic>> setTimer(Map<String, dynamic> params) async {
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    if (ctx.runner.which('systemctl') == null) throw RouteError('unavailable', trf('{0} is missing', ['systemctl']));
    final how = method;
    final timer = timerOf(how);
    if (timer == null) throw RouteError('unavailable', trf('{0} is missing', ['rate-mirrors / reflector']));
    if (on && how == 'rate-mirrors') {
      final pkexec = ctx.runner.which('pkexec');
      if (pkexec == null) throw RouteError('unavailable', trf('{0} is missing', ['pkexec']));
      final r = await ctx.runner.run(
        [pkexec, '/bin/sh', '-c', _ownUnitsScript, 'sh', _unitDir, ownTimer, rateScript, pacmanDir, ctx.runner.which('rate-mirrors')!, _libDir],
        timeout: _polkit,
      );
      if (!r.ok) throw _failed(r.code, r.stderr);
      return {'enabled': true};
    }
    final r = await ctx.runner.run(['systemctl', on ? 'enable' : 'disable', '--now', timer], timeout: _polkit);
    if (!r.ok) throw _failed(r.code, r.stderr);
    return {'enabled': on};
  }

  /// `mirrors.restore`: the lists before the last ranking back (`<file>-backup`; pkexec asks).
  /// The current lists become the backups, so a second restore undoes the first.
  Future<Map<String, dynamic>> restore() async {
    final files = filesOf(_need());
    if (_run()?['running'] == true) throw RouteError('busy', tr('the mirrors are being ranked already'));
    for (final f in files) {
      if (!File(p.join(pacmanDir, '$f-backup')).existsSync()) throw RouteError('no_backup', trf('{0} is missing', ['$f-backup']));
    }
    const script = r'''set -e
cd "$1"; shift
for f in "$@"; do
  install -m 0644 "$f-backup" "$f.maprisma-swap"
  install -m 0644 "$f" "$f-backup"
  mv -f "$f.maprisma-swap" "$f"
done''';
    final r = await ctx.runner.run([ctx.runner.which('pkexec')!, '/bin/sh', '-c', script, 'sh', pacmanDir, ...files], timeout: _polkit);
    if (!r.ok) throw _failed(r.code, r.stderr);
    return {'restored': true};
  }

  static RouteError _failed(int code, String stderr) {
    if (code == 126 || code == 127) return RouteError('cancelled', tr('the password dialog was closed'));
    final why = stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? '';
    return RouteError(code == 124 ? 'timeout' : 'failed', why.isEmpty ? trf('exit {0}', [code]) : why);
  }
}
