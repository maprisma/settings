import 'dart:async';
import 'dart:convert' show utf8;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'package:maprisma_ui/settings.dart';

/// Formats connections as a safe Markdown table for clipboard export.
@visibleForTesting
String formatConnectionsMarkdown(List<Map<String, dynamic>> conns) {
  String cell(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\r\n\t|]+'), ' ').trim();
    return cleaned.replaceAllMapped(RegExp(r'([\\`\[\]()*_])'), (m) => '\\${m[1]}');
  }

  String ep(String ip, int port) {
    final host = ip.contains(':') && !ip.startsWith('[') ? '[$ip]' : ip;
    return port > 0 ? '$host:$port' : host;
  }

  final lines = <String>[
    '| Process | Proto | State | Local | Remote | Service | Scope |',
    '| --- | --- | --- | --- | --- | --- | --- |',
  ];
  for (final c in conns.take(256)) {
    final proc = '${c['process'] ?? ''}';
    final local = ep('${c['localIp'] ?? ''}', (c['localPort'] as int?) ?? 0);
    final remote = ep('${c['remoteIp'] ?? ''}', (c['remotePort'] as int?) ?? 0);
    lines.add(
      '| ${cell(proc.isEmpty ? '—' : proc)} | ${cell('${c['proto'] ?? ''}')} | ${cell('${c['state'] ?? ''}')} | ${cell(local)} | ${cell(remote)} | ${cell('${c['service'] ?? ''}')} | ${cell('${c['scope'] ?? ''}')} |',
    );
  }
  return '${lines.join('\n')}\n';
}

/// Network & Wireless: Wi-Fi, wired and VPN management (Hyprland via `network.*` / nmcli;
/// COSMIC/KDE via their native settings app), plus built-in LAN Devices (`network.devices`)
/// and Live Network Monitor (`network.monitor`) on every desktop.
class NetworkPage extends StatelessWidget {
  const NetworkPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'network',
    title: tr('Network & Wireless'),
    what: tr('the network'),
    own: (_) => _Network(core: core),
    alsoNative: (_) => [_NativeNetworkTools(core: core)],
  );
}

enum _NetworkTab { wifi, devices, monitor }

enum _NativeNetTab { devices, monitor }

enum _MonitorSubView { connections, byApp, interfaces }

enum _ProtoFilter { all, tcp, udp }

enum _ScopeFilter { all, active, listening, external, lan, loopback }

enum _MonitorSort { traffic, app, state, remote, port }

String _formatBytes(num value) {
  final b = value.toDouble();
  if (b < 1024) return '${b.round()} B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _formatRate(num bytesPerSec) => '${_formatBytes(bytesPerSec)}/s';

/// On COSMIC/KDE: exposes LAN Devices and Network Monitor directly below the native settings card.
class _NativeNetworkTools extends StatefulWidget {
  const _NativeNetworkTools({required this.core});
  final CoreCall core;
  @override
  State<_NativeNetworkTools> createState() => _NativeNetworkToolsState();
}

class _NativeNetworkToolsState extends State<_NativeNetworkTools> {
  _NativeNetTab _tab = _NativeNetTab.devices;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_NativeNetTab>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: _NativeNetTab.devices,
              icon: const Icon(Icons.devices, size: 16),
              label: Text(tr('LAN Devices'), key: const ValueKey('network-tab-devices')),
            ),
            ButtonSegment(
              value: _NativeNetTab.monitor,
              icon: const Icon(Icons.monitor_heart_outlined, size: 16),
              label: Text(tr('Network Monitor'), key: const ValueKey('network-tab-monitor')),
            ),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        const SizedBox(height: SettingsMetrics.sectionGap),
        if (_tab == _NativeNetTab.devices)
          _LanDevicesView(core: widget.core)
        else
          _NetworkMonitorView(core: widget.core),
      ],
    );
  }
}

class _Network extends StatefulWidget {
  const _Network({required this.core});
  final CoreCall core;
  @override
  State<_Network> createState() => _NetworkState();
}

