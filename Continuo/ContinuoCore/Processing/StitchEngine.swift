import CoreGraphics
import Foundation
import OSLog

public struct StitchEngine: Sendable {
    private static let logger = Logger(
        subsystem: "dev.iamshift.Continuo",
        category: "mapping-performance"
    )

    public var normalizer: ImageNormalizer
    public var registrar: PairwiseRegistrar
    public var renderer: PreviewRenderer
    public var maximumConcurrentRegistrations: Int
    public var mappingPreviewMaximumPixelSize: Int
    public var direction: StitchDirection

    public init(
        normalizer: ImageNormalizer = ImageNormalizer(),
        registrar: PairwiseRegistrar = PairwiseRegistrar(),
        renderer: PreviewRenderer = PreviewRenderer(),
        maximumConcurrentRegistrations: Int = 3,
        mappingPreviewMaximumPixelSize: Int = 640,
        direction: StitchDirection = .vertical
    ) {
        self.normalizer = normalizer
        self.registrar = registrar
        self.renderer = renderer
        self.maximumConcurrentRegistrations = max(1, maximumConcurrentRegistrations)
        self.mappingPreviewMaximumPixelSize = max(320, mappingPreviewMaximumPixelSize)
        self.direction = direction
    }

    public func stitch(
        sources: [SourceImage],
        precomputedJoins: [JoinResult]? = nil,
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) async throws -> StitchPreview {
        do {
            let stitchStartedAt = DispatchTime.now().uptimeNanoseconds
            let activeSources = try validatedSources(from: sources)
            let normalizationStartedAt = DispatchTime.now().uptimeNanoseconds
            let normalized = try normalize(activeSources, direction: direction, progress: progress)
            let normalizationMilliseconds = elapsedMilliseconds(since: normalizationStartedAt)
            let joins: [JoinResult]
            let mappingMilliseconds: Double
            if let precomputedJoins,
               joinsMatch(precomputedJoins, sources: activeSources) {
                joins = precomputedJoins
                mappingMilliseconds = 0
            } else {
                let mappingStartedAt = DispatchTime.now().uptimeNanoseconds
                joins = try await map(
                    normalized,
                    maximumConcurrentRegistrations: maximumConcurrentRegistrations,
                    direction: direction,
                    progress: progress
                )
                mappingMilliseconds = elapsedMilliseconds(since: mappingStartedAt)
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
            let renderingStartedAt = DispatchTime.now().uptimeNanoseconds
            let normalizer = normalizer
            let preview = try renderer.render(
                sources: normalized,
                joins: joins,
                imageProvider: { index in
                    try Task.checkCancellation()
                    let image = DirectionalImageAdapter.renderingImage(
                        try normalizer.makeRenderingImage(activeSources[index]),
                        for: direction
                    )
                    progress(StitchProgress(
                        stage: .rendering,
                        completed: index + 1,
                        total: activeSources.count,
                        message: "Rendered screenshot \(index + 1) of \(activeSources.count)."
                    ))
                    return image
                }
            )
            let renderingMilliseconds = elapsedMilliseconds(since: renderingStartedAt)
            let outputImage: CGImage
            let outputPixelSize: PixelSize
            if direction == .horizontal {
                let cropped = DirectionalImageAdapter.cropHorizontalCrossAxis(
                    preview.image,
                    placements: preview.placements
                )
                outputImage = DirectionalImageAdapter.outputImage(cropped, for: direction)
                outputPixelSize = PixelSize(width: cropped.height, height: cropped.width)
            } else {
                outputImage = preview.image
                outputPixelSize = preview.pixelSize
            }
            progress(StitchProgress(stage: .complete, completed: 1, total: 1, message: "Preview ready."))
            Self.logger.info(
                "Stitch completed: sources=\(activeSources.count), direction=\(direction.rawValue, privacy: .public), normalization_ms=\(normalizationMilliseconds, privacy: .public), mapping_ms=\(mappingMilliseconds, privacy: .public), rendering_ms=\(renderingMilliseconds, privacy: .public), total_ms=\(elapsedMilliseconds(since: stitchStartedAt), privacy: .public)."
            )
            return StitchPreview(
                image: outputImage,
                pixelSize: outputPixelSize,
                placements: preview.placements,
                joins: preview.joins
            )
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

            let computedJoins = try await scanPairs(
                in: activeSources,
                at: missingPairIndices,
                direction: direction
            )
            for (pairIndex, join) in computedJoins {
                orderedJoins[pairIndex] = join
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
        direction: StitchDirection,
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
            normalized.append(
                DirectionalImageAdapter.matchingImage(
                    try normalizer.normalizeForMatching(source),
                    for: direction
                )
            )
            progress(StitchProgress(
                stage: .normalizing,
                completed: index + 1,
                total: sources.count,
                message: "Prepared screenshot \(index + 1) of \(sources.count)."
            ))
        }
        return normalized
    }

    private func map(
        _ normalized: [NormalizedImage],
        maximumConcurrentRegistrations: Int,
        direction: StitchDirection,
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) async throws -> [JoinResult] {
        let joinCount = max(0, normalized.count - 1)
        guard joinCount > 0 else { return [] }

        let concurrency = min(joinCount, max(1, maximumConcurrentRegistrations))
        let registrar = registrarForDirection(direction)
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
                    return (index, try await registrar.register(from: from, to: to, direction: direction))
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
                    return (next, try await registrar.register(from: from, to: to, direction: direction))
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

    private func scanPairs(
        in sources: [SourceImage],
        at pairIndices: [Int],
        direction: StitchDirection
    ) async throws -> [Int: JoinResult] {
        let scanStartedAt = DispatchTime.now().uptimeNanoseconds
        let sourceIndices = Set(pairIndices.flatMap { [$0, $0 + 1] })
        let previewNormalizer = ImageNormalizer(configuration: ImageNormalizationConfiguration(
            matchingMaximumPixelSize: min(
                normalizer.configuration.matchingMaximumPixelSize,
                mappingPreviewMaximumPixelSize
            )
        ))
        let directionalRegistrar = registrarForDirection(direction)
        var fastConfiguration = directionalRegistrar.configuration
        fastConfiguration.visionFallbackEnabled = false
        let fastRegistrar = PairwiseRegistrar(configuration: fastConfiguration)
        let requiresLandscapeVerticalRefinement = direction == .vertical && sources.contains {
            $0.pixelSize.width > $0.pixelSize.height
        }
        let previewSources = try await normalizeSources(
            sources,
            at: sourceIndices,
            using: previewNormalizer,
            direction: direction
        )
        var joins = try await registerPairs(
            pairIndices,
            normalizedByIndex: previewSources,
            registrar: fastRegistrar,
            direction: direction
        )

        let refinementPairIndices = requiresLandscapeVerticalRefinement
            ? pairIndices
            : pairIndices.filter { joins[$0]?.confidence.isAccepted != true }
        guard !refinementPairIndices.isEmpty else {
            logMappingPerformance(
                pairCount: pairIndices.count,
                previewRefinementCount: 0,
                highDetailRefinementCount: 0,
                startedAt: scanStartedAt
            )
            return joins
        }

        let previewRefinedJoins = try await registerPairs(
            refinementPairIndices,
            normalizedByIndex: previewSources,
            registrar: directionalRegistrar,
            direction: direction
        )
        joins.merge(previewRefinedJoins) { _, refined in refined }

        let highDetailPairIndices = refinementPairIndices.filter {
            requiresLandscapeVerticalRefinement || joins[$0]?.confidence.isAccepted != true
        }
        guard !highDetailPairIndices.isEmpty else {
            logMappingPerformance(
                pairCount: pairIndices.count,
                previewRefinementCount: refinementPairIndices.count,
                highDetailRefinementCount: 0,
                startedAt: scanStartedAt
            )
            return joins
        }

        let refinementSourceIndices = Set(highDetailPairIndices.flatMap { [$0, $0 + 1] })
        let refinementSources = try await normalizeSources(
            sources,
            at: refinementSourceIndices,
            using: normalizer,
            direction: direction
        )
        let refinedJoins = try await registerPairs(
            highDetailPairIndices,
            normalizedByIndex: refinementSources,
            registrar: directionalRegistrar,
            direction: direction
        )
        joins.merge(refinedJoins) { _, refined in refined }
        logMappingPerformance(
            pairCount: pairIndices.count,
            previewRefinementCount: refinementPairIndices.count,
            highDetailRefinementCount: highDetailPairIndices.count,
            startedAt: scanStartedAt
        )
        return joins
    }

    private func registrarForDirection(_ direction: StitchDirection) -> PairwiseRegistrar {
        guard direction == .horizontal else { return registrar }
        var configuration = registrar.configuration
        configuration.highSimilarityThreshold = min(configuration.highSimilarityThreshold, 0.86)
        configuration.minimumStructuralSimilarityThreshold = min(
            configuration.minimumStructuralSimilarityThreshold,
            0.44
        )
        configuration.highCoverageSimilarityThreshold = min(
            configuration.highCoverageSimilarityThreshold,
            0.50
        )
        return PairwiseRegistrar(configuration: configuration)
    }

    private func logMappingPerformance(
        pairCount: Int,
        previewRefinementCount: Int,
        highDetailRefinementCount: Int,
        startedAt: UInt64
    ) {
        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000
        Self.logger.info(
            "Mapped \(pairCount) pair(s) in \(elapsedMilliseconds, privacy: .public) ms; preview_refinements=\(previewRefinementCount), high_detail_refinements=\(highDetailRefinementCount)."
        )
    }

    private func elapsedMilliseconds(since startedAt: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }

    private func normalizeSources(
        _ sources: [SourceImage],
        at sourceIndices: Set<Int>,
        using normalizer: ImageNormalizer,
        direction: StitchDirection
    ) async throws -> [Int: NormalizedImage] {
        let orderedIndices = sourceIndices.sorted()
        let concurrency = min(maximumConcurrentRegistrations, orderedIndices.count)
        var normalizedByIndex: [Int: NormalizedImage] = [:]
        normalizedByIndex.reserveCapacity(orderedIndices.count)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: (Int, NormalizedImage).self) { group in
            for _ in 0..<concurrency {
                let sourceIndex = orderedIndices[nextIndex]
                nextIndex += 1
                let source = sources[sourceIndex]
                group.addTask {
                    (
                        sourceIndex,
                        DirectionalImageAdapter.matchingImage(
                            try normalizer.normalizeForMatching(source),
                            for: direction
                        )
                    )
                }
            }

            while let (sourceIndex, normalized) = try await group.next() {
                normalizedByIndex[sourceIndex] = normalized
                guard nextIndex < orderedIndices.count else { continue }
                let nextSourceIndex = orderedIndices[nextIndex]
                nextIndex += 1
                let source = sources[nextSourceIndex]
                group.addTask {
                    (
                        nextSourceIndex,
                        DirectionalImageAdapter.matchingImage(
                            try normalizer.normalizeForMatching(source),
                            for: direction
                        )
                    )
                }
            }
        }
        return normalizedByIndex
    }

    private func registerPairs(
        _ pairIndices: [Int],
        normalizedByIndex: [Int: NormalizedImage],
        registrar: PairwiseRegistrar,
        direction: StitchDirection
    ) async throws -> [Int: JoinResult] {
        let concurrency = min(maximumConcurrentRegistrations, pairIndices.count)
        var joins: [Int: JoinResult] = [:]
        joins.reserveCapacity(pairIndices.count)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: (Int, JoinResult).self) { group in
            for _ in 0..<concurrency {
                let pairIndex = pairIndices[nextIndex]
                nextIndex += 1
                guard
                    let from = normalizedByIndex[pairIndex],
                    let to = normalizedByIndex[pairIndex + 1]
                else {
                    throw ContinuoError.cancelled
                }
                group.addTask {
                    (pairIndex, try await registrar.register(from: from, to: to, direction: .vertical))
                }
            }

            while let (pairIndex, join) = try await group.next() {
                joins[pairIndex] = join
                guard nextIndex < pairIndices.count else { continue }
                let nextPairIndex = pairIndices[nextIndex]
                nextIndex += 1
                guard
                    let from = normalizedByIndex[nextPairIndex],
                    let to = normalizedByIndex[nextPairIndex + 1]
                else {
                    throw ContinuoError.cancelled
                }
                group.addTask {
                    (nextPairIndex, try await registrar.register(from: from, to: to, direction: .vertical))
                }
            }
        }
        return joins
    }

    private struct SourcePairKey: Hashable, Sendable {
        let from: UUID
        let to: UUID
    }
}
