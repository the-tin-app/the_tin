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
    /// The camera, already configured. Built by `configured()`, which must run OFF the MainActor.
    struct Configured {
        let session: AVCaptureSession
        let output: AVCapturePhotoOutput
    }

    let session: AVCaptureSession
    private let output: AVCapturePhotoOutput
    private(set) var isAvailable: Bool
    // Serial, off-main queue for start/stop — same pattern as AVCaptureFrameSource. Apple
    // documents startRunning()/stopRunning() as blocking; a shared serial queue is what makes
    // "start, then immediately stop" (a fast tab switch) resolve in call order instead of
    // racing two independent detached tasks against the session.
    private let sessionQueue = DispatchQueue(label: "lens.session")
    private var pending: CheckedContinuation<CIImage?, Never>?
    // Tags `pending` with the settings' own uniqueID. Reusing one LensPhotoSource across a
    // stop() → start() → capture() cycle (exactly what a SwiftUI @State-held screen does on
    // disappear/appear) can leave an earlier capture's delegate callback still outstanding when
    // a newer capture begins. Without this tag, that stale callback would read whatever
    // `pending` holds AT THE MOMENT IT RUNS and resume the newer capture with the older image
    // (or a spurious nil) — no crash, just the wrong photo silently delivered. Both delegate
    // methods below ignore any callback whose uniqueID doesn't match this.
    private var pendingID: Int64?

    /// Cheap: everything expensive already happened in `configured()`. `nil` means no usable
    /// camera, and `isAvailable` stays false.
    init(_ built: Configured?) {
        session = built?.session ?? AVCaptureSession()
        output = built?.output ?? AVCapturePhotoOutput()
        isAvailable = built != nil
        super.init()
    }

    /// Acquires the camera and configures the session.
    ///
    /// ⚠️ `nonisolated`, and it MUST be called off the MainActor — that is the only reason this is
    /// split out of `init`. `AVCaptureDeviceInput(device:)` and the whole
    /// `beginConfiguration`/`commitConfiguration` sequence are documented as blocking, and doing
    /// them on the MainActor is exactly the shape of `ScannerPackModel.buildScanDependencies()`,
    /// which froze the tab switch for 5–10 s on an A10 (2026-08-03). Same fix as
    /// `CardDetailModel.load()`: build off-main, assign back on the MainActor.
    nonisolated static func configured() -> Configured? {
        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        // ⚠️ `.builtInWideAngleCamera`, NOT a virtual multi-camera device, and that choice is worth
        // 17 measured points of auto-lock. Framing two cards fills the frame from close enough that
        // iOS silently hands a virtual device's capture to the ULTRA-WIDE in macro mode; macro crops
        // that sensor and the crop is 12 MP whatever Photo Mode says. The first quadrant ladder was
        // shot that way by accident and EXIF gave it away — ƒ/2.2 at 25 mm where this camera is
        // ƒ/1.78 at 24 mm. At 12 MP quadrant framing only MATCHED a whole-page shot; at 24 MP it
        // gained 17 points. Neither the framing nor the sensor shows this on its own.
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else { return nil }

        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        session.addOutput(output)
        if #available(iOS 16.0, *) {
            output.maxPhotoDimensions = device.activeFormat.supportedMaxPhotoDimensions.last
                ?? output.maxPhotoDimensions
        }
        // Belt and braces for the same trap: a physical wide-angle device has no constituents, so
        // this is a no-op today — but it is what keeps a future switch to a virtual device from
        // quietly reintroducing macro handoff, which is invisible in every way except the accuracy.
        if #available(iOS 16.0, *), !device.constituentDevices.isEmpty,
           (try? device.lockForConfiguration()) != nil {
            device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
            device.unlockForConfiguration()
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
        return Configured(session: session, output: output)
    }

    /// Starts the session and suspends until `startRunning()` has actually returned. Callers
    /// MUST await this before the first `capture()` — `startRunning()` is documented as blocking
    /// and potentially slow, and `capturePhoto(with:delegate:)` against a session that hasn't
    /// started yet throws synchronously (a crash, not a recoverable error), so a fire-and-forget
    /// start plus an immediate shutter tap is a real race. Runs on `sessionQueue`, not a bare
    /// detached task, so it can never race a concurrent `stop()`.
    func start() async {
        guard isAvailable else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
                c.resume()
            }
        }
    }

    /// Stops the session. Settles any in-flight `capture()` with nil FIRST: `AVCapturePhotoOutput`
    /// does not retain its delegate for the duration of a capture (Apple puts that on the caller),
    /// so a screen tearing down mid-shutter-press — ordinary navigation, not an error — can
    /// deallocate `self` before the delegate ever fires. Without this, that leaks the awaiting
    /// task silently: no crash, no callback, just a hang.
    func stop() {
        if let c = pending {
            pending = nil
            pendingID = nil
            c.resume(returning: nil)
        }
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// One shutter press. A nil return means "not ready" — the lens is unavailable, the session
    /// hasn't finished starting (see `start()`), or a capture is already in flight — NOT
    /// "failed"; callers should not surface it as an error.
    func capture() async -> (id: UUID, image: CIImage)? {
        guard isAvailable, session.isRunning, pending == nil else { return nil }
        let settings = AVCapturePhotoSettings()
        // Ask for the full sensor per shot. `maxPhotoDimensions` on the OUTPUT sets the ceiling;
        // without asking here too, a capture comes back at the preset's default instead.
        if #available(iOS 16.0, *) { settings.maxPhotoDimensions = output.maxPhotoDimensions }
        let image = await withCheckedContinuation { (c: CheckedContinuation<CIImage?, Never>) in
            pendingID = settings.uniqueID
            pending = c
            output.capturePhoto(with: settings, delegate: self)
        }
        guard let image else { return nil }
        megapixels = Double(image.extent.width * image.extent.height) / 1_000_000
        return (UUID(), image)
    }

    /// Megapixels the last capture actually delivered.
    ///
    /// ⚠️ Surfaced to the user when it comes back small, because a silent 12 MP shot costs about a
    /// third of the auto-locks and is otherwise **completely invisible** — the photograph looks fine,
    /// the framing looks fine, and only the accuracy is wrong. This is the one symptom of the macro
    /// handoff a person can actually see.
    private(set) var megapixels: Double?

    /// ~20 MP: comfortably under the 24.5 MP a 4:3 main-camera still delivers on a 17 Pro Max, and
    /// comfortably over the 12.2 MP an ultra-wide macro crop delivers. Older phones with a genuine
    /// 12 MP main camera will trip it — which is honest, because they really do have less to work
    /// with, and the line says what to do about it rather than blaming the phone.
    var deliveredSmallPhoto: Bool { (megapixels ?? .infinity) < 20 }
}

