#!/usr/bin/env python3
"""Insert public release configuration without interpolating XML or credentials."""
import base64, json, os, pathlib, plistlib, sys, urllib.parse
config = json.loads((pathlib.Path(__file__).resolve().parent.parent / 'Release/update-config.json').read_text())
feed = os.environ.get('SPARKLE_FEED_URL', config['feedURL'])
key = os.environ.get('SPARKLE_PUBLIC_KEY', config['publicKey'])
parsed = urllib.parse.urlparse(feed)
if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
    raise SystemExit('The update feed must be a public HTTPS URL without credentials')
if len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit('Sparkle requires a 32-byte Ed25519 public key')
path = pathlib.Path(sys.argv[1])
with path.open('rb') as source:
    info = plistlib.load(source)
info.update(SUFeedURL=feed, SUPublicEDKey=key, SUEnableAutomaticChecks=True,
            SUAutomaticallyUpdate=False, SUSendProfileInfo=False, SUScheduledCheckInterval=86400)
with path.open('wb') as output:
    plistlib.dump(info, output)
