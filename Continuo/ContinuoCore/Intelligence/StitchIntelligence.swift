import Foundation

public enum StitchIntelligenceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case visionAssisted
    case foundationModelsAssisted

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .visionAssisted: "Vision-assisted"
        case .foundationModelsAssisted: "Foundation Models-assisted"
        }
    }

    public var description: String {
        switch self {
        case .automatic:
            "Use Continuo’s deterministic pixel matching and the fastest path."
        case .visionAssisted:
            "Use Apple Vision when pixel matching needs a second opinion."
        case .foundationModelsAssisted:
            "Use Foundation Models to narrow candidates before Vision and pixel matching."
        }
    }
}

public protocol ScreenshotIntelligenceAdvisor: Sendable {
    func prioritizedCandidateIDs(_ candidates: [AutomaticScreenshotCandidate]) async -> Set<String>?
}

public struct NoopScreenshotIntelligenceAdvisor: ScreenshotIntelligenceAdvisor {
    public init() {}

    public func prioritizedCandidateIDs(_ candidates: [AutomaticScreenshotCandidate]) async -> Set<String>? {
        nil
    }
}

public enum ScreenshotIntelligenceFactory {
    public static func advisor(for mode: StitchIntelligenceMode) -> any ScreenshotIntelligenceAdvisor {
        switch mode {
        case .automatic, .visionAssisted:
            NoopScreenshotIntelligenceAdvisor()
        case .foundationModelsAssisted:
            FoundationModelScreenshotAdvisor()
        }
    }
}
