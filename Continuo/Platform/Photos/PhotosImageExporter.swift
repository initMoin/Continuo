import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum PhotosImageExportError: LocalizedError, Sendable {
    case permissionDenied
    case encodingFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Continuo does not have permission to add images to Photos. Enable Photos access in Settings and try again."
        case .encodingFailed:
            "Continuo could not encode the full-resolution stitched PNG."
        case let .saveFailed(message):
            "Photos could not save the stitched image: \(message)"
        }
    }
}

struct PhotosImageExporter: Sendable {
    func save(_ image: CGImage) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Continuo-Stitched-\(UUID().uuidString)")
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotosImageExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotosImageExportError.encodingFailed
        }

        try await save(fileURL: url, shouldMoveFile: false)
    }

    func save(fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PhotosImageExportError.saveFailed("The full-resolution history image is no longer available.")
        }
        try await save(fileURL: fileURL, shouldMoveFile: true)
    }

    private func save(fileURL: URL, shouldMoveFile: Bool) async throws {
        let status = await requestAddPermissionIfNeeded()
        guard status == .authorized || status == .limited else {
            throw PhotosImageExportError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = shouldMoveFile
                request.addResource(with: .photo, fileURL: fileURL, options: options)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: PhotosImageExportError.saveFailed(error.localizedDescription))
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PhotosImageExportError.saveFailed("The Photos change was not committed."))
                }
            }
        }
    }

    private func requestAddPermissionIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
