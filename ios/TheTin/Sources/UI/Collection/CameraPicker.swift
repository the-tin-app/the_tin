import SwiftUI
import UIKit

/// One still from the camera.
///
/// `UIImagePickerController`, not an AVCapture session: the scanner needs a live frame pipeline
/// and pays for it, this needs a single photo, and the system camera UI (framing, flash, retake)
/// is free. ~30 lines against a scanner-sized amount of code.
///
/// ⚠️ `.camera` is unavailable on the simulator — callers must gate on
/// `UIImagePickerController.isSourceTypeAvailable(.camera)` or the controller presents empty.
///
/// ⚠️ **This deliberately does NOT use `@Environment(\.dismiss)`.** It did, and on a device the
/// camera opened and closed instantly, taking the whole entry-form sheet with it: `dismiss` resolves
/// against whatever presentation the environment currently points at, and when the enclosing cover
/// is re-identified mid-presentation that is the SHEET, not the cover. `onFinish` hands the result
/// back and lets the owner lower its own flag, which can only ever close the cover.
struct CameraPicker: UIViewControllerRepresentable {
    /// nil = cancelled. Called exactly once.
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = PortraitImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    /// `UISupportedInterfaceOrientations` is portrait-only, and `UIImagePickerController` ignores
    /// it: turn the phone while the camera is up and the whole capture UI goes landscape (device,
    /// 2026-08-10). A card is photographed portrait, and the report's exhibit is laid out for
    /// portrait, so pin it rather than accept whichever way the phone was tilted.
    final class PortraitImagePickerController: UIImagePickerController {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
        override var shouldAutorotate: Bool { false }
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let onFinish: (UIImage?) -> Void
        /// The delegate can fire twice (cancel racing a finish); the owner must not be told twice.
        private var finished = false

        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        private func finish(_ image: UIImage?) {
            guard !finished else { return }
            finished = true
            onFinish(image)
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info:
                                   [UIImagePickerController.InfoKey: Any]) {
            finish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            finish(nil)
        }
    }
}
