#!/usr/bin/env python3
"""Reproducible VibeRemote changes to the upstream BlackHole HAL source."""
from pathlib import Path
import shutil
import sys
root = Path(__file__).resolve().parents[1]
p = Path(sys.argv[1]) / 'BlackHole' / 'BlackHole.c'
s = p.read_text()
def replace(old, new):
    global s
    if s.count(old) != 1:
        raise SystemExit(f'Upstream driver changed: expected one anchor {old!r}')
    s = s.replace(old, new)
replace('#pragma mark IO Operations', '#pragma mark IO Operations\n\n#include "VRSharedAudio.c"\nstatic VRSharedHandle *gVRSharedReader = NULL;')
replace('    // allocate ring buffer', '''    // StartIO is outside the realtime render callback. Never map files in ReadInput.
    if (!gVRSharedReader) {
        struct stat console;
        if (!stat("/dev/console", &console) && console.st_uid >= 500)
            gVRSharedReader = vr_audio_open(console.st_uid, 0);
    }
    // allocate ring buffer''')
replace('        free(gRingBuffer);', '''        vr_audio_close(gVRSharedReader);
        gVRSharedReader = NULL;
        free(gRingBuffer);''')
replace('        // If mute is one let\'s just fill the buffer with zeros or if there\'s no apps outputting audio', '''        if (vr_audio_read(gVRSharedReader, inIOCycleInfo->mInputTime.mSampleTime,
                          ioMainBuffer, inIOBufferFrameSize, kNumber_Of_Channels)) {
            if (gMute_Master_Value)
                vDSP_vclr(ioMainBuffer, 1, inIOBufferFrameSize * kNumber_Of_Channels);
            else if (kEnableVolumeControl)
                vDSP_vsmul(ioMainBuffer, 1, &gVolume_Master_Value, ioMainBuffer, 1,
                           inIOBufferFrameSize * kNumber_Of_Channels);
            return noErr;
        }
        // If mute is one let's just fill the buffer with zeros or if there's no apps outputting audio''')
# CoreAudio converts client formats; the shared transport is always 48 kHz mono.
replace('#define                             kSampleRates       8000, 16000, 24000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000', '#define                             kSampleRates       48000')
p.write_text(s)
shutil.copy2(root / 'SharedAudio/VRSharedAudio.c', p.parent / 'VRSharedAudio.c')
(p.parent / 'include').mkdir(exist_ok=True)
shutil.copy2(root / 'SharedAudio/include/VRSharedAudio.h', p.parent / 'include/VRSharedAudio.h')
