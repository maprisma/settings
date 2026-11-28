// The Voice page against fake core answers (voice.*): the status, the engine drop-down with
// unavailable engines disabled, the settings it writes, a model download with progress and
// Cancel, Remove, Use, Try it with partial and final text, and the note when Maprisma
// Dictation is missing; the wake phrase card (its settings, the live line, Try the phrase).
// `--page voice` opens it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app.dart';
import 'package:maprisma_manager/home.dart';
import 'package:maprisma_manager/voice_page.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:maprisma_ui/settings.dart' show SettingsToggle;

import 'page_shots.dart';

const _dark = {'background': '#1a2234', 'foreground': '#cdd6ee', 'accent': '#4dd6c8', 'muted': '#a0a9c0', 'green': '#7fd88f', 'red': '#f38ba8'};

Map<String, dynamic> _status({bool ready = true, List<String> engines = const ['whisper']}) => {
  'enabled': true, 'ready': ready, 'why_not': ready ? '' : 'no_model', 'message': ready ? 'Ready' : 'No Whisper model is installed.',
  'engine': 'whisper', 'engine_setting': 'auto', 'engines': engines, 'model': 'ggml-large-v3-turbo-q5_0.bin',
  'language': 'auto', 'microphone': 'default', 'state': 'idle', 'version': '0.1.0', 'typed_by_engine': false,
};

Map<String, dynamic> _wakeStatus({required bool enabled, bool active = false, String? why}) => {
  ..._status(),
  'wake_enabled': enabled,
  'wake_active': active,
  'wake_phrase': 'Hey Linux',
  'wake_why_not': why ?? (enabled ? '' : 'off'),
  'wake_message': '',
};

Map<String, dynamic> _models() => {
  'active': 'ggml-large-v3-turbo-q5_0.bin',
  'folder': '/home/u/.local/share/maprisma-voice/models',
  'catalog': [
    {'id': 'base', 'file': 'ggml-base.bin', 'installed': true, 'label': 'Whisper base (148 MB · fast, any PC)', 'size': 147951465},
    {'id': 'small', 'file': 'ggml-small.bin', 'installed': false, 'label': 'Whisper small (488 MB · balanced)', 'size': 487601967},
    {'id': 'turbo', 'file': 'ggml-large-v3-turbo-q5_0.bin', 'installed': true, 'label': 'Whisper large-v3-turbo (574 MB · best accuracy)', 'size': 574041195},
  ],
  'models': [
    {'name': 'ggml-base.bin', 'managed': true, 'active': false, 'path': '/home/u/.local/share/maprisma-voice/models/ggml-base.bin', 'size': 147951465},
    {'name': 'ggml-large-v3-turbo-q5_0.bin', 'managed': true, 'active': true, 'path': '/home/u/.local/share/maprisma-voice/models/ggml-large-v3-turbo-q5_0.bin', 'size': 574041195},
    {'name': 'ggml-medium.bin', 'managed': false, 'active': false, 'path': '/home/u/.local/share/voxtype/models/ggml-medium.bin', 'size': 1500000000},
  ],
};

Map<String, dynamic> _get({
  bool installed = true,
  bool ready = true,
  Map<String, dynamic>? status,
  Map<String, dynamic> settings = const {},
  Map<String, dynamic>? noiseCancel,
}) => installed
    ? {
        'installed': true,
        'binary': '/home/u/.local/bin/maprisma-voice',
        'install_url': 'https://github.com/maprisma/dictation',
        'status': status ?? _status(ready: ready),
        'status_error': null,
        'models': _models(),
        'settings': settings,
        'microphones': {
          'default': 'alsa_input.usb-Mic',
          'sources': [
            {'name': 'alsa_input.usb-Mic', 'description': 'USB Microphone'},
            {'name': 'alsa_input.pci-analog', 'description': 'Built-in Audio'},
          ],
        },
        'noise_cancel': noiseCancel ?? const {'available': false, 'enabled': false, 'active': false},
        'tasks': {'download': null, 'dictate': null},
      }
    : {'installed': false, 'binary': null, 'install_url': 'https://github.com/maprisma/dictation', 'microphones': {'default': null, 'sources': []}, 'noise_cancel': const {'available': false, 'enabled': false, 'active': false}, 'tasks': {'download': null, 'dictate': null}};

