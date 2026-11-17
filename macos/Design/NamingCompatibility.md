# vvhisper naming and compatibility

Current product spelling: **vvhisper**. Package/module, app build product, voice bridge,
helper build product, test target/folder, resource bundle, icon sources, entitlements,
source symbols and current UI branding use vvhisper. `ButtonAction.vvhisperDictation`
retains its historical persisted raw value so existing mappings still decode.

The following old strings are deliberate interoperability contracts, not product names:

- `com.viberemote.app` signing/defaults identity, Keychain services, approved helper Mach
  service/launchd plist, audio bundle ID and cross-process notifications.
- Installed `Contents/MacOS/VibeRemoteHelper`: the new `vvhisperHelper` build product is
  packaged at the existing registered launchd path to preserve helper approval/restarts.
- `VibeRemoteAudio.driver`, shared-memory ABI/metadata and accepted old audio device names:
  installed driver and helper must continue communicating without a driver reinstall.
- Existing Application Support, log directories, window-frame defaults and update keys.
- GitHub release/feed URLs and historical research evidence naming earlier builds.

Do not blindly replace these strings. Changing them needs an explicit data/permissions
migration or compatibility reader, plus installed-device validation. Current diagnostics
labels say App Log and Source Code rather than presenting old internal names as branding.
