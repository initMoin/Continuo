import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
public struct AutomaticScreenshotImporter {
    public var configuration: AutomaticScreenshotSelectionConfiguration

    public init(
        configuration: AutomaticScreenshotSelectionConfiguration = AutomaticScreenshotSelectionConfiguration()
    ) {
        self.configuration = configuration
    }

    public func importRecentScreenshotCandidates(
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) async throws -> [SourceImage] {
        let authorizationStatus = await requestReadPermissionIfNeeded()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw ContinuoError.photoLibraryPermissionDenied
        }

        let assets = fetchScreenshotAssets()
        guard assets.count >= configuration.minimumSequenceLength else {
            throw ContinuoError.noMatchingScreenshotSequence
        }

        let destination = try makeDestinationDirectory()
        var sources: [SourceImage] = []
        sources.reserveCapacity(assets.count)

        do {
            for (index, asset) in assets.enumerated() {
                try Task.checkCancellation()
                progress(StitchProgress(
                    stage: .importing,
                    completed: index,
                    total: assets.count,
                    message: "Fetching screenshot \(index + 1) of \(assets.count)…"
                ))

                let thumbnailData = try await loadCandidateThumbnail(asset)
                let filename = resourceFilename(for: asset) ?? "Screenshot-\(index + 1).png"
                let localURL = destination
                    .appendingPathComponent("Auto-\(UUID().uuidString)")
                    .appendingPathExtension("png")
                try thumbnailData.write(to: localURL, options: [.atomic])

                sources.append(SourceImage(
                    localURL: localURL,
                    sourceIdentifier: asset.localIdentifier,
                    sourceOrigin: .photos,
                    pixelSize: PixelSize(width: asset.pixelWidth, height: asset.pixelHeight),
                    orientation: .up,
                    captureDate: asset.creationDate,
                    filename: filename
                ))

                progress(StitchProgress(
                    stage: .importing,
                    completed: index + 1,
                    total: assets.count,
                    message: "Fetched screenshot \(index + 1) of \(assets.count)."
                ))
            }
        } catch {
            for source in sources {
                try? FileManager.default.removeItem(at: source.localURL)
            }
            throw error
        }
        return sources
    }

    public func importFullResolutionSources(
        _ candidates: [SourceImage],
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) async throws -> [SourceImage] {
        let identifiers = candidates.compactMap(\.sourceIdentifier)
        guard identifiers.count == candidates.count else {
            throw ContinuoError.importFailed("the automatically selected screenshots")
        }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }

        let destination = try makeDestinationDirectory()
        var sources: [SourceImage] = []
        sources.reserveCapacity(candidates.count)
        do {
            for (index, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                guard
                    let identifier = candidate.sourceIdentifier,
                    let asset = assetsByIdentifier[identifier]
                else {
                    throw ContinuoError.sourceUnavailable(candidate.filename ?? "screenshot")
                }

                progress(StitchProgress(
                    stage: .importing,
                    completed: index,
                    total: candidates.count,
                    message: "Fetching selected screenshot \(index + 1) of \(candidates.count)…"
                ))
                let transfer = try await loadAsset(asset)
                let fileExtension = transfer.uti
                    .flatMap { UTType($0)?.preferredFilenameExtension }
                    ?? "png"
                let localURL = destination
                    .appendingPathComponent("Auto-Full-\(UUID().uuidString)")
                    .appendingPathExtension(fileExtension)
                try transfer.data.write(to: localURL, options: [.atomic])
                sources.append(SourceImage(
                    id: candidate.id,
                    localURL: localURL,
                    sourceIdentifier: identifier,
                    sourceOrigin: .photos,
                    pixelSize: PixelSize(width: asset.pixelWidth, height: asset.pixelHeight),
                    orientation: imageOrientation(transfer.orientation),
                    captureDate: asset.creationDate,
                    filename: transfer.filename ?? candidate.filename
                ))
                progress(StitchProgress(
                    stage: .importing,
                    completed: index + 1,
                    total: candidates.count,
                    message: "Fetched selected screenshot \(index + 1) of \(candidates.count)."
                ))
            }
        } catch {
            for source in sources {
                try? FileManager.default.removeItem(at: source.localURL)
            }
            throw error
        }
        return sources
    }

    private func fetchScreenshotAssets() -> [PHAsset] {
        var assets = collectAssets(
            with: NSPredicate(
                format: "mediaType == %d AND mediaSubtype == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
        )

        // Some Photos libraries expose screenshot files without the
        // photoScreenshot subtype. Only broaden the query when the typed
        // query cannot provide a complete candidate set, then keep assets
        // whose original resource name still identifies them as screenshots.
        if assets.count < configuration.minimumSequenceLength {
            let knownIdentifiers = Set(assets.map(\.localIdentifier))
            let fallbackAssets = collectAssets(
                with: NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue),
                limit: max(configuration.maximumCandidateCount * 8, 100)
            )
            assets.append(contentsOf: fallbackAssets.filter {
                !knownIdentifiers.contains($0.localIdentifier) && isLikelyScreenshot($0)
            })
        }

        return assets
            .prefix(configuration.maximumCandidateCount)
            .sorted {
            switch ($0.creationDate, $1.creationDate) {
            case let (left?, right?) where left != right:
                return left < right
            default:
                return $0.localIdentifier < $1.localIdentifier
            }
        }
    }

    private func collectAssets(with predicate: NSPredicate, limit: Int? = nil) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        let collectionLimit = limit ?? configuration.maximumCandidateCount
        options.fetchLimit = collectionLimit
        options.predicate = predicate

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(min(result.count, collectionLimit))
        result.enumerateObjects { asset, _, stop in
            guard assets.count < collectionLimit else {
                stop.pointee = true
                return
            }
            assets.append(asset)
        }
        return assets
    }

    private func isLikelyScreenshot(_ asset: PHAsset) -> Bool {
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            return true
        }
        let filename = resourceFilename(for: asset) ?? ""
        return filename.localizedCaseInsensitiveContains("screenshot")
    }

    private func requestReadPermissionIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else {
            return current
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func loadCandidateThumbnail(_ asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .fast
        let longestSide = max(1, max(asset.pixelWidth, asset.pixelHeight))
        let scale = min(
            1,
            CGFloat(configuration.candidateMaximumPixelSize) / CGFloat(longestSide)
        )
        let targetSize = CGSize(
            width: max(1, CGFloat(asset.pixelWidth) * scale),
            height: max(1, CGFloat(asset.pixelHeight) * scale)
        )

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                    return
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: ContinuoError.cancelled)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: ContinuoError.importFailed(error.localizedDescription))
                } else if let image, let data = Self.pngData(from: image) {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ContinuoError.importFailed("a screenshot thumbnail from Photos"))
                }
            }
        }
    }

