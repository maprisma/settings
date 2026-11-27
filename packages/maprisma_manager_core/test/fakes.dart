// Fake system tools for the settings pages' tests (core and Flutter): pactl, hyprctl,
// localectl, nmcli, bluetoothctl, xdg-mime, timedatectl and .desktop files. No package:test
// here, so the Flutter tests can use them too.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'support.dart';

/// pactl's JSON as PipeWire's pulse server gives it (shortened from a real machine).
final soundFixtures = {
  'info': {'default_sink_name': 'hdmi', 'default_source_name': 'mic'},
  'sinks': [
    {'index': 72, 'name': 'hdmi', 'description': 'HDMI (LG TV)', 'mute': false, 'volume': {'front-left': {'value_percent': '80%'}, 'front-right': {'value_percent': '60%'}}},
    {'index': 74, 'name': 'speakers', 'description': 'USB Audio Speakers', 'mute': true, 'volume': {'front-left': {'value_percent': '100%'}}},
  ],
  'sources': [
    {'index': 72, 'name': 'hdmi.monitor', 'description': 'Monitor of HDMI', 'monitor_source': 'hdmi', 'mute': false, 'volume': {}},
    {'index': 78, 'name': 'mic', 'description': 'Razer Kiyo', 'monitor_source': '', 'mute': false, 'volume': {'mono': {'value_percent': '45%'}}},
  ],
  'sink-inputs': [
    {'index': 4374, 'mute': false, 'properties': {'application.name': 'Google Chrome', 'media.name': 'Playback'}, 'volume': {'front-left': {'value_percent': '100%'}}},
  ],
  'cards': [
    {
      'name': 'alsa_card.usb',
      'properties': {'device.description': 'USB Audio'},
      'active_profile': 'HiFi',
      'profiles': {'off': {'description': 'Off', 'available': true}, 'HiFi': {'description': 'HiFi', 'available': true}},
    },
  ],
};

/// A fake pactl: `-f json list <what>` / `-f json info` from `$HOME/pactl/<what>.json`, every
/// other call appended to $HOME/pactl.log.
void fakePactl(World w) {
  for (final MapEntry(:key, :value) in soundFixtures.entries) {
    w.writeFile(p.join(w.home, 'pactl', '$key.json'), jsonEncode(value));
  }
  w.fake('pactl', r'''
if [ "$1" = "-f" ]; then
  if [ "$3" = "info" ]; then f="$HOME/pactl/info.json"; else f="$HOME/pactl/$4.json"; fi
  while IFS= read -r l || [ -n "$l" ]; do echo "$l"; done < "$f"
  exit 0
fi
echo "$*" >> "$HOME/pactl.log"''');
}

final monitorsFixture = [
  {
    'name': 'HDMI-A-1', 'description': 'LG TV', 'width': 3840, 'height': 2160, 'refreshRate': 120.0, 'x': 0, 'y': 0, 'scale': 2, 'transform': 0,
    'vrr': false, 'disabled': false, 'mirrorOf': 'none', 'availableModes': ['3840x2160@120.00Hz', '3840x2160@60.00Hz', '1920x1080@60.00Hz'],
  },
  {
    'name': 'DP-1', 'description': 'Dell', 'width': 2560, 'height': 1440, 'refreshRate': 59.95, 'x': 1920, 'y': 0, 'scale': 1, 'transform': 0,
    'vrr': false, 'disabled': false, 'mirrorOf': 'none', 'availableModes': ['2560x1440@59.95Hz'],
  },
];

