import 'translations.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:maprisma_core_kit/files.dart' show StagingFile;
import 'package:path/path.dart' as p;

import 'context.dart';
import 'run.dart' show isExecutableFile;
import 'sound.dart';

/// The Voice page (`voice.*`): Maprisma Dictation's voice service `maprisma-voice`, always
/// through its command line (argv lists, never a shell; bounded output, time limits), so the
/// service checks every value in one place: `status --json`, `models --json`, `get`,
/// `set KEY VALUE` (VALUE as JSON), `unset KEY`, `model download|remove NAME` and
/// `dictate --seconds N`, `wake test --seconds N --json`. A download, a try and a wake test run
/// in the background, one of each at a time, and are polled with `voice.tasks`; `voice.cancel`
/// ends them. The contract is
/// maprisma-dictation's docs/protocol.md.
final class VoiceService {
  VoiceService(this.ctx, this.sound);
  final Ctx ctx;
  final SoundService sound;

  static const repoUrl = 'https://github.com/maprisma/dictation';

  /// The engines in the service's order of choice (status `engines` lists the available ones).
  static const engines = ['whisper', 'online', 'omarchy', 'voxtype', 'superwhisper'];

  /// The settings the page sets; the service checks the values.
  static const keys = {
    'enabled', 'engine', 'model', 'language', 'microphone', 'unload_minutes', 'preload', //
    'noise_filter', 'vad_sensitivity', 'hallucination_filter', 'media_during_dictation', //
    'wake_enabled', 'wake_phrase', 'wake_language', 'wake_model', 'wake_sensitivity',
  };

  /// How strongly background noise is filtered before transcription.
  static const noiseFilters = ['off', 'standard', 'strong'];

  /// Voice-activity detection threshold for dictation.
  static const vadSensitivities = ['strict', 'normal', 'sensitive'];

  /// What to do with playing media (videos, music) while dictation is listening.
  static const mediaActions = ['keep', 'duck', 'pause'];

  /// How far what was heard may be from the wake phrase.
  static const sensitivities = ['strict', 'normal', 'loose'];

  /// PipeWire WebRTC echo-cancel virtual microphone source name and config file name.
  static const noiseCancelSource = 'maprisma.noise_cancel_source';
  static const noiseCancelConfigName = '50-maprisma-noise-cancel.conf';
  static const _pipewireLibDirs = [
    '/usr/lib',
    '/usr/lib64',
    '/usr/lib/x86_64-linux-gnu',
    '/usr/lib/aarch64-linux-gnu',
  ];

  static const _noiseCancelConfig = '''context.modules = [
    {   name = libpipewire-module-echo-cancel
        flags = [ nofail ]
        args = {
            library.name  = aec/libspa-aec-webrtc
            node.latency  = 1024/48000
            monitor.mode  = true
            aec.args = {
                webrtc.gain_control = true
                webrtc.noise_suppression = true
                webrtc.high_pass_filter = true
                webrtc.extended_filter = true
            }
            source.props = {
                node.name = "maprisma.noise_cancel_source"
                node.description = "Maprisma Noise-Cancelling Mic"
            }
        }
    }
]
''';

  static final _alnum = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _phraseChars = RegExp(r"^[\p{L}\p{N} ,.!?'-]*$", unicode: true);

  /// The service's rule for `wake_phrase`: 2–40 characters, letters, digits, spaces and
  /// `,.!?'-`, at least two letters or digits, no spaces at the ends.
  static bool validWakePhrase(String phrase) {
    final n = phrase.runes.length;
    return n >= 2 && n <= 40 && phrase.trim() == phrase && _phraseChars.hasMatch(phrase) && _alnum.allMatches(phrase).length >= 2;
  }

  static final _language = RegExp(r'^(auto|[a-z]{2,3})$');

  /// At most this much of a command's stdout and stderr is kept.
  static const maxOutput = 256 * 1024;
  static const _stderrTail = 4096;

  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$');

