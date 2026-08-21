import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct StitchedImageDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.png]
    static let writableContentTypes: [UTType] = [.png]

    private let data: Data?
    private let sourceURL: URL

    init(image: CGImage) throws {
        guard let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  destinationData,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        data = destinationData as Data
        sourceURL = URL(fileURLWithPath: "")
    }

    init(fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        data = nil
        sourceURL = fileURL
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        sourceURL = URL(fileURLWithPath: "")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let data {
            return FileWrapper(regularFileWithContents: data)
        }
        return try FileWrapper(url: sourceURL, options: .immediate)
    }
}
