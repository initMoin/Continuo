import CoreGraphics
import Foundation
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import Continuo

final class ContinuoTests: XCTestCase {
    func testSupportProductIDsRemainStable() {
        XCTAssertEqual(
            SupportProduct.allCases.map(\.rawValue),
            [
                "continuo.support.lemon_cookie",
                "continuo.support.caramel_latte",
                "continuo.support.philly_cheesesteak"
            ]
        )
    }

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
        XCTAssertEqual(normalized.matchingRepresentation.rowMeans.count, normalized.workingPixelSize.height)
        XCTAssertEqual(normalized.matchingRepresentation.rowVariances.count, normalized.workingPixelSize.height)
        XCTAssertEqual(normalized.matchingRepresentation.rowEdgeEnergy.count, normalized.workingPixelSize.height)
        XCTAssertGreaterThan(normalized.matchingRepresentation.edgeMagnitude.max() ?? 0, 0)
    }

    func testBackgroundNormalizationBoundsMatchingPixelsAndKeepsOutputSize() throws {
        let image = try XCTUnwrap(makeTestImage(
            width: 80,
            rows: (0..<160).map { Float($0) / 160.0 }
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-matching-normalization-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(image, to: url)

        let normalizer = ImageNormalizer(
            configuration: ImageNormalizationConfiguration(matchingMaximumPixelSize: 64)
        )
        let normalized = try normalizer.normalizeForMatching(
            SourceImage(localURL: url, filename: "fixture.png")
        )

        XCTAssertEqual(normalized.workingPixelSize, PixelSize(width: 80, height: 160))
        XCTAssertLessThanOrEqual(max(normalized.image.width, normalized.image.height), 64)
        XCTAssertEqual(normalized.image.width, normalized.matchingImage.width)
        XCTAssertEqual(normalized.image.height, normalized.matchingImage.height)
        XCTAssertEqual(
            normalized.matchingRepresentation.grayscale.count,
            normalized.matchingImage.width * normalized.matchingImage.height
        )
    }

    func testDisplayThumbnailBoundsPixelsWithoutBuildingAStitchPreview() throws {
        let image = try XCTUnwrap(makeTestImage(
            width: 80,
            rows: (0..<160).map { Float($0) / 160.0 }
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-display-thumbnail-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(image, to: url)

        let thumbnail = try ImageNormalizer().makeThumbnail(
            SourceImage(localURL: url, filename: "fixture.png"),
            maximumPixelSize: 40
        )

        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 40)
        XCTAssertEqual(thumbnail.width, 20)
        XCTAssertEqual(thumbnail.height, 40)
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

    @MainActor
    func testImportingAdditionalFilesAppendsToUnsavedSelection() throws {
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-append-first-\(UUID().uuidString).png")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-append-second-\(UUID().uuidString).png")
        let historyRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-append-history-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
            try? FileManager.default.removeItem(at: historyRootURL)
        }

        let image = try XCTUnwrap(makeTestImage(width: 4, rows: [0.2, 0.8]))
        try writePNG(image, to: firstURL)
        try writePNG(image, to: secondURL)

        let viewModel = ContinuoViewModel(
            historyImageStore: HistoryImageStore(directoryURL: historyRootURL)
        )
        viewModel.importFiles([firstURL])
        viewModel.importFiles([secondURL])

        XCTAssertEqual(viewModel.sources.count, 2)
        XCTAssertEqual(viewModel.sources.map(\.originalSourceURL), [firstURL, secondURL])
        viewModel.clearSources()
    }

    func testAutomaticScreenshotSelectorPrefersLongestCompatibleChronologicalPath() {
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let first = makeSequenceSource("first", date: baseDate)
        let second = makeSequenceSource("second", date: baseDate.addingTimeInterval(4))
        let unrelated = makeSequenceSource("unrelated", date: baseDate.addingTimeInterval(8))
        let fourth = makeSequenceSource("fourth", date: baseDate.addingTimeInterval(12))
        let fifth = makeSequenceSource("fifth", date: baseDate.addingTimeInterval(16))

        let joins = [
            makeAcceptedJoin(from: first.id, to: second.id, translation: Point2D(x: 0, y: 40), overlapHeight: 60),
            makeAcceptedJoin(from: second.id, to: unrelated.id, translation: Point2D(x: 0, y: 40), overlapHeight: 60),
            makeAcceptedJoin(from: unrelated.id, to: fourth.id, translation: Point2D(x: 0, y: 40), overlapHeight: 60),
            makeAcceptedJoin(from: fourth.id, to: fifth.id, translation: Point2D(x: 0, y: 40), overlapHeight: 60)
        ]

        let selection = AutomaticScreenshotSequenceSelector().select(
            sources: [fifth, unrelated, first, fourth, second],
            joins: joins
        )

        XCTAssertEqual(selection?.sources.map(\.filename), ["first", "second", "unrelated", "fourth", "fifth"])
        XCTAssertEqual(selection?.joinCount, 4)
        XCTAssertEqual(selection?.joins.map(\.id), joins.map(\.id))
    }

    func testAutomaticScreenshotSelectorDoesNotBridgeLargeCreationDateGaps() {
        let baseDate = Date(timeIntervalSince1970: 2_000)
        let first = makeSequenceSource("first", date: baseDate)
        let second = makeSequenceSource("second", date: baseDate.addingTimeInterval(4))
        let distant = makeSequenceSource("distant", date: baseDate.addingTimeInterval(900))

        let joins = [
            makeAcceptedJoin(from: first.id, to: second.id, translation: Point2D(x: 0, y: 40), overlapHeight: 60),
            makeAcceptedJoin(from: second.id, to: distant.id, translation: Point2D(x: 0, y: 40), overlapHeight: 60)
        ]

        let selection = AutomaticScreenshotSequenceSelector().select(
            sources: [first, second, distant],
            joins: joins
        )

        XCTAssertEqual(selection?.sources.map(\.filename), ["first", "second"])
        XCTAssertEqual(selection?.joinCount, 1)
    }

    func testAutomaticScreenshotSelectorSupportsReverseCaptureDirection() {
        let baseDate = Date(timeIntervalSince1970: 3_000)
        let bottom = makeSequenceSource("bottom", date: baseDate)
        let middle = makeSequenceSource("middle", date: baseDate.addingTimeInterval(4))
        let top = makeSequenceSource("top", date: baseDate.addingTimeInterval(8))
        let joins = [
            makeAcceptedJoin(from: top.id, to: middle.id, translation: Point2D(x: 0, y: 40), overlapHeight: 60),
            makeAcceptedJoin(from: middle.id, to: bottom.id, translation: Point2D(x: 0, y: 40), overlapHeight: 60)
        ]

        let selection = AutomaticScreenshotSequenceSelector().select(
            sources: [middle, top, bottom],
            joins: joins
        )

        XCTAssertEqual(selection?.sources.map(\.filename), ["top", "middle", "bottom"])
        XCTAssertEqual(selection?.joinCount, 2)
        XCTAssertEqual(selection?.joins.map(\.fromSourceID), [top.id, middle.id])
    }

    func testAutomaticScreenshotSessionSelectorUsesNewestBoundedCompatibleSession() {
        let configuration = AutomaticScreenshotSelectionConfiguration(
            maximumCandidateCount: 3,
            metadataFetchLimit: 20,
            maximumTemporalGap: 60,
            maximumSessionDuration: 180,
            maximumRecentAge: 3_600
        )
        let selector = AutomaticScreenshotSessionSelector(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 10_000)
        let phoneSize = PixelSize(width: 430, height: 932)
        let tabletSize = PixelSize(width: 2_048, height: 2_732)
        let candidates = [
            AutomaticScreenshotCandidate(
                identifier: "old-1",
                captureDate: baseDate,
                pixelSize: phoneSize
            ),
            AutomaticScreenshotCandidate(
                identifier: "old-2",
                captureDate: baseDate.addingTimeInterval(20),
                pixelSize: phoneSize
            ),
            AutomaticScreenshotCandidate(
                identifier: "recent-1",
                captureDate: baseDate.addingTimeInterval(600),
                pixelSize: phoneSize
            ),
            AutomaticScreenshotCandidate(
                identifier: "recent-2",
                captureDate: baseDate.addingTimeInterval(620),
                pixelSize: phoneSize
            ),
            AutomaticScreenshotCandidate(
                identifier: "recent-3",
                captureDate: baseDate.addingTimeInterval(640),
                pixelSize: phoneSize
            ),
            AutomaticScreenshotCandidate(
                identifier: "recent-4",
                captureDate: baseDate.addingTimeInterval(660),
                pixelSize: phoneSize
            ),
            AutomaticScreenshotCandidate(
                identifier: "newest-isolated",
                captureDate: baseDate.addingTimeInterval(900),
                pixelSize: tabletSize
            )
        ]

        let selected = selector.newestEligibleSession(from: candidates)

        XCTAssertEqual(selected.map(\.identifier), ["recent-2", "recent-3", "recent-4"])
    }

    func testAutomaticScreenshotSessionSelectorDoesNotChainPastSessionDuration() {
        let configuration = AutomaticScreenshotSelectionConfiguration(
            maximumCandidateCount: 12,
            metadataFetchLimit: 20,
            maximumTemporalGap: 60,
            maximumSessionDuration: 100,
            maximumRecentAge: 3_600
        )
        let selector = AutomaticScreenshotSessionSelector(configuration: configuration)
        let baseDate = Date(timeIntervalSince1970: 20_000)
        let candidates = (0..<4).map { index in
            AutomaticScreenshotCandidate(
                identifier: "candidate-\(index)",
                captureDate: baseDate.addingTimeInterval(Double(index * 50)),
                pixelSize: PixelSize(width: 430, height: 932)
            )
        }

        let selected = selector.newestEligibleSession(from: candidates)

        XCTAssertEqual(selected.map(\.identifier), ["candidate-1", "candidate-2", "candidate-3"])
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
        XCTAssertGreaterThan(result.diagnostics.elapsedMilliseconds, 0)
    }

    func testVerticalRegistrationSupportsLandscapeSources() async throws {
        let width = 160
        let firstRows = variedRows(start: 0, count: 100)
        let secondRows = variedRows(start: 40, count: 100)
        let firstImage = try XCTUnwrap(makeTestImage(width: width, rows: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(width: width, rows: secondRows))
        let first = makeNormalizedImage(id: UUID(), image: firstImage, rows: firstRows)
        let second = makeNormalizedImage(id: UUID(), image: secondImage, rows: secondRows)

        let result = try await PairwiseRegistrar().register(from: first, to: second)

        XCTAssertTrue(result.confidence.isAccepted, "diagnostics=\(result.diagnostics)")
        XCTAssertLessThanOrEqual(abs(result.transform.ty - 40), 2)
        XCTAssertLessThan(abs(result.transform.tx), 2)
    }

    func testRegistrationConvertsBoundedMatchingTranslationToOutputPixels() async throws {
        let width = 16
        let firstRows = variedRows(start: 0, count: 100)
        let secondRows = variedRows(start: 40, count: 100)
        let firstImage = try XCTUnwrap(makeTestImage(width: width, rows: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(width: width, rows: secondRows))
        let outputSize = PixelSize(width: width * 2, height: 200)
        let first = makeNormalizedImage(
            id: UUID(),
            image: firstImage,
            rows: firstRows,
            workingPixelSize: outputSize
        )
        let second = makeNormalizedImage(
            id: UUID(),
            image: secondImage,
            rows: secondRows,
            workingPixelSize: outputSize
        )

        let result = try await PairwiseRegistrar().register(from: first, to: second)

        XCTAssertTrue(result.confidence.isAccepted, "diagnostics=\(result.diagnostics)")
        XCTAssertLessThanOrEqual(abs(result.transform.ty - 80), 4)
        XCTAssertEqual(result.diagnostics.translation.x, result.transform.tx)
        XCTAssertEqual(result.diagnostics.translation.y, result.transform.ty)
    }

    func testPrecomputedMappingReusesUnchangedDirectedJoin() async throws {
        let width = 16
        let firstRows = variedRows(start: 0, count: 100)
        let secondRows = variedRows(start: 40, count: 100)
        let thirdRows = variedRows(start: 80, count: 100)
        let images = try [firstRows, secondRows, thirdRows].map { rows in
            try XCTUnwrap(makeTestImage(width: width, rows: rows))
        }
        let urls = images.indices.map { index in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("continuo-reused-join-\(index)-\(UUID().uuidString).png")
        }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for (image, url) in zip(images, urls) {
            try writePNG(image, to: url)
        }

        let sources = urls.map { SourceImage(localURL: $0, filename: $0.lastPathComponent) }
        let reused = makeAcceptedJoin(
            from: sources[0].id,
            to: sources[1].id,
            translation: Point2D(x: 0, y: 40),
            overlapWidth: width,
            overlapHeight: 60
        )

        let joins = try await StitchEngine().precomputeJoins(
            for: sources,
            reusing: [reused]
        )

        XCTAssertEqual(joins.count, 2)
        XCTAssertEqual(joins[0].id, reused.id)
        XCTAssertEqual(joins[1].fromSourceID, sources[1].id)
        XCTAssertEqual(joins[1].toSourceID, sources[2].id)
    }

    func testEnginePrecomputesVerticalJoinsForLandscapeSources() async throws {
        let width = 160
        let firstImage = try XCTUnwrap(
            makeTestImage(width: width, rows: variedRows(start: 0, count: 100))
        )
        let secondImage = try XCTUnwrap(
            makeTestImage(width: width, rows: variedRows(start: 40, count: 100))
        )
        let urls = [
            FileManager.default.temporaryDirectory
                .appendingPathComponent("continuo-landscape-vertical-first-\(UUID().uuidString).png"),
            FileManager.default.temporaryDirectory
                .appendingPathComponent("continuo-landscape-vertical-second-\(UUID().uuidString).png")
        ]
        defer {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try writePNG(firstImage, to: urls[0])
        try writePNG(secondImage, to: urls[1])

        let sources = urls.map { SourceImage(localURL: $0, filename: $0.lastPathComponent) }
        let joins = try await StitchEngine(direction: .vertical).precomputeJoins(for: sources)

        XCTAssertEqual(joins.count, 1)
        XCTAssertTrue(joins[0].confidence.isAccepted, "diagnostics=\(joins[0].diagnostics)")
        XCTAssertLessThanOrEqual(abs(joins[0].transform.ty - 40), 3)
    }

    func testDirectionalAdapterSwapsMatchingGeometryForHorizontalStacking() throws {
        let image = try XCTUnwrap(makeTestImage(width: 12, rows: variedRows(start: 0, count: 7)))
        let normalized = makeNormalizedImage(
            id: UUID(),
            image: image,
            rows: variedRows(start: 0, count: 7),
            width: 12
        )

        let adapted = DirectionalImageAdapter.matchingImage(normalized, for: .horizontal)

        XCTAssertEqual(adapted.matchingImage.width, image.height)
        XCTAssertEqual(adapted.matchingImage.height, image.width)
        XCTAssertEqual(adapted.matchingRepresentation.width, normalized.matchingRepresentation.height)
        XCTAssertEqual(adapted.matchingRepresentation.height, normalized.matchingRepresentation.width)
        XCTAssertEqual(adapted.workingPixelSize, PixelSize(width: normalized.workingPixelSize.height, height: normalized.workingPixelSize.width))
    }

    func testEnginePrecomputesHorizontalJoinsForSideBySideSources() async throws {
        let width = 100
        let height = 16
        let shift = 40
        let globalColumns = variedRows(start: 0, count: width + shift)
        let firstValues = (0..<height).map { row in
            (0..<width).map { column in
                globalColumns[column] * 0.7 + Float((row * 11) % 13) / 40
            }
        }
        let secondValues = (0..<height).map { row in
            (0..<width).map { column in
                globalColumns[column + shift] * 0.7 + Float((row * 11) % 13) / 40
            }
        }
        let firstImage = try XCTUnwrap(makeTestImage(values: firstValues))
        let secondImage = try XCTUnwrap(makeTestImage(values: secondValues))
        let urls = [
            FileManager.default.temporaryDirectory
                .appendingPathComponent("continuo-horizontal-first-\(UUID().uuidString).png"),
            FileManager.default.temporaryDirectory
                .appendingPathComponent("continuo-horizontal-second-\(UUID().uuidString).png")
        ]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        try writePNG(firstImage, to: urls[0])
        try writePNG(secondImage, to: urls[1])

        let sources = urls.map { SourceImage(localURL: $0, filename: $0.lastPathComponent) }
        let joins = try await StitchEngine(direction: .horizontal).precomputeJoins(for: sources)

        XCTAssertEqual(joins.count, 1)
        XCTAssertTrue(joins[0].confidence.isAccepted, "diagnostics=\(joins[0].diagnostics)")
        XCTAssertLessThanOrEqual(abs(joins[0].transform.ty - Double(shift)), 5)
        XCTAssertLessThan(abs(joins[0].transform.tx), 5)

        let preview = try await StitchEngine(direction: .horizontal).stitch(
            sources: sources,
            precomputedJoins: joins
        )
        XCTAssertEqual(preview.pixelSize, PixelSize(width: width + shift, height: height))
        let outputRows = readRedRows(from: preview.image)
        XCTAssertGreaterThan(outputRows.first?.reduce(0, max) ?? 0, 0)
        XCTAssertGreaterThan(outputRows.last?.reduce(0, max) ?? 0, 0)
    }

    func testJoinDiagnosticsDecodesLegacyPayloadWithoutTiming() throws {
        let diagnostics = JoinDiagnostics(
            code: "registration.accepted",
            message: "High-confidence vertical join.",
            recoverySuggestion: "",
            similarityScore: 0.95,
            overlapSize: PixelSize(width: 16, height: 60),
            overlapPercentage: 0.6,
            translation: Point2D(x: 0, y: 40),
            crossAxisDrift: 0,
            residualError: 0.05,
            backend: .correlationFallback,
            ambiguousCandidates: false,
            candidateCount: 10,
            elapsedMilliseconds: 12.5
        )
        let encoded = try JSONEncoder().encode(diagnostics)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "elapsedMilliseconds")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(JoinDiagnostics.self, from: legacyData)
        XCTAssertEqual(decoded.elapsedMilliseconds, 0)
        XCTAssertEqual(decoded.similarityScore, diagnostics.similarityScore)
        XCTAssertEqual(decoded.translation, diagnostics.translation)
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

    func testRegistrationUsesBoundedSearchForLargerRepresentations() async throws {
        let width = 128
        let firstRows = detailedRows(start: 0, count: 512, width: width)
        let secondRows = renderedVariant(detailedRows(start: 160, count: 512, width: width))
        let firstImage = try XCTUnwrap(makeTestImage(values: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(values: secondRows))
        let first = makeNormalizedImage(id: UUID(), image: firstImage, values: firstRows)
        let second = makeNormalizedImage(id: UUID(), image: secondImage, values: secondRows)

        let configuration = RegistrationConfiguration(
            maximumSeedOffsets: 6,
            coarseDriftSamples: 13
        )
        let result = try await PairwiseRegistrar(configuration: configuration).register(from: first, to: second)

        XCTAssertLessThan(
            result.diagnostics.candidateCount,
            900,
            "The fallback search should stay bounded; diagnostics=\(result.diagnostics)"
        )
        XCTAssertLessThanOrEqual(
            abs(result.transform.ty - 160),
            12,
            "The bounded search should retain the correct vertical neighborhood; diagnostics=\(result.diagnostics)"
        )
    }

    func testRegistrationFindsLargeScrollWhenRowProfilePrefersRepeatedContent() async throws {
        let width = 64
        let firstRows = detailedRows(start: 0, count: 1_536, width: width)
        let secondRows = renderedVariant(detailedRows(start: 960, count: 1_536, width: width))
        let firstImage = try XCTUnwrap(makeTestImage(values: firstRows))
        let secondImage = try XCTUnwrap(makeTestImage(values: secondRows))
        let first = makeNormalizedImage(id: UUID(), image: firstImage, values: firstRows)
        let second = makeNormalizedImage(id: UUID(), image: secondImage, values: secondRows)

        let result = try await PairwiseRegistrar().register(from: first, to: second)

        XCTAssertTrue(result.confidence.isAccepted, "diagnostics=\(result.diagnostics)")
        XCTAssertLessThanOrEqual(
            abs(result.transform.ty - 960),
            12,
            "The full-range fallback scan should recover a large vertical displacement; diagnostics=\(result.diagnostics)"
        )
        XCTAssertGreaterThan(result.diagnostics.candidateCount, 0)
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
        let firstImage = try XCTUnwrap(makeExactRowImage(firstValues))
        let secondImage = try XCTUnwrap(makeExactRowImage(secondValues))
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
            image: try XCTUnwrap(makeExactRowImage(firstValues)),
            values: firstValues,
            width: 1
        )
        let second = makeNormalizedImage(
            id: secondID,
            image: try XCTUnwrap(makeExactRowImage(secondValues)),
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

    func testPixelCompositorPreservesPixelsOutsideTheExplicitSeam() throws {
        let firstValues: [[Float]] = [
            [0.10, 0.20],
            [0.30, 0.40],
            [0.50, 0.60],
            [0.70, 0.80]
        ]
        let secondValues: [[Float]] = [
            [0.55, 0.65],
            [0.75, 0.85],
            [0.90, 0.95],
            [0.15, 0.25]
        ]
        let first = try XCTUnwrap(makeTestImage(values: firstValues))
        let second = try XCTUnwrap(makeTestImage(values: secondValues))

        let output = try PixelCompositor().compose(
            images: [first, second],
            frames: [
                Rect2D(x: 0, y: 0, width: 2, height: 4),
                Rect2D(x: 0, y: 2, width: 2, height: 4)
            ],
            seamPositions: [0, 1]
        )

        XCTAssertEqual(output.width, 2)
        XCTAssertEqual(output.height, 6)
        XCTAssertEqual(readRedRows(from: output), [
            [25, 51],
            [76, 102],
            [127, 153],
            [185, 210],
            [229, 242],
            [38, 63]
        ])
    }

    func testPixelCompositorRequestsFullResolutionSourcesOnDemandInOrder() throws {
        let images = [
            try XCTUnwrap(makeExactRowImage([0.10, 0.20, 0.30, 0.40])),
            try XCTUnwrap(makeExactRowImage([0.30, 0.40, 0.50, 0.60]))
        ]
        var requestedIndices: [Int] = []

        let output = try PixelCompositor().compose(
            imageCount: images.count,
            frames: [
                Rect2D(x: 0, y: 0, width: 1, height: 4),
                Rect2D(x: 0, y: 2, width: 1, height: 4)
            ],
            seamPositions: [0, 1],
            imageProvider: { index in
                requestedIndices.append(index)
                return images[index]
            }
        )

        XCTAssertEqual(requestedIndices, [0, 1])
        XCTAssertEqual(output.height, 6)
    }

    func testPixelCompositorLeavesIdenticalOverlapByteForByteUnchanged() throws {
        let firstValues: [[Float]] = [
            [0.10],
            [0.20],
            [0.30],
            [0.40]
        ]
        let secondValues: [[Float]] = [
            [0.30],
            [0.40],
            [0.50],
            [0.60]
        ]

        let output = try PixelCompositor().compose(
            images: [
                try XCTUnwrap(makeExactRowImage(firstValues.map { $0[0] })),
                try XCTUnwrap(makeExactRowImage(secondValues.map { $0[0] }))
            ],
            frames: [
                Rect2D(x: 0, y: 0, width: 1, height: 4),
                Rect2D(x: 0, y: 2, width: 1, height: 4)
            ],
            seamPositions: [0, 1]
        )

        XCTAssertEqual(readRedRows(from: output), [[25], [51], [76], [102], [127], [153]])
    }

    func testPixelCompositorUsesTwoExplicitRowsForLargeDisagreements() throws {
        let first = try XCTUnwrap(makeTestImage(values: (0..<12).map { _ in [Float(0.10)] }))
        let second = try XCTUnwrap(makeTestImage(values: (0..<12).map { _ in [Float(0.90)] }))

        let output = try PixelCompositor().compose(
            images: [first, second],
            frames: [
                Rect2D(x: 0, y: 0, width: 1, height: 12),
                Rect2D(x: 0, y: 4, width: 1, height: 12)
            ],
            seamPositions: [0, 6]
        )
        let rows = readRedRows(from: output).map { $0[0] }

        XCTAssertEqual(Array(rows[0..<9]), Array(repeating: 25, count: 9))
        XCTAssertGreaterThan(rows[9], 25)
        XCTAssertLessThan(rows[9], 230)
        XCTAssertGreaterThan(rows[10], rows[9])
        XCTAssertEqual(Array(rows[11..<16]), Array(repeating: 229, count: 5))
    }

    func testPixelCompositorSurvivesPNGEncodeAndDecodeWithoutChangingPixels() throws {
        let image = try XCTUnwrap(makeTestImage(values: [[0.05, 0.25], [0.50, 0.75]]))
        let output = try PixelCompositor().compose(
            images: [image],
            frames: [Rect2D(x: 0, y: 0, width: 2, height: 2)],
            seamPositions: [0]
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("continuo-compositor-roundtrip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(output, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(readRedRows(from: decoded), readRedRows(from: output))
    }

    func testPixelCompositorHandlesPaddedRowsAndNonRGBAInputs() throws {
        let values: [[Float]] = [
            [0.10, 0.20],
            [0.30, 0.40]
        ]
        let padded = try XCTUnwrap(makePaddedImage(values: values))
        let grayscale = try XCTUnwrap(makeGrayscaleImage(values: values))

        let paddedOutput = try PixelCompositor().compose(
            images: [padded],
            frames: [Rect2D(x: 0, y: 0, width: 2, height: 2)],
            seamPositions: [0]
        )
        let grayscaleOutput = try PixelCompositor().compose(
            images: [grayscale],
            frames: [Rect2D(x: 0, y: 0, width: 2, height: 2)],
            seamPositions: [0]
        )

        XCTAssertEqual(readRedRows(from: paddedOutput), [[25, 51], [76, 102]])
        XCTAssertEqual(readRedRows(from: grayscaleOutput), [[25, 51], [76, 102]])
    }

    func testRendererCompositesThreeScreensInOrder() throws {
        let firstValues = (0..<4).map { Float($0 + 1) / 10 }
        let secondValues = (2..<6).map { Float($0 + 1) / 10 }
        let thirdValues = (4..<8).map { Float($0 + 1) / 10 }
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let first = makeNormalizedImage(
            id: firstID,
            image: try XCTUnwrap(makeExactRowImage(firstValues)),
            values: firstValues,
            width: 1
        )
        let second = makeNormalizedImage(
            id: secondID,
            image: try XCTUnwrap(makeExactRowImage(secondValues)),
            values: secondValues,
            width: 1
        )
        let third = makeNormalizedImage(
            id: thirdID,
            image: try XCTUnwrap(makeExactRowImage(thirdValues)),
            values: thirdValues,
            width: 1
        )

        let joins = [
            makeAcceptedJoin(from: firstID, to: secondID, translation: Point2D(x: 0, y: 2), overlapHeight: 2),
            makeAcceptedJoin(from: secondID, to: thirdID, translation: Point2D(x: 0, y: 2), overlapHeight: 2)
        ]
        let preview = try PreviewRenderer().render(sources: [first, second, third], joins: joins)

        XCTAssertEqual(preview.pixelSize, PixelSize(width: 1, height: 8))
        XCTAssertEqual(readRedRows(from: preview.image).map { $0[0] }, [25, 51, 76, 102, 127, 153, 178, 204])
    }

    func testRendererAlignsNegativeOriginAndSmallCrossAxisDriftToPixels() throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstValues: [[Float]] = [
            [0.10, 0.20],
            [0.30, 0.40],
            [0.50, 0.60],
            [0.70, 0.80]
        ]
        let secondValues: [[Float]] = [
            [0.30, 0.40],
            [0.50, 0.60],
            [0.70, 0.80],
            [0.90, 1.00]
        ]
        let first = makeNormalizedImage(
            id: firstID,
            image: try XCTUnwrap(makeTestImage(values: firstValues)),
            values: firstValues
        )
        let second = makeNormalizedImage(
            id: secondID,
            image: try XCTUnwrap(makeTestImage(values: secondValues)),
            values: secondValues
        )
        let join = makeAcceptedJoin(
            from: firstID,
            to: secondID,
            translation: Point2D(x: -1, y: 2),
            overlapWidth: 1,
            overlapHeight: 2
        )

        let preview = try PreviewRenderer().render(sources: [first, second], joins: [join])

        XCTAssertEqual(preview.pixelSize, PixelSize(width: 3, height: 6))
        XCTAssertEqual(preview.placements.map { $0.frame }, [
            Rect2D(x: 1, y: 0, width: 2, height: 4),
            Rect2D(x: 0, y: 2, width: 2, height: 4)
        ])
    }

    func testPixelCompositorHonorsCancellation() async throws {
        let image = try XCTUnwrap(makeTestImage(values: (0..<64).map { _ in [Float(0.5)] }))
        let task = Task { () throws -> CGImage in
            await Task.yield()
            return try PixelCompositor().compose(
                images: [image],
                frames: [Rect2D(x: 0, y: 0, width: 1, height: 64)],
                seamPositions: [0]
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled compositor task should not produce an image.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error).")
        }
    }

    @MainActor
    func testViewModelRemainsReadyAfterFinalProgressCallback() async throws {
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-view-model-first-\(UUID().uuidString).png")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-view-model-second-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let firstRows = variedRows(start: 0, count: 100)
        let secondRows = variedRows(start: 40, count: 100)
        try writePNG(try XCTUnwrap(makeTestImage(width: 16, rows: firstRows)), to: firstURL)
        try writePNG(try XCTUnwrap(makeTestImage(width: 16, rows: secondRows)), to: secondURL)

        let viewModel = ContinuoViewModel()
        viewModel.importFiles([firstURL, secondURL])
        XCTAssertEqual(viewModel.sources.count, 2)
        viewModel.stitch()

        var reachedReady = false
        for _ in 0..<250 {
            if viewModel.state == .ready {
                reachedReady = true
                break
            }
            if case .failed = viewModel.state {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(reachedReady, "The view model did not publish a ready result: \(viewModel.state)")
        XCTAssertNotNil(viewModel.preview)

        // Allow any progress delivery tasks queued immediately before the
        // engine returned to execute. They must not revert the ready state.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertNotNil(viewModel.preview)
    }

    @MainActor
    func testResetArchivesSavedStitchAndClearsActiveWorkflow() async throws {
        let historyRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-view-model-history-\(UUID().uuidString)", isDirectory: true)
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-reset-first-\(UUID().uuidString).png")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-reset-second-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: historyRootURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let firstRows = variedRows(start: 0, count: 100)
        let secondRows = variedRows(start: 40, count: 100)
        try writePNG(try XCTUnwrap(makeTestImage(width: 16, rows: firstRows)), to: firstURL)
        try writePNG(try XCTUnwrap(makeTestImage(width: 16, rows: secondRows)), to: secondURL)

        let viewModel = ContinuoViewModel(
            historyImageStore: HistoryImageStore(directoryURL: historyRootURL)
        )
        viewModel.importFiles([firstURL, secondURL])
        viewModel.stitch()

        for _ in 0..<250 {
            if viewModel.state == .ready || viewModel.state == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let preview = try XCTUnwrap(viewModel.preview)
        viewModel.markSaveCompleted()
        XCTAssertTrue(viewModel.isCurrentPreviewSaved)

        await viewModel.resetActiveWorkflowAndWait()

        XCTAssertTrue(viewModel.sources.isEmpty)
        XCTAssertNil(viewModel.preview)
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertFalse(viewModel.isCurrentPreviewSaved)
        XCTAssertEqual(viewModel.completedStitches.count, 1)
        XCTAssertEqual(viewModel.completedStitches[0].pixelSize, preview.pixelSize)
        XCTAssertEqual(viewModel.completedStitches[0].thumbnail.width, preview.image.width)
        XCTAssertEqual(viewModel.completedStitches[0].thumbnail.height, preview.image.height)
        let archivedURL = try XCTUnwrap(viewModel.completedStitches[0].fullResolutionURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedURL.path))
        XCTAssertEqual(viewModel.completedStitches[0].sources.map(\.originalSourceURL), [firstURL, secondURL])
        XCTAssertFalse(viewModel.completedStitches[0].sourceImagesDeleted)

        viewModel.consumeHistoryAsset(id: viewModel.completedStitches[0].id)
        XCTAssertNil(viewModel.completedStitches[0].fullResolutionURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedURL.path))
    }

    func testHistoryImageStorePersistsFullResolutionAndBoundsThumbnail() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let image = try XCTUnwrap(makeTestImage(width: 12, rows: Array(repeating: 0.4, count: 2_400)))
        let store = HistoryImageStore(directoryURL: rootURL)
        let stitchID = UUID()
        let asset = try store.archive(
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            id: stitchID
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.fullResolutionURL.path))
        XCTAssertTrue(asset.fullResolutionURL.path.contains("/Images/"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: rootURL
                    .appendingPathComponent("Thumbnails", isDirectory: true)
                    .appendingPathComponent("\(stitchID.uuidString).thumbnail.png")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: rootURL
                    .appendingPathComponent("Metadata", isDirectory: true)
                    .appendingPathComponent(stitchID.uuidString)
                    .appendingPathExtension("json")
                    .path
            )
        )
        XCTAssertEqual(asset.pixelSize, PixelSize(width: image.width, height: image.height))
        XCTAssertLessThanOrEqual(max(asset.thumbnail.width, asset.thumbnail.height), 1_600)
        XCTAssertEqual(asset.fullResolutionURL.pathExtension, "png")

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].pixelSize, asset.pixelSize)
        XCTAssertEqual(loaded[0].fullResolutionURL, asset.fullResolutionURL)
        XCTAssertLessThanOrEqual(max(loaded[0].thumbnail.width, loaded[0].thumbnail.height), 1_600)

        var consumedStitch = loaded[0]
        store.remove(asset.fullResolutionURL)
        consumedStitch.fullResolutionURL = nil
        try store.update(consumedStitch)

        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.fullResolutionURL.path))
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertNil(reloaded[0].fullResolutionURL)
        XCTAssertEqual(reloaded[0].thumbnail.width, loaded[0].thumbnail.width)
    }

    func testHistoryImageStoreDeletesEveryHistoryArtifact() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let image = try XCTUnwrap(makeTestImage(width: 8, rows: [0.1, 0.3, 0.6, 0.9]))
        let store = HistoryImageStore(directoryURL: rootURL)
        let stitchID = UUID()
        let asset = try store.archive(
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            id: stitchID
        )
        let thumbnailURL = rootURL
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("\(stitchID.uuidString).thumbnail.png")
        let metadataURL = rootURL
            .appendingPathComponent("Metadata", isDirectory: true)
            .appendingPathComponent(stitchID.uuidString)
            .appendingPathExtension("json")

        try store.deleteHistory(id: stitchID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.fullResolutionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testHistoryImageStoreMovesFilesBetweenLocations() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-move-source-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-move-destination-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let image = try XCTUnwrap(makeTestImage(width: 8, rows: [0.1, 0.3, 0.6, 0.9]))
        let sourceStore = HistoryImageStore(directoryURL: sourceURL)
        let destinationStore = HistoryImageStore(directoryURL: destinationURL)
        let asset = try sourceStore.archive(
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            id: UUID()
        )

        let progress = LockedValues<HistoryTransferProgress>()
        let result = try sourceStore.migrateHistory(to: destinationStore) {
            progress.append($0)
        }
        let progressValues = progress.values
        let loadedDestination = try destinationStore.load()
        XCTAssertEqual(loadedDestination.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.fullResolutionURL.path))
        XCTAssertTrue(loadedDestination[0].fullResolutionURL?.path.contains("/Images/") == true)
        XCTAssertEqual(result.copiedFileCount, 3)
        XCTAssertTrue(progressValues.contains { $0.phase == .preparing })
        XCTAssertTrue(progressValues.contains { $0.phase == .copying && $0.completed == 3 })

        try sourceStore.removeStoredFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.fullResolutionURL.path))
        XCTAssertTrue(try sourceStore.load().isEmpty)
        XCTAssertEqual(try destinationStore.load().count, 1)
    }

    func testHistoryImageStoreMigratesLegacyFlatFilesIntoSeparateFolders() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let image = try XCTUnwrap(makeTestImage(width: 8, rows: [0.1, 0.3, 0.6, 0.9]))
        let store = HistoryImageStore(directoryURL: rootURL)
        let stitchID = UUID()
        let asset = try store.archive(
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            id: stitchID
        )

        let legacyFiles = [
            asset.fullResolutionURL,
            rootURL.appendingPathComponent("Thumbnails", isDirectory: true)
                .appendingPathComponent("\(stitchID.uuidString).thumbnail.png"),
            rootURL.appendingPathComponent("Metadata", isDirectory: true)
                .appendingPathComponent(stitchID.uuidString)
                .appendingPathExtension("json")
        ]
        for file in legacyFiles {
            try FileManager.default.moveItem(at: file, to: rootURL.appendingPathComponent(file.lastPathComponent))
        }

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(loaded[0].fullResolutionURL?.path.contains("/Images/") == true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: rootURL
                    .appendingPathComponent("Thumbnails", isDirectory: true)
                    .appendingPathComponent("\(stitchID.uuidString).thumbnail.png")
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: rootURL
                    .appendingPathComponent("Metadata", isDirectory: true)
                    .appendingPathComponent(stitchID.uuidString)
                    .appendingPathExtension("json")
                    .path
            )
        )
    }

    func testLocalHistoryAssetIsImmediatelyReadyForExport() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let image = try XCTUnwrap(makeTestImage(width: 8, rows: [0.1, 0.3, 0.6, 0.9]))
        let store = HistoryImageStore(directoryURL: rootURL)
        let asset = try store.archive(
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            id: UUID()
        )

        try await store.prepareForExport(asset.fullResolutionURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.fullResolutionURL.path))
    }

    @MainActor
    func testStartingNewImportsRetainsEverySavedStitchInHistory() async throws {
        let historyRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-multiple-history-\(UUID().uuidString)", isDirectory: true)
        let firstImportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-next-first-\(UUID().uuidString).png")
        let secondImportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-next-second-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: historyRootURL)
            try? FileManager.default.removeItem(at: firstImportURL)
            try? FileManager.default.removeItem(at: secondImportURL)
        }

        let image = try XCTUnwrap(makeTestImage(width: 4, rows: [0.1, 0.3, 0.6, 0.9]))
        try writePNG(image, to: firstImportURL)
        try writePNG(image, to: secondImportURL)
        let store = HistoryImageStore(directoryURL: historyRootURL)
        let viewModel = ContinuoViewModel(historyImageStore: store)

        viewModel.preview = StitchPreview(
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            placements: [],
            joins: []
        )
        viewModel.markSaveCompleted()
        viewModel.importFiles([firstImportURL])

        for _ in 0..<200 where viewModel.completedStitches.count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.completedStitches.count, 1)
        XCTAssertEqual(viewModel.sources.count, 1)

        viewModel.preview = StitchPreview(
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            placements: [],
            joins: []
        )
        viewModel.markSaveCompleted()
        viewModel.importFiles([secondImportURL])

        for _ in 0..<200 where viewModel.completedStitches.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.completedStitches.count, 2)
        XCTAssertEqual(try store.load().count, 2)
        viewModel.clearSources()
    }

    @MainActor
    func testResetDoesNotArchiveUnsavedStitch() async throws {
        let historyRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-unsaved-history-\(UUID().uuidString)", isDirectory: true)
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-unsaved-reset-first-\(UUID().uuidString).png")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-unsaved-reset-second-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: historyRootURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        try writePNG(
            try XCTUnwrap(makeTestImage(width: 16, rows: variedRows(start: 0, count: 100))),
            to: firstURL
        )
        try writePNG(
            try XCTUnwrap(makeTestImage(width: 16, rows: variedRows(start: 40, count: 100))),
            to: secondURL
        )

        let viewModel = ContinuoViewModel(
            historyImageStore: HistoryImageStore(directoryURL: historyRootURL)
        )
        viewModel.importFiles([firstURL, secondURL])
        viewModel.stitch()

        for _ in 0..<250 {
            if viewModel.state == .ready || viewModel.state == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNotNil(viewModel.preview)
        XCTAssertFalse(viewModel.isCurrentPreviewSaved)

        await viewModel.resetActiveWorkflowAndWait()

        XCTAssertTrue(viewModel.completedStitches.isEmpty)
        XCTAssertTrue(viewModel.sources.isEmpty)
        XCTAssertNil(viewModel.preview)
    }

    @MainActor
    func testResetArchivesSourceDeletedStateForHistoryActions() async throws {
        let image = try XCTUnwrap(makeTestImage(width: 2, rows: [0.2, 0.8]))
        let historyRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-deleted-history-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-deleted-state-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: historyRootURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let source = SourceImage(
            localURL: sourceURL,
            sourceOrigin: .files,
            originalSourceURL: sourceURL,
            filename: sourceURL.lastPathComponent
        )
        let preview = StitchPreview(
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            placements: [],
            joins: []
        )
        let viewModel = ContinuoViewModel(
            historyImageStore: HistoryImageStore(directoryURL: historyRootURL)
        )
        viewModel.sources = [source]
        viewModel.preview = preview
        viewModel.markSaveCompleted()
        viewModel.sourceCleanupState = .deleted

        await viewModel.resetActiveWorkflowAndWait()

        XCTAssertEqual(viewModel.completedStitches.count, 1)
        XCTAssertTrue(viewModel.completedStitches[0].sourceImagesDeleted)
        XCTAssertEqual(viewModel.completedStitches[0].sources, [source])
    }

    @MainActor
    func testHistorySourceDeletionOnlyDeletesTheRequestedStitchSources() async throws {
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-delete-first-\(UUID().uuidString).png")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-delete-second-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let image = try XCTUnwrap(makeTestImage(width: 2, rows: [0.2, 0.8]))
        try writePNG(image, to: firstURL)
        try writePNG(image, to: secondURL)

        let firstSource = SourceImage(
            localURL: firstURL,
            sourceOrigin: .files,
            originalSourceURL: firstURL,
            filename: firstURL.lastPathComponent
        )
        let secondSource = SourceImage(
            localURL: secondURL,
            sourceOrigin: .files,
            originalSourceURL: secondURL,
            filename: secondURL.lastPathComponent
        )
        let firstStitch = CompletedStitch(
            thumbnail: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            sources: [firstSource]
        )
        let secondStitch = CompletedStitch(
            thumbnail: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            sources: [secondSource]
        )

        let viewModel = ContinuoViewModel()
        viewModel.completedStitches = [firstStitch, secondStitch]

        await viewModel.deleteCompletedStitchSources(id: firstStitch.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(viewModel.completedStitches[0].sourceImagesDeleted)
        XCTAssertFalse(viewModel.completedStitches[1].sourceImagesDeleted)
        XCTAssertNil(viewModel.completedStitches[0].sourceDeletionError)
        XCTAssertNil(viewModel.completedStitches[1].sourceDeletionError)
    }

    @MainActor
    func testHistorySourceDeletionKeepsFailureOnTheRequestedStitch() async throws {
        let validURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-history-delete-valid-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: validURL) }

        let image = try XCTUnwrap(makeTestImage(width: 2, rows: [0.2, 0.8]))
        try writePNG(image, to: validURL)

        let validSource = SourceImage(
            localURL: validURL,
            sourceOrigin: .files,
            originalSourceURL: validURL,
            filename: validURL.lastPathComponent
        )
        let missingSource = SourceImage(
            localURL: validURL,
            sourceOrigin: .files,
            originalSourceURL: validURL.appendingPathExtension("missing"),
            filename: "missing.png"
        )
        let validStitch = CompletedStitch(
            thumbnail: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            sources: [validSource]
        )
        let failingStitch = CompletedStitch(
            thumbnail: image,
            pixelSize: PixelSize(width: image.width, height: image.height),
            sources: [missingSource]
        )

        let viewModel = ContinuoViewModel()
        viewModel.completedStitches = [validStitch, failingStitch]

        await viewModel.deleteCompletedStitchSources(id: failingStitch.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: validURL.path))
        XCTAssertFalse(viewModel.completedStitches[0].sourceImagesDeleted)
        XCTAssertFalse(viewModel.completedStitches[1].sourceImagesDeleted)
        XCTAssertNotNil(viewModel.completedStitches[1].sourceDeletionError)
        XCTAssertNil(viewModel.completedStitches[0].sourceDeletionError)
    }

    @MainActor
    func testClearingSourcesRemovesOnlyContinuoWorkingCopy() throws {
        let originalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-cleanup-original-\(UUID().uuidString).png")
        let workingCopyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuo-cleanup-working-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: workingCopyURL)
        }

        let image = try XCTUnwrap(makeTestImage(width: 2, rows: [0.2, 0.8]))
        try writePNG(image, to: originalURL)
        try FileManager.default.copyItem(at: originalURL, to: workingCopyURL)

        let source = SourceImage(
            localURL: workingCopyURL,
            sourceOrigin: .files,
            originalSourceURL: originalURL,
            filename: originalURL.lastPathComponent
        )
        let viewModel = ContinuoViewModel()
        viewModel.sources = [source]

        viewModel.clearSources()

        XCTAssertFalse(FileManager.default.fileExists(atPath: workingCopyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
    }

    private func makeNormalizedImage(
        id: UUID,
        image: CGImage,
        rows: [Float],
        width: Int = 16,
        workingPixelSize: PixelSize? = nil
    ) -> NormalizedImage {
        let values = rows.flatMap { row in
            (0..<width).map { column in
                let columnTexture = Float((column * 37 + 7) % 17) / 16.0 * 0.45
                return (row * 0.5) + columnTexture
            }
        }
        return makeNormalizedImage(
            id: id,
            image: image,
            values: values,
            width: width,
            workingPixelSize: workingPixelSize
        )
    }

    private func makeSequenceSource(_ filename: String, date: Date) -> SourceImage {
        SourceImage(
            localURL: URL(fileURLWithPath: "/tmp/\(filename).png"),
            pixelSize: PixelSize(width: 430, height: 932),
            captureDate: date,
            filename: filename
        )
    }

    private func makeNormalizedImage(id: UUID, image: CGImage, values: [[Float]]) -> NormalizedImage {
        makeNormalizedImage(id: id, image: image, values: values.flatMap { $0 }, width: values.first?.count ?? 0)
    }

    private func makeNormalizedImage(
        id: UUID,
        image: CGImage,
        values: [Float],
        width: Int,
        workingPixelSize: PixelSize? = nil
    ) -> NormalizedImage {
        let height = max(1, values.count / max(1, width))
        let mean = values.reduce(0, +) / Float(max(1, values.count))
        let centered = values.map { $0 - mean }
        let source = SourceImage(id: id, localURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).png"), filename: id.uuidString)
        return NormalizedImage(
            source: source,
            image: image,
            matchingRepresentation: MatchingRepresentation(width: width, height: height, grayscale: centered),
            originalPixelSize: workingPixelSize ?? PixelSize(width: width, height: height),
            workingPixelSize: workingPixelSize ?? PixelSize(width: width, height: height)
        )
    }

    private func makeAcceptedJoin(
        from: UUID,
        to: UUID,
        translation: Point2D,
        overlapWidth: Int = 1,
        overlapHeight: Int
    ) -> JoinResult {
        let diagnostics = JoinDiagnostics(
            code: "registration.accepted",
            message: "High-confidence vertical join.",
            recoverySuggestion: "",
            similarityScore: 1,
            overlapSize: PixelSize(width: overlapWidth, height: overlapHeight),
            overlapPercentage: 0.5,
            translation: translation,
            crossAxisDrift: abs(translation.x),
            residualError: 0,
            backend: .correlationFallback,
            ambiguousCandidates: false,
            candidateCount: 1
        )
        return JoinResult(
            fromSourceID: from,
            toSourceID: to,
            transform: AffineTransformData(translation: translation),
            overlapRect: Rect2D(
                x: translation.x,
                y: translation.y,
                width: Double(overlapWidth),
                height: Double(overlapHeight)
            ),
            seam: SeamDefinition(axis: .horizontal, position: Double(overlapHeight / 2)),
            confidence: .high,
            diagnostics: diagnostics
        )
    }

    private func readRedRows(from image: CGImage) -> [[UInt8]] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        return (0..<image.height).map { y in
            (0..<image.width).map { x in
                data[(y * image.bytesPerRow) + (x * 4)]
            }
        }
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

    private func makeExactRowImage(_ rows: [Float]) -> CGImage? {
        makeTestImage(values: rows.map { [$0] })
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

    private func makePaddedImage(values: [[Float]]) -> CGImage? {
        let width = values.first?.count ?? 0
        let height = values.count
        let bytesPerRow = (width * 4) + 8
        var bytes = [UInt8](repeating: 0xA5, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(max(0, min(255, Int(values[y][x] * 255))))
                let offset = (y * bytesPerRow) + (x * 4)
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
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func makeGrayscaleImage(values: [[Float]]) -> CGImage? {
        let width = values.first?.count ?? 0
        let height = values.count
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[(y * width) + x] = UInt8(max(0, min(255, Int(values[y][x] * 255))))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
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

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
