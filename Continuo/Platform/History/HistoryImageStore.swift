import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum HistoryStorageLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case onThisDevice
    case iCloudDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onThisDevice:
            "On This Device"
        case .iCloudDrive:
            "iCloud Drive"
        }
    }

    var systemImage: String {
        switch self {
        case .onThisDevice:
            "iphone"
        case .iCloudDrive:
            "icloud"
        }
    }
}

enum HistoryDeletionScope: Equatable, Sendable {
    case currentDevice
    case everywhere
}

enum HistorySyncState: Equatable, Sendable {
    case localOnly
    case syncing
    case upToDate
    case unavailable
    case failed

    var title: String {
        switch self {
        case .localOnly:
            "On this device"
        case .syncing:
            "Syncing with iCloud"
        case .upToDate:
            "Up to date"
        case .unavailable:
            "iCloud unavailable"
        case .failed:
            "Sync needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .localOnly:
            "iphone"
        case .syncing:
            "arrow.triangle.2.circlepath.icloud"
        case .upToDate:
            "checkmark.icloud"
        case .unavailable:
            "exclamationmark.icloud"
        case .failed:
            "exclamationmark.triangle"
        }
    }
}

enum HistoryImageStoreError: LocalizedError, Sendable {
    case directoryCreationFailed(String)
    case encodingFailed
    case metadataWriteFailed(String)
    case thumbnailCreationFailed
    case iCloudUnavailable
    case exportDownloadFailed(String)
    case exportDownloadTimedOut
    case migrationFailed(String, completed: Int?, total: Int?)

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
        case .iCloudUnavailable:
            "iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive before selecting it for history."
        case let .exportDownloadFailed(message):
            "Continuo could not download the full-resolution history image from iCloud Drive: \(message)"
        case .exportDownloadTimedOut:
            "Continuo is still downloading the full-resolution history image from iCloud Drive. Try again when it is available."
        case let .migrationFailed(message, completed, total):
            if let completed, let total, total > 0, completed < total {
                "History transfer incomplete: moved \(completed) of \(total) files. \(message)"
            } else {
                "Continuo could not move stitch history: \(message)"
            }
        }
    }
}

struct HistoryTransferProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case preparing
        case copying
        case loading
        case cleaning
        case finished
    }

    let phase: Phase
    let completed: Int
    let total: Int
    let currentFile: String?

    var fraction: Double {
        guard total > 0 else {
            return phase == .finished ? 1 : 0
        }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var message: String {
        switch phase {
        case .preparing:
            "Preparing history transfer…"
        case .copying:
            if let currentFile {
                "Moving \(currentFile)…"
            } else {
                "Moving stitch history…"
            }
        case .loading:
            "Reloading history at the new location…"
        case .cleaning:
            "Cleaning up the previous history location…"
        case .finished:
            "History transfer complete."
        }
    }
}

struct HistoryTransferResult: Sendable, Equatable {
    let source: HistoryStorageLocation
    let destination: HistoryStorageLocation
    let copiedFileCount: Int

    var message: String {
        let fileWord = copiedFileCount == 1 ? "file" : "files"
        return "Moved \(copiedFileCount) history \(fileWord) from \(source.title) to \(destination.title). Metadata, thumbnails, and full-resolution PNGs are stored in separate folders."
    }
}

