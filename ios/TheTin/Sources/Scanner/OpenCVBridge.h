#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface OpenCVBridge : NSObject
+ (NSString *)opencvVersion;
+ (nullable NSDictionary *)fingerprintForImageBytes:(NSData *)png;
+ (nullable NSDictionary *)fingerprintForPixels:(NSData *)bgra
                                          width:(int)w
                                         height:(int)h
                                    bytesPerRow:(int)stride
    NS_SWIFT_NAME(fingerprint(forPixels:width:height:bytesPerRow:));
+ (int)ransacInliersBetween:(NSData *)descA keypointsA:(NSData *)kpA countA:(int)nA
              andDescriptors:(NSData *)descB keypointsB:(NSData *)kpB countB:(int)nB
    NS_SWIFT_NAME(ransacInliers(between:keypointsA:countA:andDescriptors:keypointsB:countB:));
@end
NS_ASSUME_NONNULL_END