/// A fake core: voice.get answers [answer]; download and try move on with every voice.tasks.
class _Fake {
  _Fake(this.answer);
  Map<String, dynamic> answer;
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic>? download, dictate, wake;
  int polls = 0, wakePolls = 0;

  /// What voice.wake_test ends with, and what voice.status answers.
  Map<String, dynamic> wakeResult = {'heard': 'Hey Linux, open Firefox.', 'matched': true, 'score': 0.93, 'needed': 0.75, 'rest': 'open Firefox', 'phrase': 'Hey Linux', 'model': 'ggml-base.bin', 'speech': true};
  Map<String, dynamic>? liveStatus;

  /// Optional blocker on voice.tasks to test non-overlapping poll behavior (M1).
  Completer<void>? holdTasks;
  int activeTaskCalls = 0, maxConcurrentTaskCalls = 0;

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    switch (method) {
      case 'settings.get':
        return {'language': 'en'};
      case 'apps.list':
        return {'apps': <Object>[], 'desktop': 'cosmic'};
      case 'jobs.list':
        return {'jobs': <Object>[]};
      case 'voice.get':
        return {...answer, 'tasks': {'download': download, 'dictate': dictate, 'wake': wake}};
      case 'voice.status':
        return {'status': liveStatus ?? answer['status'], 'status_error': null};
      case 'voice.wake_test':
        wake = {'kind': 'wake', 'state': 'running', 'seconds': params['seconds'], 'result': null};
        return {'task': wake};
      case 'voice.download':
        download = {'kind': 'download', 'state': 'running', 'model': params['model'], 'progress': null};
        return {'task': download};
      case 'voice.try':
        dictate = {'kind': 'dictate', 'state': 'running', 'seconds': params['seconds'], 'partial': '', 'text': '', 'level': null, 'peak': null};
        return {'task': dictate};
      case 'voice.cancel':
        if (params['kind'] == 'download') download = {...?download, 'state': 'cancelled'};
        if (params['kind'] == 'dictate') dictate = {...?dictate, 'state': 'cancelled'};
        if (params['kind'] == 'wake') wake = {...?wake, 'state': 'cancelled'};
        return {};
      case 'voice.tasks':
        activeTaskCalls++;
        if (activeTaskCalls > maxConcurrentTaskCalls) maxConcurrentTaskCalls = activeTaskCalls;
        try {
          if (holdTasks != null) await holdTasks!.future;
          polls++;
          if (download?['state'] == 'running') download = {...download!, 'progress': 42.0};
          if (dictate?['state'] == 'running') {
            if (polls == 1) {
              // ~ -46 dB -> Quiet / noise floor
              dictate = {...dictate!, 'partial': '', 'level': 0.005, 'peak': 0.005};
            } else if (polls == 2) {
              // ~ -18 dB -> Voice detected (70% bar)
              dictate = {...dictate!, 'partial': 'hallo', 'level': 0.1259, 'peak': 0.1259};
            } else if (polls == 3) {
              // ~ -12 dB -> Loud (80% bar, amber)
              dictate = {...dictate!, 'partial': 'hallo', 'level': 0.2512, 'peak': 0.2512};
            } else if (polls == 4) {
              // ~ -4 dB -> Too loud (93% bar, red)
              dictate = {...dictate!, 'partial': 'hallo', 'level': 0.6310, 'peak': 0.6310};
            } else {
              dictate = {...dictate!, 'state': 'succeeded', 'partial': 'hallo welt', 'text': 'Hallo Welt.', 'level': 0.05, 'peak': 0.6310};
            }
          }
          if (wake?['state'] == 'running' && ++wakePolls >= 3) wake = {...wake!, 'state': 'succeeded', 'result': wakeResult};
          return {'download': download, 'dictate': dictate, 'wake': wake};
        } finally {
          activeTaskCalls--;
        }
      default:
        return {};
    }
  }

  List<Map<String, dynamic>> of(String method) => [for (final c in calls) if (c.$1 == method) c.$2];
}