  /// Test hooks: time limits and polling intervals.
  Duration downloadTimeout = const Duration(hours: 2);
  Duration quickTimeout = const Duration(seconds: 10);
  Duration noiseCancelPollInterval = const Duration(milliseconds: 250);
  Duration noiseCancelPollTimeout = const Duration(seconds: 4);
  Duration cancelGrace = const Duration(milliseconds: 300);

  final Map<String, VoiceTask> _tasks = {};

  /// `~/.local/bin/maprisma-voice` (where install.sh puts it), else the one on PATH.
  String? binary() {
    final own = p.join(ctx.paths.bin, 'maprisma-voice');
    if (isExecutableFile(own)) return own;
    return ctx.runner.which('maprisma-voice');
  }

  String _need() => binary() ?? (throw RouteError('not_installed', tr('maprisma-voice is not installed')));

  Future<Process?> _start(String exe, List<String> args, {bool keepStdinOpen = false}) async {
    try {
      final process = await Process.start(exe, args, environment: ctx.environment, includeParentEnvironment: false);
      if (!keepStdinOpen) process.stdin.close().ignore();
      return process;
    } on ProcessException {
      return null;
    }
  }

  /// One short command: (exit code, stdout, stderr); the code is null when it could not start,
  /// ran too long or said too much (then it is killed).
  Future<(int?, String, String)> _run(String exe, List<String> args, {Duration? timeout}) async {
    final process = await _start(exe, args);
    if (process == null) return (null, '', trf('could not start {0}', [exe]));
    final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
    var tooMuch = false;
    void take(BytesBuilder into, List<int> chunk) {
      if (tooMuch) return;
      if (out.length + err.length + chunk.length > maxOutput) {
        tooMuch = true;
        process.kill(ProcessSignal.sigkill);
        return;
      }
      into.add(chunk);
    }

    final streams = [process.stdout.listen((c) => take(out, c)).asFuture<void>(), process.stderr.listen((c) => take(err, c)).asFuture<void>()];
    int? code;
    try {
      code = await process.exitCode.timeout(timeout ?? quickTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await Future.wait(streams).timeout(const Duration(seconds: 1), onTimeout: () => const []);
    String text(BytesBuilder b) => utf8.decode(b.takeBytes(), allowMalformed: true);
    return (tooMuch ? null : code, text(out), text(err));
  }

  static String _firstLine(String s, int? code) {
    final l = s.trim().split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).firstOrNull;
    return l ?? (code == null ? tr('no answer in time') : trf('exit {0}', [code]));
  }

  Future<Object?> _json(String exe, List<String> args) async {
    final (code, out, _) = await _run(exe, args);
    if (code != 0) return null;
    try {
      return jsonDecode(out);
    } on FormatException {
      return null;
    }
  }

  // --- reading -------------------------------------------------------------------------------

  /// Path to the user PipeWire drop-in for the WebRTC noise-cancelling microphone.
  String get noiseCancelConfigPath => p.join(ctx.paths.config, 'pipewire', 'pipewire.conf.d', noiseCancelConfigName);

  bool _hasPipewirePlugin(String relativePath) =>
      _pipewireLibDirs.any((dir) => File(ctx.paths.sys('$dir/$relativePath')).existsSync());

  /// Whether BOTH PipeWire's echo-cancel module and WebRTC AEC SPA plugin are installed.
  bool get noiseCancelAvailable =>
      _hasPipewirePlugin('pipewire-0.3/libpipewire-module-echo-cancel.so') &&
      _hasPipewirePlugin('spa-0.2/aec/libspa-aec-webrtc.so');

  /// Whether the PipeWire drop-in exists as a regular file inside real directories (never following symlinks).
  bool get noiseCancelEnabled {
    final pw = p.join(ctx.paths.config, 'pipewire');
    final dir = p.join(pw, 'pipewire.conf.d');
    if (FileSystemEntity.typeSync(pw, followLinks: false) != FileSystemEntityType.directory) return false;
    if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.directory) return false;
    return FileSystemEntity.typeSync(noiseCancelConfigPath, followLinks: false) == FileSystemEntityType.file;
  }