/// A fake hyprctl (monitors, devices, getoption from $HOME/`opt/<key>`, reload logged) and
/// localectl (two layouts).
/// `hyprctl animations -j` of this PC's config (Maprisma Shell's animations.lua), shortened.
final animationsFixture = [
  [
    {'name': 'global', 'overridden': true, 'bezier': 'default', 'enabled': true, 'speed': 8.0, 'style': ''},
    {'name': 'windows', 'overridden': false, 'bezier': '', 'enabled': true, 'speed': 0.0, 'style': ''},
    {'name': 'windowsIn', 'overridden': true, 'bezier': 'emphasizedDecel', 'enabled': true, 'speed': 5.0, 'style': ''},
    {'name': 'windowsOut', 'overridden': true, 'bezier': 'emphasizedAccel', 'enabled': true, 'speed': 3.0, 'style': ''},
    {'name': 'windowsMove', 'overridden': true, 'bezier': 'standard', 'enabled': true, 'speed': 6.0, 'style': ''},
    {'name': 'layersIn', 'overridden': true, 'bezier': 'emphasizedDecel', 'enabled': true, 'speed': 5.0, 'style': 'slide'},
    {'name': 'layersOut', 'overridden': true, 'bezier': 'emphasizedAccel', 'enabled': true, 'speed': 4.0, 'style': 'slide'},
    {'name': 'fade', 'overridden': true, 'bezier': 'standard', 'enabled': true, 'speed': 6.0, 'style': ''},
    {'name': 'fadeLayers', 'overridden': true, 'bezier': 'standard', 'enabled': true, 'speed': 5.0, 'style': ''},
    {'name': 'workspaces', 'overridden': true, 'bezier': 'standard', 'enabled': true, 'speed': 5.0, 'style': ''},
    {'name': 'workspacesIn', 'overridden': false, 'bezier': '', 'enabled': true, 'speed': 0.0, 'style': ''},
    {'name': 'specialWorkspace', 'overridden': true, 'bezier': 'specialWorkSwitch', 'enabled': true, 'speed': 4.0, 'style': 'slidefadevert 15%'},
  ],
  [
    {'name': 'standard', 'X0': 0.2, 'Y0': 0.0, 'X1': 0.0, 'Y1': 1.0},
  ],
];

void fakeHypr(World w, {bool touchpad = false}) {
  w.writeFile(p.join(w.home, 'hypr', 'monitors.json'), jsonEncode(monitorsFixture));
  w.writeFile(p.join(w.home, 'hypr', 'devices.json'), jsonEncode({'mice': [{'name': touchpad ? 'elan-touchpad' : 'logitech-mouse'}], 'keyboards': []}));
  w.writeFile(p.join(w.home, 'opt', 'input.kb_layout'), '{"option": "input:kb_layout", "str": "de", "set": true}');
  w.writeFile(p.join(w.home, 'opt', 'input.repeat_rate'), '{"option": "input:repeat_rate", "int": 35, "set": true}');
  w.writeFile(p.join(w.home, 'opt', 'animations.enabled'), '{"option": "animations:enabled", "bool": true, "set": true}');
  w.writeFile(p.join(w.home, 'hypr', 'animations.json'), jsonEncode(animationsFixture));
  w.fake('hyprctl', r'''
show() { while IFS= read -r l || [ -n "$l" ]; do echo "$l"; done < "$1"; }
case "$1" in
  monitors) show "$HOME/hypr/monitors.json" ;;
  devices) show "$HOME/hypr/devices.json" ;;
  animations) show "$HOME/hypr/animations.json" ;;
  getoption) if [ -f "$HOME/opt/$2" ]; then show "$HOME/opt/$2"; else echo '{"option": "x", "bool": false, "set": false}'; fi ;;
  reload) echo reload >> "$HOME/hyprctl.log"; echo ok ;;
  *) exit 1 ;;
esac''');
  w.fake('localectl', 'echo de; echo us; echo fr');
}

const uuidHome = '11111111-2222-3333-4444-555555555555';
const uuidWired = '66666666-7777-8888-9999-000000000000';
const uuidVpn = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const uuidNew = '12345678-1234-1234-1234-123456789abc';

