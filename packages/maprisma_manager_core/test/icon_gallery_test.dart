import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const _sampleLucide = {
  'prefix': 'lucide',
  'width': 24,
  'height': 24,
  'icons': {
    'wifi': {'body': '<path fill="none" stroke="currentColor" d="M5 13a10 10 0 0 1 14 0"/>'},
    'wifi-off': {'body': '<path fill="none" stroke="currentColor" d="M2 2l20 20"/>'},
    'cloud-wifi': {'body': '<path fill="none" stroke="currentColor" d="M4 16h16"/>'},
    'mywifiicon': {'body': '<path fill="none" stroke="currentColor" d="M1 1h22"/>'},
    'bell': {'body': '<path fill="none" stroke="currentColor" d="M6 8a6 6 0 0 1 12 0"/>', 'width': 24.0, 'height': 24.0},
    'alpha': {'body': '<circle cx="12" cy="12" r="8"/>'},
    'zebra': {'body': '<rect x="2" y="2" width="20" height="20"/>', 'left': 1, 'top': 2, 'width': 20, 'height': 20},
    'volume-mute': {'body': '<path d="M11 5L6 9H2v6h4l5 4z"/>'},
    'audio-volume-mute': {'body': '<path d="M11 5L6 9H2v6h4l5 4z"/>'},
    'bad_name!': {'body': '<path d="M0 0h1"/>'},
  },
  'aliases': {
    'wireless': {'parent': 'wifi'},
    'wlan-signal': {'parent': 'wifi'},
    'chained-alias': {'parent': 'wireless'},
    'broken-alias': {'parent': 'does-not-exist'},
  },
};

const _sampleTabler = {
  'prefix': 'tabler',
  'width': 24,
  'height': 24,
  'icons': {
    'sun': {'body': '<circle cx="12" cy="12" r="4"/>'},
    'moon': {'body': '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>'},
  },
};

