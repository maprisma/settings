import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() {
    w = World.create();
    w.fake('pacman', 'exit 1');
  });
  tearDown(() {
    setLocalCatalog(const []);
    w.dispose();
  });

  test('loads rust_applet and rust_standalone entries from local-apps.json and deduplicates discovery', () async {
    w.writeFile(
      w.paths.localAppsFile,
      jsonEncode({
        'apps': [
          {
            'id': 'private-applet',
            'name': 'Maprisma Private Applet',
            'preset': 'rust_applet',
            'repo': 'maprisma-private-applet',
            'github': 'maprisma/private-applet',
            'suffix': 'PrivateApplet',
            'binary': 'maprisma-private-applet',
            'scripts': ['helper.py'],
            'data': [
              {'path': '{config}/maprisma-private-applet', 'note': 'local config'},
            ],
            'units': [
              {'name': 'maprisma-private-applet.service'},
            ],
          },
          {
            'id': 'private-amp',
            'name': 'Maprisma Private Amp',
            'preset': 'rust_standalone',
            'repo': 'maprisma-private-amp',
            'github': 'maprisma/private-amp',
            'binary': 'maprisma-private-amp',
            'appId': 'io.github.ubruckhaus.MaprismaPrivateAmp',
            'morePaths': [
              {'path': '{icons}/io.github.ubruckhaus.MaprismaPrivateAmp-active-symbolic.svg', 'kind': 'file'},
            ],
            'data': ['{config}/maprisma-private-amp'],
          },
        ],
      }),
    );

    w.repo('maprisma-private-applet');
    w.repo('maprisma-private-amp');

    final core = w.core(desktop: 'Hyprland');
    expect(findApp('private-applet'), isNotNull);
    expect(findApp('private-amp'), isNotNull);

    w.install('private-applet');
    w.install('private-amp');

    final list = await core.call('apps.list');
    final applet = appOf(list, 'private-applet');
    expect(applet['state'], 'installed');
    expect(applet['bar']['has'], isTrue);
    expect(applet['sources']['inputs'][0]['github']['repo'], 'maprisma/private-applet');

    final amp = appOf(list, 'private-amp');
    expect(amp['state'], 'installed');
    expect(amp['bar']['has'], isTrue);
    expect(amp['sources']['inputs'][0]['github']['repo'], 'maprisma/private-amp');

    // Local catalog entries must not reappear as unknown discovered apps.
    final discovered = ((list['discovered'] as Map)['apps'] as List).cast<Map<String, dynamic>>();
    expect(discovered.where((d) => d['name'] == 'maprisma-private-applet' || d['name'] == 'maprisma-private-amp'), isEmpty);

    // Bar editor on Hyprland sees both tray entries.
    final bar = await core.call('bar.get');
    final barApps = {
      for (final area in (bar['areas'] as Map).values)
        for (final e in area as List)
          if (e is Map && e['app'] != null) e['app'],
      for (final e in (bar['out'] as List? ?? const []))
        if (e is Map && e['app'] != null) e['app'],
    };
    expect(barApps, containsAll(['private-applet', 'private-amp']));
  });

  test('ignores missing, malformed, oversized, and colliding local-apps.json entries safely', () {
    expect(loadLocalCatalog(w.paths), isEmpty);

    final warnings = <String>[];
    w.writeFile(w.paths.localAppsFile, '{not json');
    expect(loadLocalCatalog(w.paths, onWarning: warnings.add), isEmpty);
    expect(warnings, isNotEmpty);

    warnings.clear();
    w.writeFile(
      w.paths.localAppsFile,
      jsonEncode([
        // Collides with built-in id
        {
          'id': 'wlan',
          'name': 'Shadow WLAN',
          'preset': 'rust_standalone',
          'repo': 'maprisma-wlan-shadow',
          'binary': 'maprisma-wlan-shadow',
          'appId': 'io.github.ubruckhaus.Shadow',
        },
        // Collides with selfApp
        {
          'id': 'settings',
          'name': 'Shadow Settings',
          'preset': 'rust_standalone',
          'repo': 'maprisma-shadow',
          'binary': 'maprisma-shadow',
          'appId': 'io.github.ubruckhaus.Shadow',
        },
        // Invalid template placeholder
        {
          'id': 'bad-tpl',
          'name': 'Bad Template',
          'repo': 'maprisma-bad',
          'paths': [
            {'path': '{nonexistent}/x', 'kind': 'file'},
          ],
        },
        // Valid custom entry
        {
          'id': 'custom-ok',
          'name': 'Custom OK',
          'repo': 'maprisma-custom-ok',
          'paths': [
            {'path': '{bin}/maprisma-custom-ok', 'kind': 'executable'},
          ],
        },
        // Duplicate of earlier local entry
        {
          'id': 'custom-ok',
          'name': 'Custom Dup',
          'repo': 'maprisma-custom-dup',
          'paths': [
            {'path': '{bin}/maprisma-custom-dup', 'kind': 'executable'},
          ],
        },
      ]),
    );

    final loaded = loadLocalCatalog(w.paths, onWarning: warnings.add);
    expect(loaded.map((e) => e.id).toList(), ['custom-ok']);
    expect(warnings, hasLength(4));

    // Oversized file is ignored cleanly
    warnings.clear();
    File(w.paths.localAppsFile).writeAsStringSync('[${' ' * (256 * 1024 + 16)}]');
    expect(loadLocalCatalog(w.paths, onWarning: warnings.add), isEmpty);
    expect(warnings.single, contains('exceeds'));
  });
}
