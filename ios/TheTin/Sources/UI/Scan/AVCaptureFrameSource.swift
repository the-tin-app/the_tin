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
    /// Held past `init` so the frame rate can be re-tuned live. Only written during `init`,
    /// before any frame is delivered.
    private var device: AVCaptureDevice?
    private var idle = false

    /// Frames per second with a card in view. The session's own default is 30, which is twice
    /// what the pipeline can spend: a lock needs `stabilityK` = 3 heavy frames and
    /// `fingerThrottle` spends 4 camera frames on each, so 15fps still locks in about a second —
    /// while halving the ISP, the per-frame document-segmentation pass, and the match cascade.
    private static let scanningFPS = 15.0
    /// Frames per second with nothing to look at. The scanner gets left open on a table between
    /// stacks, and at 30fps that is a segmentation network running ~22 times a second against a
    /// tabletop — the bulk of why the phone gets hot during a long session.
    private static let idleFPS = 2.0

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
            // AFTER commitConfiguration, not inside it: setting a session preset resets the
            // frame-duration properties, so capping the rate before the preset lands is a no-op.
            device.activeVideoMinFrameDuration = Self.frameDuration(capping: Self.scanningFPS, on: device)
            device.unlockForConfiguration()
        }
        self.device = device
    }

    /// Drop to `idleFPS` when there is nothing to look at — nothing detected for a while, or a
    /// sheet is up over the viewfinder — and back to `scanningFPS` when there is.
    func setIdle(_ idle: Bool) {
        guard idle != self.idle else { return }   // called per frame; only act on the transition
        self.idle = idle
        let fps = idle ? Self.idleFPS : Self.scanningFPS
        queue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            device.activeVideoMinFrameDuration = Self.frameDuration(capping: fps, on: device)
            device.unlockForConfiguration()
        }
    }

    /// The minimum frame DURATION that caps capture at `fps`, clamped to what the active format
    /// supports — an out-of-range duration raises rather than failing softly.
    ///
    /// Deliberately paired with `activeVideoMinFrameDuration` alone, never `max`: capping the
    /// maximum duration would also cap exposure time, and a card under indoor light needs the
    /// long exposures the camera chooses for itself.
    private static func frameDuration(capping fps: Double, on device: AVCaptureDevice) -> CMTime {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let lo = ranges.map(\.minFrameRate).min() ?? fps
        let hi = ranges.map(\.maxFrameRate).max() ?? fps
        return CMTime(seconds: 1 / min(max(fps, lo), hi), preferredTimescale: 600)
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

    /// Newest frame only. `AsyncStream`'s default policy is `.unbounded`, and `captureOutput`
    /// yields and returns instantly — so `alwaysDiscardsLateVideoFrames` never engages (AVFoundation
    /// sees a delegate that is never late) and the back-pressure lands here instead, as an unbounded
    /// queue of pool-owned `CVPixelBuffer`s.
    ///
    /// `ScanModel.run` consumes serially, one `pipeline.process` at a time. An A19 keeps up with
    /// 30fps so the queue sits at zero and this is invisible. An A10 iPad measured ~3 heavy frames
    /// per second (ScanDiag, 2026-07-27) ≈ 12 consumed against 30 produced — ~18 buffers a second
    /// accumulating. Two things break: retaining pool buffers past the delegate callback starves
    /// the capture pool until delivery degrades, and — worse — a FIFO queue hands the pipeline the
    /// OLDEST held frame, so it permanently analyses what the camera saw seconds ago. Hold a card
    /// steady and it is grinding on the blurred frames from while you were still moving it.
    ///
    /// `.bufferingNewest(1)` is what `alwaysDiscardsLateVideoFrames` was trying to express: drop
    /// stale frames, always work on a recent one, hold at most one buffer beyond the one in flight.
    func stream() -> AsyncStream<CVPixelBuffer> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
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