  Map<String, dynamic> _noiseCancelStatus(Map<String, dynamic> mics) {
    final sources = (mics['sources'] as List?) ?? const [];
    final active = sources.any((s) => s is Map && s['name'] == noiseCancelSource);
    return {'available': noiseCancelAvailable, 'enabled': noiseCancelEnabled, 'active': active};
  }

  /// `voice.get`: whether it is installed, the service's status (or why there is none), the
  /// models, the settings file's values, the microphones, PipeWire noise-cancel status, and the running tasks.
  Future<Map<String, dynamic>> get() async {
    final exe = binary();
    final microphones = sound.microphones();
    if (exe == null) {
      final mics = await microphones;
      return {
        'installed': false,
        'binary': null,
        'install_url': repoUrl,
        'microphones': mics,
        'noise_cancel': _noiseCancelStatus(mics),
        'tasks': tasks(),
      };
    }
    final status = _run(exe, ['status', '--json']);
    final models = _json(exe, ['models', '--json']);
    final settings = _json(exe, ['get']);
    final (code, out, err) = await status;
    Map<String, dynamic>? state;
    String? why;
    if (code == 0) {
      try {
        final v = jsonDecode(out);
        if (v is Map<String, dynamic>) state = v;
      } on FormatException {
        // said below
      }
      if (state == null) why = tr('the voice service gave no readable answer');
    } else {
      why = _firstLine(err, code);
    }
    final m = await models, s = await settings, mics = await microphones;
    return {
      'installed': true,
      'binary': exe,
      'install_url': repoUrl,
      'status': state,
      'status_error': why,
      'models': m is Map ? m : null,
      'settings': s is Map ? s : const <String, dynamic>{},
      'microphones': mics,
      'noise_cancel': _noiseCancelStatus(mics),
      'tasks': tasks(),
    };
  }

  /// `voice.status`: only `status --json` (the page's live wake line), or why there is none.
  Future<Map<String, dynamic>> status() async {
    final exe = _need();
    final (code, out, err) = await _run(exe, ['status', '--json']);
    if (code != 0) return {'status': null, 'status_error': _firstLine(err, code)};
    try {
      final v = jsonDecode(out);
      if (v is Map<String, dynamic>) return {'status': v, 'status_error': null};
    } on FormatException {
      // said below
    }
    return {'status': null, 'status_error': tr('the voice service gave no readable answer')};
  }

  /// `voice.tasks`: {download, dictate, wake}, each null before the first.
  Map<String, dynamic> tasks() => {for (final k in const ['download', 'dictate', 'wake']) k: _tasks[k]?.toJson()};

  // --- settings ------------------------------------------------------------------------------

  static bool _valueOk(String key, Object? value) => switch (key) {
    'enabled' || 'preload' || 'wake_enabled' || 'hallucination_filter' => value is bool,
    'unload_minutes' => value is int && value >= 0 && value <= 1440,
    'noise_filter' => value is String && noiseFilters.contains(value),
    'vad_sensitivity' => value is String && vadSensitivities.contains(value),
    'media_during_dictation' => value is String && mediaActions.contains(value),
    'wake_phrase' => value is String && validWakePhrase(value),
    'wake_language' => value is String && _language.hasMatch(value),
    'wake_model' => value is String && (value.isEmpty || (_name.hasMatch(value) && !value.contains('..'))),
    'wake_sensitivity' => value is String && sensitivities.contains(value),
    _ => value is String && value.length <= 200 && !value.contains('\n') && !value.contains('\x00'),
  };

  String _key(Map<String, dynamic> params) {
    final key = params['key'];
    if (key is! String || !keys.contains(key)) throw RouteError('bad_params', 'key (${keys.join(', ')})');
    return key;
  }

  Future<void> _write(List<String> args) async {
    final (code, _, err) = await _run(_need(), args);
    if (code == 0) return;
    throw RouteError(code == 2 ? 'bad_params' : 'failed', _firstLine(err, code));
  }

