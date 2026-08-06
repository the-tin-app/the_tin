import AVFoundation
import CoreImage
import Observation

/// Full-resolution stills for the lens, on its OWN capture session.
///
/// ⚠️ Deliberately NOT a mode of `AVCaptureFrameSource`. That session is pinned to
/// `.hd1920x1080` because 4K starved the scanning pipeline into dropped, motion-blurred frames —
/// a hard-won on-device result. The lens needs the opposite (`.photo`, full sensor), so it gets
/// its own session rather than putting the scanner's tuning on a switch. The two never run
/// simultaneously: you are either scanning or lensing.
///
/// Why stills and not the live pipeline at all: a 1080p preview frame gives a card in a 40-card
/// case ~100 px of width against the 660 px canonical plate. A 12 MP still gives ~440–660 px.
/// The still-photo choice is load-bearing for whether this feature can work, not a UX preference.
@MainActor @Observable
final class LensPhotoSource: NSObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private(set) var isAvailable = false
    private var pending: CheckedContinuation<CIImage?, Never>?

    override init() {
        super.init()
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        session.addOutput(output)
        if #available(iOS 16.0, *) {
            output.maxPhotoDimensions = device.activeFormat.supportedMaxPhotoDimensions.last
                ?? output.maxPhotoDimensions
        }
        // Deliver the still UPRIGHT, the same fix that made the scanner match at all: the back
        // sensor is natively landscape, and a sideways image warps every rectified plate.
        if let conn = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
        session.commitConfiguration()
        isAvailable = true
    }

    func start() {
        guard isAvailable, !session.isRunning else { return }
        Task.detached { [session] in session.startRunning() }
    }

    func stop() {
        guard session.isRunning else { return }
        Task.detached { [session] in session.stopRunning() }
    }

    /// One shutter press. Returns nil on the simulator, on an AVFoundation error, or if a capture
    /// is already in flight.
    func capture() async -> (id: UUID, image: CIImage)? {
        guard isAvailable, pending == nil else { return nil }
        let settings = AVCapturePhotoSettings()
        let image = await withCheckedContinuation { (c: CheckedContinuation<CIImage?, Never>) in
            pending = c
            output.capturePhoto(with: settings, delegate: self)
        }
        guard let image else { return nil }
        return (UUID(), image)
    }
}

extension LensPhotoSource: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { CIImage(data: $0) }
        Task { @MainActor in
            let c = self.pending
            self.pending = nil
            c?.resume(returning: image)
        }
    }
}
