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
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info:
                                   [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
