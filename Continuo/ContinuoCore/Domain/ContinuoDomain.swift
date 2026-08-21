import CoreGraphics
import Foundation

public struct PixelSize: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }

    public var area: Int {
        width * height
    }
}

public struct Point2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

public struct Rect2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct AffineTransformData: Codable, Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public init(translation: Point2D) {
        self.init(tx: translation.x, ty: translation.y)
    }

    public init(_ transform: CGAffineTransform) {
        self.init(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: transform.tx, ty: transform.ty)
    }

    public var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

public enum ImageOrientation: String, Codable, Equatable, Sendable {
    case up
    case upMirrored
    case down
    case downMirrored
    case leftMirrored
    case right
    case rightMirrored
    case left
}

public enum SourceOrigin: String, Codable, Equatable, Hashable, Sendable {
    case photos
    case files
    case unknown
}

public struct SourceImage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var localURL: URL
    public var sourceIdentifier: String?
    public var sourceOrigin: SourceOrigin
    public var originalSourceURL: URL?
    public var securityScopedBookmarkData: Data?
    public var pixelSize: PixelSize
    public var orientation: ImageOrientation
    public var captureDate: Date?
    public var filename: String?
    public var position: Point2D?
    public var excluded: Bool

    public init(
        id: UUID = UUID(),
        localURL: URL,
        sourceIdentifier: String? = nil,
        sourceOrigin: SourceOrigin = .unknown,
        originalSourceURL: URL? = nil,
        securityScopedBookmarkData: Data? = nil,
        pixelSize: PixelSize = PixelSize(width: 0, height: 0),
        orientation: ImageOrientation = .up,
        captureDate: Date? = nil,
        filename: String? = nil,
        position: Point2D? = nil,
        excluded: Bool = false
    ) {
        self.id = id
        self.localURL = localURL
        self.sourceIdentifier = sourceIdentifier
        self.sourceOrigin = sourceOrigin
        self.originalSourceURL = originalSourceURL
        self.securityScopedBookmarkData = securityScopedBookmarkData
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.captureDate = captureDate
        self.filename = filename
        self.position = position
        self.excluded = excluded
    }
}

public enum CanvasLayout: String, Codable, Sendable {
    case vertical
    case horizontal
    case freeform
}

public enum StitchDirection: String, Codable, Sendable {
    case vertical
    case horizontal
}

public enum ConfidenceLevel: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
    case rejected

    public var isAccepted: Bool {
        self == .high || self == .medium
    }
}

public enum RegistrationBackend: String, Codable, Sendable {
    case vision
    case rowProfile
    case correlationFallback
}

public enum JoinFailureReason: String, Codable, Sendable {
    case noMatchFound
    case insufficientOverlap
    case excessiveCrossAxisDrift
    case lowVisualAgreement
    case ambiguousMatch
    case unsupportedDirection
}

