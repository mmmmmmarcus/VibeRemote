#!/usr/bin/env python3
import base64, pathlib, sys, urllib.parse, xml.etree.ElementTree as ET
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
root = ET.parse(pathlib.Path(sys.argv[1])).getroot()
items = root.findall('./channel/item')
if not items:
    raise SystemExit('An update feed must contain an item')
versions = []
for item in items:
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise SystemExit('Missing update enclosure')
    url = urllib.parse.urlparse(enclosure.get('url', ''))
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise SystemExit('Update archives must use HTTPS without credentials')
    signature = enclosure.get(SPARKLE + 'edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise SystemExit('Missing or malformed Ed25519 archive signature')
    if int(enclosure.get('length', '0')) <= 0:
        raise SystemExit('Invalid archive size')
    version = item.findtext(SPARKLE + 'version') or enclosure.get(SPARKLE + 'version', '')
    if not version.isdigit():
        raise SystemExit('Build versions must be integers')
    versions.append(int(version))
if len(set(versions)) != len(versions):
    raise SystemExit('Duplicate build numbers')
print(f'Validated {len(items)} signed HTTPS update items')
