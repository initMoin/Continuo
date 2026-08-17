import CoreGraphics
import Foundation

/// Errors emitted by the deterministic pixel compositor.
public enum PixelCompositingError: Error, Equatable, LocalizedError, Sendable {
    case noImages
    case countMismatch
    case invalidFrame(index: Int, frame: Rect2D)
    case frameImageSizeMismatch(index: Int, frameSize: PixelSize, imageSize: PixelSize)
    case missingOverlap(index: Int)
    case imageCreationFailed

    public var errorDescription: String? {
        switch self {
        case .noImages:
            "Continuo could not composite an empty image set."
        case .countMismatch:
            "Continuo could not match the compositing frames and seam data to the source images."
        case let .invalidFrame(index, frame):
            "The frame for screenshot \(index + 1) is not a valid pixel-aligned rectangle (\(frame.x), \(frame.y), \(frame.width), \(frame.height))."
        case let .frameImageSizeMismatch(index, frameSize, imageSize):
            "The frame for screenshot \(index + 1) is \(frameSize.width) × \(frameSize.height), but its pixels are \(imageSize.width) × \(imageSize.height)."
        case let .missingOverlap(index):
            "Screenshot \(index + 1) does not overlap the preceding screenshot."
        case .imageCreationFailed:
            "Continuo could not create the final composited image."
        }
    }
}

/// Composites normalized screenshots on an integer pixel grid.
///
/// Core Graphics is used only to decode unsupported source layouts and to
/// create the final CGImage. Ownership at the seam is decided by this type's
/// byte-level loop, so fractional clip coverage, interpolation, and implicit
/// alpha blending cannot alter screenshot pixels outside the selected seam.
public struct PixelCompositor: Sendable {
    public init() {}

