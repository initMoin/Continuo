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
    /// Weak alternatives should not force review merely because they are
    /// numerically close to the selected candidate.
    public var ambiguityMinimumSimilarity: Double
    public var ambiguityMinimumCoverageRatio: Double
    /// Number of vertical offsets retained from the inexpensive row-profile
    /// pass before the 2D correlation search begins.
    public var maximumSeedOffsets: Int
    /// Approximate number of horizontal drift samples used for each coarse
    /// vertical seed. The exact count is bounded by the image dimensions.
    public var coarseDriftSamples: Int
    /// A high-overlap match can be useful even when local pixel agreement is
    /// modest (for example, text rendered with slightly different antialiasing).
    public var highCoverageAcceptanceRatio: Double
    public var highCoverageSimilarityThreshold: Double
    /// Avoids one-pixel near-duplicate matches winning over the actual scroll
    /// displacement on repetitive interfaces. Scales with image height.
    public var minimumVerticalTranslationRatio: Double
    /// Fixed status/navigation/search chrome is excluded from matching only;
    /// source pixels remain untouched for rendering.
    public var matchingTopExclusionRatio: Double
    public var matchingBottomExclusionRatio: Double
    /// Prevents shared columns or fixed chrome from making unrelated images
    /// look like a valid medium-confidence vertical match.
    public var minimumStructuralSimilarityThreshold: Double
    public var visionFallbackEnabled: Bool

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
        ambiguityMinimumVerticalSeparation: Double = 36,
        ambiguityMinimumSimilarity: Double = 0.58,
        ambiguityMinimumCoverageRatio: Double = 0.30,
        maximumSeedOffsets: Int = 6,
        coarseDriftSamples: Int = 13,
        highCoverageAcceptanceRatio: Double = 0.55,
        highCoverageSimilarityThreshold: Double = 0.54,
        minimumVerticalTranslationRatio: Double = 0.02,
        matchingTopExclusionRatio: Double = 0.10,
        matchingBottomExclusionRatio: Double = 0.04,
        minimumStructuralSimilarityThreshold: Double = 0.52,
        visionFallbackEnabled: Bool = true
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
        self.ambiguityMinimumSimilarity = min(1, max(0, ambiguityMinimumSimilarity))
        self.ambiguityMinimumCoverageRatio = min(1, max(minimumOverlapRatio, ambiguityMinimumCoverageRatio))
        self.maximumSeedOffsets = max(2, maximumSeedOffsets)
        self.coarseDriftSamples = max(5, coarseDriftSamples)
        self.highCoverageAcceptanceRatio = min(1, max(minimumOverlapRatio, highCoverageAcceptanceRatio))
        self.highCoverageSimilarityThreshold = min(1, max(0, highCoverageSimilarityThreshold))
        self.minimumVerticalTranslationRatio = min(0.25, max(0, minimumVerticalTranslationRatio))
        self.matchingTopExclusionRatio = min(0.30, max(0, matchingTopExclusionRatio))
        self.matchingBottomExclusionRatio = min(0.20, max(0, matchingBottomExclusionRatio))
        self.minimumStructuralSimilarityThreshold = min(1, max(0, minimumStructuralSimilarityThreshold))
        self.visionFallbackEnabled = visionFallbackEnabled
    }
}

public struct PairwiseRegistrar: Sendable {
    public var configuration: RegistrationConfiguration

    public init(configuration: RegistrationConfiguration = RegistrationConfiguration()) {
        self.configuration = configuration
    }

    public func register(from: NormalizedImage, to: NormalizedImage, direction: StitchDirection = .vertical) async throws -> JoinResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        try Task.checkCancellation()

