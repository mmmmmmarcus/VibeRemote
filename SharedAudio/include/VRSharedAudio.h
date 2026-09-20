#ifndef VR_SHARED_AUDIO_H
#define VR_SHARED_AUDIO_H
#include <stdint.h>
#include <sys/types.h>
#define VR_AUDIO_RATE 48000
#define VR_AUDIO_CAPACITY 96000
#define VR_AUDIO_DIRECTORY "/Library/Application Support/VibeRemote/Audio"
typedef struct VRSharedHandle VRSharedHandle;
// Preparation is root-only and scopes ownership to the authenticated XPC peer.
int vr_audio_prepare(uid_t uid);
VRSharedHandle *vr_audio_open(uid_t uid, int writer);
void vr_audio_close(VRSharedHandle *handle);
void vr_audio_heartbeat(VRSharedHandle *handle);
void vr_audio_begin(VRSharedHandle *handle);
uint64_t vr_audio_write(VRSharedHandle *handle, const float *samples, uint32_t count);
uint64_t vr_audio_written(VRSharedHandle *handle);
uint64_t vr_audio_consumed(VRSharedHandle *handle);
uint64_t vr_audio_underruns(VRSharedHandle *handle);
// No allocation, file access, blocking locks or logging in this render function.
int vr_audio_read(VRSharedHandle *handle, double sampleTime, float *output,
                  uint32_t frames, uint32_t channels);
#endif
