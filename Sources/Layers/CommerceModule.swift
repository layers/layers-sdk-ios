import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// Commerce integration for tracking purchases and transactions.
/// Converts Swift commerce types to event properties and delegates to the Rust core.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class CommerceModule: @unchecked Sendable {

    // MARK: - Types

    public struct Transaction: Sendable {
        public let transactionId: String
        public let productId: String
        public let price: Decimal
        public let currency: String
        public let quantity: Int
        public let purchaseDate: Date
        public let isRestored: Bool
        public let subscriptionGroupId: String?
        public let originalTransactionId: String?

        public init(
            transactionId: String,
            productId: String,
            price: Decimal,
            currency: String,
            quantity: Int = 1,
            purchaseDate: Date = Date(),
            isRestored: Bool = false,
            subscriptionGroupId: String? = nil,
            originalTransactionId: String? = nil
        ) {
            self.transactionId = transactionId
            self.productId = productId
            self.price = price
            self.currency = currency
            self.quantity = quantity
            self.purchaseDate = purchaseDate
            self.isRestored = isRestored
            self.subscriptionGroupId = subscriptionGroupId
            self.originalTransactionId = originalTransactionId
        }
    }

    public struct CartItem: Sendable {
        public let productId: String
        public let name: String
        public let price: Decimal
        public let quantity: Int
        public let category: String?

        public init(
            productId: String,
            name: String,
            price: Decimal,
            quantity: Int = 1,
            category: String? = nil
        ) {
            self.productId = productId
            self.name = name
            self.price = price
            self.quantity = quantity
            self.category = category
        }

        public var total: Decimal { price * Decimal(quantity) }
    }

    public struct Order: Sendable {
        public let orderId: String
        public let items: [CartItem]
        public let subtotal: Decimal
        public let tax: Decimal?
        public let shipping: Decimal?
        public let discount: Decimal?
        public let currency: String
        public let couponCode: String?

        public init(
            orderId: String,
            items: [CartItem],
            subtotal: Decimal,
            tax: Decimal? = nil,
            shipping: Decimal? = nil,
            discount: Decimal? = nil,
            currency: String = "USD",
            couponCode: String? = nil
        ) {
            self.orderId = orderId
            self.items = items
            self.subtotal = subtotal
            self.tax = tax
            self.shipping = shipping
            self.discount = discount
            self.currency = currency
            self.couponCode = couponCode
        }

        public var total: Decimal {
            var t = subtotal
            if let tax { t += tax }
            if let shipping { t += shipping }
            if let discount { t -= discount }
            return t
        }
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var _core: LayersCoreHandle?
    private var _skan: SKANModule?

    /// StoreKit 2 `Transaction.updates` listener. Started lazily via
    /// `startAutomaticPurchaseTracking()`. The task is cancelled on `detach()`.
    private var _autoPurchaseTask: Task<Void, Never>?

    /// Set of transaction IDs already emitted, to dedupe across:
    ///   1. The initial `Transaction.currentEntitlements` flush on startup.
    ///   2. The continuous `Transaction.updates` stream.
    /// StoreKit 2 may yield the same transaction through both channels.
    private var _emittedTransactionIds: Set<String> = []

    private var lockedCore: LayersCoreHandle? {
        lock.lock()
        defer { lock.unlock() }
        return _core
    }

    private var lockedSkan: SKANModule? {
        lock.lock()
        defer { lock.unlock() }
        return _skan
    }

    init() {}

    func attach(core: LayersCoreHandle, skan: SKANModule) {
        lock.lock()
        _core = core
        _skan = skan
        lock.unlock()
    }

    /// Stop any in-flight `Transaction.updates` listener. Idempotent.
    func detach() {
        lock.lock()
        let task = _autoPurchaseTask
        _autoPurchaseTask = nil
        _emittedTransactionIds.removeAll()
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Purchase Tracking

    @discardableResult
    public func trackPurchase(transaction: Transaction) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        let revenue = NSDecimalNumber(decimal: transaction.price * Decimal(transaction.quantity)).stringValue
        var props: [String: String] = [
            "transaction_id": transaction.transactionId,
            "product_id": transaction.productId,
            "price": NSDecimalNumber(decimal: transaction.price).stringValue,
            "currency": transaction.currency,
            "quantity": String(transaction.quantity),
            "revenue": revenue,
            "is_restored": String(transaction.isRestored),
        ]
        if let g = transaction.subscriptionGroupId { props["subscription_group_id"] = g }
        if let o = transaction.originalTransactionId { props["original_transaction_id"] = o }

        do {
            try core.track(
                eventName: "purchase_success",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            lockedSkan?.processEvent(eventName: "purchase", properties: props)
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    @discardableResult
    public func trackOrder(_ order: Order) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        var props: [String: String] = [
            "order_id": order.orderId,
            "subtotal": NSDecimalNumber(decimal: order.subtotal).stringValue,
            "total": NSDecimalNumber(decimal: order.total).stringValue,
            "currency": order.currency,
            "item_count": String(order.items.count),
            "revenue": NSDecimalNumber(decimal: order.total).stringValue,
            "product_ids": order.items.map(\.productId).joined(separator: ","),
        ]
        if let tax = order.tax { props["tax"] = NSDecimalNumber(decimal: tax).stringValue }
        if let s = order.shipping { props["shipping"] = NSDecimalNumber(decimal: s).stringValue }
        if let d = order.discount { props["discount"] = NSDecimalNumber(decimal: d).stringValue }
        if let c = order.couponCode { props["coupon_code"] = c }

        do {
            try core.track(
                eventName: "purchase_success",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            lockedSkan?.processEvent(eventName: "purchase", properties: props)
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    @discardableResult
    public func trackAddToCart(_ item: CartItem) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        var props: [String: String] = [
            "product_id": item.productId,
            "product_name": item.name,
            "price": NSDecimalNumber(decimal: item.price).stringValue,
            "quantity": String(item.quantity),
            "value": NSDecimalNumber(decimal: item.total).stringValue,
        ]
        if let c = item.category { props["category"] = c }
        do {
            try core.track(
                eventName: "add_to_cart",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    @discardableResult
    public func trackRemoveFromCart(_ item: CartItem) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        var props: [String: String] = [
            "product_id": item.productId,
            "product_name": item.name,
            "price": NSDecimalNumber(decimal: item.price).stringValue,
            "quantity": String(item.quantity),
        ]
        if let c = item.category { props["category"] = c }
        do {
            try core.track(
                eventName: "remove_from_cart",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    @discardableResult
    public func trackBeginCheckout(items: [CartItem], currency: String = "USD") -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        let total = items.reduce(Decimal.zero) { $0 + $1.total }
        let props: [String: String] = [
            "item_count": String(items.count),
            "value": NSDecimalNumber(decimal: total).stringValue,
            "currency": currency,
            "product_ids": items.map(\.productId).joined(separator: ","),
        ]
        do {
            try core.track(
                eventName: "begin_checkout",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            lockedSkan?.processEvent(eventName: "begin_checkout", properties: props)
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    @discardableResult
    public func trackViewProduct(productId: String, name: String, price: Decimal, currency: String = "USD", category: String? = nil) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        var props: [String: String] = [
            "product_id": productId,
            "product_name": name,
            "price": NSDecimalNumber(decimal: price).stringValue,
            "currency": currency,
        ]
        if let c = category { props["category"] = c }
        do {
            try core.track(
                eventName: "view_item",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    @discardableResult
    public func trackRefund(transactionId: String, amount: Decimal, currency: String, reason: String? = nil) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        var props: [String: String] = [
            "transaction_id": transactionId,
            "amount": NSDecimalNumber(decimal: amount).stringValue,
            "currency": currency,
        ]
        if let r = reason { props["reason"] = r }
        do {
            try core.track(
                eventName: "refund",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    // MARK: - StoreKit 2

    #if canImport(StoreKit)
    @available(iOS 15.0, macOS 13.0, tvOS 15.0, watchOS 8.0, *)
    @discardableResult
    public func trackStoreKit2Transaction(_ skTransaction: StoreKit.Transaction) -> SafeResult<Void> {
        let currencyCode: String
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            currencyCode = skTransaction.currency?.identifier ?? "USD"
        } else {
            currencyCode = "USD"
        }

        let transaction = Transaction(
            transactionId: String(skTransaction.id),
            productId: skTransaction.productID,
            price: skTransaction.price ?? .zero,
            currency: currencyCode,
            quantity: skTransaction.purchasedQuantity,
            purchaseDate: skTransaction.purchaseDate,
            isRestored: skTransaction.revocationDate != nil,
            subscriptionGroupId: skTransaction.subscriptionGroupID,
            originalTransactionId: String(skTransaction.originalID)
        )
        return trackPurchase(transaction: transaction)
    }

    // MARK: - Automatic StoreKit 2 Purchase Capture

    /// Start a background `Task` that listens to `StoreKit.Transaction.updates`
    /// and emits `$in_app_purchase` events for every finalized transaction.
    ///
    /// **Opt-in.** Wired by `Layers.initialize` only when
    /// `LayersConfig(automaticPurchaseTrackingEnabled: true)` is passed —
    /// the default is `false` for privacy posture (see CLAUDE.md decision #4).
    ///
    /// Idempotent: calling repeatedly is a no-op while a task is active.
    @available(iOS 15.0, macOS 13.0, tvOS 15.0, watchOS 8.0, *)
    public func startAutomaticPurchaseTracking() {
        lock.lock()
        if _autoPurchaseTask != nil {
            lock.unlock()
            return
        }
        // Detached so we don't inherit the caller's actor context.
        let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.consumeStoreKitUpdates()
        }
        _autoPurchaseTask = task
        lock.unlock()
    }

    /// Stop the auto-capture task started by `startAutomaticPurchaseTracking()`.
    @available(iOS 15.0, macOS 13.0, tvOS 15.0, watchOS 8.0, *)
    public func stopAutomaticPurchaseTracking() {
        lock.lock()
        let task = _autoPurchaseTask
        _autoPurchaseTask = nil
        lock.unlock()
        task?.cancel()
    }

    /// Build the `$in_app_purchase` property dict from a verified StoreKit 2
    /// transaction. Extracted so unit tests can validate the property mapping
    /// without spinning up a real StoreKit session.
    @available(iOS 15.0, macOS 13.0, tvOS 15.0, watchOS 8.0, *)
    static func inAppPurchaseProperties(
        from skTransaction: StoreKit.Transaction
    ) -> [String: String] {
        let currencyCode: String
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            currencyCode = skTransaction.currency?.identifier ?? "USD"
        } else {
            currencyCode = "USD"
        }
        let price = skTransaction.price ?? .zero

        var props: [String: String] = [
            "transaction_id": String(skTransaction.id),
            "original_transaction_id": String(skTransaction.originalID),
            "product_id": skTransaction.productID,
            "price": NSDecimalNumber(decimal: price).stringValue,
            "currency": currencyCode,
            "quantity": String(skTransaction.purchasedQuantity),
            "is_upgraded": String(skTransaction.isUpgraded),
        ]
        if let groupId = skTransaction.subscriptionGroupID {
            props["subscription_group_id"] = groupId
        }
        if let offer = skTransaction.offerID {
            props["offer_id"] = offer
        }
        return props
    }

    @available(iOS 15.0, macOS 13.0, tvOS 15.0, watchOS 8.0, *)
    private func consumeStoreKitUpdates() async {
        for await result in StoreKit.Transaction.updates {
            if Task.isCancelled { return }
            await processVerificationResult(result)
        }
    }

    @available(iOS 15.0, macOS 13.0, tvOS 15.0, watchOS 8.0, *)
    private func processVerificationResult(
        _ result: VerificationResult<StoreKit.Transaction>
    ) async {
        guard case .verified(let tx) = result else {
            // Unverified transactions are dropped — same posture as Apple's docs.
            return
        }
        emitInAppPurchase(transaction: tx)
        await tx.finish()
    }

    /// Emit `$in_app_purchase` for the given transaction, deduping by `id`.
    /// Internal so unit tests can drive emission without a real StoreKit stream.
    @available(iOS 15.0, macOS 13.0, tvOS 15.0, watchOS 8.0, *)
    func emitInAppPurchase(transaction: StoreKit.Transaction) {
        let txId = String(transaction.id)
        lock.lock()
        guard let core = _core else {
            lock.unlock()
            return
        }
        if _emittedTransactionIds.contains(txId) {
            lock.unlock()
            return
        }
        _emittedTransactionIds.insert(txId)
        let skan = _skan
        lock.unlock()

        let props = Self.inAppPurchaseProperties(from: transaction)
        do {
            try core.track(
                eventName: "$in_app_purchase",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            skan?.processEvent(eventName: "purchase", properties: props)
        } catch {
            // Best-effort — auto-capture must never crash the host app.
        }
    }

    /// Test hook: returns the count of transaction IDs the dedupe set is
    /// currently holding.
    var _emittedTransactionCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return _emittedTransactionIds.count
    }
    #endif
}
