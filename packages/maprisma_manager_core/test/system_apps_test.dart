import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late World w;

  setUp(() {
    configureLanguage('en');
    w = World.create();
  });

  tearDown(() => w.dispose());

  void addExe(String name, [String script = '#!/bin/sh\nexit 0\n']) {
    w.writeFile(p.join(w.fakeBin, name), script, mode: '755');
  }

  test('lists installed non-Maprisma apps across sources and excludes Maprisma apps', () async {
    addExe('firefox');
    addExe('spotify-launcher');
    addExe('flatpak', '''#!/bin/sh
if [ "\$1" = "list" ]; then
  printf 'org.gimp.GIMP\\t2.10.38\\t250 MB\\tflathub\\tCreate images and edit photographs\\n'
fi
''');
    addExe('google-chrome');
    addExe('mytool');
    addExe('maprisma-launcher');

    final sysApps = w.paths.sys('/usr/share/applications');
    final flatpakApps = w.paths.sys('/var/lib/flatpak/exports/share/applications');
    final userApps = w.paths.apps;

    // Official pacman app
    w.writeFile(p.join(sysApps, 'firefox.desktop'), '''
[Desktop Entry]
Type=Application
Name=Firefox
Comment=Browse the Web
Exec=firefox %u
Icon=firefox
Actions=new-private-window;

[Desktop Action new-private-window]
Name=New Private Window
Exec=firefox --private-window
''');

    // AUR app
    w.writeFile(p.join(sysApps, 'spotify.desktop'), '''
[Desktop Entry]
Type=Application
Name=Spotify
Comment=Music streaming
Exec=spotify-launcher
''');

    // Flatpak app
    w.writeFile(p.join(flatpakApps, 'org.gimp.GIMP.desktop'), '''
[Desktop Entry]
Type=Application
Name=GIMP
Exec=flatpak run org.gimp.GIMP
X-Flatpak=org.gimp.GIMP
''');

    // Browser PWA (even with NoDisplay=true, included like Launcher)
    w.writeFile(p.join(userApps, 'chrome-abc123-Default.desktop'), '''
[Desktop Entry]
Type=Application
Name=YouTube
Exec=google-chrome --app-id=abc123
StartupWMClass=crx_abc123
NoDisplay=true
''');

    // Local user app
    w.writeFile(p.join(userApps, 'mytool.desktop'), '''
[Desktop Entry]
Type=Application
Name=My Local Tool
Comment=Handcrafted helper
Exec=mytool
''');

    // Standalone AppImage
    w.writeFile(p.join(w.home, 'Applications/TaskManagerOG-1.1.1-x86_64.AppImage'), '#!/bin/sh\nexit 0\n', mode: '755');

    // Maprisma apps that MUST be excluded
    w.writeFile(p.join(userApps, 'com.maprisma.Settings.desktop'), '''
[Desktop Entry]
Type=Application
Name=Maprisma Settings
Exec=mytool
''');
    w.writeFile(p.join(userApps, 'io.github.ubruckhaus.CosmicMaprismaWlan.desktop'), '''
[Desktop Entry]
Type=Application
Name=Maprisma WLAN Monitor
Exec=mytool
''');
    w.writeFile(p.join(sysApps, 'maprisma-launcher.desktop'), '''
[Desktop Entry]
Type=Application
Name=Maprisma Launcher
Exec=maprisma-launcher
''');

    // Fake pacman DB + pacman binary
    final pacLocal = w.paths.sys('/var/lib/pacman/local');
    w.writeFile(p.join(pacLocal, 'firefox-132.0-1/desc'), '''
%NAME%
firefox

%VERSION%
132.0-1

%DESC%
Fast, Private & Safe Web Browser

%URL%
https://www.mozilla.org/firefox/

%SIZE%
260000000

%INSTALLDATE%
1700000000
''');
    w.writeFile(p.join(pacLocal, 'spotify-launcher-0.6.1-1/desc'), '''
%NAME%
spotify-launcher

%VERSION%
0.6.1-1

%URL%
https://aur.archlinux.org/packages/spotify-launcher
''');

    addExe('pacman', '''#!/bin/sh
case "\$1" in
  -Qo)
    shift; [ "\$1" = "--" ] && shift
    for f in "\$@"; do
      case "\$f" in
        *firefox.desktop) echo "\$f is owned by firefox 132.0-1" ;;
        *spotify.desktop) echo "\$f is owned by spotify-launcher 0.6.1-1" ;;
      esac
    done
    ;;
  -Qqm)
    echo "spotify-launcher"
    ;;
esac
''');

    // Theme icon for firefox
    w.writeFile(p.join(w.paths.sys('/usr/share/icons/hicolor/scalable/apps/firefox.svg')), '<svg xmlns="http://www.w3.org/2000/svg"/>');

    // Default browser in mimeapps.list
    w.writeFile(p.join(w.paths.config, 'mimeapps.list'), '''
[Default Applications]
x-scheme-handler/http=firefox.desktop
''');

    final core = w.core(extra: {'XDG_DATA_DIRS': '/usr/share'});
    final res = await core.call('system_apps.list');
    final apps = (res['apps'] as List).cast<Map<String, dynamic>>();
    final byId = {for (final a in apps) a['id'] as String: a};

    expect(byId.keys, containsAll(['firefox.desktop', 'spotify.desktop', 'org.gimp.GIMP.desktop', 'chrome-abc123-Default.desktop', 'mytool.desktop', 'appimage:TaskManagerOG-1.1.1-x86_64.AppImage']));
    // Maprisma apps excluded!
    expect(byId.keys.any((k) => k.contains('maprisma') || k.contains('ubruckhaus')), isFalse);

    final ff = byId['firefox.desktop']!;
    expect(ff['source'], 'pacman');
    expect(ff['version'], '132.0-1');
    expect(ff['website'], 'https://www.mozilla.org/firefox/');
    expect(ff['defaultRoles'], contains('browser'));
    expect((ff['actions'] as List).length, 1);
    expect((ff['icon'] as Map)['file'], endsWith('firefox.svg'));

    expect(byId['spotify.desktop']!['source'], 'aur');
    expect(byId['org.gimp.GIMP.desktop']!['source'], 'flatpak');
    expect(byId['org.gimp.GIMP.desktop']!['version'], '2.10.38');
    expect(byId['chrome-abc123-Default.desktop']!['source'], 'webapp');
    expect(byId['chrome-abc123-Default.desktop']!['browser'], 'Chrome');
    expect(byId['mytool.desktop']!['source'], 'local');
    final ai = byId['appimage:TaskManagerOG-1.1.1-x86_64.AppImage']!;
    expect(ai['source'], 'appimage');
    expect(ai['name'], 'TaskManagerOG');
    expect(ai['version'], '1.1.1');
  });

  test('check_updates attaches pacman, AUR, and Flatpak updates', () async {
    addExe('firefox');
    addExe('spotify-launcher');
    addExe('flatpak', '''#!/bin/sh
if [ "\$1" = "list" ]; then
  printf 'org.gimp.GIMP\\t2.10.38\\t250 MB\\tflathub\\tEditor\\n'
elif [ "\$1" = "remote-ls" ]; then
  printf 'org.gimp.GIMP\\t3.0.0\\n'
fi
''');
    addExe('checkupdates', '#!/bin/sh\necho "firefox 132.0-1 -> 133.0-1"\n');
    addExe('paru', '#!/bin/sh\nif [ "\$1" = "-Qua" ]; then echo "spotify-launcher 0.6.1-1 -> 0.6.2-1"; fi\n');
    addExe('pacman', '''#!/bin/sh
case "\$1" in
  -Qo)
    shift; [ "\$1" = "--" ] && shift
    for f in "\$@"; do
      case "\$f" in
        *firefox.desktop) echo "\$f is owned by firefox 132.0-1" ;;
        *spotify.desktop) echo "\$f is owned by spotify-launcher 0.6.1-1" ;;
      esac
    done
    ;;
  -Qqm) echo "spotify-launcher" ;;
esac
''');

    final sysApps = w.paths.sys('/usr/share/applications');
    w.writeFile(p.join(sysApps, 'firefox.desktop'), '[Desktop Entry]\nType=Application\nName=Firefox\nExec=firefox\n');
    w.writeFile(p.join(sysApps, 'spotify.desktop'), '[Desktop Entry]\nType=Application\nName=Spotify\nExec=spotify-launcher\n');
    w.writeFile(p.join(w.paths.sys('/var/lib/flatpak/exports/share/applications/org.gimp.GIMP.desktop')), '[Desktop Entry]\nType=Application\nName=GIMP\nExec=flatpak run org.gimp.GIMP\nX-Flatpak=org.gimp.GIMP\n');

    final core = w.core(extra: {'XDG_DATA_DIRS': '/usr/share'});
    final chk = await core.call('system_apps.check_updates', {'force': true});
    expect(chk['updates'], 3);
    final apps = ((await core.call('system_apps.list'))['apps'] as List).cast<Map<String, dynamic>>();
    final byId = {for (final a in apps) a['id'] as String: a};
    expect((byId['firefox.desktop']!['update'] as Map)['available'], '133.0-1');
    expect((byId['spotify.desktop']!['update'] as Map)['available'], '0.6.2-1');
    expect((byId['org.gimp.GIMP.desktop']!['update'] as Map)['available'], '3.0.0');
  });

  test('autostart toggles, remove_plan checks pacman dependencies, and trash job removes local app', () async {
    addExe('firefox');
    addExe('mytool');
    addExe('pacman', '''#!/bin/sh
case "\$1" in
  -Qo)
    shift; [ "\$1" = "--" ] && shift
    for f in "\$@"; do
      case "\$f" in
        *firefox.desktop) echo "\$f is owned by firefox 132.0-1" ;;
      esac
    done
    ;;
  -Qi)
    echo "Name            : firefox"
    echo "Required By     : firefox-i18n-de"
    ;;
esac
''');

    w.writeFile(p.join(w.paths.sys('/usr/share/applications/firefox.desktop')), '[Desktop Entry]\nType=Application\nName=Firefox\nExec=firefox\n');
    final localDesktop = p.join(w.paths.apps, 'mytool.desktop');
    w.writeFile(localDesktop, '[Desktop Entry]\nType=Application\nName=My Tool\nExec=mytool\n');

    final core = w.core(extra: {'XDG_DATA_DIRS': '/usr/share'});
    await core.call('system_apps.list');

    // Autostart toggle
    await core.call('system_apps.autostart', {'id': 'mytool.desktop', 'on': true});
    expect(File(p.join(w.paths.autostart, 'mytool.desktop')).existsSync(), isTrue);
    var apps = ((await core.call('system_apps.list'))['apps'] as List).cast<Map<String, dynamic>>();
    expect(apps.firstWhere((a) => a['id'] == 'mytool.desktop')['autostart'], isTrue);

    await core.call('system_apps.autostart', {'id': 'mytool.desktop', 'on': false});
    expect(File(p.join(w.paths.autostart, 'mytool.desktop')).existsSync(), isFalse);

    // Pacman Required By blocks removal
    final ffPlan = await core.call('system_apps.remove_plan', {'id': 'firefox.desktop'});
    expect(ffPlan['neededBy'], ['firefox-i18n-de']);
    expect(ffPlan['blocked'], isNotNull);

    // Local app remove plan + job moves file to Trash
    final localPlan = await core.call('system_apps.remove_plan', {'id': 'mytool.desktop'});
    expect(localPlan['kind'], 'trash');
    expect(localPlan['blocked'], isNull);

    final started = await core.call('system_jobs.start', {'app': 'mytool.desktop', 'kind': 'remove'});
    final jobId = started['id'] as String;
    Map<String, dynamic> state = started;
    for (var i = 0; i < 40 && state['state'] != 'succeeded' && state['state'] != 'failed'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      state = await core.call('system_jobs.get', {'id': jobId});
    }
    expect(state['state'], 'succeeded');
    expect(File(localDesktop).existsSync(), isFalse);
    expect(File(p.join(w.paths.data, 'Trash/files/mytool.desktop')).existsSync(), isTrue);
  });
}
