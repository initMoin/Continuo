import Foundation

public struct AutomaticScreenshotSelectionConfiguration: Sendable, Equatable {
    public var maximumCandidateCount: Int
    public var maximumLookahead: Int
    public var maximumTemporalGap: TimeInterval
    public var minimumSequenceLength: Int
    public var dimensionTolerance: Double
    public var candidateMaximumPixelSize: Int

    public init(
        maximumCandidateCount: Int = 50,
        maximumLookahead: Int = 3,
        maximumTemporalGap: TimeInterval = 5 * 60,
        minimumSequenceLength: Int = 2,
        dimensionTolerance: Double = 0.02,
        candidateMaximumPixelSize: Int = 1_200
    ) {
        self.maximumCandidateCount = max(2, maximumCandidateCount)
        self.maximumLookahead = max(1, maximumLookahead)
        self.maximumTemporalGap = max(1, maximumTemporalGap)
        self.minimumSequenceLength = max(2, minimumSequenceLength)
        self.dimensionTolerance = min(1, max(0, dimensionTolerance))
        self.candidateMaximumPixelSize = max(320, candidateMaximumPixelSize)
    }
}

public struct AutomaticScreenshotSequenceSelection: Sendable, Equatable {
    public let sources: [SourceImage]
    public let score: Double
    public let joinCount: Int

    public init(sources: [SourceImage], score: Double, joinCount: Int) {
        self.sources = sources
        self.score = score
        self.joinCount = joinCount
    }
}

/// Chooses the strongest chronological path through screenshot candidates.
///
/// The selector is deliberately independent of Photos. It consumes source
/// metadata and the registrar's pairwise results so it can be tested with
/// fixtures and reused by another importer in the future.
public struct AutomaticScreenshotSequenceSelector: Sendable {
    public var configuration: AutomaticScreenshotSelectionConfiguration

    public init(
        configuration: AutomaticScreenshotSelectionConfiguration = AutomaticScreenshotSelectionConfiguration()
    ) {
        self.configuration = configuration
    }

    public func select(
        sources: [SourceImage],
        joins: [JoinResult]
    ) -> AutomaticScreenshotSequenceSelection? {
        guard sources.count >= configuration.minimumSequenceLength else {
            return nil
        }

        let chronologicalSources = sources.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.captureDate, rhs.element.captureDate) {
                case let (left?, right?) where left != right:
                    return left < right
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)