extension LensPhotoSource: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let uniqueID = photo.resolvedSettings.uniqueID
        let image = photo.fileDataRepresentation().flatMap { CIImage(data: $0) }
        Task { @MainActor in
            // Drop this callback if it doesn't belong to the capture currently pending — a stop()
            // that already resumed the continuation, followed by a fresh capture(), does not stop
            // AVFoundation's underlying capture; its callback still arrives, tagged with the OLD
            // uniqueID, and must not be allowed to resolve the NEW capture with stale data.
            guard self.pendingID == uniqueID, let c = self.pending else { return }
            self.pending = nil
            self.pendingID = nil
            c.resume(returning: image)
        }
    }

    /// Terminal callback for a `capturePhoto` call — Apple documents this as firing exactly once
    /// per call regardless of success or failure, independent of whether
    /// `didFinishProcessingPhoto` fired at all. Backstop only: the happy path already resumed
    /// and cleared `pending`/`pendingID` above, so this is a no-op then. If some error path never
    /// calls through to `didFinishProcessingPhoto`, this is what keeps `capture()` from hanging
    /// forever — and the uniqueID guard keeps it from resolving a capture it doesn't belong to.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                                 error: Error?) {
        let uniqueID = resolvedSettings.uniqueID
        Task { @MainActor in
            guard self.pendingID == uniqueID, let c = self.pending else { return }
            self.pending = nil
            self.pendingID = nil
            c.resume(returning: nil)
        }
    }
}
