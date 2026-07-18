import Observation
import StoreKit

@MainActor @Observable
final class SubscriptionManager {
    static let productIDs = ["com.agentdeck.pro.annual", "com.agentdeck.pro.monthly"]
    private(set) var products: [Product] = []
    private(set) var isEntitled = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var updatesTask: Task<Void, Never>?

    func start() async {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.refreshEntitlement()
            }
        }
        await loadProducts()
        await refreshEntitlement()
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Self.productIDs)
                .sorted { productRank($0.id) < productRank($1.id) }
            errorMessage = products.isEmpty ? "Plans are not available from the App Store yet. Try again shortly." : nil
        } catch {
            errorMessage = "Subscriptions are temporarily unavailable. \(error.localizedDescription)"
        }
    }

    func purchase(_ product: Product) async {
        isLoading = true
        defer { isLoading = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refreshEntitlement()
            case .success(.unverified):
                errorMessage = "The App Store could not verify this purchase."
            case .pending:
                errorMessage = "Purchase pending approval."
            case .userCancelled:
                break
            @unknown default:
                errorMessage = "The App Store returned an unknown purchase state."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    func refreshEntitlement() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            active = true
        }
        isEntitled = active
    }

    private func productRank(_ id: String) -> Int {
        id.contains("annual") ? 0 : 1
    }
}
