// opencv2 headers must be included before any Apple/Foundation headers: OpenCV
// defines an `enum { NO, ... }` internally, and Foundation's `NO` macro
// (`__objc_no`) would otherwise be substituted into it, breaking the parse.
#import <opencv2/opencv.hpp>
#import "OpenCVBridge.h"
#import "FingerprintParams.h"

static NSDictionary *packORB(const cv::Mat &gray) {
    cv::Ptr<cv::ORB> orb = cv::ORB::create(
        kFPOrbNfeatures, kFPOrbScaleFactor, kFPOrbNlevels, kFPOrbEdgeThreshold,
        kFPOrbFirstLevel, kFPOrbWtaK, cv::ORB::HARRIS_SCORE, kFPOrbPatchSize, kFPOrbFastThreshold);
    std::vector<cv::KeyPoint> kps; cv::Mat desc;
    orb->detectAndCompute(gray, cv::noArray(), kps, desc);
    int n = desc.rows;
    NSMutableData *descData = [NSMutableData dataWithLength:n * 32];
    if (n > 0) memcpy(descData.mutableBytes, desc.data, n * 32);
    NSMutableData *kpData = [NSMutableData dataWithLength:n * 5 * sizeof(float)];
    float *kp = (float *)kpData.mutableBytes;
    for (int i = 0; i < n; i++) {
        kp[i*5+0] = kps[i].pt.x; kp[i*5+1] = kps[i].pt.y; kp[i*5+2] = kps[i].size;
        kp[i*5+3] = kps[i].angle; kp[i*5+4] = kps[i].response;
    }
    return @{ @"n": @(n), @"descriptors": descData, @"keypoints": kpData };
}

@implementation OpenCVBridge
+ (NSString *)opencvVersion {
    return [NSString stringWithUTF8String:CV_VERSION];
}

+ (nullable NSDictionary *)fingerprintForImageBytes:(NSData *)png {
    std::vector<uchar> buf((const uchar *)png.bytes, (const uchar *)png.bytes + png.length);
    cv::Mat bgr = cv::imdecode(buf, cv::IMREAD_COLOR);
    if (bgr.empty()) return nil;

    cv::Mat resized, gray;
    cv::resize(bgr, resized, cv::Size(kFPCanonW, kFPCanonH), 0, 0, cv::INTER_AREA);
    cv::cvtColor(resized, gray, cv::COLOR_BGR2GRAY);

    return packORB(gray);
}

+ (nullable NSDictionary *)fingerprintForPixels:(NSData *)bgra
                                          width:(int)w height:(int)h bytesPerRow:(int)stride {
    if (w != kFPCanonW || h != kFPCanonH) return nil;      // already-canonical contract
    if (bgra.length < (NSUInteger)stride * h) return nil;
    cv::Mat bgraMat(h, w, CV_8UC4, (void *)bgra.bytes, stride);
    cv::Mat gray;
    cv::cvtColor(bgraMat, gray, cv::COLOR_BGRA2GRAY);       // NO resize — plate is canonical
    return packORB(gray);
}

+ (int)ransacInliersBetween:(NSData *)descA keypointsA:(NSData *)kpA countA:(int)nA
              andDescriptors:(NSData *)descB keypointsB:(NSData *)kpB countB:(int)nB {
    if (nA < 4 || nB < 4) return 0;
    cv::Mat dA(nA, 32, CV_8U, (void *)descA.bytes);
    cv::Mat dB(nB, 32, CV_8U, (void *)descB.bytes);
    const float *kA = (const float *)kpA.bytes; // stride 2 (x,y)
    const float *kB = (const float *)kpB.bytes;

    cv::BFMatcher matcher(cv::NORM_HAMMING);
    std::vector<std::vector<cv::DMatch>> knn;
    matcher.knnMatch(dA, dB, knn, 2);

    std::vector<cv::Point2f> ptsA, ptsB;
    for (auto &m : knn) {
        if (m.size() == 2 && m[0].distance < 0.80f * m[1].distance) {
            ptsA.emplace_back(kA[m[0].queryIdx*2+0], kA[m[0].queryIdx*2+1]);
            ptsB.emplace_back(kB[m[0].trainIdx*2+0], kB[m[0].trainIdx*2+1]);
        }
    }
    if (ptsA.size() < 4) return (int)ptsA.size();
    cv::Mat mask;
    cv::findHomography(ptsA, ptsB, cv::RANSAC, 5.0, mask);
    if (mask.empty()) return 0;
    return cv::countNonZero(mask);
}
@end
