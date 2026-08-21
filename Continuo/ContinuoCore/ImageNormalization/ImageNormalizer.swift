import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct MatchingRepresentation: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let grayscale: [Float]
    public let edgeMagnitude: [Float]
    public let verticalGradient: [Float]
    /// Full-resolution row statistics used to seed vertical registration.
    ///
    /// These are calculated once during normalization and reused for every
    /// adjacent pair. They do not replace the source pixels or alter the
    /// registration representation; they avoid rescanning the same pixels for
    /// each pair in a multi-screenshot stitch.
    public let rowMeans: [Float]
    public let rowVariances: [Float]
    public let rowEdgeEnergy: [Float]

    public init(
        width: Int,
        height: Int,
        grayscale: [Float],
        edgeMagnitude: [Float]? = nil,
        verticalGradient: [Float]? = nil,
        rowMeans: [Float]? = nil,
        rowVariances: [Float]? = nil,
        rowEdgeEnergy: [Float]? = nil
    ) {
        self.width = width
        self.height = height
        self.grayscale = grayscale
        let resolvedEdgeMagnitude: [Float]
        if let edgeMagnitude, edgeMagnitude.count == grayscale.count {
            resolvedEdgeMagnitude = edgeMagnitude
        } else {
            resolvedEdgeMagnitude = Self.makeEdgeMagnitude(from: grayscale, width: width, height: height)
        }
        self.edgeMagnitude = resolvedEdgeMagnitude
        if let verticalGradient, verticalGradient.count == grayscale.count {
            self.verticalGradient = verticalGradient
        } else {
            self.verticalGradient = Self.makeVerticalGradient(from: grayscale, width: width, height: height)
        }

        if let rowMeans,
           let rowVariances,
           let rowEdgeEnergy,
           rowMeans.count == height,
           rowVariances.count == height,
           rowEdgeEnergy.count == height {
            self.rowMeans = rowMeans
            self.rowVariances = rowVariances
            self.rowEdgeEnergy = rowEdgeEnergy
        } else {
            let statistics = Self.makeRowStatistics(
                from: grayscale,
                edgeMagnitude: resolvedEdgeMagnitude,
                width: width,
                height: height
            )
            self.rowMeans = statistics.means
            self.rowVariances = statistics.variances
            self.rowEdgeEnergy = statistics.edgeEnergy
        }
    }

    public subscript(x: Int, y: Int) -> Float {
        grayscale[(y * width) + x]
    }

    public func edge(atX x: Int, y: Int) -> Float {
        edgeMagnitude[(y * width) + x]
    }

    public func verticalGradient(atX x: Int, y: Int) -> Float {
        verticalGradient[(y * width) + x]
    }

    private static func makeVerticalGradient(from grayscale: [Float], width: Int, height: Int) -> [Float] {
        guard width > 0, height > 0, grayscale.count == width * height else {
            return [Float](repeating: 0, count: grayscale.count)
        }

        var gradients = [Float](repeating: 0, count: grayscale.count)
        var maximum: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width) + x
                let top = grayscale[(max(0, y - 1) * width) + x]
                let bottom = grayscale[(min(height - 1, y + 1) * width) + x]
                let gradient = (bottom - top) * 0.5
                gradients[index] = gradient
                maximum = max(maximum, abs(gradient))
            }
        }

        guard maximum > 0.0001 else { return gradients }
        var divisor = maximum
        vDSP_vsdiv(gradients, 1, &divisor, &gradients, 1, vDSP_Length(gradients.count))
        return gradients
    }

    private static func makeEdgeMagnitude(from grayscale: [Float], width: Int, height: Int) -> [Float] {
        guard width > 0, height > 0, grayscale.count == width * height else {
            return [Float](repeating: 0, count: grayscale.count)
        }

        var edges = [Float](repeating: 0, count: grayscale.count)
        var maximum: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width) + x
                let left = grayscale[(y * width) + max(0, x - 1)]
                let right = grayscale[(y * width) + min(width - 1, x + 1)]
                let top = grayscale[(max(0, y - 1) * width) + x]
                let bottom = grayscale[(min(height - 1, y + 1) * width) + x]
                let horizontal = (right - left) * 0.5
                let vertical = (bottom - top) * 0.5
                let magnitude = sqrt((horizontal * horizontal) + (vertical * vertical))
                edges[index] = magnitude
                maximum = max(maximum, magnitude)
            }
        }

        guard maximum > 0.0001 else { return edges }
        var divisor = maximum
        vDSP_vsdiv(edges, 1, &divisor, &edges, 1, vDSP_Length(edges.count))
        return edges
    }

    private static func makeRowStatistics(
        from grayscale: [Float],
        edgeMagnitude: [Float],
        width: Int,
        height: Int
    ) -> (means: [Float], variances: [Float], edgeEnergy: [Float]) {
        guard width > 0, height > 0, grayscale.count == width * height else {
            return (
                means: [Float](repeating: 0, count: max(0, height)),
                variances: [Float](repeating: 0, count: max(0, height)),
                edgeEnergy: [Float](repeating: 0, count: max(0, height))
            )
        }

        var means = [Float](repeating: 0, count: height)
        var variances = [Float](repeating: 0, count: height)
        var edgeEnergy = [Float](repeating: 0, count: height)
        let rowWidth = Float(width)

        for y in 0..<height {
            let rowStart = y * width
            var sum: Float = 0
            var squaredSum: Float = 0
            var edgeSum: Float = 0
            for x in 0..<width {
                let index = rowStart + x
                let value = grayscale[index]
                sum += value
                squaredSum += value * value
                if index < edgeMagnitude.count {
                    edgeSum += edgeMagnitude[index]
                }
            }
            let mean = sum / rowWidth
            means[y] = mean
            variances[y] = max(0, (squaredSum / rowWidth) - (mean * mean))
            edgeEnergy[y] = edgeSum / rowWidth
        }

        return (means, variances, edgeEnergy)
    }
}