        let candidateOrders = [
            chronologicalSources,
            Array(chronologicalSources.reversed())
        ]
        var bestSelection: AutomaticScreenshotSequenceSelection?
        for orderedSources in candidateOrders {
            guard let selection = selectOrdered(sources: orderedSources, joins: joins) else {
                continue
            }
            if let currentBest = bestSelection {
                if isBetterSelection(selection, than: currentBest) {
                    bestSelection = selection
                }
            } else {
                bestSelection = selection
            }
        }
        return bestSelection
    }

    private func selectOrdered(
        sources orderedSources: [SourceImage],
        joins: [JoinResult]
    ) -> AutomaticScreenshotSequenceSelection? {

        let sourceIndex = Dictionary(
            uniqueKeysWithValues: orderedSources.enumerated().map { ($0.element.id, $0.offset) }
        )
        var joinLookup: [JoinKey: JoinResult] = [:]
        for join in joins {
            guard
                let fromIndex = sourceIndex[join.fromSourceID],
                let toIndex = sourceIndex[join.toSourceID],
                fromIndex < toIndex
            else {
                continue
            }
            joinLookup[JoinKey(from: join.fromSourceID, to: join.toSourceID)] = join
        }

        var bestPaths = Array(repeating: [Int](), count: orderedSources.count)
        var bestScores = Array(repeating: 0.0, count: orderedSources.count)

        for startIndex in stride(from: orderedSources.count - 1, through: 0, by: -1) {
            bestPaths[startIndex] = [startIndex]

            let endIndex = min(
                orderedSources.count - 1,
                startIndex + configuration.maximumLookahead
            )
            guard startIndex < endIndex else {
                continue
            }

            for nextIndex in (startIndex + 1)...endIndex {
                let from = orderedSources[startIndex]
                let to = orderedSources[nextIndex]
                guard
                    temporallyCompatible(from: from, to: to),
                    dimensionsCompatible(from: from, to: to),
                    let join = joinLookup[JoinKey(from: from.id, to: to.id)],
                    join.confidence.isAccepted
                else {
                    continue
                }

                let candidatePath = [startIndex] + bestPaths[nextIndex]
                guard candidatePath.count >= 2 else {
                    continue
                }

                let candidateScore = edgeScore(
                    join: join,
                    skippedSourceCount: max(0, nextIndex - startIndex - 1),
                    from: from,
                    to: to
                ) + bestScores[nextIndex]
                if isBetterPath(
                    candidatePath,
                    score: candidateScore,
                    than: bestPaths[startIndex],
                    score: bestScores[startIndex]
                ) {
                    bestPaths[startIndex] = candidatePath
                    bestScores[startIndex] = candidateScore
                }
            }
        }

        var best: (path: [Int], score: Double)?
        for index in orderedSources.indices {
            guard bestPaths[index].count >= configuration.minimumSequenceLength else {
                continue
            }
            let candidate = (path: bestPaths[index], score: bestScores[index])
            if let currentBest = best {
                if isBetterPath(
                    candidate.path,
                    score: candidate.score,
                    than: currentBest.path,
                    score: currentBest.score
                ) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        guard let best else {
            return nil
        }

        let selectedSources = best.path.map { orderedSources[$0] }
        return AutomaticScreenshotSequenceSelection(
            sources: selectedSources,
            score: best.score,
            joinCount: max(0, selectedSources.count - 1)
        )
    }

    private func temporallyCompatible(from: SourceImage, to: SourceImage) -> Bool {
        guard let fromDate = from.captureDate, let toDate = to.captureDate else {
            return true
        }
        return abs(toDate.timeIntervalSince(fromDate)) <= configuration.maximumTemporalGap
    }

    private func dimensionsCompatible(from: SourceImage, to: SourceImage) -> Bool {
        guard
            from.pixelSize.width > 0,
            from.pixelSize.height > 0,
            to.pixelSize.width > 0,
            to.pixelSize.height > 0
        else {
            return true
        }

        let widthDelta = relativeDelta(from.pixelSize.width, to.pixelSize.width)
        let heightDelta = relativeDelta(from.pixelSize.height, to.pixelSize.height)
        return widthDelta <= configuration.dimensionTolerance &&
            heightDelta <= configuration.dimensionTolerance
    }

    private func relativeDelta(_ lhs: Int, _ rhs: Int) -> Double {
        abs(Double(lhs - rhs)) / Double(max(1, max(lhs, rhs)))
    }

    private func edgeScore(
        join: JoinResult,
        skippedSourceCount: Int,
        from: SourceImage,
        to: SourceImage
    ) -> Double {
        let similarity = min(1, max(0, join.diagnostics.similarityScore))
        let overlap = min(1, max(0, join.diagnostics.overlapPercentage))
        let quality = (similarity * 0.72) + (overlap * 0.28)
        let gapPenalty: Double
        if let fromDate = from.captureDate, let toDate = to.captureDate {
            let gap = abs(toDate.timeIntervalSince(fromDate))
            gapPenalty = min(0.20, gap / configuration.maximumTemporalGap * 0.20)
        } else {
            gapPenalty = 0
        }
        let skippedPenalty = Double(skippedSourceCount) * 0.18
        return quality + 0.35 - gapPenalty - skippedPenalty
    }

    private func isBetterPath(
        _ lhs: [Int],
        score lhsScore: Double,
        than rhs: [Int],
        score rhsScore: Double
    ) -> Bool {
        if lhs.count != rhs.count {
            return lhs.count > rhs.count
        }
        if abs(lhsScore - rhsScore) > 0.0001 {
            return lhsScore > rhsScore
        }
        return (lhs.first ?? .max) < (rhs.first ?? .max)
    }

    private func isBetterSelection(
        _ lhs: AutomaticScreenshotSequenceSelection,
        than rhs: AutomaticScreenshotSequenceSelection
    ) -> Bool {
        if lhs.sources.count != rhs.sources.count {
            return lhs.sources.count > rhs.sources.count
        }
        return lhs.score > rhs.score + 0.0001
    }

    private struct JoinKey: Hashable {
        let from: UUID
        let to: UUID
    }
}
