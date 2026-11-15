// The Ask AI rules (docs/ask-ai-rules.md): reading (restrictive when malformed), writing under the
// shared lock, the decision, and the log.
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/src/ai/rules.dart';
import 'package:maprisma_manager_core/src/ai/posix.dart';
import 'package:maprisma_manager_core/src/paths.dart';
import 'package:maprisma_manager_core/src/ai/shared_helper.dart';
import 'package:maprisma_manager_core/src/translations_generated.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;
  setUp(() => w = World.create());
  tearDown(() => w.dispose());
  File shared() => File(sharedAiFile(w.paths));
  void write(Object v) => shared()
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(v));

  test('no file: everything allowed, level review', () {
    final r = readAskAiRules(w.paths);
    expect(r.level, 'review');
    expect(r.broken, isFalse);
    expect(askAiAllowed(w.paths, 'launcher.remove'), isTrue);
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'aur'), isTrue);
  });

  test('switches, sources and the Downloads folder decide; answers switches all off', () {
    write({
      'helper': 'auto',
      'ask_ai': {
        'level': 'review',
        'actions': {'launcher.remove': false},
        'sources': {'aur': false},
        'folders': {'downloads': false},
      },
    });
    expect(askAiAllowed(w.paths, 'launcher.remove'), isFalse);
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'pacman'), isTrue);
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'aur'), isFalse);
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'local'), isFalse); // downloads off
    write({'ask_ai': {'level': 'answers'}});
    expect(askAiAllowed(w.paths, 'theme.apply'), isFalse);
  });

  test('malformed is restrictive and reported', () {
    write({'ask_ai': 'off'});
    expect(readAskAiRules(w.paths).level, 'answers');
    write({'ask_ai': {'actions': {'launcher.remove': 'false'}}});
    expect(askAiAllowed(w.paths, 'launcher.remove'), isFalse);
    expect(readAskAiRules(w.paths).broken, isTrue);
    write({'ask_ai': {'sources': ['aur']}});
    expect(askAiAllowed(w.paths, 'launcher.install', source: 'pacman'), isFalse);
    write({'ask_ai': {'actions': null}}); // null isn't an object: restrictive, like the apps
    expect(askAiAllowed(w.paths, 'launcher.install'), isFalse);
    write({'ask_ai': null});
    expect(readAskAiRules(w.paths).level, 'answers');
    write({'ask_ai': {'level': 'yolo'}});
    expect(readAskAiRules(w.paths).level, 'answers');
    shared().writeAsStringSync('{not json');
    expect(readAskAiRules(w.paths).broken, isTrue);
    expect(askAiAllowed(w.paths, 'theme.apply'), isFalse);
  });

  test('a switch keeps the other keys; a broken file is never rewritten, only reset', () {
    write({'helper': 'claude', 'web_search': true});
    writeAskAiRule(w.paths, kind: 'actions', id: 'launcher.remove', on: false);
    writeAskAiRule(w.paths, level: 'answers');
    final v = jsonDecode(shared().readAsStringSync()) as Map;
    expect(v['helper'], 'claude');
    expect(v['web_search'], isTrue);
    expect((v['ask_ai'] as Map)['actions'], {'launcher.remove': false});
    expect((v['ask_ai'] as Map)['level'], 'answers');
    expect(() => writeAskAiRule(w.paths, kind: 'actions', id: 'nope', on: false), throwsArgumentError);
    shared().writeAsStringSync('{broken');
    expect(() => writeAskAiRule(w.paths, level: 'review'), throwsA(isA<FileSystemException>()));
    expect(() => writeSharedHelper(w.paths, 'auto'), throwsA(isA<FileSystemException>()));
    expect(shared().readAsStringSync(), '{broken');
    resetAskAiRules(w.paths);
    expect(readAskAiRules(w.paths).broken, isFalse);
    expect(Directory(p.dirname(shared().path)).listSync().where((e) => e.path.contains('.broken-')), hasLength(1));
  });

  test('the log: appended, newest first, trimmed, cleared; private', () {
    for (var i = 0; i < askAiLogMax + 5; i++) {
      appendAskAiLog(w.paths, op: 'op$i', app: 'launcher', action: 'launcher.install', target: 'x$i', result: 'started');
    }
    final entries = readAskAiLog(w.paths, limit: 3);
    expect([for (final e in entries) e['op']], ['op1004', 'op1003', 'op1002']);
    final lines = File(askAiLogFile(w.paths)).readAsLinesSync();
    expect(lines.length, lessThanOrEqualTo(askAiLogKeep + 5));
    expect(File(askAiLogFile(w.paths)).statSync().mode & 0x1ff, 0x180);
    expect(readAskAiLog(w.paths).first['target'], 'x1004');
    clearAskAiLog(w.paths);
    expect(readAskAiLog(w.paths), isEmpty);
  });

  test('ai.rules view: effective state follows the level', () {
    write({'ask_ai': {'level': 'answers', 'actions': {'theme.apply': false}}});
    final v = askAiRulesView(w.paths);
    final apply = (v['actions'] as List).firstWhere((a) => a['id'] == 'theme.apply') as Map;
    final install = (v['actions'] as List).firstWhere((a) => a['id'] == 'launcher.install') as Map;
    expect(apply['on'], isFalse);
    expect(install['on'], isTrue);
    expect(install['effective'], isFalse);
  });
  test('nested edits preserve unknown and malformed fields', () {
    write({'ask_ai': {'future': {'x': 1}, 'actions': {'unknown': null, 'theme.apply': 'bad'}}});
    writeAskAiRule(w.paths, kind: 'actions', id: 'launcher.remove', on: false);
    final rules = (jsonDecode(shared().readAsStringSync()) as Map)['ask_ai'] as Map;
    expect(rules['future'], {'x': 1});
    expect(rules['actions'], {'unknown': null, 'theme.apply': 'bad', 'launcher.remove': false});
    expect(askAiAllowed(w.paths, 'theme.apply'), isFalse);
  });

  test('view distinguishes partial damage and dependent local source', () {
    write({'ask_ai': {'actions': {'theme.apply': null}, 'folders': {'downloads': false}}});
    final view = askAiRulesView(w.paths);
    expect(view['broken'], isTrue);
    expect(view['answers_only_error'], isFalse);
    expect((view['sources'] as List).firstWhere((i) => i['id'] == 'local')['effective'], isFalse);
    expect(askAiAllowed(w.paths, 'launcher.remove'), isTrue);
    write({'ask_ai': null});
    expect(askAiRulesView(w.paths)['answers_only_error'], isTrue);
  });

  test('append repairs incomplete tails and tolerates invalid UTF8 during rotation', () {
    final log = File(askAiLogFile(w.paths))..createSync(recursive: true);
    log.writeAsBytesSync([255, 10, ...utf8.encode('{"time":')]);
    appendAskAiLog(w.paths, op: 'recovered', app: 'settings', action: 'settings.updates', target: 'x', result: 'done');
    expect(readAskAiLog(w.paths).single['op'], 'recovered');
    log.writeAsBytesSync([...List.filled(askAiLogBytes + 1, 255), 10]);
    expect(() => appendAskAiLog(w.paths, op: 'rotated', app: 'settings', action: 'settings.updates', target: 'x', result: 'done'), returnsNormally);
    expect(readAskAiLog(w.paths).first['op'], 'rotated');
  });

  test('append and clear refuse symlink data files', () {
    final log = File(askAiLogFile(w.paths));
    log.parent.createSync(recursive: true);
    final target = File(p.join(w.paths.state, 'untouched'))..writeAsStringSync('keep');
    Link(log.path).createSync(target.path);
    appendAskAiLog(w.paths, op: 'x', app: 'settings', action: 'settings.updates', target: 'x', result: 'done');
    clearAskAiLog(w.paths);
    expect(target.readAsStringSync(), 'keep');
  });

  test('locks reject special files and links and correct regular file permissions', () {
    final lock = File(sharedAiLock(w.paths));
    lock.parent.createSync(recursive: true);
    lock.writeAsStringSync('');
    chmodPath(lock.path, 0x1ff);
    expect(Posix.instance.withFlock(lock.path, () => 42), 42);
    expect(lock.statSync().mode & 0x1ff, 0x180);
    lock.deleteSync();
    final target = File('${lock.path}.target')..writeAsStringSync('keep');
    Link(lock.path).createSync(target.path);
    expect(() => Posix.instance.withFlock(lock.path, () => fail('called')), throwsA(isA<FileSystemException>()));
    Link(lock.path).deleteSync();
    expect(Process.runSync('mkfifo', [lock.path]).exitCode, 0);
    expect(() => Posix.instance.withFlock(lock.path, () => fail('called')), throwsA(isA<FileSystemException>()));
    expect(target.readAsStringSync(), 'keep');
  });

  test('default-off ids: only true allows; a reset leaves them off; the rest stays missing = on', () {
    expect(askAiAllowed(w.paths, 'mail.move'), isFalse);
    expect(askAiAllowed(w.paths, 'mail.trash'), isFalse);
    expect(askAiAllowed(w.paths, 'mail.archive'), isTrue);
    expect(askAiDataAllowed(w.paths, 'mail.attachments'), isFalse);
    write({'ask_ai': {'actions': {'mail.move': true, 'mail.trash': false, 'mail.draft': false}}});
    expect(askAiAllowed(w.paths, 'mail.move'), isTrue);
    expect(askAiAllowed(w.paths, 'mail.trash'), isFalse);
    expect(askAiAllowed(w.paths, 'mail.draft'), isFalse);
    write({'ask_ai': {'actions': {'mail.move': 'yes'}}});
    expect(askAiAllowed(w.paths, 'mail.move'), isFalse);
    expect(readAskAiRules(w.paths).broken, isTrue);
    write({'ask_ai': {'actions': {'mail.move': true, 'mail.trash': true}, 'data': {'mail.attachments': true}}});
    writeAskAiRule(w.paths, kind: 'data', id: 'mail.online', on: false);
    expect(askAiDataAllowed(w.paths, 'mail.attachments'), isTrue);
    resetAskAiRules(w.paths);
    expect(askAiAllowed(w.paths, 'mail.move'), isFalse);
    expect(askAiAllowed(w.paths, 'mail.trash'), isFalse);
    expect(askAiDataAllowed(w.paths, 'mail.attachments'), isFalse);
    expect(askAiDataAllowed(w.paths, 'mail.online'), isTrue);
    expect(askAiAllowed(w.paths, 'mail.label'), isTrue);
  });

  test('data ids: own kind, independent of the level; malformed data is all off', () {
    expect(askAiDataAllowed(w.paths, 'mail.online'), isTrue);
    expect(askAiDataAllowed(w.paths, 'mail.tone_samples'), isTrue);
    writeAskAiRule(w.paths, kind: 'data', id: 'mail.online', on: false);
    writeAskAiRule(w.paths, kind: 'data', id: 'mail.attachments', on: true);
    final stored = (jsonDecode(shared().readAsStringSync()) as Map)['ask_ai'] as Map;
    expect(stored['data'], {'mail.online': false, 'mail.attachments': true});
    expect(askAiDataAllowed(w.paths, 'mail.online'), isFalse);
    expect(askAiDataAllowed(w.paths, 'mail.attachments'), isTrue);
    expect(() => writeAskAiRule(w.paths, kind: 'data', id: 'launcher.remove', on: false), throwsArgumentError);
    // answers only: every action off, the data switches still say what is sent
    writeAskAiRule(w.paths, level: 'answers');
    expect(askAiAllowed(w.paths, 'mail.draft'), isFalse);
    expect(askAiDataAllowed(w.paths, 'mail.attachments'), isTrue);
    expect(askAiDataAllowed(w.paths, 'mail.tone_samples'), isTrue);
    final view = askAiRulesView(w.paths);
    expect(view['level'], 'answers');
    // malformed: not an object, or a known id that isn't a boolean
    write({'ask_ai': {'data': ['mail.online']}});
    expect(askAiDataAllowed(w.paths, 'mail.online'), isFalse);
    expect(askAiDataAllowed(w.paths, 'mail.tone_samples'), isFalse);
    expect(askAiAllowed(w.paths, 'mail.draft'), isTrue); // only the data kind is off
    expect(readAskAiRules(w.paths).broken, isTrue);
    write({'ask_ai': {'data': {'mail.online': 1, 'mail.future': 'x'}}});
    expect(askAiDataAllowed(w.paths, 'mail.online'), isFalse);
    expect(askAiDataAllowed(w.paths, 'mail.tone_samples'), isTrue);
    expect(readAskAiRules(w.paths).broken, isTrue);
    expect(() => writeAskAiRule(w.paths, kind: 'data', id: 'mail.online', on: true), returnsNormally);
    write({'ask_ai': {'data': 'off'}});
    expect(() => writeAskAiRule(w.paths, kind: 'data', id: 'mail.online', on: true), throwsA(isA<FileSystemException>()));
    // an unreadable file or an ask_ai that isn't an object: nothing is sent either
    write({'ask_ai': 'off'});
    expect(askAiDataAllowed(w.paths, 'mail.online'), isFalse);
    shared().writeAsStringSync('{not json');
    expect(askAiDataAllowed(w.paths, 'mail.tone_samples'), isFalse);
  });

  group('Mail installed', () {
    // A fake bundle like Mail's installer makes: ~/.local/bin/maprisma-mail → lib/maprisma-mail/maprisma-mail.
    String bundle(String dir, {bool omamail = true, bool libapp = true, bool executable = true}) {
      final program = File(p.join(dir, 'maprisma-mail'))..createSync(recursive: true);
      if (executable) Process.runSync('chmod', ['755', program.path]);
      if (omamail) File(p.join(dir, 'bin/omamail')).createSync(recursive: true);
      if (libapp) File(p.join(dir, 'lib/libapp.so')).createSync(recursive: true);
      return program.path;
    }

    void desktop(String appsDir, String exec) => File(p.join(appsDir, 'com.maprisma.Mail.desktop'))
      ..createSync(recursive: true)
      ..writeAsStringSync('[Desktop Entry]\nType=Application\nName=Maprisma Mail\nExec=$exec\n');

    Map<String, String> env([Map<String, String> extra = const {}]) => w.env(extra: extra);

    test('the user\'s desktop file, a linked program and the bundle next to it', () {
      expect(mailInstalled(w.paths, env()), isFalse);
      final program = bundle(p.join(w.home, '.local/lib/maprisma-mail'));
      final link = p.join(w.home, '.local/bin/maprisma-mail');
      Directory(p.dirname(link)).createSync(recursive: true);
      Link(link).createSync(program);
      desktop(w.paths.apps, '"$link"');
      expect(mailInstalled(w.paths, env()), isTrue);
      desktop(w.paths.apps, '$link %U');
      expect(mailInstalled(w.paths, env()), isTrue);
      // a link whose bundle is gone, or a missing program
      File(p.join(w.home, '.local/lib/maprisma-mail/lib/libapp.so')).deleteSync();
      expect(mailInstalled(w.paths, env()), isFalse);
      desktop(w.paths.apps, '"${p.join(w.home, 'nowhere')}"');
      expect(mailInstalled(w.paths, env()), isFalse);
      // ~ and variables are not expanded
      desktop(w.paths.apps, '~/.local/bin/maprisma-mail');
      expect(mailInstalled(w.paths, env()), isFalse);
    });

    test('not executable, no omamail, a bare name in PATH, XDG_DATA_HOME', () {
      final dir = p.join(w.dir, 'opt/mail');
      final program = bundle(dir, executable: false);
      desktop(w.paths.apps, program);
      expect(mailInstalled(w.paths, env()), isFalse);
      Process.runSync('chmod', ['755', program]);
      expect(mailInstalled(w.paths, env()), isTrue);
      File(p.join(dir, 'bin/omamail')).deleteSync();
      expect(mailInstalled(w.paths, env()), isFalse);
      File(p.join(dir, 'bin/omamail')).createSync();
      desktop(w.paths.apps, 'maprisma-mail');
      expect(mailInstalled(w.paths, env()), isFalse); // not in PATH
      expect(mailInstalled(w.paths, env({'PATH': '${w.fakeBin}:$dir'})), isTrue);
      final data = p.join(w.dir, 'xdgdata');
      final moved = Paths.fromEnvironment(env({'XDG_DATA_HOME': data}));
      expect(mailInstalled(moved, env({'XDG_DATA_HOME': data})), isFalse);
      desktop(p.join(data, 'applications'), program);
      expect(mailInstalled(moved, env({'XDG_DATA_HOME': data})), isTrue);
    });

    test('a system data folder (XDG_DATA_DIRS or its default) under the root', () {
      final program = bundle(p.join(w.dir, 'opt/mail'));
      desktop(p.join(w.root, 'usr/share/applications'), program);
      expect(mailInstalled(w.paths, env()), isTrue);
      expect(mailInstalled(w.paths, env({'XDG_DATA_DIRS': '/srv/share'})), isFalse);
      desktop(p.join(w.root, 'srv/share/applications'), program);
      expect(mailInstalled(w.paths, env({'XDG_DATA_DIRS': '/srv/share'})), isTrue);
      // the user's file comes first and hides the system's
      desktop(w.paths.apps, '"${p.join(w.dir, 'gone')}"');
      expect(mailInstalled(w.paths, env()), isFalse);
    });

    test('the view leaves Mail out until it is installed; stored switches are kept', () {
      write({'ask_ai': {'actions': {'mail.draft': false}, 'data': {'mail.online': false}}});
      var view = askAiRulesView(w.paths, environment: env());
      expect(view['mail_installed'], isFalse);
      expect((view['actions'] as List).where((a) => a['app'] == 'mail'), isEmpty);
      expect(view['data'], isEmpty);
      expect((view['answers'] as List).where((a) => a['app'] == 'mail'), isEmpty);
      expect(((jsonDecode(shared().readAsStringSync()) as Map)['ask_ai'] as Map)['actions'], {'mail.draft': false});
      desktop(w.paths.apps, bundle(p.join(w.dir, 'opt/mail')));
      writeAskAiRule(w.paths, level: 'answers');
      view = askAiRulesView(w.paths, environment: env());
      expect(view['mail_installed'], isTrue);
      Map item(String kind, String id) => (view[kind] as List).firstWhere((i) => i['id'] == id) as Map;
      expect(item('actions', 'mail.draft')['on'], isFalse);
      expect(item('actions', 'mail.label')['on'], isTrue);
      expect(item('actions', 'mail.label')['effective'], isFalse); // answers only
      expect(item('actions', 'mail.move')['on'], isFalse);
      expect(item('actions', 'mail.move')['default_off'], isTrue);
      expect(item('data', 'mail.online')['on'], isFalse);
      expect(item('data', 'mail.tone_samples')['effective'], isTrue); // data ignores the level
      expect(item('data', 'mail.attachments')['effective'], isFalse);
      expect(item('data', 'mail.attachments')['default_off'], isTrue);
      expect((view['answers'] as List).map((a) => a['id']), contains('mail.answers'));
    });
  });

  test('every label of the page is translated in every language', () {
    for (final i in [...askAiActions, ...askAiSources, ...askAiFolders, ...askAiData, ...askAiAnswers]) {
      for (final code in catalogs.keys) {
        expect(catalogs[code]![i.label], isNotNull, reason: '$code: ${i.label}');
      }
    }
  });
}
