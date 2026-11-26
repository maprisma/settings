import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';
import 'support.dart';

void main() {
  late World w;
  setUp(() {
    w = World.create();
    fakeNmcli(w);
    fakeBluetoothctl(w);
  });
  tearDown(() => w.dispose());

  List<String> log(String name) {
    final f = File(p.join(w.home, name));
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }

  test('terse lines: escaped colons stay in the field', () {
    expect(NetworkService.terse(r'Home\:Net:WPA2:70'), ['Home:Net', 'WPA2', '70']);
    expect(NetworkService.terse(r'a\\b::c'), [r'a\b', '', 'c']);
  });

  test('network.get: known, visible (one per name, strongest, hidden ones left out), wired, VPN', () async {
    final r = await w.core(desktop: 'Hyprland').call('network.get');
    expect(r['wifiOn'], isTrue);
    expect(r['known'], [{'name': 'Home:Net', 'uuid': uuidHome, 'type': '802-11-wireless', 'active': true, 'device': 'wlan0'}]);
    expect([for (final v in r['visible'] as List) v['ssid']], ['Neighbour', 'Home:Net', 'Cafe']);
    final home = (r['visible'] as List).firstWhere((v) => v['ssid'] == 'Home:Net') as Map;
    expect(home, allOf(containsPair('inUse', true), containsPair('known', true), containsPair('signal', 70)));
    expect([for (final c in r['wired'] as List) c['uuid']], [uuidWired]);
    expect([for (final c in r['vpn'] as List) c['name']], ['Work']);
  });

  test('connect with a password: the key only in a private passwd-file (no argument, no editor), gone after', () async {
    final core = w.core(desktop: 'Hyprland');
    final r = await core.call('network.connect', {'ssid': 'Neighbour', 'password': 'secret-pass-123'});
    expect(r['uuid'], uuidNew);
    final calls = log('nmcli.log');
    expect(calls.where((l) => !l.startsWith('passwd-file:')).any((l) => l.contains('secret-pass-123')), isFalse);
    expect(calls, contains('passwd-file: 802-11-wireless-security.psk:secret-pass-123'));
    expect(calls, contains('passwd-dir-mode: 700'));
    expect(calls.any((l) => l.contains('connection edit')), isFalse);
    expect(calls.firstWhere((l) => l.contains('connection add')), endsWith('wifi-sec.key-mgmt wpa-psk wifi-sec.psk-flags 0'));
    final file = calls.firstWhere((l) => l.startsWith('connection up uuid $uuidNew passwd-file ')).split(' ').last;
    expect(File(file).existsSync(), isFalse);
    expect(Directory(p.dirname(file)).existsSync(), isFalse);
  });

  test('a secret file that can\'t be written also removes the new connection', () async {
    final runtime = Directory(p.join(w.dir, 'run'))..createSync();
    Process.runSync('chmod', ['500', runtime.path]);
    addTearDown(() => Process.runSync('chmod', ['700', runtime.path]));
    final core = w.core(desktop: 'Hyprland', extra: {'XDG_RUNTIME_DIR': runtime.path});
    await expectLater(core.call('network.connect', {'ssid': 'Neighbour', 'password': 'secret-pass-123'}), throwsA(anything));
    expect(log('nmcli.log'), contains('connection delete uuid $uuidNew'));
    expect(log('nmcli.log').any((l) => l.contains('connection up')), isFalse);
  });

  test('a password with a space at its start or end is refused (nmcli would trim it)', () async {
    final core = w.core(desktop: 'Hyprland');
    await expectLater(core.call('network.connect', {'ssid': 'Neighbour', 'password': 'abcdefgh '}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
    expect(log('nmcli.log').any((l) => l.contains('connection add')), isFalse);
  });

  test('a refused password removes the new connection again and throws auth_failed', () async {
    w.writeFile(p.join(w.home, 'fail-up'), '');
    final core = w.core(desktop: 'Hyprland');
    await expectLater(
      core.call('network.connect', {'ssid': 'Neighbour', 'password': 'wrong-pass-1'}),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'auth_failed').having((e) => e.message, 'message', contains('Secrets were required'))),
    );
    expect(log('nmcli.log'), contains('connection delete uuid $uuidNew'));
  });

  test('auth failure detection: Wi-Fi auth errors throw auth_failed; non-auth and non-Wi-Fi throw failed', () async {
    final core = w.core(desktop: 'Hyprland');
    for (final msg in [
      'Error: Secrets were required, but not provided.',
      'Error: No agents were available for this request.',
      'Error: Connection activation failed: invalid key.',
      'Error: Connection activation failed: supplicant-timeout.',
      'Error: Connection activation failed: 4-way handshake failed.',
    ]) {
      w.writeFile(p.join(w.home, 'fail-up'), msg);
      await expectLater(
        core.call('network.up', {'uuid': uuidHome}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'auth_failed').having((e) => e.message, 'message', msg.replaceFirst('Error: ', ''))),
        reason: msg,
      );
    }
    // Config/property errors or non-auth errors must NOT trigger auth_failed.
    for (final msg in [
      'Error: No network with SSID found.',
      'Error: 802-11-wireless-security.key-mgmt: property is missing.',
      'Error: password field not supported on this setting.',
    ]) {
      w.writeFile(p.join(w.home, 'fail-up'), msg);
      await expectLater(
        core.call('network.up', {'uuid': uuidHome}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'failed').having((e) => e.message, 'message', msg.replaceFirst('Error: ', ''))),
        reason: msg,
      );
    }
    // Non-Wi-Fi (VPN / wired) must never throw auth_failed even if stderr mentions secrets.
    w.writeFile(p.join(w.home, 'fail-up'), 'Error: Secrets were required, but not provided.');
    for (final uuid in [uuidWired, uuidVpn]) {
      await expectLater(
        core.call('network.up', {'uuid': uuid}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'failed')),
        reason: uuid,
      );
    }
  });

  test('network.up with a password preserves SAE/PSK without wiping PSK, uses a private passwd-file, and cleans up', () async {
    final core = w.core(desktop: 'Hyprland');
    // WPA3-SAE connection: preserves sae (never overwrites with wpa-psk) and does not wipe wifi-sec.psk.
    w.writeFile(p.join(w.home, 'key-mgmt'), 'sae');
    await core.call('network.up', {'uuid': uuidHome, 'password': 'new-secret-999'});
    final calls = log('nmcli.log');
    expect(calls.where((l) => !l.startsWith('passwd-file:')).any((l) => l.contains('new-secret-999')), isFalse);
    expect(calls.any((l) => l.contains('connection edit')), isFalse);
    expect(calls, contains('passwd-file: 802-11-wireless-security.psk:new-secret-999'));
    expect(calls, contains('passwd-dir-mode: 700'));
    final modIdx = calls.indexWhere((l) => l == 'connection modify uuid $uuidHome wifi-sec.psk-flags 0');
    final upIdx = calls.indexWhere((l) => l.startsWith('connection up uuid $uuidHome passwd-file '));
    expect(modIdx, greaterThanOrEqualTo(0));
    expect(upIdx, greaterThan(modIdx));
    expect(calls[modIdx], isNot(contains('wpa-psk')));
    expect(calls[modIdx], isNot(contains('wifi-sec.psk ')));
    final file = calls[upIdx].split(' ').last;
    expect(File(file).existsSync(), isFalse);
    expect(Directory(p.dirname(file)).existsSync(), isFalse);

    // Open profile (empty key-mgmt) initializes key-mgmt to wpa-psk.
    w.writeFile(p.join(w.home, 'key-mgmt'), '');
    await core.call('network.up', {'uuid': uuidHome, 'password': 'open-to-wpa-1'});
    expect(log('nmcli.log'), contains('connection modify uuid $uuidHome wifi-sec.key-mgmt wpa-psk wifi-sec.psk-flags 0'));

    // Cleanup also runs when authentication fails.
    w.writeFile(p.join(w.home, 'key-mgmt'), 'wpa-psk');
    w.writeFile(p.join(w.home, 'fail-up'), '');
    await expectLater(
      core.call('network.up', {'uuid': uuidHome, 'password': 'still-wrong-99'}),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'auth_failed')),
    );
    final failedUp = log('nmcli.log').lastWhere((l) => l.startsWith('connection up uuid $uuidHome passwd-file '));
    final failedFile = failedUp.split(' ').last;
    expect(File(failedFile).existsSync(), isFalse);
    expect(Directory(p.dirname(failedFile)).existsSync(), isFalse);
  });

  test('network.up with password rejects enterprise Wi-Fi, non-Wi-Fi, and invalid passwords (including UTF-8 byte limit)', () async {
    final core = w.core(desktop: 'Hyprland');
    for (final params in [
      {'uuid': uuidWired, 'password': 'valid-pass-123'},
      {'uuid': uuidVpn, 'password': 'valid-pass-123'},
      {'uuid': uuidHome, 'password': 'short'},
      {'uuid': uuidHome, 'password': 'abcdefgh '},
      {'uuid': uuidHome, 'password': 'has\nnewline'},
      // 32 'ä' chars = 64 UTF-8 bytes (> 63 byte WPA PSK limit).
      {'uuid': uuidHome, 'password': 'ä' * 32},
    ]) {
      await expectLater(
        core.call('network.up', params),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')),
        reason: '$params',
      );
    }
    for (final eap in ['wpa-eap', 'wpa-eap-suite-b-192', 'ieee8021x']) {
      w.writeFile(p.join(w.home, 'key-mgmt'), eap);
      await expectLater(
        core.call('network.up', {'uuid': uuidHome, 'password': 'valid-pass-123'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params').having((e) => e.message, 'message', contains('Enterprise'))),
        reason: eap,
      );
    }
    expect(log('nmcli.log').any((l) => l.startsWith('connection modify') || l.startsWith('connection up')), isFalse);
  });

  test('network.connect matches existing connections by 802-11-wireless.ssid, not profile name', () async {
    final core = w.core(desktop: 'Hyprland');
    // Same actual SSID: reuses uuidHome.
    final r = await core.call('network.connect', {'ssid': 'Home:Net', 'password': 'updated-pass-1'});
    expect(r['uuid'], uuidHome);
    expect(log('nmcli.log').any((l) => l.contains('connection add')), isFalse);
    expect(log('nmcli.log'), contains('passwd-file: 802-11-wireless-security.psk:updated-pass-1'));

    // Renamed profile whose NAME is "Home:Net" but 802-11-wireless.ssid is "DifferentSSID": creates a new connection.
    w.writeFile(p.join(w.home, 'home-ssid'), 'DifferentSSID');
    final r2 = await core.call('network.connect', {'ssid': 'Home:Net', 'password': 'brand-new-pass'});
    expect(r2['uuid'], uuidNew);
    expect(log('nmcli.log').any((l) => l.contains('connection add')), isTrue);
  });

  test('up/down/forget only for known connections of the right kind; bad input refused', () async {
    final core = w.core(desktop: 'Hyprland');
    await core.call('network.down', {'uuid': uuidHome});
    await core.call('network.up', {'uuid': uuidVpn});
    await core.call('network.forget', {'uuid': uuidHome});
    await core.call('network.wifi', {'on': false});
    expect(log('nmcli.log').where((l) => !l.startsWith('-t')), ['connection down uuid $uuidHome', 'connection up uuid $uuidVpn', 'connection delete uuid $uuidHome', 'radio wifi off']);
    for (final (route, params) in [
      ('network.forget', {'uuid': uuidWired}),
      ('network.up', {'uuid': '99999999-0000-0000-0000-000000000000'}),
      ('network.up', {'uuid': '--help'}),
      ('network.connect', {'ssid': 'x', 'password': 'short'}),
      ('network.connect', {'ssid': ''}),
      ('network.connect', {'ssid': '--help'}),
    ]) {
      await expectLater(core.call(route, params), throwsA(isA<RouteError>()), reason: '$route $params');
    }
  });

  test('bluetooth.get: paired with battery, nearby without the paired and the unnamed', () async {
    final r = await w.core(desktop: 'Hyprland').call('bluetooth.get');
    expect(r['powered'], isTrue);
    expect(r['paired'], [{'mac': 'AA:BB:CC:DD:EE:01', 'name': 'My Headphones', 'connected': true, 'icon': 'audio-headset', 'battery': 80}]);
    expect(r['nearby'], [{'mac': 'AA:BB:CC:DD:EE:02', 'name': 'Keyboard K3'}]);
  });

  test('bluetooth actions go to bluetoothctl; a bad address is refused', () async {
    final core = w.core(desktop: 'Hyprland');
    await core.call('bluetooth.pair', {'mac': 'AA:BB:CC:DD:EE:02'});
    await core.call('bluetooth.forget', {'mac': 'AA:BB:CC:DD:EE:01'});
    await core.call('bluetooth.power', {'on': false});
    expect(log('bt.log'), ['pair AA:BB:CC:DD:EE:02', 'trust AA:BB:CC:DD:EE:02', 'connect AA:BB:CC:DD:EE:02', 'remove AA:BB:CC:DD:EE:01', 'power off']);
    await expectLater(core.call('bluetooth.connect', {'mac': 'aa:bb'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
  });
}
