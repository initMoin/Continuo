import CoreGraphics
import Foundation

/// Errors raised when a pixel-space crop cannot be completed safely.
public enum PixelCropError: Error, Equatable, LocalizedError, Sendable {
    case invalidRectangle(Rect2D)
    case rectangleOutOfBounds(rectangle: Rect2D, imageSize: PixelSize)
    case cropFailed(Rect2D)

    public var errorDescription: String? {
        switch self {
        case let .invalidRectangle(rectangle):
            "The requested pixel crop is invalid (x: \(rectangle.x), y: \(rectangle.y), width: \(rectangle.width), height: \(rectangle.height))."
        case let .rectangleOutOfBounds(rectangle, imageSize):
            "The requested pixel crop (x: \(rectangle.x), y: \(rectangle.y), width: \(rectangle.width), height: \(rectangle.height)) is outside the image bounds (\(imageSize.width) × \(imageSize.height))."
        case let .cropFailed(rectangle):
            "Continuo could not create the requested pixel crop at (x: \(rectangle.x), y: \(rectangle.y), width: \(rectangle.width), height: \(rectangle.height))."
        }
    }
}

/// Crops already-normalized images without changing their pixel resolution.
///
/// Rectangles use the same pixel-space convention as `Rect2D` and the
/// normalized image pipeline. This type intentionally operates on `CGImage`
/// instead of `UIImage` so it remains usable by the shared iOS, iPadOS, and
/// macOS engine.
public struct PixelRegionCropper: Sendable {
    public init() {}

    public func crop(_ image: CGImage, to rectangle: Rect2D) throws -> CGImage {
        guard rectangle.x.isFinite,
              rectangle.y.isFinite,
              rectangle.width.isFinite,
              rectangle.height.isFinite,
              rectangle.width > 0,
              rectangle.height > 0 else {
            throw PixelCropError.invalidRectangle(rectangle)
        }

        let requestedRect = rectangle.cgRect.integral
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        let imageSize = PixelSize(width: image.width, height: image.height)

        guard imageBounds.contains(requestedRect) else {
            throw PixelCropError.rectangleOutOfBounds(
                rectangle: Rect2D(requestedRect),
                imageSize: imageSize
            )
        }

        guard let cropped = image.cropping(to: requestedRect) else {
            throw PixelCropError.cropFailed(Rect2D(requestedRect))
        }
        return cropped
    }
}
