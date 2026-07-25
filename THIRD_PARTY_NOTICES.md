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
