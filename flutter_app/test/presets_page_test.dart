import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/home.dart';
import 'package:maprisma_manager/presets_page.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

import 'page_shots.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0'};

Map<String, dynamic> _loadAnswer({
  String desktopId = 'hyprland',
  String desktopName = 'Hyprland',
  List<String> caps = const ['workspaces', 'tiling', 'windows', 'presetLayouts', 'splits'],
  bool active = true,
  int maxWindows = 2,
  Map<String, dynamic>? workspaceCaps,
  Map<String, dynamic>? workspacePresets,
  Map<String, dynamic>? workspaceModes,
  Map<String, dynamic>? workspaceSplits,
  Map<String, dynamic>? workspaceLayouts,
  List<Map<String, dynamic>>? presets,
  int activeWorkspace = 1,
}) => {
  'desktop': {'id': desktopId, 'name': desktopName, 'terminal': 'kitty', 'caps': caps},
  'state': caps.contains('workspaces')
      ? {
          'schema': 2,
          'active': active,
          'autoMoveOnRestore': false,
          'maxWindows': maxWindows,
          'workspaceCaps': workspaceCaps ?? {'2': 3},
          'workspaceModes': workspaceModes ?? {'2': 'tiled'},
          'workspacePresets': workspacePresets ?? {'2': 'master-left'},
          'workspaceSplits': workspaceSplits ?? {'2': 0.6},
          'defaultModes': <String, dynamic>{},
          'defaultPresets': <String, dynamic>{},
          'workspaceLayouts': workspaceLayouts ??
              {
                '1': {'apps': ['firefox.desktop', 'kitty.desktop'], 'autostart': false},
              },
        }
      : null,
  'looks': caps.contains('workspaces')
      ? {
          'workspaces': {
            '1': {'theme': 'nord', 'name': 'Nord', 'limit': 2, 'mode': 'tiled', 'preset': 'side-by-side'},
            '2': {'theme': 'nord', 'name': 'Nord', 'limit': 3, 'mode': 'tiled', 'preset': 'master-left'},
          },
          'current': 'nord',
          'active_workspace': activeWorkspace,
        }
      : null,
  'presets': presets ??
      [
        {
          'name': 'Work',
          'theme': 'nord',
          'wallpaper': 'mountain.png',
          'font': 'JetBrains Mono',
          'workspaces': {
            'maxWindows': 2,
            'workspaceCaps': {'2': 3},
            'workspaceModes': {'2': 'tiled'},
            'workspaceLayouts': {'1': {'apps': ['firefox.desktop'], 'autostart': false}},
          },
        },
        {
          'name': 'Minimal',
          'theme': 'nord',
          'wallpaper': null,
          'font': 'JetBrains Mono',
        },
      ],
  'themes': [
    {'slug': 'nord', 'name': 'Nord', 'current': true, 'hidden': false},
  ],
};

class _FakePresetsCore {
  _FakePresetsCore(this.loadData, {this.loadError, this.restoreConflict = false, this.failMethod});
  Map<String, dynamic> loadData;
  ServiceError? loadError;
  bool restoreConflict;
  String? failMethod;
  final calls = <(String, Map<String, dynamic>)>[];

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, Map<String, dynamic>.from(params)));
    if (failMethod == method) throw ServiceError('failed', 'boom');
    switch (method) {
      case 'settings.get':
        return {'language': 'en'};
      case 'apps.list':
        return {'apps': <Object>[], 'desktop': 'hyprland'};
      case 'jobs.list':
        return {'jobs': <Object>[]};
      case 'presets.load':
        if (loadError != null) throw loadError!;
        return loadData;
      case 'presets.app_launchers':
        return {
          'launchers': [
            {'desktop_id': 'firefox.desktop', 'name': 'Firefox', 'icon': 'firefox'},
            {'desktop_id': 'code.desktop', 'name': 'VS Code', 'icon': 'code'},
          ],
        };
      case 'presets.app_restore':
        if (restoreConflict && params['action'] == 'ask') {
          return {'status': 'conflict', 'conflict_count': 2};
        }
        return {'status': 'restored', 'launched': ['firefox.desktop'], 'failed': <String>[]};
      case 'presets.undo':
        return {'undone': true};
      default:
        return {'ok': true};
    }
  }

  List<Map<String, dynamic>> of(String method) => [for (final c in calls) if (c.$1 == method) c.$2];
}

