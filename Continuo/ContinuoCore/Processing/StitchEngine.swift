import Foundation

public struct StitchEngine: Sendable {
    public var normalizer: ImageNormalizer
    public var registrar: PairwiseRegistrar
    public var renderer: PreviewRenderer
    public var maximumConcurrentRegistrations: Int

    public init(
        normalizer: ImageNormalizer = ImageNormalizer(),
        registrar: PairwiseRegistrar = PairwiseRegistrar(),
        renderer: PreviewRenderer = PreviewRenderer(),
        maximumConcurrentRegistrations: Int = 2
    ) {
        self.normalizer = normalizer
        self.registrar = registrar
        self.renderer = renderer
        self.maximumConcurrentRegistrations = max(1, maximumConcurrentRegistrations)
    }

    public func stitch(
        sources: [SourceImage],
        precomputedJoins: [JoinResult]? = nil,
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) async throws -> StitchPreview {
        do {
            let activeSources = try validatedSources(from: sources)
            let normalized = try normalize(activeSources, progress: progress)
            let joins: [JoinResult]
            if let precomputedJoins,
               joinsMatch(precomputedJoins, sources: activeSources) {
                joins = precomputedJoins
            } else {
                joins = try await map(
                    normalized,
                    maximumConcurrentRegistrations: maximumConcurrentRegistrations,
                    progress: progress
                )
            }

            for join in joins where !join.confidence.isAccepted {
                throw ContinuoError.registrationFailed(join)
            }

            try Task.checkCancellation()
            progress(StitchProgress(
                stage: .rendering,
                completed: 0,
                total: activeSources.count,
                message: "Rendering screenshot 1 of \(activeSources.count)…"
            ))
            let normalizer = normalizer
            let preview = try renderer.render(
                sources: normalized,
                joins: joins,
                imageProvider: { index in
                    try Task.checkCancellation()
                    let image = try normalizer.makeRenderingImage(activeSources[index])
                    progress(StitchProgress(
                        stage: .rendering,
                        completed: index + 1,
                        total: activeSources.count,
                        message: "Rendered screenshot \(index + 1) of \(activeSources.count)."
                    ))
                    return image
                }
            )
            progress(StitchProgress(stage: .complete, completed: 1, total: 1, message: "Preview ready."))
            return preview
        } catch is CancellationError {
            throw ContinuoError.cancelled
        }
    }

    /// Performs the same adjacent-pair validation used by stitching without
    /// retaining decoded source images after the task completes. Callers can
    /// safely cache the returned joins and later pass them to `stitch`.
    public func precomputeJoins(
        for sources: [SourceImage],
        reusing reusableJoins: [JoinResult] = []
    ) async throws -> [JoinResult] {
        do {
            let activeSources = try validatedSources(from: sources)
            let reusableByPair = Dictionary(
                reusableJoins.map {
                    (SourcePairKey(from: $0.fromSourceID, to: $0.toSourceID), $0)
                },
                uniquingKeysWith: { first, _ in first }
            )
            var orderedJoins = [JoinResult?](
                repeating: nil,
                count: activeSources.count - 1
            )
            var missingPairIndices: [Int] = []
            missingPairIndices.reserveCapacity(orderedJoins.count)
            for index in orderedJoins.indices {
                let key = SourcePairKey(
                    from: activeSources[index].id,
                    to: activeSources[index + 1].id
                )
                if let reusable = reusableByPair[key] {
                    orderedJoins[index] = reusable
                } else {
                    missingPairIndices.append(index)
                }
            }

            guard !missingPairIndices.isEmpty else {
                return orderedJoins.compactMap { $0 }
            }

            // Initial preparation normalizes every source once. After an
            // order edit, normalize only endpoints belonging to new edges.
            if reusableByPair.isEmpty {
                let normalized = try normalizeForMapping(activeSources)
                return try await map(
                    normalized,
                    maximumConcurrentRegistrations: min(2, maximumConcurrentRegistrations)
                )
            }

            let normalizer = normalizer
            let registrar = registrar
            let concurrency = min(
                missingPairIndices.count,
                min(2, maximumConcurrentRegistrations)
            )
            var nextWorkIndex = 0
            try await withThrowingTaskGroup(of: (Int, JoinResult).self) { group in
                for _ in 0..<concurrency {
                    let pairIndex = missingPairIndices[nextWorkIndex]
                    nextWorkIndex += 1
                    let from = activeSources[pairIndex]
                    let to = activeSources[pairIndex + 1]
                    group.addTask {
                        let normalizedFrom = try normalizer.normalizeForMatching(from)
                        let normalizedTo = try normalizer.normalizeForMatching(to)
                        return (
                            pairIndex,
                            try await registrar.register(from: normalizedFrom, to: normalizedTo)
                        )
                    }
                }

                while let (pairIndex, join) = try await group.next() {
                    orderedJoins[pairIndex] = join
                    guard nextWorkIndex < missingPairIndices.count else { continue }

                    let nextPairIndex = missingPairIndices[nextWorkIndex]
                    nextWorkIndex += 1
                    let from = activeSources[nextPairIndex]
                    let to = activeSources[nextPairIndex + 1]
                    group.addTask {
                        let normalizedFrom = try normalizer.normalizeForMatching(from)
                        let normalizedTo = try normalizer.normalizeForMatching(to)
                        return (
                            nextPairIndex,
                            try await registrar.register(from: normalizedFrom, to: normalizedTo)
                        )
                    }
                }
            }

            guard orderedJoins.allSatisfy({ $0 != nil }) else {
                throw ContinuoError.cancelled
            }
            return orderedJoins.compactMap { $0 }
        } catch is CancellationError {
            throw ContinuoError.cancelled
        }
    }

