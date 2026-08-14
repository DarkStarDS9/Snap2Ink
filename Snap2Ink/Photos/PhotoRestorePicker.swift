import PhotosUI
import SwiftUI

/// Multi-select photo picker, scoped to images, for choosing which backed-up prints to resend.
///
/// `PHPickerViewController` runs out-of-process and grants scoped access to whatever the user
/// selects without any Photos permission at all — the permission this feature does need
/// (`NSPhotoLibraryAddUsageDescription`) is only for the backup *write* path in
/// `PhotoBackupService`. The user can browse into the configured album from the picker's own
/// chrome; there is no way (or need) to scope the picker itself to one album.
struct PhotoRestorePicker: UIViewControllerRepresentable {
    let onSelection: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelection: ([PHPickerResult]) -> Void

        init(onSelection: @escaping ([PHPickerResult]) -> Void) {
            self.onSelection = onSelection
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onSelection(results)
        }
    }
}
