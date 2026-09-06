import Foundation

public struct AutomaticScreenshotSequenceBuilder: Sendable {
    public var configuration: AutomaticScreenshotSelectionConfiguration
    public var normalizer: ImageNormalizer
    public var registrar: PairwiseRegistrar
    public var maximumConcurrentRegistrations: Int

    public init(
        configuration: AutomaticScreenshotSelectionConfiguration = AutomaticScreenshotSelectionConfiguration(),
        normalizer: ImageNormalizer = ImageNormalizer(),
        registrar: PairwiseRegistrar = PairwiseRegistrar(),
        maximumConcurrentRegistrations: Int = 2
    ) {
        self.configuration = configuration
        self.normalizer = normalizer
        self.registrar = registrar
        self.maximumConcurrentRegistrations = max(1, maximumConcurrentRegistrations)
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

        let candidatePairs = makeCandidatePairs(in: candidates)
        guard !candidatePairs.isEmpty else {
            throw ContinuoError.noMatchingScreenshotSequence
        }

        var normalizedByID: [UUID: NormalizedImage] = [:]
        normalizedByID.reserveCapacity(candidates.count)

        progress(StitchProgress(
            stage: .normalizing,
            completed: 0,
            total: candidates.count,
            message: "Preparing candidate screenshots…"
        ))

        // The Photos adapter has already reduced discovery to one bounded
        // session of small previews, so normalizing each candidate once avoids
        // repeated decode work while keeping memory use predictable.
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            normalizedByID[candidate.id] = try normalizer.normalize(candidate)
            progress(StitchProgress(
                stage: .normalizing,
                completed: index + 1,
                total: candidates.count,
                message: "Prepared candidate screenshot \(index + 1) of \(candidates.count)."
            ))
        }

        let selector = AutomaticScreenshotSequenceSelector(configuration: configuration)
        let forwardJoins = try await register(
            candidatePairs,
            candidates: candidates,
            normalizedByID: normalizedByID,
            reverseDirection: false,
            progress: progress
        )
        if let selection = selector.select(sources: candidates, joins: forwardJoins) {
            return selection
        }

        // Most screenshot sequences follow capture chronology. Only pay for
        // reverse registration when that common path produced no accepted
        // sequence.
        let reverseJoins = try await register(
            candidatePairs,
            candidates: candidates,
            normalizedByID: normalizedByID,
            reverseDirection: true,
            progress: progress
        )
        guard let selection = selector.select(
            sources: candidates,
            joins: forwardJoins + reverseJoins
        ) else {
            throw ContinuoError.noMatchingScreenshotSequence
        }
        return selection
    }

    private func makeCandidatePairs(
        in candidates: [SourceImage]
    ) -> [(fromIndex: Int, toIndex: Int)] {
        var pairs: [(fromIndex: Int, toIndex: Int)] = []
        for startIndex in candidates.indices {
            let endIndex = min(
                candidates.count - 1,
                startIndex + configuration.maximumLookahead
            )
            guard startIndex < endIndex else { continue }

            for nextIndex in (startIndex + 1)...endIndex {
                let from = candidates[startIndex]
                let to = candidates[nextIndex]
                guard
                    temporallyCompatible(from: from, to: to),
                    dimensionsCompatible(from: from, to: to)
                else {
                    continue
                }
                pairs.append((fromIndex: startIndex, toIndex: nextIndex))
            }
        }
        return pairs
    }

    private func register(
        _ pairs: [(fromIndex: Int, toIndex: Int)],
        candidates: [SourceImage],
        normalizedByID: [UUID: NormalizedImage],
        reverseDirection: Bool,
        progress: @escaping @Sendable (StitchProgress) -> Void
    ) async throws -> [JoinResult] {
        let workItems = pairs.compactMap { pair -> RegistrationWorkItem? in
            guard
                candidates.indices.contains(pair.fromIndex),
                candidates.indices.contains(pair.toIndex),
                let chronologicalFrom = normalizedByID[candidates[pair.fromIndex].id],
                let chronologicalTo = normalizedByID[candidates[pair.toIndex].id]
            else {
                return nil
            }
            return RegistrationWorkItem(
                from: reverseDirection ? chronologicalTo : chronologicalFrom,
                to: reverseDirection ? chronologicalFrom : chronologicalTo
            )
        }
        guard !workItems.isEmpty else { return [] }

        let registrar = registrar
        let concurrency = min(maximumConcurrentRegistrations, workItems.count)
        let directionDescription = reverseDirection ? " in reverse order" : ""
        var joins = [JoinResult?](repeating: nil, count: workItems.count)
        var nextWorkIndex = 0
        var completed = 0
        progress(StitchProgress(
            stage: .registering,
            completed: 0,
            total: workItems.count,
            message: "Comparing nearby screenshots\(directionDescription)…"
        ))

        try await withThrowingTaskGroup(of: (Int, JoinResult).self) { group in
            for _ in 0..<concurrency {
                let resultIndex = nextWorkIndex
                let work = workItems[resultIndex]
                nextWorkIndex += 1
                group.addTask {
                    (resultIndex, try await registrar.register(from: work.from, to: work.to))
                }
            }

            while let (resultIndex, join) = try await group.next() {
                joins[resultIndex] = join
                completed += 1
                progress(StitchProgress(
                    stage: .registering,
                    completed: completed,
                    total: workItems.count,
                    message: "Compared \(completed) of \(workItems.count) nearby screenshots\(directionDescription)."
                ))

                guard nextWorkIndex < workItems.count else { continue }
                let nextResultIndex = nextWorkIndex
                let work = workItems[nextResultIndex]
                nextWorkIndex += 1
                group.addTask {
                    (nextResultIndex, try await registrar.register(from: work.from, to: work.to))
                }
            }
        }

        return joins.compactMap { $0 }
    }

    private struct RegistrationWorkItem: Sendable {
        let from: NormalizedImage
        let to: NormalizedImage
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
