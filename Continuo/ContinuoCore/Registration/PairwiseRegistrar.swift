import Accelerate
import CoreGraphics
import Foundation
import Vision

public struct RegistrationConfiguration: Sendable, Equatable {
    public var minimumOverlapRatio: Double
    public var maximumCrossAxisDriftRatio: Double
    public var maximumSearchDriftRatio: Double
    public var highSimilarityThreshold: Double
    public var mediumSimilarityThreshold: Double
    public var lowSimilarityThreshold: Double
    public var ambiguityDelta: Double
    public var ambiguityCoverageDelta: Double
    public var ambiguityMinimumVerticalSeparation: Double

    public init(
        minimumOverlapRatio: Double = 0.18,
        maximumCrossAxisDriftRatio: Double = 0.16,
        maximumSearchDriftRatio: Double = 0.60,
        highSimilarityThreshold: Double = 0.90,
        mediumSimilarityThreshold: Double = 0.64,
        // Keep a conservative floor for unrelated images while allowing
        // medium-confidence, text-heavy matches to proceed.
        lowSimilarityThreshold: Double = 0.54,
        ambiguityDelta: Double = 0.006,
        ambiguityCoverageDelta: Double = 0.015,
        ambiguityMinimumVerticalSeparation: Double = 36
    ) {
        self.minimumOverlapRatio = minimumOverlapRatio
        self.maximumCrossAxisDriftRatio = maximumCrossAxisDriftRatio
        self.maximumSearchDriftRatio = maximumSearchDriftRatio
        self.highSimilarityThreshold = highSimilarityThreshold
        self.mediumSimilarityThreshold = mediumSimilarityThreshold
        self.lowSimilarityThreshold = lowSimilarityThreshold
        self.ambiguityDelta = ambiguityDelta
        self.ambiguityCoverageDelta = max(0, ambiguityCoverageDelta)
        self.ambiguityMinimumVerticalSeparation = max(1, ambiguityMinimumVerticalSeparation)
    }
}

public struct PairwiseRegistrar: Sendable {
    public var configuration: RegistrationConfiguration

    public init(configuration: RegistrationConfiguration = RegistrationConfiguration()) {
        self.configuration = configuration
    }

    public func register(from: NormalizedImage, to: NormalizedImage, direction: StitchDirection = .vertical) async throws -> JoinResult {
        try Task.checkCancellation()

        guard direction == .vertical else {
            return rejectedJoin(
                from: from,
                to: to,
                reason: .unsupportedDirection,
                code: "registration.unsupported_direction",
                message: "This foundation milestone registers vertical screenshot sequences only.",
                suggestion: "Choose a vertical screenshot sequence and try again."
            )
        }

        let visionTranslation = await visionTranslation(from: from.image, to: to.image)
        try Task.checkCancellation()

        let allowedDrift = Double(max(from.matchingRepresentation.width, to.matchingRepresentation.width)) * configuration.maximumCrossAxisDriftRatio
        if let visionTranslation,
           let visionCandidate = evaluate(
               translation: visionTranslation,
               from: from.matchingRepresentation,
               to: to.matchingRepresentation
           ),
           abs(visionCandidate.translation.x) <= allowedDrift,
           visionCandidate.overlapPercentage >= configuration.minimumOverlapRatio,
           visionCandidate.similarityScore >= configuration.mediumSimilarityThreshold {
            return makeJoinResult(
                from: from,
                to: to,
                candidate: visionCandidate,
                backend: .vision,
                ambiguous: false,
                candidateCount: 1
            )
        }

        let profile = try bestRowProfile(from: from.matchingRepresentation, to: to.matchingRepresentation)
        let correlation = try bestCorrelation(from: from.matchingRepresentation, to: to.matchingRepresentation)

        var fallbackOptions: [(candidate: Candidate, backend: RegistrationBackend)] = []
        if let profile {
            fallbackOptions.append((profile.best, .rowProfile))
        }
        if let correlation {
            fallbackOptions.append((correlation.best, .correlationFallback))
        }

        guard !fallbackOptions.isEmpty else {
            return rejectedJoin(
                from: from,
                to: to,
                reason: .noMatchFound,
                code: "registration.no_match",
                message: "Continuo could not find a usable overlap between these screenshots.",
                suggestion: "Check that the screenshots are adjacent and share visible content."
            )
        }

        var selected = fallbackOptions[0]
        for option in fallbackOptions.dropFirst() where isPreferred(option.candidate, over: selected.candidate) {
            selected = option
        }

        var alternatives = fallbackOptions
            .filter { $0.candidate.translation != selected.candidate.translation }
            .map(\.candidate)
        if let profile {
            alternatives.append(profile.second)
        }
        if let correlation {
            if let second = correlation.second {
                alternatives.append(second)
            }
        }
        let second = alternatives
            .filter { $0.translation != selected.candidate.translation }
            .max { lhs, rhs in isPreferred(rhs, over: lhs) }
        let isAmbiguous = second.map { second in
            let scoreGap = selected.candidate.similarityScore - second.similarityScore
            let coverageGap = selected.candidate.overlapPercentage - second.overlapPercentage
            let verticalSeparation = abs(selected.candidate.translation.y - second.translation.y)
            // An alternate candidate should only force review when the
            // selected candidate is below the medium-confidence floor. A
            // strong local match can legitimately have a nearby alternative
            // in text-heavy or repetitive screenshots; rejecting those joins
            // made otherwise obvious sequences fail unnecessarily.
            let selectedIsBelowMediumConfidence = selected.candidate.similarityScore < configuration.mediumSimilarityThreshold
            return selectedIsBelowMediumConfidence &&
                scoreGap <= configuration.ambiguityDelta &&
                coverageGap <= configuration.ambiguityCoverageDelta &&
                verticalSeparation >= configuration.ambiguityMinimumVerticalSeparation
        } ?? false
        return makeJoinResult(
            from: from,
            to: to,
            candidate: selected.candidate,
            backend: selected.backend,
            ambiguous: isAmbiguous,
            candidateCount: (profile?.candidateCount ?? 0) + (correlation?.candidateCount ?? 0)
        )
    }

