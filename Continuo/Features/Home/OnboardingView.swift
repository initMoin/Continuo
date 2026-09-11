import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void
    @State private var selectedPage = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Screenshots, continued",
            message: "Choose the screenshots that belong together. Continuo finds the overlap and turns them into one clean image.",
            systemImage: "rectangle.stack",
            tint: ContinuoDesign.logoGreen
        ),
        OnboardingPage(
            title: "Your history, your choice",
            message: "History stays on this device by default. You can enable private iCloud Drive storage later to keep it available across your devices.",
            systemImage: "icloud",
            tint: ContinuoDesign.primaryAction
        ),
        OnboardingPage(
            title: "Two ways to delete",
            message: "Remove from this device hides the stitch here while keeping it elsewhere. Delete everywhere removes its history files from iCloud Drive and every synced device.",
            systemImage: "trash",
            tint: ContinuoDesign.destructive
        )
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 0) {
#if os(iOS)
                TabView(selection: $selectedPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        onboardingPage(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
#else
                onboardingPage(pages[selectedPage])
                    .contentTransition(.opacity)
                    .gesture(pageSwipeGesture)
#endif

                navigationControls
            }
            .fontDesign(.rounded)
            .frame(maxWidth: horizontalSizeClass == .regular ? 620 : .infinity)
            .frame(height: horizontalSizeClass == .regular ? 560 : 500)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(macOS)
        .frame(width: 660, height: 600)
#endif
    }

    private var navigationControls: some View {
        HStack(spacing: 28) {
            Button {
                movePage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .disabled(selectedPage == 0)
            .opacity(selectedPage == 0 ? 0.3 : 1)
            .accessibilityLabel("Previous onboarding page")

            HStack(spacing: 10) {
                ForEach(pages.indices, id: \.self) { index in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedPage = index
                        }
                    } label: {
                        Circle()
                            .fill(index == selectedPage ? ContinuoDesign.primaryAction : Color.secondary.opacity(0.28))
                            .frame(width: index == selectedPage ? 9 : 7, height: index == selectedPage ? 9 : 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Onboarding page \(index + 1) of \(pages.count)")
                }
            }

            if selectedPage == pages.count - 1 {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .tint(ContinuoDesign.primaryAction)
                .accessibilityLabel("Finish onboarding")
            } else {
                Button {
                    movePage(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next onboarding page")
            }
        }
        .padding(.bottom, 18)
    }

    private func onboardingPage(_ page: OnboardingPage) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)

            Image(systemName: page.systemImage)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(page.tint)
                .frame(width: 96, height: 96)
                .background(page.tint.opacity(0.14), in: Circle())
                .overlay {
                    Circle()
                        .stroke(page.tint.opacity(0.32), lineWidth: 1)
                }

            VStack(spacing: 8) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                movePage(by: value.translation.width < 0 ? 1 : -1)
            }
    }

    private func movePage(by offset: Int) {
        let nextPage = min(max(selectedPage + offset, 0), pages.count - 1)
        guard nextPage != selectedPage else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedPage = nextPage
        }
    }
}

private struct OnboardingPage: Sendable {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
}
