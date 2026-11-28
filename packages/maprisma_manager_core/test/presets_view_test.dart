import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// Fake `maprisma-theme-core` implementing `call <method> [<json>]`.
void fakePresetsCore(
  World w, {
  List<String> caps = const ['workspaces', 'tiling', 'windows', 'presetLayouts', 'splits'],
  String desktopId = 'hyprland',
  String desktopName = 'Hyprland',
  String? failError,
  int exitCode = 0,
  bool restoreConflict = false,
  bool failApply = false,
}) {
  final capsJson = jsonEncode(caps);
  final script = failError != null
      ? '''#!/bin/sh
echo '{"error":"$failError","message":"old or blocked"}'
exit ${exitCode == 0 ? 2 : exitCode}
'''
      : exitCode == 124
      ? '#!/bin/sh\nexit 124\n'
      : '''#!/bin/sh
if [ "\$1" != "call" ]; then
  echo '{"error":"bad_args"}'
  exit 2
fi
method="\$2"
payload="\$3"
printf '%s %s\\n' "\$method" "\$payload" >> "\$HOME/presets.log"
case "\$method" in
  desktop.info)
    printf '{"id":"$desktopId","name":"$desktopName","terminal":"kitty","caps":$capsJson}\\n' ;;
  workspaces.get)
    printf '{"state":{"schema":2,"active":true,"autoMoveOnRestore":false,"maxWindows":2,"workspaceCaps":{"2":3},"workspaceModes":{"2":"tiled"},"workspacePresets":{"2":"master-left"},"workspaceSplits":{"2":0.6},"defaultModes":{},"defaultPresets":{},"workspaceLayouts":{"1":{"apps":["firefox.desktop"],"autostart":false}}},"desktop":{"workspaces":[]}}\\n' ;;
  workspaces.looks)
    printf '{"workspaces":{"1":{"theme":"nord","name":"Nord","limit":2,"mode":"tiled","preset":"side-by-side"}},"current":"nord","workspace_themes":false,"workspace_wallpapers":false,"active_workspace":2}\\n' ;;
  workspaces.set)
    printf '{"receipt":"r-set"}\\n' ;;
  workspaces.bulk)
    printf '{"receipt":"r-bulk"}\\n' ;;
  workspaces.reset)
    printf '{"receipt":"r-reset"}\\n' ;;
  workspaces.apply)
    if [ "$failApply" = "true" ]; then
      printf '{"error":"failed","message":"wm busy"}\\n'
      exit 1
    fi
    printf '{"applied":true,"receipt":"r-apply"}\\n' ;;
  workspaces.undo)
    printf '{"undone":true,"state":{"schema":2,"active":false,"maxWindows":2}}\\n' ;;
  apppresets.launchers)
    printf '{"launchers":[{"desktop_id":"firefox.desktop","name":"Firefox","icon":"firefox"},{"desktop_id":"kitty.desktop","name":"Kitty","icon":"kitty"}]}\\n' ;;
  apppresets.add|apppresets.save|apppresets.remove|apppresets.remove_all|apppresets.autostart)
    printf '{"receipt":"r-app"}\\n' ;;
  apppresets.restore)
    case "$restoreConflict:\$payload" in
      true:*'"ask"'*) printf '{"status":"conflict","conflict_count":2}\\n' ;;
      *) printf '{"status":"restored","launched":["firefox.desktop"],"failed":[],"moves":[],"closed":0,"receipt":"r-restore"}\\n' ;;
    esac ;;
  presets.list)
    printf '{"presets":[{"name":"Work","theme":"nord","wallpaper":"a.png","font":"JetBrains Mono"}]}\\n' ;;
  presets.save|presets.delete)
    printf '{"receipt":"r-preset"}\\n' ;;
  presets.apply)
    printf '{"applied":true,"receipt":"r-preset-apply","appearance":true}\\n' ;;
  presets.assign)
    printf '{"assigned":true,"receipt":"r-assign","appearance":true}\\n' ;;
  themes.list)
    printf '{"themes":[{"slug":"nord","name":"Nord","current":true,"hidden":false,"colors":{"mode":"dark","background":"#2e3440","foreground":"#d8dee9","accent":"#88c0d0"}}],"current":"nord"}\\n' ;;
  *)
    printf '{"error":"not_found","message":"unknown %s"}\\n' "\$method"
    exit 1 ;;
esac
''';
  w.writeFile(p.join(w.home, '.local/bin/maprisma-theme-core'), script, mode: '755');
}

