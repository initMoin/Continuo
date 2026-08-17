import Foundation

public struct StitchEngine: Sendable {
    public var normalizer: ImageNormalizer
    public var registrar: PairwiseRegistrar
    public var renderer: PreviewRenderer

    public init(
        normalizer: ImageNormalizer = ImageNormalizer(),
        registrar: PairwiseRegistrar = PairwiseRegistrar(),
        renderer: PreviewRenderer = PreviewRenderer()
    ) {
        self.normalizer = normalizer
        self.registrar = registrar
        self.renderer = renderer
    }

    public func stitch(
        sources: [SourceImage],
        progress: @escaping @Sendable (StitchProgress) -> Void = { _ in }
    ) async throws -> StitchPreview {
        do {
            let activeSources = sources.filter { !$0.excluded }
            guard !activeSources.isEmpty else { throw ContinuoError.noSources }
            guard activeSources.count >= 2 else { throw ContinuoError.needsAtLeastTwoSources }

            var normalized: [NormalizedImage] = []
            normalized.reserveCapacity(activeSources.count)
            for (index, source) in activeSources.enumerated() {
                try Task.checkCancellation()
                progress(StitchProgress(
                    stage: .normalizing,
                    completed: index,
                    total: activeSources.count,
                    message: "Preparing screenshot \(index + 1) of \(activeSources.count)…"
                ))
                normalized.append(try normalizer.normalize(source))
                progress(StitchProgress(
                    stage: .normalizing,
                    completed: index + 1,
                    total: activeSources.count,
                    message: "Prepared full-resolution screenshot \(index + 1) of \(activeSources.count)."
                ))
            }

            var joins: [JoinResult] = []
            joins.reserveCapacity(max(0, normalized.count - 1))
            for index in 0..<(normalized.count - 1) {
                try Task.checkCancellation()
                progress(StitchProgress(
                    stage: .registering,
                    completed: index,
                    total: normalized.count - 1,
                    message: "Mapping join \(index + 1) of \(normalized.count - 1)…"
                ))
                let join = try await registrar.register(from: normalized[index], to: normalized[index + 1])
                joins.append(join)
                guard join.confidence.isAccepted else {
                    throw ContinuoError.registrationFailed(join)
                }
                progress(StitchProgress(
                    stage: .registering,
                    completed: index + 1,
                    total: normalized.count - 1,
                    message: "Mapped join \(index + 1) of \(normalized.count - 1)."
                ))
            }

            try Task.checkCancellation()
            progress(StitchProgress(stage: .rendering, completed: 0, total: 1, message: "Rendering preview…"))
            let preview = try renderer.render(sources: normalized, joins: joins)
            progress(StitchProgress(stage: .complete, completed: 1, total: 1, message: "Preview ready."))
            return preview
        } catch is CancellationError {
            throw ContinuoError.cancelled
        }
    }
}
