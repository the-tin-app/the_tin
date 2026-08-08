#import <AVFoundation/AVFoundation.h>

/// `-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]` is **documented to raise an
/// NSException** for a whole family of invalid-argument conditions, and Swift cannot catch an
/// Objective-C exception. So a mistake in one line of camera configuration is not a recoverable
/// error — it is `abort()`.
///
/// That is not theoretical. On 2026-08-07 a device build crashed on the shutter press, twice, with
/// SIGABRT and this exact frame on top: settings carried a `maxPhotoDimensions` read from the active
/// format BEFORE `startRunning()`, and the preset had re-selected a format by capture time, so the
/// value was no longer one the format supported. The user was mid-binder-scan.
///
/// The caller now builds settings that cannot be invalid (see `LensPhotoSource.capture`). This exists
/// because that is a reason not to crash TODAY, and a `@try` is what makes it true for every other
/// throwing condition in the same API — a session that stopped between the guard and the call, a
/// missing video connection, a duplicate `uniqueID`. Returning NO costs a shutter press; the
/// alternative costs the scan.
BOOL TinCapturePhotoSafely(AVCapturePhotoOutput *output,
                           AVCapturePhotoSettings *settings,
                           id<AVCapturePhotoCaptureDelegate> delegate,
                           NSString **reason);
