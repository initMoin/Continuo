import Foundation
import Photos

enum SourceDeletionError: LocalizedError, Sendable {
    case permissionDenied
    case noDeletableSources
    case missingPhotoIdentifier(String)
    case missingPhotoAsset(String)
    case missingFileAccess(String)
    case unsupportedSource(String)
    case fileDeletionFailed(String)
    case photoDeletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Continuo was not granted permission to delete the selected Photos items. Nothing was deleted."
        case .noDeletableSources:
            "There are no selected source images to delete."
        case let .missingPhotoIdentifier(filename):
            "Continuo could not identify the selected Photos item " + filename + ". Nothing was deleted."
        case let .missingPhotoAsset(identifier):
            "The selected Photos item " + identifier + " is no longer available. Nothing was deleted."
        case let .missingFileAccess(filename):
            "Continuo could not access the selected Files item " + filename + ". Nothing was deleted."
        case let .unsupportedSource(filename):
            "Continuo does not have a safe deletion reference for " + filename + ". Nothing was deleted."
        case let .fileDeletionFailed(filename):
            "Continuo could not delete the selected Files item " + filename + ". Photos items, if any, may already have been deleted."
        case let .photoDeletionFailed(message):
            "Continuo could not delete the selected Photos items: " + message
        }
    }
}

struct SourceDeletionService: Sendable {
    func delete(_ sources: [SourceImage]) async throws {
        guard !sources.isEmpty else {
            throw SourceDeletionError.noDeletableSources
        }

        let photosSources = sources.filter { $0.sourceOrigin == .photos }
        let fileSources = sources.filter { $0.sourceOrigin == .files }
        let unsupportedSources = sources.filter { $0.sourceOrigin == .unknown }

        if let unsupportedSource = unsupportedSources.first {
            throw SourceDeletionError.unsupportedSource(displayName(for: unsupportedSource))
        }
        guard !photosSources.isEmpty || !fileSources.isEmpty else {
            throw SourceDeletionError.noDeletableSources
        }

        // Resolve and validate all file references before changing either
        // source collection. This avoids deleting Files items when another
        // selected source cannot be resolved safely.
        let resolvedFiles = try fileSources.map(resolveFileSource)

        let photoAssets: [PHAsset]
        if photosSources.isEmpty {
            photoAssets = []
        } else {
            let status = await requestReadWritePermissionIfNeeded()
            guard status == .authorized || status == .limited else {
                throw SourceDeletionError.permissionDenied
            }
            photoAssets = try fetchPhotoAssets(for: photosSources)
        }

        // The stitched output is never passed into this service. Only the
        // exact original source references captured during import are used.
        if !photoAssets.isEmpty {
            try await deletePhotoAssets(photoAssets)
        }

        for file in resolvedFiles {
            try deleteFile(file)
        }
    }

    private func requestReadWritePermissionIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func fetchPhotoAssets(for sources: [SourceImage]) throws -> [PHAsset] {
        let identifiers = try sources.map { source in
            guard let identifier = source.sourceIdentifier, !identifier.isEmpty else {
                throw SourceDeletionError.missingPhotoIdentifier(displayName(for: source))
            }
            return identifier
        }

        let expectedIdentifiers = Set(identifiers)
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        let foundIdentifiers = Set(assets.map(\.localIdentifier))
        guard foundIdentifiers == expectedIdentifiers else {
            let missingIdentifier = expectedIdentifiers.subtracting(foundIdentifiers).first ?? identifiers[0]
            throw SourceDeletionError.missingPhotoAsset(missingIdentifier)
        }
        return assets
    }

    private func deletePhotoAssets(_ assets: [PHAsset]) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                } completionHandler: { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: SourceDeletionError.photoDeletionFailed("The Photos change was not committed."))
                    }
                }
            }
        } catch let error as SourceDeletionError {
            throw error
        } catch {
            throw SourceDeletionError.photoDeletionFailed(error.localizedDescription)
        }
    }

    private struct ResolvedFileSource: Sendable {
        let source: SourceImage
        let url: URL
    }

    private func resolveFileSource(_ source: SourceImage) throws -> ResolvedFileSource {
        let displayName = displayName(for: source)
        let resolvedURL: URL?

        if let bookmarkData = source.securityScopedBookmarkData {
            var isStale = false
            #if os(macOS)
            let bookmarkOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let bookmarkOptions: URL.BookmarkResolutionOptions = []
            #endif
            resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: bookmarkOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } else {
            resolvedURL = source.originalSourceURL
        }

        guard let resolvedURL else {
            throw SourceDeletionError.missingFileAccess(displayName)
        }

        let hasAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { resolvedURL.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw SourceDeletionError.missingFileAccess(displayName)
        }
        return ResolvedFileSource(source: source, url: resolvedURL)
    }

    private func deleteFile(_ resolved: ResolvedFileSource) throws {
        let hasAccess = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { resolved.url.stopAccessingSecurityScopedResource() }
        }

        do {
            try FileManager.default.removeItem(at: resolved.url)
        } catch {
            throw SourceDeletionError.fileDeletionFailed(displayName(for: resolved.source))
        }
    }

    private func displayName(for source: SourceImage) -> String {
        source.filename ?? source.originalSourceURL?.lastPathComponent ?? source.localURL.lastPathComponent
    }
}