    private func makeJoinResult(
        from: NormalizedImage,
        to: NormalizedImage,
        candidate: Candidate,
        backend: RegistrationBackend,
        ambiguous: Bool,
        candidateCount: Int
    ) -> JoinResult {
        let allowedDrift = Double(max(from.matchingRepresentation.width, to.matchingRepresentation.width)) * configuration.maximumCrossAxisDriftRatio
        // A weak match over only a sliver of the screenshots is too easy to
        // get from repeated rows or unrelated content. Larger overlaps use
        // the more accommodating similarity rules below.
        let thinOverlapWithWeakAgreement = candidate.overlapPercentage < 0.25 && candidate.similarityScore < 0.80

        let failureReason: JoinFailureReason?
        if abs(candidate.translation.x) > allowedDrift {
            failureReason = .excessiveCrossAxisDrift
        } else if ambiguous {
            failureReason = .ambiguousMatch
        } else if candidate.overlapPercentage < configuration.minimumOverlapRatio {
            failureReason = .insufficientOverlap
        } else if candidate.similarityScore < configuration.lowSimilarityThreshold || thinOverlapWithWeakAgreement {
            failureReason = .lowVisualAgreement
        } else {
            failureReason = nil
        }

        let confidence: ConfidenceLevel
        if failureReason != nil {
            confidence = candidate.similarityScore >= configuration.lowSimilarityThreshold ? .low : .rejected
        } else if candidate.similarityScore >= configuration.highSimilarityThreshold {
            confidence = .high
        } else if candidate.similarityScore >= configuration.mediumSimilarityThreshold {
            confidence = .medium
        } else {
            confidence = .low
        }

        let diagnostics = JoinDiagnostics(
            code: failureReason == nil ? "registration.accepted" : code(for: failureReason!),
            message: message(for: confidence, reason: failureReason),
            recoverySuggestion: suggestion(for: failureReason),
            similarityScore: candidate.similarityScore,
            overlapSize: PixelSize(width: candidate.overlapWidth, height: candidate.overlapHeight),
            overlapPercentage: candidate.overlapPercentage,
            translation: candidate.translation,
            crossAxisDrift: abs(candidate.translation.x),
            residualError: 1.0 - candidate.similarityScore,
            backend: backend,
            ambiguousCandidates: ambiguous,
            candidateCount: candidateCount,
            failureReason: failureReason
        )

        return JoinResult(
            fromSourceID: from.source.id,
            toSourceID: to.source.id,
            transform: AffineTransformData(translation: candidate.translation),
            overlapRect: candidate.overlapRect,
            seam: SeamDefinition(axis: .horizontal, position: Double(candidate.overlapHeight)),
            confidence: confidence,
            diagnostics: diagnostics
        )
    }