    /// Composites images in top-left engine coordinates.
    ///
    /// `frames` may contain negative origins; the compositor translates the
    /// complete arrangement so the smallest x/y origin becomes zero. The
    /// first seam value is ignored and exists only to keep the arrays aligned
    /// with `images` and `frames`.
    public func compose(
        images: [CGImage],
        frames: [Rect2D],
        seamPositions: [Double]
    ) throws -> CGImage {
        try Task.checkCancellation()

        guard !images.isEmpty else {
            throw PixelCompositingError.noImages
        }
        guard images.count == frames.count,
              seamPositions.count == images.count else {
            throw PixelCompositingError.countMismatch
        }

        let pixelFrames = try frames.enumerated().map { index, frame in
            try PixelFrame(index: index, rectangle: frame)
        }
        let minimumX = pixelFrames.map(\.x).min() ?? 0
        let minimumY = pixelFrames.map(\.y).min() ?? 0
        let translatedFrames = pixelFrames.map {
            PixelFrame(x: $0.x - minimumX, y: $0.y - minimumY, width: $0.width, height: $0.height)
        }

        let canvasWidth = translatedFrames.map { $0.x + $0.width }.max() ?? 0
        let canvasHeight = translatedFrames.map { $0.y + $0.height }.max() ?? 0
        guard canvasWidth > 0, canvasHeight > 0 else {
            throw PixelCompositingError.imageCreationFailed
        }

        var output = [UInt8](repeating: 255, count: canvasWidth * canvasHeight * 4)

        for index in images.indices {
            try Task.checkCancellation()
            let source = try RGBA8Bitmap(image: images[index])
            let frame = translatedFrames[index]
            let imageSize = PixelSize(width: source.width, height: source.height)
            let frameSize = PixelSize(width: frame.width, height: frame.height)
            guard frameSize == imageSize else {
                throw PixelCompositingError.frameImageSizeMismatch(
                    index: index,
                    frameSize: frameSize,
                    imageSize: imageSize
                )
            }

            if index == 0 {
                try copyWholeImage(source, into: &output, at: frame, canvasWidth: canvasWidth)
                continue
            }

            let previousFrame = translatedFrames[index - 1]
            let overlap = overlap(of: previousFrame, and: frame)
            guard overlap.width > 0, overlap.height > 0 else {
                throw PixelCompositingError.missingOverlap(index: index)
            }

            let seamBand = makeSeamBand(
                seamPosition: seamPositions[index],
                overlap: overlap,
                incomingFrame: frame
            )

            for sourceY in 0..<source.height {
                if sourceY.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                let outputY = frame.y + sourceY

                for sourceX in 0..<source.width {
                    let outputX = frame.x + sourceX
                    let isInOverlap = outputX >= overlap.minX &&
                        outputX < overlap.maxX &&
                        outputY >= overlap.minY &&
                        outputY < overlap.maxY

                    if !isInOverlap || sourceY >= seamBand.end {
                        copyPixel(
                            from: source,
                            sourceX: sourceX,
                            sourceY: sourceY,
                            into: &output,
                            outputX: outputX,
                            outputY: outputY,
                            canvasWidth: canvasWidth
                        )
                    } else if sourceY >= seamBand.start {
                        blendPixelIfNeeded(
                            from: source,
                            sourceX: sourceX,
                            sourceY: sourceY,
                            into: &output,
                            outputX: outputX,
                            outputY: outputY,
                            canvasWidth: canvasWidth,
                            incomingAlpha: seamBand.alpha(for: sourceY)
                        )
                    }
                    // Rows before the seam deliberately retain the already
                    // composited previous result byte-for-byte.
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: canvasWidth,
                  height: canvasHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: canvasWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw PixelCompositingError.imageCreationFailed
        }

        return image
    }

    private func overlap(of first: PixelFrame, and second: PixelFrame) -> PixelRect {
        PixelRect(
            minX: max(first.x, second.x),
            minY: max(first.y, second.y),
            maxX: min(first.x + first.width, second.x + second.width),
            maxY: min(first.y + first.height, second.y + second.height)
        )
    }

    private func makeSeamBand(
        seamPosition: Double,
        overlap: PixelRect,
        incomingFrame: PixelFrame
    ) -> SeamBand {
        let overlapStartInSource = overlap.minY - incomingFrame.y
        let overlapEndInSource = overlap.maxY - incomingFrame.y
        let overlapHeight = overlapEndInSource - overlapStartInSource
        let rowCount = overlapHeight >= 8 ? min(2, overlapHeight) : 1
        let fallbackSeam = Double(overlapStartInSource) + (Double(overlapHeight) / 2)
        let requestedSeam = seamPosition.isFinite ? seamPosition : fallbackSeam
        let seamRow = min(
            overlapEndInSource - 1,
            max(overlapStartInSource, Int(requestedSeam.rounded(.toNearestOrAwayFromZero)))
        )
        let firstRow = min(
            overlapEndInSource - rowCount,
            max(overlapStartInSource, seamRow - (rowCount / 2))
        )
        return SeamBand(start: firstRow, end: firstRow + rowCount)
    }

    private func copyWholeImage(
        _ source: RGBA8Bitmap,
        into output: inout [UInt8],
        at frame: PixelFrame,
        canvasWidth: Int
    ) throws {
        for sourceY in 0..<source.height {
            if sourceY.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let sourceOffset = sourceY * source.bytesPerRow
            let outputOffset = ((frame.y + sourceY) * canvasWidth + frame.x) * 4
            output.withUnsafeMutableBytes { outputBytes in
                source.bytes.withUnsafeBytes { sourceBytes in
                    let destination = outputBytes.baseAddress!.advanced(by: outputOffset)
                    let origin = sourceBytes.baseAddress!.advanced(by: sourceOffset)
                    destination.copyMemory(from: origin, byteCount: source.width * 4)
                }
            }
        }
    }

    private func copyPixel(
        from source: RGBA8Bitmap,
        sourceX: Int,
        sourceY: Int,
        into output: inout [UInt8],
        outputX: Int,
        outputY: Int,
        canvasWidth: Int
    ) {
        let sourceOffset = (sourceY * source.bytesPerRow) + (sourceX * 4)
        let outputOffset = ((outputY * canvasWidth) + outputX) * 4
        output[outputOffset] = source.bytes[sourceOffset]
        output[outputOffset + 1] = source.bytes[sourceOffset + 1]
        output[outputOffset + 2] = source.bytes[sourceOffset + 2]
        output[outputOffset + 3] = 255
    }

    private func blendPixelIfNeeded(
        from source: RGBA8Bitmap,
        sourceX: Int,
        sourceY: Int,
        into output: inout [UInt8],
        outputX: Int,
        outputY: Int,
        canvasWidth: Int,
        incomingAlpha: Double
    ) {
        let sourceOffset = (sourceY * source.bytesPerRow) + (sourceX * 4)
        let outputOffset = ((outputY * canvasWidth) + outputX) * 4
        let alpha = min(1, max(0, incomingAlpha))

        if output[outputOffset] == source.bytes[sourceOffset],
           output[outputOffset + 1] == source.bytes[sourceOffset + 1],
           output[outputOffset + 2] == source.bytes[sourceOffset + 2] {
            // Identical overlap is copied by retaining the existing byte. This
            // avoids introducing a rounding or color-profile change in shared
            // screenshot content.
            return
        }

        for channel in 0..<3 {
            let previous = Double(output[outputOffset + channel])
            let incoming = Double(source.bytes[sourceOffset + channel])
            output[outputOffset + channel] = UInt8((previous + ((incoming - previous) * alpha)).rounded())
        }
        output[outputOffset + 3] = 255
    }
}

private struct PixelFrame: Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(index: Int, rectangle: Rect2D) throws {
        guard rectangle.x.isFinite,
              rectangle.y.isFinite,
              rectangle.width.isFinite,
              rectangle.height.isFinite,
              rectangle.width > 0,
              rectangle.height > 0 else {
            throw PixelCompositingError.invalidFrame(index: index, frame: rectangle)
        }

        let x = Int(rectangle.x.rounded(.toNearestOrAwayFromZero))
        let y = Int(rectangle.y.rounded(.toNearestOrAwayFromZero))
        let width = Int(rectangle.width.rounded(.toNearestOrAwayFromZero))
        let height = Int(rectangle.height.rounded(.toNearestOrAwayFromZero))
        guard width > 0, height > 0 else {
            throw PixelCompositingError.invalidFrame(index: index, frame: rectangle)
        }

        self.init(x: x, y: y, width: width, height: height)
    }

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

private struct PixelRect: Sendable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
}

private struct SeamBand: Sendable {
    let start: Int
    let end: Int

