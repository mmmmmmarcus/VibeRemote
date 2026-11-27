#!/usr/bin/env python3
"""Build a bounded spelling trie from checksum-verified Rime dictionary sources.

Derived data only: upstream tables/weights are never modified. The enclosing
Rime bundle retains their licenses and dictionary-provenance.json. No Han text
is copied: Rime still owns conversion and validates every suggested commit.
"""
from collections import deque
import struct


def compile_typo_index(resources, destination):
    syllables = set((resources / 'PinyinSyllables.txt').read_text().split())
    entries = {}
    # Match vvhisper_lexicon.dict.yaml, not arbitrary files in the directory.
    for name in ('8105', 'base', 'ext', 'tencent', 'vvhisper_design'):
        for line in (resources / 'cn_dicts' / (name + '.dict.yaml')).open():
            fields = line.rstrip().split('\t')
            if len(fields) < 3:
                continue
            try:
                weight = int(fields[2])
            except ValueError:
                continue
            parts = fields[1].split()
            spelling = ''.join(parts)
            if (weight < 1000 or not 2 <= len(parts) <= 10 or
                    not 6 <= len(spelling) <= 32 or
                    not all(part in syllables for part in parts)):
                continue
            entries[spelling] = max(entries.get(spelling, 0), min(weight, 0xffffffff))
    # Frequency cap, deterministic ties. Rare names remain in the exact Rime path.
    selected = sorted(entries, key=lambda s: (-entries[s], s))[:80000]
    root = {'children': {}, 'weight': 0, 'maximum': 0}
    for spelling in selected:
        node = root
        node['maximum'] = max(node['maximum'], entries[spelling])
        for letter in spelling:
            node = node['children'].setdefault(letter, {'children': {}, 'weight': 0, 'maximum': 0})
            node['maximum'] = max(node['maximum'], entries[spelling])
        node['weight'] = entries[spelling]
    pending = deque([(0, root)])
    records = []
    next_child = 1
    while pending:
        letter, node = pending.popleft()
        children = sorted(node['children'].items())
        # Little-endian fixed 16-byte record: first child, terminal frequency,
        # descendant max frequency, child count, ASCII edge, reserved.
        records.append(struct.pack('<IIIHBB', next_child, node['weight'],
                                   node['maximum'], len(children), letter, 0))
        next_child += len(children)
        pending.extend((ord(key), child) for key, child in children)
    if len(records) > 500000:
        raise ValueError('Typo trie exceeds extension memory budget')
    output = b'VVTYPO01' + struct.pack('<II', len(records), len(selected)) + b''.join(records)
    (destination / 'PinyinTypo.bin').write_bytes(output)
    print(f'Pinyin typo index: {len(selected)} spellings, {len(records)} nodes, {len(output)} bytes')