void main() {
  setUpAll(loadShotFonts);
  setUp(() => configureLanguage('en'));

  Future<_Fake> open(WidgetTester tester, Map<String, dynamic> answer) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = _Fake(answer);
    await tester.pumpWidget(ManagerApp(core: fake.call, look: const {'colors': _dark}, checkOnStart: false, relook: null, page: 'voice'));
    await tester.pumpAndSettle();
    return fake;
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
  }

  Future<void> pick(WidgetTester tester, String key, String label) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byWidgetPredicate((w) => w is DropdownButton)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  test('the sidebar knows the Voice page by name, after AI', () {
    expect(ManagerHomeState.sectionNamed('voice'), Section.voice);
    expect(ManagerHomeState.name(Section.voice), 'Voice');
    expect(Section.values.indexOf(Section.voice), Section.values.indexOf(Section.ai) + 1);
  });

  test('engines: Automatic naming the one in use; unavailable ones disabled with why', () {
    final s = _status(engines: ['whisper', 'online']);
    expect(VoicePageState.engineChoices(s), [
      ('auto', 'Automatic (Local Whisper)'),
      ('whisper', 'Local Whisper'),
      ('online', 'Online'),
      ('voxtype', 'Voxtype · not installed'),
      ('superwhisper', 'Superwhisper · not installed'),
      ('omarchy', 'Omarchy · not installed'),
    ]);
    expect(VoicePageState.enginesOff(s), {'voxtype', 'superwhisper', 'omarchy'});
    // the saved engine stays selectable
    expect(VoicePageState.enginesOff({...s, 'engine_setting': 'voxtype'}), {'superwhisper', 'omarchy'});
    expect(VoicePageState.languageChoices('sv').map((c) => c.$1), ['auto', 'de', 'en', 'fr', 'es', 'it', 'pt', 'nl', 'pl', 'sv', '*']);
  });

  testWidgets('ready: status, settings, models and Try it', (tester) async {
    await open(tester, _get(settings: {'unload_minutes': 10}));
    expect(find.byKey(const ValueKey('voice-page')), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('Engine: Local Whisper'), findsOneWidget);
    expect(find.text('Automatic (Local Whisper)'), findsOneWidget);
    expect(find.text('Default (USB Microphone)'), findsOneWidget);
    expect(find.text('After 10 minutes'), findsOneWidget);
    expect(find.text('Whisper small (488 MB · balanced)'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-download-small')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-remove-base')), findsOneWidget);
    expect(find.text('In use'), findsOneWidget);
    // not ours: Use, but no Remove
    expect(find.byKey(const ValueKey('voice-use-ggml-medium.bin')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-remove-ggml-medium.bin')), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'page-voice');
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings go to voice.set with their types', (tester) async {
    final fake = await open(tester, _get());
    await tapKey(tester, 'voice-enabled');
    await tester.pumpAndSettle();
    await pick(tester, 'voice-language', 'Deutsch');
    await pick(tester, 'voice-microphone', 'Built-in Audio');
    await pick(tester, 'voice-unload', 'Never');
    await tapKey(tester, 'voice-preload');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-use-ggml-base.bin')));
    await tester.pumpAndSettle();
    expect(fake.of('voice.set'), [
      {'key': 'enabled', 'value': false},
      {'key': 'language', 'value': 'de'},
      {'key': 'microphone', 'value': 'alsa_input.pci-analog'},
      {'key': 'unload_minutes', 'value': 0},
      {'key': 'preload', 'value': true},
      {'key': 'model', 'value': 'ggml-base.bin'},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('another language code is typed', (tester) async {
    final fake = await open(tester, _get());
    await pick(tester, 'voice-language', 'Other code…');
    await tester.enterText(find.byKey(const ValueKey('voice-language-code')), 'SV');
    await tapKey(tester, 'voice-language-ok');
    await tester.pumpAndSettle();
    expect(fake.of('voice.set'), [{'key': 'language', 'value': 'sv'}]);
  });

  testWidgets('an unavailable engine cannot be picked', (tester) async {
    final fake = await open(tester, _get());
    await pick(tester, 'voice-engine', 'Voxtype · not installed');
    expect(fake.of('voice.set'), isEmpty);
    // the menu stays open: close it
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await pick(tester, 'voice-engine', 'Local Whisper');
    expect(fake.of('voice.set'), [{'key': 'engine', 'value': 'whisper'}]);
  });

  testWidgets('a download shows its progress and can be cancelled', (tester) async {
    final fake = await open(tester, _get());
    await tapKey(tester, 'voice-download-small');
    await tester.pump();
    expect(fake.of('voice.download'), [{'model': 'small'}]);
    expect(find.byKey(const ValueKey('voice-download-progress')), findsOneWidget);
    // others wait
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-try'))).onPressed, isNotNull);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.text('Downloading… 42 %'), findsOneWidget);
    await tapKey(tester, 'voice-download-cancel');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(fake.of('voice.cancel'), [{'kind': 'download'}]);
    expect(find.byKey(const ValueKey('voice-download-progress')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Remove asks first', (tester) async {
    final fake = await open(tester, _get());
    await tapKey(tester, 'voice-remove-base');
    await tester.pumpAndSettle();
    expect(find.text('Remove Whisper base (148 MB · fast, any PC)?'), findsOneWidget);
    await tapKey(tester, 'voice-remove-confirm');
    await tester.pumpAndSettle();
    expect(fake.of('voice.remove'), [{'model': 'base'}]);
  });

  testWidgets('Try it: live dB level meter (U1/U2, hidden until first level, non-overlapping 150 ms polls M1), partial text, final text and peak', (tester) async {
    final fake = await open(tester, _get());
    await tapKey(tester, 'voice-try');
    await tester.pump();
    expect(fake.of('voice.try'), [{'seconds': 5}]);
    expect(find.text('Listening for 5 s… speak now'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-try-stop')), findsOneWidget);
    // U2: before any level event arrives (null), no false level bar is shown
    expect(find.byKey(const ValueKey('voice-try-level')), findsNothing);

    // M1: hold the first voice.tasks poll across several 150 ms ticks -> never overlaps!
    final gate = fake.holdTasks = Completer<void>();
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 160));
    expect(fake.maxConcurrentTaskCalls, 1);
    fake.holdTasks = null;
    gate.complete();
    await tester.pump();
    await tester.pump();

    // Poll 1 (-46 dB): Quiet / noise floor
    expect(find.byKey(const ValueKey('voice-try-level')), findsOneWidget);
    expect(find.textContaining('Quiet / noise floor'), findsOneWidget);
    // Poll 2 (-18 dB -> 70% bar): Voice detected + partial text
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();
    expect(find.text('hallo'), findsOneWidget);
    expect(find.textContaining('Voice detected · -18 dB'), findsOneWidget);
    final greenBar = tester.widget<LinearProgressIndicator>(
      find.descendant(of: find.byKey(const ValueKey('voice-try-level')), matching: find.byType(LinearProgressIndicator)),
    );
    expect(greenBar.value, closeTo(0.70, 0.02));
    // Poll 3 (-12 dB -> 80% bar): Loud (amber)
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();
    expect(find.textContaining('Loud · -12 dB'), findsOneWidget);
    // Poll 4 (-4 dB -> 93% bar): Too loud (red)
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();
    expect(find.textContaining('Too loud — lower mic gain · -4 dB'), findsOneWidget);
    // Poll 5: Final text + peak microphone level shown
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(find.text('Hallo Welt.'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-try')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-try-level')), findsOneWidget);
    expect(find.text('Peak microphone level'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('not ready: the service\'s reason; Try it is off', (tester) async {
    await open(tester, _get(ready: false));
    expect(find.text('No Whisper model is installed.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-try'))).onPressed, isNull);
    expect(find.text('Dictation has to be ready first.'), findsOneWidget);
  });

  testWidgets('an engine that types itself (Omarchy): Try it is off and the note says why', (tester) async {
    final fake = await open(tester, _get(status: {..._status(engines: ['whisper', 'omarchy']), 'engine': 'omarchy', 'typed_by_engine': true}));
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-try'))).onPressed, isNull);
    expect(find.text('This engine types the text itself, into the window that has the focus, so it can\'t be tried here.'), findsOneWidget);
    expect(find.text('Dictation has to be ready first.'), findsNothing);
    expect(fake.of('voice.try'), isEmpty);
  });

  test('the wake line: every wake_why_not code in words', () {
    final on = {'wake_enabled': true, 'wake_phrase': 'Hallo Rechner', 'wake_message': ''};
    expect(VoicePageState.wakeLine({'wake_enabled': false, 'wake_why_not': 'off'}), ('off', 'Off: the microphone is not listening for the phrase.'));
    expect(VoicePageState.wakeLine({...on, 'wake_why_not': '', 'wake_active': true}), ('on', 'Listening for “Hallo Rechner”'));
    expect(VoicePageState.wakeLine({...on, 'wake_why_not': '', 'wake_active': false}).$1, 'paused');
    expect(VoicePageState.wakeLine({...on, 'wake_why_not': 'disabled'}), ('paused', 'Not listening: Dictation is off.'));
    expect(VoicePageState.wakeLine({...on, 'wake_why_not': 'busy'}), ('paused', 'Paused while a dictation runs.'));
    expect(VoicePageState.wakeLine({...on, 'wake_why_not': 'speaking'}).$1, 'paused');
    expect(VoicePageState.wakeLine({...on, 'wake_why_not': 'cooldown'}).$1, 'paused');
    for (final code in ['no_whisper_server', 'no_model', 'no_recorder', 'recorder_failed', 'failed']) {
      expect(VoicePageState.wakeLine({...on, 'wake_why_not': code}).$1, 'problem', reason: code);
    }
    expect(VoicePageState.wakeLine({...on, 'wake_why_not': 'failed', 'wake_message': 'boom'}).$2, 'The wake listener failed: boom');
    // a code this page doesn't know yet: the service's own words
    expect(VoicePageState.wakeLine({...on, 'wake_why_not': 'new_code', 'wake_message': 'Something new.'}), ('problem', 'Something new.'));
  });

  test('wake models: the smallest installed one, then the installed ones by their catalog name', () {
    final m = _models();
    expect(VoicePageState.wakeModelChoices(m, ''), [
      ('', 'Smallest installed'),
      ('ggml-base.bin', 'Whisper base'),
      ('ggml-large-v3-turbo-q5_0.bin', 'Whisper large-v3-turbo'),
      ('ggml-medium.bin', 'ggml-medium.bin'),
    ]);
    // a catalog id names its file; a model that is gone stays shown
    expect(VoicePageState.wakeModelValue(m, 'base'), 'ggml-base.bin');
    expect(VoicePageState.wakeModelChoices(m, 'ggml-tiny.bin').last, ('ggml-tiny.bin', 'ggml-tiny.bin'));
  });

  testWidgets('wake phrase off: the card, its note, and the settings it writes', (tester) async {
    final fake = await open(tester, _get(status: _wakeStatus(enabled: false), settings: {'wake_language': 'de'}));
    expect(find.text('Wake phrase'), findsOneWidget);
    expect(find.textContaining('the microphone stays open'), findsWidgets);
    expect(find.textContaining('nothing is stored or sent online'), findsOneWidget);
    expect(find.text('Off: the microphone is not listening for the phrase.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('voice-wake-phrase'))).controller!.text, 'Hey Linux');
    expect(find.descendant(of: find.byKey(const ValueKey('voice-wake-language')), matching: find.text('Deutsch')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('voice-wake-sensitivity')), matching: find.text('Normal')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('voice-wake-model')), matching: find.text('Smallest installed')), findsOneWidget);
    // nothing is written by just opening the page
    expect(fake.of('voice.set'), isEmpty);
    await tapKey(tester, 'voice-wake-enabled');
    await tester.pumpAndSettle();
    await pick(tester, 'voice-wake-language', 'English');
    await pick(tester, 'voice-wake-sensitivity', 'Loose');
    await pick(tester, 'voice-wake-model', 'Whisper base');
    expect(fake.of('voice.set'), [
      {'key': 'wake_enabled', 'value': true},
      {'key': 'wake_language', 'value': 'en'},
      {'key': 'wake_sensitivity', 'value': 'loose'},
      {'key': 'wake_model', 'value': 'ggml-base.bin'},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the phrase is checked like the service and saved on Enter or when the field is left', (tester) async {
    final fake = await open(tester, _get(status: _wakeStatus(enabled: false)));
    final field = find.byKey(const ValueKey('voice-wake-phrase'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'Hey "Linux"');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('2–40 letters or digits; also spaces and , . ! ? \' -'), findsOneWidget);
    expect(fake.of('voice.set'), isEmpty);
    await tester.enterText(field, '  Hallo Rechner ');
    await tester.pump();
    expect(find.text('2–40 letters or digits; also spaces and , . ! ? \' -'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(fake.of('voice.set'), [{'key': 'wake_phrase', 'value': 'Hallo Rechner'}]);
    // leaving the field saves too
    await tester.tap(field);
    await tester.enterText(field, 'OK Computer');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(fake.of('voice.set').last, {'key': 'wake_phrase', 'value': 'OK Computer'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('wake phrase on: the line follows the service while the page is open', (tester) async {
    final fake = await open(tester, _get(status: _wakeStatus(enabled: true, active: true)));
    expect(find.text('Listening for “Hey Linux”'), findsOneWidget);
    if (shotsDir != null) await saveShot(tester, 'page-voice-wake');
    fake.liveStatus = _wakeStatus(enabled: true, why: 'busy');
    await tester.pump(wakeStatusEvery);
    await tester.pump();
    expect(find.text('Paused while a dictation runs.'), findsOneWidget);
    expect(fake.of('voice.status'), isNotEmpty);
    fake.liveStatus = _wakeStatus(enabled: true, why: 'no_model');
    await tester.pump(wakeStatusEvery);
    await tester.pump();
    expect(find.text('Not listening: no Whisper model is installed.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Try the phrase: "say it now", then what was heard and the score; the others wait', (tester) async {
    final fake = await open(tester, _get(status: _wakeStatus(enabled: false)));
    await tapKey(tester, 'voice-wake-try');
    await tester.pump();
    expect(fake.of('voice.wake_test'), [{'seconds': 8}]);
    expect(find.text('Say your phrase now…'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-wake-stop')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-wake-try')), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-try'))).onPressed, isNull);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 450));
    }
    await tester.pumpAndSettle();
    expect(find.text('It matches. Heard: “Hey Linux, open Firefox.”'), findsOneWidget);
    expect(find.text('Score 93 % (a match needs 75 %) · Request after it: open Firefox'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-wake-try'))).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('voice-try'))).onPressed, isNotNull);
    // no match, then nothing heard
    fake.wakeResult = {'heard': 'Hallo Welt', 'matched': false, 'score': 0.41, 'needed': 0.75, 'rest': '', 'speech': true};
    fake.wakePolls = 0;
    await tapKey(tester, 'voice-wake-try');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 450));
    }
    await tester.pumpAndSettle();
    expect(find.text('No match. Heard: “Hallo Welt”'), findsOneWidget);
    expect(find.text('Score 41 % (a match needs 75 %)'), findsOneWidget);
    if (shotsDir != null) await saveShot(tester, 'page-voice-wake-try');
    fake.wakeResult = {'heard': '', 'matched': false, 'score': 0.0, 'needed': 0.75, 'rest': '', 'speech': false};
    fake.wakePolls = 0;
    await tapKey(tester, 'voice-wake-try');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 450));
    }
    await tester.pumpAndSettle();
    expect(find.text('Nothing was heard.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Try the phrase can be cancelled', (tester) async {
    final fake = await open(tester, _get(status: _wakeStatus(enabled: false)));
    await tapKey(tester, 'voice-wake-try');
    await tester.pump();
    await tapKey(tester, 'voice-wake-stop');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(fake.of('voice.cancel'), [{'kind': 'wake'}]);
    expect(find.descendant(of: find.byKey(const ValueKey('voice-wake-result')), matching: find.text('Cancelled')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-wake-try')), findsOneWidget);
  });

  testWidgets('not installed: Install and the GitHub link', (tester) async {
    final fake = await open(tester, _get(installed: false));
    expect(find.text('Maprisma Dictation is not installed'), findsOneWidget);
    expect(find.textContaining('github.com/maprisma/dictation'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-install')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-enabled')), findsNothing);
    if (shotsDir != null) await saveShot(tester, 'page-voice-missing');
    await tapKey(tester, 'voice-github');
    await tester.pumpAndSettle();
    expect(fake.of('links.open'), [{'url': 'https://github.com/maprisma/dictation'}]);
  });

  testWidgets('Audio & noise filtering: noise filter, VAD sensitivity, media action, engine-aware hallucination filter', (tester) async {
    final fake = await open(
      tester,
      _get(settings: {'noise_filter': 'standard', 'vad_sensitivity': 'normal', 'hallucination_filter': true}),
    );
    expect(find.text('Audio & noise filtering'), findsOneWidget);
    expect(find.textContaining('Shared with Maprisma Dictation'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-noise-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-vad-sensitivity')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-hallucination-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-media-action')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('voice-media-action')), matching: find.text('Keep playing')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-noise-cancel')), findsNothing);
    // Engine-aware description for Local Whisper
    expect(find.textContaining('Local Whisper sometimes hallucinates'), findsOneWidget);

    await pick(tester, 'voice-noise-filter', 'Strong');
    await pick(tester, 'voice-vad-sensitivity', 'Strict');
    await tapKey(tester, 'voice-hallucination-filter');
    await tester.pumpAndSettle();
    await pick(tester, 'voice-media-action', 'Lower volume');
    await pick(tester, 'voice-media-action', 'Pause media');
    expect(fake.of('voice.set'), [
      {'key': 'noise_filter', 'value': 'strong'},
      {'key': 'vad_sensitivity', 'value': 'strict'},
      {'key': 'hallucination_filter', 'value': false},
      {'key': 'media_during_dictation', 'value': 'duck'},
      {'key': 'media_during_dictation', 'value': 'pause'},
    ]);
    expect(tester.takeException(), isNull);
  });

  test('hallucinationDescription adapts to Local Whisper, Online Whisper, settings fallback, and external engines (M4)', () {
    expect(VoicePageState.hallucinationDescription({'engine': 'whisper'}), contains('Local Whisper'));
    expect(VoicePageState.hallucinationDescription({'engine': 'online'}), contains('Online Whisper'));
    expect(VoicePageState.hallucinationDescription({'engine': 'voxtype'}), contains('Voxtype'));
    expect(VoicePageState.hallucinationDescription({'engine': 'omarchy'}), contains('Omarchy'));
    expect(VoicePageState.hallucinationDescription(const {}, {'engine': 'online'}), contains('Online Whisper'));
    expect(VoicePageState.hallucinationDescription(const {}, {'engine': 'voxtype'}), contains('Voxtype'));
    expect(VoicePageState.hallucinationDescription(const {}, {'engine': 'auto'}), contains('Local Whisper or Online Whisper'));
    expect(VoicePageState.hallucinationDescription(const {}), contains('Local Whisper or Online Whisper'));
  });

  testWidgets('hallucination toggle is disabled when an external engine is active (M4)', (tester) async {
    await open(
      tester,
      _get(status: {..._status(engines: ['whisper', 'voxtype']), 'engine': 'voxtype', 'typed_by_engine': true}),
    );
    final toggle = tester.widget<SettingsToggle>(find.byKey(const ValueKey('voice-hallucination-filter')));
    expect(toggle.onChanged, isNull);
    expect(find.textContaining('Voxtype handles its own transcription'), findsOneWidget);
  });

  testWidgets('PipeWire noise-cancelling microphone toggle: descriptions (U3/U4), waiting state, Active chip', (tester) async {
    final fake = await open(
      tester,
      _get(noiseCancel: const {'available': true, 'enabled': false, 'active': false}),
    );
    expect(find.byKey(const ValueKey('voice-noise-cancel')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-noise-cancel-active')), findsNothing);
    expect(find.textContaining('WebRTC echo & noise cancellation (filters out YouTube/speaker playback from your mic)'), findsOneWidget);
    expect(find.textContaining('Switching restarts audio briefly'), findsOneWidget);

    // Enabled but not yet active -> shows waiting for PipeWire text (U4)
    fake.answer = _get(noiseCancel: const {'available': true, 'enabled': true, 'active': false});
    await tapKey(tester, 'voice-noise-cancel');
    await tester.pumpAndSettle();
    expect(fake.of('voice.noise_cancel'), [{'enabled': true, 'apply': true}]);
    expect(find.byKey(const ValueKey('voice-noise-cancel-active')), findsNothing);
    expect(find.textContaining('Enabled — waiting for PipeWire (takes effect after audio restarts)'), findsOneWidget);

    // Reload with active: true -> Active chip appears
    fake.answer = _get(noiseCancel: const {'available': true, 'enabled': true, 'active': true});
    final reload = find.byTooltip('Reload');
    await tester.ensureVisible(reload);
    await tester.pumpAndSettle();
    await tester.tap(reload);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('voice-noise-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-noise-cancel-active')), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.textContaining('to filter out speaker/video playback and background noise'), findsOneWidget);

    // Toggling off calls voice.noise_cancel with enabled: false, apply: true
    fake.answer = _get(noiseCancel: const {'available': true, 'enabled': false, 'active': false});
    await tapKey(tester, 'voice-noise-cancel');
    await tester.pumpAndSettle();
    expect(fake.of('voice.noise_cancel'), [
      {'enabled': true, 'apply': true},
      {'enabled': false, 'apply': true},
    ]);
    expect(find.byKey(const ValueKey('voice-noise-cancel-active')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