    private func visionTranslation(from: CGImage, to: CGImage) async -> Point2D? {
        do {
            // Vision treats `source` as the moving image and `target` as the
            // reference image. The result maps the moving image into target
            // coordinates, so placement in canvas coordinates is inverted.
            let request = TrackTranslationalImageRegistrationRequest()
            let handler = TargetedImageRequestHandler(source: to, target: from)
            let observation = try await handler.perform(request)
            let transform = observation.alignmentTransform
            return Point2D(x: Double(-transform.tx), y: Double(-transform.ty))
        } catch {
            return nil
        }
    }

    private struct Candidate: Sendable {
        var translation: Point2D
        var overlapWidth: Int
        var overlapHeight: Int
        var overlapPercentage: Double
        var overlapRect: Rect2D
        var similarityScore: Double
        var profileScore: Double = 0
    }

    private struct CorrelationResult: Sendable {
        var best: Candidate
        var second: Candidate?
        var candidateCount: Int
    }

    private struct RowFeature: Sendable {
        var mean: Double
        var variance: Double
        var edgeEnergy: Double
    }

    private struct RowProfileResult: Sendable {
        var best: Candidate
        var second: Candidate
        var candidateCount: Int
    }

    private struct SignalAccumulator {
        var count = 0
        var lhsSum = 0.0
        var rhsSum = 0.0
        var lhsSquaredSum = 0.0
        var rhsSquaredSum = 0.0
        var crossProductSum = 0.0

        mutating func append(_ lhs: Float, _ rhs: Float) {
            let left = Double(lhs)
            let right = Double(rhs)
            count += 1
            lhsSum += left
            rhsSum += right
            lhsSquaredSum += left * left
            rhsSquaredSum += right * right
            crossProductSum += left * right
        }

        var normalizedCorrelation: Double {
            guard count > 0 else { return 0 }
            let divisor = Double(count)
            let lhsMean = lhsSum / divisor
            let rhsMean = rhsSum / divisor
            let lhsVariance = max(0, (lhsSquaredSum / divisor) - (lhsMean * lhsMean))
            let rhsVariance = max(0, (rhsSquaredSum / divisor) - (rhsMean * rhsMean))

            guard lhsVariance > 0.0000001, rhsVariance > 0.0000001 else {
                return abs(lhsMean - rhsMean) < 0.0001 ? 1 : 0
            }

            let covariance = (crossProductSum / divisor) - (lhsMean * rhsMean)
            let correlation = covariance / sqrt(lhsVariance * rhsVariance)
            return min(1, max(0, (correlation + 1) * 0.5))
        }
    }

    private func bestRowProfile(from: MatchingRepresentation, to: MatchingRepresentation) throws -> RowProfileResult? {
        let minimumOverlap = max(2, Int(Double(min(from.height, to.height)) * configuration.minimumOverlapRatio))
        let maximumOffset = min(from.height - minimumOverlap, to.height - minimumOverlap)
        guard maximumOffset >= 1 else { return nil }

        let fromProfile = makeRowProfile(from)
        let toProfile = makeRowProfile(to)
        let offsetStep = max(1, min(12, min(from.height, to.height) / 80))
        var scoredOffsets: [(offset: Int, score: Double)] = []

        for offset in sampledValues(from: 1, through: maximumOffset, by: offsetStep) {
            try Task.checkCancellation()
            let overlapHeight = min(from.height - offset, to.height)
            let profileScore = rowProfileAgreement(
                from: fromProfile,
                to: toProfile,
                offset: offset,
                overlapHeight: overlapHeight
            )
            let coverage = Double(overlapHeight) / Double(max(1, min(from.height, to.height)))
            scoredOffsets.append((offset, (profileScore * 0.90) + (min(1, coverage) * 0.10)))
        }

        guard let bestOffset = scoredOffsets.max(by: { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.002 {
                return lhs.score < rhs.score
            }
            return lhs.offset > rhs.offset
        }) else {
            return nil
        }

        let secondOffset = scoredOffsets
            .filter { $0.offset != bestOffset.offset }
            .max { lhs, rhs in lhs.score < rhs.score }

        guard var bestCandidate = evaluate(
            translation: Point2D(x: 0, y: Double(bestOffset.offset)),
            from: from,
            to: to
        ) else {
            return nil
        }
        bestCandidate.profileScore = bestOffset.score
        bestCandidate.similarityScore = min(1, max(0,
            (bestCandidate.similarityScore * 0.45) + (bestOffset.score * 0.55)
        ))

        guard let secondOffset,
              var secondCandidate = evaluate(
                  translation: Point2D(x: 0, y: Double(secondOffset.offset)),
                  from: from,
                  to: to
              ) else {
            return RowProfileResult(
                best: bestCandidate,
                second: bestCandidate,
                candidateCount: scoredOffsets.count
            )
        }
        secondCandidate.profileScore = secondOffset.score
        secondCandidate.similarityScore = min(1, max(0,
            (secondCandidate.similarityScore * 0.45) + (secondOffset.score * 0.55)
        ))

        return RowProfileResult(
            best: bestCandidate,
            second: secondCandidate,
            candidateCount: scoredOffsets.count
        )
    }

