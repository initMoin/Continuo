import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public struct FoundationModelScreenshotAdvisor: ScreenshotIntelligenceAdvisor {
    public init() {}

    public func prioritizedCandidateIDs(_ candidates: [AutomaticScreenshotCandidate]) async -> Set<String>? {
#if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard !candidates.isEmpty else { return nil }

        let metadata = candidates.map { candidate in
            let date = candidate.captureDate?.ISO8601Format() ?? "unknown-date"
            return "id=\(candidate.identifier), date=\(date), size=\(candidate.pixelSize.width)x\(candidate.pixelSize.height)"
        }.joined(separator: "\n")
        let prompt = """
        You are assisting a screenshot stitching app. From the candidate metadata below, return only a comma-separated list of candidate ids that most likely belong to one contiguous scrolling capture session. Keep chronological neighbors with matching dimensions. Do not invent ids and do not explain your answer.

        \(metadata)
        """

        do {
            let session = LanguageModelSession(instructions: "Return only ids from the supplied metadata.")
            let response = try await session.respond(to: prompt)
            let knownIDs = Set(candidates.map(\.identifier))
            let ids = response.content
                .split { $0 == "," || $0 == "\n" || $0 == " " || $0 == "`" }
                .map(String.init)
                .filter { knownIDs.contains($0) }
            return ids.count >= 2 ? Set(ids) : nil
        } catch {
            return nil
        }
#else
        return nil
#endif
    }
}