class _NetworkState extends State<_Network> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'network.get';

  _NetworkTab _tab = _NetworkTab.wifi;
  int _devicesReload = 0;
  int _monitorReload = 0;
  bool scanning = false;

  Future<void> rescan() async {
    if (scanning) return;
    setState(() => scanning = true);
    try {
      await loadFrom('network.get', {'rescan': true});
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  void _reloadActiveTab() {
    switch (_tab) {
      case _NetworkTab.wifi:
        unawaited(load());
      case _NetworkTab.devices:
        setState(() => _devicesReload++);
      case _NetworkTab.monitor:
        setState(() => _monitorReload++);
    }
  }

  static IconData signal(int s) => s >= 70 ? Icons.network_wifi : s >= 45 ? Icons.network_wifi_3_bar : s >= 25 ? Icons.network_wifi_2_bar : Icons.network_wifi_1_bar;

  static const _maxPasswordAttempts = 5;

  /// Runs a core route while keeping [working] true and reloading afterwards; returns any
  /// [ServiceError] instead of immediately showing a snackbar so callers can handle auth retries.
  Future<ServiceError?> _tryAction(String route, Map<String, dynamic> params) async {
    setState(() => working = true);
    ServiceError? err;
    try {
      try {
        await core(route, params);
      } on ServiceError catch (e) {
        err = e;
      }
      if (mounted) {
        try {
          await load();
        } on Object {
          // A reload failure must never mask the primary action result.
        }
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
    return err;
  }

  Future<void> _promptAndUp(Map k, {String? note, String? title}) async {
    final name = '${k['name']}';
    var currentNote = note;
    for (var attempt = 0; attempt < _maxPasswordAttempts; attempt++) {
      if (!mounted) return;
      final password = await showDialog<String>(
        context: context,
        builder: (_) => _PasswordDialog(ssid: name, title: title, note: currentNote),
      );
      if (password == null || !mounted) return;
      final err = await _tryAction('network.up', {'uuid': k['uuid'], 'password': password});
      if (err == null) {
        if (mounted) tellOn(this, trf('Connected to {0}', [name]));
        return;
      }
      if (err.code != 'auth_failed' || attempt + 1 >= _maxPasswordAttempts) {
        if (mounted) tellOn(this, failure(err));
        return;
      }
      currentNote = tr('Wrong password. Try again.');
    }
  }

  Future<void> _connectKnown(Map k) async {
    if (working) return;
    final name = '${k['name']}';
    final err = await _tryAction('network.up', {'uuid': k['uuid']});
    if (err == null) {
      if (mounted) tellOn(this, trf('Connected to {0}', [name]));
      return;
    }
    if (err.code != 'auth_failed') {
      if (mounted) tellOn(this, failure(err));
      return;
    }
    if (!mounted) return;
    await _promptAndUp(k, note: tr('The saved password did not work. Enter a new password.'));
  }

  Future<void> _changePassword(Map k) async {
    if (working) return;
    await _promptAndUp(k, title: trf('Change password for {0}', [k['name']]));
  }

  Future<void> join(Map v) async {
    if (working) return;
    final ssid = '${v['ssid']}';
    final open = '${v['security']}'.trim().isEmpty;
    String? note;
    if (open) {
      final err = await _tryAction('network.connect', {'ssid': ssid});
      if (err == null) {
        if (mounted) tellOn(this, trf('Connected to {0}', [ssid]));
        return;
      }
      if (err.code != 'auth_failed') {
        if (mounted) tellOn(this, failure(err));
        return;
      }
      note = tr('This network requires a password.');
    }
    for (var attempt = 0; attempt < _maxPasswordAttempts; attempt++) {
      if (!mounted) return;
      final password = await showDialog<String>(
        context: context,
        builder: (_) => _PasswordDialog(ssid: ssid, note: note),
      );
      if (password == null || !mounted) return;
      final err = await _tryAction('network.connect', {'ssid': ssid, 'password': password});
      if (err == null) {
        if (mounted) tellOn(this, trf('Connected to {0}', [ssid]));
        return;
      }
      if (err.code != 'auth_failed' || attempt + 1 >= _maxPasswordAttempts) {
        if (mounted) tellOn(this, failure(err));
        return;
      }
      note = tr('Wrong password. Try again.');
    }
  }

  Widget _knownRow(Map k) {
    final on = k['active'] == true;
    return SettingsItem(
      key: ValueKey('known-${k['uuid']}'),
      leading: Icon(on ? Icons.wifi : Icons.wifi_outlined, size: 20),
      title: '${k['name']}',
      description: on ? tr('Connected') : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: working ? null : () => on ? act('network.down', {'uuid': k['uuid']}) : _connectKnown(k),
            child: Text(on ? tr('Disconnect') : tr('Connect')),
          ),
          PopupMenuButton<String>(
            key: ValueKey('known-menu-${k['uuid']}'),
            tooltip: tr('More'),
            enabled: !working,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'password', child: Text(tr('Change password'))),
              PopupMenuItem(value: 'forget', child: Text(tr('Forget'))),
            ],
            onSelected: (v) {
              if (v == 'password') {
                _changePassword(k);
              } else if (v == 'forget') {
                act('network.forget', {'uuid': k['uuid']});
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(Map c, {String? device}) => SettingsToggle(
    key: ValueKey('conn-${c['uuid']}'),
    title: '${c['name']}',
    description: c['active'] == true ? tr('Connected') : device,
    value: c['active'] == true,
    onChanged: working ? null : (v) => act(v ? 'network.up' : 'network.down', {'uuid': c['uuid']}),
  );

  List<Widget> _wifiSections(BuildContext context) {
    final d = data;
    if (d == null) return loadingOrError(context);
    final known = (d['known'] as List).cast<Map>();
    final visible = [for (final v in (d['visible'] as List).cast<Map>()) if (v['known'] != true) v];
    final wired = (d['wired'] as List).cast<Map>();
    final wiredDevices = (d['wiredDevices'] as List).cast<Map>();
    final vpn = (d['vpn'] as List).cast<Map>();
    return [
      if (d['wifiDevice'] == true) ...[
        SettingsSection(
          title: tr('Wi-Fi'),
          children: [
            SettingsToggle(key: const ValueKey('wifi-on'), title: tr('Wi-Fi'), value: d['wifiOn'] == true, onChanged: working ? null : (v) => act('network.wifi', {'on': v})),
            for (final k in known) _knownRow(k),
          ],
        ),
        if (d['wifiOn'] == true)
          SettingsSection(
            title: tr('Visible networks'),
            note: visible.isEmpty ? tr('No other networks found.') : null,
            children: [
              SettingsItem(
                title: tr('Search again'),
                trailing: scanning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(key: const ValueKey('wifi-rescan'), tooltip: tr('Search again'), onPressed: rescan, icon: const Icon(Icons.wifi_find, size: 20)),
              ),
              for (final v in visible)
                SettingsItem(
                  key: ValueKey('visible-${v['ssid']}'),
                  leading: Icon(signal(v['signal'] as int), size: 20),
                  title: '${v['ssid']}',
                  description: '${v['security']}'.trim().isEmpty ? tr('Open network') : '${v['security']}',
                  onTap: working ? null : () => join(v),
                  trailing: Icon('${v['security']}'.trim().isEmpty ? Icons.lock_open : Icons.lock_outline, size: 16),
                ),
            ],
          ),
      ],
      if (wired.isNotEmpty || wiredDevices.isNotEmpty)
        SettingsSection(
          title: tr('Wired'),
          note: wiredDevices.isNotEmpty && wiredDevices.every((w) => w['state'] == 'unavailable') ? tr('No cable is plugged in.') : null,
          children: [for (final c in wired) _toggleRow(c)],
        ),
      if (vpn.isNotEmpty)
        SettingsSection(
          title: tr('VPN'),
          children: [for (final c in vpn) _toggleRow(c)],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final actions = [
      if (d?['monitor'] == true)
        TextButton.icon(
          key: const ValueKey('network-monitor'),
          onPressed: () => act('apps.open', {'id': 'wlan'}, reload: false),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(tr('WLAN Monitor')),
        ),
      if (working)
        const Padding(
          padding: EdgeInsets.only(right: 8),
          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      IconButton(tooltip: tr('Reload'), onPressed: _reloadActiveTab, icon: const Icon(Icons.refresh)),
    ];

    return SettingsPage(
      title: tr('Network & Wireless'),
      actions: actions,
      children: [
        SegmentedButton<_NetworkTab>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: _NetworkTab.wifi,
              icon: const Icon(Icons.wifi, size: 16),
              label: Text(tr('Wi-Fi & Connections'), key: const ValueKey('network-tab-wifi')),
            ),
            ButtonSegment(
              value: _NetworkTab.devices,
              icon: const Icon(Icons.devices, size: 16),
              label: Text(tr('LAN Devices'), key: const ValueKey('network-tab-devices')),
            ),
            ButtonSegment(
              value: _NetworkTab.monitor,
              icon: const Icon(Icons.monitor_heart_outlined, size: 16),
              label: Text(tr('Network Monitor'), key: const ValueKey('network-tab-monitor')),
            ),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        if (_tab == _NetworkTab.wifi)
          ..._wifiSections(context)
        else if (_tab == _NetworkTab.devices)
          _LanDevicesView(core: core, reloadToken: _devicesReload)
        else
          _NetworkMonitorView(core: core, reloadToken: _monitorReload),
      ],
    );
  }
}

/// LAN Devices tab: connection summary card, search & Online-only filter, expandable device rows.
class _LanDevicesView extends StatefulWidget {
  const _LanDevicesView({required this.core, this.reloadToken = 0});
  final CoreCall core;
  final int reloadToken;
  @override
  State<_LanDevicesView> createState() => _LanDevicesViewState();
}

class _LanDevicesViewState extends State<_LanDevicesView> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = false;
  final _searchCtrl = TextEditingController();
  String _search = '';
  bool _onlineOnly = false;
  final Set<String> _expandedIps = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _LanDevicesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      unawaited(_load(rescan: true));
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool rescan = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final r = await widget.core('network.devices', {if (rescan) 'rescan': true});
      if (mounted) {
        setState(() {
          _data = r;
          _error = null;
        });
      }
    } on ServiceError catch (e) {
      if (mounted) {
        if (_data != null) {
          tellOn(this, failure(e));
        } else {
          setState(() => _error = failure(e));
        }
      }
    } on Object catch (e) {
      if (mounted) {
        if (_data != null) {
          tellOn(this, '$e');
        } else {
          setState(() => _error = '$e');
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyText(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) tellOn(this, trf('Copied {0}', [value]));
    } on Object catch (e) {
      if (mounted) tellOn(this, '$e');
    }
  }

  static IconData _deviceIcon(String kind) => switch (kind) {
    'router' => Icons.router,
    'computer' => Icons.computer,
    'phone' => Icons.smartphone,
    'tv' => Icons.tv,
    'smarthome' => Icons.home_outlined,
    'printer' => Icons.print,
    _ => Icons.devices_other,
  };

  Widget _badge(BuildContext context, String label, {Color? color}) {
    final cs = Theme.of(context).colorScheme;
    final fg = color ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildSummary(BuildContext context, Map<String, dynamic> d) {
    final cs = Theme.of(context).colorScheme;
    if (d['active'] != true || d['link'] is! Map) {
      return SettingsSection(
        title: tr('Connection'),
        children: [
          SettingsItem(
            leading: const Icon(Icons.wifi_off, size: 20),
            title: tr('Not connected to a network.'),
          ),
        ],
      );
    }
    final link = (d['link'] as Map).cast<String, dynamic>();
    final traffic = (d['traffic'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final isWireless = link['isWireless'] == true;
    final iface = '${link['iface'] ?? ''}';
    final ssid = '${link['ssid'] ?? ''}';
    final title = isWireless ? (ssid.isNotEmpty ? ssid : iface) : trf('Wired ({0})', [iface]);
    final quality = link['quality'] as int?;
    final signalDbm = link['signalDbm'] as int?;
    final band = '${link['band'] ?? ''}';
    final channel = link['channel'] as int?;
    final widthMhz = link['widthMhz'] as int?;
    final rxMbps = link['rxMbps'] as int?;
    final txMbps = link['txMbps'] as int?;
    final ip = '${link['ip'] ?? ''}';
    final gateway = link['gateway'] as String?;

    final radioParts = <String>[
      if (band.isNotEmpty) band,
      if (channel != null) trf('ch {0}', [channel]),
      if (widthMhz != null) '$widthMhz MHz',
      if (rxMbps != null || txMbps != null) '↓ ${rxMbps ?? 0} / ↑ ${txMbps ?? 0} Mbit/s',
    ];
    final addrParts = <String>[
      if (ip.isNotEmpty) 'IP $ip',
      if (gateway != null && gateway.isNotEmpty) '${tr('Gateway')} $gateway',
      if (iface.isNotEmpty) '${tr('Interface')} $iface',
    ];
    final rxRate = (traffic['rxRate'] as num?) ?? 0;
    final txRate = (traffic['txRate'] as num?) ?? 0;
    final rxBytes = (traffic['rxBytes'] as num?) ?? 0;
    final txBytes = (traffic['txBytes'] as num?) ?? 0;

    return SettingsSection(
      title: tr('Connection'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(isWireless ? Icons.wifi : Icons.settings_ethernet, size: 22, color: cs.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        if (radioParts.isNotEmpty)
                          Text(
                            radioParts.join(' · '),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (isWireless && quality != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('${tr('Signal')}: ', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(value: (quality / 100.0).clamp(0.0, 1.0), minHeight: 6),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      signalDbm != null ? '$quality % ($signalDbm dBm)' : '$quality %',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
              if (addrParts.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  addrParts.join(' · '),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 6),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  Text(
                    '${tr('Traffic')}: ↓ ${_formatRate(rxRate)} · ↑ ${_formatRate(txRate)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '↓ ${_formatBytes(rxBytes)} · ↑ ${_formatBytes(txBytes)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceRow(BuildContext context, Map<String, dynamic> dev) {
    final cs = Theme.of(context).colorScheme;
    final ip = '${dev['ip'] ?? ''}';
    final mac = '${dev['mac'] ?? ''}';
    final name = '${dev['name'] ?? ip}';
    final vendor = '${dev['vendor'] ?? ''}';
    final state = '${dev['state'] ?? ''}';
    final kind = '${dev['kind'] ?? 'device'}';
    final online = dev['online'] == true;
    final isSelf = dev['isSelf'] == true;
    final isGateway = dev['isGateway'] == true;
    final webUrl = dev['webUrl'] as String?;
    final expanded = _expandedIps.contains(ip);

    return Column(
      key: ValueKey('device-$ip'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (expanded) {
              _expandedIps.remove(ip);
            } else {
              _expandedIps.add(ip);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                Icon(_deviceIcon(kind), size: 20, color: online ? cs.primary : cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(name, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                          if (isSelf) _badge(context, tr('This PC'), color: cs.primary),
                          if (isGateway && name != tr('Router')) _badge(context, tr('Router'), color: cs.tertiary),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        vendor.isNotEmpty ? '$ip · $vendor' : ip,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _badge(context, online ? tr('Online') : tr('Idle'), color: online ? Colors.green.shade600 : cs.onSurfaceVariant),
                const SizedBox(width: 4),
                IconButton(
                  key: ValueKey('device-copy-$ip'),
                  tooltip: tr('Copy IP'),
                  icon: const Icon(Icons.copy, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _copyText(ip),
                ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (expanded)
          Container(
            padding: const EdgeInsets.fromLTRB(52, 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('${tr('MAC')}: ${mac.isNotEmpty ? mac : '—'}', style: Theme.of(context).textTheme.bodySmall),
                    Text('${tr('Vendor')}: ${vendor.isNotEmpty ? vendor : '—'}', style: Theme.of(context).textTheme.bodySmall),
                    Text('${tr('State')}: ${state.isNotEmpty ? state : '—'}', style: Theme.of(context).textTheme.bodySmall),
                    if (webUrl != null && webUrl.isNotEmpty)
                      Text('${tr('Web UI')}: $webUrl', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                if (mac.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: () => _copyText(mac),
                    icon: const Icon(Icons.copy, size: 14),
                    label: Text(tr('Copy MAC')),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      if (_error != null) {
        return SettingsSection(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Expanded(child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    key: const ValueKey('devices-retry'),
                    onPressed: _loading ? null : () => _load(rescan: true),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(tr('Retry')),
                  ),
                ],
              ),
            ),
          ],
        );
      }
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
    }

    final allDevices = (d['devices'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final q = _search.trim().toLowerCase();
    final filtered = [
      for (final dev in allDevices)
        if (!_onlineOnly || dev['online'] == true)
          if (q.isEmpty ||
              '${dev['name']} ${dev['ip']} ${dev['mac']} ${dev['vendor']} ${dev['kind']} ${dev['state']}'.toLowerCase().contains(q))
            dev,
    ];
    final onlineCount = (d['onlineCount'] as int?) ?? allDevices.where((x) => x['online'] == true).length;
    final totalCount = (d['totalCount'] as int?) ?? allDevices.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSummary(context, d),
        const SizedBox(height: SettingsMetrics.sectionGap),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 300,
              child: TextField(
                key: const ValueKey('devices-search'),
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: tr('Filter devices by name, IP, MAC, vendor…'),
                  suffixIcon: _search.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _search = '');
                          },
                        ),
                ),
              ),
            ),
            FilterChip(
              key: const ValueKey('devices-online-only'),
              label: Text(tr('Online only')),
              selected: _onlineOnly,
              onSelected: (v) => setState(() => _onlineOnly = v),
            ),
            OutlinedButton.icon(
              key: const ValueKey('devices-refresh'),
              onPressed: _loading ? null : () => _load(rescan: true),
              icon: _loading
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: Text(tr('Refresh')),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SettingsSection(
          title: '${tr('LAN Devices')} · ${trf('{0} online · {1} total', [onlineCount, totalCount])}',
          children: [
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Text(
                  allDevices.isEmpty ? tr('No devices found.') : tr('No devices match the current filter.'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              )
            else
              for (final dev in filtered) _buildDeviceRow(context, dev),
          ],
        ),
      ],
    );
  }
}

/// Live Network Monitor tab: summary + Pause/Resume + Copy table + 3s auto-refresh +
/// Connections (filters/sort/expand), By app, and Interfaces + DNS.
class _NetworkMonitorView extends StatefulWidget {
  const _NetworkMonitorView({required this.core, this.reloadToken = 0});
  final CoreCall core;
  final int reloadToken;
  @override
  State<_NetworkMonitorView> createState() => _NetworkMonitorViewState();
}

class _NetworkMonitorViewState extends State<_NetworkMonitorView> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _fetching = false;
  bool _paused = false;
  bool _appVisible = true;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  _MonitorSubView _subView = _MonitorSubView.connections;
  _ProtoFilter _proto = _ProtoFilter.all;
  _ScopeFilter _scope = _ScopeFilter.all;
  _MonitorSort _sort = _MonitorSort.traffic;
  final _searchCtrl = TextEditingController();
  String _search = '';
  String? _appFilter;
  final Set<String> _expandedIds = {};

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _appVisible = true;
        if (mounted && !_paused) {
          unawaited(_load());
          _startTimer();
        }
      },
      onHide: _onAppBackgrounded,
      onPause: _onAppBackgrounded,
      onDetach: _onAppBackgrounded,
    );
    unawaited(_load());
    _startTimer();
  }

  void _onAppBackgrounded() {
    _appVisible = false;
    _stopTimer();
  }

  @override
  void didUpdateWidget(covariant _NetworkMonitorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _stopTimer();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _startTimer() {
    _stopTimer();
    if (_paused || !_appVisible) return;
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_paused && _appVisible) unawaited(_load());
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
    if (_paused) {
      _stopTimer();
    } else {
      unawaited(_load());
      _startTimer();
    }
  }

  Future<void> _load() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final r = await widget.core('network.monitor');
      if (mounted) {
        setState(() {
          _data = r;
          _error = null;
        });
      }
    } on ServiceError catch (e) {
      if (mounted) {
        if (_data != null) {
          tellOn(this, failure(e));
        } else {
          setState(() => _error = failure(e));
        }
      }
    } on Object catch (e) {
      if (mounted) {
        if (_data != null) {
          tellOn(this, '$e');
        } else {
          setState(() => _error = '$e');
        }
      }
    } finally {
      _fetching = false;
    }
  }

  bool get _hasFilters => _search.trim().isNotEmpty || _proto != _ProtoFilter.all || _scope != _ScopeFilter.all || _appFilter != null;

  void _clearFilters() {
    _searchCtrl.clear();
    setState(() {
      _search = '';
      _proto = _ProtoFilter.all;
      _scope = _ScopeFilter.all;
      _appFilter = null;
    });
  }

  void _filterByApp(String appName) {
    _searchCtrl.clear();
    setState(() {
      _subView = _MonitorSubView.connections;
      _search = '';
      _appFilter = appName;
      _proto = _ProtoFilter.all;
      _scope = _ScopeFilter.all;
    });
  }

  static bool _isListeningConn(Map<String, dynamic> c) {
    final state = '${c['state'] ?? ''}';
    if (state == 'LISTEN') return true;
    if (state == 'UNCONN') {
      final rp = (c['remotePort'] as int?) ?? 0;
      final rip = '${c['remoteIp'] ?? ''}';
      return rp == 0 || rip.isEmpty || rip == '*' || rip == '0.0.0.0' || rip == '::';
    }
    return false;
  }

  static int _stateRank(String s) => switch (s) {
    'ESTABLISHED' => 0,
    'LISTEN' => 1,
    'SYN_SENT' || 'SYN_RECV' => 2,
    'CLOSE_WAIT' => 3,
    'TIME_WAIT' => 4,
    'UNCONN' => 5,
    _ => 6,
  };

  List<Map<String, dynamic>> _filteredConnections(List<Map<String, dynamic>> all) {
    final q = _search.trim().toLowerCase();
    final out = <Map<String, dynamic>>[];
    for (final c in all) {
      if (_appFilter != null) {
        final proc = '${c['process'] ?? ''}';
        if (_appFilter == 'system') {
          if (proc.isNotEmpty) continue;
        } else if (proc != _appFilter) {
          continue;
        }
      }
      final proto = '${c['proto'] ?? ''}';
      if (_proto == _ProtoFilter.tcp && !proto.startsWith('tcp')) continue;
      if (_proto == _ProtoFilter.udp && !proto.startsWith('udp')) continue;
      final state = '${c['state'] ?? ''}';
      final scope = '${c['scope'] ?? ''}';
      final listening = _isListeningConn(c);
      switch (_scope) {
        case _ScopeFilter.all:
          break;
        case _ScopeFilter.active:
          if (listening || (state != 'ESTABLISHED' && state != 'SYN_SENT' && state != 'SYN_RECV' && state != 'UNCONN')) continue;
        case _ScopeFilter.listening:
          if (!listening) continue;
        case _ScopeFilter.external:
          if (scope != 'external') continue;
        case _ScopeFilter.lan:
          if (scope != 'lan') continue;
        case _ScopeFilter.loopback:
          if (scope != 'loopback') continue;
      }
      if (q.isNotEmpty) {
        final hay = '${c['process']} ${c['cmdline']} ${c['remoteIp']} ${c['remotePort']} ${c['localIp']} ${c['localPort']} ${c['service']} ${c['pid'] ?? ''} $state $proto'.toLowerCase();
        if (!hay.contains(q)) continue;
      }
      out.add(c);
    }

    out.sort((a, b) {
      switch (_sort) {
        case _MonitorSort.traffic:
          final ra = ((a['rxRate'] as num?) ?? 0) + ((a['txRate'] as num?) ?? 0);
          final rb = ((b['rxRate'] as num?) ?? 0) + ((b['txRate'] as num?) ?? 0);
          final rCmp = rb.compareTo(ra);
          if (rCmp != 0) return rCmp;
          final ba = ((a['rxBytes'] as num?) ?? 0) + ((a['txBytes'] as num?) ?? 0);
          final bb = ((b['rxBytes'] as num?) ?? 0) + ((b['txBytes'] as num?) ?? 0);
          final bCmp = bb.compareTo(ba);
          if (bCmp != 0) return bCmp;
          return '${a['process'] ?? ''}'.toLowerCase().compareTo('${b['process'] ?? ''}'.toLowerCase());
        case _MonitorSort.app:
          final pCmp = '${a['process'] ?? ''}'.toLowerCase().compareTo('${b['process'] ?? ''}'.toLowerCase());
          if (pCmp != 0) return pCmp;
          return ((a['remotePort'] as int?) ?? 0).compareTo((b['remotePort'] as int?) ?? 0);
        case _MonitorSort.state:
          final sCmp = _stateRank('${a['state'] ?? ''}').compareTo(_stateRank('${b['state'] ?? ''}'));
          if (sCmp != 0) return sCmp;
          return '${a['process'] ?? ''}'.toLowerCase().compareTo('${b['process'] ?? ''}'.toLowerCase());
        case _MonitorSort.remote:
          final ipCmp = '${a['remoteIp'] ?? ''}'.compareTo('${b['remoteIp'] ?? ''}');
          if (ipCmp != 0) return ipCmp;
          return ((a['remotePort'] as int?) ?? 0).compareTo((b['remotePort'] as int?) ?? 0);
        case _MonitorSort.port:
          final pa = ((a['remotePort'] as int?) ?? 0) > 0 ? (a['remotePort'] as int) : ((a['localPort'] as int?) ?? 0);
          final pb = ((b['remotePort'] as int?) ?? 0) > 0 ? (b['remotePort'] as int) : ((b['localPort'] as int?) ?? 0);
          final pCmp = pa.compareTo(pb);
          if (pCmp != 0) return pCmp;
          return '${a['process'] ?? ''}'.toLowerCase().compareTo('${b['process'] ?? ''}'.toLowerCase());
      }
    });
    return out;
  }

  static String _endpoint(String ip, int port) {
    final host = ip.contains(':') && !ip.startsWith('[') ? '[$ip]' : ip;
    return port > 0 ? '$host:$port' : host;
  }

  Future<void> _copyTable(List<Map<String, dynamic>> filtered) async {
    try {
      await Clipboard.setData(ClipboardData(text: formatConnectionsMarkdown(filtered)));
      if (mounted) tellOn(this, tr('Copied table to clipboard'));
    } on Object catch (e) {
      if (mounted) tellOn(this, '$e');
    }
  }

  Future<void> _copyEndpoint(String ep) async {
    try {
      await Clipboard.setData(ClipboardData(text: ep));
      if (mounted) tellOn(this, trf('Copied {0}', [ep]));
    } on Object catch (e) {
      if (mounted) tellOn(this, '$e');
    }
  }

  String _sortLabel(_MonitorSort s) => switch (s) {
    _MonitorSort.traffic => tr('Traffic'),
    _MonitorSort.app => tr('App'),
    _MonitorSort.state => tr('State'),
    _MonitorSort.remote => tr('Remote'),
    _MonitorSort.port => tr('Port'),
  };

  Widget _pill(BuildContext context, String text, {Color? color}) {
    final cs = Theme.of(context).colorScheme;
    final fg = color ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, Map<String, dynamic> summary, List<Map<String, dynamic>> filtered) {
    final cs = Theme.of(context).colorScheme;
    final est = (summary['established'] as int?) ?? 0;
    final lis = (summary['listening'] as int?) ?? 0;
    final ext = (summary['external'] as int?) ?? 0;
    final tot = (summary['total'] as int?) ?? 0;
    final rxRate = (summary['rxRate'] as num?) ?? 0;
    final txRate = (summary['txRate'] as num?) ?? 0;
    final rxBytes = (summary['rxBytes'] as num?) ?? 0;
    final txBytes = (summary['txBytes'] as num?) ?? 0;

    return SettingsSection(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          trf('{0} active · {1} listening · {2} external · {3} total', [est, lis, ext, tot]),
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (_paused) _pill(context, tr('Paused'), color: cs.error),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  Text(
                    '↓ ${_formatRate(rxRate)} · ↑ ${_formatRate(txRate)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '↓ ${_formatBytes(rxBytes)} · ↑ ${_formatBytes(txBytes)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('monitor-pause'),
                    onPressed: _togglePause,
                    icon: Icon(_paused ? Icons.play_arrow : Icons.pause, size: 16),
                    label: Text(_paused ? tr('Resume') : tr('Pause')),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('monitor-copy-table'),
                    onPressed: () => _copyTable(filtered),
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(tr('Copy table')),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('monitor-refresh'),
                    onPressed: _load,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(tr('Refresh')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConnectionsView(BuildContext context, List<Map<String, dynamic>> all, List<Map<String, dynamic>> filtered) {
    final cs = Theme.of(context).colorScheme;
    const cap = 150;
    final shown = filtered.take(cap).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('monitor-search'),
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: tr('Filter by app, IP, port, service…'),
                  suffixIcon: _search.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _search = '');
                          },
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${tr('Sort')}: ', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                DropdownButton<_MonitorSort>(
                  key: const ValueKey('monitor-sort'),
                  value: _sort,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final s in _MonitorSort.values) DropdownMenuItem(value: s, child: Text(_sortLabel(s))),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _sort = v);
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              label: tr('Protocol'),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    key: const ValueKey('monitor-proto-all'),
                    tooltip: '${tr('Protocol')}: ${tr('All')}',
                    label: Text(tr('All')),
                    selected: _proto == _ProtoFilter.all,
                    onSelected: (_) => setState(() => _proto = _ProtoFilter.all),
                  ),
                  ChoiceChip(
                    key: const ValueKey('monitor-proto-tcp'),
                    label: Text(tr('TCP')),
                    selected: _proto == _ProtoFilter.tcp,
                    onSelected: (_) => setState(() => _proto = _ProtoFilter.tcp),
                  ),
                  ChoiceChip(
                    key: const ValueKey('monitor-proto-udp'),
                    label: Text(tr('UDP')),
                    selected: _proto == _ProtoFilter.udp,
                    onSelected: (_) => setState(() => _proto = _ProtoFilter.udp),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: tr('Scope'),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    key: const ValueKey('monitor-scope-all'),
                    tooltip: '${tr('Scope')}: ${tr('All')}',
                    label: Text(tr('All')),
                    selected: _scope == _ScopeFilter.all,
                    onSelected: (_) => setState(() => _scope = _ScopeFilter.all),
                  ),
                  ChoiceChip(
                    key: const ValueKey('monitor-scope-active'),
                    label: Text(tr('Active')),
                    selected: _scope == _ScopeFilter.active,
                    onSelected: (_) => setState(() => _scope = _ScopeFilter.active),
                  ),
                  ChoiceChip(
                    key: const ValueKey('monitor-scope-listening'),
                    label: Text(tr('Listening')),
                    selected: _scope == _ScopeFilter.listening,
                    onSelected: (_) => setState(() => _scope = _ScopeFilter.listening),
                  ),
                  ChoiceChip(
                    key: const ValueKey('monitor-scope-external'),
                    label: Text(tr('External')),
                    selected: _scope == _ScopeFilter.external,
                    onSelected: (_) => setState(() => _scope = _ScopeFilter.external),
                  ),
                  ChoiceChip(
                    key: const ValueKey('monitor-scope-lan'),
                    label: Text(tr('LAN')),
                    selected: _scope == _ScopeFilter.lan,
                    onSelected: (_) => setState(() => _scope = _ScopeFilter.lan),
                  ),
                  ChoiceChip(
                    key: const ValueKey('monitor-scope-loopback'),
                    label: Text(tr('Local')),
                    selected: _scope == _ScopeFilter.loopback,
                    onSelected: (_) => setState(() => _scope = _ScopeFilter.loopback),
                  ),
                ],
              ),
            ),
            if (_appFilter != null)
              InputChip(
                key: const ValueKey('monitor-app-filter-chip'),
                label: Text('${tr('App')}: ${_appFilter == 'system' ? tr('system') : _appFilter}'),
                selected: true,
                onDeleted: () => setState(() => _appFilter = null),
              ),
            if (_hasFilters)
              TextButton.icon(
                key: const ValueKey('monitor-clear-filters'),
                onPressed: _clearFilters,
                icon: const Icon(Icons.clear, size: 16),
                label: Text(tr('Clear filters')),
              ),
          ],
        ),
        const SizedBox(height: 10),
        SettingsSection(
          title: trf('Showing {0} of {1} connections', [filtered.length, all.length]),
          note: filtered.length > cap ? trf('Showing first 150 of {0} connections. Use search or filters to narrow down.', [filtered.length]) : null,
          children: [
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Text(
                  tr('No connections match the current filters.'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              )
            else
              ...() {
                final seenKeys = <String, int>{};
                return [
                  for (final c in shown)
                    () {
                      final rawId = '${c['id'] ?? ''}';
                      final n = (seenKeys[rawId] ?? 0) + 1;
                      seenKeys[rawId] = n;
                      final rowId = n == 1 ? rawId : '$rawId#$n';
                      return _buildConnectionRow(context, c, rowId);
                    }(),
                ];
              }(),
          ],
        ),
      ],
    );
  }

  Widget _buildConnectionRow(BuildContext context, Map<String, dynamic> c, String id) {
    final cs = Theme.of(context).colorScheme;
    final proto = '${c['proto'] ?? ''}'.toUpperCase();
    final state = '${c['state'] ?? ''}';
    final proc = '${c['process'] ?? ''}';
    final service = '${c['service'] ?? ''}';
    final scope = '${c['scope'] ?? ''}';
    final localIp = '${c['localIp'] ?? ''}';
    final localPort = (c['localPort'] as int?) ?? 0;
    final remoteIp = '${c['remoteIp'] ?? ''}';
    final remotePort = (c['remotePort'] as int?) ?? 0;
    final pid = c['pid'] as int?;
    final cmdline = '${c['cmdline'] ?? ''}';
    final rxBytes = (c['rxBytes'] as num?) ?? 0;
    final txBytes = (c['txBytes'] as num?) ?? 0;
    final rxRate = (c['rxRate'] as num?) ?? 0;
    final txRate = (c['txRate'] as num?) ?? 0;
    final rttMs = c['rttMs'] as num?;

    final localEp = _endpoint(localIp, localPort);
    final remoteEp = _endpoint(remoteIp, remotePort);
    final hasRemote = remotePort > 0 && remoteIp.isNotEmpty && remoteIp != '0.0.0.0' && remoteIp != '::' && remoteIp != '*';
    final primaryEp = hasRemote ? remoteEp : localEp;
    final expanded = _expandedIds.contains(id);

    final Color stateColor = switch (state) {
      'ESTABLISHED' => Colors.green.shade600,
      'LISTEN' => cs.primary,
      'SYN_SENT' || 'SYN_RECV' => Colors.orange.shade700,
      _ => cs.onSurfaceVariant,
    };
    final String scopeLabel = switch (scope) {
      'external' => tr('External'),
      'lan' => tr('LAN'),
      'any' => tr('All interfaces'),
      _ => tr('Local'),
    };
    final rateSum = rxRate + txRate;
    final bytesSum = rxBytes + txBytes;

    return Column(
      key: ValueKey('monitor-conn-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (expanded) {
              _expandedIds.remove(id);
            } else {
              _expandedIds.add(id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            proc.isNotEmpty ? proc : tr('system'),
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          _pill(context, proto, color: cs.primary),
                          if (service.isNotEmpty) _pill(context, service, color: cs.tertiary),
                          _pill(context, state, color: stateColor),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$primaryEp · $scopeLabel',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (rateSum > 0)
                  Text(
                    '↓ ${_formatRate(rxRate)} ↑ ${_formatRate(txRate)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
                  )
                else if (bytesSum > 0)
                  Text(
                    '↓ ${_formatBytes(rxBytes)} ↑ ${_formatBytes(txBytes)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                const SizedBox(width: 6),
                Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    Text('${tr('Local')}: $localEp', style: Theme.of(context).textTheme.bodySmall),
                    Text('${tr('Remote')}: $remoteEp', style: Theme.of(context).textTheme.bodySmall),
                    if (pid != null) Text('${tr('PID')}: $pid', style: Theme.of(context).textTheme.bodySmall),
                    if (rttMs != null) Text('${tr('RTT')}: $rttMs ms', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                if (bytesSum > 0 || rateSum > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${tr('Traffic')}: ↓ ${_formatBytes(rxBytes)} (${_formatRate(rxRate)}) · ↑ ${_formatBytes(txBytes)} (${_formatRate(txRate)})',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
                if (cmdline.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${tr('Command')}: $cmdline',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('monitor-filter-app'),
                      onPressed: () => _filterByApp(proc.isNotEmpty ? proc : 'system'),
                      icon: const Icon(Icons.filter_alt_outlined, size: 14),
                      label: Text(tr('Filter by this app')),
                      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('monitor-copy-endpoint'),
                      onPressed: () => _copyEndpoint(primaryEp),
                      icon: const Icon(Icons.copy, size: 14),
                      label: Text(tr('Copy endpoint')),
                      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildByAppView(BuildContext context, List<Map<String, dynamic>> procs) {
    final cs = Theme.of(context).colorScheme;
    final q = _search.trim().toLowerCase();
    final filtered = [
      for (final p in procs)
        if (q.isEmpty || '${p['name']}'.toLowerCase().contains(q)) p,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('monitor-app-search'),
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: tr('Filter apps by name…'),
                  suffixIcon: _search.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _search = '');
                          },
                        ),
                ),
              ),
            ),
            if (_search.trim().isNotEmpty) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                key: const ValueKey('monitor-app-clear-filters'),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _search = '');
                },
                icon: const Icon(Icons.clear, size: 16),
                label: Text(tr('Clear filters')),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        SettingsSection(
          title: tr('By app'),
          children: [
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Text(
                  tr('No apps match the current filter.'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              )
            else
              for (final p in filtered)
                SettingsItem(
                  key: ValueKey('monitor-app-${p['name']}'),
                  leading: const Icon(Icons.apps, size: 20),
                  title: '${p['name']}',
                  description: [
                    trf('{0} connections', [p['connections']]),
                    if (((p['external'] as int?) ?? 0) > 0) trf('{0} external', [p['external']]),
                    if (((p['listening'] as int?) ?? 0) > 0) trf('{0} listening', [p['listening']]),
                  ].join(' · '),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if ((((p['rxRate'] as num?) ?? 0) + ((p['txRate'] as num?) ?? 0)) > 0)
                            Text(
                              '↓ ${_formatRate((p['rxRate'] as num?) ?? 0)} ↑ ${_formatRate((p['txRate'] as num?) ?? 0)}',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
                            ),
                          if ((((p['rxBytes'] as num?) ?? 0) + ((p['txBytes'] as num?) ?? 0)) > 0)
                            Text(
                              '↓ ${_formatBytes((p['rxBytes'] as num?) ?? 0)} ↑ ${_formatBytes((p['txBytes'] as num?) ?? 0)}',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                        ],
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                  onTap: () => _filterByApp('${p['name']}'),
                ),
          ],
        ),
      ],
    );
  }

  static IconData _ifaceIcon(String kind) => switch (kind) {
    'wifi' => Icons.wifi,
    'ethernet' => Icons.settings_ethernet,
    'vpn' => Icons.vpn_key_outlined,
    'loopback' => Icons.loop,
    _ => Icons.lan_outlined,
  };

  Widget _buildInterfacesView(BuildContext context, List<Map<String, dynamic>> ifaces, List<String> dns) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: tr('Interfaces'),
          children: [
            if (ifaces.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Text(
                  tr('No interfaces found.'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              )
            else
              for (final i in ifaces)
                Padding(
                  key: ValueKey('monitor-iface-${i['name']}'),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _ifaceIcon('${i['kind'] ?? 'other'}'),
                            size: 20,
                            color: i['state'] == 'up' ? cs.primary : cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              '${i['name']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _pill(
                            context,
                            i['state'] == 'up' ? tr('UP') : tr('DOWN'),
                            color: i['state'] == 'up' ? Colors.green.shade600 : cs.onSurfaceVariant,
                          ),
                          const Spacer(),
                          Text(
                            '↓ ${_formatRate((i['rxRate'] as num?) ?? 0)} · ↑ ${_formatRate((i['txRate'] as num?) ?? 0)}',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 14,
                        runSpacing: 4,
                        children: [
                          if ('${i['ip'] ?? ''}'.isNotEmpty) Text('IPv4: ${i['ip']}', style: Theme.of(context).textTheme.bodySmall),
                          if ('${i['ipv6'] ?? ''}'.isNotEmpty) Text('IPv6: ${i['ipv6']}', style: Theme.of(context).textTheme.bodySmall),
                          if ('${i['mac'] ?? ''}'.isNotEmpty) Text('${tr('MAC')}: ${i['mac']}', style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 14,
                        runSpacing: 4,
                        children: [
                          Text(
                            '↓ ${_formatBytes((i['rxBytes'] as num?) ?? 0)} · ↑ ${_formatBytes((i['txBytes'] as num?) ?? 0)}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          Text(
                            trf('Errors: {0} · Dropped: {1}', [
                              ((i['rxErrors'] as int?) ?? 0) + ((i['txErrors'] as int?) ?? 0),
                              ((i['rxDropped'] as int?) ?? 0) + ((i['txDropped'] as int?) ?? 0),
                            ]),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
          ],
        ),
        const SizedBox(height: SettingsMetrics.sectionGap),
        SettingsSection(
          title: tr('DNS servers'),
          children: [
            if (dns.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Text(
                  tr('No DNS servers found.'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              )
            else
              for (final server in dns)
                SettingsItem(
                  key: ValueKey('monitor-dns-$server'),
                  leading: const Icon(Icons.dns_outlined, size: 18),
                  title: server,
                  trailing: IconButton(
                    tooltip: tr('Copy IP'),
                    icon: const Icon(Icons.copy, size: 16),
                    onPressed: () => _copyEndpoint(server),
                  ),
                ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      if (_error != null) {
        return SettingsSection(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Expanded(child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    key: const ValueKey('monitor-retry'),
                    onPressed: _load,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(tr('Retry')),
                  ),
                ],
              ),
            ),
          ],
        );
      }
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
    }

    final summary = (d['summary'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final connections = ((d['connections'] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final processes = ((d['processes'] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final interfaces = ((d['interfaces'] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final dns = ((d['dns'] as List?) ?? const []).map((e) => '$e').toList();
    final filtered = _filteredConnections(connections);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSummaryCard(context, summary, filtered),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: const ValueKey('monitor-view-connections'),
              label: Text(tr('Connections')),
              selected: _subView == _MonitorSubView.connections,
              onSelected: (_) => setState(() => _subView = _MonitorSubView.connections),
            ),
            ChoiceChip(
              key: const ValueKey('monitor-view-apps'),
              label: Text(tr('By app')),
              selected: _subView == _MonitorSubView.byApp,
              onSelected: (_) => setState(() => _subView = _MonitorSubView.byApp),
            ),
            ChoiceChip(
              key: const ValueKey('monitor-view-interfaces'),
              label: Text(tr('Interfaces')),
              selected: _subView == _MonitorSubView.interfaces,
              onSelected: (_) => setState(() => _subView = _MonitorSubView.interfaces),
            ),
          ],
        ),
        const SizedBox(height: 14),
        switch (_subView) {
          _MonitorSubView.connections => _buildConnectionsView(context, connections, filtered),
          _MonitorSubView.byApp => _buildByAppView(context, processes),
          _MonitorSubView.interfaces => _buildInterfacesView(context, interfaces, dns),
        },
      ],
    );
  }
}

/// The network's password (shown on request).
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.ssid, this.note, this.title});
  final String ssid;
  final String? note;
  final String? title;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _field = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  bool get _ok {
    final bytes = utf8.encode(_field.text).length;
    return bytes >= 8 && bytes <= 63;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title ?? trf('Connect to {0}', [widget.ssid])),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.note != null) ...[
              Text(
                widget.note!,
                key: const ValueKey('wifi-password-note'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.error),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const ValueKey('wifi-password'),
              controller: _field,
              autofocus: true,
              obscureText: !_show,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _ok ? Navigator.pop(context, _field.text) : null,
              decoration: InputDecoration(
                hintText: tr('Password'),
                suffixIcon: IconButton(
                  tooltip: _show ? tr('Hide password') : tr('Show password'),
                  onPressed: () => setState(() => _show = !_show),
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility, size: 18),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(
          key: const ValueKey('wifi-connect'),
          onPressed: _ok ? () => Navigator.pop(context, _field.text) : null,
          child: Text(tr('Connect')),
        ),
      ],
    );
  }
}
