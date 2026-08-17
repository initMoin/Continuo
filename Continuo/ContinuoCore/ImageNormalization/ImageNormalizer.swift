import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public struct MatchingRepresentation: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let grayscale: [Float]
    public let edgeMagnitude: [Float]
    public let verticalGradient: [Float]

    public init(
        width: Int,
        height: Int,
        grayscale: [Float],
        edgeMagnitude: [Float]? = nil,
        verticalGradient: [Float]? = nil
    ) {
        self.width = width
        self.height = height
        self.grayscale = grayscale
        if let edgeMagnitude, edgeMagnitude.count == grayscale.count {
            self.edgeMagnitude = edgeMagnitude
        } else {
            self.edgeMagnitude = Self.makeEdgeMagnitude(from: grayscale, width: width, height: height)
        }
        if let verticalGradient, verticalGradient.count == grayscale.count {
            self.verticalGradient = verticalGradient
        } else {
            self.verticalGradient = Self.makeVerticalGradient(from: grayscale, width: width, height: height)
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

        guard let decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, imageOptions as CFDictionary) else {
            throw ContinuoError.imageDecodeFailed(source.filename ?? source.localURL.lastPathComponent)
        }

        let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        guard let fullResolutionImage = makeOrientedImage(from: decodedImage, orientation: orientation),
              let matchingImage = makeNormalizedColorImage(from: fullResolutionImage) else {
            throw ContinuoError.imageDecodeFailed(source.filename ?? source.localURL.lastPathComponent)
        }

        let workingSize = PixelSize(width: fullResolutionImage.width, height: fullResolutionImage.height)
        let matching = makeMatchingRepresentation(from: matchingImage)
        var normalizedSource = source
        normalizedSource.pixelSize = originalSize.width > 0 && originalSize.height > 0 ? originalSize : workingSize
        normalizedSource.orientation = .up

        return NormalizedImage(
            source: normalizedSource,
            image: fullResolutionImage,
            matchingRepresentation: matching,
            originalPixelSize: originalSize.width > 0 && originalSize.height > 0 ? originalSize : workingSize,
            workingPixelSize: workingSize
        )
    }

    private func makeNormalizedColorImage(from image: CGImage) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width
        let height = image.height
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
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
