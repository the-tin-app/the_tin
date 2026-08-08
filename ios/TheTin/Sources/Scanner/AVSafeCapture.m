#import "AVSafeCapture.h"

BOOL TinRunCatchingObjCException(void (NS_NOESCAPE ^block)(void), NSString **reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        // ⚠️ Reported, never swallowed. The point of surviving this is to be able to say what happened:
        // a silent no-op is a worse bug than the crash it replaced, and the reason string is what turns
        // the next configuration mistake into a one-look diagnosis.
        if (reason) {
            *reason = e.reason.length ? e.reason : e.name;
        }
        return NO;
    }
}
