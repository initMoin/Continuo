import CoreGraphics
import SwiftUI

struct SmoothProgressBar: View {
    let progress: Double
    let reduceMotion: Bool
    @State private var shimmerPhase: CGFloat = -0.25

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = min(1, max(0, progress))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(
                        ContinuoDesign.logoGreen
                    )
                    .frame(width: proxy.size.width * clampedProgress)
                if !reduceMotion {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.72), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 76)
                        .offset(x: ((proxy.size.width + 76) * shimmerPhase) - 76)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: progress)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }
}

struct ScreenshotThumbnail: View {
    let source: SourceImage
    let index: Int
    let magicProgress: CGFloat
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(5)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading screenshot…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Text("\(index + 1)")
                    .font(ContinuoDesign.Typography.metadata(size: 11).weight(.bold))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.background)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.72), in: Capsule())
                    .padding(7)
            }
            .frame(width: 148, height: 232)
            .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.primary.opacity(0.16), lineWidth: 1)
            }
            .scaleEffect(1 - (0.025 * magicProgress))
            .offset(y: -CGFloat(index % 2) * 3 * magicProgress)

            Text("Screenshot \(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Screenshot \(index + 1), selected in position \(index + 1)")
        .task(id: source.localURL) {
            let source = source
            let result = await Task.detached(priority: .utility) {
                SendableThumbnail(
                    image: try? ImageNormalizer().makeThumbnail(
                        source,
                        maximumPixelSize: 640
                    )
                )
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = result.image
        }
    }
}

private struct SendableThumbnail: @unchecked Sendable {
    let image: CGImage?
}
