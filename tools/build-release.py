#!/usr/bin/env python3
"""Build a Maprisma Settings release: dist/maprisma-settings-<version>-x86_64.tar.gz and its SHA-256
(after Maprisma Launcher's tools/build-release.py).

The committed files are copied to a clean folder and built there with `tools/install-local --stage`
(translations, a fresh Flutter release build, the core CLI, the bar icon when cargo is there, the
links of the old names), the release identity is checked, and one folder
maprisma-settings-<version>/ is packed:
    app/                      the bundle (maprisma-settings, lib/, data/, bin/maprisma-settings-core,
                              bin/maprisma-settings-applet and -tray)
    share/applications/       com.maprisma.Settings.desktop
    share/metainfo/           com.maprisma.Settings.metainfo.xml
    share/icons/hicolor/scalable/apps/com.maprisma.Settings.svg
    LICENSE
The AppImage is made from it (packaging/build-appimage.py).

    tools/build-release.py
"""
import hashlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'com.maprisma.Settings'
BINARY = 'maprisma-settings'


def version() -> str:
    found = re.search(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)', (ROOT / 'flutter_app/pubspec.yaml').read_text(), re.M)
    if not found:
        sys.exit('no version in flutter_app/pubspec.yaml')
    return found.group(1)


def check_identity(src: Path, ver: str):
    cmake = (src / 'flutter_app/linux/CMakeLists.txt').read_text()
    if f'set(APPLICATION_ID "{APP_ID}")' not in cmake or f'set(BINARY_NAME "{BINARY}")' not in cmake:
        sys.exit('Unexpected application id or binary name in flutter_app/linux/CMakeLists.txt')
    core = (src / 'packages/maprisma_manager_core/lib/src/core.dart').read_text()
    if f"const coreVersion = '{ver}';" not in core:
        sys.exit(f'coreVersion in packages/maprisma_manager_core/lib/src/core.dart is not {ver}')
    meta = (src / f'packaging/{APP_ID}.metainfo.xml').read_text()
    if f'<release version="{ver}"' not in meta:
        sys.exit(f'The metainfo has no <release version="{ver}">: add it before building')


def main():
    ver = version()
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    files = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, check=True, capture_output=True).stdout.split(b'\0')
    with tempfile.TemporaryDirectory(prefix='release-', dir=dist) as temp:
        src = Path(temp) / 'src'
        for name in filter(None, files):
            rel = Path(name.decode())
            if not (ROOT / rel).is_file():
                continue
            (src / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, src / rel)
        check_identity(src, ver)
        stage = Path(temp) / 'stage'
        subprocess.run([str(src / 'tools/install-local'), '--stage', str(stage)], cwd=src, check=True)
        bundle = stage / 'bundle'
        for need in (BINARY, 'bin/maprisma-settings-core', 'bin/maprisma-settings-applet', 'bin/maprisma-settings-tray'):
            if not (bundle / need).is_file():
                sys.exit(f'no {need} in the bundle')
        top = Path(temp) / f'{BINARY}-{ver}'
        shutil.copytree(bundle, top / 'app', symlinks=True)
        for name, sub in ((f'{APP_ID}.desktop', 'applications'), (f'{APP_ID}.metainfo.xml', 'metainfo'),
                          (f'{APP_ID}.svg', 'icons/hicolor/scalable/apps')):
            (top / 'share' / sub).mkdir(parents=True, exist_ok=True)
            shutil.copy2(src / 'packaging' / name, top / 'share' / sub / name)
        shutil.copy2(src / 'LICENSE', top / 'LICENSE')
        archive = dist / f'{BINARY}-{ver}-x86_64.tar.gz'

        def owned(info):          # root-owned in any package made from it, no build user's names
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            return info
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(top, arcname=top.name, filter=owned)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (dist / f'{archive.name}.sha256').write_text(f'{digest}  {archive.name}\n')
    print(f'\n{archive}\nsha256 {digest}')


if __name__ == '__main__':
    main()