    func alpha(for row: Int) -> Double {
        let count = max(1, end - start)
        return Double(row - start + 1) / Double(count + 1)
    }
}

private struct RGBA8Bitmap: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init(image: CGImage) throws {
        self.width = image.width
        self.height = image.height
        self.bytesPerRow = image.width * 4

        guard image.width > 0, image.height > 0 else {
            throw PixelCompositingError.imageCreationFailed
        }

        if Self.canReadDirectly(image),
           let providerData = image.dataProvider?.data as Data?,
           providerData.count >= image.bytesPerRow * image.height {
            var directBytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            directBytes.withUnsafeMutableBytes { destinationBytes in
                providerData.withUnsafeBytes { sourceBytes in
                    for row in 0..<image.height {
                        let destination = destinationBytes.baseAddress!.advanced(by: row * image.width * 4)
                        let source = sourceBytes.baseAddress!.advanced(by: row * image.bytesPerRow)
                        destination.copyMemory(from: source, byteCount: image.width * 4)
                    }
                }
            }
            self.bytes = Self.makeOpaque(directBytes, alphaInfo: image.alphaInfo, premultiplied: image.alphaInfo == .premultipliedLast)
            return
        }

        var convertedBytes = [UInt8](repeating: 255, count: image.width * image.height * 4)
        let didCreateContext = convertedBytes.withUnsafeMutableBytes { destinationBytes -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: destinationBytes.baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            context.setShouldAntialias(false)
            context.interpolationQuality = .none
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }

        guard didCreateContext else {
            throw PixelCompositingError.imageCreationFailed
        }
        self.bytes = convertedBytes
    }

    private static func canReadDirectly(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 8,
              image.bitsPerPixel == 32,
              image.bytesPerRow >= image.width * 4,
              image.colorSpace?.name == CGColorSpace.sRGB,
              image.alphaInfo == .premultipliedLast || image.alphaInfo == .last else {
            return false
        }

        let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        return byteOrder == 0
    }

    private static func makeOpaque(_ bytes: [UInt8], alphaInfo: CGImageAlphaInfo, premultiplied: Bool) -> [UInt8] {
        guard alphaInfo != .none, alphaInfo != .noneSkipLast else {
            return bytes
        }

        var bytes = bytes
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = bytes[offset + 3]
            guard alpha < 255 else { continue }

            if premultiplied {
                let whiteContribution = 255 - Int(alpha)
                bytes[offset] = UInt8(min(255, Int(bytes[offset]) + whiteContribution))
                bytes[offset + 1] = UInt8(min(255, Int(bytes[offset + 1]) + whiteContribution))
                bytes[offset + 2] = UInt8(min(255, Int(bytes[offset + 2]) + whiteContribution))
            } else {
                let inverseAlpha = 255 - Int(alpha)
                bytes[offset] = UInt8((Int(bytes[offset]) * Int(alpha) + (255 * inverseAlpha) + 127) / 255)
                bytes[offset + 1] = UInt8((Int(bytes[offset + 1]) * Int(alpha) + (255 * inverseAlpha) + 127) / 255)
                bytes[offset + 2] = UInt8((Int(bytes[offset + 2]) * Int(alpha) + (255 * inverseAlpha) + 127) / 255)
            }
            bytes[offset + 3] = 255
        }
        return bytes
    }
}