struct HistoryAssetPreparationProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case checking
        case requestingDownload
        case downloading
        case ready
    }

    let phase: Phase
    let fraction: Double?

    var message: String {
        switch phase {
        case .checking:
            "Checking the full-resolution stitch…"
        case .requestingDownload:
            "Requesting the full-resolution stitch from iCloud…"
        case .downloading:
            "Downloading the full-resolution stitch from iCloud…"
        case .ready:
            "Full-resolution stitch is ready."
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
    static let iCloudContainerIdentifier = "iCloud.dev.iamshift.Continuo"

    private let directoryURL: URL
    private let fileManager: FileManager
    let location: HistoryStorageLocation
    let isAvailable: Bool

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        location: HistoryStorageLocation = .onThisDevice
    ) {
        self.fileManager = fileManager
        self.location = location
        self.isAvailable = location == .onThisDevice || directoryURL != nil || fileManager.url(forUbiquityContainerIdentifier: Self.iCloudContainerIdentifier) != nil
        if let directoryURL {
            self.directoryURL = directoryURL
        } else if location == .iCloudDrive {
            let containerURL = fileManager.url(forUbiquityContainerIdentifier: Self.iCloudContainerIdentifier)
                ?? fileManager.temporaryDirectory
            self.directoryURL = containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Continuo", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directoryURL = applicationSupport
                .appendingPathComponent("Continuo", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
        }
    }

    init(fileManager: FileManager = .default, directoryURL: URL) {
        self.fileManager = fileManager
        self.location = .onThisDevice
        self.isAvailable = true
        self.directoryURL = directoryURL
    }

    func migrateHistory(
        to destination: HistoryImageStore,
        progress: @escaping @Sendable (HistoryTransferProgress) -> Void = { _ in }
    ) throws -> HistoryTransferResult {
        guard location != destination.location || directoryURL != destination.directoryURL else {
            return HistoryTransferResult(source: location, destination: destination.location, copiedFileCount: 0)
        }

        var completed = 0
        var total = 0
        do {
            try destination.createDirectory()
            let files = try storedFiles()
            total = files.count
            progress(HistoryTransferProgress(
                phase: .preparing,
                completed: completed,
                total: total,
                currentFile: nil
            ))
            for (index, file) in files.enumerated() {
                let target = destination.migrationURL(for: file, relativeTo: directoryURL)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: file, to: target)
                completed = index + 1
                progress(HistoryTransferProgress(
                    phase: .copying,
                    completed: completed,
                    total: total,
                    currentFile: file.lastPathComponent
                ))
            }
            return HistoryTransferResult(
                source: location,
                destination: destination.location,
                copiedFileCount: completed
            )
        } catch {
            throw HistoryImageStoreError.migrationFailed(
                error.localizedDescription,
                completed: completed,
                total: total
            )
        }
    }

    func removeStoredFiles() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }
        let files = try storedFiles()
        for file in files {
            try fileManager.removeItem(at: file)
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
        guard isAvailable else {
            throw HistoryImageStoreError.iCloudUnavailable
        }
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
        guard isAvailable else {
            throw HistoryImageStoreError.iCloudUnavailable
        }
        try createDirectory()
        try migrateLegacyArchives()
        let decoder = JSONDecoder()
        var stitches: [CompletedStitch] = []
        let metadataFiles = try fileManager.contentsOfDirectory(
            at: metadataDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in metadataFiles where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let record = try? decoder.decode(HistoryRecord.self, from: data),
                let thumbnail = loadImage(at: thumbnailURL(for: record.id))
            else {
                continue
            }

            let fullResolutionURL: URL?
            if record.fullResolutionFilename != nil {
                let candidateURL = self.fullResolutionURL(for: record.id)
                fullResolutionURL = fileManager.fileExists(atPath: candidateURL.path) ? candidateURL : nil
            } else {
                fullResolutionURL = nil
            }
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
        guard isAvailable else {
            throw HistoryImageStoreError.iCloudUnavailable
        }
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

    /// Removes every persisted artifact for one history entry. When the store
    /// is backed by iCloud Drive, deleting these files propagates the deletion
    /// to the user's other devices through the ubiquitous container.
    func deleteHistory(id: UUID) throws {
        guard isAvailable else {
            throw HistoryImageStoreError.iCloudUnavailable
        }

        for url in [
            fullResolutionURL(for: id),
            thumbnailURL(for: id),
            metadataURL(for: id)
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func remove(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// Ensures an iCloud-backed asset has been downloaded before an exporter
    /// reads or transfers it. Local history files are immediately ready.
    func prepareForExport(
        _ url: URL,
        progress: @escaping @Sendable (HistoryAssetPreparationProgress) async -> Void = { _ in }
    ) async throws {
        await progress(HistoryAssetPreparationProgress(phase: .checking, fraction: nil))
        guard location == .iCloudDrive else {
            await progress(HistoryAssetPreparationProgress(phase: .ready, fraction: 1))
            return
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        var monitoredURL = url
        monitoredURL.removeAllCachedResourceValues()
        if let values = try? monitoredURL.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]) {
            if values.isUbiquitousItem == false || values.ubiquitousItemDownloadingStatus == .current {
                await progress(HistoryAssetPreparationProgress(phase: .ready, fraction: 1))
                return
            }
        }

        await progress(HistoryAssetPreparationProgress(phase: .requestingDownload, fraction: nil))
        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw HistoryImageStoreError.exportDownloadFailed(error.localizedDescription)
        }

        // Large, tall PNGs can take longer than a minute on a constrained
        // connection. Keep the operation cancellable while allowing five
        // minutes before presenting a retryable timeout.
        for _ in 0..<600 {
            try Task.checkCancellation()
            do {
                monitoredURL.removeAllCachedResourceValues()
                let values = try monitoredURL.resourceValues(forKeys: [
                    .ubiquitousItemDownloadingStatusKey,
                    .ubiquitousItemDownloadingErrorKey,
                    .ubiquitousItemIsDownloadingKey
                ])
                if let error = values.ubiquitousItemDownloadingError {
                    throw HistoryImageStoreError.exportDownloadFailed(error.localizedDescription)
                }
                if values.ubiquitousItemDownloadingStatus == .current {
                    await progress(HistoryAssetPreparationProgress(phase: .ready, fraction: 1))
                    return
                }
                await progress(HistoryAssetPreparationProgress(phase: .downloading, fraction: nil))
            } catch let error as HistoryImageStoreError {
                throw error
            } catch {
                throw HistoryImageStoreError.exportDownloadFailed(error.localizedDescription)
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        throw HistoryImageStoreError.exportDownloadTimedOut
    }

    private func createDirectory() throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for folder in ["Images", "Thumbnails", "Metadata"] {
                try fileManager.createDirectory(
                    at: directoryURL.appendingPathComponent(folder, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
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
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
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

        for url in urls where url.pathExtension == "json" {
            let idString = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: idString) else { continue }
            let destination = metadataURL(for: id)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: url, to: destination)
            }
        }

        for url in urls where url.pathExtension == "png" && url.lastPathComponent.hasSuffix(".thumbnail.png") {
            let idString = url
                .deletingPathExtension()
                .deletingPathExtension()
                .lastPathComponent
            guard let id = UUID(uuidString: idString) else { continue }
            let destination = thumbnailURL(for: id)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: url, to: destination)
            }
        }

        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "png" && !url.lastPathComponent.hasSuffix(".thumbnail.png") {
            let idString = url.deletingPathExtension().lastPathComponent
            guard
                let id = UUID(uuidString: idString),
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
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            let fullResolutionDestination = fullResolutionURL(for: id)
            if !fileManager.fileExists(atPath: fullResolutionDestination.path) {
                try fileManager.moveItem(at: url, to: fullResolutionDestination)
            }

            let thumbnailDestination = thumbnailURL(for: id)
            if !fileManager.fileExists(atPath: thumbnailDestination.path) {
                try writePNG(thumbnail, to: thumbnailDestination)
            }

            let existingRecord: HistoryRecord?
            if let data = try? Data(contentsOf: metadataURL(for: id)) {
                existingRecord = try? decoder.decode(HistoryRecord.self, from: data)
            } else {
                existingRecord = nil
            }
            try writeRecord(HistoryRecord(
                id: id,
                pixelSize: existingRecord?.pixelSize ?? PixelSize(width: width, height: height),
                savedAt: existingRecord?.savedAt ?? values?.creationDate ?? Date(),
                sources: existingRecord?.sources ?? [],
                sourceImagesDeleted: existingRecord?.sourceImagesDeleted ?? false,
                sourceDeletionError: existingRecord?.sourceDeletionError,
                fullResolutionFilename: fullResolutionDestination.lastPathComponent,
                thumbnailFilename: thumbnailDestination.lastPathComponent
            ))
        }
    }

    private func fullResolutionURL(for id: UUID) -> URL {
        imagesDirectoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("png")
    }

    private func thumbnailURL(for id: UUID) -> URL {
        thumbnailsDirectoryURL
            .appendingPathComponent("\(id.uuidString).thumbnail.png")
    }

    private func metadataURL(for id: UUID) -> URL {
        metadataDirectoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
    }

    private var imagesDirectoryURL: URL {
        directoryURL.appendingPathComponent("Images", isDirectory: true)
    }

    private var thumbnailsDirectoryURL: URL {
        directoryURL.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private var metadataDirectoryURL: URL {
        directoryURL.appendingPathComponent("Metadata", isDirectory: true)
    }

    private func storedFiles() throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory != true {
                files.append(url)
            }
        }
        return files
    }

    private func migrationURL(for file: URL, relativeTo sourceRoot: URL) -> URL {
        let relativePath = file.path.replacingOccurrences(
            of: sourceRoot.path + "/",
            with: ""
        )
        let components = relativePath.split(separator: "/")
        if components.count > 1 {
            return directoryURL.appendingPathComponent(relativePath)
        }

        switch file.pathExtension.lowercased() {
        case "json":
            return metadataDirectoryURL.appendingPathComponent(file.lastPathComponent)
        case "png" where file.lastPathComponent.hasSuffix(".thumbnail.png"):
            return thumbnailsDirectoryURL.appendingPathComponent(file.lastPathComponent)
        case "png":
            return imagesDirectoryURL.appendingPathComponent(file.lastPathComponent)
        default:
            return directoryURL.appendingPathComponent(file.lastPathComponent)
        }
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
