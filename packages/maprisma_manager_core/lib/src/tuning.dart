import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'translations.dart';

/// The Optimize page's Network card (`tune_net.*`): the DNS servers of the active connection
/// (NetworkManager: automatic from the router or a public resolver, with a speed test), TCP's
/// congestion control (BBR through a sysctl drop-in, pkexec asks) and Wi-Fi power saving.
final class NetTuneService {
  NetTuneService(this.ctx);
  final Ctx ctx;

  static const _polkit = Duration(minutes: 2);

  /// The resolvers the card offers: id → [name, IPv4 servers…].
  static const resolvers = {
    'cloudflare': ['Cloudflare', '1.1.1.1', '1.0.0.1'],
    'quad9': ['Quad9', '9.9.9.9', '149.112.112.112'],
    'google': ['Google', '8.8.8.8', '8.8.4.4'],
  };

  /// The sysctl drop-in this card writes for BBR.
  String get sysctlFile => p.join(ctx.paths.root, 'etc', 'sysctl.d', '99-maprisma-network.conf');

  String _proc(String key) {
    try {
      return File(p.join(ctx.paths.proc, 'sys', key)).readAsStringSync().trim();
    } on FileSystemException {
      return '';
    }
  }

  Future<String> _run(List<String> argv, {Duration timeout = const Duration(seconds: 10)}) async {
    final r = await ctx.runner.run(argv, timeout: timeout);
    if (!r.ok) {
      if (argv.first.endsWith('pkexec') && (r.code == 126 || r.code == 127)) throw RouteError('cancelled', tr('the password dialog was closed'));
      final why = r.stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? '';
      throw RouteError(r.code == 124 ? 'timeout' : 'failed', why.isEmpty ? trf('exit {0}', [r.code]) : why);
    }
    return r.stdout;
  }

  /// The active connection with the default route (not loopback): uuid, name, type, device.
  Future<Map<String, String>?> _active() async {
    if (ctx.runner.which('nmcli') == null) return null;
    final out = await _run(['nmcli', '-t', '-f', 'NAME,UUID,TYPE,DEVICE', 'connection', 'show', '--active']);
    for (final l in out.split('\n')) {
      // nmcli -t escapes ':' in values as '\:'.
      final f = l.split(RegExp(r'(?<!\\):')).map((v) => v.replaceAll(r'\:', ':')).toList();
      if (f.length < 4 || f[2] == 'loopback' || f[3].isEmpty || f[2] == 'bridge' || f[2] == 'tun') continue;
      return {'name': f[0], 'uuid': f[1], 'type': f[2], 'device': f[3]};
    }
    return null;
  }

  /// `tune_net.get`.
  Future<Map<String, dynamic>> get() async {
    final active = await _active();
    Map<String, dynamic>? dns, wifi;
    if (active != null) {
      final conf = (await _run(['nmcli', '-t', '-g', 'ipv4.ignore-auto-dns,ipv4.dns,802-11-wireless.powersave', 'connection', 'show', active['uuid']!]))
          .split('\n');
      String line(int i) => i < conf.length ? conf[i].trim() : '';
      final manual = [for (final s in line(1).split(',')) if (s.trim().isNotEmpty) s.trim()];
      final device = await _run(['nmcli', '-t', '-f', 'IP4.DNS,IP6.DNS', 'device', 'show', active['device']!]);
      final current = [for (final l in device.split('\n')) if (l.contains(':')) l.substring(l.indexOf(':') + 1).trim()]..removeWhere((s) => s.isEmpty);
      final ignoreAuto = line(0) == 'yes';
      String mode = 'auto';
      if (manual.isNotEmpty) {
        mode = resolvers.entries.where((e) => e.value.sublist(1).join(',') == manual.join(',')).map((e) => e.key).firstOrNull ?? 'custom';
      }
      dns = {'mode': mode, 'manual': manual, 'ignoreAuto': ignoreAuto, 'current': current};
      if (active['type'] == '802-11-wireless') {
        // 0 default (as the global setting), 1 ignore, 2 off, 3 on.
        final ps = line(2);
        final global = ps == 'default' || ps == '0' || ps.isEmpty;
        wifi = {'powersave': ps == '3' || ps == 'enable' || (global && _globalPowersaveOn()), 'value': ps};
      }
    }
    final available = _proc('net/ipv4/tcp_available_congestion_control').split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final hasBbrModule = available.contains('bbr') || _bbrModule();
    return {
      'connection': active,
      'dns': dns,
      'dig': ctx.runner.which('dig') != null,
      'resolvers': [for (final e in resolvers.entries) {'id': e.key, 'name': e.value[0], 'servers': e.value.sublist(1)}],
      'tcp': {
        'congestion': _proc('net/ipv4/tcp_congestion_control'),
        'qdisc': _proc('net/core/default_qdisc'),
        'bbrAvailable': hasBbrModule,
        'ours': File(sysctlFile).existsSync(),
      },
      'wifi': wifi,
      'pkexec': ctx.runner.which('pkexec') != null,
    };
  }

