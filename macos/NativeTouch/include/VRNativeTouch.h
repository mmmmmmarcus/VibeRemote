#ifndef VR_NATIVE_TOUCH_H
#define VR_NATIVE_TOUCH_H
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
typedef void (*VRTouchCallback)(uint64_t device, int count, float x, float y, double timestamp);
// Main-thread lifecycle. Only remote-sized, non-built-in surfaces are opened.
int vr_touch_start(VRTouchCallback callback);
void vr_touch_stop(void);
// Main-thread, read-only source lookup for an existing CoreGraphics media event.
uint64_t vr_media_event_sender(CFTypeRef event);
#endif
