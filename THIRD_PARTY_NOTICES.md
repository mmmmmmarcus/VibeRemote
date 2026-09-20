# Third-party notices

## BlackHole (VibeRemote audio driver)

The `VibeRemote` virtual audio device shipped in `AudioDriver/VibeRemoteAudio.driver`
is a **modified build of BlackHole**, © Existential Audio Inc., licensed under the
**GNU General Public License v3.0**.

- Upstream source: https://github.com/ExistentialAudio/BlackHole
- License: GPL-3.0 (see the upstream `LICENSE`)
- Build script: [`build_audio_driver.sh`](build_audio_driver.sh), which fetches upstream
  source and applies the modifications below.

Modifications applied:

1. Branding via BlackHole's supported compile-time constants — `kDriver_Name`,
   `kDevice_Name`, `kDevice2_Name`, `kManufacturer_Name`, `kPlugIn_BundleID`,
   `kHas_Driver_Name_Format=false`, `kNumber_Of_Channels=2` — so the device, driver, and
   manufacturer all present as "VibeRemote".
2. One source edit in `BlackHole/BlackHole.c`: the audio box's hardcoded manufacturer
   string is routed through `kManufacturer_Name` (it otherwise ignores the constant).
3. The driver icon resource is replaced with the VibeRemote icon.
4. `scripts/patch_audio_driver.py` integrates `SharedAudio/VRSharedAudio.c` into the HAL
   input callback, fixes hardware rate to 48 kHz, and retains loopback fallback. The
   build pins upstream revision `ffcb74433fbcf8c8ca5c736677c1a4864384dc09`.
5. Driver metadata advertises `VibeRemoteSharedAudioVersion=1`.

Because the driver is a GPL-3.0 derivative, anyone distributing a VibeRemote build that
includes it must also make the corresponding driver source available under GPL-3.0. The
build script reproduces that source from upstream plus the modifications listed above.

## EZAudio

The bundled `EZAudioOSX.framework` is distributed under the MIT License.
Its copyright and license text are preserved at
`Vendor/SiriRemoteVoiceControl/Frameworks/LICENSE.txt`.

## Legacy SiriRemoteVoiceControl helper

The repository retains a prebuilt `SiriRemoteVoiceControl-BlackHole` binary for
local historical reference. VibeRemote no longer packages or runs that binary;
the app builds its microphone bridge helper from `VoiceBridgeHelper/` instead.

## Apple PacketLogger (optional personal build dependency)

Personal builds can copy an already-installed, Apple-signed `PacketLogger.app` into
`Contents/Resources`, preserving its complete original bundle and signature. Apple
retains ownership of this proprietary component; it is not covered by this repository's
license and is not committed here. Public release builds omit it unless the packager
explicitly opts in after reviewing their redistribution authorization. No CouchVox
binary, payload or source is included.

## Private MultitouchSupport interface

The experimental touch adapter dynamically loads the macOS system framework. Contact
layout references: https://github.com/lauschue/Remotastic/blob/main/MultitouchSupport.h
and https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h . The wrapper
and gesture implementation are original VibeRemote code; the private ABI may change.
