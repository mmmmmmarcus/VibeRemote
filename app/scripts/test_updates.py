#!/usr/bin/env python3
"""Reject malformed release metadata before it can be published."""
import base64, json, os, pathlib, plistlib, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parent.parent

class UpdateValidationTests(unittest.TestCase):
    def test_feed_rejects_unsigned_insecure_and_duplicate_updates(self):
        sig = base64.b64encode(bytes(64)).decode()
        item = f'<item><sparkle:version>2</sparkle:version><enclosure url="https://example.com/app.zip" length="12" sparkle:edSignature="{sig}"/></item>'
        with tempfile.TemporaryDirectory() as directory:
            feed = pathlib.Path(directory) / 'appcast.xml'
            for body, expected in [(item, 0), (item.replace('https:', 'http:'), 1),
                                   (item.replace(sig, ''), 1), (item + item, 1), ('', 1)]:
                feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' + body + '</channel></rss>')
                result = subprocess.run(['python3', str(ROOT / 'scripts/validate-appcast.py'), str(feed)], capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr.decode())

    def test_bundle_configuration_rejects_unsafe_feed_and_invalid_key(self):
        with tempfile.TemporaryDirectory() as directory:
            info = pathlib.Path(directory) / 'Info.plist'
            for overrides, success in [({}, True), ({'SPARKLE_FEED_URL':'http://example.com/feed'}, False),
                                       ({'SPARKLE_FEED_URL':'https://user:password@example.com/feed'}, False),
                                       ({'SPARKLE_PUBLIC_KEY':'broken'}, False)]:
                info.write_bytes(plistlib.dumps({'CFBundleVersion':'2'}))
                env = {k:v for k,v in os.environ.items() if not k.startswith('SPARKLE_')}
                env.update(overrides)
                result = subprocess.run(['python3', str(ROOT / 'scripts/configure-updates.py'), str(info)], env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, success)
                if success:
                    data = plistlib.loads(info.read_bytes())
                    self.assertFalse(data['SUSendProfileInfo'])
                    self.assertFalse(data['SUAutomaticallyUpdate'])
                    self.assertTrue(data['SUEnableAutomaticChecks'])

if __name__ == '__main__':
    unittest.main()
