import Foundation
import os.log

/// Optional Superwall integration for Layers.
///
/// Tracks paywall events (presentation, dismiss, purchase, skip) when
/// Superwall triggers them. Does **not** import SuperwallKit — instead,
/// it exposes a duck-typed API that accepts the raw event values your app
/// extracts from Superwall callbacks.
///
/// **Usage with SuperwallKit:**
/// ```swift
/// import SuperwallKit
///
/// class MySuperwallDelegate: SuperwallDelegate {
///     func handleSuperwallEvent(withInfo eventInfo: SuperwallEventInfo) {
///         Layers.shared.superwall.onEvent(
///             eventName: eventInfo.event.rawName,
///             params: eventInfo.params
///         )
///     }
///
///     func paywallWillPresent(withInfo info: PaywallInfo) {
///         Layers.shared.superwall.trackPresentation(
///             paywallId: info.identifier,
///             placement: info.name,
///             experimentId: info.experiment?.id,
///             variantId: info.experiment?.variant.id
///         )
///     }
///
///     func paywallWillDismiss(withInfo info: PaywallInfo) {
///         Layers.shared.superwall.trackDismiss(paywallId: info.identifier)
///     }
/// }
/// ```
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class SuperwallModule: @unchecked Sendable {

    private static let log = OSLog(subsystem: "io.layers.sdk", category: "SuperwallModule")

    // MARK: - Properties

    private let lock = NSLock()
    private var _layers: Layers?

    private var lockedLayers: Layers? {
        lock.lock()
        defer { lock.unlock() }
        return _layers
    }

    init() {}

    func attach(layers: Layers) {
        lock.lock()
        _layers = layers
        lock.unlock()
    }

    // MARK: - Generic Event Forwarding

    /// Forward any Superwall event to Layers, prefixed with `superwall_`.
    ///
    /// This is the simplest integration point. Wire it up in your
    /// `SuperwallDelegate.handleSuperwallEvent(withInfo:)` callback.
    ///
    /// - Parameters:
    ///   - eventName: The raw event name from Superwall (e.g. `"paywall_open"`,
    ///     `"transaction_start"`). Will be tracked as `"superwall_<eventName>"`.
    ///   - params: Optional dictionary of event parameters from Superwall.
    @discardableResult
    public func onEvent(eventName: String, params: [String: Any]? = nil) -> SafeResult<Void> {
        guard let layers = lockedLayers else { return .failure(.notInitialized) }
        var properties: [String: Any] = ["source": "superwall"]
        if let params {
            properties.merge(params) { _, new in new }
        }
        return layers.track("superwall_\(eventName)", properties: properties)
    }

    // MARK: - Typed Paywall Events

    /// Track that a paywall was presented to the user.
    ///
    /// - Parameters:
    ///   - paywallId: The paywall identifier from `PaywallInfo.identifier`.
    ///   - placement: The paywall name/placement from `PaywallInfo.name`.
    ///   - experimentId: Optional A/B test experiment ID.
    ///   - variantId: Optional A/B test variant ID.
    @discardableResult
    public func trackPresentation(
        paywallId: String,
        placement: String? = nil,
        experimentId: String? = nil,
        variantId: String? = nil
    ) -> SafeResult<Void> {
        guard let layers = lockedLayers else { return .failure(.notInitialized) }
        var properties: [String: Any] = [
            "paywall_id": paywallId,
            "placement": placement ?? "unknown",
            "source": "superwall"
        ]
        if let experimentId, let variantId {
            properties["ab_test"] = [
                "id": experimentId,
                "variant": variantId
            ]
        }
        return layers.track("paywall_show", properties: properties)
    }

    /// Track that a paywall was dismissed.
    ///
    /// - Parameter paywallId: The paywall identifier from `PaywallInfo.identifier`.
    @discardableResult
    public func trackDismiss(paywallId: String) -> SafeResult<Void> {
        guard let layers = lockedLayers else { return .failure(.notInitialized) }
        return layers.track("paywall_dismiss", properties: [
            "paywall_id": paywallId,
            "source": "superwall"
        ])
    }

    /// Track a purchase initiated from a Superwall paywall.
    ///
    /// - Parameters:
    ///   - paywallId: The paywall identifier.
    ///   - productId: The product identifier (e.g. App Store product ID).
    ///   - price: The product price, if available.
    ///   - currency: The currency code (e.g. `"USD"`), if available.
    @discardableResult
    public func trackPurchase(
        paywallId: String,
        productId: String? = nil,
        price: Decimal? = nil,
        currency: String? = nil
    ) -> SafeResult<Void> {
        guard let layers = lockedLayers else { return .failure(.notInitialized) }
        var properties: [String: Any] = [
            "paywall_id": paywallId,
            "source": "superwall"
        ]
        if let productId { properties["product_id"] = productId }
        if let price { properties["price"] = NSDecimalNumber(decimal: price).doubleValue }
        if let currency { properties["currency"] = currency }
        return layers.track("paywall_purchase", properties: properties)
    }

    /// Track that a paywall was skipped (e.g. user holdout, no rule match).
    ///
    /// - Parameters:
    ///   - paywallId: The paywall identifier, if available.
    ///   - reason: The reason the paywall was skipped (e.g. `"holdout"`,
    ///     `"no_rule_match"`, `"user_is_subscribed"`).
    @discardableResult
    public func trackSkip(paywallId: String? = nil, reason: String) -> SafeResult<Void> {
        guard let layers = lockedLayers else { return .failure(.notInitialized) }
        return layers.track("paywall_skip", properties: [
            "paywall_id": paywallId ?? "unknown",
            "reason": reason,
            "source": "superwall"
        ])
    }

    // MARK: - User Attributes

    /// Pass Layers attribution data to Superwall as user attributes.
    ///
    /// Call this after Layers is initialized to sync attribution data.
    /// Returns a dictionary suitable for passing to
    /// `Superwall.instance.setUserAttributes(_:)`.
    ///
    /// ```swift
    /// let attrs = Layers.shared.superwall.userAttributes()
    /// Superwall.instance.setUserAttributes(attrs)
    /// ```
    public func userAttributes() -> [String: Any] {
        guard let layers = lockedLayers else { return [:] }
        var attrs: [String: Any] = [:]
        let installId = Layers.getOrCreateInstallId()
        attrs["layers_id"] = installId
        let anonId = layers.anonymousId
        if !anonId.isEmpty {
            attrs["layers_anonymous_id"] = anonId
        }
        if let userId = layers.appUserId {
            attrs["layers_user_id"] = userId
        }
        if let sessionId = layers.sessionId {
            attrs["layers_session_id"] = sessionId
        }
        return attrs
    }
}