  bool _globalPowersaveOn() {
    // NetworkManager's default is on unless a conf.d file says wifi.powersave = 2.
    for (final dir in ['etc/NetworkManager/conf.d', 'usr/lib/NetworkManager/conf.d']) {
      final d = Directory(p.join(ctx.paths.root, dir));
      if (!d.existsSync()) continue;
      for (final f in d.listSync().whereType<File>()) {
        try {
          final m = RegExp(r'^\s*wifi\.powersave\s*=\s*(\d)', multiLine: true).firstMatch(f.readAsStringSync());
          if (m != null) return m[1] == '3';
        } on FileSystemException {
          continue;
        }
      }
    }
    return true;
  }

  bool _bbrModule() {
    // tcp_bbr not loaded yet: is its module there for the running kernel (sysctl loads it)?
    final rel = _proc('kernel/osrelease');
    final dir = Directory(p.join(ctx.paths.root, 'lib', 'modules', rel, 'kernel', 'net', 'ipv4'));
    if (rel.isEmpty || !dir.existsSync()) return false;
    return dir.listSync().any((f) => p.basename(f.path).startsWith('tcp_bbr.ko'));
  }

  /// `tune_net.test_dns`: one lookup through each resolver (and the current one) with dig; ms or null.
  Future<Map<String, dynamic>> testDns() async {
    if (ctx.runner.which('dig') == null) throw RouteError('unavailable', trf('{0} is missing', ['dig']));
    final active = await _active();
    final targets = <String, String>{for (final e in resolvers.entries) e.key: e.value[1]};
    if (active != null) {
      final device = await _run(['nmcli', '-t', '-f', 'IP4.DNS', 'device', 'show', active['device']!]);
      final first = [for (final l in device.split('\n')) if (l.contains(':')) l.substring(l.indexOf(':') + 1).trim()].where((s) => s.isNotEmpty).firstOrNull;
      if (first != null) targets['current'] = first;
    }
    final results = await Future.wait([
      for (final e in targets.entries)
        () async {
          // Two names: the second shows the time without the resolver's cache helping much.
          final times = <int>[];
          for (final name in ['archlinux.org', 'cachyos.org']) {
            final r = await ctx.runner.run(['dig', '@${e.value}', name, '+tries=1', '+time=2', '+noall', '+stats'], timeout: const Duration(seconds: 5));
            final m = RegExp(r'Query time: (\d+) msec').firstMatch(r.stdout);
            if (r.ok && m != null) times.add(int.parse(m[1]!));
          }
          return MapEntry(e.key, {'server': e.value, 'ms': times.isEmpty ? null : times.reduce((a, b) => a + b) ~/ times.length});
        }(),
    ]);
    return {'results': Map.fromEntries(results)};
  }

  /// `tune_net.set_dns` {mode: auto|cloudflare|quad9|google}: the active connection's DNS, then
  /// the connection comes up again with it (a second's break).
  Future<Map<String, dynamic>> setDns(Map<String, dynamic> params) async {
    final mode = params['mode'];
    if (mode != 'auto' && !resolvers.containsKey(mode)) throw RouteError('bad_params', 'mode');
    final active = await _active();
    if (active == null) throw RouteError('unavailable', tr('no active network connection'));
    final servers = mode == 'auto' ? '' : resolvers[mode]!.sublist(1).join(',');
    await _run(['nmcli', 'connection', 'modify', active['uuid']!, 'ipv4.dns', servers, 'ipv4.ignore-auto-dns', mode == 'auto' ? 'no' : 'yes'], timeout: _polkit);
    await _run(['nmcli', 'device', 'reapply', active['device']!], timeout: const Duration(seconds: 30));
    return {'mode': mode};
  }

  /// `tune_net.set_powersave` {on}: Wi-Fi power saving of the active Wi-Fi connection.
  Future<Map<String, dynamic>> setPowersave(Map<String, dynamic> params) async {
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    final active = await _active();
    if (active == null || active['type'] != '802-11-wireless') throw RouteError('unavailable', tr('no active Wi-Fi connection'));
    await _run(['nmcli', 'connection', 'modify', active['uuid']!, '802-11-wireless.powersave', on ? '3' : '2'], timeout: _polkit);
    await _run(['nmcli', 'device', 'reapply', active['device']!], timeout: const Duration(seconds: 30));
    return {'on': on};
  }

