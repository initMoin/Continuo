import Foundation
import PhotosUI
import UniformTypeIdentifiers

@MainActor
public struct PhotosImageImporter {
    public init() {}

    public func importItems(
        _ results: [PHPickerResult],
        progress: @escaping (StitchProgress) -> Void = { _ in }
    ) async throws -> [SourceImage] {
        try await importProviders(
            results.enumerated().map { index, result in
                PhotoTransfer(
                    provider: result.itemProvider,
                    sourceIdentifier: result.assetIdentifier,
                    contentTypes: result.itemProvider.registeredTypeIdentifiers.compactMap(UTType.init),
                    index: index
                )
            },
            progress: progress
        )
    }

    private func importProviders(
        _ transfers: [PhotoTransfer],
        progress: @escaping (StitchProgress) -> Void
    ) async throws -> [SourceImage] {
        let destination = try makeDestinationDirectory()
        var sources: [SourceImage] = []
        sources.reserveCapacity(transfers.count)

        // PHPicker returns results in the order selected when its selection
        // behavior is `.ordered`. Process sequentially so that order remains
        // the source order presented to the stitch engine.
        for transfer in transfers {
            guard let sourceIdentifier = transfer.sourceIdentifier, !sourceIdentifier.isEmpty else {
                throw ContinuoError.importFailed(
                    "selected screenshot \(transfer.index + 1) could not be linked to its Photos asset"
                )
            }
            try validateStillImage(transfer.contentTypes, index: transfer.index)
            progress(StitchProgress(
                stage: .importing,
                completed: transfer.index,
                total: transfers.count,
                message: "Downloading screenshot \(transfer.index + 1) of \(transfers.count)…"
            ))
            let data = try await transfer.loadData()
            let fileExtension = transfer.contentTypes
                .first(where: { $0.conforms(to: .image) })?
                .preferredFilenameExtension ?? "png"
            let filename = "Photo-\(transfer.index + 1).\(fileExtension)"
            let url = destination.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
            try data.write(to: url, options: [.atomic])
            sources.append(SourceImage(
                localURL: url,
                sourceIdentifier: sourceIdentifier,
                sourceOrigin: .photos,
                filename: filename
            ))
            progress(StitchProgress(
                stage: .importing,
                completed: transfer.index + 1,
                total: transfers.count,
                message: "Imported screenshot \(transfer.index + 1) of \(transfers.count)."
            ))
        }
        return sources
    }

    private func validateStillImage(_ contentTypes: [UTType], index: Int) throws {
        let isLivePhoto = contentTypes.contains {
            $0.identifier == "com.apple.live-photo" || $0.identifier == "com.apple.live-photo-bundle"
        }
        let isMovie = contentTypes.contains { $0.conforms(to: .movie) }
        let isImage = contentTypes.isEmpty || contentTypes.contains { $0.conforms(to: .image) }

        guard isImage, !isLivePhoto, !isMovie else {
            throw ContinuoError.unsupportedMedia("Selected item \(index + 1)")
        }
    }

    private struct PhotoTransfer {
        let provider: NSItemProvider
        let sourceIdentifier: String?
        let contentTypes: [UTType]
        let index: Int

        func loadData() async throws -> Data {
            guard let typeIdentifier = contentTypes.first(where: { $0.conforms(to: .image) })?.identifier else {
                throw ContinuoError.importFailed("selected screenshot \(index + 1)")
            }

            let provider = provider
            let index = index
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    if let error {
                        continuation.resume(throwing: ContinuoError.importFailed("selected screenshot \(index + 1): \(error.localizedDescription)"))
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: ContinuoError.importFailed("selected screenshot \(index + 1)"))
                    }
                }
            }
        }
    }

    private func makeDestinationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuoImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
