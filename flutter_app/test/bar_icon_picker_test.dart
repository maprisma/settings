import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app_facts.dart';
import 'package:maprisma_manager/app_icon.dart';
import 'package:maprisma_manager/bar_editor.dart';
import 'package:maprisma_manager/icon_picker.dart';
import 'package:path/path.dart' as p;

const _packs = [
  {'id': 'lucide', 'name': 'Lucide', 'license': 'ISC'},
  {'id': 'tabler', 'name': 'Tabler', 'license': 'MIT'},
  {'id': 'mdi', 'name': 'Material Design', 'license': 'Apache-2.0'},
  {'id': 'bi', 'name': 'Bootstrap', 'license': 'MIT'},
];

const _svgWifi = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="18" r="2" fill="currentColor"/></svg>';
const _svgBolt = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M13 2 L4 14 H12 L11 22 L20 10 H12 Z" fill="currentColor"/></svg>';

void main() {
  late Directory tmp;
  late String wlanIconFile;
  late String themeIconFile;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bar_icon_picker_test_');
    wlanIconFile = p.join(tmp.path, 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor-symbolic.svg');
    themeIconFile = p.join(tmp.path, 'network-wireless-symbolic.svg');
    File(wlanIconFile).writeAsStringSync(_svgWifi);
    File(themeIconFile).writeAsStringSync(_svgBolt);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<App> sampleApps() => [
        {
          'id': 'wlan',
          'name': 'Maprisma WLAN Monitor',
          'state': 'installed',
          'icon': {'file': wlanIconFile, 'symbolic': true},
        },
        {
          'id': 'hue',
          'name': 'Maprisma Lights',
          'state': 'installed',
          'icon': {'file': themeIconFile, 'symbolic': true},
        },
        {
          'id': 'llm',
          'name': 'Maprisma LLM Monitor',
          'state': 'installed',
          'icon': {'file': themeIconFile, 'symbolic': true},
        },
      ];

  testWidgets('BarEditorPage shows change-icon button only for changeable Maprisma apps (areas, out, and systemTray)', (tester) async {
    Future<Map<String, dynamic>> fakeCore(String method, [Map<String, dynamic> params = const {}]) async {
      if (method == 'bar.get') {
        return {
          'kind': 'cosmicPanel',
          'panel': 'Panel',
          'revision': 'r1',
          'areas': {
            'left': [
              {'id': 'com.system76.CosmicAppletWorkspaces', 'name': 'Workspaces', 'ours': false},
              {
                'id': 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor',
                'app': 'wlan',
                'ours': true,
                'iconChangeable': true,
                'iconChanged': true,
                'barIconFile': wlanIconFile,
                'barIconSha': 'sha-1',
              },
            ],
            'center': [
              {
                'id': 'io.github.ubruckhaus.CosmicMaprismaHueLights',
                'app': 'hue',
                'ours': true,
                'iconChangeable': false,
                'iconChanged': false,
              },
            ],
            'right': const [],
          },
          'out': [
            {
              'id': 'io.github.ubruckhaus.CosmicMaprismaLlmMonitor',
              'app': 'llm',
              'ours': true,
              'iconChangeable': true,
              'iconChanged': false,
              'barIconFile': themeIconFile,
              'barIconSha': 'sha-llm',
            },
          ],
        };
      }
      return {};
    }

    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: BarEditorPage(core: fakeCore, apps: sampleApps(), embedded: true)));
    await tester.pumpAndSettle();

    // Changeable entries in area and in "Not in the bar" have the icon button.
    expect(find.byKey(const ValueKey('bar-icon-wlan')), findsOneWidget);
    expect(find.byKey(const ValueKey('bar-icon-llm')), findsOneWidget);
    // Non-changeable Maprisma app and desktop's own entry do NOT.
    expect(find.byKey(const ValueKey('bar-icon-hue')), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('area-left')), matching: find.byIcon(Icons.edit_outlined)), findsOneWidget);

    // Custom-changed icon button uses primary tint.
    final wlanEdit = tester.widget<Icon>(
      find.descendant(of: find.byKey(const ValueKey('bar-icon-wlan')), matching: find.byType(Icon)),
    );
    final ctx = tester.element(find.byKey(const ValueKey('bar-icon-wlan')));
    expect(wlanEdit.color, Theme.of(ctx).colorScheme.primary);

    // Also verify systemTray mode renders trailing IconButton only for changeable entries.
    Future<Map<String, dynamic>> trayCore(String method, [Map<String, dynamic> params = const {}]) async {
      if (method == 'bar.get') {
        return {
          'kind': 'systemTray',
          'trays': [
            {'id': 'wlan', 'app': 'wlan', 'startsAtLogin': true, 'running': true, 'iconChangeable': true, 'iconChanged': false, 'barIconFile': wlanIconFile, 'barIconSha': 'sha-1'},
            {'id': 'hue', 'app': 'hue', 'startsAtLogin': false, 'running': false, 'iconChangeable': false, 'iconChanged': false},
          ],
        };
      }
      return {};
    }

    await tester.pumpWidget(MaterialApp(home: BarEditorPage(core: trayCore, apps: sampleApps(), embedded: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bar-icon-wlan')), findsOneWidget);
    expect(find.byKey(const ValueKey('bar-icon-hue')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [900.0, 460.0]) {
    testWidgets('clicking bar-icon opens IconPicker, switches to Online gallery, changes pack, searches, applies, reloads bar & notifies at ${width.round()} px', (tester) async {
      final calls = <(String, Map<String, dynamic>)>[];
      var barGetCount = 0;
      var iconsChangedCount = 0;
      var iconChanged = false;
      var sha = 'sha-initial';

      Future<Map<String, dynamic>> fakeCore(String method, [Map<String, dynamic> params = const {}]) async {
        calls.add((method, Map<String, dynamic>.from(params)));
        switch (method) {
          case 'bar.get':
            barGetCount++;
            return {
              'kind': 'cosmicPanel',
              'panel': 'Panel',
              'revision': 'r$barGetCount',
              'areas': {
                'left': [
                  {
                    'id': 'io.github.ubruckhaus.CosmicMaprismaWlanMonitor',
                    'app': 'wlan',
                    'ours': true,
                    'iconChangeable': true,
                    'iconChanged': iconChanged,
                    'barIconFile': wlanIconFile,
                    'barIconSha': sha,
                  },
                ],
                'center': const [],
                'right': const [],
              },
              'out': const [],
            };
          case 'icons.get':
            return {
              'changeable': true,
              'current': iconChanged ? 'changed' : 'original',
              'file': wlanIconFile,
              'note': 'the COSMIC applet draws a built-in copy when no icon theme overrides it, so restart the panel if it does not refresh immediately',
              'theme': {'name': 'Cosmic'},
              'total': 1,
              'truncated': false,
              'choices': [
                {'name': 'network-wireless-symbolic', 'theme': 'Cosmic', 'file': themeIconFile},
              ],
            };
          case 'icons.gallery':
            final pack = '${params['pack'] ?? 'lucide'}';
            final q = '${params['query'] ?? ''}'.toLowerCase();
            final all = pack == 'tabler'
                ? [
                    {'id': 'gallery:tabler:wifi', 'pack': 'tabler', 'name': 'wifi', 'svg': _svgWifi},
                    {'id': 'gallery:tabler:bolt', 'pack': 'tabler', 'name': 'bolt', 'svg': _svgBolt},
                  ]
                : [
                    {'id': 'gallery:lucide:radio', 'pack': 'lucide', 'name': 'radio', 'svg': _svgWifi},
                    {'id': 'gallery:lucide:zap', 'pack': 'lucide', 'name': 'zap', 'svg': _svgBolt},
                  ];
            final filtered = q.isEmpty ? all : all.where((e) => '${e['name']}'.contains(q)).toList();
            return {
              'pack': pack,
              'packs': _packs,
              'query': q,
              'total': filtered.length,
              'truncated': false,
              'cached': true,
              'offline': false,
              'error': null,
              'choices': filtered,
            };
          case 'icons.set':
            iconChanged = true;
            sha = 'sha-updated';
            File(wlanIconFile).writeAsStringSync(_svgBolt);
            return {'ok': true};
          default:
            return {};
        }
      }

      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: BarEditorPage(
          core: fakeCore,
          apps: sampleApps(),
          embedded: true,
          onIconsChanged: () => iconsChangedCount++,
        ),
      ));
      await tester.pumpAndSettle();
      expect(barGetCount, 1);

      // Tap the little change-icon symbol on the WLAN chip.
      await tester.tap(find.byKey(const ValueKey('bar-icon-wlan')));
      await tester.pumpAndSettle();

      expect(find.text('Bar icon of Maprisma WLAN Monitor'), findsOneWidget);
      expect(find.byKey(const ValueKey('icon-tab-theme')), findsOneWidget);
      expect(find.byKey(const ValueKey('icon-tab-gallery')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Switch to Online gallery tab.
      await tester.tap(find.byKey(const ValueKey('icon-tab-gallery')));
      await tester.pumpAndSettle();
      expect(calls.any((c) => c.$1 == 'icons.gallery' && c.$2['pack'] == 'lucide'), isTrue);
      expect(find.byKey(const ValueKey('gallery-pack-tabler')), findsOneWidget);
      expect(tester.getRect(find.byType(GridView)).height, greaterThan(80));
      expect(tester.takeException(), isNull);

      // Switch to Tabler pack.
      await tester.tap(find.byKey(const ValueKey('gallery-pack-tabler')));
      await tester.pumpAndSettle();
      expect(calls.any((c) => c.$1 == 'icons.gallery' && c.$2['pack'] == 'tabler'), isTrue);

      // Search for 'wifi' (wait past 250ms debounce).
      await tester.enterText(find.byKey(const ValueKey('icon-search')), 'wifi');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(calls.any((c) => c.$1 == 'icons.gallery' && c.$2['pack'] == 'tabler' && c.$2['query'] == 'wifi'), isTrue);

      // Select the filtered icon and wait past double-tap threshold.
      final cell = find.descendant(of: find.byType(GridView), matching: find.byType(InkWell)).first;
      await tester.tap(cell);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('wifi (tabler)'), findsOneWidget);

      // Apply the icon.
      await tester.tap(find.text('Use this icon'));
      await tester.pumpAndSettle();

      expect(calls.any((c) => c.$1 == 'icons.set' && c.$2['app'] == 'wlan' && c.$2['icon'] == 'gallery:tabler:wifi'), isTrue);
      expect(barGetCount, 2);
      expect(iconsChangedCount, 1);
      expect(calls.where((c) => c.$1 == 'bar.move'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Online gallery offline/error state with Retry button at ${width.round()} px', (tester) async {
      var galleryCalls = 0;
      var sawRefresh = false;

      Future<Map<String, dynamic>> fakeCore(String method, [Map<String, dynamic> params = const {}]) async {
        if (method == 'icons.get') {
          return {
            'changeable': true,
            'current': 'original',
            'file': wlanIconFile,
            'theme': {'name': 'Cosmic'},
            'total': 1,
            'truncated': false,
            'choices': [
              {'name': 'network-wireless-symbolic', 'theme': 'Cosmic', 'file': themeIconFile},
            ],
          };
        }
        if (method == 'icons.gallery') {
          galleryCalls++;
          if (params['refresh'] == true) sawRefresh = true;
          if (galleryCalls == 1) {
            return {
              'pack': 'lucide',
              'packs': _packs,
              'query': '',
              'total': 0,
              'truncated': false,
              'cached': false,
              'offline': true,
              'error': 'Could not download icon pack',
              'choices': const [],
            };
          }
          return {
            'pack': 'lucide',
            'packs': _packs,
            'query': '',
            'total': 1,
            'truncated': false,
            'cached': true,
            'offline': true,
            'error': null,
            'choices': [
              {'id': 'gallery:lucide:wifi', 'pack': 'lucide', 'name': 'wifi', 'svg': _svgWifi},
            ],
          };
        }
        return {};
      }

      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: IconPicker(core: fakeCore, app: sampleApps().first),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('icon-tab-gallery')));
      await tester.pumpAndSettle();

      expect(find.text('Could not download icon pack'), findsOneWidget);
      expect(find.byKey(const ValueKey('gallery-retry')), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('gallery-retry')));
      await tester.pumpAndSettle();

      expect(sawRefresh, isTrue);
      expect(find.textContaining('Offline: showing cached icons'), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('AppIcon with cacheKey reloads SVG bytes when overwritten at the same path', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AppIcon(wlanIconFile, symbolic: true, size: 24, cacheKey: 'sha-1')));
    await tester.pumpAndSettle();
    final first = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(first.key, ValueKey('$wlanIconFile#sha-1'));
    expect(first.bytesLoader, isA<SvgBytesLoader>());

    File(wlanIconFile).writeAsStringSync(_svgBolt);
    await tester.pumpWidget(MaterialApp(home: AppIcon(wlanIconFile, symbolic: true, size: 24, cacheKey: 'sha-2')));
    await tester.pumpAndSettle();
    final second = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(second.key, ValueKey('$wlanIconFile#sha-2'));
    expect((second.bytesLoader as SvgBytesLoader).bytes, File(wlanIconFile).readAsBytesSync());
    expect(tester.takeException(), isNull);
  });
}
