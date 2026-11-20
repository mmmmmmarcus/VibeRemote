"""Build an indexed, offline candidate table from the shared iOS dictionary sources."""
import shutil
import sqlite3
import sys
from pathlib import Path

source, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
path = output / 'pinyin.db'
path.unlink(missing_ok=True)
db = sqlite3.connect(path)
db.execute('CREATE TABLE words(spelling TEXT, word TEXT, weight INTEGER, PRIMARY KEY(spelling, word)) WITHOUT ROWID')


pronunciations = {}


def entries(path):
    for line in path.read_text().splitlines():
        parts = line.split('\t')
        if len(parts) == 2 and not line.startswith('#') and parts[1].isdigit():
            # The Tencent source omits readings. Use the highest-weight character
            # reading where every character is covered by the shared syllabary.
            readings = [pronunciations.get(ch) for ch in parts[0]]
            if readings and all(readings):
                yield ''.join(pair[1] for pair in readings), parts[0], int(parts[1])
        if len(parts) >= 3 and not line.startswith('#') and parts[2].strip().isdigit():
            if len(parts[0]) == 1:
                candidate = (int(parts[2]), parts[1])
                pronunciations[parts[0]] = max(candidate, pronunciations.get(parts[0], candidate))
            yield parts[1].replace(' ', ''), parts[0], int(parts[2])


for name in ['8105', 'base', 'ext', 'tencent', 'vvhisper_design']:
    db.executemany('INSERT OR IGNORE INTO words VALUES (?,?,?)',
                   entries(source / 'cn_dicts' / (name + '.dict.yaml')))
db.commit()
db.close()
for name in ['RimeIce-LICENSE.txt', 'VvhisperLexicon-LICENSE.txt', 'dictionary-provenance.json', 'EnglishWords.txt']:
    shutil.copyfile(source / name, output / name)
