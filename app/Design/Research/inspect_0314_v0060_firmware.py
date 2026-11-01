#!/usr/bin/env python3
"""Offline, hash-pinned 0314/hw0021/v0060 AFU inspection. No device API.

Optional ELF is an analysis container, not executable/flashable firmware.
Addresses in this report map to AFU offset = address + 0x80. This differs from B439.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

EXPECTED = '66e98f7616856c4d76aafc547155f849c0c0812ec4e42ea6c2103f2c35e4a659'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('afu', type=Path)
    parser.add_argument('--elf', type=Path)
    args = parser.parse_args()
    original = args.afu.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    if digest != EXPECTED:
        parser.error('Unrecognized firmware SHA-256; no decoding performed')
    data = original[0x80:]
    result = {
        'sha256': digest, 'size': len(original), 'afu_offset_for_address_zero': 128,
        'header_hex': original[:32].hex(' '),
        'lock_entry_address': '0x952a8',
        'lock_entry_bytes': data[0x952a8:0x952b8].hex(' '),
        'lock_name_address': '0x9fc07',
        'lock_name': data[0x9fc07:0x9fc0c].decode('ascii'),
        'get_branch_table_address': '0x56520',
        'get_branch_table_halfwords': list(struct.unpack_from('<5H', data, 0x56520)),
        'candidate_internal_report': '0x3c',
        'candidate_branch_address': '0x5652a',
        'caveat': 'Static candidate only. BLE HID registration/request translation not yet verified. Do not probe from this output.'
    }
    print(json.dumps(result, indent=2))
    if args.elf:
        names = b'\0.text\0.shstrtab\0'
        name_offset = 0x100 + len(data)
        section_offset = (name_offset + len(names) + 3) & ~3
        header = b'\x7fELF' + bytes([1, 1, 1, 0]) + bytes(8) + struct.pack(
            '<HHIIIIIHHHHHH', 2, 40, 1, struct.unpack_from('<I', data, 4)[0],
            0, section_offset, 0x5000000, 52, 0, 0, 40, 3, 2)
        output = (header.ljust(0x100, b'\0') + data + names).ljust(section_offset, b'\0')
        output += bytes(40)
        output += struct.pack('<10I', 1, 1, 6, 0, 0x100, len(data), 0, 0, 4, 0)
        output += struct.pack('<10I', 7, 3, 0, 0, name_offset, len(names), 0, 0, 1, 0)
        with args.elf.open('xb') as destination:
            destination.write(output)

if __name__ == '__main__':
    main()