  /// `voice.set` {key, value}: `maprisma-voice set KEY <value as JSON>`.
  Future<Map<String, dynamic>> set(Map<String, dynamic> params) async {
    final key = _key(params);
    final value = params['value'];
    if (!_valueOk(key, value)) throw RouteError('bad_params', 'value');
    await _write(['set', key, jsonEncode(value)]);
    return {'key': key, 'value': value};
  }

  /// `voice.unset` {key}: back to the service's default.
  Future<Map<String, dynamic>> unset(Map<String, dynamic> params) async {
    final key = _key(params);
    await _write(['unset', key]);
    return {'key': key};
  }

  // --- PipeWire WebRTC noise-cancelling microphone -------------------------------------------

  void _ensureSafeDir(String dir) {
    final type = FileSystemEntity.typeSync(dir, followLinks: false);
    if (type == FileSystemEntityType.directory) return;
    if (type == FileSystemEntityType.notFound) {
      Directory(dir).createSync();
      return;
    }
    throw RouteError('failed', tr('PipeWire config path is not a directory'));
  }

  /// `voice.noise_cancel` {enabled, apply?}: writes or removes the PipeWire WebRTC echo-cancel
  /// virtual microphone drop-in (safely, without symlink traversal inside PipeWire's config
  /// subdirectories; `$XDG_CONFIG_HOME` itself may be a symlink), resets the selected mic to
  /// `default` when disabling if it pointed at the removed virtual source, and optionally
  /// restarts PipeWire + WirePlumber and waits for the virtual mic to appear or disappear.
  Future<Map<String, dynamic>> setNoiseCancel(Map<String, dynamic> params) async {
    final enabled = params['enabled'];
    if (enabled is! bool) throw RouteError('bad_params', 'enabled');
    final apply = params['apply'] ?? false;
    if (apply is! bool) throw RouteError('bad_params', 'apply');

    final configRoot = ctx.paths.config;
    final pwDir = p.join(configRoot, 'pipewire');
    final confDir = p.join(pwDir, 'pipewire.conf.d');
    final target = p.join(confDir, noiseCancelConfigName);
    var changed = false;

    if (enabled) {
      if (!noiseCancelAvailable) {
        throw RouteError('unavailable', tr('PipeWire echo-cancel module is not installed'));
      }
      if (!Directory(configRoot).existsSync()) {
        Directory(configRoot).createSync(recursive: true);
      }
      _ensureSafeDir(pwDir);
      _ensureSafeDir(confDir);
      final targetType = FileSystemEntity.typeSync(target, followLinks: false);
      if (targetType != FileSystemEntityType.notFound && targetType != FileSystemEntityType.file) {
        throw RouteError('failed', tr('PipeWire config file is not a regular file'));
      }
      final alreadySame = targetType == FileSystemEntityType.file && _readIfRegular(target) == _noiseCancelConfig;
      if (!alreadySame) {
        final temp = p.join(confDir, '.$noiseCancelConfigName.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
        StagingFile? staged;
        try {
          staged = StagingFile(temp, exclusive: true, mode: 0x1a4);
          staged.add(utf8.encode(_noiseCancelConfig));
          staged.publish(target);
          changed = true;
        } on Object catch (e) {
          throw RouteError('failed', '$e');
        } finally {
          staged?.close();
        }
      }
    } else {
      final pwType = FileSystemEntity.typeSync(pwDir, followLinks: false);
      if (pwType != FileSystemEntityType.notFound) {
        if (pwType != FileSystemEntityType.directory) {
          throw RouteError('failed', tr('PipeWire config path is not a directory'));
        }
        final confType = FileSystemEntity.typeSync(confDir, followLinks: false);
        if (confType != FileSystemEntityType.notFound) {
          if (confType != FileSystemEntityType.directory) {
            throw RouteError('failed', tr('PipeWire config path is not a directory'));
          }
          final targetType = FileSystemEntity.typeSync(target, followLinks: false);
          if (targetType == FileSystemEntityType.file) {
            try {
              File(target).deleteSync();
              changed = true;
            } on FileSystemException catch (e) {
              throw RouteError('failed', e.message);
            }
          } else if (targetType != FileSystemEntityType.notFound) {
            throw RouteError('failed', tr('PipeWire config file is not a regular file'));
          }
        }
      }
      // Don't leave dictation pointing at the removed virtual source.
      final exe = binary();
      if (exe != null) {
        final current = await _json(exe, ['get']);
        if (current is Map && current['microphone'] == noiseCancelSource) {
          await _run(exe, ['set', 'microphone', jsonEncode('default')]);
        }
      }
    }

    var applied = false;
    String? message;
    if (apply && changed) {
      final r = await ctx.runner.run(
        ['systemctl', '--user', 'restart', 'pipewire', 'wireplumber'],
        timeout: const Duration(seconds: 15),
      );
      if (!r.ok) {
        message = trf(
          'Saved PipeWire configuration, but restarting audio failed ({0}). It will take effect after PipeWire restarts.',
          [_firstLine(r.stderr, r.code)],
        );
      } else {
        applied = true;
      }
    }

    var mics = await sound.microphones();
    var status = _noiseCancelStatus(mics);
    if (applied && status['active'] != enabled) {
      final deadline = DateTime.now().add(noiseCancelPollTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(noiseCancelPollInterval);
        mics = await sound.microphones();
        status = _noiseCancelStatus(mics);
        if (status['active'] == enabled) break;
      }
    }

    return {
      'noise_cancel': status,
      'enabled': status['enabled'],
      'active': status['active'],
      'applied': applied,
      'message': ?message,
    };
  }

  static String? _readIfRegular(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  // --- models --------------------------------------------------------------------------------

  String _model(Map<String, dynamic> params) {
    final m = params['model'];
    if (m is! String || !_name.hasMatch(m) || m.contains('..')) throw RouteError('bad_params', 'model');
    return m;
  }

  bool _running(String kind) => _tasks[kind]?.state == 'running';

  /// `voice.remove` {model}: only a model the service installed (its own folder).
  Future<Map<String, dynamic>> remove(Map<String, dynamic> params) async {
    final model = _model(params);
    final exe = _need();
    if (_running('download') && _tasks['download']!.model == model) throw RouteError('busy', tr('the model is being downloaded'));
    final (code, _, err) = await _run(exe, ['model', 'remove', model], timeout: const Duration(seconds: 20));
    if (code != 0) throw RouteError('failed', _firstLine(err, code));
    return {'model': model, 'removed': true};
  }

  /// The service's own model folder (`model download` writes `<file>.part` there, then renames).
  String get modelsDir => p.join(ctx.paths.data, 'maprisma-voice', 'models');

  static final _modelFile = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.bin$');

  /// `voice.download` {model}: `model download NAME` in the background (curl's progress bar on
  /// stderr gives the percent; the path on stdout when done). Only a catalog model that is not
  /// installed yet: so a Cancel can never take a model that was already there.
  Future<Map<String, dynamic>> download(Map<String, dynamic> params) async {
    final model = _model(params);
    final exe = _need();
    if (_running('download')) throw RouteError('busy', tr('a model is already being downloaded'));
    final listing = await _json(exe, ['models', '--json']);
    final catalog = listing is Map && listing['catalog'] is List ? listing['catalog'] as List : const [];
    final entry = catalog.whereType<Map>().where((c) => c['id'] == model).firstOrNull;
    final file = entry?['file'];
    if (entry == null || file is! String || !_modelFile.hasMatch(file) || file.contains('..')) {
      throw RouteError('bad_params', tr('not a model the voice service can download'));
    }
    if (entry['installed'] == true) throw RouteError('exists', tr('the model is already installed'));
    // checked again after the wait: one download at a time
    if (_running('download')) throw RouteError('busy', tr('a model is already being downloaded'));
    final task = _tasks['download'] = VoiceTask('download', ctx.clock(), model: model)..file = file;
    unawaited(_follow(task, exe, ['model', 'download', model], downloadTimeout));
    return {'task': task.toJson()};
  }

  /// After a cancelled download: only this download's `<file>.part` in the service's folder (a
  /// regular file, never through a link); a finished model is left alone.
  void _removePart(String file) {
    final dir = modelsDir;
    final part = p.join(dir, '$file.part');
    if (!p.isWithin(dir, part) || p.dirname(part) != dir) return;
    if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.directory) return;
    if (FileSystemEntity.typeSync(part, followLinks: false) != FileSystemEntityType.file) return;
    try {
      File(part).deleteSync();
    } on FileSystemException {
      // gone already
    }
  }

  // --- try it --------------------------------------------------------------------------------

  /// `voice.try` {seconds?}: `dictate --events --seconds N` (1–30, default 5) in the background;
  /// JSON events on stdout carry live microphone levels, partial text and final text (falling
  /// back cleanly to plain-text stdout / "… text" stderr for older or fake binaries). Only with
  /// an engine that hands the text back: one that types it itself (status `typed_by_engine`:
  /// Voxtype, Superwhisper, Omarchy) would type into whatever window has the focus.
  Future<Map<String, dynamic>> tryIt(Map<String, dynamic> params) async {
    final seconds = params['seconds'] ?? 5;
    if (seconds is! int || seconds < 1 || seconds > 30) throw RouteError('bad_params', 'seconds (1–30)');
    final exe = _need();
    if (_running('dictate') || _running('wake')) throw RouteError('busy', tr('a try is already running'));
    final status = await _json(exe, ['status', '--json']);
    if (status is! Map) throw RouteError('unavailable', tr('the voice service gave no readable answer'));
    if (status['typed_by_engine'] != false) throw RouteError('unavailable', tr('This engine types the text itself, into the window that has the focus, so it can\'t be tried here.'));
    if (_running('dictate') || _running('wake')) throw RouteError('busy', tr('a try is already running'));
    final task = _tasks['dictate'] = VoiceTask('dictate', ctx.clock(), seconds: seconds);
    unawaited(_follow(task, exe, ['dictate', '--events', '--seconds', '$seconds'], Duration(seconds: seconds + 90)));
    return {'task': task.toJson()};
  }

  /// `voice.wake_test` {seconds?}: `wake test --seconds N --json` (1–10, default 8) in the
  /// background: the service listens once for one stretch of speech and says what its wake
  /// recogniser heard (`result`: heard, matched, score, needed, rest, phrase, model, speech).
  /// Exit 0 matches, 1 no match, 3 no speech: all `succeeded` with the result; 4 (no service)
  /// or no readable answer: `failed` with the service's last line. Nothing is started on a match.
  Future<Map<String, dynamic>> wakeTest(Map<String, dynamic> params) async {
    final seconds = params['seconds'] ?? 8;
    if (seconds is! int || seconds < 1 || seconds > 10) throw RouteError('bad_params', 'seconds (1–10)');
    final exe = _need();
    if (_running('wake') || _running('dictate')) throw RouteError('busy', tr('a try is already running'));
    final task = _tasks['wake'] = VoiceTask('wake', ctx.clock(), seconds: seconds);
    // loading the recogniser's model may take a while the first time (the service allows 120 s)
    unawaited(_follow(task, exe, ['wake', 'test', '--seconds', '$seconds', '--json'], Duration(seconds: seconds + 130)));
    return {'task': task.toJson()};
  }

  /// `voice.cancel` {kind}: ends a running download (the service's curl dies with it; this
  /// download's leftover `.part` is removed) or try (the service cancels a session whose client left), or a wake test.
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> params) async {
    final kind = params['kind'];
    if (kind != 'download' && kind != 'dictate' && kind != 'wake') throw RouteError('bad_params', 'kind (download, dictate or wake)');
    final task = _tasks[kind];
    if (task == null || task.state != 'running') throw RouteError('finished', tr('nothing is running'));
    task.cancelled = true;
    final proc = task.process;
    if (proc != null) {
      if (kind == 'dictate') {
        task.closeStdin(cancel: true);
        unawaited(
          Future<void>.delayed(cancelGrace, () {
            if (task.state == 'running' && task.process == proc) {
              proc.kill(ProcessSignal.sigterm);
            }
          }),
        );
      } else {
        proc.kill(ProcessSignal.sigterm);
      }
    }
    return {'task': task.toJson()};
  }