public struct JoinDiagnostics: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var recoverySuggestion: String
    public var similarityScore: Double
    public var overlapSize: PixelSize
    public var overlapPercentage: Double
    public var translation: Point2D
    public var crossAxisDrift: Double
    public var residualError: Double
    public var backend: RegistrationBackend
    public var ambiguousCandidates: Bool
    public var candidateCount: Int
    /// Monotonic wall-clock duration for this pairwise registration.
    /// This is diagnostic only and is not used to make acceptance decisions.
    public var elapsedMilliseconds: Double
    public var failureReason: JoinFailureReason?

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case recoverySuggestion
        case similarityScore
        case overlapSize
        case overlapPercentage
        case translation
        case crossAxisDrift
        case residualError
        case backend
        case ambiguousCandidates
        case candidateCount
        case elapsedMilliseconds
        case failureReason
    }

    public init(
        code: String,
        message: String,
        recoverySuggestion: String,
        similarityScore: Double,
        overlapSize: PixelSize,
        overlapPercentage: Double,
        translation: Point2D,
        crossAxisDrift: Double,
        residualError: Double,
        backend: RegistrationBackend,
        ambiguousCandidates: Bool,
        candidateCount: Int,
        elapsedMilliseconds: Double = 0,
        failureReason: JoinFailureReason? = nil
    ) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.similarityScore = similarityScore
        self.overlapSize = overlapSize
        self.overlapPercentage = overlapPercentage
        self.translation = translation
        self.crossAxisDrift = crossAxisDrift
        self.residualError = residualError
        self.backend = backend
        self.ambiguousCandidates = ambiguousCandidates
        self.candidateCount = candidateCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.failureReason = failureReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(String.self, forKey: .code)
        self.message = try container.decode(String.self, forKey: .message)
        self.recoverySuggestion = try container.decode(String.self, forKey: .recoverySuggestion)
        self.similarityScore = try container.decode(Double.self, forKey: .similarityScore)
        self.overlapSize = try container.decode(PixelSize.self, forKey: .overlapSize)
        self.overlapPercentage = try container.decode(Double.self, forKey: .overlapPercentage)
        self.translation = try container.decode(Point2D.self, forKey: .translation)
        self.crossAxisDrift = try container.decode(Double.self, forKey: .crossAxisDrift)
        self.residualError = try container.decode(Double.self, forKey: .residualError)
        self.backend = try container.decode(RegistrationBackend.self, forKey: .backend)
        self.ambiguousCandidates = try container.decode(Bool.self, forKey: .ambiguousCandidates)
        self.candidateCount = try container.decode(Int.self, forKey: .candidateCount)
        self.elapsedMilliseconds = try container.decodeIfPresent(Double.self, forKey: .elapsedMilliseconds) ?? 0
        self.failureReason = try container.decodeIfPresent(JoinFailureReason.self, forKey: .failureReason)
    }
}

public struct SeamDefinition: Codable, Equatable, Sendable {
    public enum Axis: String, Codable, Sendable {
        case horizontal
        case vertical
    }

    public var axis: Axis
    public var position: Double
    public var sourceCoordinate: Bool

    public init(axis: Axis, position: Double, sourceCoordinate: Bool = true) {
        self.axis = axis
        self.position = position
        self.sourceCoordinate = sourceCoordinate
    }
}

public struct JoinResult: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let fromSourceID: UUID
    public let toSourceID: UUID
    public var transform: AffineTransformData
    public var overlapRect: Rect2D
    public var seam: SeamDefinition
    public var confidence: ConfidenceLevel
    public var diagnostics: JoinDiagnostics

    public init(
        id: UUID = UUID(),
        fromSourceID: UUID,
        toSourceID: UUID,
        transform: AffineTransformData,
        overlapRect: Rect2D,
        seam: SeamDefinition,
        confidence: ConfidenceLevel,
        diagnostics: JoinDiagnostics
    ) {
        self.id = id
        self.fromSourceID = fromSourceID
        self.toSourceID = toSourceID
        self.transform = transform
        self.overlapRect = overlapRect
        self.seam = seam
        self.confidence = confidence
        self.diagnostics = diagnostics
    }
}

public struct ExportSettings: Codable, Equatable, Sendable {
    public var maximumPixelCount: Int
    public var maximumWidth: Int
    public var maximumHeight: Int

    public init(maximumPixelCount: Int = 40_000_000, maximumWidth: Int = 16_000, maximumHeight: Int = 40_000) {
        self.maximumPixelCount = maximumPixelCount
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
    }
}

public struct StitchProject: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sources: [SourceImage]
    public var layout: CanvasLayout
    public var joins: [JoinResult]
    public var exportSettings: ExportSettings

    public init(
        id: UUID = UUID(),
        name: String,
        sources: [SourceImage],
        layout: CanvasLayout = .vertical,
        joins: [JoinResult] = [],
        exportSettings: ExportSettings = ExportSettings(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sources = sources
        self.layout = layout
        self.joins = joins
        self.exportSettings = exportSettings
    }
}

