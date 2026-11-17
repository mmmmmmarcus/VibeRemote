#import <Foundation/Foundation.h>

/// Debug-only experiment. Release builds always return NO.
BOOL VVReturnToKeyboardHost(NSString * _Nonnull bundleIdentifier);
void VVObserveKeyboardHandoff(void);
NSString * _Nullable VVKeyboardHostObservedSince(NSDate * _Nonnull since);
void VVClearKeyboardHandoff(void);
NSString * _Nonnull VVKeyboardHandoffDiagnostic(void);
