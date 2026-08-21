import PhotosUI
import SwiftUI

/// Native Photos picker that preserves selection order and returns the
/// underlying Photos asset identifier needed for safe deletion.
struct OrderedPhotosPicker: View {
    let onComplete: ([PHPickerResult]) -> Void

    var body: some View {
#if os(iOS)
        OrderedPhotosPickerView(onComplete: onComplete)
            .ignoresSafeArea()
#elseif os(macOS)
        OrderedPhotosPickerView(onComplete: onComplete)
#endif
    }
}

#if os(iOS)
private struct OrderedPhotosPickerView: UIViewControllerRepresentable {
    let onComplete: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let configuration = makeConfiguration()
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    private func makeConfiguration() -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 50
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        return configuration
    }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([PHPickerResult]) -> Void

        init(onComplete: @escaping ([PHPickerResult]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onComplete(results)
            picker.dismiss(animated: true)
        }
    }
}
#elseif os(macOS)
private struct OrderedPhotosPickerView: NSViewControllerRepresentable {
    let onComplete: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeNSViewController(context: Context) -> PHPickerViewController {
        let configuration = makeConfiguration()
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateNSViewController(_ picker: PHPickerViewController, context: Context) {}

    private func makeConfiguration() -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 50
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        return configuration
    }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([PHPickerResult]) -> Void

        init(onComplete: @escaping ([PHPickerResult]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onComplete(results)
            picker.dismiss(nil)
        }
    }
}
#endif
