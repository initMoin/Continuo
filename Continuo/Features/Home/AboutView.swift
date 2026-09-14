import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingSupport = false

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return switch (version, build) {
        case let (version?, _): "Version \(version)"
        default: "Development build"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    aboutHero
                    aboutSection(
                        title: "Where Continuo came from",
                        text: "There are already many apps in the App Store that connect and stitch screenshots into one. However, either they weren’t automated or they stopped working. I needed it for a problem that kept showing up and bugging me. So I built my own solution and maybe it helps you too."
                    )
                    aboutSection(
                        title: "Keeping your things yours",
                        text: "All your screenshot stitches stay on your device. History can stay there as well or it can live in your private iCloud Drive."
                    )
                    aboutSection(
                        title: "Built to get out of your way",
                        text: "Choose your screenshots, choose the right direction, and let Continuo handle the rest, the more tedious part. The result feels obvious when finished... and satisfying."
                    )
                    whoAmISection
                    contactLinks
                    Text("For those moments when one screenshot just doesn't do the trick")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                }
                .frame(maxWidth: horizontalSizeClass == .regular ? 640 : 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ContinuoDesign.Layout.pageHorizontalPadding)
                .padding(.vertical, 28)
            }
            .fontDesign(.rounded)
            .navigationTitle("About")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingSupport) {
                SupportContinuoView()
#if os(iOS)
                    .presentationDetents([.height(380)])
                    .presentationDragIndicator(.visible)
#endif
            }
        }
#if os(macOS)
        .frame(width: 700, height: 860, alignment: .topLeading)
#endif
    }

    private var aboutHero: some View {
        VStack(spacing: 8) {
            Image("continuo-wordmark")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 48)
                .accessibilityHidden(true)

            Text(versionText)
                .font(ContinuoDesign.Typography.metadata())
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
    }

    private func aboutSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(ContinuoDesign.primaryAction)
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whoAmISection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("whoami")
                .font(.headline.weight(.semibold))
                .foregroundStyle(ContinuoDesign.primaryAction)
            Text("\(Text("Hi, I'm ").bold())\(Text("moin.").bold().italic()) And, I build apps for you, the user. I hope you enjoy Continuo and make good use of it. Please reach out if you come across any issues, had a great feature idea, or needed my help building a whole new app!")
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contactLinks: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 6) {
                Link(destination: URL(string: "https://iamshift.dev")!) {
                    aboutSiteLinkLabel {
                        Image("iamshift.dev-logo")
                            .resizable()
                            .scaledToFit()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Visit iamshift.dev")

                Link(destination: URL(string: "mailto:support@iamshift.dev")!) {
                    aboutLinkLabel(title: "support@iamshift.dev") {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(ContinuoDesign.primaryAction)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Email support at support@iamshift.dev")
            }
            .frame(maxWidth: .infinity)

            supportLink
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var supportLink: some View {
        Button {
            showingSupport = true
        } label: {
            VStack(spacing: 7) {
                Image(systemName: "heart.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(ContinuoDesign.primaryAction, in: Circle())
                Text("Support Continuo")
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .top)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Support Continuo")
    }

    private func aboutLinkLabel<Icon: View>(
        title: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 8) {
            icon()
                .frame(width: 34, height: 34)
            Text(title)
                .font(title.contains("@") ? ContinuoDesign.Typography.metadata(size: 12) : .subheadline.weight(.medium))
                .fontDesign(title.contains("@") ? .monospaced : .rounded)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)
    }

    private func aboutSiteLinkLabel<Icon: View>(
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 8) {
            icon()
                .frame(width: 34, height: 34)

            Text("\(Text("m").font(.custom("Aleo", size: 15)))\(Text("o").font(.custom("Aleo", size: 15)))\(Text("i").font(.custom("Aleo-Italic", size: 15)))\(Text("n.").font(.custom("Aleo", size: 15)))\(Text("sh").font(.custom("Aleo-Italic", size: 15)))\(Text("i").font(.custom("Aleo", size: 15)))\(Text("ft()").font(.custom("Aleo-Italic", size: 15)))")
            .lineLimit(1)
            .minimumScaleFactor(0.82)

            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)
    }
}