/// A fake nmcli: terse answers from the arguments, every call logged to $HOME/nmcli.log;
/// `connection up` fails when $HOME/fail-up exists (with its content or "Secrets were required"),
/// or when $HOME/expected-psk exists and the passwd-file does not supply that PSK;
/// $HOME/home-down makes Home:Net show as disconnected.
void fakeNmcli(World w) {
  w.fake('nmcli', '''
echo "\$*" >> "\$HOME/nmcli.log"
case "\$*" in
  "-t radio wifi") echo enabled ;;
  "-t -f DEVICE,TYPE,STATE,CONNECTION device status")
    if [ -f "\$HOME/home-down" ]; then
      printf 'wlan0:wifi:disconnected:\\nenp16s0:ethernet:unavailable:\\n'
    else
      printf 'wlan0:wifi:connected:Home\\\\:Net\\nenp16s0:ethernet:unavailable:\\n'
    fi ;;
  "-t -f NAME,UUID,TYPE,ACTIVE,DEVICE connection show")
    if [ -f "\$HOME/home-down" ]; then
      printf 'Home\\\\:Net:$uuidHome:802-11-wireless:no:\\nWired connection 1:$uuidWired:802-3-ethernet:no:\\nWork:$uuidVpn:wireguard:no:\\nlo:x:loopback:yes:lo\\n'
    else
      printf 'Home\\\\:Net:$uuidHome:802-11-wireless:yes:wlan0\\nWired connection 1:$uuidWired:802-3-ethernet:no:\\nWork:$uuidVpn:wireguard:no:\\nlo:x:loopback:yes:lo\\n'
    fi ;;
  "-t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list --rescan no"|"-t -f IN-USE,SSID,SECURITY,SIGNAL device wifi list --rescan yes")
    printf '*:Home\\\\:Net:WPA2:70\\n :Home\\\\:Net:WPA3:40\\n :Cafe::55\\n ::WPA2:30\\n :Neighbour:WPA2:80\\n' ;;
  "-t -f connection.uuid connection add"*) echo "connection.uuid:$uuidNew" ;;
  "-g 802-11-wireless-security.key-mgmt connection show uuid "*)
    if [ -f "\$HOME/key-mgmt" ]; then
      km=""
      IFS= read -r km < "\$HOME/key-mgmt" || true
      echo "\$km"
    else
      echo "wpa-psk"
    fi ;;
  "-g 802-11-wireless.ssid connection show uuid $uuidHome")
    if [ -f "\$HOME/home-ssid" ]; then
      s=""
      IFS= read -r s < "\$HOME/home-ssid" || true
      echo "\$s"
    else
      echo "Home:Net"
    fi ;;
  "device wifi connect "*)
    if [ -f "\$HOME/fail-open" ]; then
      echo "Error: Secrets were required, but not provided." >&2
      exit 4
    fi ;;
  "connection up uuid "*)
    psk=""
    case "\$5" in passwd-file)
      while IFS= read -r l; do
        echo "passwd-file: \$l" >> "\$HOME/nmcli.log"
        psk="\$l"
      done < "\$6"
      echo "passwd-dir-mode: \$(/usr/bin/stat -c %a "\$(/usr/bin/dirname "\$6")")" >> "\$HOME/nmcli.log" ;;
    esac
    if [ -f "\$HOME/fail-up" ]; then
      msg=""
      IFS= read -r msg < "\$HOME/fail-up" || true
      echo "\${msg:-Error: Secrets were required, but not provided.}" >&2
      exit 4
    fi
    if [ -f "\$HOME/expected-psk" ]; then
      want=""
      IFS= read -r want < "\$HOME/expected-psk" || true
      if [ "\$psk" != "802-11-wireless-security.psk:\$want" ]; then
        echo "Error: Connection activation failed: Secrets were required, but not provided." >&2
        exit 4
      fi
      /usr/bin/rm -f "\$HOME/home-down"
    fi ;;
esac
exit 0''');
}

