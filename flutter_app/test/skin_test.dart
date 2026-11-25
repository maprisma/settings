import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/skin.dart';
import 'package:maprisma_manager/theme.dart';
import 'package:maprisma_manager/window_style.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';

void main() {
  tearDown(() => configureLanguage('en'));

  group('skin definitions and normalization', () {
    test('appSkins has exact 6 skins in order', () {
      expect(appSkins, ['native', 'synthwave', 'cozy', 'terminal', 'disco', 'zen']);
    });

    test('normalizeSkin handles valid, case/whitespace, null and unknown values', () {
      for (final s in appSkins) {
        expect(normalizeSkin(s), s);
      }
      expect(normalizeSkin(' SYNTHWAVE '), 'synthwave');
      expect(normalizeSkin(null), 'native');
      expect(normalizeSkin(''), 'native');
      expect(normalizeSkin('neon-unknown'), 'native');
    });

    test('skinStyle returns exact palettes for all 6 skins', () {
      expect(skinStyle('native'), isNull);
      expect(skinStyle('unknown'), isNull);

      final synthwave = skinStyle('synthwave')!;
      expect(synthwave.accent, const Color(0xffff2e93));
      expect(synthwave.borderTint, const Color(0xff00e5ff));
      expect(synthwave.bgTint, const Color(0xff3a1259));
      expect(synthwave.windowBg, const Color(0xff130924));
      expect(synthwave.foreground, const Color(0xfff4eaff));
      expect(synthwave.borderWidth, 1.5);

      final cozy = skinStyle('cozy')!;
      expect(cozy.accent, const Color(0xfff09a36));
      expect(cozy.borderTint, const Color(0xffe0822a));
      expect(cozy.bgTint, const Color(0xff593012));
      expect(cozy.windowBg, const Color(0xff21150e));
      expect(cozy.foreground, const Color(0xfff5e8d6));
      expect(cozy.borderWidth, 1.25);

      final terminal = skinStyle('terminal')!;
      expect(terminal.accent, const Color(0xff2ce868));
      expect(terminal.borderTint, const Color(0xff22c55e));
      expect(terminal.bgTint, const Color(0xff0d381a));
      expect(terminal.windowBg, const Color(0xff09130b));
      expect(terminal.foreground, const Color(0xffd2fce0));
      expect(terminal.borderWidth, 1.25);

      final disco = skinStyle('disco')!;
      expect(disco.accent, const Color(0xffd946ef));
      expect(disco.borderTint, const Color(0xfffacc15));
      expect(disco.bgTint, const Color(0xff4c1666));
      expect(disco.windowBg, const Color(0xff1c0c2b));
      expect(disco.foreground, const Color(0xfff8ecff));
      expect(disco.borderWidth, 1.5);

      final zen = skinStyle('zen')!;
      expect(zen.accent, const Color(0xff52b798));
      expect(zen.borderTint, const Color(0xff64c2a4));
      expect(zen.bgTint, const Color(0xff1e3832));
      expect(zen.windowBg, const Color(0xff141d1c));
      expect(zen.foreground, const Color(0xffe2f0ec));
      expect(zen.borderWidth, 1.0);
    });

    test('toDesktopColors produces valid 6-digit hex strings', () {
      for (final skin in appSkins.where((s) => s != 'native')) {
        final colors = skinStyle(skin)!.toDesktopColors();
        for (final key in ['background', 'foreground', 'accent', 'muted', 'selection']) {
          expect(colors[key], matches(RegExp(r'^#[0-9a-f]{6}$')), reason: '$skin.$key');
        }
      }
    });
  });

  group('applySkinToTheme and withWindowAlpha composition', () {
    test('native returns base theme untouched', () {
      final base = appTheme(Brightness.light, {'background': '#eff1f5', 'foreground': '#4c4f69', 'accent': '#1e66f5'}, 12);
      final themed = applySkinToTheme(base, 'native');
      expect(identical(themed, base), isTrue);
      expect(themed.colorScheme.surface, const Color(0xffeff1f5));
      expect(themed.extension<AppSkinExtension>(), isNull);
    });

    test('non-native skin overrides palette, card border, and composes cleanly with withWindowAlpha', () {
      final base = appTheme(Brightness.light, {'background': '#eff1f5', 'foreground': '#4c4f69', 'accent': '#1e66f5'}, 10);
      final synth = skinStyle('synthwave')!;
      final themed = applySkinToTheme(base, 'synthwave', radius: 10);

      expect(themed.brightness, Brightness.dark);
      expect(themed.colorScheme.surface, synth.windowBg);
      expect(themed.colorScheme.onSurface, synth.foreground);
      expect(themed.colorScheme.primary, synth.accent);
      expect(themed.colorScheme.outlineVariant, synth.borderTint.withValues(alpha: 0.42));
      expect(themed.extension<AppSkinExtension>()?.skin, 'synthwave');

      final shape = themed.cardTheme.shape! as RoundedRectangleBorder;
      expect(shape.side.color, synth.borderTint.withValues(alpha: 0.48));
      expect(shape.side.width, synth.borderWidth);
      expect(themed.cardTheme.color!.a, closeTo(1.0, 0.001));

      final glassy = withWindowAlpha(themed, glassyAlpha);
      expect(glassy.scaffoldBackgroundColor.a, closeTo(glassyAlpha, 0.001));
      expect(glassy.cardTheme.color!.a, closeTo((1 + glassyAlpha) / 2, 0.001));
      expect(glassy.colorScheme.surfaceContainer.a, closeTo((1 + glassyAlpha) / 2, 0.001));
      expect(glassy.colorScheme.primary, synth.accent);
    });
  });

  group('Settings page App skin control', () {
    testWidgets('shows App skin with swatches, switches live, and saves via settings.set', (tester) async {
      configureLanguage('en');
      final settings = <String, dynamic>{'language': 'en', 'corners': 'windows', 'skin': 'native', 'screenshot_key': true};
      final calls = <(String, Object?)>[];
      Future<Map<String, dynamic>> core(String method, [Map<String, dynamic> params = const {}]) async {
        switch (method) {
          case 'settings.get':
            return {...settings};
          case 'settings.set':
            calls.add((params['key'] as String, params['value']));
            settings[params['key'] as String] = params['value'];
            return {...params};
          case 'desktop.look':
            return {'colors': {'background': '#eff1f5', 'foreground': '#4c4f69', 'accent': '#1e66f5'}};
          case 'apps.list':
            return {'apps': <Map<String, dynamic>>[], 'desktop': 'other'};
        }
        return {};
      }

      await tester.pumpWidget(ManagerApp(
        core: core,
        look: const {'colors': {'background': '#eff1f5', 'foreground': '#4c4f69', 'accent': '#1e66f5'}},
        settings: settings,
        checkOnStart: false,
        relook: null,
      ));
      await tester.pumpAndSettle();

      ThemeData currentTheme() => Theme.of(tester.element(find.byType(Scaffold).first));
      expect(currentTheme().colorScheme.surface, const Color(0xffeff1f5));

      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();

      final skinRow = find.byKey(const ValueKey('settings-skin'));
      expect(skinRow, findsOneWidget);
      final skinDropdown = find.descendant(of: skinRow, matching: find.byType(DropdownButton<String>));
      await tester.tap(skinDropdown);
      await tester.pumpAndSettle();

      for (final label in ['Native', 'Synthwave', 'Cozy', 'Terminal', 'Disco', 'Zen']) {
        expect(find.text(label), findsWidgets);
      }

      await tester.tap(find.text('Synthwave').last);
      await tester.pumpAndSettle();

      expect(calls, contains(('skin', 'synthwave')));
      expect(currentTheme().colorScheme.surface, const Color(0xff130924));
      expect(currentTheme().colorScheme.primary, const Color(0xffff2e93));

      await tester.tap(skinDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Native').last);
      await tester.pumpAndSettle();

      expect(calls, contains(('skin', 'native')));
      expect(currentTheme().colorScheme.surface, const Color(0xffeff1f5));
    });
  });
}
