import CoreGraphics
import Foundation
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import Continuo

final class ContinuoTests: XCTestCase {
    func testNormalizationPreservesFullResolutionAndNormalizesOrientation() throws {
        let image = try XCTUnwrap(makeTestImage(width: 80, rows: (0..<160).map { Float($0) / 160.0 }))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("continuo-normalization-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(image, to: url)

        let source = SourceImage(localURL: url, filename: "fixture.png")
        let normalized = try ImageNormalizer().normalize(source)

        XCTAssertEqual(normalized.originalPixelSize, PixelSize(width: 80, height: 160))
        XCTAssertEqual(normalized.workingPixelSize, PixelSize(width: 80, height: 160))
        XCTAssertEqual(normalized.image.width, 80)
        XCTAssertEqual(normalized.image.height, 160)
        XCTAssertEqual(normalized.source.orientation, .up)
        XCTAssertEqual(normalized.matchingRepresentation.grayscale.count, normalized.workingPixelSize.area)
        XCTAssertEqual(normalized.matchingRepresentation.edgeMagnitude.count, normalized.workingPixelSize.area)
        XCTAssertGreaterThan(normalized.matchingRepresentation.edgeMagnitude.max() ?? 0, 0)
    }

    func testFileImporterPreservesSelectionOrder() throws {
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("continuo-order-first-(UUID().uuidString).png")
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("continuo-order-second-(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        try writePNG(try XCTUnwrap(makeTestImage(width: 4, rows: [0.1, 0.2])), to: firstURL)
        try writePNG(try XCTUnwrap(makeTestImage(width: 4, rows: [0.3, 0.4])), to: secondURL)

        let imported = try FileImageImporter().importFiles([secondURL, firstURL])

        XCTAssertEqual(imported.map(\.filename), [secondURL.lastPathComponent, firstURL.lastPathComponent])
        XCTAssertEqual(imported.map(\.sourceOrigin), [.files, .files])
        XCTAssertEqual(imported.map(\.originalSourceURL), [secondURL, firstURL])
        XCTAssertTrue(imported.allSatisfy { $0.localURL != $0.originalSourceURL })
    }

    func testPixelRegionCropperPreservesExactPixelWindow() throws {
        let values: [[Float]] = [
            [0.05, 0.15, 0.25, 0.35],
            [0.45, 0.55, 0.65, 0.75],
            [0.85, 0.95, 0.10, 0.20]
        ]
        let image = try XCTUnwrap(makeTestImage(values: values))

        let cropped = try PixelRegionCropper().crop(
            image,
            to: Rect2D(x: 1, y: 1, width: 2, height: 2)
        )
        let data = try XCTUnwrap(cropped.dataProvider?.data as Data?)
        let redValues = (0..<cropped.height).flatMap { y in
            (0..<cropped.width).map { x in
                data[(y * cropped.bytesPerRow) + (x * 4)]
            }
        }

        XCTAssertEqual(cropped.width, 2)
        XCTAssertEqual(cropped.height, 2)
        XCTAssertEqual(redValues, [140, 165, 242, 25])
    }

    func testPixelRegionCropperRejectsInvalidAndOutOfBoundsRegions() throws {
        let image = try XCTUnwrap(makeTestImage(width: 4, rows: [0.1, 0.2, 0.3]))
        let cropper = PixelRegionCropper()

        XCTAssertThrowsError(
            try cropper.crop(image, to: Rect2D(x: 0, y: 0, width: 0, height: 1))
        ) { error in
            XCTAssertEqual(
                error as? PixelCropError,
                .invalidRectangle(Rect2D(x: 0, y: 0, width: 0, height: 1))
            )
        }

        XCTAssertThrowsError(
            try cropper.crop(image, to: Rect2D(x: 3, y: 2, width: 2, height: 1))
        ) { error in
            guard case let .rectangleOutOfBounds(rectangle, imageSize) = error as? PixelCropError else {
                return XCTFail("Expected an out-of-bounds crop error, got \(error).")
            }
            XCTAssertEqual(rectangle, Rect2D(x: 3, y: 2, width: 2, height: 1))
            XCTAssertEqual(imageSize, PixelSize(width: 4, height: 3))
        }
    }

    func testSourceDeletionRemovesOriginalFileButNotImportedWorkingCopy() async throws {
        let originalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-delete-original-\(UUID().uuidString).png")
        let workingCopyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-delete-working-copy-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: workingCopyURL)
        }

        let image = try XCTUnwrap(makeTestImage(width: 4, rows: [0.1, 0.2]))
        try writePNG(image, to: originalURL)
        try FileManager.default.copyItem(at: originalURL, to: workingCopyURL)

        let source = SourceImage(
            localURL: workingCopyURL,
            sourceOrigin: .files,
            originalSourceURL: originalURL,
            filename: originalURL.lastPathComponent
        )

        try await SourceDeletionService().delete([source])

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingCopyURL.path))
    }

    func testRegistrationFindsVerticalTranslationAndReportsConfidence() async throws {
        let width = 16
        let firstRows = variedRows(start: 0, count: 100)
        let secondRows = variedRows(start: 40, count: 100)
        let firstImage = try XCTUnwrap(makeTestImage(width: width, rows: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(width: width, rows: secondRows))
        let first = makeNormalizedImage(id: UUID(), image: firstImage, rows: firstRows)
        let second = makeNormalizedImage(id: UUID(), image: secondImage, rows: secondRows)

        let result = try await PairwiseRegistrar().register(from: first, to: second)
        XCTAssertTrue(
            result.confidence == .high || result.confidence == .medium,
            "confidence=\(result.confidence), translation=(\(result.transform.tx), \(result.transform.ty)), similarity=\(result.diagnostics.similarityScore)"
        )
        XCTAssertLessThanOrEqual(
            abs(result.transform.ty - 40),
            2,
            "translation=(\(result.transform.tx), \(result.transform.ty))"
        )
        XCTAssertGreaterThan(result.diagnostics.overlapPercentage, 0.4)
        XCTAssertNil(result.diagnostics.failureReason, "diagnostics=\(result.diagnostics)")
        XCTAssertGreaterThan(result.diagnostics.candidateCount, 0)
    }

    func testRegistrationEvaluatesComplementaryFallbackStrategies() async throws {
        let width = 16
        let firstRows = variedRows(start: 0, count: 100)
        let secondRows = variedRows(start: 40, count: 100)
        let firstImage = try XCTUnwrap(makeTestImage(width: width, rows: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(width: width, rows: secondRows))
        let first = makeNormalizedImage(id: UUID(), image: firstImage, rows: firstRows)
        let second = makeNormalizedImage(id: UUID(), image: secondImage, rows: secondRows)
        let configuration = RegistrationConfiguration(
            mediumSimilarityThreshold: 1.01,
            lowSimilarityThreshold: 0.50
        )

        let result = try await PairwiseRegistrar(configuration: configuration).register(from: first, to: second)

        XCTAssertGreaterThan(result.diagnostics.candidateCount, 1, "diagnostics=\(result.diagnostics)")
        XCTAssertTrue(
            result.diagnostics.backend == .rowProfile || result.diagnostics.backend == .correlationFallback,
            "diagnostics=\(result.diagnostics)"
        )
        XCTAssertLessThanOrEqual(abs(result.transform.ty - 40), 2, "diagnostics=\(result.diagnostics)")
    }

    func testRegistrationUsesOverlapLocalAgreementForTextLikeContent() async throws {
        let width = 16
        let sharedRows = variedRows(start: 0, count: 40)
        let firstRows = Array(repeating: 0.05, count: 60) + sharedRows
        let secondRows = sharedRows + Array(repeating: 0.95, count: 60)
        let firstImage = try XCTUnwrap(makeTestImage(width: width, rows: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(width: width, rows: secondRows))
        let first = makeNormalizedImage(id: UUID(), image: firstImage, rows: firstRows)
        let second = makeNormalizedImage(id: UUID(), image: secondImage, rows: secondRows)

        let result = try await PairwiseRegistrar().register(from: first, to: second)

        XCTAssertTrue(result.confidence.isAccepted, "diagnostics=\(result.diagnostics)")
        XCTAssertLessThanOrEqual(abs(result.transform.ty - 60), 2)
        XCTAssertGreaterThan(result.diagnostics.similarityScore, 0.80)
    }

    func testRegistrationToleratesDetailedTextRenderingVariation() async throws {
        let width = 16
        let firstValues = detailedRows(start: 0, count: 100, width: width)
        let secondValues = renderedVariant(detailedRows(start: 40, count: 100, width: width))
        let firstImage = try XCTUnwrap(makeTestImage(values: firstValues))
        let secondImage = try XCTUnwrap(makeTestImage(values: secondValues))
        let first = makeNormalizedImage(id: UUID(), image: firstImage, values: firstValues)
        let second = makeNormalizedImage(id: UUID(), image: secondImage, values: secondValues)

        let result = try await PairwiseRegistrar().register(from: first, to: second)

        XCTAssertTrue(result.confidence.isAccepted, "diagnostics=\(result.diagnostics)")
        XCTAssertLessThanOrEqual(abs(result.transform.ty - 40), 2, "diagnostics=\(result.diagnostics)")
        XCTAssertGreaterThan(result.diagnostics.overlapPercentage, 0.4, "diagnostics=\(result.diagnostics)")
    }

    func testLowAgreementProducesExplicitFailureDiagnostics() async throws {
        let width = 16
        let firstRows = (0..<100).map { Float($0) / 100.0 }
        let secondRows = (0..<100).map { Float(($0 * 37) % 101) / 100.0 }
        let firstImage = try XCTUnwrap(makeTestImage(width: width, rows: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(width: width, rows: secondRows))
        let first = makeNormalizedImage(id: UUID(), image: firstImage, rows: firstRows)
        let second = makeNormalizedImage(id: UUID(), image: secondImage, rows: secondRows)

        let result = try await PairwiseRegistrar().register(from: first, to: second)
        XCTAssertFalse(result.confidence.isAccepted, "diagnostics=\(result.diagnostics)")
        XCTAssertNotNil(result.diagnostics.failureReason, "diagnostics=\(result.diagnostics)")
        XCTAssertFalse(result.diagnostics.message.isEmpty, "diagnostics=\(result.diagnostics)")
        XCTAssertFalse(result.diagnostics.recoverySuggestion.isEmpty, "diagnostics=\(result.diagnostics)")
    }

    func testRendererProducesOneCanvasWithoutDuplicatingOverlap() throws {
        let width = 16
        let firstRows = (0..<100).map { Float($0) / 100.0 }
        let secondRows = (40..<140).map { Float($0) / 100.0 }
        let firstImage = try XCTUnwrap(makeTestImage(width: width, rows: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(width: width, rows: secondRows))
        let firstID = UUID()
        let secondID = UUID()
        let first = makeNormalizedImage(id: firstID, image: firstImage, rows: firstRows)
        let second = makeNormalizedImage(id: secondID, image: secondImage, rows: secondRows)
        let diagnostics = JoinDiagnostics(
            code: "registration.accepted",
            message: "High-confidence vertical join.",
            recoverySuggestion: "",
            similarityScore: 1,
            overlapSize: PixelSize(width: width, height: 60),
            overlapPercentage: 0.6,
            translation: Point2D(x: 0, y: 40),
            crossAxisDrift: 0,
            residualError: 0,
            backend: .correlationFallback,
            ambiguousCandidates: false,
            candidateCount: 1
        )
        let join = JoinResult(
            fromSourceID: firstID,
            toSourceID: secondID,
            transform: AffineTransformData(translation: Point2D(x: 0, y: 40)),
            overlapRect: Rect2D(x: 0, y: 40, width: Double(width), height: 60),
            seam: SeamDefinition(axis: .horizontal, position: 60),
            confidence: .high,
            diagnostics: diagnostics
        )

        let preview = try PreviewRenderer().render(sources: [first, second], joins: [join])

        XCTAssertEqual(preview.pixelSize, PixelSize(width: width, height: 140))
        XCTAssertEqual(preview.placements.count, 2)
        XCTAssertEqual(preview.placements[1].frame.y, 40)
        XCTAssertEqual(preview.joins, [join])
    }

    func testRendererUsesPlacedFrameIntersectionForTheIncomingSeam() throws {
        let firstValues: [Float] = [0.10, 0.20, 0.30, 0.40]
        let secondValues: [Float] = [0.30, 0.40, 0.50, 0.60]
        let firstImage = try XCTUnwrap(makeTestImage(width: 1, rows: firstValues))
        let secondImage = try XCTUnwrap(makeTestImage(width: 1, rows: secondValues))
        let firstID = UUID()
        let secondID = UUID()
        let first = makeNormalizedImage(id: firstID, image: firstImage, rows: firstValues, width: 1)
        let second = makeNormalizedImage(id: secondID, image: secondImage, rows: secondValues, width: 1)
        let diagnostics = JoinDiagnostics(
            code: "registration.accepted",
            message: "High-confidence vertical join.",
            recoverySuggestion: "",
            similarityScore: 1,
            overlapSize: PixelSize(width: 1, height: 2),
            overlapPercentage: 0.5,
            translation: Point2D(x: 0, y: 2),
            crossAxisDrift: 0,
            residualError: 0,
            backend: .correlationFallback,
            ambiguousCandidates: false,
            candidateCount: 1
        )
        let join = JoinResult(
            fromSourceID: firstID,
            toSourceID: secondID,
            transform: AffineTransformData(translation: Point2D(x: 0, y: 2)),
            overlapRect: Rect2D(x: 0, y: 2, width: 1, height: 2),
            // Deliberately stale: the renderer must use the placed frame
            // intersection instead of duplicating or dropping content.
            seam: SeamDefinition(axis: .horizontal, position: 0),
            confidence: .high,
            diagnostics: diagnostics
        )

        let preview = try PreviewRenderer().render(sources: [first, second], joins: [join])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("continuo-renderer-seam-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(preview.image, to: url)

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let data = try XCTUnwrap(rendered.dataProvider?.data as Data?)
        let rowValues = stride(from: 0, to: data.count, by: 4).map { Double(data[$0]) / 255.0 }
        XCTAssertEqual(rowValues.count, 6)
        XCTAssertEqual(rowValues.map { $0.rounded(toPlaces: 2) }, [0.10, 0.20, 0.30, 0.40, 0.50, 0.60])
    }

    func testRendererFeathersBackgroundDisagreementAtSurgicalSeam() throws {
        let firstValues: [Float] = [0.10, 0.10, 0.10, 0.10]
        let secondValues: [Float] = [0.30, 0.30, 0.90, 0.90]
        let firstID = UUID()
        let secondID = UUID()
        let first = makeNormalizedImage(
            id: firstID,
            image: try XCTUnwrap(makeTestImage(width: 1, rows: firstValues)),
            values: firstValues,
            width: 1
        )
        let second = makeNormalizedImage(
            id: secondID,
            image: try XCTUnwrap(makeTestImage(width: 1, rows: secondValues)),
            values: secondValues,
            width: 1
        )
        let diagnostics = JoinDiagnostics(
            code: "registration.accepted",
            message: "High-confidence vertical join.",
            recoverySuggestion: "",
            similarityScore: 0.9,
            overlapSize: PixelSize(width: 1, height: 2),
            overlapPercentage: 0.5,
            translation: Point2D(x: 0, y: 2),
            crossAxisDrift: 0,
            residualError: 0.1,
            backend: .correlationFallback,
            ambiguousCandidates: false,
            candidateCount: 1
        )
        let join = JoinResult(
            fromSourceID: firstID,
            toSourceID: secondID,
            transform: AffineTransformData(translation: Point2D(x: 0, y: 2)),
            overlapRect: Rect2D(x: 0, y: 2, width: 1, height: 2),
            seam: SeamDefinition(axis: .horizontal, position: 0),
            confidence: .high,
            diagnostics: diagnostics
        )

        let preview = try PreviewRenderer().render(sources: [first, second], joins: [join])
        let data = try XCTUnwrap(preview.image.dataProvider?.data as Data?)
        let rowValues = stride(from: 0, to: data.count, by: 4).map { Double(data[$0]) / 255.0 }

        XCTAssertEqual(rowValues.count, 6)
        XCTAssertGreaterThan(rowValues[3], 0.10)
        XCTAssertLessThan(rowValues[3], 0.35)
        XCTAssertGreaterThan(rowValues[4], 0.70)
    }

    func testRendererPreservesTopToBottomPixelOrder() throws {
        let image = try XCTUnwrap(makeTestImage(values: [[Float(1.0)], [Float(0.0)]]))
        let sourceID = UUID()
        let source = makeNormalizedImage(
            id: sourceID,
            image: image,
            values: [Float(1.0), Float(0.0)],
            width: 1
        )

        let preview = try PreviewRenderer().render(sources: [source], joins: [])
        let data = try XCTUnwrap(preview.image.dataProvider?.data as Data?)

        XCTAssertGreaterThan(data[0], 200, "The top source row must remain the top preview row.")
        XCTAssertLessThan(data[4], 50, "The bottom source row must remain the bottom preview row.")
    }

    private func makeNormalizedImage(id: UUID, image: CGImage, rows: [Float], width: Int = 16) -> NormalizedImage {
        let values = rows.flatMap { row in
            (0..<width).map { column in
                let columnTexture = Float((column * 37 + 7) % 17) / 16.0 * 0.45
                return (row * 0.5) + columnTexture
            }
        }
        return makeNormalizedImage(id: id, image: image, values: values, width: width)
    }

    private func makeNormalizedImage(id: UUID, image: CGImage, values: [[Float]]) -> NormalizedImage {
        makeNormalizedImage(id: id, image: image, values: values.flatMap { $0 }, width: values.first?.count ?? 0)
    }

    private func makeNormalizedImage(id: UUID, image: CGImage, values: [Float], width: Int) -> NormalizedImage {
        let height = max(1, values.count / max(1, width))
        let mean = values.reduce(0, +) / Float(max(1, values.count))
        let centered = values.map { $0 - mean }
        let source = SourceImage(id: id, localURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).png"), filename: id.uuidString)
        return NormalizedImage(
            source: source,
            image: image,
            matchingRepresentation: MatchingRepresentation(width: width, height: height, grayscale: centered),
            originalPixelSize: PixelSize(width: width, height: height),
            workingPixelSize: PixelSize(width: width, height: height)
        )
    }

    private func makeTestImage(width: Int, rows: [Float]) -> CGImage? {
        let values = rows.map { row in
            (0..<width).map { column in
                let columnTexture = Float((column * 37 + 7) % 17) / 16.0 * 0.45
                return (row * 0.5) + columnTexture
            }
        }
        return makeTestImage(values: values)
    }

    private func makeTestImage(values: [[Float]]) -> CGImage? {
        let width = values.first?.count ?? 0
        let height = values.count
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(max(0, min(255, Int(values[y][x] * 255))))
                let offset = ((y * width) + x) * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func detailedRows(start: Int, count: Int, width: Int) -> [[Float]] {
        let rowValues = variedRows(start: start, count: count)
        return (start..<(start + count)).enumerated().map { rowIndex, absoluteRow in
            return (0..<width).map { column in
                let columnTexture = Float((column * 37 + 7) % 17) / 16.0 * 0.45
                var value = (rowValues[rowIndex] * 0.5) + columnTexture
                let line = absoluteRow % 24
                let glyphColumn = (column + (absoluteRow / 24) * 3) % 13
                if (4...16).contains(line), glyphColumn < 2 || glyphColumn == 5 || glyphColumn == 9 {
                    value *= 0.35
                }
                return max(0, min(1, value))
            }
        }
    }

    private func renderedVariant(_ values: [[Float]]) -> [[Float]] {
        values.enumerated().map { rowIndex, row in
            row.enumerated().map { columnIndex, value in
                let selector = (rowIndex * 17 + columnIndex * 13) % 31
                let variation: Float
                if selector == 0 {
                    variation = 0.10
                } else if selector == 1 || selector == 2 {
                    variation = -0.06
                } else {
                    variation = 0
                }
                return max(0, min(1, value + variation))
            }
        }
    }

    private func variedRows(start: Int, count: Int) -> [Float] {
        var state: UInt32 = 0x1234_5678
        var allRows: [Float] = []
        allRows.reserveCapacity(start + count)
        for _ in 0..<(start + count) {
            state = state &* 1_664_525 &+ 1_013_904_223
            allRows.append(Float(state % 251) / 251.0)
        }
        return Array(allRows[start..<(start + count)])
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