void fakeBluetoothctl(World w) {
  w.fake('bluetoothctl', r'''
echo "$*" >> "$HOME/bt.log"
case "$*" in
  show) printf 'Controller 60:E9:AA:5D:C2:BC (public)\n\tName: pc\n\tPowered: yes\n' ;;
  "devices Paired") echo "Device AA:BB:CC:DD:EE:01 Headphones" ;;
  "devices Trusted") [ -f "$HOME/bt-trusted" ] && while IFS= read -r l; do echo "$l"; done < "$HOME/bt-trusted" ;;
  "pair AA:BB:CC:DD:EE:04") echo "Failed to pair: org.bluez.Error.AuthenticationTimeout" ; exit 1 ;;
  "connect AA:BB:CC:DD:EE:05") echo "Failed to connect: org.bluez.Error.Failed" ; exit 1 ;;
  devices) printf 'Device AA:BB:CC:DD:EE:01 Headphones\nDevice AA:BB:CC:DD:EE:02 Keyboard K3\nDevice AA:BB:CC:DD:EE:03 AA-BB-CC-DD-EE-03\n' ;;
  "info AA:BB:CC:DD:EE:01") printf 'Device AA:BB:CC:DD:EE:01 (public)\n\tAlias: My Headphones\n\tIcon: audio-headset\n\tConnected: yes\n\tBattery Percentage: 0x50 (80)\n' ;;
esac
exit 0''');
}

/// Fake `ip`, `iw`, `ss`, `/proc/net/dev`, `/sys/class/net/*`, `/etc/resolv.conf` and OUI hwdb
/// for `network.devices` and `network.monitor`.
void fakeNetTools(World w) {
  Directory(p.join(w.root, 'sys/class/net/wlan0/wireless')).createSync(recursive: true);
  w.writeFile(p.join(w.root, 'sys/class/net/wlan0/address'), 'aa:bb:cc:dd:ee:ff\n');
  w.writeFile(p.join(w.root, 'sys/class/net/wlan0/operstate'), 'up\n');
  w.writeFile(p.join(w.root, 'sys/class/net/wlan0/flags'), '0x1003\n');

  w.writeFile(p.join(w.root, 'sys/class/net/enp16s0/address'), '11:22:33:44:55:66\n');
  w.writeFile(p.join(w.root, 'sys/class/net/enp16s0/operstate'), 'down\n');
  w.writeFile(p.join(w.root, 'sys/class/net/enp16s0/flags'), '0x1002\n');
  w.writeFile(p.join(w.root, 'sys/class/net/enp16s0/type'), '1\n');

  w.writeFile(p.join(w.root, 'sys/class/net/lo/operstate'), 'unknown\n');
  w.writeFile(p.join(w.root, 'sys/class/net/lo/flags'), '0x9\n');
  w.writeFile(p.join(w.root, 'sys/class/net/lo/type'), '772\n');

  w.writeFile(
    p.join(w.proc, 'net/dev'),
    'Inter-|   Receive                                                |  Transmit\n'
    ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n'
    '    lo: 10000    100    0    0    0     0          0         0    10000    100    0    0    0     0       0          0\n'
    'enp16s0: 0         0    0    0    0     0          0         0        0      0    0    0    0     0       0          0\n'
    ' wlan0: 500000   500    1    2    0     0          0         0   250000    300    0    1    0     0       0          0\n',
  );

  w.writeFile(
    p.join(w.root, 'etc/resolv.conf'),
    '# Generated by NetworkManager\n'
    'nameserver 192.168.178.1\n'
    'nameserver 1.1.1.1\n'
    'nameserver 1.1.1.1\n',
  );

  w.writeFile(
    p.join(w.root, 'usr/lib/udev/hwdb.d/20-OUI.hwdb'),
    'OUI:1C23A2*\n'
    ' ID_OUI_FROM_DATABASE=AVM Audiovisuelles Marketing und Computersysteme GmbH\n'
    '\n'
    'OUI:001788*\n'
    ' ID_OUI_FROM_DATABASE=Signify B.V.\n'
    '\n'
    'OUI:D48D26*\n'
    ' ID_OUI_FROM_DATABASE=LG Innotek\n',
  );

  w.writeFile(
    p.join(w.home, 'ss.out'),
    'Netid State     Recv-Q Send-Q Local Address:Port            Peer Address:Port Process\n'
    'tcp   ESTAB     0      0      192.168.178.22:45000          1.1.1.1:443       users:(("firefox",pid=101,fd=12))\n'
    '\t cubic rto:210 rtt:12.5/0.5 bytes_sent:2000 bytes_acked:2000 bytes_received:8000\n'
    'tcp   ESTAB     0      0      192.168.178.22:45002          192.168.178.50:993 users:(("omamail",pid=202,fd=8))\n'
    '\t cubic rto:204 rtt:2.1/0.1 bytes_sent:500 bytes_acked:500 bytes_received:1500\n'
    'tcp   LISTEN    0      128    0.0.0.0:22                    0.0.0.0:*         users:(("sshd",pid=303,fd=3))\n'
    '\t cubic cwnd:10\n'
    'udp   UNCONN    0      0      127.0.0.53%lo:53              0.0.0.0:*         users:(("systemd-resolved",pid=404,fd=14))\n'
    'udp   ESTAB     0      0      192.168.178.22:51000          142.250.185.78:443 users:(("firefox",pid=101,fd=25))\n',
  );

  w.process(101, argv: ['/usr/lib/firefox/firefox', '--new-window']);
  w.process(202, argv: ['/usr/bin/omamail']);

  w.fake('ip', r'''
case "$*" in
  "-4 route show default")
    if [ ! -f "$HOME/net-offline" ]; then
      echo "default via 192.168.178.1 dev wlan0 proto dhcp src 192.168.178.22 metric 600"
    fi ;;
  "-4 -o addr show scope global")
    if [ ! -f "$HOME/net-offline" ]; then
      echo "3: wlan0    inet 192.168.178.22/24 brd 192.168.178.255 scope global dynamic noprefixroute wlan0"
    fi ;;
  "-o addr show")
    printf '1: lo    inet 127.0.0.1/8 scope host lo\n'
    printf '1: lo    inet6 ::1/128 scope host\n'
    if [ ! -f "$HOME/net-offline" ]; then
      printf '3: wlan0    inet 192.168.178.22/24 brd 192.168.178.255 scope global dynamic wlan0\n'
      printf '3: wlan0    inet6 fe80::1/64 scope link\n'
      printf '3: wlan0    inet6 2003:d5:1::22/64 scope global dynamic\n'
    fi ;;
  "-4 neigh show dev wlan0")
    printf '192.168.178.1 lladdr 1c:23:a2:92:2a:6c REACHABLE\n'
    printf '192.168.178.50 lladdr 00:17:88:11:22:33 REACHABLE\n'
    printf '192.168.178.80 lladdr 02:aa:bb:cc:dd:ee STALE\n'
    printf '192.168.178.99 FAILED\n'
    printf '192.168.178.100 INCOMPLETE\n' ;;
esac
exit 0''');

  w.fake('iw', r'''
case "$*" in
  "dev wlan0 link")
    printf 'Connected to 2e:23:a2:92:2a:80 (on wlan0)\n'
    printf '\tSSID: FRITZ!Box 7690\n'
    printf '\tfreq: 6135.0\n'
    printf '\tsignal: -55 dBm\n'
    printf '\trx bitrate: 1441.3 MBit/s 160MHz HE-MCS 7\n'
    printf '\ttx bitrate: 2401.9 MBit/s 160MHz HE-MCS 11\n' ;;
esac
exit 0''');

  w.fake('ss', r'''
if [ "$1" = "-tunapi" ] && [ -f "$HOME/ss.out" ]; then
  while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "$l"; done < "$HOME/ss.out"
  exit 0
fi
exit 1''');
}

