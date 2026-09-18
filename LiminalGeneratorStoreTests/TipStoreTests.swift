import XCTest
import StoreKit
import StoreKitTest
@testable import Liminal_Generator

final class TipStoreTests: XCTestCase {
    @MainActor
    private func makeSession() throws -> SKTestSession {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TipJar", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        // Some iOS 26.x runtimes reject Octane test controls with error 3.
        // Stop here instead of accidentally invoking a non-test storefront.
        session.askToBuyEnabled = true
        guard session.askToBuyEnabled && session.disableDialogs else {
            throw XCTSkip("StoreKit test service rejected its configuration. Use a compatible simulator runtime; never continue into a non-test purchase.")
        }
        session.askToBuyEnabled = false
        return session
    }

    @MainActor
    func testSuccessfulTipsCanRepeat() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        let store = TipStore()
        await store.loadProducts()
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.products.map(\.id), TipStore.productIDs)
        XCTAssertEqual(store.products.map(\.price), [Decimal(string: "1.99")!, Decimal(string: "4.99")!, Decimal(string: "9.99")!])
        let product = try XCTUnwrap(store.products.first)
        for _ in 0..<2 {
            await store.purchase(product)
            XCTAssertEqual(store.notice?.title, "Thank you!")
            XCTAssertNil(store.purchasingID)
            store.notice = nil
        }
        XCTAssertEqual(session.allTransactions().count, 2)
    }

    @MainActor
    func testPendingApprovalCompletesThroughUpdates() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        session.askToBuyEnabled = true
        let store = TipStore()
        await store.loadProducts()
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(store.notice?.title, "Tip awaiting approval")
        XCTAssertNil(store.purchasingID)
        let pending = try XCTUnwrap(session.allTransactions().first)
        store.notice = nil
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        for _ in 0..<100 where store.notice?.title != "Thank you!" {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.notice?.title, "Thank you!")
    }

    @MainActor
    func testCancellationIsQuiet() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        let store = TipStore()
        await store.loadProducts()
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertNil(store.notice)
        XCTAssertNil(store.purchasingID)
        XCTAssertTrue(session.allTransactions().isEmpty)
    }

    @MainActor
    func testLoadFailureCanRetry() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        let store = TipStore()
        try await session.setSimulatedError(.generic(.unknown), forAPI: .loadProducts)
        await store.loadProducts()
        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(store.products.isEmpty)
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        await store.loadProducts()
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.products.count, 3)
    }

    @MainActor
    func testPurchaseFailureDoesNotThankUser() async throws {
        let session = try makeSession()
        defer { session.resetToDefaultState(); session.clearTransactions() }
        let store = TipStore()
        await store.loadProducts()
        try await session.setSimulatedError(.generic(.unknown), forAPI: .purchase)
        await store.purchase(try XCTUnwrap(store.products.first))
        XCTAssertEqual(store.notice?.title, "Tip not completed")
        XCTAssertNil(store.purchasingID)
    }
}