    private func makeRowProfile(_ representation: MatchingRepresentation) -> [RowFeature] {
        guard representation.width > 0, representation.height > 0 else { return [] }

        var profile: [RowFeature] = []
        profile.reserveCapacity(representation.height)
        let width = Double(representation.width)
        for y in 0..<representation.height {
            var sum = 0.0
            var squaredSum = 0.0
            var edgeEnergy = 0.0
            for x in 0..<representation.width {
                let luminance = Double(representation[x, y])
                sum += luminance
                squaredSum += luminance * luminance
                edgeEnergy += Double(representation.edge(atX: x, y: y))
            }
            let mean = sum / width
            profile.append(RowFeature(
                mean: mean,
                variance: max(0, (squaredSum / width) - (mean * mean)),
                edgeEnergy: edgeEnergy / width
            ))
        }
        return profile
    }

    private func rowProfileAgreement(
        from: [RowFeature],
        to: [RowFeature],
        offset: Int,
        overlapHeight: Int
    ) -> Double {
        guard offset >= 1, overlapHeight >= 2,
              offset + overlapHeight <= from.count,
              overlapHeight <= to.count else {
            return 0
        }

        var means: ([Double], [Double]) = ([], [])
        var variances: ([Double], [Double]) = ([], [])
        var edges: ([Double], [Double]) = ([], [])
        means.0.reserveCapacity(overlapHeight)
        means.1.reserveCapacity(overlapHeight)
        variances.0.reserveCapacity(overlapHeight)
        variances.1.reserveCapacity(overlapHeight)
        edges.0.reserveCapacity(overlapHeight)
        edges.1.reserveCapacity(overlapHeight)

        for y in 0..<overlapHeight {
            let lhs = from[offset + y]
            let rhs = to[y]
            means.0.append(lhs.mean)
            means.1.append(rhs.mean)
            variances.0.append(lhs.variance)
            variances.1.append(rhs.variance)
            edges.0.append(lhs.edgeEnergy)
            edges.1.append(rhs.edgeEnergy)
        }

        return min(1, max(0,
            (rowCorrelation(means.0, means.1) * 0.45) +
            (rowCorrelation(variances.0, variances.1) * 0.25) +
            (rowCorrelation(edges.0, edges.1) * 0.30)
        ))
    }

    private func rowCorrelation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        let count = Double(lhs.count)
        let lhsMean = lhs.reduce(0, +) / count
        let rhsMean = rhs.reduce(0, +) / count
        var lhsEnergy = 0.0
        var rhsEnergy = 0.0
        var dot = 0.0
        for (left, right) in zip(lhs, rhs) {
            let centeredLeft = left - lhsMean
            let centeredRight = right - rhsMean
            lhsEnergy += centeredLeft * centeredLeft
            rhsEnergy += centeredRight * centeredRight
            dot += centeredLeft * centeredRight
        }