public struct NormalizedImage: @unchecked Sendable {
    public let source: SourceImage
    public let image: CGImage
    public let matchingRepresentation: MatchingRepresentation
    public let originalPixelSize: PixelSize
    /// The full-resolution pixel size used by registration and rendering.
    ///
    /// This property retains its original name for renderer compatibility; it
    /// is no longer a downsampled working size.
    public let workingPixelSize: PixelSize

    public init(
        source: SourceImage,
        image: CGImage,
        matchingRepresentation: MatchingRepresentation,
        originalPixelSize: PixelSize,
        workingPixelSize: PixelSize
    ) {
        self.source = source
        self.image = image
        self.matchingRepresentation = matchingRepresentation
        self.originalPixelSize = originalPixelSize
        self.workingPixelSize = workingPixelSize
    }
}

public struct ImageNormalizationConfiguration: Sendable, Equatable {
    /// Matching inputs are always decoded at their source pixel dimensions.
    /// User-facing previews are downsampled separately by the UI.
    public init() {}
}

public struct ImageNormalizer: Sendable {
    public var configuration: ImageNormalizationConfiguration

    public init(configuration: ImageNormalizationConfiguration = ImageNormalizationConfiguration()) {
        self.configuration = configuration
    }

    public func normalize(_ source: SourceImage) throws -> NormalizedImage {
        guard FileManager.default.fileExists(atPath: source.localURL.path) else {
            throw ContinuoError.sourceUnavailable(source.filename ?? source.localURL.lastPathComponent)
        }

        guard let imageSource = CGImageSourceCreateWithURL(source.localURL as CFURL, nil) else {
            throw ContinuoError.unsupportedImage(source.filename ?? source.localURL.lastPathComponent)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let originalWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let originalHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let originalSize = PixelSize(width: originalWidth, height: originalHeight)

        let imageOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true
        ]

        let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        let normalizedImage: CGImage

        // Prefer the platform decoder for every source, not only metadata
        // that advertises a depth above 8 bits. HEIF metadata can omit or
        // misreport the component depth, while the direct Image I/O path may
        // still request the incompatible BGRx8 decode block for a 10-bpc
        // image. UIImageReader/NSImage converts into a stable 8-bit
        // standard-range raster without changing the source dimensions.
        if let platformImage = makePlatformRasterImage(
            from: source.localURL,
            fallbackSize: originalSize,
            requiresNonZeroContent: false
        ) {
            normalizedImage = platformImage
        } else {
            guard let decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, imageOptions as CFDictionary) else {
                throw ContinuoError.imageDecodeFailed(source.filename ?? source.localURL.lastPathComponent)
            }
            guard let renderedImage = makeNormalizedColorImage(
                from: decodedImage,
                sourceURL: source.localURL,
                orientation: orientation
            ) else {
                throw ContinuoError.imageDecodeFailed(source.filename ?? source.localURL.lastPathComponent)
            }
            normalizedImage = renderedImage
        }

        let workingSize = PixelSize(width: normalizedImage.width, height: normalizedImage.height)
        let matching = makeMatchingRepresentation(from: normalizedImage)
        var normalizedSource = source
        normalizedSource.pixelSize = originalSize.width > 0 && originalSize.height > 0 ? originalSize : workingSize
        normalizedSource.orientation = .up

