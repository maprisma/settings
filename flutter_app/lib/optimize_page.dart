import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;
import 'package:maprisma_ui/settings.dart';

import 'backend.dart' show ServiceError;
import 'core_call.dart';

/// Optimize: things that make the PC faster, one card per group.
/// - Mirrors (core `mirrors.*`) on any Arch-based system: CachyOS's `cachyos-rate-mirrors`, else
///   plain `rate-mirrors`, else `reflector`: rank now (polkit asks for the password), the
///   automatic ranking (a timer), the lists, and the lists before the last ranking.
/// - Network (`tune_net.*`): the DNS servers with a speed test, TCP BBR, Wi-Fi power saving.
/// - Bluetooth (`tune_bt.*`): BlueZ's main.conf options (fast connect, battery levels, …).
class OptimizePage extends StatefulWidget {
  const OptimizePage({super.key, required this.core});
  final CoreCall core;
  @override
  State<OptimizePage> createState() => OptimizePageState();
}

class OptimizePageState extends State<OptimizePage> {
  Map<String, dynamic>? mirrors, net, bt;

  /// The last DNS test: resolver id (or "current") → {server, ms}.
  Map<String, dynamic>? dnsTimes;
  bool testingDns = false;
  String? error;
  bool working = false;
  Timer? _poll;

  /// The newest load: an older one that answers later is dropped.
  int _loads = 0;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool get ranking => (mirrors?['run'] as Map?)?['running'] == true;

  Future<void> load() async {
    unawaited(_loadTuning());
    final mine = ++_loads;
    try {
      final r = await widget.core('mirrors.get');
      if (mine != _loads || !mounted) return;
      final was = ranking;
      setState(() {
        mirrors = r;
        error = null;
      });
      // While it ranks the page follows it; at the end it tells how it went.
      _poll?.cancel();
      if (ranking) {
        _poll = Timer(const Duration(milliseconds: 1500), () => unawaited(load()));
      } else if (was) {
        final outcome = (r['run'] as Map?)?['outcome'];
        _tell(switch (outcome) {
          'done' => tr('The mirrors are ranked: the fastest are first now.'),
          'cancelled' => tr('Ranking was cancelled.'),
          _ => tr('Ranking the mirrors did not work; the lists stay as they were.'),
        });
      }
    } on ServiceError catch (e) {
      if (mounted && mine == _loads) setState(() => error = '${e.code}${e.reason == null ? '' : ': ${e.reason}'}');
    }
  }

  Future<void> _loadTuning() async {
    Future<Map<String, dynamic>?> get(String route) async {
      try {
        return await widget.core(route);
      } on ServiceError {
        return null;
      }
    }

    final r = await Future.wait([get('tune_net.get'), get('tune_bt.get')]);
    if (mounted) {
      setState(() {
        net = r[0];
        bt = r[1];
      });
    }
  }

  Future<void> _testDns() async {
    if (testingDns) return;
    setState(() => testingDns = true);
    try {
      final r = await widget.core('tune_net.test_dns');
      if (mounted) setState(() => dnsTimes = (r['results'] as Map).cast<String, dynamic>());
    } on ServiceError catch (e) {
      _tell(trf('That did not work ({0}){1}', [e.code, e.reason == null || e.reason!.isEmpty ? '' : ': ${e.reason}']));
    } finally {
      if (mounted) setState(() => testingDns = false);
    }
  }

