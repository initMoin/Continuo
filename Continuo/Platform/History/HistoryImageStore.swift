import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HistoryImageStoreError: LocalizedError, Sendable {
    case directoryCreationFailed(String)
    case encodingFailed
    case metadataWriteFailed(String)
    case thumbnailCreationFailed

    var errorDescription: String? {
        switch self {
        case let .directoryCreationFailed(message):
            "Continuo could not prepare local history storage: \(message)"
        case .encodingFailed:
            "Continuo could not retain the full-resolution stitched PNG."
        case let .metadataWriteFailed(message):
            "Continuo could not update stitch history: \(message)"
        case .thumbnailCreationFailed:
            "Continuo could not create a lightweight history thumbnail."
        }
    }
}

struct HistoryImageAsset: @unchecked Sendable {
    let thumbnail: CGImage
    let fullResolutionURL: URL
    let pixelSize: PixelSize
}

/// Persists lightweight history records and thumbnails separately from each
/// removable full-resolution PNG.
struct HistoryImageStore: @unchecked Sendable {
    private static let thumbnailMaximumPixelSize = 1_600

    private let directoryURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directoryURL = applicationSupport
                .appendingPathComponent("Continuo", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
        }
    }

    func archive(
        image: CGImage,
        pixelSize: PixelSize,
        id: UUID,
        savedAt: Date = Date(),
        sources: [SourceImage] = [],
        sourceImagesDeleted: Bool = false
    ) throws -> HistoryImageAsset {
        try createDirectory()

        let fullResolutionURL = self.fullResolutionURL(for: id)
        let thumbnailURL = self.thumbnailURL(for: id)
        do {
            try writePNG(image, to: fullResolutionURL)
            guard let thumbnail = Self.makeThumbnail(
                from: image,
                maximumPixelSize: Self.thumbnailMaximumPixelSize
            ) else {
                throw HistoryImageStoreError.thumbnailCreationFailed
            }
            try writePNG(thumbnail, to: thumbnailURL)
            try writeRecord(HistoryRecord(
                id: id,
                pixelSize: pixelSize,
                savedAt: savedAt,
                sources: sources,
                sourceImagesDeleted: sourceImagesDeleted,
                sourceDeletionError: nil,
                fullResolutionFilename: fullResolutionURL.lastPathComponent,
                thumbnailFilename: thumbnailURL.lastPathComponent
            ))
            return HistoryImageAsset(
                thumbnail: thumbnail,
                fullResolutionURL: fullResolutionURL,
                pixelSize: pixelSize
            )
        } catch {
            try? fileManager.removeItem(at: fullResolutionURL)
            try? fileManager.removeItem(at: thumbnailURL)
            try? fileManager.removeItem(at: metadataURL(for: id))
            throw error
        }
    }

    func load() throws -> [CompletedStitch] {
        try createDirectory()
        try migrateLegacyArchives()
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        var stitches: [CompletedStitch] = []
        for url in urls where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let record = try? decoder.decode(HistoryRecord.self, from: data),
                let thumbnail = loadImage(
                    at: directoryURL.appendingPathComponent(record.thumbnailFilename)
                )
            else {
                continue
            }

            let fullResolutionURL = record.fullResolutionFilename.map {
                directoryURL.appendingPathComponent($0)
            }.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
            var stitch = CompletedStitch(
                id: record.id,
                thumbnail: thumbnail,
                fullResolutionURL: fullResolutionURL,
                pixelSize: record.pixelSize,
                savedAt: record.savedAt,
                sources: record.sources,
                sourceImagesDeleted: record.sourceImagesDeleted
            )
            stitch.sourceDeletionError = record.sourceDeletionError
            stitches.append(stitch)
        }
        return stitches.sorted { $0.savedAt > $1.savedAt }
    }

    func update(_ stitch: CompletedStitch) throws {
        try createDirectory()
        try writeRecord(HistoryRecord(
            id: stitch.id,
            pixelSize: stitch.pixelSize,
            savedAt: stitch.savedAt,
            sources: stitch.sources,
            sourceImagesDeleted: stitch.sourceImagesDeleted,
            sourceDeletionError: stitch.sourceDeletionError,
            fullResolutionFilename: stitch.fullResolutionURL?.lastPathComponent,
            thumbnailFilename: thumbnailURL(for: stitch.id).lastPathComponent
        ))
    }

    func remove(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    private func createDirectory() throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw HistoryImageStoreError.directoryCreationFailed(error.localizedDescription)
        }
    }

    private func writeRecord(_ record: HistoryRecord) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: metadataURL(for: record.id), options: [.atomic])
        } catch {
            throw HistoryImageStoreError.metadataWriteFailed(error.localizedDescription)
        }
    }

    private func writePNG(_ image: CGImage, to destinationURL: URL) throws {
        let temporaryURL = directoryURL
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw HistoryImageStoreError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HistoryImageStoreError.encodingFailed
        }

        try? fileManager.removeItem(at: destinationURL)
        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            throw HistoryImageStoreError.encodingFailed
        }
    }

    private func migrateLegacyArchives() throws {
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "png" && !url.lastPathComponent.hasSuffix(".thumbnail.png") {
            let idString = url.deletingPathExtension().lastPathComponent
            guard
                let id = UUID(uuidString: idString),
                !fileManager.fileExists(atPath: metadataURL(for: id).path),
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                let thumbnail = Self.makeThumbnail(
                    from: source,
                    maximumPixelSize: Self.thumbnailMaximumPixelSize
                )
            else {
                continue
            }
            let thumbnailURL = thumbnailURL(for: id)
            try writePNG(thumbnail, to: thumbnailURL)
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            try writeRecord(HistoryRecord(
                id: id,
                pixelSize: PixelSize(width: width, height: height),
                savedAt: values?.creationDate ?? Date(),
                sources: [],
                sourceImagesDeleted: false,
                sourceDeletionError: nil,
                fullResolutionFilename: url.lastPathComponent,
                thumbnailFilename: thumbnailURL.lastPathComponent
            ))
        }
    }

    private func fullResolutionURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }

    private func thumbnailURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).thumbnail.png")
    }

    private func metadataURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func makeThumbnail(from image: CGImage, maximumPixelSize: Int) -> CGImage? {
        let longestSide = max(image.width, image.height)
        let scale = min(1, CGFloat(maximumPixelSize) / CGFloat(max(1, longestSide)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func makeThumbnail(from source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private struct HistoryRecord: Codable, Sendable {
        let id: UUID
        let pixelSize: PixelSize
        let savedAt: Date
        let sources: [SourceImage]
        let sourceImagesDeleted: Bool
        let sourceDeletionError: String?
        let fullResolutionFilename: String?
        let thumbnailFilename: String
    }
}
