import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('skin defaults to native, persists non-native values, omits native on save, and rejects unknown values', () async {
    final world = World.create();
    addTearDown(world.dispose);
    final core = world.core();

    expect((await core.call('settings.get'))['skin'], 'native');

    for (final skin in ['synthwave', 'cozy', 'terminal', 'disco', 'zen']) {
      await core.call('settings.set', {'key': 'skin', 'value': skin});
      expect((await core.call('settings.get'))['skin'], skin);
      final raw = jsonDecode(File(world.paths.settingsFile).readAsStringSync()) as Map;
      expect(raw['skin'], skin);
    }

    await core.call('settings.set', {'key': 'skin', 'value': 'native'});
    expect((await core.call('settings.get'))['skin'], 'native');
    final afterNative = jsonDecode(File(world.paths.settingsFile).readAsStringSync()) as Map;
    expect(afterNative.containsKey('skin'), isFalse);

    await expectLater(
      core.call('settings.set', {'key': 'skin', 'value': 'invalid-skin'}),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')),
    );

    // Unknown stored value normalizes to native on read.
    File(world.paths.settingsFile).writeAsStringSync(jsonEncode({'skin': 'unknown'}));
    expect((await core.call('settings.get'))['skin'], 'native');
  });
}
