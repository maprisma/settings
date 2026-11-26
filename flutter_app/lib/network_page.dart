import 'dart:convert' show utf8;

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'package:maprisma_ui/settings.dart';

/// Network & Wireless, as COSMIC Settings' Wi-Fi, Wired and VPN pages: the Wi-Fi switch, known
/// networks (connect, disconnect, forget), visible networks (connect, with a password when
/// needed), wired and VPN connections. Hyprland: `network.*` (nmcli). Maprisma WLAN Monitor
/// opens for the details.
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
  );
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
    for (var attempt = 0; attempt < _maxPasswordAttempts && mounted; attempt++) {
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
    for (var attempt = 0; attempt < _maxPasswordAttempts && mounted; attempt++) {
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
      ...reloadActions(),
    ];
    if (d == null) return SettingsPage(title: tr('Network & Wireless'), actions: actions, children: loadingOrError(context));
    final known = (d['known'] as List).cast<Map>();
    final visible = [for (final v in (d['visible'] as List).cast<Map>()) if (v['known'] != true) v];
    final wired = (d['wired'] as List).cast<Map>();
    final wiredDevices = (d['wiredDevices'] as List).cast<Map>();
    final vpn = (d['vpn'] as List).cast<Map>();
    return SettingsPage(
      title: tr('Network & Wireless'),
      actions: actions,
      children: [
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
      ],
    );
  }
}

/// The network's password (shown on request).
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.ssid, this.note, this.title, this.confirmLabel});
  final String ssid;
  final String? note;
  final String? title;
  final String? confirmLabel;
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
          child: Text(widget.confirmLabel ?? tr('Connect')),
        ),
      ],
    );
  }
}
