import CoreGraphics
import CoreImage
import Foundation

public enum DirectionalImageAdapter {
    public static func matchingImage(
        _ normalized: NormalizedImage,
        for direction: StitchDirection
    ) -> NormalizedImage {
        guard direction == .horizontal else { return normalized }

        let matchingImage = rotate(normalized.matchingImage, clockwise: true)
        let grayscale = transpose(
            normalized.matchingRepresentation.grayscale,
            width: normalized.matchingRepresentation.width,
            height: normalized.matchingRepresentation.height
        )
        let representation = MatchingRepresentation(
            width: normalized.matchingRepresentation.height,
            height: normalized.matchingRepresentation.width,
            grayscale: grayscale
        )
        let source = swapPixelGeometry(normalized.source)
        return NormalizedImage(
            source: source,
            image: matchingImage,
            matchingImage: matchingImage,
            matchingRepresentation: representation,
            originalPixelSize: swap(normalized.originalPixelSize),
            workingPixelSize: swap(normalized.workingPixelSize)
        )
    }

    public static func renderingImage(
        _ image: CGImage,
        for direction: StitchDirection
    ) -> CGImage {
        direction == .horizontal ? rotate(image, clockwise: true) : image
    }

    public static func outputImage(
        _ image: CGImage,
        for direction: StitchDirection
    ) -> CGImage {
        direction == .horizontal ? rotate(image, clockwise: false) : image
    }

    public static func cropHorizontalCrossAxis(
        _ image: CGImage,
        placements: [SourcePlacement]
    ) -> CGImage {
        guard !placements.isEmpty else { return image }
        let commonStart = placements.map { $0.frame.x }.max() ?? 0
        let commonEnd = placements.map { $0.frame.x + $0.frame.width }.min() ?? Double(image.width)
        let start = max(0, Int(ceil(commonStart)))
        let end = min(image.width, Int(floor(commonEnd)))
        guard end > start, end - start < image.width else { return image }
        return image.cropping(
            to: CGRect(x: start, y: 0, width: end - start, height: image.height)
        ) ?? image
    }

    private static func swapPixelGeometry(_ source: SourceImage) -> SourceImage {
        var source = source
        source.pixelSize = swap(source.pixelSize)
        return source
    }

    private static func swap(_ size: PixelSize) -> PixelSize {
        PixelSize(width: size.height, height: size.width)
    }

    private static func transpose(_ values: [Float], width: Int, height: Int) -> [Float] {
        guard width > 0, height > 0, values.count == width * height else { return [] }
        var transposed = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                let rotatedX = height - 1 - y
                let rotatedY = x
                transposed[(rotatedY * height) + rotatedX] = values[(y * width) + x]
            }
        }
        return transposed
    }

    private static func rotate(_ image: CGImage, clockwise: Bool) -> CGImage {
        let orientation: CGImagePropertyOrientation = clockwise ? .right : .left
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation.rawValue))
        return CIContext(options: [.useSoftwareRenderer: true])
            .createCGImage(oriented, from: oriented.extent) ?? image
    }
}
