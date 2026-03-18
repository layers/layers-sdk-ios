import Foundation
import os.log

/// Protocol for RevenueCat's `Purchases` object.
/// Avoids a hard dependency on the RevenueCat SDK.
/// Consumers implement this protocol (or use the provided extension) to bridge
/// RevenueCat customer info updates to Layers.
public protocol RevenueCatPurchasesType: AnyObject {
    /// Register a listener for customer info updates.
    func addCustomerInfoUpdateListener(_ listener: @escaping (RevenueCatCustomerInfoType) -> Void)
    /// Fetch current customer info.
    func getCustomerInfo(completion: @escaping (RevenueCatCustomerInfoType?, Error?) -> Void)
}

/// Protocol for RevenueCat's `CustomerInfo` object.
public protocol RevenueCatCustomerInfoType {
    /// Set of currently active subscription product identifiers.
    var activeSubscriptions: Set<String> { get }
    /// The original RevenueCat app user ID.
    var originalAppUserId: String { get }
}

/// Optional RevenueCat integration for the Layers SDK.
///
/// Tracks `purchase_success` when a RevenueCat purchase completes,
/// tracks `subscription_start` when new subscriptions are detected,
/// and syncs subscriber status to Layers user properties.
///
/// Usage:
/// ```swift
/// // After initializing both Layers and RevenueCat:
/// Layers.shared.revenueCat.connect(Purchases.shared)
///
/// // Or manually track a purchase:
/// Layers.shared.revenueCat.trackPurchase(
///     productId: "premium_monthly",
///     price: 9.99,
///     currency: "USD"
/// )
/// ```
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class RevenueCatModule: @unchecked Sendable {

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "RevenueCat")

    private let lock = NSLock()
    private var _core: LayersCoreHandle?
    private var _isConnected = false
    private var _activeSubscriptions: Set<String> = []
    private var _isInitialLoadDone = false

    init() {}

    func attach(core: LayersCoreHandle) {
        lock.lock()
        _core = core
        lock.unlock()
    }

    private var lockedCore: LayersCoreHandle? {
        lock.lock()
        defer { lock.unlock() }
        return _core
    }

    // MARK: - Connect to RevenueCat

    /// Connect Layers to your existing RevenueCat Purchases instance.
    ///
    /// Listens for customer info updates to detect new subscriptions
    /// and syncs user properties (is_subscriber, revenuecat_original_app_user_id).
    ///
    /// - Parameter purchases: An object conforming to `RevenueCatPurchasesType`.
    ///   RevenueCat's `Purchases` class can be extended to conform.
    @discardableResult
    public func connect(_ purchases: RevenueCatPurchasesType) -> SafeResult<Void> {
        lock.lock()
        guard !_isConnected else {
            lock.unlock()
            return .success(())
        }
        _isConnected = true
        lock.unlock()

        // Listen for future customer info updates
        purchases.addCustomerInfoUpdateListener { [weak self] info in
            self?.handleCustomerInfoUpdate(info, isInitialLoad: false)
        }

        // Fetch current customer info for initial state
        purchases.getCustomerInfo { [weak self] info, _ in
            if let info {
                self?.handleCustomerInfoUpdate(info, isInitialLoad: true)
            }
        }

        os_log("Connected to RevenueCat", log: Self.log, type: .debug)
        return .success(())
    }

    /// Whether the module is currently connected to a RevenueCat instance.
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    // MARK: - Manual Purchase Tracking

    /// Manually track a RevenueCat purchase.
    ///
    /// Use this when you have purchase details but are not using the `connect()` listener pattern.
    ///
    /// - Parameters:
    ///   - productId: The product identifier (e.g., "premium_monthly").
    ///   - price: The purchase price.
    ///   - currency: The ISO 4217 currency code (e.g., "USD").
    ///   - store: The store name (defaults to "app_store" on iOS/macOS).
    @discardableResult
    public func trackPurchase(
        productId: String,
        price: Double,
        currency: String,
        store: String = "app_store"
    ) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        let props: [String: String] = [
            "product_id": productId,
            "revenue": String(price),
            "currency": currency,
            "store": store,
            "source": "revenuecat"
        ]
        do {
            try core.track(
                eventName: "purchase_success",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    // MARK: - Customer Info Handling

    private func handleCustomerInfoUpdate(_ info: RevenueCatCustomerInfoType, isInitialLoad: Bool) {
        let currentSubs = info.activeSubscriptions

        lock.lock()
        let previousSubs = _activeSubscriptions
        let wasInitialLoadDone = _isInitialLoadDone

        if isInitialLoad && wasInitialLoadDone {
            lock.unlock()
            return
        }

        // Track new subscriptions (only after initial load is complete)
        if !isInitialLoad && wasInitialLoadDone {
            let newSubs = currentSubs.subtracting(previousSubs)
            // Unlock before tracking (track acquires its own lock via core)
            _activeSubscriptions = currentSubs
            lock.unlock()

            for subId in newSubs {
                trackSubscriptionStart(productId: subId)
            }
        } else {
            _activeSubscriptions = currentSubs
            _isInitialLoadDone = true
            lock.unlock()
        }

        // Sync user properties
        syncUserProperties(
            isSubscriber: !currentSubs.isEmpty,
            originalAppUserId: info.originalAppUserId
        )
    }

    private func trackSubscriptionStart(productId: String) {
        guard let core = lockedCore else { return }
        let props: [String: String] = [
            "product_id": productId,
            "source": "revenuecat"
        ]
        do {
            try core.track(
                eventName: "subscription_start",
                propertiesJson: Layers.jsonString(from: props),
                userId: nil,
                anonymousId: nil
            )
        } catch {
            os_log("Failed to track subscription_start: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
        }
    }

    private func syncUserProperties(isSubscriber: Bool, originalAppUserId: String) {
        guard let core = lockedCore else { return }
        var userProps: [String: Any] = [
            "is_subscriber": isSubscriber
        ]
        if !originalAppUserId.isEmpty {
            userProps["revenuecat_original_app_user_id"] = originalAppUserId
        }
        do {
            try core.setUserProperties(
                propertiesJson: Layers.jsonString(from: userProps) ?? "{}"
            )
        } catch {
            os_log("Failed to sync RevenueCat user properties: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Testing

    /// Reset all RevenueCat integration state. For testing only.
    func resetForTesting() {
        lock.lock()
        _isConnected = false
        _isInitialLoadDone = false
        _activeSubscriptions = []
        _core = nil
        lock.unlock()
    }
}
