import 'translations.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:maprisma_core_kit/files.dart' show PrivateFolder;
import 'package:path/path.dart' as p;

import 'context.dart';

/// The Network & Wireless page on Hyprland (COSMIC Settings' Wi-Fi, Wired and VPN): the Wi-Fi
/// switch, known and visible networks (connect, disconnect, forget), wired and VPN connections
/// (connect, disconnect). Through `nmcli` (NetworkManager); a Wi-Fi password goes only through
/// a private passwd-file (never a command line, never nmcli's editor and its history). WPA-Enterprise and editing are left to
/// Maprisma WLAN Monitor or nm-connection-editor.
final class NetworkService {
  NetworkService(this.ctx);
  final Ctx ctx;

  /// nmcli's terse line split at unescaped ':' (`\:` and `\\` are escapes).
  static List<String> terse(String line) {
    final out = <String>[];
    final b = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == r'\' && i + 1 < line.length) {
        b.write(line[++i]);
      } else if (c == ':') {
        out.add(b.toString());
        b.clear();
      } else {
        b.write(c);
      }
    }
    out.add(b.toString());
    return out;
  }

  Future<List<List<String>>> _rows(List<String> args, {Duration timeout = const Duration(seconds: 15)}) async {
    final r = await ctx.runner.run(['nmcli', '-t', ...args], timeout: timeout);
    if (!r.ok) throw RouteError('failed', _why(r.stderr, r.code));
    return [for (final l in r.stdout.split('\n')) if (l.isNotEmpty) terse(l)];
  }

  static final _authFailure = RegExp(
    r'secrets were required|no agents were available|no secrets|no-secrets|supplicant-timeout|supplicant-disconnect|4-way handshake|pre-shared key|invalid key|wrong password',
    caseSensitive: false,
  );

  static bool _isAuthFailure(String stderr) => _authFailure.hasMatch(stderr);

  Future<String> _prop(String uuid, String field) async {
    final r = await ctx.runner.run(['nmcli', '-g', field, 'connection', 'show', 'uuid', uuid], timeout: const Duration(seconds: 15));
    if (!r.ok) throw RouteError('failed', _why(r.stderr, r.code));
    return r.stdout.replaceFirst(RegExp(r'\r?\n$'), '');
  }

  Future<void> _nmcli(List<String> args, {Duration timeout = const Duration(seconds: 45), bool detectAuth = false}) async {
    final r = await ctx.runner.run(['nmcli', ...args], timeout: timeout);
    if (!r.ok) {
      final msg = _why(r.stderr, r.code);
      throw RouteError(detectAuth && _isAuthFailure(r.stderr) ? 'auth_failed' : 'failed', msg);
    }
  }

  static String _why(String s, int code) {
    final l = s.trim().split('\n').where((x) => x.trim().isNotEmpty).lastOrNull?.trim() ?? '';
    return l.isEmpty ? trf('exit {0}', [code]) : l.replaceFirst(RegExp(r'^Error:\s*'), '');
  }

  void _need() {
    if (ctx.runner.which('nmcli') == null) throw RouteError('unavailable', tr('nmcli is missing (NetworkManager)'));
  }

  static const _wifi = '802-11-wireless', _wired = '802-3-ethernet';
  static const _vpn = {'vpn', 'wireguard'};

  /// `network.get` {rescan?}.
  Future<Map<String, dynamic>> get([Map<String, dynamic> params = const {}]) async {
    _need();
    final rescan = params['rescan'] == true;
    final radio = await _rows(['radio', 'wifi']);
    final devices = await _rows(['-f', 'DEVICE,TYPE,STATE,CONNECTION', 'device', 'status']);
    final conns = await _rows(['-f', 'NAME,UUID,TYPE,ACTIVE,DEVICE', 'connection', 'show']);
    final hasWifi = devices.any((d) => d.length > 1 && d[1] == 'wifi');
    final wifiOn = radio.isNotEmpty && radio.first.first == 'enabled';
    var visible = <List<String>>[];
    if (hasWifi && wifiOn) {
      try {
        visible = await _rows(['-f', 'IN-USE,SSID,SECURITY,SIGNAL', 'device', 'wifi', 'list', '--rescan', rescan ? 'yes' : 'no'], timeout: const Duration(seconds: 30));
      } on RouteError {
        visible = const [];
      }
    }
    Map<String, dynamic> conn(List<String> c) => {'name': c[0], 'uuid': c[1], 'type': c[2], 'active': c[3] == 'yes', 'device': c.length > 4 ? c[4] : ''};
    final known = [for (final c in conns) if (c.length >= 4 && c[2] == _wifi) conn(c)];
    // One row per network name: the strongest; the known ones are listed above.
    final bySsid = <String, Map<String, dynamic>>{};
    for (final v in visible) {
      if (v.length < 4 || v[1].isEmpty) continue;
      final signal = int.tryParse(v[3]) ?? 0;
      final seen = bySsid[v[1]];
      if (seen == null || (seen['signal'] as int) < signal || v[0] == '*') {
        bySsid[v[1]] = {'ssid': v[1], 'security': v[2], 'signal': signal, 'inUse': v[0] == '*' || (seen?['inUse'] == true), 'known': known.any((k) => k['name'] == v[1])};
      }
    }
    final networks = bySsid.values.toList()..sort((a, b) => (b['signal'] as int).compareTo(a['signal'] as int));
    return {
      'wifiDevice': hasWifi,
      'wifiOn': wifiOn,
      'known': known,
      'visible': networks,
      'wired': [for (final c in conns) if (c.length >= 4 && c[2] == _wired) conn(c)],
      'wiredDevices': [
        for (final d in devices)
          if (d.length >= 3 && d[1] == 'ethernet') {'device': d[0], 'state': d[2], 'connection': d.length > 3 ? d[3] : ''},
      ],
      'vpn': [for (final c in conns) if (c.length >= 4 && _vpn.contains(c[2])) conn(c)],
      'monitor': ctx.runner.which('maprisma-wlan-monitor') != null,
      'editor': ctx.runner.which('nm-connection-editor') != null,
    };
  }

  /// `network.wifi` {on}.
  Future<Map<String, dynamic>> wifi(Map<String, dynamic> params) async {
    _need();
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    await _nmcli(['radio', 'wifi', on ? 'on' : 'off'], timeout: const Duration(seconds: 15));
    return {'on': on};
  }

  Future<Map<String, dynamic>> _known(Object? uuid, {Set<String>? types}) async {
    if (uuid is! String || !RegExp(r'^[0-9a-fA-F-]{8,64}$').hasMatch(uuid)) throw RouteError('bad_params', 'uuid');
    final conns = await _rows(['-f', 'NAME,UUID,TYPE,ACTIVE,DEVICE', 'connection', 'show']);
    final c = conns.where((c) => c.length >= 4 && c[1] == uuid && (types == null || types.contains(c[2]))).firstOrNull;
    if (c == null) throw RouteError('not_found', tr('no such connection'));
    return {'name': c[0], 'uuid': c[1], 'type': c[2]};
  }

  static String _validatePassword(Object? password) {
    if (password is! String || password.contains('\n')) {
      throw RouteError('bad_params', tr('The password needs 8 to 63 characters'));
    }
    final bytes = utf8.encode(password).length;
    if (bytes < 8 || bytes > 63) {
      throw RouteError('bad_params', tr('The password needs 8 to 63 characters'));
    }
    // nmcli trims what it reads from a passwd-file: such a password would be sent shortened.
    if (password.trim() != password) {
      throw RouteError('bad_params', tr('A password that starts or ends with a space can\'t be set here: use Maprisma WLAN Monitor or nmcli'));
    }
    return password;
  }

  /// Writes the Wi-Fi PSK into a private 0700 runtime folder / 0600 `secrets` file for `nmcli`'s
  /// `passwd-file`, runs [fn] with its path, and always removes the folder afterwards.
  Future<T> _withPasswdFile<T>(String password, Future<T> Function(String path) fn) async {
    // A folder only this user can enter (0700, in the runtime folder: memory, not disk), the
    // file only this user can read (0600, never through a link).
    final runtime = ctx.environment['XDG_RUNTIME_DIR'];
    final base = runtime != null && runtime.startsWith('/') && Directory(runtime).existsSync() ? runtime : Directory.systemTemp.path;
    final dir = Directory('$base/maprisma-settings-wifi-$pid-${DateTime.now().microsecondsSinceEpoch}');
    try {
      final folder = PrivateFolder.open(dir.path);
      try {
        folder.writeNew('secrets', utf8.encode('802-11-wireless-security.psk:$password\n'));
      } finally {
        folder.close();
      }
      return await fn('${dir.path}/secrets');
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }

  /// `network.up` {uuid, password?} / `network.down` {uuid}: a known Wi-Fi, wired or VPN connection.
  /// With `password` (Wi-Fi PSK/SAE only), preserves existing `sae`/`wpa-psk` key-mgmt without
  /// wiping any existing saved PSK up front and activates via a private passwd-file (never a
  /// command line, never nmcli's editor).
  Future<Map<String, dynamic>> up(Map<String, dynamic> params) async {
    _need();
    final c = await _known(params['uuid'], types: {_wifi, _wired, ..._vpn});
    final uuid = c['uuid'] as String;
    final rawPassword = params['password'];
    if (rawPassword == null) {
      await _nmcli(['connection', 'up', 'uuid', uuid], detectAuth: c['type'] == _wifi);
      return c;
    }
    if (c['type'] != _wifi) throw RouteError('bad_params', 'password');
    final password = _validatePassword(rawPassword);
    final keyMgmt = (await _prop(uuid, '802-11-wireless-security.key-mgmt')).trim();
    if (keyMgmt.startsWith('wpa-eap') || keyMgmt == 'ieee8021x') {
      throw RouteError('bad_params', tr('Enterprise Wi-Fi passwords cannot be changed here'));
    }
    // Preserve WPA3-SAE (or existing wpa-psk) and keep any working PSK intact if activation fails;
    // only initialize key-mgmt to wpa-psk when the profile had no security setting yet.
    await _nmcli(
      [
        'connection',
        'modify',
        'uuid',
        uuid,
        if (keyMgmt.isEmpty) ...['wifi-sec.key-mgmt', 'wpa-psk'],
        'wifi-sec.psk-flags',
        '0',
      ],
      timeout: const Duration(seconds: 20),
    );
    await _withPasswdFile(
      password,
      (path) => _nmcli(['connection', 'up', 'uuid', uuid, 'passwd-file', path], timeout: const Duration(seconds: 60), detectAuth: true),
    );
    return c;
  }

  Future<Map<String, dynamic>> down(Map<String, dynamic> params) async {
    _need();
    final c = await _known(params['uuid'], types: {_wifi, _wired, ..._vpn});
    await _nmcli(['connection', 'down', 'uuid', c['uuid'] as String], timeout: const Duration(seconds: 20));
    return c;
  }

  /// `network.forget` {uuid}: a known Wi-Fi network only.
  Future<Map<String, dynamic>> forget(Map<String, dynamic> params) async {
    _need();
    final c = await _known(params['uuid'], types: {_wifi});
    await _nmcli(['connection', 'delete', 'uuid', c['uuid'] as String], timeout: const Duration(seconds: 20));
    return c;
  }

  /// `network.connect` {ssid, password?}: a visible network. Open: `device wifi connect`; with a
  /// password: a new connection without the key, brought up with a private passwd-file. If a known
  /// Wi-Fi connection with the same `802-11-wireless.ssid` already exists, activates/updates it.
  Future<Map<String, dynamic>> connect(Map<String, dynamic> params) async {
    _need();
    final ssid = params['ssid'], rawPassword = params['password'];
    // A name starting with '-' would reach nmcli as an option.
    if (ssid is! String || ssid.isEmpty || ssid.length > 32 || ssid.contains('\n') || ssid.startsWith('-')) throw RouteError('bad_params', 'ssid');
    final password = rawPassword == null ? null : _validatePassword(rawPassword);
    final conns = await _rows(['-f', 'NAME,UUID,TYPE,ACTIVE,DEVICE', 'connection', 'show']);
    String? existingUuid;
    for (final c in conns) {
      if (c.length >= 4 && c[2] == _wifi) {
        if (await _prop(c[1], '802-11-wireless.ssid') == ssid) {
          existingUuid = c[1];
          break;
        }
      }
    }
    if (existingUuid != null) {
      final c = await up({'uuid': existingUuid, if (password != null) 'password': password});
      return {'ssid': ssid, 'uuid': c['uuid']};
    }
    if (password == null) {
      await _nmcli(['device', 'wifi', 'connect', ssid], detectAuth: true);
      return {'ssid': ssid};
    }
    // The key is saved by NetworkManager (psk-flags 0) when it comes from nmcli's passwd-file:
    // never on a command line, never in nmcli's editor history (~/.cache/nmcli-history).
    final add = await ctx.runner.run(['nmcli', '-t', '-f', 'connection.uuid', 'connection', 'add', 'type', 'wifi', 'con-name', ssid, 'ssid', ssid, 'wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk-flags', '0'], timeout: const Duration(seconds: 20));
    if (!add.ok) throw RouteError('failed', _why(add.stderr, add.code));
    final uuid = RegExp(r'[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}').firstMatch(add.stdout)?.group(0);
    if (uuid == null) throw RouteError('failed', tr('NetworkManager made no connection'));
    try {
      await _withPasswdFile(
        password,
        (path) => _nmcli(['connection', 'up', 'uuid', uuid, 'passwd-file', path], timeout: const Duration(seconds: 60), detectAuth: true),
      );
    } on Object {
      // A wrong password (or a secret file that couldn't be written) leaves no half connection.
      await ctx.runner.run(['nmcli', 'connection', 'delete', 'uuid', uuid], timeout: const Duration(seconds: 15));
      rethrow;
    }
    return {'ssid': ssid, 'uuid': uuid};
  }

  // --- LAN Devices (`network.devices`) & Live Network Monitor (`network.monitor`) ---

  Map<String, String>? _ouiDb;
  final Map<String, ({int rx, int tx, DateTime at})> _prevDevTraffic = {};
  final Map<String, ({int rx, int tx})> _prevSockBytes = {};
  DateTime? _prevSockTime;
  final Map<String, ({int rx, int tx})> _prevIfaceBytes = {};
  DateTime? _prevIfaceTime;

  static const _activeNeighStates = {'REACHABLE', 'DELAY', 'PROBE', 'PERMANENT', 'NOARP'};
  static const _skipNeighStates = {'FAILED', 'INCOMPLETE'};
  static final _ifaceRe = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_@.:+-]{0,31}$');
  static final _ouiLineRe = RegExp(r'^OUI:([0-9A-Fa-f]{6})\*\s*$');
  static final _macRe = RegExp(r'^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$');
  static final _ipv4Re = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

  static bool isValidIface(String name) => name.isNotEmpty && name != '.' && name != '..' && !name.contains('..') && _ifaceRe.hasMatch(name);

  static bool isListeningConn(Map<String, dynamic> c) {
    final state = '${c['state'] ?? ''}';
    if (state == 'LISTEN') return true;
    if (state == 'UNCONN') {
      final rp = (c['remotePort'] as int?) ?? 0;
      final rip = '${c['remoteIp'] ?? ''}';
      return rp == 0 || rip.isEmpty || rip == '*' || rip == '0.0.0.0' || rip == '::';
    }
    return false;
  }

  static bool isActiveConn(Map<String, dynamic> c) {
    if (isListeningConn(c)) return false;
    final state = '${c['state'] ?? ''}';
    return state == 'ESTABLISHED' || state == 'SYN_SENT' || state == 'SYN_RECV' || state == 'UNCONN';
  }

  static final _vendorSuffixRe = RegExp(
    r'\b(Incorporated|Inc\.?|Corporation|Corp\.?|Co\.?,?\s*Ltd\.?|Ltd\.?|Pte\.?|GmbH|B\.?V\.?|S\.?A\.?|AG|LLC|PLC)\b\.?',
    caseSensitive: false,
  );
  static const _vendorAliases = {
    'Sonova Consumer Hearing': 'Sennheiser (Sonova)',
    'Versuni': 'Philips (Versuni)',
    'Signify': 'Philips Hue (Signify)',
    'LG Innotek': 'LG Electronics',
    'CLOUD NETWORK TECHNOLOGY SINGAPORE': 'Foxconn / MediaTek',
    'AVM Audiovisuelles Marketing und Computersysteme': 'AVM FRITZ!',
  };

  static final _kindNameRules = <(String, RegExp)>[
    ('router', RegExp(r'repeater|fritz!?box|fritz!?repeater|mesh|access ?point|router', caseSensitive: false)),
    ('tv', RegExp(r'\btv\b|webos|bravia|fire ?tv|chromecast|roku|television|tizen|android ?tv|shield|soundbar|speaker|sonos|homepod|apple ?tv|playstation|\bps[345]\b|xbox|nintendo', caseSensitive: false)),
    ('phone', RegExp(r'iphone|ipad|android|galaxy|pixel|smartphone|handy|phone|tablet|watch', caseSensitive: false)),
    ('printer', RegExp(r'printer|drucker|laserjet|officejet|deskjet|\bepson|\bbrother|\bcanon|\bhl-|\bmfc-', caseSensitive: false)),
    ('smarthome', RegExp(r'\bhue\b|tradfri|nanoleaf|\bwiz\b|lamp|light|bulb|shelly|sonoff|switchbot|roborock|roomba|camera|\bcam\b|doorbell|reolink|eufy|arlo|hikvision|espresso|coffee', caseSensitive: false)),
    ('computer', RegExp(r'macbook|imac|\bmac\b|mac ?mini|mac ?studio|mac ?pro|laptop|notebook|thinkpad|surface|chromebook|desktop|\bpc\b|workstation|omarchy|raspberry|\bnas\b|synology|qnap|server', caseSensitive: false)),
  ];

  static final _kindVendorRules = <(String, RegExp)>[
    ('router', RegExp(r'\bavm\b|fritz|ubiquiti|netgear|linksys|ruckus|eero|zyxel|mikrotik|tp-link', caseSensitive: false)),
    ('smarthome', RegExp(r'espressif|tuya|shelly|allterco|microchip|silicon lab|itead|sonoff|meross|particle|texas instruments|nordic|beken|bouffalo|signify|philips hue|lumi united|nanoleaf|versuni|miele|bsh|irobot|roborock|dreame|ecovacs', caseSensitive: false)),
    ('printer', RegExp(r'brother|epson|canon|hewlett|hp inc|kyocera|lexmark|xerox', caseSensitive: false)),
    ('tv', RegExp(r'lg electronics|sonos|sennheiser|sonova|bose|harman|denon|yamaha|bang|bluesound|nintendo|sony', caseSensitive: false)),
    ('phone', RegExp(r'samsung|xiaomi|huawei|oneplus|oppo|vivo|motorola|realme|nothing tech|google', caseSensitive: false)),
    ('computer', RegExp(r'apple|raspberry|intel|foxconn|mediatek|liteon|azurewave|framework|dell|lenovo|acer|synology|qnap|western digital', caseSensitive: false)),
  ];

  static const _wellKnownServices = <int, String>{
    20: 'FTP-Data',
    21: 'FTP',
    22: 'SSH',
    23: 'Telnet',
    25: 'SMTP',
    53: 'DNS',
    67: 'DHCP',
    68: 'DHCP',
    80: 'HTTP',
    110: 'POP3',
    123: 'NTP',
    143: 'IMAP',
    161: 'SNMP',
    389: 'LDAP',
    443: 'HTTPS',
    445: 'SMB',
    465: 'SMTPS',
    514: 'Syslog',
    548: 'AFP',
    587: 'SMTP',
    631: 'IPP',
    636: 'LDAPS',
    853: 'DoT',
    993: 'IMAPS',
    995: 'POP3S',
    1194: 'OpenVPN',
    1433: 'MSSQL',
    1883: 'MQTT',
    1900: 'SSDP',
    2049: 'NFS',
    3000: 'HTTP-Dev',
    3306: 'MySQL',
    3389: 'RDP',
    5000: 'UPnP',
    5353: 'mDNS',
    5355: 'LLMNR',
    5432: 'PostgreSQL',
    5672: 'AMQP',
    5900: 'VNC',
    6379: 'Redis',
    6443: 'K8s-API',
    8000: 'HTTP-Alt',
    8008: 'Cast',
    8009: 'Cast',
    8080: 'HTTP-Alt',
    8443: 'HTTPS-Alt',
    8883: 'MQTTS',
    9000: 'HTTP-Alt',
    9090: 'Prometheus',
    9200: 'Elasticsearch',
    27017: 'MongoDB',
    51820: 'WireGuard',
  };

  static const _stateMap = <String, String>{
    'ESTAB': 'ESTABLISHED',
    'ESTABLISHED': 'ESTABLISHED',
    'LISTEN': 'LISTEN',
    'TIME-WAIT': 'TIME_WAIT',
    'TIME_WAIT': 'TIME_WAIT',
    'CLOSE-WAIT': 'CLOSE_WAIT',
    'CLOSE_WAIT': 'CLOSE_WAIT',
    'FIN-WAIT-1': 'FIN_WAIT_1',
    'FIN_WAIT_1': 'FIN_WAIT_1',
    'FIN-WAIT-2': 'FIN_WAIT_2',
    'FIN_WAIT_2': 'FIN_WAIT_2',
    'SYN-SENT': 'SYN_SENT',
    'SYN_SENT': 'SYN_SENT',
    'SYN-RECV': 'SYN_RECV',
    'SYN_RECV': 'SYN_RECV',
    'LAST-ACK': 'LAST_ACK',
    'LAST_ACK': 'LAST_ACK',
    'CLOSING': 'CLOSING',
    'CLOSE': 'CLOSE',
    'UNCONN': 'UNCONN',
  };

  static const _procTcpStates = <String, String>{
    '01': 'ESTABLISHED',
    '02': 'SYN_SENT',
    '03': 'SYN_RECV',
    '04': 'FIN_WAIT_1',
    '05': 'FIN_WAIT_2',
    '06': 'TIME_WAIT',
    '07': 'CLOSE',
    '08': 'CLOSE_WAIT',
    '09': 'LAST_ACK',
    '0A': 'LISTEN',
    '0B': 'CLOSING',
  };

  static const _vpnPrefixes = ['nordlynx', 'nordtun', 'tailscale', 'proton', 'pvpn', 'wg', 'mullvad', 'zt', 'tun', 'tap', 'ppp', 'ipsec', 'vti'];
  static const _otherIfacePrefixes = ['docker', 'br-', 'virbr', 'veth', 'cni', 'flannel', 'podman'];
  static const _vpnLinkTypes = {'65534', '512'};

  static final _ssUserRe = RegExp(r'\("([^"]*)",pid=(\d+),fd=\d+\)');
  static final _ssRttRe = RegExp(r'\brtt:(\d+(?:\.\d+)?)/');
  static final _ssBytesSentRe = RegExp(r'\bbytes_sent:(\d+)');
  static final _ssBytesAckedRe = RegExp(r'\bbytes_acked:(\d+)');
  static final _ssBytesRecvRe = RegExp(r'\bbytes_received:(\d+)');
  static final _socketInodeRe = RegExp(r'^socket:\[(\d+)\]$');

  static String cleanText(String text, {int limit = 120}) {
    final kept = <int>[];
    for (final rune in text.runes) {
      if (rune < 32 ||
          rune == 127 ||
          (rune >= 0x80 && rune <= 0x9F) ||
          (rune >= 0x200B && rune <= 0x200F) ||
          (rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          rune == 0xFEFF ||
          rune == 60 ||
          rune == 62 ||
          rune == 38) {
        continue;
      }
      kept.add(rune);
    }
    final trimmed = String.fromCharCodes(kept).trim();
    final runes = trimmed.runes;
    return runes.length > limit ? String.fromCharCodes(runes.take(limit)) : trimmed;
  }

  static String _clean(String text, [int limit = 120]) => cleanText(text, limit: limit);

  static String _readFileText(String path, [int maxBytes = 1048576]) {
    try {
      final f = File(path);
      if (!f.existsSync()) return '';
      final raf = f.openSync();
      try {
        final builder = BytesBuilder(copy: false);
        var remaining = maxBytes;
        while (remaining > 0) {
          final want = remaining > 65536 ? 65536 : remaining;
          final chunk = raf.readSync(want);
          if (chunk.isEmpty) break;
          builder.add(chunk);
          remaining -= chunk.length;
        }
        return utf8.decode(builder.takeBytes(), allowMalformed: true);
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return '';
    }
  }

  static double _round1(double v) => (v * 10).roundToDouble() / 10;
  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  Map<String, String> _loadOuiDb() {
    if (_ouiDb != null) return _ouiDb!;
    final db = <String, String>{};
    final hwdb = File(ctx.paths.sys('/usr/lib/udev/hwdb.d/20-OUI.hwdb'));
    if (hwdb.existsSync()) {
      try {
        String? prefix;
        for (final line in hwdb.readAsLinesSync(encoding: const Utf8Codec(allowMalformed: true))) {
          if (line.startsWith('OUI:')) {
            final m = _ouiLineRe.firstMatch(line);
            prefix = m?.group(1)?.toUpperCase();
          } else if (prefix != null && line.contains('ID_OUI_FROM_DATABASE=')) {
            final idx = line.indexOf('=');
            db[prefix] = _clean(line.substring(idx + 1), 60);
            prefix = null;
          }
        }
      } on FileSystemException {
        // ignore unreadable hwdb
      }
    }
    if (db.isEmpty) {
      final oui = File(ctx.paths.sys('/usr/share/hwdata/oui.txt'));
      if (oui.existsSync()) {
        try {
          for (final line in oui.readAsLinesSync(encoding: const Utf8Codec(allowMalformed: true))) {
            final idx = line.indexOf('(base 16)');
            if (idx > 0) {
              final prefix = line.substring(0, idx).trim().toUpperCase();
              if (prefix.length == 6) {
                db[prefix] = _clean(line.substring(idx + 9), 60);
              }
            }
          }
        } on FileSystemException {
          // ignore
        }
      }
    }
    _ouiDb = db;
    return db;
  }

  static String _shortenVendor(String vendor) {
    if (vendor.isEmpty) return '';
    var cleaned = vendor.replaceAll(_vendorSuffixRe, '').replaceAll(RegExp(r'\s{2,}'), ' ').replaceAll(RegExp(r'[,\s.]+$'), '').trim();
    final alias = _vendorAliases[cleaned];
    if (alias != null) return alias;
    if (cleaned.length > 4 && cleaned == cleaned.toUpperCase() && RegExp(r'[A-Z]').hasMatch(cleaned)) {
      cleaned = cleaned.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}').join(' ');
    }
    return cleaned.isEmpty ? vendor : cleaned;
  }

  String lookupVendor(String mac) {
    final hex = mac.replaceAll(':', '').replaceAll('-', '').toUpperCase();
    if (hex.length < 6) return '';
    final vendor = _loadOuiDb()[hex.substring(0, 6)];
    if (vendor != null && vendor.isNotEmpty) return _shortenVendor(vendor);
    // Locally administered MAC address bit (second hex char is 2, 6, A, or E).
    if (const {'2', '6', 'A', 'E'}.contains(hex[1])) return 'Private MAC';
    return '';
  }

  static String classifyDeviceKind({
    String name = '',
    String vendor = '',
    bool isGateway = false,
    bool isSelf = false,
  }) {
    if (isGateway) return 'router';
    if (isSelf) return 'computer';
    final nameNorm = name.toLowerCase().replaceAll('_', ' ').replaceAll('-', ' ');
    if (nameNorm.trim().isNotEmpty) {
      for (final (kind, re) in _kindNameRules) {
        if (re.hasMatch(nameNorm)) return kind;
      }
    }
    final vendorNorm = vendor.toLowerCase();
    if (vendorNorm.trim().isNotEmpty) {
      for (final (kind, re) in _kindVendorRules) {
        if (re.hasMatch(vendorNorm)) return kind;
      }
    }
    return 'device';
  }

  static (String, int?) freqToBandChannel(double? freqMhz) {
    if (freqMhz == null || freqMhz <= 0) return ('', null);
    final f = freqMhz.round();
    if (f >= 2412 && f <= 2484) {
      return ('2.4 GHz', f == 2484 ? 14 : (f - 2407) ~/ 5);
    }
    if (f >= 5170 && f <= 5895) {
      return ('5 GHz', (f - 5000) ~/ 5);
    }
    if (f >= 5925 && f <= 7125) {
      return ('6 GHz', (f - 5950) ~/ 5);
    }
    return ('$f MHz', null);
  }

  static int dbmToQuality(int signalDbm) => (2 * (signalDbm + 100)).clamp(0, 100);

  static String normalizeState(String state) {
    final raw = state.trim().toUpperCase();
    return _stateMap[raw] ?? _clean(raw.replaceAll('-', '_'), 24);
  }

  static String identifyService(int port, String proto) {
    if (port <= 0) return '';
    if (port == 443 && proto.startsWith('udp')) return 'QUIC';
    return _wellKnownServices[port] ?? '';
  }

  static String classifyScope(String ipStr) {
    var raw = ipStr.trim();
    if (raw.startsWith('[') && raw.endsWith(']')) raw = raw.substring(1, raw.length - 1);
    final pct = raw.indexOf('%');
    if (pct != -1) raw = raw.substring(0, pct);
    if (raw.isEmpty || raw == '*' || raw == '0.0.0.0' || raw == '::') return 'any';
    final addr = InternetAddress.tryParse(raw);
    if (addr == null) return 'any';
    final bytes = addr.rawAddress;
    if (bytes.length == 4) return _classifyIpv4Bytes(bytes, 0);
    if (bytes.length == 16) {
      // Unwrap IPv4-mapped IPv6 (::ffff:a.b.c.d).
      var mapped = true;
      for (var i = 0; i < 10; i++) {
        if (bytes[i] != 0) {
          mapped = false;
          break;
        }
      }
      if (mapped && bytes[10] == 0xff && bytes[11] == 0xff) {
        return _classifyIpv4Bytes(bytes, 12);
      }
      // Unspecified :: -> 'any'; loopback ::1 -> 'loopback'.
      var allZero = true;
      for (var i = 0; i < 15; i++) {
        if (bytes[i] != 0) {
          allZero = false;
          break;
        }
      }
      if (allZero && bytes[15] == 0) return 'any';
      if (allZero && bytes[15] == 1) return 'loopback';
      // ULA fc00::/7, link-local fe80::/10, multicast ff00::/8.
      if ((bytes[0] & 0xfe) == 0xfc) return 'lan';
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return 'lan';
      if (bytes[0] == 0xff) return 'lan';
      return 'external';
    }
    return 'any';
  }

  static String _classifyIpv4Bytes(List<int> b, int o) {
    final b0 = b[o], b1 = b[o + 1], b2 = b[o + 2], b3 = b[o + 3];
    if (b0 == 0 && b1 == 0 && b2 == 0 && b3 == 0) return 'any';
    if (b0 == 127) return 'loopback';
    if (b0 == 10) return 'lan';
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return 'lan';
    if (b0 == 192 && b1 == 168) return 'lan';
    if (b0 == 169 && b1 == 254) return 'lan';
    if (b0 == 100 && b1 >= 64 && b1 <= 127) return 'lan';
    if (b0 >= 224) return 'lan';
    return 'external';
  }

  static ({String ip, int port, bool isV6}) _parseAddrPort(String token) {
    final raw = token.trim();
    if (raw.isEmpty) return (ip: '', port: 0, isV6: false);
    var ipPart = '';
    var portPart = '';
    var isV6 = false;
    if (raw.startsWith('[')) {
      final end = raw.indexOf(']');
      if (end != -1) {
        ipPart = raw.substring(1, end);
        var rest = raw.substring(end + 1);
        if (rest.contains('%') && rest.contains(':')) {
          rest = rest.substring(rest.lastIndexOf(':'));
        }
        if (rest.startsWith(':')) portPart = rest.substring(1);
        isV6 = true;
      } else {
        ipPart = raw;
      }
    } else {
      final idx = raw.lastIndexOf(':');
      if (idx != -1) {
        ipPart = raw.substring(0, idx);
        portPart = raw.substring(idx + 1);
      } else {
        ipPart = raw;
      }
    }
    final pct = ipPart.indexOf('%');
    if (pct != -1) ipPart = ipPart.substring(0, pct);
    String ipClean;
    if (ipPart == '*' || ipPart.isEmpty) {
      ipClean = ipPart;
    } else {
      if (ipPart.contains(':')) isV6 = true;
      final parsed = InternetAddress.tryParse(ipPart);
      if (parsed != null) {
        ipClean = parsed.address;
        isV6 = parsed.type == InternetAddressType.IPv6;
      } else {
        ipClean = _clean(ipPart, 64);
      }
    }
    var port = 0;
    if (portPart.isNotEmpty && portPart != '*') {
      final pVal = int.tryParse(portPart);
      if (pVal != null && pVal >= 0 && pVal <= 65535) port = pVal;
    }
    return (ip: ipClean, port: port, isV6: isV6);
  }

  static Map<String, ({int rxBytes, int rxErrors, int rxDropped, int txBytes, int txErrors, int txDropped})> _parseProcNetDev(String text) {
    final out = <String, ({int rxBytes, int rxErrors, int rxDropped, int txBytes, int txErrors, int txDropped})>{};
    final lines = text.split('\n');
    for (var i = 2; i < lines.length; i++) {
      final line = lines[i];
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final iface = _clean(line.substring(0, colon).trim(), 32);
      if (!isValidIface(iface)) continue;
      final fields = line.substring(colon + 1).trim().split(RegExp(r'\s+'));
      if (fields.length < 12) continue;
      final rxBytes = int.tryParse(fields[0]);
      final rxErrors = int.tryParse(fields[2]);
      final rxDropped = int.tryParse(fields[3]);
      final txBytes = int.tryParse(fields[8]);
      final txErrors = int.tryParse(fields[10]);
      final txDropped = int.tryParse(fields[11]);
      if (rxBytes == null || rxErrors == null || rxDropped == null || txBytes == null || txErrors == null || txDropped == null) continue;
      out[iface] = (
        rxBytes: rxBytes,
        rxErrors: rxErrors,
        rxDropped: rxDropped,
        txBytes: txBytes,
        txErrors: txErrors,
        txDropped: txDropped,
      );
    }
    return out;
  }

  static ({Map<String, String?> routes, String? primary}) _parseDefaultRoutes(String text) {
    final best = <String, ({String? gw, int metric})>{};
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('default')) continue;
      final parts = line.split(RegExp(r'\s+'));
      String? iface;
      String? gw;
      var metric = 0;
      for (var i = 1; i < parts.length; i++) {
        if (parts[i] == 'dev' && i + 1 < parts.length) {
          iface = parts[++i];
        } else if (parts[i] == 'via' && i + 1 < parts.length) {
          gw = parts[++i];
        } else if (parts[i] == 'metric' && i + 1 < parts.length) {
          metric = int.tryParse(parts[++i]) ?? 0;
        }
      }
      if (iface == null || !isValidIface(iface)) continue;
      final prev = best[iface];
      if (prev == null || metric < prev.metric) {
        best[iface] = (gw: gw, metric: metric);
      }
    }
    String? primary;
    int? bestMetric;
    for (final entry in best.entries) {
      if (bestMetric == null || entry.value.metric < bestMetric) {
        bestMetric = entry.value.metric;
        primary = entry.key;
      }
    }
    return (routes: {for (final e in best.entries) e.key: e.value.gw}, primary: primary);
  }

  static List<({String iface, String cidr, String ip})> _parseGlobalIpv4(String text) {
    final out = <({String iface, String cidr, String ip})>[];
    for (final rawLine in text.split('\n')) {
      final parts = rawLine.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      final inetIdx = parts.indexOf('inet');
      if (inetIdx == -1 || inetIdx + 1 >= parts.length) continue;
      final iface = parts[1];
      if (!isValidIface(iface)) continue;
      final cidr = _clean(parts[inetIdx + 1], 32);
      final ip = cidr.split('/').first;
      if (!_ipv4Re.hasMatch(ip)) continue;
      out.add((iface: iface, cidr: cidr, ip: ip));
    }
    return out;
  }

  bool _isWirelessIface(String iface) {
    final base = ctx.paths.sys('/sys/class/net/$iface');
    if (Directory('$base/wireless').existsSync() || Directory('$base/phy80211').existsSync()) return true;
    if (Directory(base).existsSync()) return false;
    return iface.startsWith('wl');
  }

  String _classifyInterfaceKind(String name) {
    if (name == 'lo') return 'loopback';
    final base = ctx.paths.sys('/sys/class/net/$name');
    final linkType = _readFileText('$base/type', 32).trim();
    if (linkType == '772') return 'loopback';
    if (Directory('$base/wireless').existsSync() || Directory('$base/phy80211').existsSync()) return 'wifi';
    if (name.startsWith('wl')) return 'wifi';
    if (_vpnLinkTypes.contains(linkType) || _vpnPrefixes.any(name.startsWith)) return 'vpn';
    if (_otherIfacePrefixes.any(name.startsWith)) return 'other';
    if (name.startsWith('en') || name.startsWith('eth') || (linkType == '1' && Directory('$base/device').existsSync())) return 'ethernet';
    return 'other';
  }

  static int _ipv4Order(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return 0x7fffffff;
    var n = 0;
    for (final part in parts) {
      final v = int.tryParse(part);
      if (v == null || v < 0 || v > 255) return 0x7fffffff;
      n = (n << 8) | v;
    }
    return n;
  }

  static String _deviceDisplayName(String kind, String vendor) {
    return switch (kind) {
      'router' => 'Router ($vendor)',
      'computer' => 'Computer ($vendor)',
      'phone' => 'Phone ($vendor)',
      'tv' => 'TV ($vendor)',
      'smarthome' => 'Smart home ($vendor)',
      'printer' => 'Printer ($vendor)',
      _ => vendor,
    };
  }

  /// `network.devices` {rescan?}: active interface link info, traffic counters & LAN neighbors.
  Future<Map<String, dynamic>> devices([Map<String, dynamic> params = const {}]) async {
    if (params['rescan'] == true) _ouiDb = null;
    final emptyTraffic = {'rxBytes': 0, 'txBytes': 0, 'rxRate': 0.0, 'txRate': 0.0};
    if (ctx.runner.which('ip') == null) {
      return {'active': false, 'link': null, 'traffic': emptyTraffic, 'devices': <Map<String, dynamic>>[], 'onlineCount': 0, 'totalCount': 0};
    }

    final routeRes = await ctx.runner.run(['ip', '-4', 'route', 'show', 'default'], timeout: const Duration(seconds: 5));
    final addrRes = await ctx.runner.run(['ip', '-4', '-o', 'addr', 'show', 'scope', 'global'], timeout: const Duration(seconds: 5));
    final (:routes, :primary) = _parseDefaultRoutes(routeRes.ok ? routeRes.stdout : '');
    final addrs = _parseGlobalIpv4(addrRes.ok ? addrRes.stdout : '');

    if (addrs.isEmpty) {
      return {'active': false, 'link': null, 'traffic': emptyTraffic, 'devices': <Map<String, dynamic>>[], 'onlineCount': 0, 'totalCount': 0};
    }

    final scored = [
      for (final a in addrs)
        (
          score: (a.iface == primary ? 4 : 0) + (routes.containsKey(a.iface) ? 2 : 0) + (_isWirelessIface(a.iface) ? 1 : 0),
          a: a,
          isWireless: _isWirelessIface(a.iface),
        ),
    ]..sort((x, y) => y.score.compareTo(x.score));

    final chosen = scored.first;
    final iface = chosen.a.iface;
    final ip = chosen.a.ip;
    final cidr = chosen.a.cidr;
    final isWireless = chosen.isWireless;
    final gateway = routes[iface];

    var selfMac = _clean(_readFileText(ctx.paths.sys('/sys/class/net/$iface/address'), 64).trim().toLowerCase(), 20);
    if (selfMac == '00:00:00:00:00:00') selfMac = '';

    // Wireless details via `iw dev <iface> link`.
    var ssid = '';
    var bssid = '';
    int? signalDbm;
    int? quality;
    var band = '';
    int? channel;
    int? widthMhz;
    int? txMbps;
    int? rxMbps;
    if (isWireless && ctx.runner.which('iw') != null) {
      final iwRes = await ctx.runner.run(['iw', 'dev', iface, 'link'], timeout: const Duration(seconds: 5));
      if (iwRes.ok && iwRes.stdout.isNotEmpty && !iwRes.stdout.contains('Not connected')) {
        final out = iwRes.stdout;
        final mBssid = RegExp(r'Connected to ([0-9a-fA-F:]{17})').firstMatch(out);
        if (mBssid != null) bssid = mBssid.group(1)!.toLowerCase();
        final mSsid = RegExp(r'^\s*SSID:\s*(.+)$', multiLine: true).firstMatch(out);
        if (mSsid != null) ssid = _clean(mSsid.group(1)!, 64);
        final mFreq = RegExp(r'^\s*freq:\s*([0-9.]+)', multiLine: true).firstMatch(out);
        if (mFreq != null) {
          final (b, ch) = freqToBandChannel(double.tryParse(mFreq.group(1)!));
          band = b;
          channel = ch;
        }
        final mSig = RegExp(r'^\s*signal:\s*(-?\d+)\s*dBm', multiLine: true).firstMatch(out);
        if (mSig != null) {
          signalDbm = int.tryParse(mSig.group(1)!);
          if (signalDbm != null) quality = dbmToQuality(signalDbm);
        }
        final mRx = RegExp(r'^\s*rx bitrate:\s*([0-9.]+)\s*MBit/s(?:\s+(\d+)MHz)?', multiLine: true).firstMatch(out);
        if (mRx != null) {
          final v = double.tryParse(mRx.group(1)!);
          if (v != null) rxMbps = v.round();
          if (mRx.group(2) != null) widthMhz = int.tryParse(mRx.group(2)!);
        }
        final mTx = RegExp(r'^\s*tx bitrate:\s*([0-9.]+)\s*MBit/s(?:\s+(\d+)MHz)?', multiLine: true).firstMatch(out);
        if (mTx != null) {
          final v = double.tryParse(mTx.group(1)!);
          if (v != null) txMbps = v.round();
          if (widthMhz == null && mTx.group(2) != null) widthMhz = int.tryParse(mTx.group(2)!);
        }
      }
    }

    // Traffic counters from /proc/net/dev + rate deltas across calls.
    final now = ctx.clock();
    final devStats = _parseProcNetDev(_readFileText(p.join(ctx.paths.proc, 'net/dev'), 131072));
    final st = devStats[iface];
    final rxBytes = st?.rxBytes ?? 0;
    final txBytes = st?.txBytes ?? 0;
    var rxRate = 0.0;
    var txRate = 0.0;
    final prevTraffic = _prevDevTraffic[iface];
    if (prevTraffic != null && now.isAfter(prevTraffic.at)) {
      final dt = now.difference(prevTraffic.at).inMicroseconds / 1e6;
      if (dt > 0) {
        rxRate = _round1(((rxBytes - prevTraffic.rx) / dt).clamp(0.0, double.infinity));
        txRate = _round1(((txBytes - prevTraffic.tx) / dt).clamp(0.0, double.infinity));
      }
    }
    _prevDevTraffic[iface] = (rx: rxBytes, tx: txBytes, at: now);

    // Neighbors from `ip -4 neigh show dev <iface>`.
    final neighRes = await ctx.runner.run(['ip', '-4', 'neigh', 'show', 'dev', iface], timeout: const Duration(seconds: 5));
    final byIp = <String, ({String mac, String state})>{};
    if (neighRes.ok) {
      for (final rawLine in neighRes.stdout.split('\n')) {
        final parts = rawLine.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final nIp = parts[0];
        if (!_ipv4Re.hasMatch(nIp)) continue;
        var nMac = '';
        final llIdx = parts.indexOf('lladdr');
        if (llIdx != -1 && llIdx + 1 < parts.length) {
          final cand = parts[llIdx + 1].toLowerCase();
          if (_macRe.hasMatch(cand)) nMac = cand;
        }
        final state = RegExp(r'^[A-Z]+$').hasMatch(parts.last) ? parts.last : '';
        if (_skipNeighStates.contains(state)) continue;
        if (nMac.isEmpty && nIp != gateway) continue;
        byIp[nIp] = (mac: nMac, state: state);
      }
    }

    final hostName = _clean(Platform.localHostname, 48);
    final deviceList = <Map<String, dynamic>>[];
    final seenIps = <String>{};

    void addDevice({
      required String devIp,
      required String mac,
      required String state,
      required bool isSelf,
      required bool isGateway,
    }) {
      if (!seenIps.add(devIp)) return;
      final vendor = lookupVendor(mac);
      final online = isSelf || isGateway || _activeNeighStates.contains(state);
      final kind = classifyDeviceKind(name: isSelf ? hostName : '', vendor: vendor, isGateway: isGateway, isSelf: isSelf);
      final String name;
      if (isSelf) {
        name = hostName.isNotEmpty ? hostName : tr('This PC');
      } else if (isGateway) {
        name = tr('Router');
      } else if (vendor.isNotEmpty && vendor != 'Private MAC') {
        name = _deviceDisplayName(kind, vendor);
      } else {
        name = devIp;
      }
      deviceList.add({
        'ip': devIp,
        'mac': mac,
        'name': name,
        'vendor': vendor,
        'state': state,
        'kind': kind,
        'online': online,
        'isSelf': isSelf,
        'isGateway': isGateway,
        'webUrl': isGateway ? 'http://$devIp' : null,
      });
    }

    if (gateway != null && _ipv4Re.hasMatch(gateway)) {
      final gwNeigh = byIp[gateway];
      addDevice(
        devIp: gateway,
        mac: gwNeigh?.mac ?? '',
        state: gwNeigh?.state.isNotEmpty == true ? gwNeigh!.state : 'REACHABLE',
        isSelf: gateway == ip,
        isGateway: true,
      );
    }

    addDevice(devIp: ip, mac: selfMac, state: 'SELF', isSelf: true, isGateway: ip == gateway);

    for (final entry in byIp.entries) {
      if (seenIps.contains(entry.key)) continue;
      addDevice(devIp: entry.key, mac: entry.value.mac, state: entry.value.state, isSelf: false, isGateway: false);
    }

    deviceList.sort((a, b) {
      int rank(Map<String, dynamic> d) => d['isGateway'] == true ? 0 : d['isSelf'] == true ? 1 : d['online'] == true ? 2 : 3;
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return _ipv4Order(a['ip'] as String).compareTo(_ipv4Order(b['ip'] as String));
    });

    final onlineCount = deviceList.where((d) => d['online'] == true).length;
    return {
      'active': true,
      'link': {
        'iface': iface,
        'isWireless': isWireless,
        'ip': ip,
        'cidr': cidr,
        'gateway': gateway,
        'mac': selfMac,
        'ssid': ssid,
        'bssid': bssid,
        'signalDbm': signalDbm,
        'quality': quality,
        'band': band,
        'channel': channel,
        'widthMhz': widthMhz,
        'txMbps': txMbps,
        'rxMbps': rxMbps,
      },
      'traffic': {
        'rxBytes': rxBytes,
        'txBytes': txBytes,
        'rxRate': rxRate,
        'txRate': txRate,
      },
      'devices': deviceList,
      'onlineCount': onlineCount,
      'totalCount': deviceList.length,
    };
  }

  String _readCmdline(int pid) {
    if (pid <= 0) return '';
    final raw = _readFileText(p.join(ctx.paths.proc, '$pid', 'cmdline'), 4096);
    if (raw.isEmpty) return '';
    final text = raw.replaceAll('\u0000', ' ').replaceAll(RegExp(r'\s+'), ' ');
    return _clean(text, 160);
  }

  static String _uniqueConnId(
    Map<String, int> seenIds,
    String proto,
    String localIp,
    int localPort,
    String remoteIp,
    int remotePort,
    int? pid,
  ) {
    final base = '$proto:$localIp:$localPort->$remoteIp:$remotePort${pid != null ? '#$pid' : ''}';
    final count = (seenIds[base] ?? 0) + 1;
    seenIds[base] = count;
    return count == 1 ? base : '$base#$count';
  }

  List<Map<String, dynamic>> _parseSsOutput(String text) {
    final connections = <Map<String, dynamic>>[];
    final cmdlineCache = <int, String>{};
    final seenIds = <String, int>{};
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty || line.startsWith('Netid')) continue;
      if (line.startsWith(' ') || line.startsWith('\t')) {
        if (connections.isEmpty) continue;
        final conn = connections.last;
        final mRtt = _ssRttRe.firstMatch(line);
        if (mRtt != null) {
          final v = double.tryParse(mRtt.group(1)!);
          if (v != null) conn['rttMs'] = _round2(v);
        }
        final sent = int.tryParse(_ssBytesSentRe.firstMatch(line)?.group(1) ?? '') ?? 0;
        final acked = int.tryParse(_ssBytesAckedRe.firstMatch(line)?.group(1) ?? '') ?? 0;
        if (sent > 0 || acked > 0) conn['txBytes'] = sent > acked ? sent : acked;
        final recv = int.tryParse(_ssBytesRecvRe.firstMatch(line)?.group(1) ?? '');
        if (recv != null) conn['rxBytes'] = recv;
        continue;
      }
      final parts = _splitMax(line.trim(), 7);
      if (parts.length < 6) continue;
      final netid = parts[0].toLowerCase();
      if (netid != 'tcp' && netid != 'udp') continue;
      final state = normalizeState(parts[1]);
      final local = _parseAddrPort(parts[4]);
      final remote = _parseAddrPort(parts[5]);
      final isV6 = local.isV6 || remote.isV6;
      final proto = netid == 'tcp' ? (isV6 ? 'tcp6' : 'tcp') : (isV6 ? 'udp6' : 'udp');

      var process = '';
      int? pid;
      var cmdline = '';
      if (parts.length >= 7) {
        final mUser = _ssUserRe.firstMatch(parts[6]);
        if (mUser != null) {
          process = _clean(mUser.group(1)!, 64);
          pid = int.tryParse(mUser.group(2)!);
          if (pid != null) {
            cmdline = cmdlineCache.putIfAbsent(pid, () => _readCmdline(pid!));
          }
        }
      }

      final isListening = (state == 'LISTEN' || state == 'UNCONN') &&
          (remote.port == 0 || remote.ip.isEmpty || remote.ip == '*' || remote.ip == '0.0.0.0' || remote.ip == '::');
      final servicePort = isListening ? local.port : (remote.port > 0 ? remote.port : local.port);
      final scopeIp = (isListening && local.ip.isNotEmpty && local.ip != '*' && local.ip != '0.0.0.0' && local.ip != '::') ? local.ip : remote.ip;

      connections.add({
        'id': _uniqueConnId(seenIds, proto, local.ip, local.port, remote.ip, remote.port, pid),
        'proto': proto,
        'state': state,
        'localIp': local.ip,
        'localPort': local.port,
        'remoteIp': remote.ip,
        'remotePort': remote.port,
        'scope': classifyScope(scopeIp),
        'service': identifyService(servicePort, proto),
        'process': process,
        'pid': pid,
        'cmdline': cmdline,
        'rxBytes': 0,
        'txBytes': 0,
        'rxRate': 0.0,
        'txRate': 0.0,
        'rttMs': null,
      });
    }
    return connections;
  }

  static List<String> _splitMax(String line, int maxParts) {
    final out = <String>[];
    var i = 0;
    final len = line.length;
    while (i < len && out.length < maxParts - 1) {
      while (i < len && (line[i] == ' ' || line[i] == '\t')) {
        i++;
      }
      if (i >= len) break;
      final start = i;
      while (i < len && line[i] != ' ' && line[i] != '\t') {
        i++;
      }
      out.add(line.substring(start, i));
    }
    while (i < len && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    if (i < len) out.add(line.substring(i));
    return out;
  }

  static String _decodeProcIp(String hex, bool isV6) {
    try {
      if (!isV6) {
        if (hex.length != 8) return '';
        final b0 = int.parse(hex.substring(6, 8), radix: 16);
        final b1 = int.parse(hex.substring(4, 6), radix: 16);
        final b2 = int.parse(hex.substring(2, 4), radix: 16);
        final b3 = int.parse(hex.substring(0, 2), radix: 16);
        return '$b0.$b1.$b2.$b3';
      }
      if (hex.length != 32) return '';
      final bytes = Uint8List(16);
      for (var w = 0; w < 4; w++) {
        final off = w * 8;
        final dst = w * 4;
        bytes[dst] = int.parse(hex.substring(off + 6, off + 8), radix: 16);
        bytes[dst + 1] = int.parse(hex.substring(off + 4, off + 6), radix: 16);
        bytes[dst + 2] = int.parse(hex.substring(off + 2, off + 4), radix: 16);
        bytes[dst + 3] = int.parse(hex.substring(off, off + 2), radix: 16);
      }
      return InternetAddress.fromRawAddress(bytes).address;
    } on Object {
      return '';
    }
  }

  Map<String, ({String comm, int pid})> _buildInodePidMap() {
    final map = <String, ({String comm, int pid})>{};
    final procDir = Directory(ctx.paths.proc);
    if (!procDir.existsSync()) return map;
    List<FileSystemEntity> entries;
    try {
      entries = procDir.listSync(followLinks: false);
    } on FileSystemException {
      return map;
    }
    for (final entry in entries) {
      final base = p.basename(entry.path);
      final pidVal = int.tryParse(base);
      if (pidVal == null) continue;
      final fdDir = Directory(p.join(entry.path, 'fd'));
      List<FileSystemEntity> fds;
      try {
        fds = fdDir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      String? comm;
      for (final fd in fds) {
        String target;
        try {
          target = Link(fd.path).targetSync();
        } on FileSystemException {
          continue;
        }
        final m = _socketInodeRe.firstMatch(target);
        if (m == null) continue;
        comm ??= _clean(_readFileText(p.join(entry.path, 'comm'), 128), 64);
        map[m.group(1)!] = (comm: comm, pid: pidVal);
      }
    }
    return map;
  }

  List<Map<String, dynamic>> _collectProcConnections() {
    final inodeMap = _buildInodePidMap();
    final cmdlineCache = <int, String>{};
    final seenIds = <String, int>{};
    final out = <Map<String, dynamic>>[];
    for (final proto in const ['tcp', 'tcp6', 'udp', 'udp6']) {
      final text = _readFileText(p.join(ctx.paths.proc, 'net', proto), 1048576);
      if (text.isEmpty) continue;
      final isV6 = proto.endsWith('6');
      final isUdp = proto.startsWith('udp');
      final lines = text.split('\n');
      for (var i = 1; i < lines.length; i++) {
        final fields = lines[i].trim().split(RegExp(r'\s+'));
        if (fields.length < 10) continue;
        final localParts = fields[1].split(':');
        final remoteParts = fields[2].split(':');
        if (localParts.length != 2 || remoteParts.length != 2) continue;
        final localIp = _decodeProcIp(localParts[0], isV6);
        final remoteIp = _decodeProcIp(remoteParts[0], isV6);
        final localPort = int.tryParse(localParts[1], radix: 16);
        final remotePort = int.tryParse(remoteParts[1], radix: 16);
        if (localPort == null || remotePort == null) continue;
        final stateHex = fields[3].toUpperCase();
        final state = isUdp ? (stateHex == '01' ? 'ESTABLISHED' : 'UNCONN') : (_procTcpStates[stateHex] ?? 'CLOSE');
        final inode = fields[9];
        final owner = inodeMap[inode];
        final process = owner?.comm ?? '';
        final pidVal = owner?.pid;
        final cmdline = pidVal != null ? cmdlineCache.putIfAbsent(pidVal, () => _readCmdline(pidVal)) : '';

        final isListening = (state == 'LISTEN' || state == 'UNCONN') &&
            (remotePort == 0 || remoteIp.isEmpty || remoteIp == '0.0.0.0' || remoteIp == '::');
        final servicePort = isListening ? localPort : (remotePort > 0 ? remotePort : localPort);
        final scopeIp = (isListening && localIp.isNotEmpty && localIp != '0.0.0.0' && localIp != '::') ? localIp : remoteIp;

        out.add({
          'id': _uniqueConnId(seenIds, proto, localIp, localPort, remoteIp, remotePort, pidVal),
          'proto': proto,
          'state': state,
          'localIp': localIp,
          'localPort': localPort,
          'remoteIp': remoteIp,
          'remotePort': remotePort,
          'scope': classifyScope(scopeIp),
          'service': identifyService(servicePort, proto),
          'process': process,
          'pid': pidVal,
          'cmdline': cmdline,
          'rxBytes': 0,
          'txBytes': 0,
          'rxRate': 0.0,
          'txRate': 0.0,
          'rttMs': null,
        });
      }
    }
    return out;
  }

  static Map<String, ({String ip, String ipv6})> _parseAllIpAddrs(String text) {
    final map = <String, ({String ip, String ipv6})>{};
    for (final rawLine in text.split('\n')) {
      final parts = rawLine.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      final iface = _clean(parts[1], 32);
      if (!isValidIface(iface)) continue;
      final family = parts[2];
      if (family != 'inet' && family != 'inet6') continue;
      final ipStr = _clean(parts[3].split('/').first, 64);
      final cur = map[iface] ?? (ip: '', ipv6: '');
      if (family == 'inet') {
        if (cur.ip.isEmpty) map[iface] = (ip: ipStr, ipv6: cur.ipv6);
      } else {
        final isLl = ipStr.toLowerCase().startsWith('fe80:');
        if (cur.ipv6.isEmpty || (cur.ipv6.toLowerCase().startsWith('fe80:') && !isLl)) {
          map[iface] = (ip: cur.ip, ipv6: ipStr);
        }
      }
    }
    return map;
  }

  List<String> _readDnsServers() {
    final servers = <String>[];
    final text = _readFileText(ctx.paths.sys('/etc/resolv.conf'), 32768);
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[0] == 'nameserver') {
        final cand = parts[1].split('%').first;
        final parsed = InternetAddress.tryParse(cand);
        if (parsed != null && !servers.contains(parsed.address)) {
          servers.add(parsed.address);
        }
      }
    }
    return servers;
  }

  /// `network.monitor` {}: live TCP/UDP connections, per-process aggregation, interfaces & DNS.
  Future<Map<String, dynamic>> monitor([Map<String, dynamic> params = const {}]) async {
    final now = ctx.clock();

    // 1. Collect raw connections via `ss -tunapi`, falling back to `/proc/net/*`.
    List<Map<String, dynamic>> connections;
    if (ctx.runner.which('ss') != null) {
      final ssRes = await ctx.runner.run(['ss', '-tunapi'], timeout: const Duration(seconds: 5));
      if (ssRes.ok && (ssRes.stdout.contains('Netid') || ssRes.stdout.contains('tcp') || ssRes.stdout.contains('udp'))) {
        connections = _parseSsOutput(ssRes.stdout);
      } else {
        connections = _collectProcConnections();
      }
    } else {
      connections = _collectProcConnections();
    }

    // Compute per-socket rate deltas across calls.
    final sockDt = (_prevSockTime != null && now.isAfter(_prevSockTime!)) ? now.difference(_prevSockTime!).inMicroseconds / 1e6 : null;
    final newSockBytes = <String, ({int rx, int tx})>{};
    for (final c in connections) {
      final key = c['id'] as String;
      final rx = c['rxBytes'] as int;
      final tx = c['txBytes'] as int;
      final prev = _prevSockBytes[key];
      if (sockDt != null && sockDt > 0 && prev != null) {
        c['rxRate'] = _round1(((rx - prev.rx) / sockDt).clamp(0.0, double.infinity));
        c['txRate'] = _round1(((tx - prev.tx) / sockDt).clamp(0.0, double.infinity));
      }
      newSockBytes[key] = (rx: rx, tx: tx);
    }
    _prevSockBytes
      ..clear()
      ..addAll(newSockBytes);
    _prevSockTime = now;

    // Default sort: active rate desc, total bytes desc, ESTABLISHED first, process name asc.
    connections.sort((a, b) {
      final rCmp = ((b['rxRate'] as double) + (b['txRate'] as double)).compareTo((a['rxRate'] as double) + (a['txRate'] as double));
      if (rCmp != 0) return rCmp;
      final bCmp = ((b['rxBytes'] as int) + (b['txBytes'] as int)).compareTo((a['rxBytes'] as int) + (a['txBytes'] as int));
      if (bCmp != 0) return bCmp;
      final sCmp = (a['state'] == 'ESTABLISHED' ? 0 : 1).compareTo(b['state'] == 'ESTABLISHED' ? 0 : 1);
      if (sCmp != 0) return sCmp;
      final pa = (a['process'] as String).isEmpty ? 'zzz' : (a['process'] as String).toLowerCase();
      final pb = (b['process'] as String).isEmpty ? 'zzz' : (b['process'] as String).toLowerCase();
      return pa.compareTo(pb);
    });

    // 2. Per-process aggregation.
    final procMap = <String, Map<String, dynamic>>{};
    for (final c in connections) {
      final rawName = c['process'] as String;
      final pname = rawName.isEmpty ? 'system' : rawName;
      final rec = procMap.putIfAbsent(pname, () => {
        'name': pname,
        'pids': <int>[],
        'connections': 0,
        'external': 0,
        'lan': 0,
        'listening': 0,
        'rxBytes': 0,
        'txBytes': 0,
        'rxRate': 0.0,
        'txRate': 0.0,
      });
      final cPid = c['pid'] as int?;
      final pids = rec['pids'] as List<int>;
      if (cPid != null && !pids.contains(cPid)) pids.add(cPid);
      rec['connections'] = (rec['connections'] as int) + 1;
      if (c['scope'] == 'external') rec['external'] = (rec['external'] as int) + 1;
      if (c['scope'] == 'lan') rec['lan'] = (rec['lan'] as int) + 1;
      if (isListeningConn(c)) rec['listening'] = (rec['listening'] as int) + 1;
      rec['rxBytes'] = (rec['rxBytes'] as int) + (c['rxBytes'] as int);
      rec['txBytes'] = (rec['txBytes'] as int) + (c['txBytes'] as int);
      rec['rxRate'] = _round1((rec['rxRate'] as double) + (c['rxRate'] as double));
      rec['txRate'] = _round1((rec['txRate'] as double) + (c['txRate'] as double));
    }
    final processes = procMap.values.toList()
      ..sort((a, b) {
        final rCmp = ((b['rxRate'] as double) + (b['txRate'] as double)).compareTo((a['rxRate'] as double) + (a['txRate'] as double));
        if (rCmp != 0) return rCmp;
        final cCmp = (b['connections'] as int).compareTo(a['connections'] as int);
        if (cCmp != 0) return cCmp;
        return (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
      });
    for (final proc in processes) {
      (proc['pids'] as List<int>).sort();
    }

    // 3. Interfaces from `ip -o addr show` + `/proc/net/dev`.
    final devStats = _parseProcNetDev(_readFileText(p.join(ctx.paths.proc, 'net/dev'), 131072));
    var addrMap = <String, ({String ip, String ipv6})>{};
    if (ctx.runner.which('ip') != null) {
      final ipRes = await ctx.runner.run(['ip', '-o', 'addr', 'show'], timeout: const Duration(seconds: 5));
      if (ipRes.ok) addrMap = _parseAllIpAddrs(ipRes.stdout);
    }
    final ifaceNames = <String>{...devStats.keys, ...addrMap.keys}.toList()..sort();
    final ifaceDt = (_prevIfaceTime != null && now.isAfter(_prevIfaceTime!)) ? now.difference(_prevIfaceTime!).inMicroseconds / 1e6 : null;
    final newIfaceBytes = <String, ({int rx, int tx})>{};
    final interfaces = <Map<String, dynamic>>[];

    for (final name in ifaceNames) {
      final st = devStats[name];
      final addr = addrMap[name] ?? (ip: '', ipv6: '');
      final kind = _classifyInterfaceKind(name);
      final base = ctx.paths.sys('/sys/class/net/$name');
      final oper = _readFileText('$base/operstate', 32).trim().toLowerCase();
      final flagsStr = _readFileText('$base/flags', 32).trim();
      final flags = int.tryParse(flagsStr.startsWith('0x') ? flagsStr.substring(2) : flagsStr, radix: 16) ?? 0;
      var mac = _clean(_readFileText('$base/address', 32).trim().toLowerCase(), 20);
      if (mac == '00:00:00:00:00:00') mac = '';
      final hasAddr = addr.ip.isNotEmpty || addr.ipv6.isNotEmpty;
      final isUp = oper == 'up' ||
          (oper == 'unknown' && (flags & 0x1) != 0 && (name == 'lo' || kind == 'vpn' || hasAddr)) ||
          (oper.isEmpty && (name == 'lo' || hasAddr || (flags & 0x1) != 0));

      final rxBytes = st?.rxBytes ?? 0;
      final txBytes = st?.txBytes ?? 0;
      var rxRate = 0.0;
      var txRate = 0.0;
      final prev = _prevIfaceBytes[name];
      if (ifaceDt != null && ifaceDt > 0 && prev != null) {
        rxRate = _round1(((rxBytes - prev.rx) / ifaceDt).clamp(0.0, double.infinity));
        txRate = _round1(((txBytes - prev.tx) / ifaceDt).clamp(0.0, double.infinity));
      }
      newIfaceBytes[name] = (rx: rxBytes, tx: txBytes);

      interfaces.add({
        'name': name,
        'kind': kind,
        'state': isUp ? 'up' : 'down',
        'ip': addr.ip,
        'ipv6': addr.ipv6,
        'mac': mac,
        'rxBytes': rxBytes,
        'txBytes': txBytes,
        'rxRate': rxRate,
        'txRate': txRate,
        'rxErrors': st?.rxErrors ?? 0,
        'txErrors': st?.txErrors ?? 0,
        'rxDropped': st?.rxDropped ?? 0,
        'txDropped': st?.txDropped ?? 0,
      });
    }
    _prevIfaceBytes
      ..clear()
      ..addAll(newIfaceBytes);
    _prevIfaceTime = now;

    const kindRank = {'wifi': 0, 'ethernet': 1, 'vpn': 2, 'other': 3, 'loopback': 4};
    interfaces.sort((a, b) {
      final sCmp = (a['state'] == 'up' ? 0 : 1).compareTo(b['state'] == 'up' ? 0 : 1);
      if (sCmp != 0) return sCmp;
      final kCmp = (kindRank[a['kind']] ?? 5).compareTo(kindRank[b['kind']] ?? 5);
      if (kCmp != 0) return kCmp;
      return (a['name'] as String).compareTo(b['name'] as String);
    });

    // 4. DNS & Summary.
    final dns = _readDnsServers();
    final nonLo = interfaces.where((i) => i['kind'] != 'loopback');
    final totalRxRate = _round1(nonLo.fold<double>(0.0, (s, i) => s + (i['rxRate'] as double)));
    final totalTxRate = _round1(nonLo.fold<double>(0.0, (s, i) => s + (i['txRate'] as double)));
    final totalRxBytes = nonLo.fold<int>(0, (s, i) => s + (i['rxBytes'] as int));
    final totalTxBytes = nonLo.fold<int>(0, (s, i) => s + (i['txBytes'] as int));

    final summary = {
      'total': connections.length,
      'established': connections.where(isActiveConn).length,
      'listening': connections.where(isListeningConn).length,
      'tcp': connections.where((c) => (c['proto'] as String).startsWith('tcp')).length,
      'udp': connections.where((c) => (c['proto'] as String).startsWith('udp')).length,
      'external': connections.where((c) => c['scope'] == 'external').length,
      'lan': connections.where((c) => c['scope'] == 'lan').length,
      'loopback': connections.where((c) => c['scope'] == 'loopback').length,
      'any': connections.where((c) => c['scope'] == 'any').length,
      'processes': processes.length,
      'rxRate': totalRxRate,
      'txRate': totalTxRate,
      'rxBytes': totalRxBytes,
      'txBytes': totalTxBytes,
    };

    return {
      'summary': summary,
      'connections': connections,
      'processes': processes,
      'interfaces': interfaces,
      'dns': dns,
    };
  }
}
