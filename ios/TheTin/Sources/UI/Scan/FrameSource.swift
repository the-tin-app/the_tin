import CoreVideo

/// Abstracts the origin of camera frames so `ScanModel` can be driven headlessly in
/// tests (a replayed fixture buffer) and by `AVCaptureSession` output on-device (Task 11).
protocol FrameSource {
    func stream() -> AsyncStream<CVPixelBuffer>
    /// Drop to a low idle frame rate, or return to the scanning rate. Called on every frame;
    /// implementations are expected to ignore a repeat of the state they are already in.
    func setIdle(_ idle: Bool)
}

extension FrameSource {
    /// Headless sources (a replayed fixture) have no capture device to throttle.
    func setIdle(_ idle: Bool) {}
}
