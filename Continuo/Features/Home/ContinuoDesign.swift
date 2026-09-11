import CoreGraphics
import SwiftUI

enum ContinuoDesign {
    enum Typography {
        static let titleFontFileName = "RacingSansOne-Regular.ttf"
        static let titleFontName = "RacingSansOne-Regular"

        static func titleSize(isCompact: Bool) -> CGFloat {
#if os(macOS)
            30
#else
            isCompact ? 23 : 28
#endif
        }

        static func title(size: CGFloat) -> Font {
            .custom(titleFontName, size: size, relativeTo: .largeTitle)
        }

        static func metadata(size: CGFloat? = nil) -> Font {
            if let size {
                return .system(size: size, design: .monospaced)
            }
            return .system(.caption, design: .monospaced)
        }
    }

    static let logoGreen = Color(red: 111 / 255, green: 206 / 255, blue: 67 / 255)
    static let wordmarkLight = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
    static let wordmarkDark = Color(red: 233 / 255, green: 233 / 255, blue: 233 / 255)
    static let subtitleBlue = Color(red: 79 / 255, green: 159 / 255, blue: 199 / 255)
    static let primaryAction = Color(red: 79 / 255, green: 159 / 255, blue: 199 / 255)
    static let destructive = Color(red: 180 / 255, green: 0, blue: 0)
    static let destructiveTextLight = wordmarkDark
    static let destructiveTextDark = wordmarkLight

    enum Layout {
        static let contentMaximumWidth: CGFloat = 960
        static let compactMaximumWidth: CGFloat = 350
        static let historyMaximumWidth: CGFloat = 900
        static let pageHorizontalPadding: CGFloat = 20
        static let pageTopPadding: CGFloat = 12
        static let pageBottomPadding: CGFloat = 48
        static let historyTopPadding: CGFloat = 24
#if os(macOS)
        static let macHeaderHorizontalPadding: CGFloat = 18
#endif
    }

    enum Spacing {
        static let compact: CGFloat = 10
        static let standard: CGFloat = 12
        static let panel: CGFloat = 16
        static let section: CGFloat = 20
    }

    enum Radius {
        static let panel: CGFloat = 18
        static let action: CGFloat = 22
        static let overlay: CGFloat = 26
    }

    enum Control {
        static let directionButton: CGFloat = 42
        static let shareButton: CGFloat = 44
    }
}

struct ContinuoDestructiveButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(
                colorScheme == .dark
                    ? ContinuoDesign.destructiveTextDark
                    : ContinuoDesign.destructiveTextLight
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ContinuoDesign.destructive.opacity(configuration.isPressed ? 0.76 : 1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
