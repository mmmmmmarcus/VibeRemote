#include "include/VRNativeTouch.h"
#include <dlfcn.h>

// Inspect the event already delivered to our CGEvent tap. Unlike IOHIDDeviceOpen,
// this does not claim the remote and therefore leaves MultitouchSupport available.
// Both symbols are private: missing metadata/symbols returns zero, never a guess.
uint64_t vr_media_event_sender(CFTypeRef event) {
    static int loaded;
    static CFTypeRef (*copyEvent)(CFTypeRef);
    static uint64_t (*senderID)(CFTypeRef);
    if (!loaded) {
        loaded = 1;
        void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LOCAL | RTLD_LAZY);
        void *hid = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LOCAL | RTLD_LAZY);
        if (cg) copyEvent = dlsym(cg, "CGEventCopyIOHIDEvent");
        if (hid) senderID = dlsym(hid, "IOHIDEventGetSenderID");
    }
    if (!event || !copyEvent || !senderID) return 0;
    CFTypeRef hidEvent = copyEvent(event);
    if (!hidEvent) return 0;
    uint64_t result = senderID(hidEvent);
    CFRelease(hidEvent);
    return result;
}