  /// `tune_net.set_bbr` {on}: BBR with the fq queue (on) through the drop-in, or the kernel's
  /// defaults back (off: the drop-in goes, cubic and fq_codel). pkexec asks.
  Future<Map<String, dynamic>> setBbr(Map<String, dynamic> params) async {
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    final pkexec = ctx.runner.which('pkexec');
    if (pkexec == null) throw RouteError('unavailable', trf('{0} is missing', ['pkexec']));
    const onScript = r'''set -e
mkdir -p "$(dirname "$1")"
printf '# Maprisma Settings › Optimize › Network\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$1.tmp"
chmod 0644 "$1.tmp"; mv -f "$1.tmp" "$1"
sysctl -q -p "$1"''';
    const offScript = r'''set -e
rm -f "$1"
sysctl -q -w net.ipv4.tcp_congestion_control=cubic net.core.default_qdisc=fq_codel''';
    await _run([pkexec, '/bin/sh', '-c', on ? onScript : offScript, 'sh', sysctlFile], timeout: _polkit);
    return {'on': on};
  }
}

/// The Optimize page's Bluetooth card (`tune_bt.*`): BlueZ's /etc/bluetooth/main.conf options that
/// change how Bluetooth behaves (fast connect, battery levels, on at start, reconnect attempts).
/// Writing needs root (pkexec) and a restart of bluetooth.service, which drops connected devices
/// for a moment.
final class BtTuneService {
  BtTuneService(this.ctx);
  final Ctx ctx;

  /// key → [section, BlueZ's default].
  static const options = {
    'FastConnectable': ['General', 'false'],
    'Experimental': ['General', 'false'],
    'AutoEnable': ['Policy', 'true'],
    'ReconnectAttempts': ['Policy', '7'],
  };

  String get file => p.join(ctx.paths.root, 'etc', 'bluetooth', 'main.conf');

  /// The uncommented values of [file]: section → key → value.
  Map<String, Map<String, String>> _read() {
    final out = <String, Map<String, String>>{};
    final f = File(file);
    if (!f.existsSync()) return out;
    var section = '';
    for (final raw in f.readAsLinesSync()) {
      final l = raw.trim();
      if (l.startsWith('[') && l.endsWith(']')) {
        section = l.substring(1, l.length - 1);
      } else if (!l.startsWith('#') && l.contains('=')) {
        (out[section] ??= {})[l.substring(0, l.indexOf('=')).trim()] = l.substring(l.indexOf('=') + 1).trim();
      }
    }
    return out;
  }

  /// `tune_bt.get`.
  Future<Map<String, dynamic>> get() async {
    final exists = File(file).existsSync();
    final values = _read();
    return {
      'available': exists && ctx.runner.which('bluetoothctl') != null,
      'file': file,
      'pkexec': ctx.runner.which('pkexec') != null,
      'options': {
        for (final e in options.entries)
          e.key: {'value': values[e.value[0]]?[e.key] ?? e.value[1], 'set': values[e.value[0]]?.containsKey(e.key) == true},
      },
    };
  }

  /// `tune_bt.set` {key, value}: one option written into its section (an old line of it,
  /// commented or not, is replaced), then bluetooth.service restarts.
  Future<Map<String, dynamic>> set(Map<String, dynamic> params) async {
    final key = params['key'], value = params['value'];
    if (key is! String || !options.containsKey(key)) throw RouteError('bad_params', 'key');
    final text = switch (key) {
      'ReconnectAttempts' => value is int && value >= 0 && value <= 20 ? '$value' : null,
      _ => value is bool ? '$value' : null,
    };
    if (text == null) throw RouteError('bad_params', 'value');
    if (!File(file).existsSync()) throw RouteError('unavailable', trf('{0} is missing', [file]));
    final pkexec = ctx.runner.which('pkexec');
    if (pkexec == null) throw RouteError('unavailable', trf('{0} is missing', ['pkexec']));
    // $1 file, $2 section, $3 key, $4 value; the first line of the key in the section (or its
    // commented example) becomes the value, else it goes at the end of the section.
    const script = r'''set -e
awk -v sec="$2" -v key="$3" -v val="$4" '
  function flush() { if (insec && !done) { print key " = " val; done = 1 } }
  /^[[:space:]]*\[/ { flush(); insec = ($0 ~ "^[[:space:]]*\\[" sec "\\][[:space:]]*$"); print; next }
  insec && !done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=" { print key " = " val; done = 1; next }
  { print }
  END { flush(); if (!done) { print ""; print "[" sec "]"; print key " = " val } }
' "$1" > "$1.maprisma-tmp"
chmod 0644 "$1.maprisma-tmp"; mv -f "$1.maprisma-tmp" "$1"
if command -v systemctl >/dev/null; then systemctl try-restart bluetooth.service; fi''';
    final r = await ctx.runner.run([pkexec, '/bin/sh', '-c', script, 'sh', file, options[key]![0], key, text], timeout: const Duration(minutes: 2));
    if (!r.ok) {
      if (r.code == 126 || r.code == 127) throw RouteError('cancelled', tr('the password dialog was closed'));
      final why = r.stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? '';
      throw RouteError('failed', why.isEmpty ? trf('exit {0}', [r.code]) : why);
    }
    return {'key': key, 'value': text};
  }
}
