import CoreVideo

/// Abstracts the origin of camera frames so `ScanModel` can be driven headlessly in
/// tests (a replayed fixture buffer) and by `AVCaptureSession` output on-device (Task 11).
protocol FrameSource {
    func stream() -> AsyncStream<CVPixelBuffer>
}
