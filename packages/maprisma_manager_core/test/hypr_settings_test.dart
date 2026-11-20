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
    fakeHypr(w);
  });
  tearDown(() => w.dispose());

  String lua() => File(p.join(w.home, '.config/hypr/hypr-manager.lua')).readAsStringSync();
  String user() => File(p.join(w.home, '.config/hypr/hypr-user.lua')).readAsStringSync();
  int reloads() {
    final f = File(p.join(w.home, 'hyprctl.log'));
    return f.existsSync() ? f.readAsLinesSync().length : 0;
  }

  test('displays.get: modes without Hz, scale, position, nothing stored yet', () async {
    final r = await w.core(desktop: 'Hyprland').call('displays.get');
    final m = (r['monitors'] as List).first as Map;
    expect(m, allOf(containsPair('mode', '3840x2160@120.00'), containsPair('scale', 2.0), containsPair('position', '0x0'), containsPair('enabled', true)));
    expect(m['modes'], ['3840x2160@120.00', '3840x2160@60.00', '1920x1080@60.00']);
  });

  test('displays.set writes hl.monitor into hypr-manager.lua, hooks it once into hypr-user.lua, reloads, and undoes', () async {
    w.writeFile(p.join(w.home, '.config/hypr/hypr-user.lua'), '-- mine\nhl.config({ input = { kb_layout = "de" } })\n');
    final core = w.core(desktop: 'Hyprland');
    await core.call('displays.set', {'output': 'HDMI-A-1', 'mode': '3840x2160@60.00', 'vrr': 2});
    expect(lua(), contains('hl.monitor({\n    output = "HDMI-A-1",\n    mode = "3840x2160@60.00",\n    position = "0x0",\n    scale = 2.0,\n    vrr = 2,\n})'));
    expect(user(), startsWith('-- mine\nhl.config({ input = { kb_layout = "de" } })\n'));
    expect(user(), endsWith('${HyprConfig.requireLine}\n'));
    await core.call('displays.set', {'output': 'HDMI-A-1', 'scale': 1.5});
    expect(RegExp('hypr-manager').allMatches(user()).length, 1);
    expect(reloads(), 2);
    expect((await core.call('displays.get'))['canUndo'], isTrue);
    // neither change was kept: undo goes back to before the first one
    await core.call('displays.undo');
    expect(lua(), isNot(contains('HDMI-A-1')));
    expect((await core.call('displays.get'))['pending'], isFalse);
  });

  test('a change goes back by itself unless kept; a second one goes back to before the first', () async {
    final core = w.core(desktop: 'Hyprland');
    core.displays.keepFor = const Duration(milliseconds: 300);
    final r = await core.call('displays.set', {'output': 'HDMI-A-1', 'scale': 1.5});
    expect(r['revertIn'], 0);
    await core.call('displays.set', {'output': 'HDMI-A-1', 'scale': 1.25});
    expect(lua(), contains('scale = 1.25'));
    expect((await core.call('displays.get'))['pending'], isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // back to before the first change: no line for HDMI-A-1 any more
    expect(lua(), isNot(contains('HDMI-A-1')));
    expect((await core.call('displays.get'))['pending'], isFalse);
    // kept: it stays
    await core.call('displays.set', {'output': 'HDMI-A-1', 'scale': 1.5});
    expect((await core.call('displays.keep'))['kept'], isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(lua(), contains('scale = 1.5'));
    expect((await core.call('displays.get'))['canUndo'], isFalse);
  });

  test('two changes sent together go back to the original; a keep after the countdown says it is too late', () async {
    // a slow reload, as Hyprland's can be
    File(p.join(w.fakeBin, 'hyprctl')).renameSync(p.join(w.home, 'hyprctl-real'));
    w.fake('hyprctl', 'case "\$1" in reload) /usr/bin/sleep 0.3; echo ok ;; *) exec "\$HOME/hyprctl-real" "\$@" ;; esac');
    final core = w.core(desktop: 'Hyprland');
    core.displays.keepFor = const Duration(milliseconds: 400);
    await Future.wait([
      core.call('displays.set', {'output': 'HDMI-A-1', 'scale': 1.5}),
      core.call('displays.set', {'output': 'HDMI-A-1', 'scale': 1.25}),
    ]);
    expect(lua(), contains('scale = 1.25'));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(lua(), isNot(contains('HDMI-A-1')));
    expect((await core.call('displays.keep'))['kept'], isFalse);
  });

  test('displays.set refuses unknown modes, scales, outputs and switching off the last display', () async {
    final core = w.core(desktop: 'Hyprland');
    for (final bad in [
      {'output': 'HDMI-A-1', 'mode': '800x600@60.00'},
      {'output': 'HDMI-A-1', 'scale': 1.33},
      {'output': 'HDMI-A-9', 'scale': 1.0},
      {'output': 'HDMI-A-1', 'position': 'left; rm -rf'},
      {'output': 'HDMI-A-1', 'mirror': 'HDMI-A-1'},
      {'output': 'HDMI-A-1'},
    ]) {
      await expectLater(core.call('displays.set', bad), throwsA(isA<RouteError>()), reason: '$bad');
    }
    await core.call('displays.set', {'output': 'DP-1', 'disabled': true});
    monitorsFixture[1]['disabled'] = true;
    fakeHypr(w);
    try {
      await expectLater(core.call('displays.set', {'output': 'HDMI-A-1', 'disabled': true}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'refused')));
    } finally {
      monitorsFixture[1]['disabled'] = false;
    }
    await expectLater(w.core(desktop: 'COSMIC').call('displays.get'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'unavailable')));
  });

  test('displays.store (Maprisma Display) keeps fields at once, no countdown, HDR follows Super+H', () async {
    final core = w.core(desktop: 'Hyprland');
    core.displays.keepFor = const Duration(milliseconds: 200);
    final r = await core.call('displays.store', {'output': 'HDMI-A-1', 'scale': 1.6, 'vrr': 1, 'hdr': true});
    expect(r['revertIn'], isNull);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(lua(), contains('hl.monitor({\n    output = "HDMI-A-1",\n    mode = "3840x2160@120.00",\n    position = "0x0",\n    scale = 1.6,\n    vrr = 1,\n    bitdepth = hdr_on and 10 or 8,\n    cm = hdr_on and "hdr" or "srgb",\n})'));
    expect(lua(), contains('/maprisma-hdr/hyprland'));
    expect((await core.call('displays.get'))['canUndo'], isFalse);
    expect(user(), endsWith('${HyprConfig.requireLine}\n'));
    // hdr false takes it out again (and the preamble with it); unknown keys and outputs are refused
    await core.call('displays.store', {'output': 'HDMI-A-1', 'hdr': false});
    expect(lua(), isNot(contains('hdr_on')));
    for (final bad in [
      {'output': 'HDMI-A-1', 'hdr': 'yes'},
      {'output': 'HDMI-A-1', 'cm': 'hdr'},
      {'output': 'nope', 'scale': 1.0},
      {'output': 'HDMI-A-1', 'scale': 0},
    ]) {
      await expectLater(core.call('displays.store', bad), throwsA(isA<RouteError>()), reason: '$bad');
    }
    // the page's own `hdr` is not a displays.set field
    await expectLater(core.call('displays.set', {'output': 'HDMI-A-1', 'hdr': true}), throwsA(isA<RouteError>()));
  });

  test('the hypr-monitor command stores through the same route', () async {
    final out = _Sink();
    final code = await runCli(['hypr-monitor', 'HDMI-A-1', '{"disabled": false, "scale": 1.25}'], service: w.core(desktop: 'Hyprland'), out: out);
    expect(code, 0);
    expect(out.text, contains('hypr-monitor HDMI-A-1: kept'));
    expect(lua(), contains('scale = 1.25'));
    expect(await runCli(['hypr-monitor', 'HDMI-A-1', 'not json'], service: w.core(desktop: 'Hyprland'), out: _Sink()), 2);
  });

  test('input.get reads live values; input.set writes the input block (touchpad nested) and null takes a value out', () async {
    final core = w.core(desktop: 'Hyprland');
    final r = await core.call('input.get');
    expect((r['values'] as Map)['kb_layout'], 'de');
    expect((r['values'] as Map)['repeat_rate'], 35);
    expect(r['layouts'], ['de', 'us', 'fr']);
    expect(r['touchpad'], isFalse);
    await core.call('input.set', {'key': 'kb_layout', 'value': 'de,us'});
    await core.call('input.set', {'key': 'sensitivity', 'value': -0.5});
    await core.call('input.set', {'key': 'touchpad.tap_to_click', 'value': true});
    await core.call('input.set', {'key': 'kb_options', 'value': 'caps:escape,compose:ralt'});
    expect(lua(), contains('hl.config({\n    input = {\n        kb_layout = "de,us",\n        sensitivity = -0.5,\n        kb_options = "caps:escape,compose:ralt",\n        touchpad = {\n            tap_to_click = true,\n        },\n    },\n})'));
    await core.call('input.set', {'key': 'sensitivity', 'value': null});
    expect(lua(), isNot(contains('sensitivity')));
    for (final bad in [
      {'key': 'kb_layout', 'value': 'xx'},
      {'key': 'kb_layout', 'value': 'de"; os.execute("x'},
      {'key': 'repeat_rate', 'value': 500},
      {'key': 'sensitivity', 'value': 3},
      {'key': 'accel_profile', 'value': 'turbo'},
      {'key': 'kb_options', 'value': 'caps escape'},
      {'key': 'gestures', 'value': true},
    ]) {
      await expectLater(core.call('input.set', bad), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')), reason: '$bad');
    }
  });

  test('a touchpad is found by its name', () async {
    fakeHypr(w, touchpad: true);
    expect((await w.core(desktop: 'Hyprland').call('input.get'))['touchpad'], isTrue);
  });
}

final class _Sink implements IOSink {
  final _b = StringBuffer();
  String get text => _b.toString();
  @override
  void writeln([Object? o = '']) => _b.writeln(o);
  @override
  void write(Object? o) => _b.write(o);
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
