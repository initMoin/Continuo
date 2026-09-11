import StoreKit
import SwiftUI

struct SupportContinuoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var store = ContinuoSupportStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text("Support Continuo")
                            .font(.title2.weight(.semibold))
                        Text("Continuo is free to use. These optional purchases are a simple way to support its continued development.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                    }

                    if store.isLoading {
                        ProgressView()
                            .controlSize(.regular)
                            .padding(.vertical, 20)
                    } else if store.products.isEmpty {
                        ContentUnavailableView(
                            "Support purchases unavailable",
                            systemImage: "cart.badge.questionmark",
                            description: Text(store.errorMessage ?? "Try again later.")
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(SupportProduct.allCases) { supportProduct in
                                if let product = store.product(for: supportProduct) {
                                    supportProductRow(supportProduct, product: product)
                                }
                            }
                        }
                        .frame(maxWidth: 480)
                    }

                    Text("Prices are shown in your local currency by Apple. Purchases are optional tips and do not unlock app functionality.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ContinuoDesign.Layout.pageHorizontalPadding)
                .padding(.vertical, 28)
            }
            .fontDesign(.rounded)
            .navigationTitle("Support Continuo")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(store.purchasingProductID != nil)
                }
            }
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
        }
#if os(macOS)
        .frame(width: 640, height: 600, alignment: .topLeading)
#endif
    }

    private func supportProductRow(_ supportProduct: SupportProduct, product: Product) -> some View {
        Button {
            Task {
                await store.purchase(supportProduct)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: supportProduct.systemImage)
                    .font(.title3)
                    .foregroundStyle(ContinuoDesign.logoGreen)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(supportProduct.title)
                        .font(.headline)
                    Text("Optional support")
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
