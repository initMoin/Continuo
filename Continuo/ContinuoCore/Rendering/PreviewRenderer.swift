import CoreGraphics
import Foundation

public struct PreviewRenderer: Sendable {
    public var exportSettings: ExportSettings
    private let pixelCompositor: PixelCompositor

    public init(
        exportSettings: ExportSettings = ExportSettings(),
        pixelCompositor: PixelCompositor = PixelCompositor()
    ) {
        self.exportSettings = exportSettings
        self.pixelCompositor = pixelCompositor
    }

    public func render(sources: [NormalizedImage], joins: [JoinResult]) throws -> StitchPreview {
        try Task.checkCancellation()
        guard !sources.isEmpty else { throw ContinuoError.renderingFailed("There are no normalized sources to render.") }

        var framesInOrder: [Rect2D] = []
        var current = Rect2D(x: 0, y: 0, width: Double(sources[0].workingPixelSize.width), height: Double(sources[0].workingPixelSize.height))
        framesInOrder.append(current)

        for index in 1..<sources.count {
            try Task.checkCancellation()
            guard let join = joins.first(where: { $0.toSourceID == sources[index].source.id }) else {
                throw ContinuoError.renderingFailed("The preview is missing a join for source \(sources[index].source.filename ?? sources[index].source.id.uuidString).")
            }
            let sourceSize = sources[index].workingPixelSize
            current = Rect2D(
                x: current.x + join.transform.tx,
                y: current.y + join.transform.ty,
                width: Double(sourceSize.width),
                height: Double(sourceSize.height)
            )
            framesInOrder.append(current)
        }

        let minimumX = framesInOrder.map(\.x).min() ?? 0
        let minimumY = framesInOrder.map(\.y).min() ?? 0
        // Registration may return subpixel residuals. The final screenshot is
        // an integer pixel artifact, so align frame origins once here and pass
        // only those integer coordinates to the compositor. The registration
        // diagnostics retain the residual error for review.
        let translatedFrames = framesInOrder.map {
            Rect2D(
                x: ($0.x - minimumX).rounded(.toNearestOrAwayFromZero),
                y: ($0.y - minimumY).rounded(.toNearestOrAwayFromZero),
                width: $0.width.rounded(.toNearestOrAwayFromZero),
                height: $0.height.rounded(.toNearestOrAwayFromZero)
            )
        }
        let canvasWidth = Int(ceil(translatedFrames.map { $0.x + $0.width }.max() ?? 0))
        let canvasHeight = Int(ceil(translatedFrames.map { $0.y + $0.height }.max() ?? 0))
        let canvasSize = PixelSize(width: canvasWidth, height: canvasHeight)

        guard canvasWidth > 0, canvasHeight > 0 else {
            throw ContinuoError.renderingFailed("The calculated preview has no visible pixels.")
        }
        guard canvasWidth <= exportSettings.maximumWidth,
              canvasHeight <= exportSettings.maximumHeight,
              canvasSize.area <= exportSettings.maximumPixelCount else {
            throw ContinuoError.outputTooLarge(canvasSize)
        }

        var seamPositions = [Double](repeating: 0, count: sources.count)
        for (index, source) in sources.enumerated() where index > 0 {
            try Task.checkCancellation()
            let frame = translatedFrames[index]

            guard joins.first(where: { $0.toSourceID == source.source.id }) != nil else {
                throw ContinuoError.renderingFailed(
                    "The preview is missing a join for source \(source.source.filename ?? source.source.id.uuidString)."
                )
            }

            let previous = sources[index - 1]
            let previousFrame = translatedFrames[index - 1]
            let overlapStartX = max(previousFrame.x, frame.x)
            let overlapEndX = min(previousFrame.x + previousFrame.width, frame.x + frame.width)
            let overlapStartY = max(previousFrame.y, frame.y)
            let overlapEndY = min(previousFrame.y + previousFrame.height, frame.y + frame.height)
            let overlapWidth = max(0, overlapEndX - overlapStartX)
            let overlapHeight = max(0, overlapEndY - overlapStartY)

            guard overlapWidth > 0, overlapHeight > 0 else {
                throw ContinuoError.renderingFailed(
                    "The proposed join for \(source.source.filename ?? source.source.id.uuidString) leaves a gap instead of an overlap."
                )
            }

            let overlapStartInSource = max(0, overlapStartY - frame.y)
            let overlapEndInSource = min(frame.height, overlapEndY - frame.y)
            seamPositions[index] = try surgicalSeamPosition(
                previous: previous,
                incoming: source,
                previousFrame: previousFrame,
                incomingFrame: frame,
                overlapStartX: overlapStartX,
                overlapEndX: overlapEndX,
                overlapStartInSource: overlapStartInSource,
                overlapEndInSource: overlapEndInSource
            )
        }

        let image: CGImage
        do {
            image = try pixelCompositor.compose(
                images: sources.map(\.image),
                frames: translatedFrames,
                seamPositions: seamPositions
            )
        } catch let error as PixelCompositingError {
            throw ContinuoError.pixelCompositingFailed(error)
        }

        let placements = zip(sources, translatedFrames).map { SourcePlacement(sourceID: $0.0.source.id, frame: $0.1) }
        return StitchPreview(image: image, pixelSize: canvasSize, placements: placements, joins: joins)
    }