#if os(iOS)
    nonisolated private static func pngData(from image: UIImage) -> Data? {
        image.pngData()
    }
#elseif os(macOS)
    nonisolated private static func pngData(from image: NSImage) -> Data? {
        guard
            let tiffData = image.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }
#endif

    private func loadAsset(_ asset: PHAsset) async throws -> AssetTransfer {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.resizeMode = .none
        let fallbackFilename = resourceFilename(for: asset)

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, uti, orientation, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: ContinuoError.cancelled)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: ContinuoError.importFailed(error.localizedDescription))
                } else if let data {
                    continuation.resume(
                        returning: AssetTransfer(
                            data: data,
                            uti: uti,
                            orientation: orientation,
                            filename: fallbackFilename
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: ContinuoError.importFailed("a screenshot from Photos")
                    )
                }
            }
        }
    }

    private func resourceFilename(for asset: PHAsset) -> String? {
        let resource = PHAssetResource.assetResources(for: asset).first
        if #available(iOS 27, macOS 27, *) {
            return resource?.filename
        }
        // The legacy property is deprecated in the iOS 27 SDK but remains
        // the compatibility path for the app's iOS 26 deployment target.
        return resource?.value(forKey: "originalFilename") as? String
    }

    private func imageOrientation(_ orientation: CGImagePropertyOrientation) -> ImageOrientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        case .left: .left
        @unknown default: .up
        }
    }

    private func makeDestinationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuoImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct AssetTransfer: Sendable {
        let data: Data
        let uti: String?
        let orientation: CGImagePropertyOrientation
        let filename: String?
    }
}
