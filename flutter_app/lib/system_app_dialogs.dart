import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'app_icon.dart';
import 'backend.dart' show ServiceError;
import 'core_call.dart';

typedef SysApp = Map<String, dynamic>;

String formatBytes(int bytes) {
  const units = ['B', 'kB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}

String formatEpoch(Object? seconds) {
  if (seconds is! int || seconds <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  String two(int v) => '$v'.padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

String sysAppSourceLabel(String source) => switch (source) {
  'pacman' => 'pacman',
  'aur' => 'AUR',
  'flatpak' => 'Flatpak',
  'snap' => 'Snap',
  'appimage' => 'AppImage',
  'webapp' => tr('Web app'),
  'apt' => 'apt',
  'dnf' => 'dnf',
  'zypper' => 'zypper',
  'local' => tr('Local'),
  _ => source,
};

String sysAppKindLabel(String kind) => switch (kind) {
  'app' => tr('Application'),
  'flatpak' => 'Flatpak',
  'snap' => 'Snap',
  'appimage' => 'AppImage',
  'webapp' => tr('Web app'),
  'terminal' => tr('Terminal app'),
  _ => kind,
};

String sysAppRoleLabel(String role) => switch (role) {
  'browser' => tr('Web browser'),
  'files' => tr('File manager'),
  'mail' => tr('Mail client'),
  'music' => tr('Music'),
  'video' => tr('Video'),
  'photos' => tr('Photos'),
  'calendar' => tr('Calendar'),
  'text' => tr('Text editor'),
  _ => role,
};

/// Details of an installed non-Maprisma app (mirroring Maprisma Apps' DetailsDialog).
class SystemAppDetailsDialog extends StatelessWidget {
  const SystemAppDetailsDialog({super.key, required this.core, required this.app});
  final CoreCall core;
  final SysApp app;

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
  );

  Widget _line(BuildContext context, String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 130, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(child: value),
      ],
    ),
  );

  Widget _copyable(BuildContext context, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: SelectableText(text)),
      IconButton(
        tooltip: tr('Copy'),
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        onPressed: () {
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(tr('Copied'))));
        },
        icon: const Icon(Icons.copy),
      ),
    ],
  );

  Widget _link(BuildContext context, String url) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        InkWell(
          onTap: () async {
            try {
              await core('system_apps.open_url', {'url': url});
            } on ServiceError catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Not opened: {0}', [e.reason ?? e.code]))));
              }
            }
          },
          child: Text(url, style: TextStyle(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary)),
        ),
        IconButton(
          tooltip: tr('Copy'),
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(tr('Copied'))));
          },
          icon: const Icon(Icons.copy),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = app['icon'] as Map? ?? const {};
    final pkg = app['package'] as Map?;
    final update = app['update'] as Map?;
    final roles = (app['defaultRoles'] as List?)?.cast<String>() ?? const <String>[];
    final desc = '${app['description'] ?? ''}'.trim();
    final website = '${app['website'] ?? ''}'.trim();
    final desktopPath = '${app['desktopPath'] ?? ''}'.trim();
    final program = '${app['program'] ?? ''}'.trim();
    final exec = '${app['exec'] ?? ''}'.trim();
    final version = '${app['version'] ?? ''}'.trim();
    final statusParts = <String>[
      if (app['running'] == true) tr('Running'),
      if (app['autostart'] == true) tr('Starts at login'),
    ];
    final sizeText = pkg?['size'] is int
        ? formatBytes(pkg!['size'] as int)
        : ('${pkg?['sizeText'] ?? ''}'.isNotEmpty ? '${pkg!['sizeText']}' : '');
    final installedDate = formatEpoch(pkg?['installed']);
    final fileSize = app['fileSize'] is int ? formatBytes(app['fileSize'] as int) : '';
    final modifiedDate = formatEpoch(app['modified']);

    return AlertDialog(
      title: Row(
        children: [
          AppIcon(icon['file'] as String?, size: 36),
          const SizedBox(width: 12),
          Expanded(child: Text('${app['name']}')),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (desc.isNotEmpty) Text(desc, style: TextStyle(color: scheme.onSurfaceVariant)),
              _heading(tr('Application')),
              _line(context, tr('Type'), SelectableText(sysAppKindLabel('${app['kind'] ?? 'app'}'))),
              _line(context, tr('Source'), SelectableText(sysAppSourceLabel('${app['source'] ?? 'local'}'))),
              if ('${app['desktopId'] ?? ''}'.isNotEmpty)
                _line(context, tr('ID'), SelectableText('${app['desktopId']}')),
              if (statusParts.isNotEmpty)
                _line(context, tr('State'), SelectableText(statusParts.join(' · '))),
              if (roles.isNotEmpty)
                _line(context, tr('Default app for'), SelectableText(roles.map(sysAppRoleLabel).join(', '))),
              if (pkg != null || version.isNotEmpty || update != null || website.isNotEmpty) ...[
                _heading(tr('Package')),
                if (pkg?['name'] != null)
                  _line(context, tr('Package'), SelectableText('${pkg!['name']}')),
                if (version.isNotEmpty)
                  _line(context, tr('Version'), SelectableText(version)),
                if (update != null)
                  _line(
                    context,
                    tr('Updates'),
                    SelectableText(trf('Update available: {0} → {1}', [
                      '${update['installed'] ?? ''}'.isEmpty ? tr('unknown') : update['installed'],
                      update['available'],
                    ])),
                  ),
                if ('${pkg?['remote'] ?? ''}'.isNotEmpty)
                  _line(context, tr('Remote'), SelectableText('${pkg!['remote']}')),
                if (sizeText.isNotEmpty)
                  _line(context, tr('Installed size'), SelectableText(sizeText)),
                if (installedDate.isNotEmpty)
                  _line(context, tr('Installed'), SelectableText(installedDate)),
                if (website.isNotEmpty)
                  _line(context, tr('Website'), RegExp(r'^https?://').hasMatch(website) ? _link(context, website) : SelectableText(website)),
              ],
              if (desktopPath.isNotEmpty || program.isNotEmpty || exec.isNotEmpty || fileSize.isNotEmpty) ...[
                _heading(tr('Files')),
                if (desktopPath.isNotEmpty) _line(context, tr('Desktop file'), _copyable(context, desktopPath)),
                if (program.isNotEmpty) _line(context, tr('Program'), _copyable(context, program)),
                if (exec.isNotEmpty) _line(context, tr('Command'), _copyable(context, exec)),
                if (fileSize.isNotEmpty) _line(context, tr('File size'), SelectableText(fileSize)),
                if (modifiedDate.isNotEmpty) _line(context, tr('Last changed'), SelectableText(modifiedDate)),
              ],
            ],
          ),
        ),
      ),
      actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
    );
  }
}

