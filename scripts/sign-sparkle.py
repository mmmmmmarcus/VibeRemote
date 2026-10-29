#!/usr/bin/env python3
"""Sign Sparkle from the inside out after architecture thinning."""
import pathlib, subprocess, sys
framework, identity = pathlib.Path(sys.argv[1]), sys.argv[2]
args = ['codesign', '--force', '--preserve-metadata=identifier,entitlements', '--options', 'runtime', '--timestamp' if identity != '-' else '--timestamp=none', '--sign', identity]
# Sign nested binaries first, then their containers and finally the framework.
for path in framework.rglob('*'):
    if path.is_file() and not path.is_symlink():
        kind = subprocess.check_output(['file', '-b', str(path)], text=True)
        if 'Mach-O' in kind:
            subprocess.run(args + [str(path)], check=True)
containers = [p for p in framework.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.app', '.xpc')]
for path in sorted(containers, key=lambda p: len(p.parts), reverse=True) + [framework]:
    subprocess.run(args + [str(path)], check=True)
