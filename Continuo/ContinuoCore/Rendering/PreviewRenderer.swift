import CoreGraphics
import Foundation

public struct PreviewRenderer: Sendable {
    public var exportSettings: ExportSettings

    public init(exportSettings: ExportSettings = ExportSettings()) {
        self.exportSettings = exportSettings
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
        let translatedFrames = framesInOrder.map {
            Rect2D(x: $0.x - minimumX, y: $0.y - minimumY, width: $0.width, height: $0.height)
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

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: canvasWidth,
                  height: canvasHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: canvasWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ContinuoError.renderingFailed("Continuo could not create a preview canvas.")
        }

        context.saveGState()
        // Source pixels are already normalized for display. Keep them
        // untouched and convert only the engine's top-left frame coordinates
        // into the bitmap CGContext's bottom-left drawing coordinates.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let frame = translatedFrames[index]

            guard index > 0 else {
                draw(
                    source.image,
                    in: frame,
                    on: context,
                    canvasHeight: canvasHeight
                )
                continue
            }

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

            // The old renderer always kept the entire previous screenshot and
            // began the incoming screenshot at the bottom edge of the overlap.
            // That produced a hard, edge-only join. Find a low-disagreement,
            // low-detail seam inside the shared content instead, then feather
            // only a few pixels around that seam.
            let overlapStartInSource = max(0, overlapStartY - frame.y)
            let overlapEndInSource = min(frame.height, overlapEndY - frame.y)
            let seamY = surgicalSeamPosition(
                previous: previous,
                incoming: source,
                previousFrame: previousFrame,
                incomingFrame: frame,
                overlapStartX: overlapStartX,
                overlapEndX: overlapEndX,
                overlapStartInSource: overlapStartInSource,
                overlapEndInSource: overlapEndInSource
            )
            let featherPixels = min(4.0, max(1.0, floor(overlapHeight / 32.0)))
            let featherStart = max(overlapStartInSource, seamY - (featherPixels / 2))
            let featherEnd = min(overlapEndInSource, seamY + (featherPixels / 2))

            // Preserve incoming pixels that are outside the previous frame's
            // horizontal footprint. This matters when Vision finds a small
            // cross-axis drift instead of a perfectly vertical translation.
            if overlapStartX > frame.x {
                draw(
                    source.image,
                    in: frame,
                    on: context,
                    canvasHeight: canvasHeight,
                    clip: CGRect(
                        x: frame.x,
                        y: frame.y,
                        width: overlapStartX - frame.x,
                        height: frame.height
                    )
                )
            }
            if overlapEndX < frame.x + frame.width {
                draw(
                    source.image,
                    in: frame,
                    on: context,
                    canvasHeight: canvasHeight,
                    clip: CGRect(
                        x: overlapEndX,
                        y: frame.y,
                        width: (frame.x + frame.width) - overlapEndX,
                        height: frame.height
                    )
                )
            }

            let commonWidth = overlapEndX - overlapStartX
            if overlapStartInSource > 0 {
                draw(
                    source.image,
                    in: frame,
                    on: context,
                    canvasHeight: canvasHeight,
                    clip: CGRect(
                        x: overlapStartX,
                        y: frame.y,
                        width: commonWidth,
                        height: overlapStartInSource
                    )
                )
            }

            let featherHeight = featherEnd - featherStart
            if featherHeight > 0.01 {
                let bandCount = max(2, min(8, Int(ceil(featherHeight))))
                for bandIndex in 0..<bandCount {
                    let bandStart = featherStart + (featherHeight * Double(bandIndex) / Double(bandCount))
                    let bandEnd = featherStart + (featherHeight * Double(bandIndex + 1) / Double(bandCount))
                    let bandCenter = (bandStart + bandEnd) / 2
                    let alpha = CGFloat((bandCenter - featherStart) / featherHeight)
                    draw(
                        source.image,
                        in: frame,
                        on: context,
                        canvasHeight: canvasHeight,
                        clip: CGRect(
                            x: overlapStartX,
                            y: frame.y + bandStart,
                            width: commonWidth,
                            height: bandEnd - bandStart
                        ),
                        alpha: alpha
                    )
                }
            }

            let fullStart = max(frame.y + featherEnd, frame.y + overlapStartInSource)
            if fullStart < frame.y + frame.height {
                draw(
                    source.image,
                    in: frame,
                    on: context,
                    canvasHeight: canvasHeight,
                    clip: CGRect(
                        x: overlapStartX,
                        y: fullStart,
                        width: commonWidth,
                        height: (frame.y + frame.height) - fullStart
                    )
                )
            }
        }
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw ContinuoError.renderingFailed("Continuo could not finalize the preview image.")
        }

        let placements = zip(sources, translatedFrames).map { SourcePlacement(sourceID: $0.0.source.id, frame: $0.1) }
        return StitchPreview(image: image, pixelSize: canvasSize, placements: placements, joins: joins)
    }

    private func draw(
        _ image: CGImage,
        in frame: Rect2D,
        on context: CGContext,
        canvasHeight: Int,
        clip: CGRect? = nil,
        alpha: CGFloat = 1
    ) {
        context.saveGState()
        if let clip {
            context.clip(to: bottomLeftRect(clip, canvasHeight: canvasHeight))
        }
        context.setAlpha(alpha)
        context.draw(image, in: bottomLeftRect(frame.cgRect, canvasHeight: canvasHeight))
        context.restoreGState()
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
    ) -> Double {
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
        var bestY = overlapStartInSource + (overlapHeight / 2)
        var bestCost = Double.greatestFiniteMagnitude

        for candidateY in firstCandidate...lastCandidate {
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

            guard sampleCount > 0 else { continue }
            let normalizedDisagreement = disagreement / Double(sampleCount)
            let normalizedDetail = min(1.0, detail / Double(sampleCount))
            let distanceFromCenter = abs(Double(candidateY) - (overlapStartInSource + overlapHeight / 2)) / overlapHeight
            let cost = (normalizedDisagreement * 0.60) + (normalizedDetail * 0.35) + (distanceFromCenter * 0.05)

            if cost < bestCost - 0.0001 ||
                (abs(cost - bestCost) <= 0.0001 && abs(Double(candidateY) - (overlapStartInSource + overlapHeight / 2)) < abs(bestY - (overlapStartInSource + overlapHeight / 2))) {
                bestCost = cost
                bestY = Double(candidateY)
            }
        }

        return bestY
    }

    private func bottomLeftRect(_ topLeftRect: CGRect, canvasHeight: Int) -> CGRect {
        CGRect(
            x: topLeftRect.minX,
            y: CGFloat(canvasHeight) - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
    }
}
