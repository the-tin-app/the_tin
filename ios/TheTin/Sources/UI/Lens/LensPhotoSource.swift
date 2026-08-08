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
        /// Kept so `capture()` can ask the LIVE active format what it supports. The whole ordering bug
        /// was reading that once, early, and trusting it later.
        let device: AVCaptureDevice
    }

    let session: AVCaptureSession
    private let output: AVCapturePhotoOutput
    private(set) var isAvailable: Bool
    private let device: AVCaptureDevice?
    /// What the live active format offered at the last capture, for the on-screen diagnostic.
    private var offeredDimensions: [String] = []
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
        device = built?.device
        super.init()
    }

    /// What we asked for and what arrived, for a device runsheet to quote verbatim.
    ///
    /// ⚠️ DEBUG only. It exists because "the photo came back small" has several possible causes — the
    /// wrong format queried, an unsorted dimensions list, a macro handoff — and one device session was
    /// already spent narrowing them by inference. A line on screen answers it in one look.
    var diagnostic: String? {
        #if DEBUG
        let got = megapixels.map { String(format: "%.1f MP", $0) } ?? "—"
        let offers = offeredDimensions.isEmpty ? "(not asked yet)" : offeredDimensions.joined(separator: ", ")
        return "got \(got) · offers \(offers)"
        #else
        return nil
        #endif
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
        // ⚠️ Photo dimensions are NOT chosen here. They are chosen per capture, from the format that is
        // active at that moment — see `capture()`. Choosing them here is what crashed a device build:
        // `.photo` re-selects the active format when the session starts, so a value read before
        // `startRunning()` can be absent from `supportedMaxPhotoDimensions` by the time the shutter is
        // pressed, and `capturePhoto` raises an NSException for exactly that. Swift cannot catch it.
        return Configured(session: session, output: output, device: device)
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
    /// ⚠️ Returns the image ONLY. It used to hand back an `(id:, image:)` pair, and that id was a trap:
    /// the caller stores the image under an id of its own, so a second id from here is one more thing
    /// that has to agree with the first. It didn't, and the whole feature silently found zero cards.
    func capture() async -> CIImage? {
        guard isAvailable, session.isRunning, pending == nil else { return nil }
        let settings = AVCapturePhotoSettings()
        applyPhotoDimensions(to: settings)
        let image = await withCheckedContinuation { (c: CheckedContinuation<CIImage?, Never>) in
            pendingID = settings.uniqueID
            pending = c
            // ⚠️ Through the shim, because this call is documented to RAISE and Swift cannot catch it.
            // A crash here happened, twice, mid-scan. See `AVSafeCapture.h`.
            var reason: NSString?
            if !TinCapturePhotoSafely(output, settings, self, &reason) {
                captureFailure = (reason as String?) ?? "the camera refused the capture"
                pending = nil
                pendingID = nil
                c.resume(returning: nil)
            }
        }
        guard let image else { return nil }
        megapixels = Double(image.extent.width * image.extent.height) / 1_000_000
        captureFailure = nil
        return image
    }

    /// Asks for the biggest photograph the ACTIVE format will give us, and asks at capture time.
    ///
    /// ⚠️ Every part of this is where it is because of a crash. `settings.maxPhotoDimensions` must be
    /// one of the live `activeFormat.supportedMaxPhotoDimensions` or `capturePhoto` raises — so the
    /// list is read here, immediately before the call, and `settings` is only given a value that came
    /// out of that very list. Nothing is remembered from configuration time, because `.photo` changes
    /// the active format when the session starts.
    ///
    /// ⚠️ And it deliberately prefers the largest option **at or under ~26 MP** rather than the
    /// absolute largest. The 63.3% auto-lock figure was measured on 24.5 MP photographs; a 48 MP
    /// sensor option is four times the pixels of 12 MP for a card whose short side is already well past
    /// the >1,300 px band where accuracy stopped improving, and it would be an unmeasured 4× increase
    /// in memory on a screen that holds a photograph, runs two Vision requests over it and renders a
    /// plate per card. Matching the configuration the number was measured at is the conservative
    /// choice; raising it is a change that should come with its own measurement.
    private func applyPhotoDimensions(to settings: AVCapturePhotoSettings) {
        guard #available(iOS 16.0, *), let device else { return }
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        offeredDimensions = sizes.map { "\($0.width)×\($0.height)" }
        guard !sizes.isEmpty else { return }
        let area = { (d: CMVideoDimensions) in Int(d.width) * Int(d.height) }
        let ceiling = 26_000_000
        let pick = sizes.filter { area($0) <= ceiling }.max { area($0) < area($1) }
            ?? sizes.min { area($0) < area($1) }
        guard let pick else { return }
        // The OUTPUT's ceiling has to admit it too, or the settings are still invalid.
        if area(output.maxPhotoDimensions) < area(pick) { output.maxPhotoDimensions = pick }
        settings.maxPhotoDimensions = pick
    }

    /// Set when the camera refused a capture, so the screen can say so instead of a shutter that
    /// silently does nothing.
    private(set) var captureFailure: String?

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

    var megapixelsText: String {
        megapixels.map { String(format: "%.1f MP", $0) } ?? "unknown size"
    }
}

extension LensPhotoSource: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let uniqueID = photo.resolvedSettings.uniqueID
        // ⚠️ `.applyOrientationProperty` is NOT optional, and omitting it is silent in the worst way.
        // `AVCapturePhotoOutput` honours the connection's rotation angle as **metadata**: the pixel
        // buffer stays in the sensor's native landscape and the JPEG carries an EXIF orientation tag
        // saying which way up it is. `CIImage(data:)` ignores that tag by default — so we handed every
        // stage a 90°-rotated photograph.
        //
        // It did not look like an orientation bug, which is why it cost a device session. Matching
        // still worked, because `MultiCardDetector` resolves each card's own upright rotation and a
        // sideways page just means every card lands in the [90, 270] class — so the RIGHT cards came
        // back. But their quad centres were in rotated space, so `BinderPlan.slot` quantized x against
        // y and the binder came out scrambled: correct cards, wrong pockets. The tile crop looked
        // sideways for the same reason.
        let image = photo.fileDataRepresentation()
            .flatMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
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