void main() {
  setUpAll(loadShotFonts);
  setUp(() => configureLanguage('en'));

  Future<_FakePresetsCore> open(
    WidgetTester tester,
    Map<String, dynamic> answer, {
    ServiceError? error,
    bool restoreConflict = false,
    String? failMethod,
  }) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = _FakePresetsCore(answer, loadError: error, restoreConflict: restoreConflict, failMethod: failMethod);
    await tester.pumpWidget(
      ManagerApp(key: UniqueKey(), core: fake.call, look: const {'colors': _dark}, checkOnStart: false, relook: null, page: 'presets'),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  test('sidebar registers Presets right after Theme', () {
    final s = Section.values;
    expect(s.indexOf(Section.presets), s.indexOf(Section.theme) + 1);
    expect(ManagerHomeState.sectionNamed('presets'), Section.presets);
    expect(ManagerHomeState.name(Section.presets), 'Presets');
  });

  test('preset geometry covers all 9 presets, splits, and COSMIC/KDE autotile modes', () {
    for (final p in presetLayoutNames) {
      expect(presetRects(p, 3), isNotEmpty, reason: p);
    }
    expect(presetRects('tiled', 3), hasLength(3));
    expect(presetRects('default', 4), hasLength(4));
    expect(presetRects('side-by-side', 2, split: 0.7)[0].width, greaterThan(presetRects('side-by-side', 2, split: 0.3)[0].width));
    expect(isPresetCompatibleWithCap('grid', 4), isTrue);
    expect(isPresetCompatibleWithCap('grid', 3), isFalse);
    expect(isPresetCompatibleWithCap('floating', 1), isTrue);
    expect(isPresetCompatibleWithCap('scrolling', 1), isTrue);
    expect(isPresetCompatibleWithCap('none', 1), isTrue);
    expect(presetHasSplit('master-left', 3), isTrue);
    expect(presetHasSplit('columns', 3), isTrue);
    expect(presetHasSplit('columns', 4), isFalse);
    expect(presetHasSplit('grid', 4), isFalse);
    expect(presetSplitRange('columns'), (0.20, 0.60));
    expect(presetSplitRange('master-left'), (0.20, 0.80));
  });

  testWidgets('Hyprland: workspaces tab with 9 presets, limits, split slider, bulk actions, undo, and More link', (tester) async {
    final fake = await open(tester, _loadAnswer(activeWorkspace: 2));
    expect(find.byKey(const ValueKey('presets-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-tiling-active')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-ws-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-ws-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-preset-master-left')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-preset-scrolling')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-split-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-undo')), findsNothing);

    // Toggle tiling active
    await tapKey(tester, 'presets-tiling-active');
    expect(fake.of('presets.set').last, {'active': false, 'apply': true});
    expect(find.byKey(const ValueKey('presets-undo')), findsOneWidget);

    // Change window limit to 4 on workspace 2
    await tapKey(tester, 'presets-limit-4');
    expect(fake.of('presets.set').last, {'workspace': 2, 'limit': 4, 'apply': true});

    // Reset split to even
    await tapKey(tester, 'presets-split-even');
    expect(fake.of('presets.set').last, {'workspace': 2, 'split': null, 'apply': true});

    // Reset workspace to default
    await tapKey(tester, 'presets-ws-reset');
    expect(fake.of('presets.set').last, {'workspace': 2, 'preset': null, 'mode': null, 'limit': null, 'split': null, 'apply': true});

    // Undo button calls presets.undo and hides itself
    await tapKey(tester, 'presets-undo');
    expect(fake.of('presets.undo'), hasLength(1));
    expect(find.byKey(const ValueKey('presets-undo')), findsNothing);

    // Switch to All Workspaces and test bulk actions
    await tapKey(tester, 'presets-ws-0');
    await tapKey(tester, 'presets-bulk-reset');
    expect(fake.of('presets.bulk').last, {'action': 'reset_all'});

    await tapKey(tester, 'presets-bulk-remove');
    expect(fake.of('presets.bulk').last, {'action': 'remove_all'});

    await tapKey(tester, 'presets-bulk-clear');
    await tapKey(tester, 'presets-confirm');
    expect(fake.of('presets.reset'), hasLength(1));

    // More in Maprisma Theme…
    await tapKey(tester, 'presets-more');
    expect(fake.of('apps.open').last, {'id': 'theme'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('COSMIC: shows 3 desktop modes (Tiled, Floating, Native) without split slider', (tester) async {
    final fake = await open(
      tester,
      _loadAnswer(
        desktopId: 'cosmic',
        desktopName: 'COSMIC',
        caps: const ['workspaces', 'tiling', 'windows'],
        activeWorkspace: 1,
      ),
    );
    expect(find.byKey(const ValueKey('presets-mode-tiled')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-mode-floating')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-mode-default')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-preset-master-left')), findsNothing);
    expect(find.byKey(const ValueKey('presets-split-slider')), findsNothing);

    await tapKey(tester, 'presets-mode-floating');
    expect(fake.of('presets.set').last, {'workspace': 1, 'mode': 'floating', 'apply': true});
    expect(tester.takeException(), isNull);
  });

  testWidgets('App Presets tab: chips, add app dialog, restore conflict resolution, autostart and remove all', (tester) async {
    final fake = await open(tester, _loadAnswer(activeWorkspace: 1), restoreConflict: true);
    await tester.tap(find.text('App Presets'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('presets-app-chip-0')), findsOneWidget);
    expect(find.text('firefox'), findsOneWidget);

    // Save App Preset
    await tapKey(tester, 'presets-app-save');
    expect(fake.of('presets.app_save').last, {'workspace': 1});

    // Add app dialog
    await tapKey(tester, 'presets-app-add');
    expect(fake.of('presets.app_launchers'), hasLength(1));
    await tester.enterText(find.byKey(const ValueKey('presets-launcher-search')), 'code');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('presets-launcher-code.desktop')));
    await tester.pumpAndSettle();
    expect(fake.of('presets.app_add').last, {'workspace': 1, 'desktop_id': 'code.desktop'});

    // Restore triggers inline conflict card -> choose Move Conflicting Windows
    await tapKey(tester, 'presets-app-restore');
    expect(find.byKey(const ValueKey('presets-conflict')), findsOneWidget);
    await tapKey(tester, 'presets-conflict-move');
    expect(fake.of('presets.app_restore'), [
      {'workspace': 1, 'action': 'ask'},
      {'workspace': 1, 'action': 'move'},
    ]);
    expect(find.byKey(const ValueKey('presets-conflict')), findsNothing);

    // Autostart and Auto-move switches
    await tapKey(tester, 'presets-app-autostart');
    expect(fake.of('presets.app_autostart').last, {'workspace': 1, 'enabled': true});

    await tapKey(tester, 'presets-auto-move');
    expect(fake.of('presets.set').last, {'autoMoveOnRestore': true});

    // Remove All App Presets with confirmation
    await tapKey(tester, 'presets-app-remove-all');
    await tapKey(tester, 'presets-confirm');
    expect(fake.of('presets.app_remove_all'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Save/Load Presets tab: save current, apply with confirmation, assign and delete', (tester) async {
    final fake = await open(tester, _loadAnswer());
    await tester.tap(find.text('Save/Load Presets'));
    await tester.pumpAndSettle();

    // Save a new preset
    await tester.enterText(find.byKey(const ValueKey('presets-save-name')), 'Focus');
    await tester.pumpAndSettle();
    await tapKey(tester, 'presets-save-button');
    expect(fake.of('presets.saved_save').last, {'name': 'Focus', 'includeWorkspaces': true});

    // Apply Minimal (no workspaces -> does not set Undo)
    await tapKey(tester, 'presets-saved-apply-Minimal');
    expect(fake.of('presets.saved_apply').last, {'name': 'Minimal', 'confirmed': false});
    expect(find.byKey(const ValueKey('presets-undo')), findsNothing);

    // Apply Work (includes workspaces -> shows confirmation dialog and enables Undo)
    await tapKey(tester, 'presets-saved-apply-Work');
    expect(find.byKey(const ValueKey('presets-confirm')), findsOneWidget);
    await tapKey(tester, 'presets-confirm');
    expect(fake.of('presets.saved_apply').last, {'name': 'Work', 'confirmed': true});
    expect(find.byKey(const ValueKey('presets-undo')), findsOneWidget);

    // Assign Work to workspace 4
    await tapKey(tester, 'presets-saved-assign-Work');
    await tapKey(tester, 'presets-assign-ws-4');
    expect(fake.of('presets.saved_assign').last, {'name': 'Work', 'part': 'theme', 'workspaces': [4]});

    // Delete Minimal with confirmation
    await tapKey(tester, 'presets-saved-delete-Minimal');
    await tapKey(tester, 'presets-confirm');
    expect(fake.of('presets.saved_delete').last, {'name': 'Minimal'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop without workspaces shows informational note and defaults to Save/Load Presets', (tester) async {
    await open(tester, _loadAnswer(desktopId: 'generic', desktopName: 'Generic', caps: const []));
    expect(find.byKey(const ValueKey('presets-tabs')), findsNothing);
    expect(find.text('Workspaces are not available on Generic yet.'), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-save-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-save-include')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('problem states: not_installed and too_old', (tester) async {
    await open(tester, _loadAnswer(), error: ServiceError('not_installed', 'Maprisma Theme is not installed'));
    expect(find.text('Maprisma Theme is not installed'), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-install')), findsOneWidget);

    await open(tester, _loadAnswer(), error: ServiceError('too_old', 'Update Maprisma Theme to manage presets here'));
    expect(find.text('Update Maprisma Theme to manage presets here'), findsOneWidget);
    expect(find.byKey(const ValueKey('presets-retry')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed action reloads presets.load so UI does not stay stale', (tester) async {
    final fake = await open(tester, _loadAnswer(activeWorkspace: 2), failMethod: 'presets.set');
    expect(fake.of('presets.load'), hasLength(1));

    await tapKey(tester, 'presets-tiling-active');
    expect(fake.of('presets.set'), hasLength(1));
    expect(fake.of('presets.load'), hasLength(2));
    expect(find.textContaining('boom'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