  static final _percent = RegExp(r'(\d{1,3}(?:[.,]\d+)?)\s*%');
  static const _eventNames = {'started', 'state', 'level', 'partial', 'final', 'error', 'closed'};

  Future<void> _follow(VoiceTask task, String exe, List<String> args, Duration timeout) async {
    final keepStdin = task.kind == 'dictate';
    final process = await _start(exe, args, keepStdinOpen: keepStdin);
    if (process == null) {
      task.finish('failed', ctx.clock(), message: trf('could not start {0}', [exe]));
      return;
    }
    task.process = process;
    if (task.cancelled) {
      if (keepStdin) task.closeStdin(cancel: true);
      process.kill(ProcessSignal.sigterm);
    }
    final out = BytesBuilder(copy: false);
    var outTail = '';
    var sawEvents = false, sawFinal = false;
    String? eventError, closedReason;
    var tail = '';
    final lines = <String>[];
    void line(String l) {
      final t = l.trim();
      if (t.isEmpty) return;
      if (task.kind == 'download') {
        final m = _percent.allMatches(t).lastOrNull;
        if (m != null && (t.contains('#') || t.endsWith('%'))) {
          task.progress = (double.tryParse(m[1]!.replaceAll(',', '.')) ?? 0).clamp(0, 100).toDouble();
          return;
        }
      } else if (t.startsWith('… ') || t.startsWith('... ')) {
        task.partial = t.substring(t.indexOf(' ') + 1).trim();
        return;
      }
      lines.add(t);
      if (lines.length > 20) lines.removeAt(0);
    }

    void handleDictateOutLine(String raw) {
      final t = raw.trim();
      if (t.isEmpty) return;
      if (t.startsWith('{') && t.length <= 64 * 1024) {
        try {
          final parsed = jsonDecode(t);
          if (parsed is Map && _eventNames.contains(parsed['event'])) {
            sawEvents = true;
            switch (parsed['event']) {
              case 'level':
                final r = parsed['rms'];
                if (r is num && !r.isNaN) {
                  final v = r.toDouble().clamp(0.0, 1.0);
                  task.level = v;
                  if (task.peak == null || v > task.peak!) task.peak = v;
                }
              case 'partial':
                final text = parsed['text'];
                if (text is String) task.partial = text.trim();
              case 'final':
                final text = parsed['text'];
                if (text is String) {
                  task.text = text.trim();
                  sawFinal = true;
                }
              case 'error':
                final msg = parsed['message'];
                if (msg is String && msg.trim().isNotEmpty) eventError = msg.trim();
              case 'closed':
                final reason = parsed['reason'];
                if (reason is String && reason.isNotEmpty) {
                  closedReason = reason;
                  if (reason == 'no_speech' && !sawFinal) task.text = '';
                }
            }
            return;
          }
        } on FormatException {
          // plain-text fallback below
        }
      }
      final bytes = utf8.encode('$raw\n');
      if (out.length + bytes.length <= maxOutput) out.add(bytes);
    }

    final Future<void> outDone;
    if (task.kind == 'dictate') {
      outDone = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
        outTail += chunk;
        final parts = outTail.split('\n');
        outTail = parts.removeLast();
        if (outTail.length > 64 * 1024) outTail = outTail.substring(outTail.length - 64 * 1024);
        parts.forEach(handleDictateOutLine);
      }).asFuture<void>();
    } else {
      outDone = process.stdout.listen((c) {
        if (out.length + c.length <= maxOutput) out.add(c);
      }).asFuture<void>();
    }
    final errDone = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      tail += chunk;
      final parts = tail.split(RegExp(r'[\r\n]'));
      tail = parts.removeLast();
      if (tail.length > _stderrTail) tail = tail.substring(tail.length - _stderrTail);
      parts.forEach(line);
      // a progress bar without a line end yet
      if (task.kind == 'download') {
        final m = _percent.allMatches(tail).lastOrNull;
        if (m != null) task.progress = (double.tryParse(m[1]!.replaceAll(',', '.')) ?? 0).clamp(0, 100).toDouble();
      }
    }).asFuture<void>();
    int? code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      code = null;
    } finally {
      if (keepStdin) task.closeStdin();
    }
    await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 1), onTimeout: () => const []);
    if (task.kind == 'dictate' && outTail.isNotEmpty) handleDictateOutLine(outTail);
    line(tail);
    final stdout = utf8.decode(out.takeBytes(), allowMalformed: true).trim();
    final said = lines.lastOrNull;
    if (task.cancelled) {
      // a .part left behind by the killed curl, nothing else (never `model remove`: the
      // download may have just finished)
      if (task.kind == 'download' && task.file != null) _removePart(task.file!);
      task.finish('cancelled', ctx.clock());
    } else if (code == null) {
      task.finish('failed', ctx.clock(), message: tr('it took too long and was stopped'));
    } else if (task.kind == 'wake') {
      Object? answer;
      try {
        answer = jsonDecode(stdout.split('\n').last);
      } on FormatException {
        answer = null;
      }
      if ((code == 0 || code == 1 || code == 3) && answer is Map<String, dynamic>) {
        task.result = answer;
        task.finish('succeeded', ctx.clock());
      } else {
        task.finish('failed', ctx.clock(), message: said ?? trf('exit {0}', [code]));
      }
    } else if (task.kind == 'download') {
      if (code == 0) {
        task.progress = 100;
        task.path = stdout.split('\n').last.trim();
        task.finish('succeeded', ctx.clock());
      } else {
        task.finish('failed', ctx.clock(), message: said ?? trf('exit {0}', [code]));
      }
    } else if (sawEvents) {
      if (closedReason == 'no_speech' && !sawFinal) task.text = '';
      if (code == 0) {
        task.finish('succeeded', ctx.clock(), message: task.text.isEmpty ? (eventError ?? said) : null);
      } else if (closedReason == 'no_speech' && eventError == null) {
        task.finish('succeeded', ctx.clock(), message: said);
      } else {
        task.finish('failed', ctx.clock(), message: eventError ?? said ?? trf('exit {0}', [code]));
      }
    } else {
      // dictate (plain-text fallback): 0 text (or an engine typed it: said), 3 no speech, else the reason
      task.text = stdout;
      if (code == 0) {
        task.finish('succeeded', ctx.clock(), message: stdout.isEmpty ? said : null);
      } else {
        task.finish('failed', ctx.clock(), message: said ?? trf('exit {0}', [code]));
      }
    }
  }
}