        guard lhsEnergy > 0.0000001, rhsEnergy > 0.0000001 else {
            return zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.0001 } ? 1 : 0
        }
        return min(1, max(0, (dot / sqrt(lhsEnergy * rhsEnergy) + 1) * 0.5))
    }

    private func bestCorrelation(from: MatchingRepresentation, to: MatchingRepresentation) throws -> CorrelationResult? {
        let minimumOverlap = max(2, Int(Double(min(from.height, to.height)) * configuration.minimumOverlapRatio))
        let maximumOffset = min(from.height - minimumOverlap, to.height - minimumOverlap)
        guard maximumOffset >= 1 else { return nil }

        let maximumSearchDrift = Int(Double(min(from.width, to.width)) * configuration.maximumSearchDriftRatio)
        let coarseOffsetStep = max(1, min(12, min(from.height, to.height) / 80))
        let coarseDriftStep = max(1, min(12, min(from.width, to.width) / 80))
        let coarseSampleStep = max(4, max(max(from.width, from.height), max(to.width, to.height)) / 128)
        var candidates: [Candidate] = []

        for offset in sampledValues(from: 1, through: maximumOffset, by: coarseOffsetStep) {
            try Task.checkCancellation()
            for drift in sampledValues(from: -maximumSearchDrift, through: maximumSearchDrift, by: coarseDriftStep) {
                if let candidate = evaluate(
                    translation: Point2D(x: Double(drift), y: Double(offset)),
                    from: from,
                    to: to,
                    sampleStepOverride: coarseSampleStep
                ) {
                    candidates.append(candidate)
                }
            }
        }

        guard let coarseBest = preferredCandidate(from: candidates) else { return nil }
        let coarseBestOffset = Int(coarseBest.translation.y.rounded())
        let coarseBestDrift = Int(coarseBest.translation.x.rounded())
        let fineOffsetStart = max(1, coarseBestOffset - coarseOffsetStep)
        let fineOffsetEnd = min(maximumOffset, coarseBestOffset + coarseOffsetStep)
        let fineDriftStart = max(-maximumSearchDrift, coarseBestDrift - coarseDriftStep)
        let fineDriftEnd = min(maximumSearchDrift, coarseBestDrift + coarseDriftStep)

        for offset in fineOffsetStart...fineOffsetEnd {
            try Task.checkCancellation()
            for drift in fineDriftStart...fineDriftEnd {
                if let candidate = evaluate(
                    translation: Point2D(x: Double(drift), y: Double(offset)),
                    from: from,
                    to: to
                ) {
                    candidates.append(candidate)
                }
            }
        }

        guard let best = preferredCandidate(from: candidates) else { return nil }
        let second = candidates
            .filter { $0.translation != best.translation }
            .max(by: { $0.similarityScore < $1.similarityScore })
        return CorrelationResult(best: best, second: second, candidateCount: candidates.count)
    }

    private func isPreferred(_ candidate: Candidate, over other: Candidate) -> Bool {
        let scoreGap = candidate.similarityScore - other.similarityScore
        let coverageGap = candidate.overlapPercentage - other.overlapPercentage

        // A small, coincidental patch should not beat a materially larger
        // overlap merely because its local details happen to correlate better.
        if abs(scoreGap) < 0.04, abs(coverageGap) > 0.04 {
            return coverageGap > 0
        }
        if abs(scoreGap) > 0.03 {
            return scoreGap > 0
        }

        if abs(coverageGap) > 0.01 {
            return coverageGap > 0
        }

        let drift = abs(candidate.translation.x)
        let otherDrift = abs(other.translation.x)
        if abs(drift - otherDrift) > 1 {
            return drift < otherDrift
        }

        return scoreGap > 0
    }

    private func preferredCandidate(from candidates: [Candidate]) -> Candidate? {
        var preferred: Candidate?
        for candidate in candidates {
            guard let current = preferred else {
                preferred = candidate
                continue
            }
            if isPreferred(candidate, over: current) {
                preferred = candidate
            }
        }
        return preferred
    }

    private func sampledValues(from lowerBound: Int, through upperBound: Int, by step: Int) -> [Int] {
        let safeStep = max(1, step)
        var values = Array(stride(from: lowerBound, through: upperBound, by: safeStep))
        if values.last != upperBound {
            values.append(upperBound)
        }
        return values
    }

    private func evaluate(
        translation: Point2D,
        from: MatchingRepresentation,
        to: MatchingRepresentation,
        sampleStepOverride: Int? = nil
    ) -> Candidate? {
        let offset = Int(translation.y.rounded())
        let drift = Int(translation.x.rounded())
        guard offset >= 1 else { return nil }

        let fromStartX = max(0, drift)
        let toStartX = max(0, -drift)
        let overlapWidth = min(from.width - fromStartX, to.width - toStartX)
        let overlapHeight = min(from.height - offset, to.height)
        guard overlapWidth >= 2, overlapHeight >= 2 else { return nil }

        let sampleStep = sampleStepOverride ?? max(1, max(overlapWidth, overlapHeight) / 256)
        var lhs = [Float]()
        var rhs = [Float]()
        let estimatedSamplesPerRow = max(1, (overlapWidth + sampleStep - 1) / sampleStep)
        let estimatedSampleRows = max(1, (overlapHeight + sampleStep - 1) / sampleStep)
        lhs.reserveCapacity(estimatedSamplesPerRow * estimatedSampleRows)
        rhs.reserveCapacity(lhs.capacity)

        let tileCount = min(6, max(2, overlapHeight / max(16, sampleStep * 16)))
        var luminanceTiles = [SignalAccumulator](repeating: SignalAccumulator(), count: tileCount)
        var edgeTiles = [SignalAccumulator](repeating: SignalAccumulator(), count: tileCount)

        for y in stride(from: 0, to: overlapHeight, by: sampleStep) {
            let tileIndex = min(tileCount - 1, (y * tileCount) / max(1, overlapHeight))
            for x in stride(from: 0, to: overlapWidth, by: sampleStep) {
                let left = from[fromStartX + x, offset + y]
                let right = to[toStartX + x, y]
                lhs.append(left)
                rhs.append(right)
                luminanceTiles[tileIndex].append(left, right)
                edgeTiles[tileIndex].append(
                    from.verticalGradient(atX: fromStartX + x, y: offset + y),
                    to.verticalGradient(atX: toStartX + x, y: y)
                )
            }
        }

        guard !lhs.isEmpty else { return nil }
        let luminanceScore = robustSignalScore(lhs, rhs)
        let edgeScore = median(edgeTiles.map(\.normalizedCorrelation))
        let tileConsensus = median(zip(luminanceTiles, edgeTiles).map { luminance, edge in
            (luminance.normalizedCorrelation * 0.8) + (edge.normalizedCorrelation * 0.2)
        })
        let similarity = min(1.0, max(0.0,
            (luminanceScore * 0.65) +
            (edgeScore * 0.15) +
            (tileConsensus * 0.20)
        ))
        let overlapPercentage = Double(overlapWidth * overlapHeight) / Double(max(1, min(from.width * from.height, to.width * to.height)))

        return Candidate(
            translation: Point2D(x: Double(drift), y: Double(offset)),
            overlapWidth: overlapWidth,
            overlapHeight: overlapHeight,
            overlapPercentage: overlapPercentage,
            overlapRect: Rect2D(x: Double(fromStartX), y: Double(offset), width: Double(overlapWidth), height: Double(overlapHeight)),
            similarityScore: similarity
        )
    }

    private func robustSignalScore(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }

        var lhsSum: Float = 0
        var rhsSum: Float = 0
        vDSP_sve(lhs, 1, &lhsSum, vDSP_Length(lhs.count))
        vDSP_sve(rhs, 1, &rhsSum, vDSP_Length(rhs.count))
        let lhsMean = lhsSum / Float(lhs.count)
        let rhsMean = rhsSum / Float(rhs.count)
        var negativeLHSMean = -lhsMean
        var negativeRHSMean = -rhsMean
        var locallyCenteredLHS = [Float](repeating: 0, count: lhs.count)
        var locallyCenteredRHS = [Float](repeating: 0, count: rhs.count)
        vDSP_vsadd(lhs, 1, &negativeLHSMean, &locallyCenteredLHS, 1, vDSP_Length(lhs.count))
        vDSP_vsadd(rhs, 1, &negativeRHSMean, &locallyCenteredRHS, 1, vDSP_Length(rhs.count))

        var dot: Float = 0
        var lhsEnergy: Float = 0
        var rhsEnergy: Float = 0
        vDSP_dotpr(locallyCenteredLHS, 1, locallyCenteredRHS, 1, &dot, vDSP_Length(lhs.count))
        vDSP_svesq(locallyCenteredLHS, 1, &lhsEnergy, vDSP_Length(lhs.count))
        vDSP_svesq(locallyCenteredRHS, 1, &rhsEnergy, vDSP_Length(rhs.count))

        let correlation: Double
        if lhsEnergy > 0.000001, rhsEnergy > 0.000001 {
            correlation = (Double(dot) / sqrt(Double(lhsEnergy) * Double(rhsEnergy)) + 1.0) / 2.0
        } else {
            correlation = zip(locallyCenteredLHS, locallyCenteredRHS).allSatisfy { abs($0 - $1) < 0.0001 } ? 1.0 : 0.0
        }

        let lhsStandardDeviation = sqrt(Double(lhsEnergy) / Double(lhs.count))
        let rhsStandardDeviation = sqrt(Double(rhsEnergy) / Double(rhs.count))
        let normalizationScale = max(0.035, (lhsStandardDeviation + rhsStandardDeviation) * 0.5)
        let outlierLimit = normalizationScale * 1.75
        var cappedDifference: Double = 0
        for (left, right) in zip(locallyCenteredLHS, locallyCenteredRHS) {
            cappedDifference += min(Double(abs(left - right)), outlierLimit)
        }
        let normalizedDifference = cappedDifference / Double(lhs.count) / normalizationScale
        let robustDifferenceScore = max(0, 1.0 - min(1.0, normalizedDifference * 0.65))
        return min(1.0, max(0.0, (correlation * 0.88) + (robustDifferenceScore * 0.12)))
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    private func rejectedJoin(
        from: NormalizedImage,
        to: NormalizedImage,
        reason: JoinFailureReason,
        code: String,
        message: String,
        suggestion: String
    ) -> JoinResult {
        let diagnostics = JoinDiagnostics(
            code: code,
            message: message,
            recoverySuggestion: suggestion,
            similarityScore: 0,
            overlapSize: PixelSize(width: 0, height: 0),
            overlapPercentage: 0,
            translation: Point2D(),
            crossAxisDrift: 0,
            residualError: 1,
            backend: .correlationFallback,
            ambiguousCandidates: false,
            candidateCount: 0,
            failureReason: reason
        )
        return JoinResult(
            fromSourceID: from.source.id,
            toSourceID: to.source.id,
            transform: AffineTransformData(),
            overlapRect: Rect2D(x: 0, y: 0, width: 0, height: 0),
            seam: SeamDefinition(axis: .horizontal, position: 0),
            confidence: .rejected,
            diagnostics: diagnostics
        )
    }

    private func code(for reason: JoinFailureReason) -> String {
        switch reason {
        case .noMatchFound: "registration.no_match"
        case .insufficientOverlap: "registration.insufficient_overlap"
        case .excessiveCrossAxisDrift: "registration.excessive_cross_axis_drift"
        case .lowVisualAgreement: "registration.low_visual_agreement"
        case .ambiguousMatch: "registration.ambiguous_match"
        case .unsupportedDirection: "registration.unsupported_direction"
        }
    }

    private func message(for confidence: ConfidenceLevel, reason: JoinFailureReason?) -> String {
        if let reason {
            return switch reason {
            case .insufficientOverlap: "The screenshots do not share enough visible content to trust this join."
            case .excessiveCrossAxisDrift: "The screenshots appear to move sideways more than a vertical stitch allows."
            case .lowVisualAgreement: "The proposed overlap does not agree closely enough to commit automatically."
            case .ambiguousMatch: "Several overlaps look similarly plausible, so this join needs review."
            case .noMatchFound: "No usable overlap was found."
            case .unsupportedDirection: "This direction is not available in the current foundation milestone."
            }
        }
        return switch confidence {
        case .high: "High-confidence vertical join."
        case .medium: "Medium-confidence vertical join; review is recommended."
        case .low: "Low-confidence vertical join; review is required."
        case .rejected: "The join was rejected."
        }
    }

    private func suggestion(for reason: JoinFailureReason?) -> String {
        guard let reason else { return "" }
        return switch reason {
        case .insufficientOverlap: "Select adjacent screenshots with a larger shared region."
        case .excessiveCrossAxisDrift: "Confirm the screenshots belong to the same vertical sequence."
        case .lowVisualAgreement: "Retry with a different adjacent pair or inspect the source order."
        case .ambiguousMatch: "Open Proof Mode in a later milestone to choose the intended seam."
        case .noMatchFound: "Check the selected order and verify both images are readable."
        case .unsupportedDirection: "Use vertical mode for this milestone."
        }
    }
}
