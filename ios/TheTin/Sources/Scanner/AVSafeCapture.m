#import "AVSafeCapture.h"

BOOL TinCapturePhotoSafely(AVCapturePhotoOutput *output,
                           AVCapturePhotoSettings *settings,
                           id<AVCapturePhotoCaptureDelegate> delegate,
                           NSString **reason) {
    @try {
        [output capturePhotoWithSettings:settings delegate:delegate];
        return YES;
    } @catch (NSException *e) {
        // ⚠️ Reported, never swallowed. The whole point of surviving this is to be able to say what
        // happened — an exception here means the camera was configured wrongly, and a silent shutter
        // that does nothing is a worse bug than the crash it replaced.
        if (reason) {
            *reason = e.reason.length ? e.reason : e.name;
        }
        return NO;
    }
}
