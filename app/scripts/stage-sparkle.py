#!/usr/bin/env python3
"""Stage SwiftPM's verified Sparkle artifact and thin shipped code to arm64."""
import pathlib, shutil, subprocess, sys
scratch, destination = map(pathlib.Path, sys.argv[1:])
frameworks = list((scratch / 'artifacts').glob('**/macos-arm64_x86_64/Sparkle.framework'))
if len(frameworks) != 1:
    raise SystemExit('Expected exactly one resolved Sparkle macOS framework')
source = frameworks[0]
if destination.exists():
    shutil.rmtree(destination)
subprocess.run(['ditto', str(source), str(destination)], check=True)
license_path = source.parents[2] / 'LICENSE'
shutil.copy2(license_path, destination / 'Versions/B/Resources/Sparkle-LICENSE.txt')
for path in destination.rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    kind = subprocess.check_output(['file', '-b', str(path)], text=True)
    if 'Mach-O' not in kind:
        continue
    architectures = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
    if 'arm64' not in architectures:
        raise SystemExit(f'Unsupported Sparkle architecture: {path}')
    if architectures != ['arm64']:
        temporary = path.with_name(path.name + '.arm64')
        subprocess.run(['lipo', str(path), '-thin', 'arm64', '-output', str(temporary)], check=True)
        temporary.chmod(path.stat().st_mode)
        temporary.replace(path)
print('Staged arm64 Sparkle framework')