        guard direction == .vertical else {
            return rejectedJoin(
                from: from,
                to: to,
                reason: .unsupportedDirection,
                code: "registration.unsupported_direction",
                message: "This registrar expects sources in vertical coordinate space.",
                suggestion: "Use StitchEngine’s direction-aware workflow and try again.",
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
        }

        let allowedDrift = Double(max(from.matchingRepresentation.width, to.matchingRepresentation.width)) * configuration.maximumCrossAxisDriftRatio
        let profile = try bestRowProfile(from: from.matchingRepresentation, to: to.matchingRepresentation)
        if let profile,
           isDecisiveProfileMatch(profile, allowedDrift: allowedDrift) {
            return makeJoinResult(
                from: from,
                to: to,
                candidate: profile.best,
                backend: .rowProfile,
                ambiguous: false,
                candidateCount: profile.candidateCount,
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
            )
        }

        // Most adjacent screenshots have no material cross-axis drift. Let
        // the deterministic row profile settle those inexpensive cases before
        // invoking Vision, which is reserved for the ambiguous fallback.
        let visionTranslation = configuration.visionFallbackEnabled
            ? await visionTranslation(from: from.matchingImage, to: to.matchingImage)
            : nil
        try Task.checkCancellation()

        let minimumVerticalTranslation = minimumVerticalTranslation(from: from, to: to)
        var visionCandidateForComparison: Candidate?
        if let visionTranslation,
           let visionCandidate = evaluate(
               translation: visionTranslation,
               from: from.matchingRepresentation,
               to: to.matchingRepresentation
           ),
           abs(visionCandidate.translation.x) <= allowedDrift,
           visionCandidate.translation.y >= Double(minimumVerticalTranslation),
           visionCandidate.overlapPercentage >= configuration.minimumOverlapRatio {
            if visionCandidate.similarityScore >= configuration.highSimilarityThreshold,
               visionCandidate.overlapPercentage >= configuration.highCoverageAcceptanceRatio {
                return makeJoinResult(
                    from: from,
                    to: to,
                    candidate: visionCandidate,
                    backend: .vision,
                    ambiguous: false,
                    candidateCount: 1,
                    elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
                )
            }
            visionCandidateForComparison = visionCandidate
        }
        let correlation = try bestCorrelation(
            from: from.matchingRepresentation,
            to: to.matchingRepresentation,
            seedOffsets: profile?.seedOffsets ?? [],
            preferredOffset: visionTranslation.map { Int($0.y.rounded()) }
        )
        var fallbackOptions: [(candidate: Candidate, backend: RegistrationBackend)] = []
        if let visionCandidateForComparison {
            fallbackOptions.append((visionCandidateForComparison, .vision))
        }
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
                suggestion: "Check that the screenshots are adjacent and share visible content.",
                elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
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
            let alternativeIsPlausible = second.similarityScore >= configuration.ambiguityMinimumSimilarity &&
                second.overlapPercentage >= configuration.ambiguityMinimumCoverageRatio
            return alternativeIsPlausible &&
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
            candidateCount: (profile?.candidateCount ?? 0) + (correlation?.candidateCount ?? 0),
            elapsedMilliseconds: elapsedMilliseconds(since: startedAt)
        )
    }

    private func elapsedMilliseconds(since startedAt: UInt64) -> Double {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        return Double(elapsed) / 1_000_000
    }

    /// The row-profile pass already compares luminance, variance, edge energy,
    /// and sampled pixel structure. For a strong, clearly separated result,
    /// launching the much broader two-dimensional search only adds latency.
    private func isDecisiveProfileMatch(
        _ profile: RowProfileResult,
        allowedDrift: Double
    ) -> Bool {
        let best = profile.best
        guard
            abs(best.translation.x) <= allowedDrift,
            best.similarityScore >= 0.86,
            best.overlapPercentage >= configuration.highCoverageAcceptanceRatio,
            best.structuralScore >= configuration.minimumStructuralSimilarityThreshold
        else {
            return false
        }

        let second = profile.second
        let verticalSeparation = abs(best.translation.y - second.translation.y)
        guard verticalSeparation >= configuration.ambiguityMinimumVerticalSeparation else {
            return true
        }
        let scoreGap = best.similarityScore - second.similarityScore
        let coverageGap = best.overlapPercentage - second.overlapPercentage
        return scoreGap > 0.03 || coverageGap > 0.06
    }

    private func makeJoinResult(
        from: NormalizedImage,
        to: NormalizedImage,
        candidate: Candidate,
        backend: RegistrationBackend,
        ambiguous: Bool,
        candidateCount: Int,
        elapsedMilliseconds: Double
    ) -> JoinResult {
        let allowedDrift = Double(max(from.matchingRepresentation.width, to.matchingRepresentation.width)) * configuration.maximumCrossAxisDriftRatio
        // A weak match over only a sliver of the screenshots is too easy to
        // get from repeated rows or unrelated content. Larger overlaps use
        // the more accommodating similarity rules below.
        let thinOverlapWithWeakAgreement = candidate.overlapPercentage < 0.25 && candidate.similarityScore < 0.80
        let highCoverageMatch = candidate.overlapPercentage >= configuration.highCoverageAcceptanceRatio &&
            candidate.similarityScore >= configuration.highCoverageSimilarityThreshold
        let weakVerticalStructure = candidate.similarityScore < configuration.highSimilarityThreshold &&
            candidate.structuralScore < configuration.minimumStructuralSimilarityThreshold

        let failureReason: JoinFailureReason?
        if abs(candidate.translation.x) > allowedDrift {
            failureReason = .excessiveCrossAxisDrift
        } else if ambiguous {
            failureReason = .ambiguousMatch
        } else if candidate.overlapPercentage < configuration.minimumOverlapRatio {
            failureReason = .insufficientOverlap
        } else if (candidate.similarityScore < configuration.lowSimilarityThreshold && !highCoverageMatch) ||
                    thinOverlapWithWeakAgreement || weakVerticalStructure {
            failureReason = .lowVisualAgreement
        } else {
            failureReason = nil
        }

        let confidence: ConfidenceLevel
        if failureReason != nil {
            confidence = candidate.similarityScore >= configuration.lowSimilarityThreshold ? .low : .rejected
        } else if candidate.similarityScore >= configuration.highSimilarityThreshold {
            confidence = .high
        } else if candidate.similarityScore >= configuration.mediumSimilarityThreshold || highCoverageMatch {
            confidence = .medium
        } else {
            confidence = .low
        }

        let outputCandidate = outputScaledCandidate(candidate, from: from)
        let diagnostics = JoinDiagnostics(
            code: failureReason == nil ? "registration.accepted" : code(for: failureReason!),
            message: message(for: confidence, reason: failureReason),
            recoverySuggestion: suggestion(for: failureReason),
            similarityScore: candidate.similarityScore,
            overlapSize: PixelSize(
                width: outputCandidate.overlapWidth,
                height: outputCandidate.overlapHeight
            ),
            overlapPercentage: candidate.overlapPercentage,
            translation: outputCandidate.translation,
            crossAxisDrift: abs(outputCandidate.translation.x),
            residualError: 1.0 - candidate.similarityScore,
            backend: backend,
            ambiguousCandidates: ambiguous,
            candidateCount: candidateCount,
            elapsedMilliseconds: elapsedMilliseconds,
            failureReason: failureReason
        )

        return JoinResult(
            fromSourceID: from.source.id,
            toSourceID: to.source.id,
            transform: AffineTransformData(translation: outputCandidate.translation),
            overlapRect: outputCandidate.overlapRect,
            seam: SeamDefinition(
                axis: .horizontal,
                position: Double(outputCandidate.overlapHeight)
            ),
            confidence: confidence,
            diagnostics: diagnostics
        )
    }

    /// Registration evaluates a smaller raster, but renderer coordinates must
    /// remain in the original source pixel space.
    private func outputScaledCandidate(
        _ candidate: Candidate,
        from source: NormalizedImage
    ) -> Candidate {
        let horizontalScale = Double(source.workingPixelSize.width) /
            Double(max(1, source.matchingRepresentation.width))
        let verticalScale = Double(source.workingPixelSize.height) /
            Double(max(1, source.matchingRepresentation.height))
        return Candidate(
            translation: Point2D(
                x: candidate.translation.x * horizontalScale,
                y: candidate.translation.y * verticalScale
            ),
            overlapWidth: max(0, Int((Double(candidate.overlapWidth) * horizontalScale).rounded())),
            overlapHeight: max(0, Int((Double(candidate.overlapHeight) * verticalScale).rounded())),
            overlapPercentage: candidate.overlapPercentage,
            overlapRect: Rect2D(
                x: candidate.overlapRect.x * horizontalScale,
                y: candidate.overlapRect.y * verticalScale,
                width: candidate.overlapRect.width * horizontalScale,
                height: candidate.overlapRect.height * verticalScale
            ),
            similarityScore: candidate.similarityScore,
            profileScore: candidate.profileScore,
            structuralScore: candidate.structuralScore
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
        var structuralScore: Double = 0
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
        var seedOffsets: [Int]
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

        var variance: Double {
            guard count > 0 else { return 0 }
            let divisor = Double(count)
            let average = lhsSum / divisor
            return max(0, (lhsSquaredSum / divisor) - (average * average))
        }

        var rightVariance: Double {
            guard count > 0 else { return 0 }
            let divisor = Double(count)
            let average = rhsSum / divisor
            return max(0, (rhsSquaredSum / divisor) - (average * average))
        }
    }

    private struct DoubleSignalAccumulator {
        var count = 0
        var lhsSum = 0.0
        var rhsSum = 0.0
        var lhsSquaredSum = 0.0
        var rhsSquaredSum = 0.0
        var crossProductSum = 0.0

        mutating func append(_ lhs: Double, _ rhs: Double) {
            count += 1
            lhsSum += lhs
            rhsSum += rhs
            lhsSquaredSum += lhs * lhs
            rhsSquaredSum += rhs * rhs
            crossProductSum += lhs * rhs
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
        let minimumOffset = minimumVerticalTranslation(fromHeight: from.height, toHeight: to.height)
        guard maximumOffset >= minimumOffset else { return nil }

        let fromProfile = makeRowProfile(from)
        let toProfile = makeRowProfile(to)
        let offsetStep = max(1, min(12, min(from.height, to.height) / 80))
        var scoredOffsets: [(offset: Int, score: Double)] = []
        scoredOffsets.reserveCapacity(maximumOffset / offsetStep + 1)

        for offset in sampledValues(from: minimumOffset, through: maximumOffset, by: offsetStep) {
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
        let seedOffsets = scoredOffsets
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.001 {
                    return lhs.score > rhs.score
                }
                return lhs.offset > rhs.offset
            }
            .prefix(configuration.maximumSeedOffsets)
            .map(\.offset)

        guard var bestCandidate = evaluate(
            translation: Point2D(x: 0, y: Double(bestOffset.offset)),
            from: from,
            to: to
        ) else {
            return nil
        }
        bestCandidate.profileScore = bestOffset.score
        bestCandidate.similarityScore = min(1, max(0,
            (bestCandidate.similarityScore * 0.70) + (bestOffset.score * 0.30)
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
                candidateCount: scoredOffsets.count,
                seedOffsets: Array(seedOffsets)
            )
        }
        secondCandidate.profileScore = secondOffset.score
        secondCandidate.similarityScore = min(1, max(0,
            (secondCandidate.similarityScore * 0.70) + (secondOffset.score * 0.30)
        ))

        return RowProfileResult(
            best: bestCandidate,
            second: secondCandidate,
            candidateCount: scoredOffsets.count,
            seedOffsets: Array(seedOffsets)
        )
    }

    private func makeRowProfile(_ representation: MatchingRepresentation) -> [RowFeature] {
        guard representation.width > 0, representation.height > 0 else { return [] }

        if representation.rowMeans.count == representation.height,
           representation.rowVariances.count == representation.height,
           representation.rowEdgeEnergy.count == representation.height {
            return (0..<representation.height).map { index in
                RowFeature(
                    mean: Double(representation.rowMeans[index]),
                    variance: Double(representation.rowVariances[index]),
                    edgeEnergy: Double(representation.rowEdgeEnergy[index])
                )
            }
        }

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

        var means = DoubleSignalAccumulator()
        var variances = DoubleSignalAccumulator()
        var edges = DoubleSignalAccumulator()

        for y in 0..<overlapHeight {
            let lhs = from[offset + y]
            let rhs = to[y]
            means.append(lhs.mean, rhs.mean)
            variances.append(lhs.variance, rhs.variance)
            edges.append(lhs.edgeEnergy, rhs.edgeEnergy)
        }

        return min(1, max(0,
            (means.normalizedCorrelation * 0.45) +
            (variances.normalizedCorrelation * 0.25) +
            (edges.normalizedCorrelation * 0.30)
        ))
    }

    private func bestCorrelation(
        from: MatchingRepresentation,
        to: MatchingRepresentation,
        seedOffsets: [Int],
        preferredOffset: Int?
    ) throws -> CorrelationResult? {
        let minimumOverlap = max(2, Int(Double(min(from.height, to.height)) * configuration.minimumOverlapRatio))
        let maximumOffset = min(from.height - minimumOverlap, to.height - minimumOverlap)
        let minimumOffset = minimumVerticalTranslation(fromHeight: from.height, toHeight: to.height)
        guard maximumOffset >= minimumOffset else { return nil }

        let maximumSearchDrift = Int(Double(min(from.width, to.width)) * configuration.maximumSearchDriftRatio)
        let coarseOffsetStep = max(1, min(12, min(from.height, to.height) / 80))
        let coarseDriftStep = max(
            1,
            Int(ceil(Double(max(1, maximumSearchDrift * 2)) / Double(max(1, configuration.coarseDriftSamples - 1))))
        )
        let coarseSampleStep = max(4, max(max(from.width, from.height), max(to.width, to.height)) / 128)
        var coarseCandidateByOffset: [Int: Candidate] = [:]
        var candidateCount = 0

        func retainCoarseCandidate(_ candidate: Candidate) {
            let offset = Int(candidate.translation.y.rounded())
            if let retained = coarseCandidateByOffset[offset],
               !isPreferred(candidate, over: retained) {
                return
            }
            coarseCandidateByOffset[offset] = candidate
        }

        var offsets = seedOffsets
            .map { min(max(minimumOffset, $0), maximumOffset) }
        if let preferredOffset {
            offsets.append(min(max(minimumOffset, preferredOffset), maximumOffset))
        }
        // The profile is deliberately the main accelerator, but retain a few
        // broad anchors so a strong match is still discoverable when a page
        // has unusually repetitive row structure.
        offsets.append(contentsOf: [
            minimumOffset,
            maximumOffset,
            maximumOffset / 2,
            maximumOffset / 4,
            (maximumOffset * 3) / 4,
            maximumOffset / 6,
            (maximumOffset * 5) / 6
        ])
        if offsets.isEmpty {
            offsets = sampledValues(from: minimumOffset, through: maximumOffset, by: coarseOffsetStep)
        }
        offsets = Array(Set(offsets)).sorted()

        let coarseDrifts = sampledValues(
            from: -maximumSearchDrift,
            through: maximumSearchDrift,
            by: coarseDriftStep
        )

        for offset in offsets {
            try Task.checkCancellation()
            for drift in coarseDrifts {
                if let candidate = evaluate(
                    translation: Point2D(x: Double(drift), y: Double(offset)),
                    from: from,
                    to: to,
                    sampleStepOverride: coarseSampleStep,
                    fullScoring: false
                ) {
                    candidateCount += 1
                    retainCoarseCandidate(candidate)
                }
            }
        }

        // Row profiles are intentionally inexpensive, but repeated list rows
        // and fixed chrome can make their top seeds cluster around the wrong
        // neighborhood. Scan the full vertical range at zero drift with the
        // coarse pixel step as a bounded second chance. This keeps the search
        // practical while guaranteeing that a large, straight scroll is not
        // missed merely because its row-profile peak was weak.
        if min(from.height, to.height) >= 384 {
            for offset in sampledValues(from: minimumOffset, through: maximumOffset, by: coarseOffsetStep) {
                try Task.checkCancellation()
                if let candidate = evaluate(
                    translation: Point2D(x: 0, y: Double(offset)),
                    from: from,
                    to: to,
                    sampleStepOverride: coarseSampleStep,
                    fullScoring: false
                ) {
                    candidateCount += 1
                    retainCoarseCandidate(candidate)
                }
            }
        }

        guard !coarseCandidateByOffset.isEmpty else { return nil }
        let fineOffsetRadius = max(coarseOffsetStep, coarseOffsetStep * 2)
        let fineDriftRadius = 1
        let refinementLimit = min(from.height, to.height) >= 1_200 ? 4 : 3
        var refinementCenters: [Int] = []
        func appendCenter(_ value: Int) {
            let clamped = min(max(minimumOffset, value), maximumOffset)
            if !refinementCenters.contains(clamped) {
                refinementCenters.append(clamped)
            }
        }

        // Always reserve one refinement neighborhood for a broad anchor. The
        // row-profile pass can be dominated by repeated list rows or fixed
        // chrome, so allowing every slot to be consumed by those peaks can
        // prevent the actual scroll displacement from ever reaching the
        // full-resolution refinement pass.
        let broadAnchor = (maximumOffset * 3) / 4
        appendCenter(broadAnchor)
        let topCandidateLimit = max(0, refinementLimit - 1)
        for candidate in coarseCandidateByOffset.values
            .sorted(by: { isPreferred($0, over: $1) })
            .prefix(topCandidateLimit) {
            appendCenter(Int(candidate.translation.y.rounded()))
        }
        let broadAnchors = [
            broadAnchor,
            (maximumOffset * 5) / 6,
            maximumOffset / 2,
            maximumOffset / 4,
            minimumOffset,
            maximumOffset
        ]
        for anchor in broadAnchors where refinementCenters.count < refinementLimit {
            appendCenter(anchor)
        }
        var bestCandidate: Candidate?
        var secondCandidate: Candidate?
        for center in refinementCenters {
            let fineOffsetStart = max(minimumOffset, center - fineOffsetRadius)
            let fineOffsetEnd = min(maximumOffset, center + fineOffsetRadius)
            // Broad anchors do not necessarily have a coarse candidate at
            // the same vertical offset. In that case, using the global
            // coarse-best drift can silently clamp the refinement to the
            // horizontal search boundary and skip the actual zero-drift
            // match. Start those neighborhoods at zero drift; nearby coarse
            // candidates still provide a better local drift when available.
            let centerDrift = Int(
                (coarseCandidateByOffset[center]?.translation.x ?? 0).rounded()
            )
            let fineDriftStart = max(-maximumSearchDrift, centerDrift - fineDriftRadius)
            let fineDriftEnd = min(maximumSearchDrift, centerDrift + fineDriftRadius)

            for offset in fineOffsetStart...fineOffsetEnd {
                try Task.checkCancellation()
                for drift in fineDriftStart...fineDriftEnd {
                    if let candidate = evaluate(
                        translation: Point2D(x: Double(drift), y: Double(offset)),
                        from: from,
                        to: to
                    ) {
                        candidateCount += 1
                        updateTopCandidates(candidate, best: &bestCandidate, second: &secondCandidate)
                    }
                }
            }
        }

        guard let best = bestCandidate else { return nil }

        // One final horizontal refinement is cheap and prevents a coarse
        // drift step from leaving a visibly slanted or cropped result.
        let refinedOffset = Int(best.translation.y.rounded())
        let refinedDrift = Int(best.translation.x.rounded())
        for drift in max(-maximumSearchDrift, refinedDrift - coarseDriftStep)...min(maximumSearchDrift, refinedDrift + coarseDriftStep) {
            try Task.checkCancellation()
            if let candidate = evaluate(
                translation: Point2D(x: Double(drift), y: Double(refinedOffset)),
                from: from,
                to: to
            ) {
                candidateCount += 1
                updateTopCandidates(candidate, best: &bestCandidate, second: &secondCandidate)
            }
        }

        guard let finalBest = bestCandidate else { return nil }
        return CorrelationResult(
            best: finalBest,
            second: secondCandidate,
            candidateCount: candidateCount
        )
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

    private func updateTopCandidates(
        _ candidate: Candidate,
        best: inout Candidate?,
        second: inout Candidate?
    ) {
        guard let currentBest = best else {
            best = candidate
            return
        }

        if candidate.translation == currentBest.translation {
            if isPreferred(candidate, over: currentBest) {
                best = candidate
            }
            return
        }

        if isPreferred(candidate, over: currentBest) {
            second = currentBest
            best = candidate
            return
        }

        if let currentSecond = second,
           candidate.translation == currentSecond.translation {
            if isPreferred(candidate, over: currentSecond) {
                second = candidate
            }
            return
        }

        if let currentSecond = second {
            guard isPreferred(candidate, over: currentSecond) else {
                return
            }
        }
        second = candidate
    }

    private func sampledValues(from lowerBound: Int, through upperBound: Int, by step: Int) -> [Int] {
        let safeStep = max(1, step)
        var values = Array(stride(from: lowerBound, through: upperBound, by: safeStep))
        if values.last != upperBound {
            values.append(upperBound)
        }
        return values
    }

    private func minimumVerticalTranslation(from: NormalizedImage, to: NormalizedImage) -> Int {
        minimumVerticalTranslation(
            fromHeight: from.matchingRepresentation.height,
            toHeight: to.matchingRepresentation.height
        )
    }

    private func minimumVerticalTranslation(fromHeight: Int, toHeight: Int) -> Int {
        let shorterHeight = max(1, min(fromHeight, toHeight))
        return max(
            1,
            Int((Double(shorterHeight) * configuration.minimumVerticalTranslationRatio).rounded(.up))
        )
    }

    private func evaluate(
        translation: Point2D,
        from: MatchingRepresentation,
        to: MatchingRepresentation,
        sampleStepOverride: Int? = nil,
        fullScoring: Bool = true
    ) -> Candidate? {
        let offset = Int(translation.y.rounded())
        let drift = Int(translation.x.rounded())
        let minimumOffset = minimumVerticalTranslation(fromHeight: from.height, toHeight: to.height)
        guard offset >= minimumOffset else { return nil }

        let fromStartX = max(0, drift)
        let toStartX = max(0, -drift)
        let overlapWidth = min(from.width - fromStartX, to.width - toStartX)
        let overlapHeight = min(from.height - offset, to.height)
        guard overlapWidth >= 2, overlapHeight >= 2 else { return nil }

        let topInset = min(
            overlapHeight / 4,
            Int((Double(min(from.height, to.height)) * configuration.matchingTopExclusionRatio).rounded())
        )
        let bottomInset = min(
            max(0, overlapHeight - topInset - 2),
            Int((Double(min(from.height, to.height)) * configuration.matchingBottomExclusionRatio).rounded())
        )
        let scoreStartY = topInset
        let scoreHeight = overlapHeight - topInset - bottomInset
        guard scoreHeight >= 2 else { return nil }

        let sampleStep = sampleStepOverride ?? max(1, max(overlapWidth, overlapHeight) / 256)
        let tileCount = min(6, max(2, scoreHeight / max(16, sampleStep * 16)))
        var luminanceTiles = [SignalAccumulator](repeating: SignalAccumulator(), count: tileCount)
        var edgeTiles = [SignalAccumulator](repeating: SignalAccumulator(), count: tileCount)
        var verticalStructureTiles = [SignalAccumulator](repeating: SignalAccumulator(), count: tileCount)
        var luminance = SignalAccumulator()

        for y in stride(from: scoreStartY, to: scoreStartY + scoreHeight, by: sampleStep) {
            let localY = y - scoreStartY
            let tileIndex = min(tileCount - 1, (localY * tileCount) / max(1, scoreHeight))
            for x in stride(from: 0, to: overlapWidth, by: sampleStep) {
                let left = from[fromStartX + x, offset + y]
                let right = to[toStartX + x, y]
                luminance.append(left, right)
                luminanceTiles[tileIndex].append(left, right)
                edgeTiles[tileIndex].append(
                    from.edge(atX: fromStartX + x, y: offset + y),
                    to.edge(atX: toStartX + x, y: y)
                )
                verticalStructureTiles[tileIndex].append(
                    from.verticalGradient(atX: fromStartX + x, y: offset + y),
                    to.verticalGradient(atX: toStartX + x, y: y)
                )
            }
        }

        guard luminance.count > 0 else { return nil }
        let luminanceScore: Double
        if fullScoring {
            luminanceScore = robustSignalScore(
                luminance,
                from: from,
                to: to,
                fromStartX: fromStartX,
                toStartX: toStartX,
                offset: offset,
                overlapWidth: overlapWidth,
                startY: scoreStartY,
                scoreHeight: scoreHeight,
                sampleStep: sampleStep
            )
        } else {
            luminanceScore = luminance.normalizedCorrelation
        }
        let edgeScore = median(edgeTiles.map(\.normalizedCorrelation))
        let structuralScore = median(verticalStructureTiles.map(\.normalizedCorrelation))
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
            similarityScore: similarity,
            structuralScore: structuralScore
        )
    }

    private func robustSignalScore(
        _ accumulator: SignalAccumulator,
        from: MatchingRepresentation,
        to: MatchingRepresentation,
        fromStartX: Int,
        toStartX: Int,
        offset: Int,
        overlapWidth: Int,
        startY: Int,
        scoreHeight: Int,
        sampleStep: Int
    ) -> Double {
        guard accumulator.count > 0 else { return 0 }

        let correlation = accumulator.normalizedCorrelation
        let lhsStandardDeviation = sqrt(accumulator.variance)
        let rhsStandardDeviation = sqrt(accumulator.rightVariance)
        let normalizationScale = max(0.035, (lhsStandardDeviation + rhsStandardDeviation) * 0.5)
        let outlierLimit = normalizationScale * 1.75
        var cappedDifference: Double = 0
        let lhsMean = accumulator.lhsSum / Double(accumulator.count)
        let rhsMean = accumulator.rhsSum / Double(accumulator.count)
        for y in stride(from: startY, to: startY + scoreHeight, by: sampleStep) {
            for x in stride(from: 0, to: overlapWidth, by: sampleStep) {
                let left = Double(from[fromStartX + x, offset + y]) - lhsMean
                let right = Double(to[toStartX + x, y]) - rhsMean
                cappedDifference += min(abs(left - right), outlierLimit)
            }
        }
        let normalizedDifference = cappedDifference / Double(accumulator.count) / normalizationScale
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
        suggestion: String,
        elapsedMilliseconds: Double = 0
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
            elapsedMilliseconds: elapsedMilliseconds,
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
            case .unsupportedDirection: "This registration path expects vertical coordinate space."
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
        case .unsupportedDirection: "Use the direction control in the stitch workflow."
        }
    }
}
