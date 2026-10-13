#!/usr/bin/env python3
"""Read-only, version-pinned B439 firmware inspection; no device access.

Usage: python3 inspect_b439_firmware.py MAIN.afu [--elf /tmp/B439.elf]
The optional ELF wraps original bytes for llvm-objdump, not execution/flashing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

BASE = 0x08008000
SHA256 = "9a2c3c002015ef5b11769c6c167a16a03829e5347ab971a4ee501f163022bbbc"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("firmware", type=Path)
    parser.add_argument("--elf", type=Path)
    args = parser.parse_args()
    data = args.firmware.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SHA256:
        parser.error(f"Firmware mismatch: {digest}; offsets apply only to B439 0118 hw000A production")

    def word(address):
        return struct.unpack_from("<I", data, address - BASE)[0]

    def string(address):
        offset = address - BASE
        if not 0 <= offset < len(data):
            raise ValueError(f"String outside firmware: {address:#x}")
        return data[offset:data.index(0, offset)].decode("ascii")

    # CmdProcessor report registration: type, ID, get, set, min/max payload.
    reports = []
    for address in range(0x08064450, 0x080645AC, 12):
        kind, rid, get, set_, minimum, maximum = struct.unpack_from(
            "<4BII", data, address - BASE)
        reports.append(dict(address=hex(address), type=kind, report_id=hex(rid),
                            get=bool(get), set=bool(set_), minimum=minimum, maximum=maximum))

    # FSM records: kind, event|nextState<<16, callback, event name, state name.
    # State headers (kind 1) establish the source state for kind 2 transitions.
    states = []
    current = None
    for address in range(0x0806344C, 0x08064450, 20):
        kind, packed, callback, event_name, state_name = struct.unpack_from(
            "<5I", data, address - BASE)
        if kind == 1:
            current = dict(state=packed, name=string(state_name), transitions=[])
            states.append(current)
        elif kind == 2 and current is not None:
            current["transitions"].append(dict(address=hex(address), event=hex(packed & 0xffff),
                event_name=string(event_name), next_state=packed >> 16,
                next_name=string(state_name), action=hex(callback & ~1) if callback else None))
        elif kind == 3:
            break
        else:
            raise ValueError(f"Unexpected FSM record at {address:#x}: {kind}")

    if len(states) != 20:
        raise ValueError(f"Unexpected state count: {len(states)}")
    result = dict(sha256=digest, bytes=len(data), address_base=hex(BASE),
        product_hardware=hex(word(BASE + 0x10)),
        initial_sp=hex(word(BASE + 0x200)), reset=hex(word(BASE + 0x204)),
        reports=reports, states=states,
        caveat="Static table decoding only; host transport and hardware execution are not proven.")
    print(json.dumps(result, indent=2))

    if args.elf:
        names = b"\0.text\0.shstrtab\0"
        name_offset = 0x100 + len(data)
        section_offset = (name_offset + len(names) + 3) & ~3
        header = b"\x7fELF" + bytes([1, 1, 1, 0]) + bytes(8) + struct.pack(
            "<HHIIIIIHHHHHH", 2, 40, 1, word(BASE + 0x204), 0,
            section_offset, 0x5000000, 52, 0, 0, 40, 3, 2)
        output = (header.ljust(0x100, b"\0") + data + names).ljust(section_offset, b"\0")
        output += bytes(40)
        output += struct.pack("<10I", 1, 1, 6, BASE, 0x100, len(data), 0, 0, 4, 0)
        output += struct.pack("<10I", 7, 3, 0, 0, name_offset, len(names), 0, 0, 1, 0)
        # Never overwrite an existing analysis or source file.
        with args.elf.open("xb") as destination:
            destination.write(output)


if __name__ == "__main__":
    main()
