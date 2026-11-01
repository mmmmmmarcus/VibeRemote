#include "include/VRNativeTouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <math.h>
#include <stddef.h>
// Private MultitouchSupport contact-frame ABI, dynamically loaded and fail-closed.
typedef struct { float x,y; } VRPoint;
typedef struct { VRPoint position,velocity; } VRVector;
typedef struct {
    int32_t frame; double timestamp; int32_t pathIndex; uint32_t state;
    int32_t fingerID,handID; VRVector normalized; float zTotal; int32_t field9;
    float angle,majorAxis,minorAxis; VRVector absolute; int32_t field14,field15;
    float zDensity;
} Contact;
_Static_assert(offsetof(Contact, normalized)==32 && sizeof(Contact)==96,"Unexpected contact ABI");
typedef int (*FrameCallback)(void *,Contact *,int,double,int,void *);
static void *framework;
static CFArrayRef (*createList)(void);
static int (*deviceStart)(void *,int);
static void (*deviceStop)(void *);
static int (*isBuiltIn)(void *);
static void (*sensorDimensions)(void *,int *,int *);
static void (*surfaceDimensions)(void *,int *,int *);
static void (*registerCallback)(void *,FrameCallback,void *);
static void (*unregisterCallback)(void *,FrameCallback);
static void *devices[8];
static int deviceCount;
static _Atomic(VRTouchCallback) sink;
static int frame(void *device,Contact *contacts,int count,double time,int sequence,void *context) {
    (void)sequence;(void)context;
    VRTouchCallback callback=atomic_load(&sink);
    if(!callback||count<0||count>16)return 0;
    int active=0;float x=0,y=0;
    for(int i=0;i<count;i++) {
        Contact *c=&contacts[i];
        if(c->state<3||c->state>5)continue;
        if(!isfinite(c->normalized.position.x)||!isfinite(c->normalized.position.y))continue;
        if(c->normalized.position.x<0||c->normalized.position.x>1||c->normalized.position.y<0||c->normalized.position.y>1)continue;
        x+=c->normalized.position.x;y+=c->normalized.position.y;active++;
    }
    callback((uint64_t)(uintptr_t)device,active,active?x/active:0,active?y/active:0,time);
    return 0;
}
void vr_touch_stop(void) {
    atomic_store(&sink,NULL);
    for(int i=0;i<deviceCount;i++) {
        deviceStop(devices[i]);unregisterCallback(devices[i],frame);CFRelease(devices[i]);
    }
    deviceCount=0;
}
int vr_touch_start(VRTouchCallback callback) {
    vr_touch_stop();
    if(!framework) {
        framework=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_LOCAL|RTLD_LAZY);
        if(!framework)return -1;
#define LOAD(variable,symbol) variable=dlsym(framework,symbol)
        LOAD(createList,"MTDeviceCreateList");LOAD(deviceStart,"MTDeviceStart");LOAD(deviceStop,"MTDeviceStop");
        LOAD(isBuiltIn,"MTDeviceIsBuiltIn");LOAD(sensorDimensions,"MTDeviceGetSensorDimensions");
        LOAD(surfaceDimensions,"MTDeviceGetSensorSurfaceDimensions");
        LOAD(registerCallback,"MTRegisterContactFrameCallbackWithRefcon");
        LOAD(unregisterCallback,"MTUnregisterContactFrameCallback");
#undef LOAD
    }
    if(!createList||!deviceStart||!deviceStop||!isBuiltIn||!sensorDimensions||!surfaceDimensions||!registerCallback||!unregisterCallback)return -1;
    CFArrayRef list=createList();if(!list)return 0;
    atomic_store(&sink,callback);
    for(CFIndex i=0;i<CFArrayGetCount(list)&&deviceCount<8;i++) {
        void *device=(void *)CFArrayGetValueAtIndex(list,i);
        if(isBuiltIn(device))continue;
        int rows=0,columns=0,width=0,height=0;
        sensorDimensions(device,&rows,&columns);surfaceDimensions(device,&width,&height);
        // Known Siri Remote sensor signatures; never attach to ordinary trackpads.
        if(!((rows==6&&columns==12)||(rows==12&&columns==6)||(width==2775&&height==2775)))continue;
        CFRetain(device);registerCallback(device,frame,NULL);
        if(deviceStart(device,0)==0)devices[deviceCount++]=device;
        else {unregisterCallback(device,frame);CFRelease(device);}
    }
    CFRelease(list);return deviceCount;
}
