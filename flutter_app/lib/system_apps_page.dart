import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'app_icon.dart';
import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'job_sheet.dart';
import 'jobs_model.dart';
import 'settings_widgets.dart' show pageTitleStyle;
import 'system_app_dialogs.dart';
import 'theme.dart';
import 'window.dart';

/// All installed non-Maprisma apps in one filterable, grouped list matching Maprisma Apps:
/// sections by source (System packages, AUR, Flatpak, Snap, AppImages, Web apps, Local apps),
/// update marks, running & autostart marks, per-section Update all, ⋮ menu (and right-click),
/// Details & Uninstall dialogs, and the live job log sheet at the bottom.
class SystemAppsPage extends StatefulWidget {
  const SystemAppsPage({
    super.key,
    required this.core,
    required this.jobs,
    this.checkOnStart = true,
  });

  final CoreCall core;
  final JobsModel jobs;
  final bool checkOnStart;

  @override
  State<SystemAppsPage> createState() => SystemAppsPageState();
}

class SystemAppsPageState extends State<SystemAppsPage> {
  List<SysApp> apps = [];
  bool loading = true;
  bool checking = false;
  String? error;
  String query = '';

  /// The legend's choice: only apps with this mark (`update`, `running`, `autostart`, `job`); null: all.
  String? markFilter;
  bool sheet = false;
  final filter = TextEditingController();
  final filterFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.jobs.onFinished = _jobEnded;
    widget.jobs.addListener(_jobsChanged);
    unawaited(_load().then((_) {
      if (widget.checkOnStart) unawaited(checkUpdates());
    }));
  }

  @override
  void dispose() {
    widget.jobs.removeListener(_jobsChanged);
    filter.dispose();
    filterFocus.dispose();
    super.dispose();
  }

  void _jobsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final r = await widget.core('system_apps.list');
      if (!mounted) return;
      setState(() {
        apps = [for (final x in (r['apps'] as List?) ?? const []) Map<String, dynamic>.from(x as Map)];
        loading = false;
        error = null;
      });
    } on ServiceError catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = trf('The list could not be read ({0}{1})', [e.code, e.reason == null ? '' : ': ${e.reason}']);
        });
      }
    }
  }

  Future<void> reload() => _load();

  Future<void> checkUpdates({bool force = false}) async {
    if (checking) return;
    setState(() => checking = true);
    try {
      await widget.core('system_apps.check_updates', {'force': force}).catchError((_) => <String, dynamic>{});
      await _load();
      if (force && mounted) {
        final n = apps.where((a) => a['update'] != null).length;
        tell(n == 0 ? tr('Everything is up to date') : (n == 1 ? tr('1 app has an update') : trf('{0} apps have updates', [n])));
      }
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  void tell(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  void _jobEnded(JobView j) {
    unawaited(_load());
    if (!mounted) return;
    final r = j.result;
    tell(switch (j.state) {
      'succeeded' => r['message'] is String && (r['message'] as String).isNotEmpty ? '${j.name}: ${r['message']}' : trf('{0}: done', [j.name]),
      'cancelled' => trf('{0}: cancelled, nothing was changed', [j.name]),
      _ => '${j.name}: ${r['message'] ?? r['code'] ?? j.state}',
    });
  }

  Future<void> _do(String route, Map<String, dynamic> params, {String? done, bool reloadAfter = false}) async {
    try {
      await widget.core(route, params);
      if (done != null) tell(done);
    } on ServiceError catch (e) {
      tell(trf('That did not work ({0}){1}', [e.code, e.reason == null || e.reason!.isEmpty ? '' : ': ${e.reason}']));
    }
    if (reloadAfter) await _load();
  }

  bool _needsPassword(SysApp a, String kind) {
    final source = a['source'] as String? ?? '';
    if (kind == 'remove') return const {'pacman', 'aur', 'snap', 'apt', 'dnf', 'zypper'}.contains(source);
    return source == 'pacman';
  }

  Future<void> startJob(String appId, String name, String kind, {Map<String, dynamic> options = const {}, bool password = false}) async {
    try {
      await widget.jobs.start(app: appId, name: name, kind: kind, options: options, password: password);
      setState(() => sheet = true);
    } on ServiceError catch (e) {
      tell('$name: ${e.reason ?? e.code}');
    }
  }

  bool _busy(SysApp a) => widget.jobs.jobs.any((j) => (j.app == a['id'] || (a['source'] == 'pacman' && j.app == '_pacman_system')) && !j.finished);

  bool _matches(SysApp a, String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return true;
    final pkgName = '${(a['package'] as Map?)?['name'] ?? ''}'.toLowerCase();
    return '${a['name']}'.toLowerCase().contains(s) ||
        '${a['description'] ?? ''}'.toLowerCase().contains(s) ||
        '${a['desktopId'] ?? ''}'.toLowerCase().contains(s) ||
        pkgName.contains(s) ||
        sysAppSourceLabel('${a['source'] ?? ''}').toLowerCase().contains(s);
  }

  bool _hasMark(SysApp a, String mark) => switch (mark) {
    'update' => a['update'] != null,
    'running' => a['running'] == true,
    'autostart' => a['autostart'] == true,
    'job' => _busy(a),
    _ => false,
  };

  List<(String, String, List<SysApp>)> _sections(List<SysApp> list) {
    List<SysApp> pick(bool Function(SysApp) test) => [for (final a in list) if (test(a)) a];
    return [
      ('system', tr('System packages'), pick((a) => const {'pacman', 'apt', 'dnf', 'zypper'}.contains(a['source']))),
      ('aur', tr('AUR'), pick((a) => a['source'] == 'aur')),
      ('flatpak', tr('Flatpak'), pick((a) => a['source'] == 'flatpak')),
      ('snap', tr('Snap'), pick((a) => a['source'] == 'snap')),
      ('appimage', tr('AppImages'), pick((a) => a['source'] == 'appimage')),
      ('webapp', tr('Web apps'), pick((a) => a['source'] == 'webapp')),
      ('local', tr('Local apps'), pick((a) => a['source'] == 'local')),
    ];
  }

  Future<void> openDetails(SysApp a) async {
    await showDialog<void>(context: context, builder: (_) => SystemAppDetailsDialog(core: widget.core, app: a));
  }

  Future<void> _uninstall(SysApp a) async {
    final go = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => SystemRemoveDialog(core: widget.core, app: a));
    if (go != null) {
      await startJob(
        a['id'] as String,
        '${a['name']}',
        'remove',
        options: {'delete_data': go['delete_data'] == true},
        password: go['password'] == true,
      );
    }
  }

  Future<void> updateAll([List<SysApp>? scope]) async {
    final candidates = (scope ?? apps).where((a) => a['update'] != null).toList();
    if (candidates.isEmpty) {
      tell(tr('Everything is up to date'));
      return;
    }
    final hasPacman = candidates.any((a) => a['source'] == 'pacman');
    final hasAur = candidates.any((a) => a['source'] == 'aur');
    final flatpaks = [for (final a in candidates) if (a['source'] == 'flatpak') a];
    final scheme = Theme.of(context).colorScheme;

    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(candidates.length == 1 ? tr('Update 1 app?') : trf('Update {0} apps?', [candidates.length])),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in candidates)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('• ${a['name']}  (${(a['update'] as Map)['installed'] ?? ''} → ${(a['update'] as Map)['available']})'),
                  ),
                if (hasPacman) ...[
                  const SizedBox(height: 10),
                  Text(
                    tr('System packages are upgraded together with pacman -Syu. Maprisma asks for your password first.'),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
                if (hasAur) ...[
                  const SizedBox(height: 8),
                  Text(
                    tr('AUR updates open in your terminal so you can review them.'),
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(key: const ValueKey('system-update-all-go'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Update all'))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    if (hasPacman) {
      await startJob('_pacman_system', tr('System packages'), 'update', password: true);
      if (!mounted) return;
    }
    for (final a in flatpaks) {
      await startJob(a['id'] as String, '${a['name']}', 'update');
      if (!mounted) return;
    }
    if (hasAur) {
      await startJob('_aur_all', tr('AUR'), 'update');
    }
  }

  List<PopupMenuEntry<String>> menuItems(SysApp a) {
    final busy = _busy(a);
    final update = a['update'] as Map?;
    final actions = (a['actions'] as List?)?.cast<Map>() ?? const <Map>[];
    final website = '${a['website'] ?? ''}'.trim();
    final desktopPath = '${a['desktopPath'] ?? ''}'.trim();
    final exec = '${a['exec'] ?? ''}'.trim();
    final autostart = a['autostart'] == true;

    PopupMenuItem<String> item(String value, String text, {bool enabled = true}) =>
        PopupMenuItem(value: value, enabled: enabled, child: Text(text));

    return [
      item('open', tr('Open'), enabled: a['canOpen'] == true),
      for (final act in actions)
        item('action:${act['id']}', '${act['name']}'),
      item('details', tr('Details…')),
      const PopupMenuDivider(),
      if (update != null)
        item('update', trf('Update ({0})', [update['available']]), enabled: !busy),
      if (a['canReinstall'] == true)
        item('reinstall', tr('Reinstall'), enabled: !busy),
      if (a['autostartSupported'] == true)
        item('autostart', autostart ? tr('Remove from startup') : tr('Start at login')),
      const PopupMenuDivider(),
      if (website.isNotEmpty) ...[
        item('website', tr('Open website')),
        item('copyurl', tr('Copy website URL')),
      ],
      if (desktopPath.isNotEmpty) item('copydesktop', tr('Copy desktop file path')),
      if (exec.isNotEmpty) item('copyexec', tr('Copy command')),
      if (a['canUninstall'] == true) ...[
        const PopupMenuDivider(),
        item('remove', tr('Uninstall…'), enabled: !busy),
      ],
    ];
  }

  Future<void> menu(SysApp a, Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: menuItems(a),
    );
    if (choice != null) await act(a, choice);
  }

  Future<void> act(SysApp a, String choice) async {
    switch (choice) {
      case 'open':
        await _do('system_apps.open', {'id': a['id']});
      case final String c when c.startsWith('action:'):
        await _do('system_apps.open', {'id': a['id'], 'action': c.substring(7)});
      case 'details':
        await openDetails(a);
      case 'update':
        await startJob(a['id'] as String, '${a['name']}', 'update', password: _needsPassword(a, 'update'));
      case 'reinstall':
        await startJob(a['id'] as String, '${a['name']}', 'reinstall', password: _needsPassword(a, 'reinstall'));
      case 'autostart':
        final next = a['autostart'] != true;
        await _do(
          'system_apps.autostart',
          {'id': a['id'], 'on': next},
          done: next ? trf('{0} starts at login', [a['name']]) : trf('{0} removed from startup', [a['name']]),
          reloadAfter: true,
        );
      case 'website':
        await _do('system_apps.open_url', {'url': a['website']});
      case 'copyurl':
        await Clipboard.setData(ClipboardData(text: '${a['website']}'));
        tell(tr('Copied'));
      case 'copydesktop':
        await Clipboard.setData(ClipboardData(text: '${a['desktopPath']}'));
        tell(tr('Copied'));
      case 'copyexec':
        await Clipboard.setData(ClipboardData(text: '${a['exec']}'));
        tell(tr('Copied'));
      case 'remove':
        await _uninstall(a);
    }
  }

  Future<void> _legend(Offset at) async {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    final rows = [
      ('update', Icon(Icons.arrow_circle_up, size: 16, color: marks.update), tr('Update available: Update in its menu or Update all')),
      ('running', Icon(Icons.circle, size: 10, color: marks.running), tr('Running now')),
      ('autostart', Icon(Icons.login, size: 15, color: scheme.onSurfaceVariant), tr('Starts at login')),
      ('job', const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, value: 0.75)), tr('A job is running for it')),
    ];
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(enabled: false, child: Text(tr('What the marks mean'))),
        for (final (id, mark, text) in rows)
          PopupMenuItem(
            key: ValueKey('system-legend-$id'),
            value: id,
            child: Tooltip(
              message: tr('Show only these (click again or Esc: all)'),
              child: Row(
                children: [
                  SizedBox(width: 22, child: Center(child: mark)),
                  const SizedBox(width: 8),
                  Flexible(child: Text(text)),
                  if (markFilter == id) const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.check, size: 16)),
                ],
              ),
            ),
          ),
      ],
    );
    if (choice == null || !mounted) return;
    setState(() => markFilter = markFilter == choice ? null : choice);
  }

  Widget _sectionLine(String id, String title, List<SysApp> items, {required bool narrow, required bool running}) {
    final scheme = Theme.of(context).colorScheme;
    final n = items.where((a) => a['update'] != null).length;
    final color = markColors(context).update;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 12, n > 0 ? 4 : 12, n > 0 ? 0 : 4),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                Text('${items.length}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (n > 0)
            Tooltip(
              message: trf('Update the apps of "{0}" (Ctrl+U: all)', [title]),
              child: TextButton.icon(
                key: ValueKey('system-update-all-$id'),
                style: TextButton.styleFrom(foregroundColor: color, visualDensity: VisualDensity.compact),
                onPressed: running ? null : () => updateAll(items),
                icon: Icon(Icons.arrow_circle_up, size: 16, color: running ? null : color),
                label: Text(narrow ? '$n' : trf('Update all ({0})', [n])),
              ),
            ),
        ],
      ),
    );
  }

  Widget _mark(String tooltip, IconData icon, Color color, {double size = 16}) => Padding(
    padding: const EdgeInsets.only(left: 8),
    child: Tooltip(message: tooltip, child: Icon(icon, size: size, color: color)),
  );

  Widget _chip(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(cornerSizes(context).control),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
    );
  }

  String _subtitle(SysApp a) {
    final desc = '${a['description'] ?? ''}'.trim();
    final parts = <String>[
      if (desc.isNotEmpty) desc else sysAppKindLabel('${a['kind'] ?? 'app'}'),
      if (a['running'] == true) tr('running'),
    ];
    return parts.join(' · ');
  }

  Widget _row(SysApp a) {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    final icon = a['icon'] as Map? ?? const {};
    final version = '${a['version'] ?? ''}'.trim();
    final update = a['update'] as Map?;
    final roles = (a['defaultRoles'] as List?) ?? const [];
    final job = widget.jobs.jobs.where((j) => (j.app == a['id'] || (a['source'] == 'pacman' && j.app == '_pacman_system')) && !j.finished).firstOrNull;
    final source = '${a['source'] ?? 'local'}';

    return GestureDetector(
      onSecondaryTapDown: (d) => menu(a, d.globalPosition),
      child: Builder(
        builder: (rowContext) => Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            final k = event.logicalKey;
            if (event is KeyDownEvent &&
                (k == LogicalKeyboardKey.contextMenu || (k == LogicalKeyboardKey.f10 && HardwareKeyboard.instance.isShiftPressed))) {
              final box = rowContext.findRenderObject()! as RenderBox;
              menu(a, box.localToGlobal(box.size.centerRight(Offset.zero) - const Offset(40, 0)));
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ListTile(
            key: ValueKey('sysapp-${a['id']}'),
            leading: AppIcon(icon['file'] as String?),
            title: Row(
              children: [
                Flexible(child: Text('${a['name']}', overflow: TextOverflow.ellipsis)),
                if (version.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(version, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
                if (update != null)
                  _mark(
                    trf('Update available: {0} → {1}', [
                      '${update['installed'] ?? ''}'.isEmpty ? tr('unknown') : update['installed'],
                      update['available'],
                    ]),
                    Icons.arrow_circle_up,
                    marks.update,
                  ),
                if (a['running'] == true) _mark(tr('Running now'), Icons.circle, marks.running, size: 10),
                if (a['autostart'] == true) _mark(tr('Starts at login'), Icons.login, scheme.onSurfaceVariant, size: 15),
                if (job != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Tooltip(
                      message: '${job.title}: ${phaseName(job.phase)}',
                      child: const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ),
              ],
            ),
            subtitle: Row(
              children: [
                Flexible(child: Text(_subtitle(a), maxLines: 1, overflow: TextOverflow.ellipsis)),
                _chip(sysAppSourceLabel(source)),
                if (roles.isNotEmpty) _chip(tr('Default')),
              ],
            ),
            trailing: Builder(
              builder: (context) => IconButton(
                tooltip: tr('App actions'),
                icon: const Icon(Icons.more_vert, size: 18),
                onPressed: () {
                  final box = context.findRenderObject()! as RenderBox;
                  menu(a, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                },
              ),
            ),
            onTap: () => a['canOpen'] == true ? act(a, 'open') : openDetails(a),
          ),
        ),
      ),
    );
  }

  KeyEventResult _keys(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      if (ModalRoute.of(context)?.isCurrent == false) {
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      }
      if (filter.text.isNotEmpty) {
        filter.clear();
        setState(() => query = '');
        filterFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (markFilter != null) {
        setState(() => markFilter = null);
        return KeyEventResult.handled;
      }
      if (sheet) {
        setState(() => sheet = false);
        return KeyEventResult.handled;
      }
      if (filterFocus.hasPrimaryFocus) {
        unawaited(AppWindow.hide());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.f5 || (k == LogicalKeyboardKey.keyR && HardwareKeyboard.instance.isControlPressed)) {
      unawaited(checkUpdates(force: true));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyU && HardwareKeyboard.instance.isControlPressed) {
      if (!widget.jobs.busy) unawaited(updateAll());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyL && HardwareKeyboard.instance.isControlPressed) {
      setState(() => sheet = !sheet);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = [
      for (final a in apps)
        if (_matches(a, query) && (markFilter == null || _hasMark(a, markFilter!))) a,
    ];
    final secs = _sections(shown);
    final running = widget.jobs.busy;
    final narrow = MediaQuery.sizeOf(context).width < 560;

    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _keys,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('Apps'),
                      key: const ValueKey('system-apps-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: pageTitleStyle(context),
                    ),
                  ),
                  Builder(
                    builder: (context) => IconButton(
                      key: const ValueKey('system-legend'),
                      tooltip: tr('What the marks mean'),
                      isSelected: markFilter != null,
                      onPressed: () {
                        final box = context.findRenderObject()! as RenderBox;
                        _legend(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                      },
                      icon: const Icon(Icons.info_outline),
                      selectedIcon: const Icon(Icons.filter_alt),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('system-refresh'),
                    tooltip: tr('Check for updates (F5)'),
                    onPressed: checking ? null : () => checkUpdates(force: true),
                    icon: checking
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                  ),
                  IconButton(
                    key: const ValueKey('system-job-log'),
                    tooltip: tr('Job log (Ctrl+L)'),
                    isSelected: sheet,
                    onPressed: widget.jobs.jobs.isEmpty ? null : () => setState(() => sheet = !sheet),
                    icon: Badge(
                      isLabelVisible: running,
                      smallSize: 7,
                      backgroundColor: markColors(context).update,
                      child: const Icon(Icons.terminal),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                key: const ValueKey('system-filter'),
                controller: filter,
                focusNode: filterFocus,
                autofocus: true,
                decoration: InputDecoration(hintText: tr('Type to filter'), prefixIcon: const Icon(Icons.search, size: 20)),
                onChanged: (v) => setState(() => query = v),
                onSubmitted: (_) {
                  final first = secs.expand((s) => s.$3).firstOrNull;
                  if (first != null) unawaited(openDetails(first));
                },
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(error!, style: TextStyle(color: scheme.error)),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _load, child: Text(tr('Try again'))),
                        ],
                      ),
                    )
                  : ListView(
                      key: const ValueKey('system-app-list'),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final (id, title, items) in secs)
                          if (items.isNotEmpty) ...[
                            _sectionLine(id, title, items, narrow: narrow, running: running),
                            for (final x in items) _row(x),
                          ],
                        if (shown.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                query.trim().isEmpty && markFilter == null
                                    ? tr('No installed apps found')
                                    : trf('No app matches "{0}"', [query]),
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            if (sheet && widget.jobs.shown != null)
              JobSheet(
                jobs: widget.jobs,
                height: narrow ? 220 : 260,
                onClose: () => setState(() => sheet = false),
              ),
          ],
        ),
      ),
    );
  }
}
