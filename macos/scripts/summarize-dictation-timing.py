#!/usr/bin/env python3
"""Summarize duration-only dictation JSON from any platform. Never print input records."""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

STAGES = ("micLive", "firstText", "captureStopped", "recognition", "polishDuration", "textReady", "committed")

def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None

def summary(records):
    output = {"count": len(records)}
    for stage in STAGES:
        values = [r[stage] for r in records if isinstance(r.get(stage), (int, float))
                  and not isinstance(r[stage], bool) and math.isfinite(r[stage]) and r[stage] >= 0]
        if values:
            output[stage] = {"count": len(values), "median": round(percentile(values, .5), 3), "p95": round(percentile(values, .95), 3)}
    return output

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    groups = defaultdict(list)
    for index, path in enumerate(args.files, 1):
        records = json.loads(path.read_text())
        if not isinstance(records, list):
            parser.error("Expected a JSON array of timing records")
        for record in records:
            if not isinstance(record, dict):
                continue
            packet = record.get("packetMilliseconds")
            label = str(packet) if packet in (100, 200) else "unknown"
            groups[f"input{index}/{label}ms"].append(record)
    print(json.dumps({key: summary(value) for key, value in groups.items()}, indent=2, sort_keys=True))

if __name__ == "__main__":
    main()