  void _tell(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _call(String route, [Map<String, dynamic> params = const {}, String? done]) async {
    if (working) return;
    setState(() => working = true);
    try {
      try {
        await widget.core(route, params);
        if (done != null) _tell(done);
      } on ServiceError catch (e) {
        _tell(e.code == 'cancelled'
            ? tr('Cancelled: the password dialog was closed.')
            : trf('That did not work ({0}){1}', [e.code, e.reason == null || e.reason!.isEmpty ? '' : ': ${e.reason}']));
      }
      if (mounted) await load();
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _restore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Use the previous mirror lists?')),
        content: Text(tr('The mirror lists from before the last ranking come back. The current ones are kept as the backup, so you can switch back.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(key: const ValueKey('mirrors-restore-ok'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Restore'))),
        ],
      ),
    );
    if (ok == true) await _call('mirrors.restore', const {}, tr('The previous mirror lists are back.'));
  }

  /// An ISO time as "2026-11-17 23:53".
  static String when(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (t == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Widget _rank(Map m) {
    final timer = m['timer'] as Map?;
    final run = m['run'] as Map?;
    final arch = (m['lists'] as List).cast<Map>().where((l) => l['exists'] == true).firstOrNull;
    final busy = working || ranking;
    return SettingsSection(
      key: const ValueKey('optimize-mirrors'),
      title: tr('Mirrors'),
      note: switch (m['method']) {
        'cachyos' => tr('CachyOS tests the Arch and CachyOS download mirrors (rate-mirrors) and puts the fastest first in /etc/pacman.d. Updates come in faster.'),
        'reflector' => tr('reflector tests the Arch download mirrors and puts the fastest first in /etc/pacman.d/mirrorlist. Updates come in faster.'),
        _ => tr('rate-mirrors tests the Arch download mirrors and puts the fastest first in /etc/pacman.d/mirrorlist. Updates come in faster.'),
      },
      children: [
        SettingsItem(
          key: const ValueKey('mirrors-rank'),
          title: tr('Rank the mirrors now'),
          description: ranking
              ? tr('Testing the mirrors… this takes a minute or two.')
              : arch == null
                  ? tr('Asks for the password, then tests the mirrors.')
                  : trf('Last ranked {0}. Asks for the password, then tests the mirrors.', [when(arch['ranked'])]),
          trailing: ranking
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : FilledButton.tonal(
                  key: const ValueKey('mirrors-rank-now'),
                  onPressed: busy || m['pkexec'] != true ? null : () => _call('mirrors.rank'),
                  child: Text(tr('Rank now')),
                ),
        ),
        if (timer != null)
          SettingsToggle(
            key: const ValueKey('mirrors-timer'),
            title: tr('Rank automatically'),
            description: timer['enabled'] == true
                ? trf('Runs by itself with {0}. Next: {1}', [timer['name'], when(timer['next'])])
                : trf('Runs by itself with {0}. Off now.', [timer['name']]),
            value: timer['enabled'] == true,
            onChanged: busy ? null : (v) => _call('mirrors.set_timer', {'on': v}),
          ),
        SettingsItem(
          key: const ValueKey('mirrors-restore'),
          title: tr('Use the previous lists'),
          description: m['backups'] == true ? tr('Puts the mirror lists from before the last ranking back.') : tr('There are no previous lists yet.'),
          trailing: OutlinedButton(
            key: const ValueKey('mirrors-restore-button'),
            onPressed: busy || m['backups'] != true ? null : _restore,
            child: Text(tr('Restore')),
          ),
        ),
        if (run != null && (run['lines'] as List).isNotEmpty && (ranking || run['outcome'] != 'done'))
          SettingsItem(
            key: const ValueKey('mirrors-output'),
            title: ranking ? tr('Progress') : trf('Last ranking: {0}', [_outcome('${run['outcome']}')]),
            description: (run['lines'] as List).join('\n'),
          ),
        ..._lists(m),
      ],
    );
  }

  static String _outcome(String o) => switch (o) {
    'done' => tr('done'),
    'cancelled' => tr('cancelled'),
    'running' => tr('running'),
    _ => tr('failed'),
  };

  List<Widget> _lists(Map m) => [
      for (final l in (m['lists'] as List).cast<Map>())
        SettingsItem(
          key: ValueKey('mirrors-list-${l['id']}'),
          title: l['id'] == 'arch' ? tr('Arch Linux') : tr('CachyOS'),
          description: l['exists'] != true
              ? trf('{0} is missing', ['${l['file']}'])
              : l['readable'] != true
                  ? trf('{0} is not readable', ['${l['file']}'])
                  : [
                      trf('{0} mirrors · changed {1}', [l['servers'], when(l['ranked'])]),
                      if ((l['top'] as List).isNotEmpty) trf('Fastest: {0}', [(l['top'] as List).join(', ')]),
                    ].join('\n'),
        ),
  ];

  static const _resolverNames = {'current': 'Router / current', 'cloudflare': 'Cloudflare', 'quad9': 'Quad9', 'google': 'Google'};

  Widget _network(Map n) {
    final c = n['connection'] as Map?;
    final dns = n['dns'] as Map?;
    final tcp = n['tcp'] as Map;
    final wifi = n['wifi'] as Map?;
    final busy = working;
    final times = dnsTimes;
    String timesText() {
      final entries = times!.entries.where((e) => (e.value as Map)['ms'] != null).toList()
        ..sort((a, b) => ((a.value as Map)['ms'] as int).compareTo((b.value as Map)['ms'] as int));
      final failed = times.entries.where((e) => (e.value as Map)['ms'] == null).map((e) => e.key == 'current' ? tr('Router / current') : _resolverNames[e.key]!);
      return [
        for (final e in entries) '${e.key == 'current' ? tr('Router / current') : _resolverNames[e.key]} ${(e.value as Map)['ms']} ms',
        if (failed.isNotEmpty) trf('no answer: {0}', [failed.join(', ')]),
      ].join(' · ');
    }

    return SettingsSection(
      key: const ValueKey('optimize-network'),
      title: tr('Network'),
      note: c == null ? tr('No active network connection (NetworkManager).') : trf('Active connection: {0} ({1}).', [c['name'], c['device']]),
      children: [
        if (dns != null) ...[
          SettingsChoice<String>(
            key: const ValueKey('net-dns'),
            title: tr('DNS servers'),
            description: trf('Now: {0}. Changing it reconnects {1} for a moment.', [(dns['current'] as List).take(2).join(', '), c!['name']]),
            value: '${dns['mode']}',
            choices: [
              ('auto', tr('Automatic (router)')),
              for (final r in (n['resolvers'] as List).cast<Map>()) ('${r['id']}', '${r['name']} (${(r['servers'] as List).first})'),
              if (dns['mode'] == 'custom') ('custom', tr('Own servers')),
            ],
            onChanged: busy ? null : (v) => v == 'custom' ? null : _call('tune_net.set_dns', {'mode': v}, tr('The DNS servers are changed.')),
          ),
          SettingsItem(
            key: const ValueKey('net-dns-test'),
            title: tr('Test DNS speed'),
            description: times == null ? tr('Asks each DNS server twice and shows how fast it answers.') : timesText(),
            trailing: testingDns
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : FilledButton.tonal(
                    key: const ValueKey('net-dns-test-button'),
                    onPressed: n['dig'] == true ? _testDns : null,
                    child: Text(tr('Test')),
                  ),
          ),
        ],
        SettingsToggle(
          key: const ValueKey('net-bbr'),
          title: tr('Faster TCP (BBR)'),
          description: tcp['bbrAvailable'] == true
              ? trf('Now: {0} with {1}. BBR often gives faster, steadier downloads, above all on Wi-Fi. Asks for the password.', [tcp['congestion'], tcp['qdisc']])
              : tr('This kernel has no BBR.'),
          value: tcp['congestion'] == 'bbr',
          onChanged: busy || tcp['bbrAvailable'] != true || n['pkexec'] != true ? null : (v) => _call('tune_net.set_bbr', {'on': v}),
        ),
        if (wifi != null)
          SettingsToggle(
            key: const ValueKey('net-powersave'),
            title: tr('Wi-Fi power saving'),
            description: tr('Off: lower latency and fewer drop-outs, a little more battery use.'),
            value: wifi['powersave'] == true,
            onChanged: busy ? null : (v) => _call('tune_net.set_powersave', {'on': v}),
          ),
      ],
    );
  }

  Widget _bluetooth(Map b) {
    final o = (b['options'] as Map).cast<String, dynamic>();
    bool on(String k) => '${(o[k] as Map)['value']}'.toLowerCase() == 'true';
    final busy = working || b['pkexec'] != true;
    void set(String key, Object value) => unawaited(_call('tune_bt.set', {'key': key, 'value': value}, tr('Saved; Bluetooth restarted.')));
    final attempts = int.tryParse('${(o['ReconnectAttempts'] as Map)['value']}') ?? 7;
    final choices = {0, 3, 7, 10, 15, attempts}.toList()..sort();
    return SettingsSection(
      key: const ValueKey('optimize-bluetooth'),
      title: tr('Bluetooth'),
      note: trf('Saved in {0}. Each change asks for the password and restarts Bluetooth, so connected devices reconnect.', [b['file']]),
      children: [
        SettingsToggle(
          key: const ValueKey('bt-FastConnectable'),
          title: tr('Fast connect'),
          description: tr('Devices connect faster to this PC; uses a little more power.'),
          value: on('FastConnectable'),
          onChanged: busy ? null : (v) => set('FastConnectable', v),
        ),
        SettingsToggle(
          key: const ValueKey('bt-Experimental'),
          title: tr('Battery levels of devices'),
          description: tr('Lets headphones and other devices report their battery level (BlueZ experimental features).'),
          value: on('Experimental'),
          onChanged: busy ? null : (v) => set('Experimental', v),
        ),
        SettingsToggle(
          key: const ValueKey('bt-AutoEnable'),
          title: tr('Bluetooth on at start'),
          description: tr('Turns the Bluetooth adapters on when they are found.'),
          value: on('AutoEnable'),
          onChanged: busy ? null : (v) => set('AutoEnable', v),
        ),
        SettingsChoice<int>(
          key: const ValueKey('bt-ReconnectAttempts'),
          title: tr('Reconnect attempts'),
          description: tr('How often a device that dropped out is tried again.'),
          value: attempts,
          choices: [for (final c in choices) (c, c == 0 ? tr('Never') : '$c')],
          onChanged: busy ? null : (v) => set('ReconnectAttempts', v),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = mirrors;
    final List<Widget> sections;
    if (m == null) {
      sections = [
        if (error != null)
          Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
        else
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
      ];
    } else if (m['available'] != true) {
      sections = [
        SettingsSection(
          key: const ValueKey('optimize-mirrors'),
          title: tr('Mirrors'),
          children: [
            SettingsItem(
              key: const ValueKey('mirrors-missing'),
              title: m['pacman'] == false ? tr('Rank mirrors is for Arch-based systems') : tr('Rank mirrors needs rate-mirrors or reflector'),
              description: m['pacman'] == false
                  ? tr('This system has no pacman mirror lists (/etc/pacman.d); its package manager picks mirrors its own way.')
                  : tr('Install one of them, for example: sudo pacman -S rate-mirrors (both are in the Arch extra repository).'),
            ),
          ],
        ),
      ];
    } else {
      sections = [_rank(m)];
    }
    if (m != null) {
      final n = net, b = bt;
      sections.addAll([
        if (n != null) _network(n),
        if (b != null && b['available'] == true) _bluetooth(b),
      ]);
    }
    return SettingsPage(
      title: tr('Optimize'),
      actions: [
        if (working) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
        IconButton(tooltip: tr('Reload'), onPressed: load, icon: const Icon(Icons.refresh)),
      ],
      children: sections,
    );
  }
}