/// "Do you want to uninstall …?" for a non-Maprisma app (mirroring RemoveDialog).
class SystemRemoveDialog extends StatefulWidget {
  const SystemRemoveDialog({super.key, required this.core, required this.app});
  final CoreCall core;
  final SysApp app;
  @override
  State<SystemRemoveDialog> createState() => _SystemRemoveDialogState();
}

class _SystemRemoveDialogState extends State<SystemRemoveDialog> {
  Map<String, dynamic>? plan;
  bool deleteData = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.core('system_apps.remove_plan', {'id': widget.app['id']});
      if (mounted) setState(() => plan = p);
    } on ServiceError catch (e) {
      if (mounted) setState(() => error = e.reason ?? e.code);
    }
  }

  String _short(String path) {
    final home = RegExp(r'^/home/[^/]+/').firstMatch(path);
    return home == null ? path : '~/${path.substring(home.end)}';
  }

  Widget _items(String title, List items, {required bool goes}) {
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text('$title (${items.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        for (final e in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(goes ? Icons.remove_circle_outline : Icons.shield_outlined, size: 14, color: goes ? scheme.error : scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: _short('${(e as Map)['path']}')),
                      if (e['kind'] == 'package')
                        TextSpan(
                          text: '  (${sysAppSourceLabel('${e['manager'] ?? 'pacman'}')}${'${e['version'] ?? ''}'.isEmpty ? '' : ' ${e['version']}'})',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      if (e['kind'] == 'flatpak')
                        TextSpan(
                          text: '  (Flatpak${'${e['version'] ?? ''}'.isEmpty ? '' : ' ${e['version']}'})',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      if (e['why'] != null) TextSpan(text: ': ${e['why']}', style: TextStyle(color: scheme.onSurfaceVariant)),
                    ]),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = plan;
    final blocked = p?['blocked'] as String?;
    final roles = (p?['defaultRoles'] as List?)?.cast<String>() ?? const <String>[];
    final goes = (p?['goes'] as List?) ?? const [];
    final stays = (p?['stays'] as List?) ?? const [];
    final canDeleteData = p?['canDeleteData'] == true;
    final needsPassword = p?['needsPassword'] == true;

    return AlertDialog(
      title: Text(trf('Do you want to uninstall {0}?', [widget.app['name']])),
      content: SizedBox(
        width: 560,
        child: error != null
            ? Text(error!, style: TextStyle(color: scheme.error))
            : p == null
            ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (blocked != null)
                      Text(blocked, style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
                    if (roles.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: blocked != null ? 8 : 0, bottom: 4),
                        child: Text(
                          trf('{0} is your default app for: {1}.', [widget.app['name'], roles.map(sysAppRoleLabel).join(', ')]),
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    _items(tr('Goes'), goes, goes: true),
                    _items(tr('Stays'), deleteData ? const [] : stays, goes: false),
                    if (canDeleteData)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: deleteData,
                        onChanged: (v) => setState(() => deleteData = v ?? false),
                        title: Text(tr('Also delete its app data')),
                        subtitle: Text('~/.var/app/${p['what']}'),
                      ),
                    if (needsPassword && blocked == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(tr('Maprisma asks for your password first.'), style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(
          key: const ValueKey('system-uninstall-go'),
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          onPressed: p == null || blocked != null
              ? null
              : () => Navigator.pop(context, {'delete_data': deleteData, 'password': needsPassword}),
          child: Text(tr('Uninstall')),
        ),
      ],
    );
  }
}
