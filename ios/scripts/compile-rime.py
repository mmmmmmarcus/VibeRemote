#!/usr/bin/env python3
"""Compile bundled dictionaries on the Mac, never in the keyboard extension."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
resources = root / 'Typing/Resources/Rime'
# Fail before deployment if a vendored source was edited or only partly downloaded.
provenance = json.loads((resources / 'dictionary-provenance.json').read_text())
sources = provenance['files'] | provenance.get('local_tables', {}) | provenance.get('local_resources', {})
for name, metadata in sources.items():
    if hashlib.sha256((resources / name).read_bytes()).hexdigest() != metadata['sha256']:
        raise SystemExit('Dictionary source checksum mismatch: ' + name)
library = root / 'build/dependencies/librime-static.xcframework/macos-arm64_x86_64'
with tempfile.TemporaryDirectory(prefix='vvhisper-rime-') as temporary:
    work = Path(temporary)
    compiler = work / 'compile-rime'
    subprocess.run(['xcrun', 'clang++', '-arch', 'arm64', '-std=c++17',
                    '-I' + str(library / 'Headers'), str(root / 'scripts/compile-rime.cpp'),
                    str(library / 'librime.a'), '-framework', 'CoreFoundation',
                    '-o', str(compiler)], check=True)
    source = work / 'source'
    shutil.copytree(resources, source, ignore=shutil.ignore_patterns('build'))
    user = work / 'user'
    user.mkdir()
    subprocess.run([str(compiler), str(source), str(user)], check=True)
    for name in ('vvhisper_pinyin.schema.yaml', 'vvhisper_lexicon.prism.bin',
                 'vvhisper_lexicon.table.bin', 'vvhisper_lexicon.reverse.bin'):
        if not (user / 'build' / name).is_file():
            raise SystemExit('Missing compiled dictionary: ' + name)
    # Bundle compiled tables and notices, not the build-time YAML sources.
    # The complete, unmodified dictionary sources remain in the repository.
    destination = root / 'build/resources/Rime'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(user / 'build', destination / 'build')
    shutil.copytree(resources / 'Licenses', destination / 'Licenses')
    for name in ('PinyinSyllables.txt', 'EnglishWords.txt', 'Pinyin-LICENSE.txt', 'RimeIce-LICENSE.txt', 'VvhisperLexicon-LICENSE.txt',
                 'dictionary-provenance.json'):
        shutil.copyfile(resources / name, destination / name)
