#!/usr/bin/env python3
"""Fetch the pinned, checksummed iOS Rime dependency. No runtime downloads."""
import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "build/dependencies"
VERSION = "1.17.0-pack.10.0.0"
SHA256 = "9e9923112ee9cee9bb53c25b41e51a2d7ea2ab3d91f34c7c99682224a23718ac"
STAMP = DEST / "rime.sha256"
if STAMP.exists() and STAMP.read_text() == SHA256 and (DEST / "librime-static.xcframework/Info.plist").exists():
    raise SystemExit(0)
url = f"https://github.com/ghostflyby/librime-xcframework/releases/download/{VERSION}/librime-static.xcframework.zip"
with urllib.request.urlopen(url, timeout=60) as response:
    archive = response.read()
if hashlib.sha256(archive).hexdigest() != SHA256:
    raise SystemExit("Rime archive checksum mismatch")
with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
    for entry in zipped.infolist():
        path = Path(entry.filename)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit("Unsafe Rime archive path")
    zipped.extractall(DEST)
STAMP.write_text(SHA256)
print(f"Prepared Rime {VERSION} (SHA-256 verified)")
