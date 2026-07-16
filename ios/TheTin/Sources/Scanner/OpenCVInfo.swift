import Foundation

/// Thin Swift surface over the Obj-C++ OpenCV bridge, so other targets
/// (tests) depend on Swift symbols rather than the bridging header.
enum OpenCVInfo {
    static var version: String { OpenCVBridge.opencvVersion() }
}
