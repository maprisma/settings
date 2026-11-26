// The Voice page's core (voice.*) against a fake `maprisma-voice` on PATH: it is only ever run
// with argv lists, settings go through `set KEY <JSON>`, a download and a try run in the
// background with progress, partial text and Cancel. Nothing touches the real config.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';
import 'support.dart';

/// The fake: answers from `$HOME/voice/*`, every call logged to `$HOME/voice.log` (one JSON
/// argv per line). `$HOME/voice/slow` makes a download wait for `$HOME/voice/go`; a download
/// writes `<file>.part` in the service's model folder and renames it when done (`race`: done
/// before it exits).
const _fake = r'''#!/usr/bin/python3 -I
import json, os, sys, time
home = os.environ['HOME']
d = os.path.join(home, 'voice')
a = sys.argv[1:]
with open(os.path.join(home, 'voice.log'), 'a') as f:
    f.write(json.dumps(a) + '\n')
def read(name, default=None):
    path = os.path.join(d, name)
    return open(path).read() if os.path.exists(path) else default
if a[:1] == ['status']:
    s = read('status.json')
    if s is None:
        sys.stderr.write('The voice service is not running. (no bus)\n'); sys.exit(4)
    print(s); sys.exit(0)
if a == ['models', '--json']:
    print(read('models.json', '{"catalog": [], "models": [], "active": null}')); sys.exit(0)
if a == ['get']:
    print(read('settings.json', '{}')); sys.exit(0)
if a[:1] == ['set']:
    if a[1] in ('language', 'wake_language') and a[2] == '"xx"':
        sys.stderr.write('language: not a Whisper language code\n'); sys.exit(2)
    sys.exit(0)
if a[:1] == ['unset']:
    sys.exit(0)
if a[:2] == ['model', 'download']:
    if a[2] == 'bad':
        sys.stderr.write('##   3.0%\rthe download failed (exit status: 22)\n'); sys.exit(1)
    models = os.path.join(home, '.local/share/maprisma-voice/models')
    dest = os.path.join(models, 'ggml-' + a[2] + '.bin')
    os.makedirs(models, exist_ok=True)
    open(dest + '.part', 'w').write('partial')
    for pct in ('10.0', '45.5'):
        sys.stderr.write('#' * int(float(pct) / 5) + ' ' + pct + '%\r'); sys.stderr.flush(); time.sleep(0.05)
    if os.path.exists(os.path.join(d, 'race')):
        os.rename(dest + '.part', dest)  # done, but not exited yet when Cancel comes
    while os.path.exists(os.path.join(d, 'slow')) and not os.path.exists(os.path.join(d, 'go')):
        time.sleep(0.05)
    if os.path.exists(dest + '.part'):
        os.rename(dest + '.part', dest)
    print(dest); sys.exit(0)
if a[:2] == ['model', 'remove']:
    # as the service does it: the model and its .part
    dest = os.path.join(home, '.local/share/maprisma-voice/models', 'ggml-' + a[2] + '.bin')
    for path in (dest, dest + '.part'):
        if os.path.exists(path):
            os.remove(path)
    sys.exit(0)
if a[:2] == ['wake', 'test']:
    if os.path.exists(os.path.join(d, 'wake_nobus')):
        sys.stderr.write('The voice service is not running. (no bus)\n'); sys.exit(4)
    while os.path.exists(os.path.join(d, 'slow')) and not os.path.exists(os.path.join(d, 'go')):
        time.sleep(0.05)
    w = json.loads(read('wake.json', '{}'))
    print(json.dumps(w))
    sys.exit(0 if w.get('matched') else (3 if not w.get('speech') else 1))
if a[:1] == ['dictate']:
    secs = a[a.index('--seconds') + 1] if '--seconds' in a else '5'
    if os.path.exists(os.path.join(d, 'events_nospeech')):
        print(json.dumps({'event': 'started', 'session': 's1'}), flush=True)
        print(json.dumps({'event': 'level', 'rms': 0.004}), flush=True)
        print(json.dumps({'event': 'closed', 'reason': 'no_speech'}), flush=True)
        sys.exit(3)
    if os.path.exists(os.path.join(d, 'events_error')):
        print(json.dumps({'event': 'started', 'session': 's1'}), flush=True)
        print(json.dumps({'event': 'error', 'code': 'mic', 'message': 'Microphone unplugged'}), flush=True)
        print(json.dumps({'event': 'closed', 'reason': 'error'}), flush=True)
        sys.exit(1)
    if os.path.exists(os.path.join(d, 'events')):
        import select
        print(json.dumps({'event': 'started', 'session': 's1'}), flush=True)
        print(json.dumps({'event': 'state', 'state': 'listening'}), flush=True)
        print(json.dumps({'event': 'level', 'rms': 0.042}), flush=True)
        print(json.dumps({'event': 'partial', 'text': 'hello'}), flush=True)
        while os.path.exists(os.path.join(d, 'slow')) and not os.path.exists(os.path.join(d, 'go')):
            r, _, _ = select.select([sys.stdin], [], [], 0.05)
            if r:
                line = sys.stdin.readline()
                if line == '' or line.strip() == 'cancel':
                    print(json.dumps({'event': 'closed', 'reason': 'cancelled'}), flush=True)
                    sys.exit(1)
        print(json.dumps({'event': 'level', 'rms': 0.085}), flush=True)
        print(json.dumps({'event': 'level', 'rms': 0.020}), flush=True)
        print(json.dumps({'event': 'final', 'text': 'Hello from events.', 'typed': False, 'engine': 'whisper'}), flush=True)
        print(json.dumps({'event': 'closed', 'reason': 'finished'}), flush=True)
        sys.exit(0)
    sys.stderr.write('Listening for ' + secs + ' s…\n'); sys.stderr.flush()
    if os.path.exists(os.path.join(d, 'nospeech')):
        sys.stderr.write('No speech was heard.\n'); sys.exit(3)
    sys.stderr.write('… hello\n'); sys.stderr.flush()
    while os.path.exists(os.path.join(d, 'slow')) and not os.path.exists(os.path.join(d, 'go')):
        time.sleep(0.05)
    sys.stderr.write('… hello world\n')
    print('Hello world.'); sys.exit(0)
sys.exit(2)
''';

