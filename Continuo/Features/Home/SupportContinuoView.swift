import StoreKit
import SwiftUI

struct SupportContinuoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var store = ContinuoSupportStore()

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Support Continuo")
                        .font(.title2.weight(.semibold))
                    Text("A small thank-you helps keep the stitches moving.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close support")
            }

            if store.isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .padding(.vertical, 28)
            } else if store.products.isEmpty {
                ContentUnavailableView(
                    "Tips unavailable",
                    systemImage: "cart.badge.questionmark",
                    description: Text(store.errorMessage ?? "Try again later.")
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(SupportProduct.allCases) { supportProduct in
                        if let product = store.product(for: supportProduct) {
                            supportProductRow(supportProduct, product: product)
                        }
                    }
                }
            }

        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fontDesign(.rounded)
        .task {
            await store.loadProducts()
        }
        .alert(
            "Support purchase",
            isPresented: Binding(
                get: { store.completionMessage != nil },
                set: { if !$0 { store.completionMessage = nil } }
            )
        ) {
            Button("Done", role: .cancel) {}
        } message: {
            Text(store.completionMessage ?? "Thank you for supporting Continuo.")
        }
        .alert(
            "Couldn’t complete support purchase",
            isPresented: Binding(
                get: { store.errorMessage != nil && !store.isLoading && !store.products.isEmpty },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Continuo could not complete the purchase.")
        }
#if os(macOS)
        .frame(width: 520, height: 480, alignment: .topLeading)
#endif
    }

    private func supportProductRow(_ supportProduct: SupportProduct, product: Product) -> some View {
        Button {
            Task {
                await store.purchase(supportProduct)
            }
        } label: {
            HStack(spacing: 14) {
                Image(supportProduct.assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(colorScheme == .dark ? .white : ContinuoDesign.wordmarkLight)
                    .frame(width: 38, height: 38)
                    .padding(5)
                    .background(ContinuoDesign.logoGreen.opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(supportProduct.title)
                        .font(.headline)
                    Text(supportProduct.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(product.displayPrice)
                    .font(ContinuoDesign.Typography.metadata())
                    .fontDesign(.monospaced)
                    .foregroundStyle(ContinuoDesign.primaryAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(store.purchasingProductID != nil)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: ContinuoDesign.Radius.panel, style: .continuous))
        .overlay(alignment: .trailing) {
            if store.purchasingProductID == product.id {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 16)
            }
        }
        .accessibilityLabel("Support Continuo with \(supportProduct.title), \(product.displayPrice)")
    }
}