    private func surgicalSeamPosition(
        previous: NormalizedImage,
        incoming: NormalizedImage,
        previousFrame: Rect2D,
        incomingFrame: Rect2D,
        overlapStartX: Double,
        overlapEndX: Double,
        overlapStartInSource: Double,
        overlapEndInSource: Double
    ) throws -> Double {
        let overlapHeight = overlapEndInSource - overlapStartInSource
        guard overlapHeight >= 4 else {
            return overlapStartInSource + (overlapHeight / 2)
        }

        let firstCandidate = Int(ceil(overlapStartInSource)) + 1
        let lastCandidate = Int(floor(overlapEndInSource)) - 1
        guard firstCandidate <= lastCandidate else {
            return overlapStartInSource + (overlapHeight / 2)
        }

        let xStart = Int(ceil(overlapStartX))
        let xEnd = Int(floor(overlapEndX)) - 1
        let xStep = max(1, (xEnd - xStart + 1) / 512)
        let previousRepresentation = previous.matchingRepresentation
        let incomingRepresentation = incoming.matchingRepresentation
        let searchStep = max(1, Int(overlapHeight) / 512)
        var bestY = Double(firstCandidate)
        var bestCost = Double.greatestFiniteMagnitude

        func cost(for candidateY: Int) -> Double? {
            let incomingY = min(incomingRepresentation.height - 1, max(0, candidateY))
            let previousY = min(
                previousRepresentation.height - 1,
                max(0, Int((incomingFrame.y + Double(candidateY) - previousFrame.y).rounded()))
            )
            var disagreement = 0.0
            var detail = 0.0
            var sampleCount = 0

            for outputX in stride(from: xStart, through: xEnd, by: xStep) {
                let previousX = min(
                    previousRepresentation.width - 1,
                    max(0, Int((Double(outputX) - previousFrame.x).rounded()))
                )
                let incomingX = min(
                    incomingRepresentation.width - 1,
                    max(0, Int((Double(outputX) - incomingFrame.x).rounded()))
                )
                let previousValue = previousRepresentation[previousX, previousY]
                let incomingValue = incomingRepresentation[incomingX, incomingY]
                disagreement += min(1.0, Double(abs(previousValue - incomingValue)))
                detail += Double(
                    previousRepresentation.edge(atX: previousX, y: previousY) +
                    incomingRepresentation.edge(atX: incomingX, y: incomingY)
                ) * 0.5
                sampleCount += 1
            }

            guard sampleCount > 0 else { return nil }
            let normalizedDisagreement = disagreement / Double(sampleCount)
            let normalizedDetail = min(1.0, detail / Double(sampleCount))
            let distanceFromCenter = abs(Double(candidateY) - (overlapStartInSource + overlapHeight / 2)) / overlapHeight
            return (normalizedDisagreement * 0.60) + (normalizedDetail * 0.35) + (distanceFromCenter * 0.05)
        }

        func consider(_ candidateY: Int) {
            guard let cost = cost(for: candidateY) else { return }
            if cost < bestCost - 0.0001 ||
                (abs(cost - bestCost) <= 0.0001 &&
                    abs(Double(candidateY) - (overlapStartInSource + overlapHeight / 2)) <
                    abs(bestY - (overlapStartInSource + overlapHeight / 2))) {
                bestCost = cost
                bestY = Double(candidateY)
            }
        }

        for candidateY in stride(from: firstCandidate, through: lastCandidate, by: searchStep) {
            if candidateY.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            consider(candidateY)
        }
        if (lastCandidate - firstCandidate) % searchStep != 0 {
            consider(lastCandidate)
        }

        guard searchStep > 1 else { return bestY }

        let phaseStart = firstCandidate + max(1, searchStep / 2)
        if phaseStart <= lastCandidate {
            for candidateY in stride(from: phaseStart, through: lastCandidate, by: searchStep) {
                if candidateY.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                consider(candidateY)
            }
            if (lastCandidate - phaseStart) % searchStep != 0 {
                consider(lastCandidate)
            }
        }

        let refinementStart = max(firstCandidate, Int(bestY) - searchStep)
        let refinementEnd = min(lastCandidate, Int(bestY) + searchStep)
        for candidateY in refinementStart...refinementEnd {
            if candidateY.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            consider(candidateY)
        }

        return bestY
    }

}
