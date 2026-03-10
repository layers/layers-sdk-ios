import Foundation

/// Protocol for typed events. Conform to this protocol to create custom event types
/// that can be passed to `Layers.track(_:)`.
///
/// The `properties` dictionary uses `[String: Any]` because analytics payloads are inherently
/// heterogeneous (strings, numbers, booleans, nested arrays). Values must be JSON-serializable
/// via `JSONSerialization`. For richer parameterized events, use the `StandardEvent.with(...)` builders.
///
/// Example:
/// ```swift
/// struct ButtonTapped: LayersEvent {
///     let buttonId: String
///     var eventName: String { "button_tapped" }
///     var properties: [String: Any] { ["button_id": buttonId] }
/// }
/// Layers.track(ButtonTapped(buttonId: "cta_signup"))
/// ```
public protocol LayersEvent {
    var eventName: String { get }
    /// Event properties. Values must be JSON-serializable (String, NSNumber, Bool, Array, Dictionary).
    var properties: [String: Any] { get }
}

/// Predefined standard events matching common analytics patterns.
///
/// Use the enum cases directly for simple tracking, or use the static `.with(...)` builders
/// for parameterized events:
/// ```swift
/// Layers.track(StandardEvent.purchase(amount: 9.99, currency: "USD", itemId: "sku_123"))
/// Layers.track(StandardEvent.viewItem(itemId: "sku_123", name: "Blue Widget"))
/// ```
public enum StandardEvent: String, LayersEvent, Sendable {
    case appOpen = "app_open"
    case purchase = "purchase_success"
    case viewItem = "view_item"
    case addToCart = "add_to_cart"
    case beginCheckout = "begin_checkout"
    case deepLink = "deep_link_opened"
    case screenView = "screen_view"

    public var eventName: String { rawValue }
    public var properties: [String: Any] { [:] }
}

// MARK: - Parameterized Standard Events

/// Parameterized event wrapper that carries properties alongside a standard event name.
public struct ParameterizedEvent: LayersEvent, Sendable {
    public let eventName: String
    public let properties: [String: Any]

    // Sendable conformance: [String: Any] is not automatically Sendable, but we only store
    // JSON-serializable primitives (String, NSNumber, Bool) which are all Sendable values.
    // This is safe for cross-isolation use.

    init(eventName: String, properties: [String: Any]) {
        self.eventName = eventName
        self.properties = properties
    }
}

extension StandardEvent {

    /// Create a purchase event with amount, currency, and optional item ID.
    public static func purchase(amount: Double, currency: String = "USD", itemId: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["amount": amount, "currency": currency]
        if let itemId { props["item_id"] = itemId }
        return ParameterizedEvent(eventName: Self.purchase.rawValue, properties: props)
    }

    /// Create a view item event with item ID and optional name/category.
    public static func viewItem(itemId: String, name: String? = nil, category: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["item_id": itemId]
        if let name { props["name"] = name }
        if let category { props["category"] = category }
        return ParameterizedEvent(eventName: Self.viewItem.rawValue, properties: props)
    }

    /// Create an add-to-cart event with item ID, price, and optional quantity.
    public static func addToCart(itemId: String, price: Double, quantity: Int = 1) -> ParameterizedEvent {
        return ParameterizedEvent(eventName: Self.addToCart.rawValue, properties: [
            "item_id": itemId,
            "price": price,
            "quantity": quantity,
        ])
    }

    /// Create a begin-checkout event with total value and optional currency/item count.
    public static func beginCheckout(value: Double, currency: String = "USD", itemCount: Int? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["value": value, "currency": currency]
        if let itemCount { props["item_count"] = itemCount }
        return ParameterizedEvent(eventName: Self.beginCheckout.rawValue, properties: props)
    }

    /// Create a deep link event with the originating URL.
    public static func deepLink(url: String, source: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["url": url]
        if let source { props["utm_source"] = source }
        return ParameterizedEvent(eventName: Self.deepLink.rawValue, properties: props)
    }

    /// Create a screen view event with screen name and optional class.
    public static func screenView(name: String, screenClass: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["screen_name": name]
        if let screenClass { props["screen_class"] = screenClass }
        return ParameterizedEvent(eventName: Self.screenView.rawValue, properties: props)
    }
}
