import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() {
    w = World.create();
    w.fake('pkexec', r'"$@"');
    w.fake('bluetoothctl', 'exit 0');
    w.fake('systemctl', r'echo "$*" >> "$HOME/systemctl-calls"');
    for (final t in ['sh', 'awk', 'chmod', 'mv', 'cat', 'dirname', 'mkdir', 'printf', 'rm']) {
      final real = ['/usr/bin/$t', '/bin/$t'].where((x) => File(x).existsSync()).firstOrNull;
      if (real != null) Link(p.join(w.fakeBin, t)).createSync(real);
    }
    // nmcli: one Wi-Fi connection; modify/reapply calls are logged.
    w.fake('nmcli', r'''case "$*" in
  "-t -f NAME,UUID,TYPE,DEVICE connection show --active") printf 'lo:u0:loopback:lo\nHome\\:5G:u1:802-11-wireless:wlan0\n' ;;
  "-t -g ipv4.ignore-auto-dns,ipv4.dns,802-11-wireless.powersave connection show u1") printf 'yes\n9.9.9.9,149.112.112.112\n2\n' ;;
  "-t -f IP4.DNS,IP6.DNS device show wlan0"|"-t -f IP4.DNS device show wlan0") printf 'IP4.DNS[1]:9.9.9.9\n' ;;
  *) echo "$*" >> "$HOME/nmcli-calls" ;;
esac''');
  });
  tearDown(() => w.dispose());

  String calls(String name) => File(p.join(w.home, name)).readAsStringSync();

  test('network: the connection, its DNS as a known resolver, Wi-Fi power saving off', () async {
    w.writeFile(p.join(w.proc, 'sys/net/ipv4/tcp_congestion_control'), 'cubic\n');
    w.writeFile(p.join(w.proc, 'sys/net/ipv4/tcp_available_congestion_control'), 'reno cubic bbr\n');
    final r = await w.core().call('tune_net.get');
    expect(r['connection'], {'name': 'Home:5G', 'uuid': 'u1', 'type': '802-11-wireless', 'device': 'wlan0'});
    expect(r['dns'], allOf(containsPair('mode', 'quad9'), containsPair('current', ['9.9.9.9'])));
    expect(r['wifi'], containsPair('powersave', false));
    expect(r['tcp'], allOf(containsPair('congestion', 'cubic'), containsPair('bbrAvailable', true), containsPair('ours', false)));
  });

  test('network: DNS back to automatic and power saving on go through nmcli', () async {
    await w.core().call('tune_net.set_dns', {'mode': 'auto'});
    await w.core().call('tune_net.set_powersave', {'on': true});
    expect(calls('nmcli-calls').split('\n').where((l) => l.isNotEmpty).toList(), [
      'connection modify u1 ipv4.dns  ipv4.ignore-auto-dns no',
      'device reapply wlan0',
      'connection modify u1 802-11-wireless.powersave 3',
      'device reapply wlan0',
    ]);
    await expectLater(w.core().call('tune_net.set_dns', {'mode': '1.2.3.4'}), throwsA(isA<RouteError>()));
  });

  test('bluetooth: an option replaces its commented example in its section, then bluetooth restarts', () async {
    final conf = p.join(w.root, 'etc/bluetooth/main.conf');
    w.writeFile(conf, '[General]\n#FastConnectable = false\n#KernelExperimental = false\n#Experimental = false\n\n[Policy]\n# ReconnectAttempts define it\n#ReconnectAttempts=7\n');
    final core = w.core();
    expect(((await core.call('tune_bt.get'))['options'] as Map)['FastConnectable'], {'value': 'false', 'set': false});
    await core.call('tune_bt.set', {'key': 'Experimental', 'value': true});
    await core.call('tune_bt.set', {'key': 'ReconnectAttempts', 'value': 3});
    await core.call('tune_bt.set', {'key': 'AutoEnable', 'value': false});
    expect(File(conf).readAsStringSync(),
        '[General]\n#FastConnectable = false\n#KernelExperimental = false\nExperimental = true\n\n[Policy]\n# ReconnectAttempts define it\nReconnectAttempts = 3\nAutoEnable = false\n');
    expect(calls('systemctl-calls'), contains('try-restart bluetooth.service'));
    expect(((await core.call('tune_bt.get'))['options'] as Map)['Experimental'], {'value': 'true', 'set': true});
    await expectLater(core.call('tune_bt.set', {'key': 'Privacy', 'value': true}), throwsA(isA<RouteError>()));
    await expectLater(core.call('tune_bt.set', {'key': 'ReconnectAttempts', 'value': 'x; rm'}), throwsA(isA<RouteError>()));
  });
}
