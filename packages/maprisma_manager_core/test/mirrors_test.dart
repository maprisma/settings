import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World.create());
  tearDown(() => w.dispose());

  String etc(String name) => p.join(w.root, 'etc/pacman.d', name);

  void tools({String systemctl = ''}) {
    w.fake('cachyos-rate-mirrors', r'echo "==> ranking" >&2; echo "$*" > "$HOME/rank-args"');
    w.fake('rate-mirrors', 'exit 0');
    // pkexec runs its command as given (no password in tests).
    w.fake('pkexec', r'"$@"');
    w.fake('systemctl', systemctl.isEmpty
        ? r'''case "$1" in
  show) printf 'UnitFileState=enabled\nActiveState=active\nNextElapseUSecRealtime=@1795819962\nLastTriggerUSec=@1794955968\n' ;;
  enable|disable) echo "$1 $2 $3" > "$HOME/systemctl-call" ;;
esac'''
        : systemctl);
    for (final t in ['sh', 'install', 'mv', 'cat', 'setsid']) {
      final real = ['/usr/bin/$t', '/bin/$t'].firstWhere((x) => File(x).existsSync());
      Link(p.join(w.fakeBin, t)).createSync(real);
    }
  }

  test('without cachyos-rate-mirrors: not available, no timer', () async {
    final r = await w.core().call('mirrors.get');
    expect(r['available'], false);
    expect(r['timer'], isNull);
    expect(r['run'], isNull);
    await expectLater(w.core().call('mirrors.rank'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
  });

  test('the lists: servers, the first hosts and when rate-mirrors ranked them', () async {
    tools();
    w.writeFile(etc('mirrorlist'), '# STARTED AT: x\n# FINISHED AT: 2026-11-17 23:53:15.954687384 +01:00\n'
        'Server = https://a.example/archlinux/\$repo/os/\$arch\nServer = https://b.example/\$repo/os/\$arch\n');
    w.writeFile(etc('cachyos-mirrorlist'), '#Server = https://off.example/\nServer = https://c.example/cachyos/repo/\$arch/\$repo\n');
    final r = await w.core().call('mirrors.get');
    expect(r['available'], true);
    expect(r['timer'], {'enabled': true, 'active': true, 'next': isA<String>(), 'last': isA<String>()});
    final lists = (r['lists'] as List).cast<Map>();
    expect(lists[0], allOf(containsPair('servers', 2), containsPair('top', ['a.example', 'b.example']), containsPair('byTool', true)));
    expect(DateTime.parse(lists[0]['ranked'] as String).toUtc(), DateTime.utc(2026, 11, 17, 22, 53, 15));
    expect(lists[1], allOf(containsPair('servers', 1), containsPair('byTool', false)));
    expect(r['backups'], false);
  });

  test('rank runs the tool through pkexec, detached, and get follows it to the end', () async {
    tools();
    final core = w.core();
    expect(await core.call('mirrors.rank'), {'started': true});
    Map run = {};
    for (var i = 0; i < 100; i++) {
      run = (await core.call('mirrors.get'))['run'] as Map;
      if (run['outcome'] == 'done') break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(run['outcome'], 'done');
    expect(run['lines'], ['==> ranking']);
  });

  test('a closed password dialog counts as cancelled', () async {
    tools();
    w.fake('pkexec', 'exit 126');
    final core = w.core();
    await core.call('mirrors.rank');
    Map run = {};
    for (var i = 0; i < 100; i++) {
      run = (await core.call('mirrors.get'))['run'] as Map;
      if (run['outcome'] != 'running' && run['code'] != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(run['outcome'], 'cancelled');
  });

  test('the timer goes on and off with systemctl', () async {
    tools();
    await w.core().call('mirrors.set_timer', {'on': false});
    expect(File(p.join(w.home, 'systemctl-call')).readAsStringSync().trim(), 'disable --now cachyos-rate-mirrors.timer');
    await expectLater(w.core().call('mirrors.set_timer', {'on': 'yes'}), throwsA(isA<RouteError>()));
  });

  test('restore swaps every list with its backup', () async {
    tools();
    for (final f in MirrorsService.allFiles) {
      w.writeFile(etc(f), 'new $f\n');
      w.writeFile(etc('$f-backup'), 'old $f\n');
    }
    expect((await w.core().call('mirrors.get'))['backups'], true);
    await w.core().call('mirrors.restore');
    for (final f in MirrorsService.allFiles) {
      expect(File(etc(f)).readAsStringSync(), 'old $f\n');
      expect(File(etc('$f-backup')).readAsStringSync(), 'new $f\n');
    }
  });

  test('settings: the sidebar order is checked, saved and reset', () async {
    final core = w.core();
    await core.call('settings.set', {'key': 'sidebar_order', 'value': ['apps', '-', 'optimize', 'settings']});
    expect((await core.call('settings.get'))['sidebar_order'], ['apps', '-', 'optimize', 'settings']);
    await expectLater(core.call('settings.set', {'key': 'sidebar_order', 'value': ['apps', 'apps']}), throwsA(isA<RouteError>()));
    await expectLater(core.call('settings.set', {'key': 'sidebar_order', 'value': ['../x']}), throwsA(isA<RouteError>()));
    await core.call('settings.set', {'key': 'sidebar_order', 'value': null});
    expect((await core.call('settings.get'))['sidebar_order'], isNull);
    expect(jsonDecode(File(w.paths.settingsFile).readAsStringSync()), isNot(contains('sidebar_order')));
  });
}