/// A download, a try or a wake test, as `voice.tasks` shows it.
final class VoiceTask {
  VoiceTask(this.kind, this.started, {this.model, this.seconds});
  final String kind;
  final String? model;
  final int? seconds;
  final DateTime started;
  DateTime? ended;
  String state = 'running';
  double? progress;
  double? level;
  double? peak;
  String partial = '';
  String text = '';
  String? path, message;

  /// A wake test's answer.
  Map<String, dynamic>? result;

  /// A download's file name in the service's folder (from its catalog).
  String? file;
  Process? process;
  bool cancelled = false;
  bool _stdinClosed = false;

  void closeStdin({bool cancel = false}) {
    if (_stdinClosed) return;
    _stdinClosed = true;
    final p = process;
    if (p == null) return;
    try {
      if (cancel) p.stdin.writeln('cancel');
    } on Object {
      // process may already have exited
    }
    try {
      p.stdin.close().catchError((_) {}).ignore();
    } on Object {
      // already closed
    }
  }

  void finish(String to, DateTime at, {String? message}) {
    state = to;
    ended = at;
    if (message != null) this.message = message;
    process = null;
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'state': state,
    'model': ?model,
    'seconds': ?seconds,
    'started': started.toUtc().toIso8601String(),
    if (ended != null) 'ended': ended!.toUtc().toIso8601String(),
    if (kind == 'download') 'progress': progress,
    if (kind == 'dictate') ...{'partial': partial, 'text': text, 'level': level, 'peak': peak},
    if (kind == 'wake') 'result': result,
    'path': ?path,
    'message': ?message,
  };
}
