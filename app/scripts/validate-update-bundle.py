#!/usr/bin/env python3
import json, pathlib, plistlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1])
config = json.loads((root / 'Release/update-config.json').read_text())
with (app / 'Contents/Info.plist').open('rb') as f:
    info = plistlib.load(f)
for name, expected in [('SUFeedURL', config['feedURL']), ('SUPublicEDKey', config['publicKey']),
                       ('CFBundleIdentifier', 'com.viberemote.app'), ('LSMinimumSystemVersion', '27.0')]:
    if info.get(name) != expected:
        raise SystemExit(f'Release configuration mismatch: {name}')
if not str(info.get('CFBundleVersion', '')).isdigit() or int(info['CFBundleVersion']) < 2:
    raise SystemExit('A monotonically increasing integer build number is required')
framework = app / 'Contents/Frameworks/Sparkle.framework'
if not framework.exists():
    raise SystemExit('Missing embedded Sparkle framework')
packetlogger = app / 'Contents/Resources/PacketLogger.app'
if packetlogger.exists():
    # Personal builds retain Apple's complete, original signed bundle. Never thin it.
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R=identifier \"com.apple.PacketLogger\" and anchor apple', str(packetlogger)], check=True)
for path in app.rglob('*'):
    if packetlogger in path.parents:
        continue
    if path.is_symlink() or not path.is_file():
        continue
    kind = subprocess.check_output(['file', '-b', str(path)], text=True)
    if 'Mach-O' in kind:
        arch = subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip()
        if arch != 'arm64':
            raise SystemExit(f'Non-arm64 release binary: {path}: {arch}')
print('Update configuration and arm64 bundle validated')
