import 'dart:async';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World.create());
  tearDown(() => w.dispose());

  Future<void> until(bool Function() cond) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!cond()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  String writeTray() {
    final tray = p.join(w.fakeBin, 'mm-tray');
    w.writeFile(tray, r'''#!/bin/sh
echo "direct $*" >> "$HOME/tray.log"
''', mode: '755');
    return tray;
  }

  CoreService core(String desktop, {String? hypr}) => w.core(desktop: 'KDE', extra: {
    'PATH': '${w.fakeBin}:/usr/bin:/bin',
    'XDG_CURRENT_DESKTOP': desktop,
    'HYPRLAND_INSTANCE_SIGNATURE': ?hypr,
  });

  test('a tray starts in a scope that is part of graphical-session.target while the session runs', () async {
    final tray = writeTray();
    w.fake('systemctl', 'echo "\$*" >> "\$HOME/systemctl.log"; exit 0');
    w.fake('systemd-run', 'echo "\$*" >> "\$HOME/run.log"');
    expect(await core('KDE').jobs.startTray(tray, ['daemon']), isTrue);
    final log = File(p.join(w.home, 'run.log'));
    await until(log.existsSync);
    final args = log.readAsStringSync();
    expect(args, contains('--user --scope'));
    expect(args, contains('PartOf=graphical-session.target'));
    expect(args, endsWith('$tray daemon\n'));
    expect(File(p.join(w.home, 'systemctl.log')).readAsStringSync(), contains('is-active --quiet graphical-session.target'));
  });

  test('without an active graphical session the tray is started directly', () async {
    final tray = writeTray();
    w.fake('systemctl', 'exit 3');
    w.fake('systemd-run', 'echo "\$*" >> "\$HOME/run.log"');
    expect(await core('KDE').jobs.startTray(tray), isTrue);
    final log = File(p.join(w.home, 'tray.log'));
    await until(log.existsSync);
    expect(log.readAsStringSync(), 'direct \n');
    expect(File(p.join(w.home, 'run.log')).existsSync(), isFalse);
  });

  test('a process with another desktop session\'s environment is from another session', () {
    void environ(int pid, Map<String, String> e) =>
        w.writeFile(p.join(w.proc, '$pid', 'environ'), e.entries.map((x) => '${x.key}=${x.value}\u0000').join());
    environ(10, {'XDG_CURRENT_DESKTOP': 'Hyprland', 'HYPRLAND_INSTANCE_SIGNATURE': 'abc'});
    environ(11, {'XDG_CURRENT_DESKTOP': 'KDE', 'PATH': '/usr/bin'});
    environ(12, {'XDG_CURRENT_DESKTOP': 'Hyprland', 'HYPRLAND_INSTANCE_SIGNATURE': 'old'});
    final kde = core('KDE').jobs;
    expect(kde.fromOtherSession(10), isTrue);
    expect(kde.fromOtherSession(11), isFalse);
    expect(kde.fromOtherSession(99), isFalse, reason: 'unreadable: kept');
    final hypr = core('Hyprland', hypr: 'abc').jobs;
    expect(hypr.fromOtherSession(10), isFalse);
    expect(hypr.fromOtherSession(12), isTrue, reason: 'an earlier Hyprland');
  });
}
