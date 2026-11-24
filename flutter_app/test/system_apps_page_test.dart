import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/home.dart';
import 'package:maprisma_manager/jobs_model.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0'};

void main() {
  setUp(() => configureLanguage('en'));
  tearDown(() => configureLanguage('en'));

  testWidgets('Apps page is at top of sidebar, groups non-Maprisma apps, filters, opens Details, Uninstall and Update all', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final calls = <(String, Map<String, dynamic>)>[];
    var gimpAutostart = false;
    final apps = <Map<String, dynamic>>[
      {
        'id': 'firefox.desktop',
        'desktopId': 'firefox',
        'name': 'Firefox',
        'description': 'Browse the Web',
        'icon': {'file': null, 'name': 'firefox'},
        'kind': 'app',
        'source': 'pacman',
        'desktopPath': '/usr/share/applications/firefox.desktop',
        'exec': 'firefox',
        'program': '/usr/bin/firefox',
        'version': '132.0-1',
        'package': {'name': 'firefox', 'version': '132.0-1', 'size': 260000000, 'url': 'https://mozilla.org'},
        'website': 'https://mozilla.org',
        'running': true,
        'autostart': false,
        'autostartSupported': true,
        'defaultRoles': ['browser'],
        'actions': <Map<String, String>>[],
        'update': {'installed': '132.0-1', 'available': '133.0-1', 'manager': 'pacman'},
        'canOpen': true,
        'canUpdate': true,
        'canReinstall': true,
        'canUninstall': true,
      },
      {
        'id': 'org.gimp.GIMP.desktop',
        'desktopId': 'org.gimp.GIMP',
        'name': 'GIMP',
        'description': 'Image Editor',
        'icon': {'file': null, 'name': 'org.gimp.GIMP'},
        'kind': 'flatpak',
        'source': 'flatpak',
        'desktopPath': '/var/lib/flatpak/exports/share/applications/org.gimp.GIMP.desktop',
        'exec': 'flatpak run org.gimp.GIMP',
        'version': '2.10.38',
        'package': {'name': 'org.gimp.GIMP', 'version': '2.10.38', 'remote': 'flathub', 'sizeText': '250 MB'},
        'running': false,
        'autostart': false,
        'autostartSupported': true,
        'defaultRoles': <String>[],
        'actions': <Map<String, String>>[],
        'update': {'installed': '2.10.38', 'available': '3.0.0', 'manager': 'flatpak'},
        'canOpen': true,
        'canUpdate': true,
        'canReinstall': true,
        'canUninstall': true,
      },
    ];

    Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
      calls.add((method, params));
      switch (method) {
        case 'settings.get':
          return {'language': 'en', 'corners': 'windows', 'screenshot_key': true};
        case 'apps.list':
          return {'apps': <Map<String, dynamic>>[], 'desktop': 'hyprland'};
        case 'system_apps.list':
          return {
            'desktop': 'hyprland',
            'apps': [
              for (final a in apps)
                if (a['id'] == 'org.gimp.GIMP.desktop') {...a, 'autostart': gimpAutostart} else a,
            ],
          };
        case 'system_apps.check_updates':
          return {'checked': true, 'updates': 2};
        case 'system_apps.autostart':
          if (params['id'] == 'org.gimp.GIMP.desktop') gimpAutostart = params['on'] == true;
          return {'id': params['id'], 'autostart': params['on']};
        case 'system_apps.remove_plan':
          return {
            'id': 'org.gimp.GIMP.desktop',
            'kind': 'flatpak',
            'manager': 'flatpak',
            'what': 'org.gimp.GIMP',
            'version': '2.10.38',
            'defaultRoles': const <String>[],
            'needsPassword': false,
            'canDeleteData': true,
            'goes': [
              {'path': 'org.gimp.GIMP', 'kind': 'flatpak', 'version': '2.10.38'},
            ],
            'stays': [
              {'path': '~/.var/app/org.gimp.GIMP', 'why': 'app data (kept unless deleted)'},
            ],
          };
        case 'system_jobs.start':
          return {
            'id': 'sys-1',
            'app': params['app'],
            'kind': params['kind'],
            'state': 'succeeded',
            'phase': 'finish',
            'cancellable': false,
            'result': {'ok': true},
          };
        case 'system_jobs.get':
          return {
            'id': 'sys-1',
            'state': 'succeeded',
            'phase': 'finish',
            'cancellable': false,
            'result': {'ok': true},
          };
        case 'system_jobs.log':
          return {'id': 'sys-1', 'text': 'Done\n', 'next': 5, 'finished': true};
      }
      return {};
    }

    final jobs = JobsModel(core, every: const Duration(milliseconds: 50));
    final sysJobs = JobsModel(core, prefix: 'system_jobs', every: const Duration(milliseconds: 50));
    addTearDown(jobs.dispose);
    addTearDown(sysJobs.dispose);

    await tester.pumpWidget(ManagerApp(core: core, look: const {'colors': _dark}, checkOnStart: false, relook: null, jobs: jobs, systemJobs: sysJobs));
    await tester.pumpAndSettle();

    // Sidebar order: Apps is #0 (top), Maprisma Apps is #1.
    expect(Section.values.first, Section.systemApps);
    expect(Section.values[1], Section.apps);
    expect(find.byKey(const ValueKey('nav-systemApps')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-apps')), findsOneWidget);
    expect(find.byKey(const ValueKey('system-apps-title')), findsOneWidget);

    // Sections and rows render.
    expect(find.text('System packages'), findsOneWidget);
    expect(find.text('Flatpak'), findsWidgets);
    expect(find.byKey(const ValueKey('sysapp-firefox.desktop')), findsOneWidget);
    expect(find.byKey(const ValueKey('sysapp-org.gimp.GIMP.desktop')), findsOneWidget);
    expect(find.byKey(const ValueKey('system-update-all-system')), findsOneWidget);
    expect(find.byKey(const ValueKey('system-update-all-flatpak')), findsOneWidget);

    // Filter works and Esc clears it.
    await tester.enterText(find.byKey(const ValueKey('system-filter')), 'gimp');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sysapp-firefox.desktop')), findsNothing);
    expect(find.byKey(const ValueKey('sysapp-org.gimp.GIMP.desktop')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sysapp-firefox.desktop')), findsOneWidget);

    // Legend mark filter: Running now shows only Firefox.
    await tester.tap(find.byKey(const ValueKey('system-legend')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('system-legend-running')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sysapp-firefox.desktop')), findsOneWidget);
    expect(find.byKey(const ValueKey('sysapp-org.gimp.GIMP.desktop')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sysapp-org.gimp.GIMP.desktop')), findsOneWidget);

    // Open ⋮ menu on GIMP -> Details dialog.
    final gimpMore = find.descendant(of: find.byKey(const ValueKey('sysapp-org.gimp.GIMP.desktop')), matching: find.byTooltip('App actions'));
    await tester.tap(gimpMore);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details…'));
    await tester.pumpAndSettle();
    expect(find.text('org.gimp.GIMP'), findsWidgets);
    expect(find.text('flathub'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Open ⋮ menu on GIMP -> Start at login.
    await tester.tap(gimpMore);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start at login'));
    await tester.pumpAndSettle();
    expect(gimpAutostart, isTrue);

    // Open ⋮ menu on GIMP -> Uninstall… dialog with delete data checkbox -> starts job and opens JobSheet.
    await tester.tap(gimpMore);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uninstall…'));
    await tester.pumpAndSettle();
    expect(find.text('Do you want to uninstall GIMP?'), findsOneWidget);
    await tester.tap(find.text('Also delete its app data'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('system-uninstall-go')));
    await tester.pumpAndSettle();
    expect(calls.any((c) => c.$1 == 'system_jobs.start' && c.$2['app'] == 'org.gimp.GIMP.desktop' && c.$2['kind'] == 'remove' && (c.$2['options'] as Map)['delete_data'] == true), isTrue);
    expect(find.byKey(const ValueKey('job-sheet')), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
