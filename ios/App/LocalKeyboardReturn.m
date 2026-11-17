#import "LocalKeyboardReturn.h"

#if DEBUG
#import <objc/message.h>
#import <UIKit/UIKit.h>

// UIKit delivers this transient source identity in the containing app, not in
// the extension. Observe changes from launch; never treat the initial state as
// a fresh event. Implementation lead: OpenWhispr HostAppObserver.swift (see README).
@interface VVKeyboardHandoffObserver : NSObject
@property(nonatomic, strong) NSObject *keyboards;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, strong) NSDate *observedAt;
@property(nonatomic) NSUInteger changeCount;
@end

@implementation VVKeyboardHandoffObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (object != self.keyboards || ![keyPath isEqualToString:@"currentState"]) return;
    @synchronized (self) { self.changeCount += 1; }
    @try {
        id state = change[NSKeyValueChangeNewKey];
        SEL source = NSSelectorFromString(@"sourceBundleIdentifier");
        if (![state respondsToSelector:source]) return;
        id value = ((id (*)(id, SEL))objc_msgSend)(state, source);
        if (![value isKindOfClass:NSString.class] || [value length] == 0 ||
            [value isEqualToString:NSBundle.mainBundle.bundleIdentifier]) return;
        @synchronized (self) {
            self.bundleIdentifier = value;
            self.observedAt = NSDate.date;
        }
    } @catch (__unused NSException *exception) {}
}
@end

static VVKeyboardHandoffObserver *observer;
void VVObserveKeyboardHandoff(void) {
    NSCAssert(NSThread.isMainThread, @"Install from app launch");
    if (observer) return;
    @try {
        Class type = NSClassFromString(@"_UIRemoteKeyboards");
        SEL shared = NSSelectorFromString(@"sharedRemoteKeyboards");
        if (![type respondsToSelector:shared]) return;
        id keyboards = ((id (*)(id, SEL))objc_msgSend)(type, shared);
        if (![keyboards respondsToSelector:NSSelectorFromString(@"currentState")]) return;
        observer = [VVKeyboardHandoffObserver new];
        observer.keyboards = keyboards;
        [keyboards addObserver:observer forKeyPath:@"currentState" options:NSKeyValueObservingOptionNew context:NULL];
    } @catch (__unused NSException *exception) { observer = nil; }
}

NSString *VVKeyboardHostObservedSince(NSDate *since) {
    @synchronized (observer) {
        if (!observer.observedAt || [observer.observedAt compare:since] == NSOrderedAscending ||
            -observer.observedAt.timeIntervalSinceNow > 10) return nil;
        return observer.bundleIdentifier;
    }
}

void VVClearKeyboardHandoff(void) {
    @synchronized (observer) {
        observer.bundleIdentifier = nil;
        observer.observedAt = nil;
    }
}

NSString *VVKeyboardHandoffDiagnostic(void) {
    @synchronized (observer) {
        return [NSString stringWithFormat:@"observer=%d events=%lu source=%d", observer != nil,
                (unsigned long)observer.changeCount, observer.observedAt != nil];
    }
}

BOOL VVReturnToKeyboardHost(NSString *bundleIdentifier) {
    // Private LaunchServices entry point, explicitly authorized for this local MVP.
    // The caller supplies only the fresh destination captured for this handoff.
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        SEL shared = NSSelectorFromString(@"defaultWorkspace");
        SEL open = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (!workspaceClass || ![workspaceClass respondsToSelector:shared]) return NO;
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, shared);
        if (![workspace respondsToSelector:open]) return NO;
        NSMethodSignature *signature = [workspace methodSignatureForSelector:open];
        if (signature.numberOfArguments != 3 || signature.methodReturnLength != sizeof(BOOL)) return NO;
        return ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(workspace, open, bundleIdentifier);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}
#else
BOOL VVReturnToKeyboardHost(__unused NSString *bundleIdentifier) { return NO; }
void VVObserveKeyboardHandoff(void) {}
NSString *VVKeyboardHostObservedSince(__unused NSDate *since) { return nil; }
void VVClearKeyboardHandoff(void) {}
NSString *VVKeyboardHandoffDiagnostic(void) { return @"disabled"; }
#endif
