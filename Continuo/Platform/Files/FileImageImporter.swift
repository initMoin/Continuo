import Foundation
import UniformTypeIdentifiers

public struct FileImageImporter: Sendable {
    public init() {}

    public func importFiles(_ urls: [URL]) throws -> [SourceImage] {
        let destination = try makeDestinationDirectory()
        return try urls.enumerated().compactMap { index, url in
            let type = UTType(filenameExtension: url.pathExtension)
            guard type?.conforms(to: .image) == true else { return nil }

            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            #if os(macOS)
            let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            let bookmarkOptions: URL.BookmarkCreationOptions = []
            #endif
            let bookmarkData = try? url.bookmarkData(
                options: bookmarkOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            let fileExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let copiedURL = destination
                .appendingPathComponent("File-\(index + 1)-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: url, to: copiedURL)
            return SourceImage(
                localURL: copiedURL,
                sourceOrigin: .files,
                originalSourceURL: url,
                securityScopedBookmarkData: bookmarkData,
                filename: url.lastPathComponent
            )
        }
    }

    private func makeDestinationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContinuoImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
