import Observation
import StoreKit

enum SupportProduct: String, CaseIterable, Identifiable, Sendable {
    case lemonCookie = "support.lemon-cookie"
    case caramelLatte = "support.caramel-latte"
    case phillyCheesesteak = "support.philly-cheesesteak"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lemonCookie:
            "Lemon Cookie"
        case .caramelLatte:
            "Caramel Latte"
        case .phillyCheesesteak:
            "Philly Cheesesteak"
        }
    }

    var message: String {
        switch self {
        case .lemonCookie:
            "A small bite of thanks."
        case .caramelLatte:
            "For the builds that run past bedtime."
        case .phillyCheesesteak:
            "A hearty thank-you for keeping Continuo going."
        }
    }

    var systemImage: String {
        switch self {
        case .lemonCookie:
            "circle.fill"
        case .caramelLatte:
            "cup.and.saucer.fill"
        case .phillyCheesesteak:
            "fork.knife"
        }
    }
}

@MainActor
@Observable
final class ContinuoSupportStore {
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchasingProductID: String?
    var errorMessage: String?
    var completionMessage: String?

    private var hasLoadedProducts = false
    private var transactionUpdatesTask: Task<Void, Never>?

    init() {
        transactionUpdatesTask = Task { [weak self] in
            await self?.observeTransactions()
        }
    }

    isolated deinit {
        transactionUpdatesTask?.cancel()
    }

    func loadProducts() async {
        guard !hasLoadedProducts, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoadedProducts = true
        }

        do {
            let loadedProducts = try await Product.products(
                for: SupportProduct.allCases.map(\.rawValue)
            )
            let productsByID = Dictionary(uniqueKeysWithValues: loadedProducts.map { ($0.id, $0) })
            products = SupportProduct.allCases.compactMap { productsByID[$0.rawValue] }
            if products.isEmpty {
                errorMessage = "Support purchases are not available right now."
            }
        } catch {
            errorMessage = "Continuo could not load support purchases: \(error.localizedDescription)"
        }
    }

    func product(for supportProduct: SupportProduct) -> Product? {
        products.first { $0.id == supportProduct.rawValue }
    }

    func purchase(_ supportProduct: SupportProduct) async {
        guard let product = product(for: supportProduct) else {
            errorMessage = "This support purchase is not available right now."
            return
        }
        guard purchasingProductID == nil else { return }

        purchasingProductID = product.id
        errorMessage = nil
        completionMessage = nil
        defer { purchasingProductID = nil }

        do {
            switch try await product.purchase() {
            case let .success(.verified(transaction)):
                await transaction.finish()
                completionMessage = "Thank you for the \(supportProduct.title)."
            case let .success(.unverified(_, error)):
                errorMessage = "Continuo could not verify this purchase: \(error.localizedDescription)"
            case .userCancelled:
                break
            case .pending:
                completionMessage = "Your purchase is pending approval."
            @unknown default:
                errorMessage = "Continuo could not complete this purchase."
            }
        } catch {
            errorMessage = "Continuo could not complete this purchase: \(error.localizedDescription)"
        }
    }

    private func observeTransactions() async {
        for await result in Transaction.updates {
            guard !Task.isCancelled else { return }
            if case let .verified(transaction) = result {
                await transaction.finish()
            }
        }
    }
}
