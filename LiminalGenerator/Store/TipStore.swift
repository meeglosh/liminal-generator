import StoreKit
import SwiftUI

/// Optional, repeatable tips. No entitlement or feature access depends on payment.
@MainActor
final class TipStore: ObservableObject {
    static let productIDs = [
        "com.gapco.LiminalGenerator.tip.small",
        "com.gapco.LiminalGenerator.tip.coffee",
        "com.gapco.LiminalGenerator.tip.tapes",
    ]

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var purchasingID: String?
    @Published private(set) var loadError: String?
    @Published var notice: Notice?
    var canMakePayments: Bool { AppStore.canMakePayments }

    private var updatesTask: Task<Void, Never>?
    private var unfinishedTask: Task<Void, Never>?
    private var storefrontTask: Task<Void, Never>?
    private var handledTransactions = Set<UInt64>()

    init() {
        // Start at app launch, not just when About is open: Ask to Buy or
        // interrupted purchases can finish after the sheet has been dismissed.
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.handle(result)
            }
        }
        unfinishedTask = Task { [weak self] in
            for await result in StoreKit.Transaction.unfinished {
                guard !Task.isCancelled else { return }
                await self?.handle(result)
            }
        }
        storefrontTask = Task { [weak self] in
            for await _ in Storefront.updates {
                guard !Task.isCancelled else { return }
                await self?.loadProducts()
            }
        }
    }

    deinit {
        updatesTask?.cancel()
        unfinishedTask?.cancel()
        storefrontTask?.cancel()
    }

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = Self.productIDs.compactMap { id in
                fetched.first { $0.id == id && $0.type == .consumable }
            }
            if products.count != Self.productIDs.count {
                loadError = products.isEmpty
                    ? "Tips are temporarily unavailable. Please try again later."
                    : "Some tip amounts are unavailable right now."
            }
        } catch {
            // Never substitute a hardcoded price or charge for an unavailable product.
            products = []
            loadError = "Couldn’t connect to the App Store. Please try again."
        }
    }

    func purchase(_ product: Product) async {
        guard purchasingID == nil, Self.productIDs.contains(product.id),
              product.type == .consumable else { return }
        guard canMakePayments else {
            notice = Notice(title: "Purchases unavailable", message: "In-app purchases are disabled on this device.")
            return
        }
        purchasingID = product.id
        notice = nil
        defer { purchasingID = nil }
        do {
            switch try await product.purchase() {
            case .success(let result): await handle(result)
            case .pending:
                notice = Notice(title: "Tip awaiting approval", message: "Apple is waiting for approval or payment confirmation. Thank you for wanting to support the app.")
            case .userCancelled: break
            @unknown default:
                notice = Notice(title: "Tip not completed", message: "Please try again later.")
            }
        } catch StoreKitError.userCancelled {
            // Cancellation is a normal choice, not an error to show the user.
        } catch {
            notice = Notice(title: "Tip not completed", message: "We couldn’t complete your tip. Please try again later.")
        }
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard Self.productIDs.contains(transaction.productID),
                  transaction.productType == .consumable else { return }
            // Ignore refunded/revoked tips without granting or revoking app features.
            guard transaction.revocationDate == nil else {
                await transaction.finish()
                return
            }
            guard handledTransactions.insert(transaction.id).inserted else { return }
            await transaction.finish()
            notice = Notice(title: "Thank you!", message: "Your tip helps keep the tapes rolling. Enjoy the music.")
        case .unverified:
            // Never acknowledge an unverified payment as a successful tip.
            notice = Notice(title: "Couldn’t verify tip", message: "We couldn’t verify this purchase. Please check your App Store purchase history before trying again.")
        }
    }
}
