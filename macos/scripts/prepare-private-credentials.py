#!/usr/bin/env python3
"""Stage credentials for personal builds. Never print credential values."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SERVICES = {
    'seed': 'com.viberemote.dictation.seedasr',
    'ark': 'com.viberemote.dictation.ark',
    'openai': 'com.viberemote.dictation.openai',
    'openrouter': 'com.viberemote.agent.openrouter',
}

def validate(value):
    if not isinstance(value, dict):
        raise ValueError('Expected a credential object')
    result = {}
    for name in SERVICES:
        key = value.get(name, '')
        if not isinstance(key, str) or len(key.encode()) > 8192 or any(c.isspace() for c in key):
            raise ValueError('Invalid credential field: ' + name)
        result[name] = key
    for name in ('seed', 'ark'):
        if not result[name]:
            raise ValueError('Private build requires ' + name + ' credentials')
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'macos/Resources/PrivateCredentials/credentials.json')
    args = parser.parse_args()
    source = os.environ.get('VVHISPER_PRIVATE_CREDENTIALS')
    if source:
        values = json.loads(Path(source).expanduser().read_text())
    elif sys.platform == 'darwin':
        values = {}
        for name, service in SERVICES.items():
            result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', service,
                                     '-a', 'api-key', '-w'], capture_output=True, timeout=30)
            values[name] = result.stdout.decode().strip() if result.returncode == 0 else ''
    else:
        raise ValueError('Set VVHISPER_PRIVATE_CREDENTIALS to a private JSON file on this build machine')
    values = validate(values)
    # New-console Speech API key only. Do not mix a bundled key with a saved legacy App ID.
    data = (json.dumps(values, sort_keys=True) + '\n').encode()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.output.exists() or args.output.read_bytes() != data:
        temporary = args.output.with_suffix('.tmp')
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
        temporary.replace(args.output)
    args.output.chmod(0o600)
    print('Private credentials staged (' + ', '.join(k for k, v in values.items() if v) + ').')

if __name__ == '__main__':
    try:
        main()
    except Exception:
        # JSON parsing and subprocess exceptions can contain secrets. Do not print them.
        print('Could not prepare private credentials. Unlock Keychain or set VVHISPER_PRIVATE_CREDENTIALS to a valid private JSON file containing seed and ark.', file=sys.stderr)
        sys.exit(1)