/// Applications, Time & Language and About against fakes: .desktop files under the fake root
/// and HOME, xdg-mime/timedatectl/localectl logging their calls, /proc and /sys files.
void fakeSystem(World w) {
  String app(String name, String mime, {bool hidden = false}) => '[Desktop Entry]\nType=Application\nName=$name\nName[de]=X\nExec=x\nMimeType=$mime\n${hidden ? 'NoDisplay=true\n' : ''}';
  w.writeFile(p.join(w.root, 'usr/share/applications/firefox.desktop'), app('Firefox', 'text/html;x-scheme-handler/http;x-scheme-handler/https;'));
  w.writeFile(p.join(w.root, 'usr/share/applications/chrome.desktop'), app('Chrome', 'text/html;x-scheme-handler/http;'));
  w.writeFile(p.join(w.root, 'usr/share/applications/helper.desktop'), app('Helper', 'text/html;', hidden: true));
  w.writeFile(p.join(w.root, 'usr/share/applications/editor.desktop'), app('Editor', 'text/plain;'));
  w.fake('xdg-mime', r'echo "$*" >> "$HOME/xdg.log"; if [ "$1" = query ]; then case "$3" in x-scheme-handler/http) echo firefox.desktop;; esac; fi');
  w.fake('timedatectl', r'''echo "$*" >> "$HOME/tdc.log"
case "$1" in
  show) printf 'NTP=yes\nTimezone=Europe/Berlin\nCanNTP=yes\n' ;;
  list-timezones) printf 'Europe/Berlin\nEurope/Paris\nUTC\n' ;;
esac''');
  w.fake('localectl', r'''echo "$*" >> "$HOME/lc.log"
case "$1" in
  status) printf '   System Locale: LANG=en_US.UTF-8\n                  LC_TIME=de_DE.UTF-8\n       VC Keymap: de\n      X11 Layout: de\n' ;;
  list-locales) printf 'C.UTF-8\nde_DE.UTF-8\nen_US.UTF-8\n' ;;
esac''');
}