void main() {
  late World w;

  setUp(() {
    w = World.create();
    w.fake('gtk-update-icon-cache', 'exit 0');
  });

  tearDown(() => w.dispose());

  CoreService makeCore({
    String desktop = 'COSMIC',
    DateTime Function()? clock,
    GalleryFetcher? fetcher,
  }) {
    final c = w.core(desktop: desktop, clock: clock)
      ..followPanel = (_) async => {'panel': null, 'note': 'test'};
    c.icons.iconGallery.fetch = fetcher;
    return c;
  }

  group('parseGalleryId & buildGallerySvg', () {
    test('strictly validates allowlisted pack and slug regex', () {
      expect(parseGalleryId('gallery:lucide:wifi'), (pack: 'lucide', name: 'wifi'));
      expect(parseGalleryId('gallery:tabler:music-2'), (pack: 'tabler', name: 'music-2'));
      expect(parseGalleryId('gallery:mdi:home'), (pack: 'mdi', name: 'home'));
      expect(parseGalleryId('gallery:bi:0-circle'), (pack: 'bi', name: '0-circle'));
      expect(parseGalleryId('gallery:unknown:wifi'), isNull);
      expect(parseGalleryId('gallery:lucide:'), isNull);
      expect(parseGalleryId('gallery:lucide:WiFi'), isNull);
      expect(parseGalleryId('gallery:lucide:../etc/passwd'), isNull);
      expect(parseGalleryId('gallery:lucide:wifi:extra'), isNull);
      expect(parseGalleryId('lucide:wifi'), isNull);
      expect(parseGalleryId('gallery:lucide:${'a' * 122}'), isNull);
      expect(parseGalleryId('gallery:lucide:${'a' * 121}'), isNotNull);
    });

    test('renders symbolic SVG with integer viewBox and rejects unsafe bodies via svgProblem', () {
      final ok = buildGallerySvg(body: '<path d="M1 1h10"/>', left: 0.0, top: 0.0, width: 24.0, height: 24.0);
      expect(ok, isNotNull);
      expect(ok, contains('viewBox="0 0 24 24"'));
      expect(ok, contains('.ColorScheme-Text { color:#232629; }'));
      expect(ok, contains('<g class="ColorScheme-Text" color="#232629"><path d="M1 1h10"/></g>'));
      expect(svgProblem(utf8.encode(ok!)), isNull);

      expect(buildGallerySvg(body: '<script>alert(1)</script>'), isNull);
      expect(buildGallerySvg(body: '<path onload="evil()" d="M0 0"/>'), isNull);
      expect(buildGallerySvg(body: '<image href="https://evil.example/x.png"/>'), isNull);
      expect(buildGallerySvg(body: '<foreignObject/>'), isNull);
    });
  });

  group('icons.gallery', () {
    test('curated empty query order, search ranking, aliases, deduplication, and pagination', () async {
      final fetched = <String>[];
      final c = makeCore(
        fetcher: (url) async {
          fetched.add(url);
          if (url.contains('/lucide/')) return jsonEncode(_sampleLucide);
          if (url.contains('/tabler/')) return jsonEncode(_sampleTabler);
          return null;
        },
      );

      // Initial empty query: curated icons first (wifi, bell), then curated-segment variants, then alphabetical.
      final initial = await c.call('icons.gallery');
      expect(initial['pack'], 'lucide');
      expect((initial['packs'] as List).map((pk) => pk['id']), ['lucide', 'tabler', 'mdi', 'bi']);
      expect(initial['cached'], isFalse);
      expect(initial['offline'], isFalse);
      expect(initial.containsKey('error'), isFalse);
      expect(initial['truncated'], isFalse);
      final names = [for (final ch in initial['choices'] as List) ch['name']];
      expect(names, isNot(contains('bad_name!')));
      expect(names.sublist(0, 2), ['wifi', 'bell']);
      expect(names.indexOf('wifi-off'), lessThan(names.indexOf('alpha')));
      expect(names.indexOf('alpha'), lessThan(names.indexOf('zebra')));
      expect((initial['choices'] as List).first['id'], 'gallery:lucide:wifi');
      expect((initial['choices'] as List).first['pack'], 'lucide');
      expect((initial['choices'] as List).first['svg'], contains('viewBox="0 0 24 24"'));
      final zebra = (initial['choices'] as List).firstWhere((ch) => ch['name'] == 'zebra');
      expect(zebra['svg'], contains('viewBox="1 2 20 20"'));
      expect(fetched, ['https://cdn.jsdelivr.net/npm/@iconify-json/lucide/icons.json']);

      // Search ranking: exact > startsWith > segment match > contains.
      final wifiSearch = await c.call('icons.gallery', {'pack': 'lucide', 'query': 'wifi'});
      expect(wifiSearch['cached'], isTrue);
      expect(fetched, hasLength(1)); // served from cache
      expect([for (final ch in wifiSearch['choices'] as List) ch['name']], ['wifi', 'wifi-off', 'cloud-wifi', 'mywifiicon']);

      // Multi-word query: exact slug match > all-words segment match.
      final muteSearch = await c.call('icons.gallery', {'pack': 'lucide', 'query': 'volume mute'});
      expect([for (final ch in muteSearch['choices'] as List) ch['name']], ['volume-mute', 'audio-volume-mute']);

      // Alias search (including chained alias) deduplicates by canonical icon name.
      final aliasSearch = await c.call('icons.gallery', {'pack': 'lucide', 'query': 'wireless'});
      expect([for (final ch in aliasSearch['choices'] as List) ch['name']], ['wifi']);
      final chainedSearch = await c.call('icons.gallery', {'pack': 'lucide', 'query': 'chained'});
      expect([for (final ch in chainedSearch['choices'] as List) ch['name']], ['wifi']);
      final wlanSearch = await c.call('icons.gallery', {'pack': 'lucide', 'query': 'wlan'});
      expect([for (final ch in wlanSearch['choices'] as List) ch['name']], ['wifi']);

      // Pagination via limit.
      final paged = await c.call('icons.gallery', {'pack': 'lucide', 'limit': 2});
      expect((paged['choices'] as List).length, 2);
      expect(paged['total'], initial['total']);
      expect(paged['truncated'], isTrue);

      // Another pack (tabler).
      final tabler = await c.call('icons.gallery', {'pack': 'tabler'});
      expect(tabler['pack'], 'tabler');
      expect([for (final ch in tabler['choices'] as List) ch['name']], ['sun', 'moon']);
    });

    test('rejects malicious gallery SVG bodies (e.g. <script>) and excludes them from results', () async {
      final packWithEvil = {
        'prefix': 'lucide',
        'width': 24,
        'height': 24,
        'icons': {
          'wifi': {'body': '<path d="M5 13a10 10 0 0 1 14 0"/>'},
          'evil-script': {'body': '<script>alert(1)</script><path d="M0 0h1"/>'},
          'evil-handler': {'body': '<path onclick="alert(1)" d="M0 0h1"/>'},
          'evil-href': {'body': '<use href="https://evil.example/x.svg#a"/>'},
        },
      };
      final c = makeCore(fetcher: (_) async => jsonEncode(packWithEvil));
      final r = await c.call('icons.gallery', {'pack': 'lucide'});
      expect(r['total'], 1);
      expect([for (final ch in r['choices'] as List) ch['name']], ['wifi']);
      final evilQuery = await c.call('icons.gallery', {'pack': 'lucide', 'query': 'evil'});
      expect(evilQuery['total'], 0);
      expect(evilQuery['choices'], isEmpty);
    });

    test('caching (7-day TTL), refresh, offline fallback to stale cache, and offline without cache', () async {
      var now = DateTime.utc(2026, 11, 26, 12);
      var online = true;
      var fetchCount = 0;
      var wifiBody = '<path d="M1 1h10"/>';

      final c = makeCore(
        clock: () => now,
        fetcher: (_) async {
          fetchCount++;
          if (!online) return null;
          return jsonEncode({
            'prefix': 'lucide',
            'width': 24,
            'height': 24,
            'icons': {
              'wifi': {'body': wifiBody},
            },
          });
        },
      );

      // 1. Offline with no cache -> offline: true, error, empty choices.
      online = false;
      final emptyOffline = await c.call('icons.gallery', {'pack': 'lucide'});
      expect(emptyOffline['offline'], isTrue);
      expect(emptyOffline['cached'], isFalse);
      expect(emptyOffline['error'], isA<String>());
      expect(emptyOffline['choices'], isEmpty);
      expect(emptyOffline['total'], 0);
      expect(emptyOffline['truncated'], isFalse);

      // 2. Online -> downloads and writes cache file.
      online = true;
      final first = await c.call('icons.gallery', {'pack': 'lucide'});
      expect(first['offline'], isFalse);
      expect(first['cached'], isFalse);
      expect(fetchCount, 2);
      final cachePath = p.join(w.paths.cache, 'maprisma-settings/icon-gallery/lucide.json');
      expect(File(cachePath).existsSync(), isTrue);

      // 3. Within 7 days -> served from cache without fetching.
      now = now.add(const Duration(days: 6, hours: 23));
      final cachedHit = await c.call('icons.gallery', {'pack': 'lucide'});
      expect(cachedHit['cached'], isTrue);
      expect(cachedHit['offline'], isFalse);
      expect(fetchCount, 2);

      // 4. Past 7 days while offline -> falls back to stale cache with offline: true.
      now = now.add(const Duration(hours: 2));
      online = false;
      final staleFallback = await c.call('icons.gallery', {'pack': 'lucide'});
      expect(staleFallback['offline'], isTrue);
      expect(staleFallback['cached'], isTrue);
      expect(staleFallback['total'], 1);
      expect((staleFallback['choices'] as List).single['name'], 'wifi');
      expect(fetchCount, 3);

      // 5. Explicit refresh while online -> updates cache with new content.
      online = true;
      wifiBody = '<path d="M2 2h20"/>';
      final refreshed = await c.call('icons.gallery', {'pack': 'lucide', 'refresh': true});
      expect(refreshed['cached'], isFalse);
      expect(refreshed['offline'], isFalse);
      expect((refreshed['choices'] as List).single['svg'], contains('M2 2h20'));
      expect(fetchCount, 4);
    });

    test('validates gallery params', () async {
      final c = makeCore(fetcher: (_) async => jsonEncode(_sampleLucide));
      Matcher badParams() => throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params'));
      await expectLater(c.call('icons.gallery', {'pack': 'bogus'}), badParams());
      await expectLater(c.call('icons.gallery', {'pack': 123}), badParams());
      await expectLater(c.call('icons.gallery', {'query': 42}), badParams());
      await expectLater(c.call('icons.gallery', {'limit': -1}), badParams());
      await expectLater(c.call('icons.gallery', {'limit': maxChoices + 1}), badParams());
      await expectLater(c.call('icons.gallery', {'refresh': 'yes'}), badParams());
    });

    test('downloads via curl with exact safety flags and reports missing curl cleanly', () async {
      // Without curl in PATH -> offline error.
      final noCurl = makeCore();
      final missing = await noCurl.call('icons.gallery', {'pack': 'lucide'});
      expect(missing['offline'], isTrue);
      expect(missing['error'], contains('curl'));
      expect(missing['choices'], isEmpty);

      // With fake curl -> verifies exact CLI flags and caches response.
      final argsLog = p.join(w.dir, 'curl.args');
      final payloadFile = p.join(w.dir, 'lucide.json');
      w.writeFile(payloadFile, jsonEncode(_sampleLucide));
      w.fake('curl', 'printf "%s\\n" "\$@" > "$argsLog"\n/usr/bin/cat "$payloadFile"');

      final withCurl = makeCore();
      final res = await withCurl.call('icons.gallery', {'pack': 'lucide', 'query': 'wifi'});
      expect(res['offline'], isFalse);
      expect(res['cached'], isFalse);
      expect((res['choices'] as List).first['id'], 'gallery:lucide:wifi');
      final args = File(argsLog).readAsLinesSync();
      expect(args, [
        '--silent',
        '--show-error',
        '--fail',
        '--proto',
        '=https',
        '--max-redirs',
        '0',
        '--max-time',
        '25',
        '--max-filesize',
        '${6 * 1024 * 1024}',
        '--',
        'https://cdn.jsdelivr.net/npm/@iconify-json/lucide/icons.json',
      ]);
    });
  });

  group('icons.set / reapply / reset with gallery icons', () {
    const iconName = 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-symbolic';
    String iconFile() => p.join(w.paths.icons, '$iconName.svg');
    const originalSvg = '<svg xmlns="http://www.w3.org/2000/svg"><circle r="2"/></svg>\n';

    test('applies gallery:lucide:wifi, preserves original, reapplies after overwrite, resets byte-for-byte', () async {
      w.install('wlan');
      w.writeFile(iconFile(), originalSvg);
      final originalBytes = File(iconFile()).readAsBytesSync();

      final c = makeCore(fetcher: (_) async => jsonEncode(_sampleLucide));

      // Bad gallery format & missing icon errors.
      await expectLater(
        c.call('icons.set', {'app': 'wlan', 'icon': 'gallery:unknown:wifi'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')),
      );
      await expectLater(
        c.call('icons.set', {'app': 'wlan', 'icon': 'gallery:lucide:no-such-icon'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_found')),
      );

      // Apply gallery:lucide:wifi.
      final setRes = await c.call('icons.set', {'app': 'wlan', 'icon': 'gallery:lucide:wifi'});
      expect(setRes['choice']['kind'], 'gallery');
      expect(setRes['choice']['pack'], 'lucide');
      expect(setRes['choice']['name'], 'wifi');
      final writtenBytes = File(iconFile()).readAsBytesSync();
      final writtenText = utf8.decode(writtenBytes);
      expect(writtenText, contains('ColorScheme-Text'));
      expect(writtenText, contains('M5 13a10 10 0 0 1 14 0'));
      expect(svgProblem(writtenBytes), isNull);

      final keptOriginal = p.join(w.paths.managerState, 'icons/wlan/original.svg');
      expect(File(keptOriginal).readAsBytesSync(), originalBytes);

      final got = await c.call('icons.get', {'app': 'wlan'});
      expect(got['current'], 'changed');
      expect(got['choice']['kind'], 'gallery');
      expect(got['choice']['pack'], 'lucide');
      expect(got['choice']['name'], 'wifi');

      // Simulate an installer overwriting the icon with a new default, then reapply.
      const newInstallerSvg = '<svg xmlns="http://www.w3.org/2000/svg"><rect width="4" height="4"/></svg>\n';
      w.writeFile(iconFile(), newInstallerSvg);
      final line = c.icons.reapply(findApp('wlan')!);
      expect(line, contains('wifi'));
      expect(File(iconFile()).readAsBytesSync(), writtenBytes);
      expect(File(keptOriginal).readAsStringSync(), newInstallerSvg);

      // Restore original test bytes into keptOriginal to test byte-for-byte reset of original.
      File(keptOriginal).writeAsBytesSync(originalBytes);
      final resetRes = await c.call('icons.reset', {'app': 'wlan'});
      expect(resetRes['reset'], isTrue);
      expect(File(iconFile()).readAsBytesSync(), originalBytes);
      expect((await c.call('icons.get', {'app': 'wlan'}))['current'], 'original');
    });
  });

  group('whyNot & bar.get icon metadata', () {
    test('whyNot accepts io.github.ubruckhaus.Maprisma*-symbolic as well as CosmicMaprisma*-symbolic', () {
      final c = makeCore();
      const maprismaApp = AppEntry(
        id: 'maprisma-custom',
        name: 'Maprisma Custom',
        kind: 'rust',
        inputs: [Input('maprisma-custom')],
        components: [
          Component(
            id: 'main',
            name: 'Maprisma Custom',
            repo: 'maprisma-custom',
            install: ['./install.sh'],
            paths: [
              InstalledPath('{bin}/maprisma-custom', PathKind.executable, key: true),
              InstalledPath('{icons}/io.github.ubruckhaus.MaprismaCustom-symbolic.svg', PathKind.file),
            ],
          ),
        ],
        bar: BarIcon(
          kdeId: 'maprisma-custom',
          iconName: 'io.github.ubruckhaus.MaprismaCustom-symbolic',
        ),
      );
      expect(c.icons.whyNot(maprismaApp), isNull);
      // Existing non-changeable apps stay rejected.
      expect(c.icons.whyNot(findApp('launcher')!), isNotNull);
      expect(c.icons.whyNot(findApp('maprisma')!), isNotNull);
    });

    test('bar.get includes iconChangeable, iconChanged, barIconFile, barIconSha and reflects set/reset', () async {
      final panelDir = p.join(w.paths.config, 'cosmic/com.system76.CosmicPanel.Panel/v1');
      w.writeFile(
        p.join(panelDir, 'plugins_wings'),
        'Some(([\n    "io.github.ubruckhaus.CosmicMaprismaLauncher",\n], [\n    "com.system76.CosmicAppletPower",\n]))',
      );
      w.writeFile(
        p.join(panelDir, 'plugins_center'),
        'Some([\n    "io.github.ubruckhaus.CosmicMaprismaWlanMonitor",\n])',
      );

      w.install('wlan');
      final wlanIconFile = p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-symbolic.svg');
      const origSvg = '<svg xmlns="http://www.w3.org/2000/svg"><circle r="1"/></svg>\n';
      w.writeFile(wlanIconFile, origSvg);
      final origSha = sha256Bytes(utf8.encode(origSvg));

      final c = makeCore(fetcher: (_) async => jsonEncode(_sampleLucide));

      // Before change: wlan is changeable, not changed, has file and sha; launcher is not changeable; hue (in out) has no file on disk.
      var bar = await c.call('bar.get');
      final wlanBefore = (bar['areas']['center'] as List).single as Map<String, dynamic>;
      expect(wlanBefore['iconChangeable'], isTrue);
      expect(wlanBefore['iconChanged'], isFalse);
      expect(wlanBefore['barIconFile'], wlanIconFile);
      expect(wlanBefore['barIconSha'], origSha);

      final launcherEntry = (bar['areas']['left'] as List).single as Map<String, dynamic>;
      expect(launcherEntry['iconChangeable'], isFalse);
      expect(launcherEntry['iconChanged'], isFalse);
      expect(launcherEntry.containsKey('barIconFile'), isFalse);
      expect(launcherEntry.containsKey('barIconSha'), isFalse);

      final hueOut = (bar['out'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['app'] == 'hue');
      expect(hueOut['iconChangeable'], isTrue);
      expect(hueOut['iconChanged'], isFalse);
      expect(hueOut.containsKey('barIconFile'), isFalse);
      expect(hueOut.containsKey('barIconSha'), isFalse);

      // Apply gallery icon -> iconChanged becomes true and barIconSha updates.
      await c.call('icons.set', {'app': 'wlan', 'icon': 'gallery:lucide:wifi'});
      final newSha = sha256File(wlanIconFile);
      expect(newSha, isNot(origSha));

      bar = await c.call('bar.get');
      final wlanAfter = (bar['areas']['center'] as List).single as Map<String, dynamic>;
      expect(wlanAfter['iconChangeable'], isTrue);
      expect(wlanAfter['iconChanged'], isTrue);
      expect(wlanAfter['barIconFile'], wlanIconFile);
      expect(wlanAfter['barIconSha'], newSha);

      // Reset -> iconChanged returns to false and barIconSha returns to origSha.
      await c.call('icons.reset', {'app': 'wlan'});
      bar = await c.call('bar.get');
      final wlanReset = (bar['areas']['center'] as List).single as Map<String, dynamic>;
      expect(wlanReset['iconChangeable'], isTrue);
      expect(wlanReset['iconChanged'], isFalse);
      expect(wlanReset['barIconFile'], wlanIconFile);
      expect(wlanReset['barIconSha'], origSha);
    });

    test('KDE bar.get trays include icon metadata', () async {
      w.install('wlan');
      final wlanIconFile = p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-symbolic.svg');
      w.writeFile(wlanIconFile, '<svg xmlns="http://www.w3.org/2000/svg"><circle r="1"/></svg>\n');
      final c = makeCore(desktop: 'KDE', fetcher: (_) async => jsonEncode(_sampleLucide));
      final bar = await c.call('bar.get');
      final wlanTray = (bar['trays'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['app'] == 'wlan');
      expect(wlanTray['iconChangeable'], isTrue);
      expect(wlanTray['iconChanged'], isFalse);
      expect(wlanTray['barIconFile'], wlanIconFile);
      expect(wlanTray['barIconSha'], sha256File(wlanIconFile));
    });

    test('icons.set updates sibling state variants (-active-symbolic, -off-symbolic) and reset restores them byte for byte', () async {
      w.install('wlan');
      final baseFile = p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-symbolic.svg');
      final activeFile = p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-active-symbolic.svg');
      final offFile = p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-off-symbolic.svg');
      const origBase = '<svg xmlns="http://www.w3.org/2000/svg"><circle r="1"/></svg>\n';
      const origActive = '<svg xmlns="http://www.w3.org/2000/svg"><defs><style>.ColorScheme-Highlight{color:#3daee9;}</style></defs><circle class="ColorScheme-Highlight" r="2"/></svg>\n';
      const origOff = '<svg xmlns="http://www.w3.org/2000/svg"><circle r="3"/></svg>\n';
      w.writeFile(baseFile, origBase);
      w.writeFile(activeFile, origActive);
      w.writeFile(offFile, origOff);

      final c = makeCore(fetcher: (_) async => jsonEncode(_sampleLucide));
      await c.call('icons.set', {'app': 'wlan', 'icon': 'gallery:lucide:wifi'});

      // Active variant uses the chosen icon and preserves KDE ColorScheme-Highlight.
      final activeText = File(activeFile).readAsStringSync();
      expect(activeText, contains('M5 13a10 10 0 0 1 14 0'));
      expect(activeText, contains('ColorScheme-Highlight'));
      expect(File(offFile).readAsStringSync(), contains('M5 13a10 10 0 0 1 14 0'));

      // Switching to a second icon keeps the true originals backed up.
      await c.call('icons.set', {'app': 'wlan', 'icon': 'gallery:lucide:bell'});
      expect(File(activeFile).readAsStringSync(), contains('M6 8a6 6 0 0 1 12 0'));

      // Reset restores base and every sibling variant byte for byte.
      await c.call('icons.reset', {'app': 'wlan'});
      expect(File(baseFile).readAsStringSync(), origBase);
      expect(File(activeFile).readAsStringSync(), origActive);
      expect(File(offFile).readAsStringSync(), origOff);
    });

    test('Hyprland refresh restarts symlinked trays and reloads running maprisma-shell; KDE clears icon-cache.kcache', () async {
      // Hyprland: symlinked tray + running maprisma-shell (quickshell).
      w.install('settings');
      final iconFile = p.join(w.paths.icons, 'io.github.ubruckhaus.CosmicMaprismaManager-symbolic.svg');
      w.writeFile(iconFile, '<svg xmlns="http://www.w3.org/2000/svg"><circle r="1"/></svg>\n');
      final realTray = p.join(w.paths.lib, 'maprisma-settings/bin/maprisma-settings-tray');
      w.writeFile(realTray, '#!/bin/sh\nexit 0\n', mode: '755');
      final binTray = p.join(w.paths.bin, 'maprisma-settings-tray');
      if (FileSystemEntity.typeSync(binTray, followLinks: false) != FileSystemEntityType.notFound) {
        File(binTray).deleteSync();
      }
      Link(binTray).createSync(realTray);
      w.writeFile(w.paths.expand(findApp('settings')!.bar.kdeAutostart!), '[Desktop Entry]\nExec=x\n');

      final qsLog = p.join(w.dir, 'qs.log');
      w.fake('qs', 'printf "%s\\n" "\$*" >> "$qsLog"\nexit 0');
      w.process(701, exe: realTray);
      w.process(702, exe: '/usr/bin/quickshell', argv: ['qs', '-c', 'maprisma-shell', '-n', '-d']);

      final hypr = makeCore(desktop: 'Hyprland', fetcher: (_) async => jsonEncode(_sampleLucide));
      final res = await hypr.call('icons.set', {'app': 'settings', 'icon': 'gallery:lucide:wifi'});
      expect(res['bar']['trayRestarted'], isTrue);
      expect(res['bar']['shellRestarted'], isTrue);
      expect(File(qsLog).readAsStringSync(), contains('kill -c maprisma-shell'));

      // KDE: icon-cache.kcache is removed when present.
      final kcache = File(p.join(w.paths.cache, 'icon-cache.kcache'))..createSync(recursive: true);
      expect(kcache.existsSync(), isTrue);
      final kde = makeCore(desktop: 'KDE', fetcher: (_) async => jsonEncode(_sampleLucide));
      await kde.call('icons.set', {'app': 'settings', 'icon': 'gallery:lucide:bell'});
      expect(kcache.existsSync(), isFalse);
    });
  });
}