void main() {
  late World w;
  setUp(() {
    configureLanguage('en');
    w = World.create();
  });
  tearDown(() => w.dispose());

  List<String> log() {
    final f = File(p.join(w.home, 'presets.log'));
    return f.existsSync() ? f.readAsLinesSync().map((l) => l.trim()).toList() : const [];
  }

  test('presets.load loads desktop, presets, themes, workspace state and looks when workspaces supported', () async {
    fakePresetsCore(w);
    final r = await w.core().call('presets.load');
    expect((r['desktop'] as Map)['id'], 'hyprland');
    expect((r['desktop'] as Map)['caps'], containsAll(['workspaces', 'tiling', 'windows', 'presetLayouts', 'splits']));
    expect((r['state'] as Map)['active'], isTrue);
    expect((r['looks'] as Map)['active_workspace'], 2);
    expect((r['presets'] as List).single['name'], 'Work');
    expect((r['themes'] as List).single['slug'], 'nord');
    expect(log(), containsAll(['desktop.info', 'presets.list', 'themes.list', 'workspaces.get', 'workspaces.looks']));
  });

  test('presets.load skips workspace queries when desktop lacks workspaces capability', () async {
    fakePresetsCore(w, caps: const [], desktopId: 'generic', desktopName: 'Generic');
    final r = await w.core().call('presets.load');
    expect((r['desktop'] as Map)['id'], 'generic');
    expect(r['state'], isNull);
    expect(r['looks'], isNull);
    expect((r['presets'] as List), hasLength(1));
    expect(log(), isNot(contains('workspaces.get')));
    expect(log(), isNot(contains('workspaces.looks')));
  });

  test('presets.set validates parameters, forwards to workspaces.set, and applies tiling only when requested and supported', () async {
    fakePresetsCore(w);
    final core = w.core();
    await core.call('presets.load');

    final r1 = await core.call('presets.set', {'workspace': 2, 'limit': 3, 'preset': 'master-left', 'split': 0.65, 'apply': true});
    expect(r1['applied'], isTrue);
    expect(log().where((l) => l.startsWith('workspaces.set ')).single, contains('"preset":"master-left"'));
    expect(log().where((l) => l == 'workspaces.apply'), hasLength(1));

    // Without apply: true -> no workspaces.apply
    final r2 = await core.call('presets.set', {'autoMoveOnRestore': true});
    expect(r2.containsKey('applied'), isFalse);
    expect(log().where((l) => l == 'workspaces.apply'), hasLength(1));

    // All Workspaces defaults & nulls
    await core.call('presets.set', {'maxWindows': 4, 'defaultLimit': 4, 'defaultPreset': 'grid', 'defaultMode': 'tiled', 'split': null, 'apply': false});
    await core.call('presets.set', {'workspace': 2, 'limit': null, 'preset': null, 'mode': null, 'split': null});

    // Invalid params & invalid parameter combinations throw bad_params
    for (final bad in [
      const <String, dynamic>{},
      {'workspace': 11, 'limit': 2},
      {'workspace': 1, 'limit': 5},
      {'workspace': 1, 'preset': 'invalid-preset'},
      {'workspace': 1, 'mode': 'bogus'},
      {'defaultLimit': 0, 'defaultMode': 'tiled'},
      {'limit': 2},
      {'mode': 'tiled'},
      {'preset': 'grid'},
      {'defaultMode': 'tiled'},
      {'defaultPreset': 'grid'},
      {'split': 0.95},
      {'split': 0.1},
      {'active': 'yes'},
      {'apply': 'yes', 'active': true},
    ]) {
      await expectLater(
        core.call('presets.set', bad),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')),
        reason: '$bad',
      );
    }

    // Global default split without workspace is valid
    await core.call('presets.set', {'split': 0.6});
  });

  test('presets.bulk, presets.reset, presets.apply_tiling and presets.undo (Hyprland skips double apply, COSMIC applies)', () async {
    fakePresetsCore(w);
    final core = w.core();
    await core.call('presets.load');

    await core.call('presets.bulk', {'action': 'reset_all'});
    await core.call('presets.bulk', {'action': 'remove_all'});
    await expectLater(
      core.call('presets.bulk', {'action': 'drop_all'}),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')),
    );
    await core.call('presets.reset');
    await core.call('presets.apply_tiling');
    final u = await core.call('presets.undo');
    expect(u['undone'], isTrue);
    expect(u['applied'], isTrue);

    // On Hyprland (presetLayouts), workspaces.undo does NOT trigger a second workspaces.apply
    expect(log().last, 'workspaces.undo');
    expect(log(), containsAllInOrder([
      'workspaces.bulk {"action":"reset_all"}',
      'workspaces.apply',
      'workspaces.bulk {"action":"remove_all"}',
      'workspaces.apply',
      'workspaces.reset',
      'workspaces.apply',
      'workspaces.apply',
      'workspaces.undo',
    ]));

    // On COSMIC (tiling without presetLayouts), presets.undo calls workspaces.apply afterwards
    File(p.join(w.home, 'presets.log')).deleteSync();
    fakePresetsCore(w, caps: const ['workspaces', 'tiling', 'windows'], desktopId: 'cosmic', desktopName: 'COSMIC');
    final cosmicCore = w.core();
    await cosmicCore.call('presets.load');
    final cu = await cosmicCore.call('presets.undo');
    expect(cu['undone'], isTrue);
    expect(cu['applied'], isTrue);
    expect(log().sublist(log().length - 2), ['workspaces.undo', 'workspaces.apply']);
  });

  test('failed tiling apply after saved change returns applied: false with apply_error instead of throwing', () async {
    fakePresetsCore(w, failApply: true);
    final core = w.core();
    await core.call('presets.load');

    final rSet = await core.call('presets.set', {'workspace': 2, 'limit': 3, 'apply': true});
    expect(rSet['receipt'], 'r-set');
    expect(rSet['applied'], isFalse);
    expect(rSet['apply_error'], 'wm busy');

    final rBulk = await core.call('presets.bulk', {'action': 'reset_all'});
    expect(rBulk['receipt'], 'r-bulk');
    expect(rBulk['applied'], isFalse);
    expect(rBulk['apply_error'], 'wm busy');

    final rReset = await core.call('presets.reset');
    expect(rReset['receipt'], 'r-reset');
    expect(rReset['applied'], isFalse);
    expect(rReset['apply_error'], 'wm busy');
  });

  test('app presets routes validate and forward to apppresets.*', () async {
    fakePresetsCore(w, restoreConflict: true);
    final core = w.core();

    final launchers = await core.call('presets.app_launchers');
    expect((launchers['launchers'] as List), hasLength(2));

    await core.call('presets.app_add', {'workspace': 1, 'desktop_id': 'kitty.desktop'});
    await core.call('presets.app_save', {'workspace': 1});
    await core.call('presets.app_remove', {'workspace': 1, 'index': 0});
    await core.call('presets.app_remove', {'workspace': 1});
    await core.call('presets.app_remove_all');
    await core.call('presets.app_autostart', {'workspace': 1, 'enabled': true});

    final conflict = await core.call('presets.app_restore', {'workspace': 1, 'action': 'ask'});
    expect(conflict['status'], 'conflict');
    expect(conflict['conflict_count'], 2);

    final restored = await core.call('presets.app_restore', {'workspace': 1, 'action': 'move'});
    expect(restored['status'], 'restored');

    await expectLater(core.call('presets.app_add', {'workspace': 0, 'desktop_id': 'x'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(core.call('presets.app_add', {'workspace': 1, 'desktop_id': ''}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(core.call('presets.app_remove', {'workspace': 1, 'index': -1}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(core.call('presets.app_autostart', {'workspace': 1, 'enabled': 1}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(core.call('presets.app_restore', {'workspace': 1, 'action': 'explode'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
  });

  test('saved preset routes validate and forward to presets.*', () async {
    fakePresetsCore(w);
    final core = w.core();

    await core.call('presets.saved_save', {'name': 'Coding', 'includeWorkspaces': true});
    await core.call('presets.saved_apply', {'name': 'Coding', 'confirmed': true});
    await core.call('presets.saved_assign', {'name': 'Coding', 'part': 'both', 'workspaces': [1, 3]});
    await core.call('presets.saved_delete', {'name': 'Coding'});

    expect(log(), [
      'presets.save {"name":"Coding","includeWorkspaces":true}',
      'presets.apply {"name":"Coding","confirmed":true}',
      'presets.assign {"name":"Coding","workspaces":[1,3],"part":"both"}',
      'presets.delete {"name":"Coding"}',
    ]);

    await expectLater(core.call('presets.saved_save', {'name': '   '}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(core.call('presets.saved_assign', {'name': 'Coding', 'workspaces': <int>[]}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(core.call('presets.saved_assign', {'name': 'Coding', 'workspaces': [11]}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(core.call('presets.saved_assign', {'name': 'Coding', 'workspaces': [1], 'part': 'font'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
  });

  test('error mapping: not_installed, too_old (bad_args & not_allowed), timeout (124)', () async {
    await expectLater(
      w.core().call('presets.load'),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_installed')),
    );

    fakePresetsCore(w, failError: 'bad_args');
    await expectLater(
      w.core().call('presets.load'),
      throwsA(isA<RouteError>()
          .having((e) => e.code, 'code', 'too_old')
          .having((e) => e.message, 'message', 'Update Maprisma Theme to manage presets here')),
    );

    fakePresetsCore(w, failError: 'not_allowed');
    await expectLater(
      w.core().call('presets.load'),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'too_old')),
    );

    fakePresetsCore(w, exitCode: 124);
    await expectLater(
      w.core().call('presets.load'),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'timeout')),
    );
  });
}
