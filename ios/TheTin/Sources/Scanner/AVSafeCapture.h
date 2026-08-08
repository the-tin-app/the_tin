#import <Foundation/Foundation.h>

/// Runs `block` and converts any Objective-C exception into `NO` plus a reason string.
///
/// ⚠️ This exists because **AVFoundation's camera-configuration API raises, and Swift cannot catch an
/// Objective-C exception** — so a mistake in one line of setup is not a recoverable error, it is
/// `abort()`. Both `-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]` and the
/// `maxPhotoDimensions` setters are documented to raise for invalid arguments, and on 2026-08-07 a
/// device build crashed twice on the shutter press for exactly that, mid-binder-scan.
///
/// It is a safety net, not a substitute for correctness: callers still have to pass valid arguments.
/// What it buys is that getting one wrong costs a shutter press and a visible message instead of the
/// user's scan — and the message is how the *next* mistake gets diagnosed in one look rather than in
/// a device session. The first version of this crash had its reason swallowed by Crashlytics' terminate
/// handler and cost a round trip to identify.
BOOL TinRunCatchingObjCException(void (NS_NOESCAPE ^block)(void), NSString **reason);