        return NormalizedImage(
            source: normalizedSource,
            image: normalizedImage,
            matchingRepresentation: matching,
            originalPixelSize: originalSize.width > 0 && originalSize.height > 0 ? originalSize : workingSize,
            workingPixelSize: workingSize
        )
    }

    private func makeNormalizedColorImage(
        from image: CGImage,
        sourceURL: URL,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let byteOrder = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let compatibleAlpha = image.alphaInfo == .premultipliedLast || image.alphaInfo == .last
        if orientation == .up,
           image.colorSpace?.name == colorSpace.name,
           image.bitsPerComponent == 8,
           image.bitsPerPixel == 32,
           image.bytesPerRow >= image.width * 4,
           compatibleAlpha,
           byteOrder == 0 {
            return image
        }

        // HEIF images from recent Apple devices may decode as 10-bit HEVC
        // (`bitsPerComponent == 10`, often with a Display-P3 color space).
        // A direct CGImage -> CGContext draw can produce a zero-filled
        // bitmap for that representation. Prefer the platform image decoder
        // for this conversion, preserving the source pixel dimensions while
        // producing the stable 8-bit RGBA raster expected by the compositor.
        if let platformImage = makePlatformRasterImage(
            from: sourceURL,
            fallbackSize: PixelSize(width: image.width, height: image.height),
            requiresNonZeroContent: image.bitsPerComponent > 8
        ) {
            return platformImage
        }

        let fallbackImage: CGImage
        if orientation == .up {
            fallbackImage = image
        } else {
            fallbackImage = makeOrientedImage(from: image, orientation: orientation) ?? image
        }
        let width = fallbackImage.width
        let height = fallbackImage.height
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(fallbackImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { return nil }

        // Do not allow a decoder failure to masquerade as an all-black
        // screenshot and produce a false perfect registration.
        if fallbackImage.bitsPerComponent > 8, hasNonZeroPixel(in: rendered) == false {
            return nil
        }
        return rendered
    }

    private func makePlatformRasterImage(
        from url: URL,
        fallbackSize: PixelSize,
        requiresNonZeroContent: Bool
    ) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        #if canImport(UIKit)
        var configuration = UIImageReader.Configuration()
        configuration.prefersHighDynamicRange = false
        configuration.preparesImagesForDisplay = true
        configuration.preferredThumbnailSize = .zero
        configuration.pixelsPerInch = 0
        let reader = UIImageReader(configuration: configuration)
        if let image = reader.image(data: data) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.opaque = false
            format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            let rendered = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
            if let cgImage = rendered.cgImage,
               cgImage.width > 0,
               cgImage.height > 0,
               !requiresNonZeroContent || hasNonZeroPixel(in: cgImage) {
                return cgImage
            }
        }
        #endif

        #if canImport(AppKit)
        if let image = NSImage(data: data) {
            let width = max(1, fallbackSize.width)
            let height = max(1, fallbackSize.height)
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            ),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
                return nil
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(
                in: CGRect(x: 0, y: 0, width: width, height: height),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            graphics.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            if let cgImage = bitmap.cgImage,
               cgImage.width > 0,
               cgImage.height > 0,
               hasNonZeroPixel(in: cgImage) {
                return cgImage
            }
        }
        #endif

        return nil
    }

    private func hasNonZeroPixel(in image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }

        let sampleCount = min(256, image.width * image.height)
        guard sampleCount > 0 else { return false }
        let stride = max(1, (image.width * image.height) / sampleCount)
        for sample in 0..<sampleCount {
            let pixelIndex = min(image.width * image.height - 1, sample * stride)
            let offset = (pixelIndex / image.width) * image.bytesPerRow + (pixelIndex % image.width) * 4
            if bytes[offset] != 0 || bytes[offset + 1] != 0 || bytes[offset + 2] != 0 {
                return true
            }
        }
        return false
    }

    private func makeOrientedImage(
        from image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        guard orientation != .up else { return image }

        let input = CIImage(cgImage: image)
        let oriented = input.oriented(forExifOrientation: Int32(orientation.rawValue))
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(oriented, from: oriented.extent)
    }

    private func makeMatchingRepresentation(from image: CGImage) -> MatchingRepresentation {
        let width = image.width
        let height = image.height
        let count = width * height
        var grayscale = [Float](repeating: 0, count: count)

        guard let providerData = image.dataProvider?.data, let bytes = CFDataGetBytePtr(providerData) else {
            return MatchingRepresentation(width: width, height: height, grayscale: grayscale)
        }

        let bytesPerRow = image.bytesPerRow
        for y in 0..<height {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = row.advanced(by: x * 4)
                let red = Float(pixel[0])
                let green = Float(pixel[1])
                let blue = Float(pixel[2])
                grayscale[(y * width) + x] = ((0.2126 * red) + (0.7152 * green) + (0.0722 * blue)) / 255.0
            }
        }

        // Keep the representation numerically stable for correlation while using
        // Accelerate for the aggregate normalization step.
        var sum: Float = 0
        vDSP_sve(grayscale, 1, &sum, vDSP_Length(grayscale.count))
        let mean = sum / Float(max(1, grayscale.count))
        let meanVector = [Float](repeating: mean, count: grayscale.count)
        vDSP_vsub(meanVector, 1, grayscale, 1, &grayscale, 1, vDSP_Length(grayscale.count))
        return MatchingRepresentation(width: width, height: height, grayscale: grayscale)
    }
}
