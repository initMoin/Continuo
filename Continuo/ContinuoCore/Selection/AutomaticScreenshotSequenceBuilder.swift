import Foundation

public struct AutomaticScreenshotSequenceBuilder: Sendable {
    public var configuration: AutomaticScreenshotSelectionConfiguration
    public var normalizer: ImageNormalizer
    public var registrar: PairwiseRegistrar

    public init(
        configuration: AutomaticScreenshotSelectionConfiguration = AutomaticScreenshotSelectionConfiguration(),
        normalizer: ImageNormalizer = ImageNormalizer(),
        registrar: PairwiseRegistrar = PairwiseRegistrar()
    ) {
        self.configuration = configuration
        self.normalizer = normalizer
        self.registrar = registrar
    }

    public func select(
        from sources: [SourceImage],
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) async throws -> AutomaticScreenshotSequenceSelection {
        let orderedSources = sources.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.captureDate, rhs.element.captureDate) {
                case let (left?, right?) where left != right:
                    return left < right
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
            .prefix(configuration.maximumCandidateCount)

        let candidates = Array(orderedSources)
        guard candidates.count >= configuration.minimumSequenceLength else {
            throw ContinuoError.noMatchingScreenshotSequence
        }

        var pairCount = 0
        for startIndex in candidates.indices {
            let endIndex = min(
                candidates.count - 1,
                startIndex + configuration.maximumLookahead
            )
            guard startIndex < endIndex else {
                continue
            }

            for nextIndex in (startIndex + 1)...endIndex {
                let from = candidates[startIndex]
                let to = candidates[nextIndex]
                guard
                    temporallyCompatible(from: from, to: to),
                    dimensionsCompatible(from: from, to: to)
                else {
                    continue
                }
                pairCount += 2
            }
        }

        guard pairCount > 0 else {
            throw ContinuoError.noMatchingScreenshotSequence
        }

        var normalizedByID: [UUID: NormalizedImage] = [:]
        normalizedByID.reserveCapacity(configuration.maximumLookahead + 1)
        var joins: [JoinResult] = []
        joins.reserveCapacity(pairCount)
        var completedPairs = 0
        var normalizedCount = 0

        progress(StitchProgress(
            stage: .normalizing,
            completed: 0,
            total: candidates.count,
            message: "Preparing candidate screenshots…"
        ))

        // Keep only the current source and the bounded lookahead window in
        // memory. Automatic discovery may inspect dozens of full-resolution
        // screenshots, so retaining every decoded image would defeat the
        // engine's memory constraints.
        for startIndex in candidates.indices {
            try Task.checkCancellation()
            let endIndex = min(
                candidates.count - 1,
                startIndex + configuration.maximumLookahead
            )
            guard startIndex < endIndex else {
                continue
            }

            for nextIndex in (startIndex + 1)...endIndex {
                let fromSource = candidates[startIndex]
                let toSource = candidates[nextIndex]
                guard
                    temporallyCompatible(from: fromSource, to: toSource),
                    dimensionsCompatible(from: fromSource, to: toSource)
                else {
                    continue
                }

                try Task.checkCancellation()
                let from: NormalizedImage
                if let cached = normalizedByID[fromSource.id] {
                    from = cached
                } else {
                    from = try normalizer.normalize(fromSource)
                    normalizedByID[fromSource.id] = from
                    normalizedCount += 1
                    progress(StitchProgress(
                        stage: .normalizing,
                        completed: normalizedCount,
                        total: candidates.count,
                        message: "Prepared candidate screenshot \(normalizedCount) of \(candidates.count)."
                    ))
                }

                let to: NormalizedImage
                if let cached = normalizedByID[toSource.id] {
                    to = cached
                } else {
                    to = try normalizer.normalize(toSource)
                    normalizedByID[toSource.id] = to
                    normalizedCount += 1
                    progress(StitchProgress(
                        stage: .normalizing,
                        completed: normalizedCount,
                        total: candidates.count,
                        message: "Prepared candidate screenshot \(normalizedCount) of \(candidates.count)."
                    ))
                }

                for pair in [(from: from, to: to), (from: to, to: from)] {
                    completedPairs += 1
                    progress(StitchProgress(
                        stage: .registering,
                        completed: completedPairs - 1,
                        total: pairCount,
                        message: "Comparing nearby screenshots \(completedPairs) of \(pairCount)…"
                    ))
                    joins.append(try await registrar.register(from: pair.from, to: pair.to))
                    progress(StitchProgress(
                        stage: .registering,
                        completed: completedPairs,
                        total: pairCount,
                        message: "Compared nearby screenshots \(completedPairs) of \(pairCount)."
                    ))
                }
            }

            let nextStart = startIndex + 1
            guard nextStart < candidates.count else {
                normalizedByID.removeAll()
                continue
            }
            let keepEnd = min(
                candidates.count - 1,
                nextStart + configuration.maximumLookahead
            )
            let retainedIDs = Set(candidates[nextStart...keepEnd].map(\.id))
            normalizedByID = normalizedByID.filter { retainedIDs.contains($0.key) }
        }

        guard let selection = AutomaticScreenshotSequenceSelector(configuration: configuration)
            .select(sources: candidates, joins: joins)
        else {
            throw ContinuoError.noMatchingScreenshotSequence
        }
        return selection
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
}
