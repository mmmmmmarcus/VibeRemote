#!/usr/bin/env python3
"""Transfer this user's existing Mac Seed settings into an installed Debug iOS app.

The key is never printed, passed as a process argument, or embedded in the app.
A mode-0600 temporary file is removed after transfer; the iOS app consumes and
removes its copy on the next launch. Run with the explicit device UDID.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit('Usage: import-mac-seed.py DEVICE_UDID')
key = subprocess.run(['security', 'find-generic-password', '-s',
                      'com.viberemote.dictation.seedasr', '-a', 'api-key', '-w'],
                     capture_output=True, text=True)
if key.returncode or not key.stdout.strip():
    raise SystemExit('The Mac Seed key could not be read. Enter the key in the iOS app.')
app_id = subprocess.run(['defaults', 'read', 'com.viberemote.app', 'dictationSeedAppID'],
                        capture_output=True, text=True)
with tempfile.TemporaryDirectory(prefix='vvhisper-seed-') as directory:
    path = Path(directory) / 'seed-development.json'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump({'apiKey': key.stdout.strip(), 'appID': app_id.stdout.strip() if app_id.returncode == 0 else ''}, f)
    result = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', sys.argv[1],
                            '--source', str(path), '--destination', 'Documents/seed-development.json',
                            '--domain-type', 'appDataContainer', '--domain-identifier', 'com.vvhisper.ios'],
                           capture_output=True, text=True)
    if result.returncode:
        raise SystemExit('Transfer failed; no local credentials retained. Check the device connection.')
print('Seed configuration transferred privately. Launch vvhisper to consume it into Keychain.')
