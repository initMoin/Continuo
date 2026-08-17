import Foundation
import PhotosUI
import _PhotosUI_SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct PhotosImageImporter {
    public init() {}

    public func importItems(
        _ items: [PhotosPickerItem],
        progress: @escaping (StitchProgress) -> Void = { _ in }
    ) async throws -> [SourceImage] {
        let destination = try makeDestinationDirectory()
        var sources: [SourceImage] = []
        sources.reserveCapacity(items.count)

        // ContentView requests `.ordered` PhotosPicker selection behavior.
        // Process the binding sequentially so the user's selection order is
        // the source order presented to the stitch engine.
        for (index, item) in items.enumerated() {
            try validateStillImage(item, index: index)
            progress(StitchProgress(
                stage: .importing,
                completed: index,
                total: items.count,
                message: "Downloading screenshot \(index + 1) of \(items.count)…"
            ))
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ContinuoError.importFailed("selected screenshot \(index + 1)")
            }
            let fileExtension = item.supportedContentTypes
                .first(where: { $0.conforms(to: .image) })?
                .preferredFilenameExtension ?? "png"
            let filename = "Photo-\(index + 1).\(fileExtension)"
            let url = destination.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
            try data.write(to: url, options: [.atomic])
            sources.append(SourceImage(
                localURL: url,
                sourceIdentifier: item.itemIdentifier,
                sourceOrigin: .photos,
                filename: filename
            ))
            progress(StitchProgress(
                stage: .importing,
                completed: index + 1,
                total: items.count,
                message: "Imported screenshot \(index + 1) of \(items.count)."
            ))
        }
        return sources
    }

    private func validateStillImage(_ item: PhotosPickerItem, index: Int) throws {
        let contentTypes = item.supportedContentTypes
        let isLivePhoto = contentTypes.contains {
            $0.identifier == "com.apple.live-photo" || $0.identifier == "com.apple.live-photo-bundle"
        }
        let isMovie = contentTypes.contains { $0.conforms(to: .movie) }
        let isImage = contentTypes.isEmpty || contentTypes.contains { $0.conforms(to: .image) }

        guard isImage, !isLivePhoto, !isMovie else {
            throw ContinuoError.unsupportedMedia("Selected item \(index + 1)")
        }
    }

    private func makeDestinationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuoImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
