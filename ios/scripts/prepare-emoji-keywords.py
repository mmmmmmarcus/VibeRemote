#!/usr/bin/env python3
"""Regenerate local name/keyword matches from pinned Unicode CLDR 47 data."""
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE = "https://raw.githubusercontent.com/unicode-org/cldr-json/47.0.0/cldr-json"


def identity(text):
    return "".join(c for c in text if ord(c) != 0xFE0F and not 0x1F3FB <= ord(c) <= 0x1F3FF)


def main():
    catalog = json.loads((ROOT / "Shared/EmojiCatalog.json").read_text())
    base = {identity(e["glyph"]): e for e in catalog
            if not any(0x1F3FB <= ord(c) <= 0x1F3FF for c in e["glyph"])}
    aliases = {}
    titles = {}
    sources = []
    for locale in ("en", "zh"):
        for package, key in (("annotations", "annotations"), ("annotations-derived", "annotationsDerived")):
            url = f"{BASE}/cldr-{package}-full/{key}/{locale}/annotations.json"
            data = urllib.request.urlopen(url, timeout=30).read()
            sources.append({"url": url, "sha256": hashlib.sha256(data).hexdigest()})
            annotations = json.loads(data)[key]["annotations"]
            for glyph, entry in annotations.items():
                item = base.get(identity(glyph))
                if item is None:
                    continue
                for name in entry.get("tts", []):
                    titles.setdefault(" ".join(name.lower().split()), []).append(item["glyph"])
                for name in entry.get("tts", []) + entry.get("default", []):
                    normalized = " ".join(name.lower().split())
                    if normalized:
                        choices = aliases.setdefault(normalized, [])
                        if item["glyph"] not in choices:
                            choices.append(item["glyph"])
    for item in base.values():
        titles.setdefault(item["name"].lower(), []).append(item["glyph"])
    for name, glyphs in titles.items():
        aliases[name] = list(dict.fromkeys(glyphs + aliases.get(name, [])))
    # Prefer the everyday standalone symbol over related faces/objects.
    for name, glyph in {"heart": "❤️", "爱心": "❤️", "smile": "🙂", "微笑": "🙂"}.items():
        aliases[name] = [glyph] + [g for g in aliases.get(name, []) if g != glyph]
    (ROOT / "Shared/EmojiKeywords.json").write_text(json.dumps(aliases, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    (ROOT / "Shared/EmojiKeywords-Provenance.json").write_text(json.dumps({"version": "CLDR 47.0.0", "license": "Unicode-Emoji-LICENSE.txt", "sources": sources}, indent=2) + "\n")
    print(f"Wrote {len(aliases)} English/Chinese names and keywords")


if __name__ == "__main__":
    main()
