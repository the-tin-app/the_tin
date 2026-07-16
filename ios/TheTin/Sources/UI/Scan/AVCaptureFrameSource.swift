import AVFoundation
import CoreVideo

/// Production `FrameSource` — delivers `CVPixelBuffer`s from the back camera on a
/// dedicated capture queue. Blank/no-op on the simulator (no camera device available).
///
/// Tuned for card scanning (Plan 5 device validation): 1080p (not 4K — the plate is only
/// 660×920, and 4K starved the pipeline into dropped/blurred frames), full-range continuous
/// autofocus, and — critically — the sample buffers are delivered UPRIGHT (portrait). The
/// back sensor is natively landscape, so without an explicit rotation the card arrives
/// sideways and every perspective-corrected plate is rotated/squished vs the upright
/// references → noise-floor matches. Portrait orientation was the decisive on-device fix.
final class AVCaptureFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "scan.frames")
    private var continuation: AsyncStream<CVPixelBuffer>.Continuation?

    override init() {
        super.init()
        guard let device = Self.bestCamera(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }

        session.beginConfiguration()
        // 1080p, NOT 4K: the plate is only 660×920, so 4K adds no usable detail but makes
        // Vision rectangle-detection + nf=1000 matching so slow that most frames are dropped
        // (alwaysDiscardsLateVideoFrames) — yielding sparse, motion-blurred, mostly-wrong-match
        // captures on device. 1080p keeps the pipeline at frame rate → sharper, consistent plates.
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        else { session.sessionPreset = .high }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        // Deliver the sample buffers UPRIGHT (portrait). The back sensor is natively landscape;
        // without this the card arrives rotated 90° in the pixel buffer (the preview layer
        // auto-orients so it *looks* upright, but the data output does not), so perspective-
        // correction warps a sideways card into the portrait 660×920 plate — rotated/squished
        // vs the upright references → noise-floor matches. This is the on-device match blocker.
        if let conn = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
        session.commitConfiguration()

        // Continuous autofocus across the FULL range. The prior `.near` restriction kept the
        // card soft at a normal hand-held scanning distance (low Laplacian focus → wrong
        // matches); let AF settle at whatever distance the user actually holds the card.
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .none }
            device.unlockForConfiguration()
        }
    }

    /// A macro-capable virtual device (triple / dual-wide) when present — it defaults to the
    /// wide lens but auto-switches to the ultra-wide for close focus — falling back to the
    /// plain wide-angle camera.
    private static func bestCamera() -> AVCaptureDevice? {
        for t: AVCaptureDevice.DeviceType in [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera] {
            if let d = AVCaptureDevice.default(t, for: .video, position: .back) { return d }
        }
        return nil
    }

    func stream() -> AsyncStream<CVPixelBuffer> {
        AsyncStream { cont in
            self.continuation = cont
            self.queue.async { self.session.startRunning() }
            cont.onTermination = { @Sendable _ in self.queue.async { self.session.stopRunning() } }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                        from connection: AVCaptureConnection) {
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { continuation?.yield(pb) }
    }
}
