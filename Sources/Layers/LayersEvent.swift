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
    case appInstall = "app_install"
    case appOpen = "app_open"
    case login = "login"
    case signUp = "sign_up"
    case register = "register"
    case purchase = "purchase_success"
    case addToCart = "add_to_cart"
    case addToWishlist = "add_to_wishlist"
    case initiateCheckout = "initiate_checkout"
    case beginCheckout = "begin_checkout"
    case startTrial = "start_trial"
    case subscribe = "subscribe"
    case levelStart = "level_start"
    case levelComplete = "level_complete"
    case tutorialComplete = "tutorial_complete"
    case search = "search"
    case viewItem = "view_item"
    case viewContent = "view_content"
    case share = "share"
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

    /// Create a login event with optional method (e.g. "email", "google", "apple").
    public static func login(method: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = [:]
        if let method { props["method"] = method }
        return ParameterizedEvent(eventName: Self.login.rawValue, properties: props)
    }

    /// Create a sign-up event with optional method.
    public static func signUp(method: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = [:]
        if let method { props["method"] = method }
        return ParameterizedEvent(eventName: Self.signUp.rawValue, properties: props)
    }

    /// Create a register event with optional method.
    public static func register(method: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = [:]
        if let method { props["method"] = method }
        return ParameterizedEvent(eventName: Self.register.rawValue, properties: props)
    }

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

    /// Create an add-to-wishlist event with item ID and optional name/price.
    public static func addToWishlist(itemId: String, name: String? = nil, price: Double? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["item_id": itemId]
        if let name { props["name"] = name }
        if let price { props["price"] = price }
        return ParameterizedEvent(eventName: Self.addToWishlist.rawValue, properties: props)
    }

    /// Create an initiate-checkout event with total value and optional currency/item count.
    public static func initiateCheckout(value: Double, currency: String = "USD", itemCount: Int? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["value": value, "currency": currency]
        if let itemCount { props["item_count"] = itemCount }
        return ParameterizedEvent(eventName: Self.initiateCheckout.rawValue, properties: props)
    }

    /// Create a start-trial event with optional trial plan and duration.
    public static func startTrial(plan: String? = nil, durationDays: Int? = nil) -> ParameterizedEvent {
        var props: [String: Any] = [:]
        if let plan { props["plan"] = plan }
        if let durationDays { props["duration_days"] = durationDays }
        return ParameterizedEvent(eventName: Self.startTrial.rawValue, properties: props)
    }

    /// Create a subscribe event with plan, amount, and optional currency.
    public static func subscribe(plan: String, amount: Double, currency: String = "USD") -> ParameterizedEvent {
        return ParameterizedEvent(eventName: Self.subscribe.rawValue, properties: [
            "plan": plan,
            "amount": amount,
            "currency": currency,
        ])
    }

    /// Create a level-start event with level name or number.
    public static func levelStart(level: String) -> ParameterizedEvent {
        return ParameterizedEvent(eventName: Self.levelStart.rawValue, properties: [
            "level": level,
        ])
    }

    /// Create a level-complete event with level name and optional score.
    public static func levelComplete(level: String, score: Int? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["level": level]
        if let score { props["score"] = score }
        return ParameterizedEvent(eventName: Self.levelComplete.rawValue, properties: props)
    }

    /// Create a tutorial-complete event with optional tutorial name.
    public static func tutorialComplete(name: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = [:]
        if let name { props["name"] = name }
        return ParameterizedEvent(eventName: Self.tutorialComplete.rawValue, properties: props)
    }

    /// Create a search event with search term and optional result count.
    public static func search(query: String, resultCount: Int? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["query": query]
        if let resultCount { props["result_count"] = resultCount }
        return ParameterizedEvent(eventName: Self.search.rawValue, properties: props)
    }

    /// Create a view-content event with content ID and optional content type/name.
    public static func viewContent(contentId: String, contentType: String? = nil, name: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["content_id": contentId]
        if let contentType { props["content_type"] = contentType }
        if let name { props["name"] = name }
        return ParameterizedEvent(eventName: Self.viewContent.rawValue, properties: props)
    }

    /// Create a share event with content type and optional method/content ID.
    public static func share(contentType: String, method: String? = nil, contentId: String? = nil) -> ParameterizedEvent {
        var props: [String: Any] = ["content_type": contentType]
        if let method { props["method"] = method }
        if let contentId { props["content_id"] = contentId }
        return ParameterizedEvent(eventName: Self.share.rawValue, properties: props)
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