/// A 1x1 PNG (a theme's preview in the fakes).
const tinyPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

/// A fake `~/.local/bin/maprisma-theme-core`: `list` answers three themes (one hidden, one
/// light) with the current one from \$HOME/theme-current; `apply <slug>` logs to
/// \$HOME/theme.log and makes it the current one (`apply broken` fails as Theme core does).
void fakeThemeCore(World w, {bool old = false}) {
  w.writeFile(p.join(w.home, 'theme-current'), 'nord');
  final preview = p.join(w.home, 'themes/nord/preview.png');
  File(preview)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(base64Decode(tinyPng));
  for (final n in ['b.png', 'a.png']) {
    File(p.join(w.home, 'themes/nord/backgrounds', n))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(base64Decode(tinyPng));
  }
  final walls = p.join(w.home, 'themes/nord/backgrounds');
  w.writeFile(p.join(w.home, '.local/bin/maprisma-theme-core'), old
      ? '#!/bin/sh\necho \'{"error":"bad_args"}\'\nexit 2\n'
      : '''#!/bin/sh
IFS= read -r cur < "\$HOME/theme-current" || true
t() { [ "\$1" = "\$cur" ] && echo true || echo false; }
case "\$1" in
  list)
    printf '{"current":"%s","themes":[' "\$cur"
    printf '{"slug":"nord","name":"Nord","current":%s,"favorite":true,"hidden":false,"preview":"$preview","wallpapers":["$walls/b.png","$walls/gone.png","relative.png","$walls/a.png"],"colors":{"mode":"dark","background":"#2e3440","foreground":"#d8dee9","accent":"#88c0d0"}},' "\$(t nord)"
    printf '{"slug":"latte","name":"Catppuccin Latte","current":%s,"favorite":false,"hidden":false,"preview":null,"wallpapers":["$walls/a.png"],"colors":{"mode":"light","background":"#eff1f5","foreground":"#4c4f69","accent":"#1e66f5","red":"#d20f39"}},' "\$(t latte)"
    printf '{"slug":"secret","name":"Secret","current":%s,"favorite":false,"hidden":true,"preview":null,"colors":{"mode":"dark","background":"#000000"}},' "\$(t secret)"
    printf '{"slug":"autumn","name":"Autumn","current":%s,"favorite":false,"hidden":false,"preview":"/nowhere/x.png","colors":{"mode":"dark","background":"#2a1d17","foreground":"#e8d5c0","accent":"#e07a3f","green":"bad"}}' "\$(t autumn)"
    echo ']}' ;;
  apply)
    echo "apply \$2" >> "\$HOME/theme.log"
    if [ "\$2" = broken ]; then echo '{"error":"not_found","message":"no theme broken"}'; exit 1; fi
    echo "\$2" > "\$HOME/theme-current"
    printf '{"applied":"%s","done":["colors","wallpaper"]}\n' "\$2" ;;
  *) echo '{"error":"bad_args"}'; exit 2 ;;
esac
''', mode: '755');
}