    private func validatedSources(from sources: [SourceImage]) throws -> [SourceImage] {
        let activeSources = sources.filter { !$0.excluded }
        guard !activeSources.isEmpty else { throw ContinuoError.noSources }
        guard activeSources.count >= 2 else { throw ContinuoError.needsAtLeastTwoSources }
        return activeSources
    }

    private func normalize(
        _ sources: [SourceImage],
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) throws -> [NormalizedImage] {
        var normalized: [NormalizedImage] = []
        normalized.reserveCapacity(sources.count)
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            progress(StitchProgress(
                stage: .normalizing,
                completed: index,
                total: sources.count,
                message: "Preparing screenshot \(index + 1) of \(sources.count)…"
            ))
            normalized.append(try normalizer.normalizeForMatching(source))
            progress(StitchProgress(
                stage: .normalizing,
                completed: index + 1,
                total: sources.count,
                message: "Prepared screenshot \(index + 1) of \(sources.count)."
            ))
        }
        return normalized
    }

    private func normalizeForMapping(_ sources: [SourceImage]) throws -> [NormalizedImage] {
        try normalize(sources)
    }

    private func map(
        _ normalized: [NormalizedImage],
        maximumConcurrentRegistrations: Int,
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) async throws -> [JoinResult] {
        let joinCount = max(0, normalized.count - 1)
        guard joinCount > 0 else { return [] }

        let concurrency = min(joinCount, max(1, maximumConcurrentRegistrations))
        let registrar = registrar
        var joins = [JoinResult?](repeating: nil, count: joinCount)
        var nextIndex = 0
        var completedCount = 0
        progress(StitchProgress(
            stage: .registering,
            completed: 0,
            total: joinCount,
            message: "Mapping nearby screenshots…"
        ))

        try await withThrowingTaskGroup(of: (Int, JoinResult).self) { group in
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                let from = normalized[index]
                let to = normalized[index + 1]
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await registrar.register(from: from, to: to))
                }
            }

            while let (index, join) = try await group.next() {
                joins[index] = join
                completedCount += 1
                progress(StitchProgress(
                    stage: .registering,
                    completed: completedCount,
                    total: joinCount,
                    message: "Mapped \(completedCount) of \(joinCount) nearby screenshot joins."
                ))

                guard nextIndex < joinCount else { continue }
                let next = nextIndex
                nextIndex += 1
                let from = normalized[next]
                let to = normalized[next + 1]
                group.addTask {
                    try Task.checkCancellation()
                    return (next, try await registrar.register(from: from, to: to))
                }
            }
        }

        return try joins.enumerated().map { index, join in
            guard let join else { throw ContinuoError.cancelled }
            return join
        }
    }

    private func joinsMatch(
        _ joins: [JoinResult],
        sources: [SourceImage]
    ) -> Bool {
        guard joins.count == sources.count - 1 else { return false }
        return joins.enumerated().allSatisfy { index, join in
            join.fromSourceID == sources[index].id &&
                join.toSourceID == sources[index + 1].id
        }
    }

    private struct SourcePairKey: Hashable, Sendable {
        let from: UUID
        let to: UUID
    }
}