const _status = {
  'enabled': true, 'ready': true, 'why_not': '', 'message': 'Ready', 'engine': 'whisper', 'engine_setting': 'auto',
  'engines': ['whisper'], 'model': 'ggml-base.bin', 'models': ['ggml-base.bin'], 'language': 'auto', 'microphone': 'default',
  'state': 'idle', 'version': '0.1.0', 'typed_by_engine': false,
};

/// The service's catalog: base installed, the others not.
const _models = {
  'active': 'ggml-base.bin',
  'catalog': [
    {'id': 'base', 'file': 'ggml-base.bin', 'installed': true},
    {'id': 'small', 'file': 'ggml-small.bin', 'installed': false},
    {'id': 'turbo', 'file': 'ggml-turbo.bin', 'installed': false},
    {'id': 'bad', 'file': 'ggml-bad.bin', 'installed': false},
  ],
  'models': [],
};

void main() {
  late World w;
  setUp(() {
    w = World.create();
    fakePactl(w);
  });
  tearDown(() => w.dispose());

  void installFake({String? where}) => w.writeFile(where ?? p.join(w.fakeBin, 'maprisma-voice'), _fake, mode: '755');
  void answer(String name, Object value) => w.writeFile(p.join(w.home, 'voice', name), value is String ? value : jsonEncode(value));
  List<List<String>> calls() {
    final f = File(p.join(w.home, 'voice.log'));
    return f.existsSync() ? [for (final l in f.readAsLinesSync()) (jsonDecode(l) as List).cast<String>()] : const [];
  }

  String modelsDir() => p.join(w.home, '.local/share/maprisma-voice/models');

  Matcher refused(String code) => throwsA(isA<RouteError>().having((e) => e.code, 'code', code));

  Future<Map<String, dynamic>> settle(CoreService core, String kind) async {
    for (var i = 0; i < 200; i++) {
      final t = (await core.call('voice.tasks'))[kind] as Map<String, dynamic>?;
      if (t != null && t['state'] != 'running') return t;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('$kind did not end');
  }

  test('the catalog entry: Maprisma Dictation, its bar icon, install.sh', () {
    final a = findApp('dictation')!;
    expect(a.name, 'Maprisma Dictation');
    expect(a.inputs.single.repo, 'maprisma-dictation');
    expect(a.inputs.single.github, 'maprisma/dictation');
    expect(a.components.single.install, ['./install.sh']);
    expect(a.components.single.paths.where((x) => x.key).single.path, '{bin}/maprisma-voice');
    expect(a.open, ['{bin}/maprisma-dictation', '--toggle']);
    // The bar icon toggles the overlay: a COSMIC applet, the SNI tray on KDE and Hyprland.
    expect(a.bar.cosmicApplet, 'io.github.ubruckhaus.CosmicMaprismaDictation');
    expect(a.bar.cosmicAppletExe, '{bin}/maprisma-dictation-applet');
    expect(a.bar.kdeId, 'maprisma-dictation');
    expect(a.bar.kdeKind, KdeBarKind.tray);
    expect(a.bar.kdeAutostart, '{autostart}/io.github.ubruckhaus.CosmicMaprismaDictation.Tray.desktop');
    expect(a.bar.kdeTrayExe, '{bin}/maprisma-dictation-tray');
    expect(a.bar.iconName, 'io.github.ubruckhaus.CosmicMaprismaDictation-symbolic');
    expect(hyprBarId(a), 'tray:maprisma-dictation');
    final paths = a.components.single.paths.map((x) => x.path);
    expect(paths, containsAll([
      '{bin}/maprisma-dictation',
      '{bin}/maprisma-dictation-applet',
      '{bin}/maprisma-dictation-tray',
      '{apps}/io.github.ubruckhaus.CosmicMaprismaDictation.desktop',
      '{autostart}/io.github.ubruckhaus.CosmicMaprismaDictation.Tray.desktop',
      '{icons}/io.github.ubruckhaus.CosmicMaprismaDictation-symbolic.svg',
    ]));
    expect(a.processes.map((m) => m.path), containsAll(['{bin}/maprisma-voice', '{bin}/maprisma-dictation', '{bin}/maprisma-dictation-applet', '{bin}/maprisma-dictation-tray']));
    expect(a.units.single.name, 'maprisma-voice.service');
  });

  test('not installed: the page says where to get it; the microphones are listed anyway', () async {
    final r = await w.core().call('voice.get');
    expect(r['installed'], isFalse);
    expect(r['install_url'], 'https://github.com/maprisma/dictation');
    expect([for (final s in (r['microphones'] as Map)['sources'] as List) s['name']], ['mic']);
    await expectLater(w.core().call('voice.set', {'key': 'enabled', 'value': false}), refused('not_installed'));
    await expectLater(w.core().call('voice.try', {}), refused('not_installed'));
    await expectLater(w.core().call('voice.wake_test', {}), refused('not_installed'));
  });

  test('installed: status, models, settings and microphones in one answer', () async {
    installFake();
    answer('status.json', _status);
    answer('models.json', {'active': 'ggml-base.bin', 'catalog': [{'id': 'base', 'file': 'ggml-base.bin', 'installed': true}], 'models': []});
    answer('settings.json', {'language': 'de'});
    final r = await w.core().call('voice.get');
    expect(r['installed'], isTrue);
    expect(r['binary'], p.join(w.fakeBin, 'maprisma-voice'));
    expect((r['status'] as Map)['ready'], isTrue);
    expect(r['status_error'], isNull);
    expect((r['models'] as Map)['active'], 'ggml-base.bin');
    expect(r['settings'], {'language': 'de'});
    expect((r['microphones'] as Map)['default'], isNotNull);
    expect(r['tasks'], {'download': null, 'dictate': null, 'wake': null});
    expect(calls(), containsAll([
      ['status', '--json'],
      ['models', '--json'],
      ['get'],
    ]));
  });

  test('~/.local/bin/maprisma-voice comes before PATH', () async {
    installFake();
    final own = p.join(w.home, '.local/bin/maprisma-voice');
    installFake(where: own);
    expect(VoiceService(w.core().ctx, SoundService(w.core().ctx)).binary(), own);
  });

  test('the service not running: the status says why', () async {
    installFake();
    final r = await w.core().call('voice.get');
    expect(r['status'], isNull);
    expect(r['status_error'], 'The voice service is not running. (no bus)');
  });

  test('set passes the value as JSON; the service refuses wrong ones; unknown keys never reach it', () async {
    installFake();
    final core = w.core();
    await core.call('voice.set', {'key': 'enabled', 'value': false});
    await core.call('voice.set', {'key': 'language', 'value': 'de'});
    await core.call('voice.set', {'key': 'unload_minutes', 'value': 30});
    await core.call('voice.set', {'key': 'microphone', 'value': 'alsa_input.usb-Mic'});
    await core.call('voice.unset', {'key': 'model'});
    await expectLater(core.call('voice.set', {'key': 'language', 'value': 'xx'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'whisper_server', 'value': '/tmp/x'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'enabled', 'value': 'yes'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'unload_minutes', 'value': -1}), refused('bad_params'));
    await expectLater(core.call('voice.unset', {'key': 'ui_language'}), refused('bad_params'));
    expect(calls(), [
      ['set', 'enabled', 'false'],
      ['set', 'language', '"de"'],
      ['set', 'unload_minutes', '30'],
      ['set', 'microphone', '"alsa_input.usb-Mic"'],
      ['unset', 'model'],
      ['set', 'language', '"xx"'],
    ]);
  });

  test('a download runs in the background with its percent and ends with the path', () async {
    installFake();
    answer('models.json', _models);
    answer('slow', '');
    final core = w.core();
    final started = await core.call('voice.download', {'model': 'small'});
    expect((started['task'] as Map)['state'], 'running');
    await expectLater(core.call('voice.download', {'model': 'base'}), refused('busy'));
    await expectLater(core.call('voice.remove', {'model': 'small'}), refused('busy'));
    // the progress shows while it waits
    for (var i = 0; i < 100 && ((await core.call('voice.tasks'))['download'] as Map)['progress'] != 45.5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(((await core.call('voice.tasks'))['download'] as Map)['progress'], 45.5);
    answer('go', '');
    final t = await settle(core, 'download');
    expect(t['state'], 'succeeded');
    expect(t['progress'], 100);
    expect(t['path'], endsWith('ggml-small.bin'));
    expect(calls().where((c) => c[0] == 'model'), [
      ['model', 'download', 'small'],
    ]);
  });

  test('a failed download says why; bad names are refused', () async {
    installFake();
    answer('models.json', _models);
    final core = w.core();
    await core.call('voice.download', {'model': 'bad'});
    final t = await settle(core, 'download');
    expect(t['state'], 'failed');
    expect(t['message'], 'the download failed (exit status: 22)');
    await expectLater(core.call('voice.download', {'model': '../x'}), refused('bad_params'));
    await expectLater(core.call('voice.download', {'model': '-rf'}), refused('bad_params'));
    await expectLater(core.call('voice.remove', {'model': 'a b'}), refused('bad_params'));
  });

  test('Cancel ends a download and removes only its .part (never `model remove`)', () async {
    installFake();
    answer('models.json', _models);
    answer('slow', '');
    // another model, and a stranger's .part, stay
    w.writeFile(p.join(modelsDir(), 'ggml-base.bin'), 'model');
    w.writeFile(p.join(modelsDir(), 'ggml-small.bin.part'), 'other');
    final core = w.core();
    await core.call('voice.download', {'model': 'turbo'});
    final part = File(p.join(modelsDir(), 'ggml-turbo.bin.part'));
    for (var i = 0; i < 100 && !part.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(part.existsSync(), isTrue);
    await core.call('voice.cancel', {'kind': 'download'});
    final t = await settle(core, 'download');
    expect(t['state'], 'cancelled');
    expect(part.existsSync(), isFalse);
    expect(File(p.join(modelsDir(), 'ggml-base.bin')).readAsStringSync(), 'model');
    expect(File(p.join(modelsDir(), 'ggml-small.bin.part')).readAsStringSync(), 'other');
    expect(calls().where((c) => c[0] == 'model' && c[1] == 'remove'), isEmpty);
    await expectLater(core.call('voice.cancel', {'kind': 'download'}), refused('finished'));
    await expectLater(core.call('voice.cancel', {'kind': 'x'}), refused('bad_params'));
  });

  test('Cancel just after the model was renamed into place keeps the model', () async {
    installFake();
    answer('models.json', _models);
    answer('slow', '');
    answer('race', '');
    final core = w.core();
    await core.call('voice.download', {'model': 'turbo'});
    final model = File(p.join(modelsDir(), 'ggml-turbo.bin'));
    for (var i = 0; i < 100 && !model.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(model.existsSync(), isTrue);
    await core.call('voice.cancel', {'kind': 'download'});
    expect((await settle(core, 'download'))['state'], 'cancelled');
    expect(model.readAsStringSync(), 'partial');
  });

  test('an installed model or one outside the catalog is not downloaded', () async {
    installFake();
    answer('models.json', _models);
    final core = w.core();
    await expectLater(core.call('voice.download', {'model': 'base'}), refused('exists'));
    await expectLater(core.call('voice.download', {'model': 'medium'}), refused('bad_params'));
    answer('models.json', {'catalog': [{'id': 'evil', 'file': '../../x.bin', 'installed': false}]});
    await expectLater(core.call('voice.download', {'model': 'evil'}), refused('bad_params'));
    expect(calls().where((c) => c[0] == 'model'), isEmpty);
    expect((await core.call('voice.tasks'))['download'], isNull);
  });

  test('remove goes to the service', () async {
    installFake();
    await w.core().call('voice.remove', {'model': 'base'});
    expect(calls(), [['model', 'remove', 'base']]);
  });

  test('Try it: partial text while listening, then the final text', () async {
    installFake();
    answer('status.json', _status);
    answer('slow', '');
    final core = w.core();
    await core.call('voice.try', {});
    await expectLater(core.call('voice.try', {}), refused('busy'));
    for (var i = 0; i < 100 && ((await core.call('voice.tasks'))['dictate'] as Map)['partial'] != 'hello'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(((await core.call('voice.tasks'))['dictate'] as Map)['partial'], 'hello');
    answer('go', '');
    final t = await settle(core, 'dictate');
    expect(t['state'], 'succeeded');
    expect(t['text'], 'Hello world.');
    expect(t['partial'], 'hello world');
    expect(t['seconds'], 5);
    expect(calls().last, ['dictate', '--events', '--seconds', '5']);
    await expectLater(core.call('voice.try', {'seconds': 0}), refused('bad_params'));
    await expectLater(core.call('voice.try', {'seconds': '5'}), refused('bad_params'));
  });

  test('Try it without speech: the service\'s reason', () async {
    installFake();
    answer('status.json', _status);
    answer('nospeech', '');
    final core = w.core();
    await core.call('voice.try', {'seconds': 3});
    final t = await settle(core, 'dictate');
    expect(t['state'], 'failed');
    expect(t['message'], 'No speech was heard.');
    expect(t['text'], '');
  });

  test('a try can be cancelled', () async {
    installFake();
    answer('status.json', _status);
    answer('slow', '');
    final core = w.core();
    await core.call('voice.try', {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await core.call('voice.cancel', {'kind': 'dictate'});
    expect((await settle(core, 'dictate'))['state'], 'cancelled');
  });

  test('Try it is refused with an engine that types itself, or without a status', () async {
    installFake();
    final core = w.core();
    await expectLater(core.call('voice.try', {}), refused('unavailable'));
    answer('status.json', {..._status, 'engine': 'voxtype', 'typed_by_engine': true});
    await expectLater(core.call('voice.try', {}), refused('unavailable'));
    // an older service without the field: not tried either
    answer('status.json', {..._status}..remove('typed_by_engine'));
    await expectLater(core.call('voice.try', {}), refused('unavailable'));
    expect(calls().where((c) => c[0] == 'dictate'), isEmpty);
    expect((await core.call('voice.tasks'))['dictate'], isNull);
  });

  test('the wake phrase settings: checked like the service, then passed as JSON', () async {
    installFake();
    final core = w.core();
    await core.call('voice.set', {'key': 'wake_enabled', 'value': true});
    await core.call('voice.set', {'key': 'wake_phrase', 'value': 'Hallo Rechner'});
    await core.call('voice.set', {'key': 'wake_phrase', 'value': "Hey, Linux! Ça va?"});
    await core.call('voice.set', {'key': 'wake_language', 'value': 'de'});
    await core.call('voice.set', {'key': 'wake_model', 'value': 'ggml-base.bin'});
    await core.call('voice.set', {'key': 'wake_model', 'value': ''});
    await core.call('voice.set', {'key': 'wake_sensitivity', 'value': 'loose'});
    await core.call('voice.unset', {'key': 'wake_language'});
    for (final bad in ['H', ' Hey Linux', 'Hey Linux ', 'Hey "Linux"', 'Hey; rm', '!!', 'a!', 'x' * 41, 'Hey\nLinux']) {
      await expectLater(core.call('voice.set', {'key': 'wake_phrase', 'value': bad}), refused('bad_params'), reason: bad);
    }
    await expectLater(core.call('voice.set', {'key': 'wake_enabled', 'value': 'true'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'wake_sensitivity', 'value': 'medium'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'wake_language', 'value': 'Deutsch'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'wake_model', 'value': '../x.bin'}), refused('bad_params'));
    // the service has the last word
    await expectLater(core.call('voice.set', {'key': 'wake_language', 'value': 'xx'}), refused('bad_params'));
    expect(calls(), [
      ['set', 'wake_enabled', 'true'],
      ['set', 'wake_phrase', '"Hallo Rechner"'],
      ['set', 'wake_phrase', jsonEncode("Hey, Linux! Ça va?")],
      ['set', 'wake_language', '"de"'],
      ['set', 'wake_model', '"ggml-base.bin"'],
      ['set', 'wake_model', '""'],
      ['set', 'wake_sensitivity', '"loose"'],
      ['unset', 'wake_language'],
      ['set', 'wake_language', '"xx"'],
    ]);
  });

  test('validWakePhrase is the service\'s rule', () {
    expect(VoiceService.validWakePhrase('Hey Linux'), isTrue);
    expect(VoiceService.validWakePhrase('OK Computer-2'), isTrue);
    expect(VoiceService.validWakePhrase('Grüß dich'), isTrue);
    expect(VoiceService.validWakePhrase('ab'), isTrue);
    expect(VoiceService.validWakePhrase('a.'), isFalse);
    expect(VoiceService.validWakePhrase(''), isFalse);
    expect(VoiceService.validWakePhrase('Hey  Linux'), isTrue);
    expect(VoiceService.validWakePhrase('Hey_Linux'), isFalse);
    expect(VoiceService.validWakePhrase('x' * 40), isTrue);
    expect(VoiceService.validWakePhrase('x' * 41), isFalse);
  });

  test('voice.status: only the status, or why there is none', () async {
    installFake();
    final core = w.core();
    expect(await core.call('voice.status'), {'status': null, 'status_error': 'The voice service is not running. (no bus)'});
    answer('status.json', {..._status, 'wake_enabled': true, 'wake_active': true, 'wake_why_not': ''});
    final r = await core.call('voice.status');
    expect((r['status'] as Map)['wake_active'], isTrue);
    expect(calls(), [['status', '--json'], ['status', '--json']]);
  });

  test('Try the phrase: wake test in the background, the answer as result', () async {
    installFake();
    answer('slow', '');
    answer('wake.json', {'heard': 'Hey Linux, open Firefox.', 'matched': true, 'score': 0.93, 'needed': 0.75, 'rest': 'open Firefox', 'phrase': 'Hey Linux', 'model': 'ggml-base.bin', 'speech': true});
    final core = w.core();
    final started = await core.call('voice.wake_test', {'seconds': 8});
    expect((started['task'] as Map)['state'], 'running');
    expect((started['task'] as Map)['seconds'], 8);
    await expectLater(core.call('voice.wake_test', {}), refused('busy'));
    await expectLater(core.call('voice.try', {}), refused('busy'));
    answer('go', '');
    final t = await settle(core, 'wake');
    expect(t['state'], 'succeeded');
    expect((t['result'] as Map)['matched'], isTrue);
    expect((t['result'] as Map)['rest'], 'open Firefox');
    expect(calls().where((c) => c[0] == 'wake'), [['wake', 'test', '--seconds', '8', '--json']]);
    // the default length is 8 s; 1–10 only
    await core.call('voice.wake_test', {});
    await settle(core, 'wake');
    expect(calls().last, ['wake', 'test', '--seconds', '8', '--json']);
    for (final bad in [0, 11, '8', 2.5]) {
      await expectLater(core.call('voice.wake_test', {'seconds': bad}), refused('bad_params'));
    }
  });

  test('Try the phrase: no match and no speech still give the answer; no service fails', () async {
    installFake();
    final core = w.core();
    answer('wake.json', {'heard': 'Hallo Welt', 'matched': false, 'score': 0.41, 'needed': 0.75, 'rest': '', 'phrase': 'Hey Linux', 'model': 'ggml-base.bin', 'speech': true});
    await core.call('voice.wake_test', {'seconds': 2});
    var t = await settle(core, 'wake');
    expect(t['state'], 'succeeded');
    expect((t['result'] as Map)['matched'], isFalse);
    answer('wake.json', {'heard': '', 'matched': false, 'score': 0.0, 'needed': 0.75, 'rest': '', 'phrase': 'Hey Linux', 'model': '', 'speech': false});
    await core.call('voice.wake_test', {'seconds': 2});
    t = await settle(core, 'wake');
    expect(t['state'], 'succeeded');
    expect((t['result'] as Map)['speech'], isFalse);
    answer('wake_nobus', '');
    await core.call('voice.wake_test', {'seconds': 2});
    t = await settle(core, 'wake');
    expect(t['state'], 'failed');
    expect(t['message'], 'The voice service is not running. (no bus)');
    expect(t['result'], isNull);
  });

  test('Try the phrase can be cancelled; a dictation try blocks it', () async {
    installFake();
    answer('status.json', _status);
    answer('slow', '');
    final core = w.core();
    await core.call('voice.wake_test', {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await core.call('voice.cancel', {'kind': 'wake'});
    expect((await settle(core, 'wake'))['state'], 'cancelled');
    await core.call('voice.try', {});
    await expectLater(core.call('voice.wake_test', {}), refused('busy'));
    await core.call('voice.cancel', {'kind': 'dictate'});
    await settle(core, 'dictate');
  });

  test('microphones: no monitors; without pactl none', () async {
    final m = await SoundService(w.core().ctx).microphones();
    expect([for (final s in m['sources'] as List) s['name']], ['mic']);
    File(p.join(w.fakeBin, 'pactl')).deleteSync();
    expect(await SoundService(w.core().ctx).microphones(), {'default': null, 'sources': const []});
  });

  test('v0.3.0 audio filtering settings: noise_filter, vad_sensitivity, hallucination_filter', () async {
    installFake();
    final core = w.core();
    for (final nf in VoiceService.noiseFilters) {
      await core.call('voice.set', {'key': 'noise_filter', 'value': nf});
    }
    for (final vs in VoiceService.vadSensitivities) {
      await core.call('voice.set', {'key': 'vad_sensitivity', 'value': vs});
    }
    await core.call('voice.set', {'key': 'hallucination_filter', 'value': true});
    await core.call('voice.set', {'key': 'hallucination_filter', 'value': false});
    await core.call('voice.unset', {'key': 'noise_filter'});
    await expectLater(core.call('voice.set', {'key': 'noise_filter', 'value': 'ultra'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'noise_filter', 'value': true}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'vad_sensitivity', 'value': 'loose'}), refused('bad_params'));
    await expectLater(core.call('voice.set', {'key': 'hallucination_filter', 'value': 'yes'}), refused('bad_params'));
    expect(calls(), [
      ['set', 'noise_filter', '"off"'],
      ['set', 'noise_filter', '"standard"'],
      ['set', 'noise_filter', '"strong"'],
      ['set', 'vad_sensitivity', '"strict"'],
      ['set', 'vad_sensitivity', '"normal"'],
      ['set', 'vad_sensitivity', '"sensitive"'],
      ['set', 'hallucination_filter', 'true'],
      ['set', 'hallucination_filter', 'false'],
      ['unset', 'noise_filter'],
    ]);
  });

  test('PipeWire noise-cancelling mic: both plugins required, restart polling, no-op skip, symlinked XDG_CONFIG_HOME, systemctl failure, mic reset', () async {
    installFake();
    answer('status.json', _status);
    w.fake('systemctl', r'''
echo "$*" >> "$HOME/systemctl.log"
if [ -f "$HOME/systemctl-fail" ]; then
  echo "Failed to connect to bus" >&2
  exit 1
fi
if [ -f "$HOME/systemctl-spawn-mic" ]; then
  /usr/bin/python3 -c '
import json, os, time
time.sleep(0.04)
p = os.path.join(os.environ["HOME"], "pactl/sources.json")
s = json.load(open(p))
s.append({"index": 99, "name": "maprisma.noise_cancel_source", "description": "Maprisma Noise-Cancelling Mic", "monitor_source": "", "mute": False, "volume": {}})
json.dump(s, open(p, "w"))
' >/dev/null 2>&1 &
fi
''');
    final core = w.core();
    core.voice.noiseCancelPollInterval = const Duration(milliseconds: 20);
    core.voice.noiseCancelPollTimeout = const Duration(milliseconds: 500);

    // Module absent -> unavailable; only echo-cancel without WebRTC SPA -> still unavailable (H2)
    expect((await core.call('voice.get'))['noise_cancel'], {'available': false, 'enabled': false, 'active': false});
    w.writeFile(p.join(w.root, 'usr/lib/x86_64-linux-gnu/pipewire-0.3/libpipewire-module-echo-cancel.so'), '');
    expect((await core.call('voice.get'))['noise_cancel'], {'available': false, 'enabled': false, 'active': false});
    await expectLater(core.call('voice.noise_cancel', {'enabled': true}), refused('unavailable'));
    await expectLater(core.call('voice.noise_cancel', {'enabled': 'yes'}), refused('bad_params'));
    await expectLater(core.call('voice.noise_cancel', {'enabled': true, 'apply': 'yes'}), refused('bad_params'));

    // Install WebRTC SPA plugin too -> now available (supports multiarch dirs)
    w.writeFile(p.join(w.root, 'usr/lib/x86_64-linux-gnu/spa-0.2/aec/libspa-aec-webrtc.so'), '');
    expect((await core.call('voice.get'))['noise_cancel'], {'available': true, 'enabled': false, 'active': false});

    // Enable with apply: true -> writes 0644 config, restarts PipeWire, polls until virtual mic appears (H3)
    w.writeFile(p.join(w.home, 'systemctl-spawn-mic'), '');
    final enabled = await core.call('voice.noise_cancel', {'enabled': true, 'apply': true});
    expect(enabled['applied'], isTrue);
    expect(enabled['enabled'], isTrue);
    expect(enabled['active'], isTrue);
    expect(enabled['noise_cancel'], {'available': true, 'enabled': true, 'active': true});
    final conf = File(p.join(w.home, '.config/pipewire/pipewire.conf.d/50-maprisma-noise-cancel.conf'));
    expect(conf.existsSync(), isTrue);
    expect(conf.statSync().mode & 0x1ff, 0x1a4); // 0644
    final content = conf.readAsStringSync();
    expect(content, contains('libpipewire-module-echo-cancel'));
    expect(content, contains('aec/libspa-aec-webrtc'));
    expect(content, contains('maprisma.noise_cancel_source'));
    expect(content, contains('Maprisma Noise-Cancelling Mic'));
    expect(File(p.join(w.home, 'systemctl.log')).readAsLinesSync(), ['--user restart pipewire wireplumber']);

    // Calling enable again when config is already identical skips restarting PipeWire (L5)
    final noop = await core.call('voice.noise_cancel', {'enabled': true, 'apply': true});
    expect(noop['applied'], isFalse);
    expect(File(p.join(w.home, 'systemctl.log')).readAsLinesSync(), ['--user restart pipewire wireplumber']);

    // Disabling resets selected microphone from maprisma.noise_cancel_source to default (M5)
    // and reports a graceful message if systemctl fails (L3)
    answer('settings.json', {'microphone': 'maprisma.noise_cancel_source'});
    w.writeFile(p.join(w.home, 'systemctl-fail'), '');
    final disabled = await core.call('voice.noise_cancel', {'enabled': false, 'apply': true});
    expect(disabled['applied'], isFalse);
    expect(disabled['enabled'], isFalse);
    expect(disabled['message'], contains('Failed to connect to bus'));
    expect(conf.existsSync(), isFalse);
    expect(calls(), contains(equals(['set', 'microphone', '"default"'])));

    // Symlink safety: never follow symlink at config file or subdirectory
    final victim = File(p.join(w.home, 'victim.txt'))..writeAsStringSync('keep');
    Link(conf.path).createSync(victim.path);
    expect((await core.call('voice.get'))['noise_cancel'], {'available': true, 'enabled': false, 'active': true});
    await expectLater(core.call('voice.noise_cancel', {'enabled': false}), refused('failed'));
    await expectLater(core.call('voice.noise_cancel', {'enabled': true}), refused('failed'));
    expect(victim.readAsStringSync(), 'keep');
    Link(conf.path).deleteSync();
    Directory(p.join(w.home, '.config/pipewire/pipewire.conf.d')).deleteSync();
    Link(p.join(w.home, '.config/pipewire/pipewire.conf.d')).createSync(w.home);
    await expectLater(core.call('voice.noise_cancel', {'enabled': true}), refused('failed'));

    // Symlinked XDG_CONFIG_HOME itself (dotfile managers) IS allowed (M3)
    final realCfg = Directory(p.join(w.dir, 'dotfiles-config'))..createSync(recursive: true);
    final linkedCfg = p.join(w.dir, 'linked-config');
    Link(linkedCfg).createSync(realCfg.path);
    final dotCore = w.core(extra: {'XDG_CONFIG_HOME': linkedCfg});
    final dotRes = await dotCore.call('voice.noise_cancel', {'enabled': true, 'apply': false});
    expect(dotRes['enabled'], isTrue);
    expect(File(p.join(realCfg.path, 'pipewire/pipewire.conf.d/50-maprisma-noise-cancel.conf')).existsSync(), isTrue);
  });

  test('Try it (--events): streams live level, peak, partial and final, nullable before first level, graceful cancel, handles no_speech & error', () async {
    installFake();
    answer('status.json', _status);
    answer('events', '');
    answer('slow', '');
    final core = w.core();
    final started = await core.call('voice.try', {'seconds': 6});
    // U2: level and peak start as null until a real level JSON event arrives
    expect((started['task'] as Map)['level'], isNull);
    expect((started['task'] as Map)['peak'], isNull);
    // Live level and partial update while running (and stdin stays open so it doesn't cancel!)
    for (var i = 0; i < 100 && ((await core.call('voice.tasks'))['dictate'] as Map)['partial'] != 'hello'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final live = (await core.call('voice.tasks'))['dictate'] as Map;
    expect(live['state'], 'running');
    expect(live['partial'], 'hello');
    expect(live['level'], closeTo(0.042, 0.0001));
    expect(live['peak'], closeTo(0.042, 0.0001));
    // Let it finish
    answer('go', '');
    final done = await settle(core, 'dictate');
    expect(done['state'], 'succeeded');
    expect(done['text'], 'Hello from events.');
    expect(done['level'], closeTo(0.020, 0.0001));
    expect(done['peak'], closeTo(0.085, 0.0001));

    // Graceful cancel via stdin ("cancel\n" + EOF) exits cleanly before SIGTERM grace (M2)
    File(p.join(w.home, 'voice/go')).deleteSync();
    await core.call('voice.try', {'seconds': 5});
    for (var i = 0; i < 100 && ((await core.call('voice.tasks'))['dictate'] as Map)['partial'] != 'hello'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await core.call('voice.cancel', {'kind': 'dictate'});
    expect((await settle(core, 'dictate'))['state'], 'cancelled');

    // no_speech closed event -> empty text, succeeds cleanly so UI says "Nothing was heard"
    File(p.join(w.home, 'voice/events')).deleteSync();
    File(p.join(w.home, 'voice/slow')).deleteSync();
    answer('events_nospeech', '');
    await core.call('voice.try', {'seconds': 5});
    final ns = await settle(core, 'dictate');
    expect(ns['state'], 'succeeded');
    expect(ns['text'], '');
    expect(ns['peak'], closeTo(0.004, 0.0001));

    // error event -> failed with error message
    File(p.join(w.home, 'voice/events_nospeech')).deleteSync();
    answer('events_error', '');
    await core.call('voice.try', {'seconds': 5});
    final er = await settle(core, 'dictate');
    expect(er['state'], 'failed');
    expect(er['message'], 'Microphone unplugged');
  });
}