public struct StitchProgress: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case importing
        case normalizing
        case registering
        case rendering
        case complete
    }

    public var stage: Stage
    public var completed: Int
    public var total: Int
    public var message: String

    public init(stage: Stage, completed: Int, total: Int, message: String) {
        self.stage = stage
        self.completed = completed
        self.total = total
        self.message = message
    }

    /// A weighted estimate across the actual pipeline stages. This keeps the
    /// UI progress moving forward instead of restarting at every stage.
    public var overallFraction: Double {
        let withinStage = min(1, max(0, Double(completed) / Double(max(1, total))))
        switch stage {
        case .importing:
            return withinStage * 0.20
        case .normalizing:
            return 0.20 + (withinStage * 0.20)
        case .registering:
            return 0.40 + (withinStage * 0.46)
        case .rendering:
            return 0.86 + (withinStage * 0.12)
        case .complete:
            return 1
        }
    }

    public var stageTitle: String {
        switch stage {
        case .importing: "Importing"
        case .normalizing: "Preparing full-resolution images"
        case .registering: "Finding screenshot joins"
        case .rendering: "Rendering halo output"
        case .complete: "Complete"
        }
    }
}

public struct SourcePlacement: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var frame: Rect2D

    public init(sourceID: UUID, frame: Rect2D) {
        self.sourceID = sourceID
        self.frame = frame
    }
}

public struct StitchPreview: @unchecked Sendable {
    public let image: CGImage
    public let pixelSize: PixelSize
    public let placements: [SourcePlacement]
    public let joins: [JoinResult]

    public init(image: CGImage, pixelSize: PixelSize, placements: [SourcePlacement], joins: [JoinResult]) {
        self.image = image
        self.pixelSize = pixelSize
        self.placements = placements
        self.joins = joins
    }
}

/// A completed stitch retained after the active workflow is reset.
///
/// History keeps only a bounded thumbnail in memory. The full-resolution PNG,
/// when available, remains in app-owned storage until the user explicitly
/// exports it.
public struct CompletedStitch: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let thumbnail: CGImage
    public var fullResolutionURL: URL?
    public let pixelSize: PixelSize
    public let savedAt: Date
    public var sources: [SourceImage]
    public var sourceImagesDeleted: Bool
    public var sourceDeletionInProgress: Bool
    public var sourceDeletionError: String?

    public init(
        id: UUID = UUID(),
        thumbnail: CGImage,
        fullResolutionURL: URL? = nil,
        pixelSize: PixelSize,
        savedAt: Date = Date(),
        sources: [SourceImage] = [],
        sourceImagesDeleted: Bool = false
    ) {
        self.id = id
        self.thumbnail = thumbnail
        self.fullResolutionURL = fullResolutionURL
        self.pixelSize = pixelSize
        self.savedAt = savedAt
        self.sources = sources
        self.sourceImagesDeleted = sourceImagesDeleted
        self.sourceDeletionInProgress = false
        self.sourceDeletionError = nil
    }
}

public enum ContinuoError: Error, LocalizedError, Sendable {
    case noSources
    case needsAtLeastTwoSources
    case photoLibraryPermissionDenied
    case noMatchingScreenshotSequence
    case sourceUnavailable(String)
    case unsupportedImage(String)
    case unsupportedMedia(String)
    case importFailed(String)
    case imageDecodeFailed(String)
    case registrationFailed(JoinResult)
    case pixelCropFailed(PixelCropError)
    case pixelCompositingFailed(PixelCompositingError)
    case renderingFailed(String)
    case outputTooLarge(PixelSize)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noSources:
            "Select at least two screenshots to begin."
        case .needsAtLeastTwoSources:
            "Continuo needs at least two screenshots for a join."
        case .photoLibraryPermissionDenied:
            "Continuo needs Photos access to find screenshots automatically."
        case .noMatchingScreenshotSequence:
            "Continuo could not find a nearby screenshot sequence that fits together."
        case let .sourceUnavailable(name):
            "The source \(name) is no longer available."
        case let .unsupportedImage(name):
            "The source \(name) is not a supported image."
        case let .unsupportedMedia(name):
            "\(name) is not a still image. Videos and Live Photos are not supported."
        case let .importFailed(name):
            "Continuo could not import \(name)."
        case let .imageDecodeFailed(name):
            "Continuo could not decode \(name)."
        case let .registrationFailed(join):
            join.diagnostics.message
        case let .pixelCropFailed(error):
            error.localizedDescription
        case let .pixelCompositingFailed(error):
            error.localizedDescription
        case let .renderingFailed(message):
            message
        case let .outputTooLarge(size):
            "The preview would be too large to render safely (\(size.width) × \(size.height))."
        case .cancelled:
            "Processing was cancelled."
        }
    }
}
