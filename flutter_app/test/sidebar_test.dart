// The sidebar (COSMIC Settings' layout): Apps, Bar, Power, Settings; the Power page on Hyprland
// (Maprisma Shell's idle times, the power profile) and on COSMIC (only a link to COSMIC
// Settings). With MAPRISMA_SHOTS=<folder> it saves PNGs of the pages.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/core_call.dart';
import 'package:maprisma_manager/home.dart';
import 'package:maprisma_manager/jobs_model.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;

import '../../packages/maprisma_manager_core/test/support.dart';
import 'page_shots.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0'};

void main() {
  late World w;
  setUpAll(loadShotFonts);
  setUp(() {
    configureLanguage('en');
    w = World.create();
    w.writeFile(p.join(w.home, 'profile'), 'balanced');
    w.writeFile(p.join(w.fakeBin, 'powerprofilesctl'), r'''#!/bin/sh
read cur < "$HOME/profile"
case "$1" in
  list) for x in performance balanced power-saver; do if [ "$x" = "$cur" ]; then echo "* $x:"; else echo "  $x:"; fi; echo; done ;;
  set) echo "$2" > "$HOME/profile" ;;
esac
''', mode: '755');
    w.writeFile(p.join(w.fakeBin, 'cosmic-settings'), '#!/bin/sh\n', mode: '755');
  });
  tearDown(() => w.dispose());

  String shellFile() => p.join(w.home, '.config/maprisma-shell/shell.json');

  CoreCall call(CoreService core) {
    final inner = inProcess(core);
    return (m, [params = const {}]) async {
      final r = await Zone.root.run(() => inner(m, params).then<Object>((v) => v, onError: (Object e) => _Failed(e)));
      if (r is _Failed) throw r.error;
      return r as Map<String, dynamic>;
    };
  }

  Future<void> settle(WidgetTester tester, [int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> open(WidgetTester tester, String desktop, double width) async {
    tester.view.physicalSize = Size(width, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = w.core(desktop: desktop);
    final jobs = JobsModel(call(core), every: const Duration(milliseconds: 200));
    addTearDown(jobs.dispose);
    await tester.pumpWidget(ManagerApp(core: call(core), look: const {'colors': _dark}, checkOnStart: false, relook: null, jobs: jobs, screenshots: p.join(w.dir, 'shots')));
    await settle(tester);
  }

  /// A page from the sidebar (in a condensed window through the toggle first).
  Future<void> nav(WidgetTester tester, String page) async {
    if (find.byKey(const ValueKey('nav-toggle')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('nav-toggle')));
      await settle(tester, 2);
    }
    // The sidebar scrolls (all entries can be reordered, Settings too): down to the entry first.
    final entry = find.byKey(ValueKey('nav-$page'));
    if (entry.evaluate().isEmpty) {
      // (a drag on the entries would move them: scroll the list itself)
      final list = tester.state<ScrollableState>(find.descendant(of: find.byKey(const ValueKey('sidebar')), matching: find.byType(Scrollable)).first);
      list.position.jumpTo(list.position.maxScrollExtent);
      await tester.pump();
    }
    await tester.tap(entry);
    await settle(tester);
  }

  testWidgets('the sidebar: entries and the separator are dragged into another order, saved, and reset', (tester) async {
    await open(tester, 'Hyprland', 900);
    List<String> saved() => ((jsonDecode(File(w.paths.settingsFile).readAsStringSync()) as Map)['sidebar_order'] as List?)?.cast<String>() ?? const [];
    double y(String key) => tester.getCenter(find.byKey(ValueKey(key))).dy;
    // Network below Bluetooth: drag it down one row (32 + 8).
    expect(y('nav-network'), lessThan(y('nav-bluetooth')));
    final drag = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('nav-network'))));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await drag.moveBy(const Offset(0, 6));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await drag.up();
    await settle(tester);
    expect(y('nav-network'), greaterThan(y('nav-bluetooth')));
    expect(saved().indexOf('network'), greaterThan(saved().indexOf('bluetooth')));
    // Ctrl+2 follows the order: Bluetooth is the third page now (Apps, Maprisma Apps, Bluetooth).
    expect(saved().take(3), ['systemApps', 'apps', 'bluetooth']);

    // A separator below Apps through the right-click menu, then it goes again.
    await tester.tap(find.byKey(const ValueKey('nav-systemApps')), buttons: kSecondaryButton);
    await settle(tester, 2);
    await tester.tap(find.byKey(const ValueKey('nav-menu-add')));
    await settle(tester);
    expect(saved().take(3), ['systemApps', '-', 'apps']);
    expect(find.byKey(const ValueKey('nav-separator-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-separator-0')), buttons: kSecondaryButton);
    await settle(tester, 2);
    await tester.tap(find.byKey(const ValueKey('nav-menu-remove')));
    await settle(tester);
    expect(saved().take(2), ['systemApps', 'apps']);

    // Default order: the saved one is removed.
    await tester.tap(find.byKey(const ValueKey('nav-apps')), buttons: kSecondaryButton);
    await settle(tester, 2);
    await tester.tap(find.byKey(const ValueKey('nav-menu-reset')));
    await settle(tester);
    expect(saved(), isEmpty);
    expect(y('nav-network'), lessThan(y('nav-bluetooth')));
  });

  testWidgets('Optimize: the Mirrors, Network and Bluetooth cards', (tester) async {
    w.fake('cachyos-rate-mirrors', 'exit 0');
    w.fake('rate-mirrors', 'exit 0');
    w.fake('pkexec', r'"$@"');
    w.fake('bluetoothctl', 'exit 0');
    w.fake('dig', 'echo ";; Query time: 12 msec"');
    w.fake('systemctl', r"""case "$1" in show) printf 'UnitFileState=enabled\nActiveState=active\nNextElapseUSecRealtime=@1795819962\nLastTriggerUSec=@1794955968\n' ;; esac""");
    w.fake('nmcli', r"""case "$*" in
  "-t -f NAME,UUID,TYPE,DEVICE connection show --active") printf 'Home:u1:802-11-wireless:wlan0\n' ;;
  "-t -g ipv4.ignore-auto-dns,ipv4.dns,802-11-wireless.powersave connection show u1") printf 'no\n\n0\n' ;;
  *"device show wlan0") printf 'IP4.DNS[1]:192.168.1.1\n' ;;
esac""");
    w.writeFile(p.join(w.root, 'etc/pacman.d/mirrorlist'), '# FINISHED AT: 2026-11-17 23:53:15.954687384 +01:00\nServer = https://a.example/\$repo/os/\$arch\n');
    w.writeFile(p.join(w.root, 'etc/pacman.d/cachyos-mirrorlist'), 'Server = https://c.example/\$arch/\$repo\n');
    w.writeFile(p.join(w.root, 'etc/bluetooth/main.conf'), '[General]\n#FastConnectable = false\n[Policy]\n#AutoEnable=true\n');
    w.writeFile(p.join(w.proc, 'sys/net/ipv4/tcp_congestion_control'), 'cubic\n');
    w.writeFile(p.join(w.proc, 'sys/net/ipv4/tcp_available_congestion_control'), 'reno cubic bbr\n');
    w.writeFile(p.join(w.proc, 'sys/net/core/default_qdisc'), 'fq_codel\n');
    await open(tester, 'Hyprland', 900);
    await nav(tester, 'optimize');
    for (final k in ['optimize-mirrors', 'optimize-network', 'mirrors-rank-now', 'mirrors-list-arch', 'net-dns', 'net-bbr', 'net-powersave']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    await tester.ensureVisible(find.byKey(const ValueKey('net-dns-test-button')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('net-dns-test-button')));
    // eight dig runs: under a loaded test run they take a while
    for (var i = 0; i < 40 && find.textContaining('Google 12 ms').evaluate().isEmpty; i++) {
      await settle(tester, 1);
    }
    expect(find.textContaining('Google 12 ms'), findsOneWidget);
    if (shotsDir != null) await saveShot(tester, 'optimize-900');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('bt-FastConnectable')), 200, scrollable: find.descendant(of: find.byKey(const ValueKey('optimize-page')), matching: find.byType(Scrollable)).first);
    expect(find.byKey(const ValueKey('optimize-bluetooth')), findsOneWidget);
    if (shotsDir != null) await saveShot(tester, 'optimize-bluetooth-900');
  });

  test('a saved order: unknown pages go, new pages come in after the page they follow', () {
    final merged = ManagerHomeState.mergeOrder(['settings', '-', '-', 'gone', 'power', 'systemApps']);
    expect(merged.take(4), ['settings', '-', 'power', 'optimize']);
    expect(merged.where((e) => e != '-').toSet(), {for (final s in Section.values) s.name});
    expect(ManagerHomeState.mergeOrder(null), ManagerHomeState.defaultOrder());
  });

  for (final width in [900.0, 600.0]) {
    testWidgets('Hyprland at ${width.round()} px: the sidebar, the Power page writes shell.json and sets the profile', (tester) async {
      w.writeFile(shellFile(), jsonEncode({'wallpaper': '/w.jpg', 'idle': {'lock': 180, 'screenOff': 300, 'suspend': 600, 'whilePlaying': false}}));
      await open(tester, 'Hyprland', width);
      final condensed = width < 648;
      // condensed: the sidebar hides behind the toggle and covers the window when shown
      expect(find.byKey(const ValueKey('sidebar')), condensed ? findsNothing : findsOneWidget);
      if (shotsDir != null) await saveShot(tester, 'sidebar-apps-${width.round()}');
      if (condensed) {
        await tester.tap(find.byKey(const ValueKey('nav-toggle')));
        await settle(tester, 2);
        if (shotsDir != null) await saveShot(tester, 'sidebar-open-${width.round()}');
        await tester.tap(find.byKey(const ValueKey('nav-toggle')));
        await settle(tester, 2);
      }
      // the list's filter has the keyboard; on another page Esc must not reach the hidden list:
      // it goes back to Apps (rule 5a) with the filter as it was
      await tester.enterText(find.byKey(const ValueKey('system-filter')), 'firefox');
      await settle(tester, 2);
      await nav(tester, 'power');
      expect(find.byKey(const ValueKey('sidebar')), condensed ? findsNothing : findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 2);
      expect(find.byKey(const ValueKey('power-page')), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('system-filter'), skipOffstage: false)).controller!.text, 'firefox');
      await nav(tester, 'power');
      for (final s in ['Power mode', 'Power saving options', 'Extended battery life', 'High performance']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('10 minutes'), findsOneWidget);
      if (shotsDir != null) await saveShot(tester, 'power-hyprland-${width.round()}');

      await tester.tap(find.byKey(const ValueKey('profile-power-saver')));
      await settle(tester);
      expect(File(p.join(w.home, 'profile')).readAsStringSync().trim(), 'power-saver');

      await tester.tap(find.text('10 minutes'));
      await settle(tester, 2);
      await tester.tap(find.text('Never').last);
      await settle(tester);
      final stored = jsonDecode(File(shellFile()).readAsStringSync()) as Map;
      expect(stored['wallpaper'], '/w.jpg');
      expect((stored['idle'] as Map)['suspend'], 0);

      await tester.ensureVisible(find.byKey(const ValueKey('idle-whilePlaying')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('idle-whilePlaying')));
      await settle(tester);
      expect(((jsonDecode(File(shellFile()).readAsStringSync()) as Map)['idle'] as Map)['whilePlaying'], isTrue);

      // Ctrl+, the settings; Ctrl+1 back to Apps; Ctrl+2 to Maprisma Apps
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
      if (shotsDir != null) await saveShot(tester, 'settings-${width.round()}');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.byKey(const ValueKey('settings-page')), findsNothing);
      expect(find.byKey(const ValueKey('system-apps-title')), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.byKey(const ValueKey('apps-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('COSMIC: the Power page only opens COSMIC Settings; Settings: F12 and Corners are saved', (tester) async {
    await open(tester, 'COSMIC', 900);
    await nav(tester, 'power');
    expect(find.text('Power is set in COSMIC Settings'), findsOneWidget);
    expect(find.text('Power mode'), findsNothing);
    expect(find.text('Power saving options'), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'power-cosmic-900');

    await nav(tester, 'settings');
    await tester.tap(find.byKey(const ValueKey('settings-screenshot-key')));
    await settle(tester);
    expect(Settings.load(w.paths).screenshotKey, isFalse);
    await tester.tap(find.text('Like windows'));
    await settle(tester, 2);
    await tester.tap(find.text('Square').last);
    await settle(tester);
    expect(Settings.load(w.paths).corners, 'square');
    expect(tester.takeException(), isNull);
  });

  // Rule 5a: Esc on a side page goes back to Apps; on Apps (the filter has the keyboard) it
  // hides the window as --toggle does; a dialog takes its own Esc first.
  testWidgets('Esc: side page back to Apps, then the window hides; a dialog first', (tester) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('maprisma-manager/window'), (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('maprisma-manager/window'), null));
    await open(tester, 'hyprland', 900);
    await nav(tester, 'power');
    expect(find.byKey(const ValueKey('power-page')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, 2);
    expect(find.byKey(const ValueKey('power-page')), findsNothing);
    expect(calls, isNot(contains('hide')));
    showDialog<void>(context: tester.element(find.byKey(const ValueKey('sidebar'))), builder: (_) => const AlertDialog(content: Text('a dialog')));
    await settle(tester, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, 2);
    expect(find.text('a dialog'), findsNothing);
    expect(calls, isNot(contains('hide')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, 2);
    expect(calls, contains('hide'));
  });
}

final class _Failed {
  _Failed(this.error);
  final Object error;
}
