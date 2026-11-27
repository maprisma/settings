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
    expect(log('bt.log'), ['show', 'pair AA:BB:CC:DD:EE:02', 'trust AA:BB:CC:DD:EE:02', 'connect AA:BB:CC:DD:EE:02', 'remove AA:BB:CC:DD:EE:01', 'power off']);
    await expectLater(core.call('bluetooth.connect', {'mac': 'aa:bb'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')));
  });

  test('bluetooth.pair: a device that never pairs (no bonding) still connects; a failed connect is an error', () async {
    final core = w.core(desktop: 'Hyprland');
    await core.call('bluetooth.pair', {'mac': 'AA:BB:CC:DD:EE:04'});
    expect(log('bt.log'), ['show', 'pair AA:BB:CC:DD:EE:04', 'trust AA:BB:CC:DD:EE:04', 'connect AA:BB:CC:DD:EE:04']);
    await expectLater(
      core.call('bluetooth.pair', {'mac': 'AA:BB:CC:DD:EE:05'}),
      throwsA(isA<RouteError>().having((e) => e.message, 'message', contains('Failed to connect'))),
    );
  });

  test('bluetooth.get: trusted devices count as known, not nearby', () async {
    w.writeFile(p.join(w.home, 'bt-trusted'), 'Device AA:BB:CC:DD:EE:02 Keyboard K3\n');
    final r = await w.core(desktop: 'Hyprland').call('bluetooth.get');
    expect((r['paired'] as List).map((d) => d['mac']), ['AA:BB:CC:DD:EE:01', 'AA:BB:CC:DD:EE:02']);
    expect(r['nearby'], isEmpty);
  });

  test('network.devices: parses link, wireless iw details, OUI vendors, device kinds, and traffic rate deltas', () async {
    fakeNetTools(w);
    var now = DateTime.utc(2026, 11, 26, 12, 0, 0);
    final core = w.core(desktop: 'Hyprland', clock: () => now);

    final r1 = await core.call('network.devices');
    expect(r1['active'], isTrue);
    final link = r1['link'] as Map<String, dynamic>;
    expect(link['iface'], 'wlan0');
    expect(link['isWireless'], isTrue);
    expect(link['ip'], '192.168.178.22');
    expect(link['cidr'], '192.168.178.22/24');
    expect(link['gateway'], '192.168.178.1');
    expect(link['mac'], 'aa:bb:cc:dd:ee:ff');
    expect(link['ssid'], 'FRITZ!Box 7690');
    expect(link['bssid'], '2e:23:a2:92:2a:80');
    expect(link['signalDbm'], -55);
    expect(link['quality'], 90);
    expect(link['band'], '6 GHz');
    expect(link['channel'], 37);
    expect(link['widthMhz'], 160);
    expect(link['rxMbps'], 1441);
    expect(link['txMbps'], 2402);

    final t1 = r1['traffic'] as Map<String, dynamic>;
    expect(t1['rxBytes'], 500000);
    expect(t1['txBytes'], 250000);
    expect(t1['rxRate'], 0.0);
    expect(t1['txRate'], 0.0);

    final devs = (r1['devices'] as List).cast<Map<String, dynamic>>();
    // FAILED and INCOMPLETE neighbors must be excluded.
    expect(devs.map((d) => d['ip']), containsAllInOrder(['192.168.178.1', '192.168.178.22', '192.168.178.50', '192.168.178.80']));
    expect(devs.any((d) => d['ip'] == '192.168.178.99' || d['ip'] == '192.168.178.100'), isFalse);
    expect(r1['onlineCount'], 3);
    expect(r1['totalCount'], 4);

    final gw = devs.firstWhere((d) => d['ip'] == '192.168.178.1');
    expect(gw['isGateway'], isTrue);
    expect(gw['kind'], 'router');
    expect(gw['vendor'], 'AVM FRITZ!');
    expect(gw['online'], isTrue);
    expect(gw['webUrl'], 'http://192.168.178.1');

    final self = devs.firstWhere((d) => d['ip'] == '192.168.178.22');
    expect(self['isSelf'], isTrue);
    expect(self['kind'], 'computer');
    expect(self['online'], isTrue);

    final hue = devs.firstWhere((d) => d['ip'] == '192.168.178.50');
    expect(hue['vendor'], 'Philips Hue (Signify)');
    expect(hue['kind'], 'smarthome');
    expect(hue['online'], isTrue);

    final priv = devs.firstWhere((d) => d['ip'] == '192.168.178.80');
    expect(priv['vendor'], 'Private MAC');
    expect(priv['kind'], 'device');
    expect(priv['online'], isFalse);

    // Advance clock by 2 seconds and bump /proc/net/dev counters to verify delta rates.
    now = now.add(const Duration(seconds: 2));
    w.writeFile(
      p.join(w.proc, 'net/dev'),
      'Inter-|   Receive                                                |  Transmit\n'
      ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n'
      '    lo: 10000    100    0    0    0     0          0         0    10000    100    0    0    0     0       0          0\n'
      ' wlan0: 520000   520    1    2    0     0          0         0   256000    310    0    1    0     0       0          0\n',
    );
    final r2 = await core.call('network.devices', {'rescan': true});
    final t2 = r2['traffic'] as Map<String, dynamic>;
    expect(t2['rxRate'], 10000.0);
    expect(t2['txRate'], 3000.0);

    // Offline state returns active: false.
    w.writeFile(p.join(w.home, 'net-offline'), '');
    final rOff = await core.call('network.devices');
    expect(rOff['active'], isFalse);
    expect(rOff['link'], isNull);
    expect(rOff['devices'], isEmpty);
  });

  test('network.monitor: parses ss connections, services, scopes, per-process aggregation, interfaces, DNS and rate deltas', () async {
    fakeNetTools(w);
    var now = DateTime.utc(2026, 11, 26, 12, 0, 0);
    final core = w.core(desktop: 'Hyprland', clock: () => now);

    final r1 = await core.call('network.monitor');
    final sum1 = r1['summary'] as Map<String, dynamic>;
    expect(sum1['total'], 5);
    expect(sum1['established'], 3);
    expect(sum1['listening'], 2);
    expect(sum1['tcp'], 3);
    expect(sum1['udp'], 2);
    expect(sum1['external'], 2);
    expect(sum1['lan'], 1);
    expect(sum1['loopback'], 1);
    expect(sum1['any'], 1);
    expect(sum1['processes'], 4);
    expect(sum1['rxBytes'], 500000);
    expect(sum1['txBytes'], 250000);

    final conns = (r1['connections'] as List).cast<Map<String, dynamic>>();
    final ffHttps = conns.firstWhere((c) => c['remoteIp'] == '1.1.1.1');
    expect(ffHttps['proto'], 'tcp');
    expect(ffHttps['state'], 'ESTABLISHED');
    expect(ffHttps['service'], 'HTTPS');
    expect(ffHttps['scope'], 'external');
    expect(ffHttps['process'], 'firefox');
    expect(ffHttps['pid'], 101);
    expect(ffHttps['cmdline'], contains('firefox'));
    expect(ffHttps['rxBytes'], 8000);
    expect(ffHttps['txBytes'], 2000);
    expect(ffHttps['rttMs'], 12.5);

    final ffQuic = conns.firstWhere((c) => c['remoteIp'] == '142.250.185.78');
    expect(ffQuic['proto'], 'udp');
    expect(ffQuic['service'], 'QUIC');
    expect(ffQuic['scope'], 'external');

    final mail = conns.firstWhere((c) => c['process'] == 'omamail');
    expect(mail['service'], 'IMAPS');
    expect(mail['scope'], 'lan');

    final sshd = conns.firstWhere((c) => c['process'] == 'sshd');
    expect(sshd['state'], 'LISTEN');
    expect(sshd['service'], 'SSH');
    expect(sshd['scope'], 'any');

    final procs = (r1['processes'] as List).cast<Map<String, dynamic>>();
    final ffProc = procs.firstWhere((pr) => pr['name'] == 'firefox');
    expect(ffProc['connections'], 2);
    expect(ffProc['external'], 2);
    expect(ffProc['rxBytes'], 8000);
    expect(ffProc['txBytes'], 2000);

    final ifaces = (r1['interfaces'] as List).cast<Map<String, dynamic>>();
    final wlan = ifaces.firstWhere((i) => i['name'] == 'wlan0');
    expect(wlan['kind'], 'wifi');
    expect(wlan['state'], 'up');
    expect(wlan['ip'], '192.168.178.22');
    // Prefers global IPv6 over link-local fe80::1.
    expect(wlan['ipv6'], '2003:d5:1::22');
    expect(wlan['mac'], 'aa:bb:cc:dd:ee:ff');
    expect(wlan['rxErrors'], 1);
    expect(wlan['rxDropped'], 2);

    expect(r1['dns'], ['192.168.178.1', '1.1.1.1']);

    // Second sample after 2s: verify per-socket and per-interface delta rates.
    now = now.add(const Duration(seconds: 2));
    w.writeFile(
      p.join(w.home, 'ss.out'),
      'Netid State     Recv-Q Send-Q Local Address:Port            Peer Address:Port Process\n'
      'tcp   ESTAB     0      0      192.168.178.22:45000          1.1.1.1:443       users:(("firefox",pid=101,fd=12))\n'
      '\t cubic rto:210 rtt:12.0/0.4 bytes_sent:6000 bytes_acked:6000 bytes_received:18000\n',
    );
    w.writeFile(
      p.join(w.proc, 'net/dev'),
      'Inter-|   Receive                                                |  Transmit\n'
      ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n'
      '    lo: 10000    100    0    0    0     0          0         0    10000    100    0    0    0     0       0          0\n'
      ' wlan0: 510000   510    1    2    0     0          0         0   254000    304    0    1    0     0       0          0\n',
    );
    final r2 = await core.call('network.monitor');
    final ff2 = (r2['connections'] as List).cast<Map<String, dynamic>>().single;
    expect(ff2['rxRate'], 5000.0);
    expect(ff2['txRate'], 2000.0);
    final sum2 = r2['summary'] as Map<String, dynamic>;
    expect(sum2['rxRate'], 5000.0);
    expect(sum2['txRate'], 2000.0);
  });

  test('network.monitor falls back to /proc/net/{tcp,udp} when ss is unavailable', () async {
    // Do NOT install fake `ss`; populate /proc/net/tcp, /proc/net/udp and /proc/777/fd.
    w.writeFile(
      p.join(w.proc, 'net/tcp'),
      '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
      '   0: 16B2A8C0:9C40 01010101:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 98765\n'
      '   1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 55555\n',
    );
    w.writeFile(p.join(w.proc, '777/comm'), 'curl\n');
    w.writeFile(p.join(w.proc, '777/cmdline'), 'curl\u0000https://example.com\u0000');
    Directory(p.join(w.proc, '777/fd')).createSync(recursive: true);
    Link(p.join(w.proc, '777/fd/3')).createSync('socket:[98765]');

    final r = await w.core(desktop: 'Hyprland').call('network.monitor');
    final conns = (r['connections'] as List).cast<Map<String, dynamic>>();
    expect(conns.length, 2);
    final c = conns.firstWhere((x) => x['state'] == 'ESTABLISHED');
    expect(c['localIp'], '192.168.178.22');
    expect(c['localPort'], 40000);
    expect(c['remoteIp'], '1.1.1.1');
    expect(c['remotePort'], 443);
    expect(c['service'], 'HTTPS');
    expect(c['scope'], 'external');
    expect(c['process'], 'curl');
    expect(c['pid'], 777);
  });

  test('network classification & security helpers: scope, cleanText, iface validation, OUI sub-blocks, unique IDs', () async {
    // S1: wildcards map to 'any', only real loopback maps to 'loopback'.
    expect(NetworkService.classifyScope('127.0.0.1'), 'loopback');
    expect(NetworkService.classifyScope('::1'), 'loopback');
    expect(NetworkService.classifyScope('::ffff:127.0.0.1'), 'loopback');
    expect(NetworkService.classifyScope('0.0.0.0'), 'any');
    expect(NetworkService.classifyScope('::'), 'any');
    expect(NetworkService.classifyScope('*'), 'any');
    expect(NetworkService.classifyScope(''), 'any');
    expect(NetworkService.classifyScope('192.168.1.5'), 'lan');
    expect(NetworkService.classifyScope('10.0.0.1'), 'lan');
    expect(NetworkService.classifyScope('172.20.1.1'), 'lan');
    expect(NetworkService.classifyScope('fe80::1%wlan0'), 'lan');
    expect(NetworkService.classifyScope('fc00::1'), 'lan');
    expect(NetworkService.classifyScope('::ffff:192.168.1.1'), 'lan');
    expect(NetworkService.classifyScope('1.1.1.1'), 'external');
    expect(NetworkService.classifyScope('2606:4700:4700::1111'), 'external');

    expect(NetworkService.identifyService(443, 'tcp'), 'HTTPS');
    expect(NetworkService.identifyService(443, 'udp'), 'QUIC');
    expect(NetworkService.identifyService(5353, 'udp'), 'mDNS');
    expect(NetworkService.identifyService(8009, 'tcp'), 'Cast');

    expect(NetworkService.freqToBandChannel(2437), ('2.4 GHz', 6));
    expect(NetworkService.freqToBandChannel(5180), ('5 GHz', 36));
    expect(NetworkService.freqToBandChannel(6135), ('6 GHz', 37));

    // S2: strip C1 control & bidi/zero-width chars, truncate by runes (never split surrogate pairs).
    expect(NetworkService.cleanText('ab\u0085\u009B\u200B\u202E\u2066\uFEFFcd<>&'), 'abcd');
    final emojiTrunc = NetworkService.cleanText('A😀B😀C', limit: 3);
    expect(emojiTrunc, 'A😀B');

    // S3: strict interface name validation.
    expect(NetworkService.isValidIface('wlan0'), isTrue);
    expect(NetworkService.isValidIface('enp16s0'), isTrue);
    expect(NetworkService.isValidIface('veth_1@if2'), isTrue);
    expect(NetworkService.isValidIface(''), isFalse);
    expect(NetworkService.isValidIface('.'), isFalse);
    expect(NetworkService.isValidIface('..'), isFalse);
    expect(NetworkService.isValidIface('-eth0'), isFalse);
    expect(NetworkService.isValidIface('a..b'), isFalse);
    expect(NetworkService.isValidIface('eth0/../../etc'), isFalse);

    // B6: OUI MA-M/MA-S sub-blocks (>6 hex digits) must NOT overwrite parent 6-digit OUI vendor.
    fakeNetTools(w);
    w.writeFile(
      p.join(w.root, 'usr/lib/udev/hwdb.d/20-OUI.hwdb'),
      'OUI:1C23A2*\n'
      ' ID_OUI_FROM_DATABASE=AVM Audiovisuelles Marketing und Computersysteme GmbH\n'
      '\n'
      'OUI:1C23A201*\n'
      ' ID_OUI_FROM_DATABASE=Wrong Sub-Allocation Corp\n',
    );
    final core = w.core(desktop: 'Hyprland');
    final devRes = await core.call('network.devices');
    final gw = (devRes['devices'] as List).cast<Map<String, dynamic>>().firstWhere((d) => d['ip'] == '192.168.178.1');
    expect(gw['vendor'], 'AVM FRITZ!');

    // B1: multiple sockets on same udp 0.0.0.0:5353 (different PIDs and anonymous) get unique IDs.
    w.writeFile(
      p.join(w.home, 'ss.out'),
      'Netid State     Recv-Q Send-Q Local Address:Port            Peer Address:Port Process\n'
      'udp   UNCONN    0      0      0.0.0.0:5353                  0.0.0.0:*         users:(("avahi-daemon",pid=501,fd=12))\n'
      'udp   UNCONN    0      0      0.0.0.0:5353                  0.0.0.0:*         users:(("chrome",pid=502,fd=40))\n'
      'udp   UNCONN    0      0      0.0.0.0:5353                  0.0.0.0:*\n'
      'udp   UNCONN    0      0      0.0.0.0:5353                  0.0.0.0:*\n',
    );
    final monRes = await core.call('network.monitor');
    final ids = [for (final c in (monRes['connections'] as List).cast<Map<String, dynamic>>()) c['id'] as String];
    expect(ids.length, 4);
    expect(ids.toSet().length, 4);
    // U3: wildcard UDP UNCONN sockets count as listening, not established/active.
    final sum = monRes['summary'] as Map<String, dynamic>;
    expect(sum['listening'], 4);
    expect(sum['established'], 0);
    expect(sum['any'], 4);
    expect(sum['loopback'], 0);
  });
}
