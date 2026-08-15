import AVFoundation
import SwiftUI
import UIKit

/// A plain QR reader for printed labels. Reports the first code it sees and then stops.
///
/// ⚠️ **`AVCaptureMetadataOutput`, NOT `DataScannerViewController`.** VisionKit's DataScanner
/// requires A12 or later; the iPad 7th gen this project tests on is an **A10**, so DataScanner is
/// unavailable on a device we ship to — and available on every simulator, which is precisely how
/// you build something that passes here and fails in Tomas's hands.
///
/// ⚠️ **This is the app's THIRD `AVCaptureSession`.** `ScanTabContainer` documents that the card
/// scanner and the Lens each own one and the hardware will not run both — and presenting a sheet
/// over a live scanner does NOT tear that session down. So this must only ever be presented from
/// somewhere no camera is running (today: the Tin's toolbar). It needs no fingerprint pack; a QR
/// code is read by the hardware, not by our matcher.
struct QRScannerView: UIViewControllerRepresentable {
    /// Called on the main actor for each newly-seen code. Return `true` to accept it and stop
    /// reading; return `false` to keep scanning — which is what a QR that isn't one of our labels
    /// gets, so pointing at a random poster doesn't dead-end the viewfinder.
    let onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: QRScannerViewController, context: Context) {
        vc.onCode = onCode
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Bool)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// `metadataOutput` fires repeatedly for a code still in frame; a second call would
    /// re-navigate on top of the screen the first one opened.
    private var reported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }   // no camera (simulator): stays black
        session.addInput(input)

        // ⚠️ The preset IS this reader's range, and the default (`.high`, 1080p) is not enough.
        // Detection runs on the capture stream, so what matters is how many PIXELS the code spans,
        // not how big it looks in the preview. The wide camera covers ~823 mm at 2 ft, so a
        // 22.6 mm label QR is ~2.7% of the frame — 52 px at 1080p, spread over 53 modules, i.e.
        // ~1 px per module against the ~2 the detector wants. That is why it only read once you
        // pinch-zoomed to 2.4×: zooming buys pixels. 4K doubles them linearly instead, for free
        // and without narrowing the field you have to aim.
        //
        // Falls back on anything without 4K — notably the A10 iPad's 8 MP camera, which tops out
        // at 1080p and therefore still wants the label closer. Resolution is the constraint there,
        // same as it is for the card scanner on that device.
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Set AFTER addOutput — availableMetadataObjectTypes is empty until the output has a
        // session, and assigning an unsupported type raises.
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reported = false
        guard !session.isRunning else { return }
        // startRunning blocks; off the main thread or the presentation animation hitches.
        Task.detached(priority: .userInitiated) { [session] in session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop HERE, not in deinit: this session must be gone before the user can reach the Scan
        // tab, and a view controller's deinit is not a guarantee about when.
        guard session.isRunning else { return }
        Task.detached(priority: .userInitiated) { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !reported,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let string = object.stringValue else { return }
        reported = onCode?(string) ?? true
    }
}
