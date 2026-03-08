# Layers iOS SDK

The Layers iOS SDK provides analytics, attribution, and monetization tracking for iOS and macOS apps. It features event tracking, screen tracking, user identification, App Tracking Transparency (ATT), SKAdNetwork (SKAN), deep link handling, StoreKit commerce tracking, AdServices attribution, and clipboard-based deferred deep links.

## Requirements

- iOS 14.0+ / macOS 12.0+ / tvOS 14.0+ / watchOS 7.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add the Layers SDK to your project using Xcode:

1. Go to **File > Add Package Dependencies...**
2. Enter the repository URL: `https://github.com/layers/layers-sdk-ios`
3. Select your version rule (e.g. "Up to Next Major")
4. Add the `Layers` library to your target

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/layers/layers-sdk-ios", from: "2.0.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "Layers", package: "layers-sdk-ios")
    ]
)
```

## Quick Start

```swift
import Layers

// Initialize in your AppDelegate or App init
let config = LayersConfig(
    appId: "your-app-id",
    environment: .production
)
Layers.initialize(config: config)

// Track events
Layers.track("button_tapped", properties: ["button_name": "signup"])

// Track screen views
Layers.screen("Home")

// Identify users
Layers.identify(userId: "user_123", traits: ["plan": "premium"])
```

## Configuration

### LayersConfig

| Parameter | Type | Default | Description |
|---|---|---|---|
| `appId` | `String` | *required* | Your Layers application identifier. |
| `environment` | `Environment` | `.production` | Deployment environment: `.development`, `.staging`, or `.production`. |
| `enableDebug` | `Bool` | `false` | Enable verbose debug logging via `os_log`. |
| `flushQueueSize` | `UInt32` | `20` | Number of queued events that triggers an automatic flush. |
| `flushIntervalSecs` | `UInt32` | `30` | How often (in seconds) the event queue is flushed automatically. |
| `maxQueueSize` | `UInt32` | `10000` | Maximum number of events to hold in the queue before dropping the oldest. |
| `baseUrl` | `String?` | `nil` | Custom base URL for the ingest API. Uses the production endpoint when `nil`. |
| `autoTrackAppOpen` | `Bool` | `true` | Whether to automatically fire an `app_open` event during initialization. Set to `false` to fire it manually. |

```swift
let config = LayersConfig(
    appId: "your-app-id",
    environment: .development,
    enableDebug: true,
    flushQueueSize: 10,
    flushIntervalSecs: 15,
    maxQueueSize: 5000,
    autoTrackAppOpen: true
)
```

### Environment

```swift
public enum Environment: String, Sendable {
    case development
    case staging
    case production
}
```

## Core API

The SDK is accessed through the `Layers.shared` singleton. All public methods are also available as static methods on the `Layers` class for convenience. Every method returns a `SafeResult<T>` -- the SDK is guaranteed to never throw or crash your app.

### SafeResult

```swift
public enum SafeResult<T: Sendable>: Sendable {
    case success(T)
    case failure(LayersError)
}
```

### Initialization

```swift
// Static convenience
@discardableResult
static func initialize(config: LayersConfig) -> SafeResult<Void>

// Instance method
@discardableResult
func initialize(config: LayersConfig) -> SafeResult<Void>
```

Initializes the SDK. Loads persisted events, collects device info, fetches remote config, and fires an `app_open` event (unless `autoTrackAppOpen` is `false`). Idempotent -- calling again after successful init returns `.success` immediately.

### Event Tracking

```swift
// Track a custom event
@discardableResult
static func track(_ event: String, properties: [String: Any] = [:]) -> SafeResult<Void>

// Track a typed event conforming to LayersEvent
@discardableResult
static func track(_ event: some LayersEvent) -> SafeResult<Void>
```

```swift
Layers.track("purchase_completed", properties: [
    "product_id": "sku_123",
    "price": 9.99,
    "currency": "USD"
])
```

### Typed Events (LayersEvent protocol)

Define your own event types for type safety:

```swift
public protocol LayersEvent {
    var eventName: String { get }
    var properties: [String: Any] { get }
}
```

```swift
struct PurchaseEvent: LayersEvent {
    let eventName = "purchase_completed"
    let productId: String
    let price: Double

    var properties: [String: Any] {
        ["product_id": productId, "price": price]
    }
}

Layers.track(PurchaseEvent(productId: "sku_123", price: 9.99))
```

### Screen Tracking

```swift
@discardableResult
static func screen(_ name: String, properties: [String: Any] = [:]) -> SafeResult<Void>
```

```swift
Layers.screen("ProductDetail", properties: ["product_id": "sku_123"])
```

### User Identity

```swift
// Identify a user with optional traits
@discardableResult
static func identify(userId: String, traits: [String: Any] = [:]) -> SafeResult<Void>

// Set the app user ID (without traits)
@discardableResult
static func setAppUserId(_ userId: String) -> SafeResult<Void>

// Clear the current user ID
@discardableResult
static func clearAppUserId() -> SafeResult<Void>

// Set user properties independently
@discardableResult
static func setUserProperties(_ properties: [String: Any]) -> SafeResult<Void>
```

```swift
// After login
Layers.identify(userId: "user_123", traits: [
    "email": "user@example.com",
    "plan": "premium",
    "signup_date": "2024-01-15"
])

// Update properties later
Layers.setUserProperties(["subscription_status": "active"])

// On logout
Layers.clearAppUserId()
```

### Consent Management

```swift
@discardableResult
static func setConsent(_ consent: ConsentSettings) -> SafeResult<Void>
```

```swift
public struct ConsentSettings: Sendable, Equatable {
    public var analytics: Bool?
    public var advertising: Bool?

    public static let denied    // analytics: false, advertising: false
    public static let full      // analytics: true, advertising: true
}
```

```swift
// User accepts all tracking
Layers.setConsent(.full)

// User opts out of advertising only
Layers.setConsent(ConsentSettings(analytics: true, advertising: false))

// User denies all
Layers.setConsent(.denied)
```

### Flush & Lifecycle

```swift
// Async flush (preferred)
static func flush() async -> SafeResult<Void>

// Synchronous flush (blocks calling thread -- avoid on main thread)
@discardableResult
static func flushBlocking() -> SafeResult<Void>

// Reset user identity and properties
@discardableResult
static func reset() -> SafeResult<Void>

// Shut down the SDK and release resources
@discardableResult
static func shutdown() -> SafeResult<Void>
```

The SDK automatically flushes when the app enters the background and on a periodic timer.

### Read-Only Properties

```swift
// Whether the SDK has been initialized
Layers.shared.isInitialized: Bool

// The current app user ID, or nil
Layers.shared.appUserId: String?

// The current anonymous ID
Layers.shared.anonymousId: String

// The current session ID, or nil if not initialized
Layers.shared.sessionId: String?

// Number of events in the queue, or nil if not initialized
Layers.shared.queueDepth: Int?
```

### Debug

```swift
static func debugStatus() -> String
```

Returns a formatted string with the current SDK state, including initialization status, user IDs, session ID, queue depth, SKAN support, and ATT status.

## App Tracking Transparency (ATT)

Access the ATT module via `Layers.shared.att`.

### ATT API

```swift
// Get the current ATT authorization status
func getStatus() -> ATTModule.Status

// Request tracking authorization (shows system dialog)
func requestTracking() async -> SafeResult<ATTModule.Status>

// Whether ATT is supported on this device
func isSupported() -> Bool

// Whether the user has already been prompted
func hasBeenPrompted() -> Bool

// Get IDFA (nil if not authorized)
func getAdvertisingId() -> String?

// Get IDFV (always available, no ATT required)
func getVendorId() -> String?
```

### ATT Status

```swift
public enum Status: String, Sendable {
    case notDetermined = "not_determined"
    case restricted
    case denied
    case authorized
    case unknown
}
```

### ATT Usage

```swift
// Request ATT permission (e.g. after onboarding)
let result = await Layers.shared.att.requestTracking()
switch result {
case .success(let status):
    print("ATT status: \(status)")
case .failure(let error):
    print("ATT error: \(error)")
}

// The SDK automatically:
// - Updates device context with IDFA (if authorized) and IDFV
// - Syncs ATT status to the analytics pipeline
```

> **Important**: Add `NSUserTrackingUsageDescription` to your `Info.plist` to explain why you need tracking permission.

## SKAdNetwork (SKAN)

Access the SKAN module via `Layers.shared.skan`. SKAN is auto-configured from the server's remote config -- you typically do not need to call these methods manually.

### SKAN API

```swift
// Set a preset configuration (subscriptions, ecommerce, gaming)
@discardableResult
func setPreset(_ preset: SKANModule.Preset) -> SafeResult<Void>

// Set custom conversion rules from JSON
@discardableResult
func setRules(_ rulesJson: String) -> SafeResult<Void>

// Process an event through SKAN rules
@discardableResult
func processEvent(eventName: String, properties: [String: String] = [:]) -> SafeResult<Int>

// Register app for SKAN attribution
@discardableResult
func registerForAttribution() -> SafeResult<Void>

// Query SKAN support
func isSupported() -> Bool
func getVersion() -> String    // "2.0", "2.1", "3.0", "4.0", or "unsupported"
func supportsSKAN4() -> Bool
```

### SKAN Presets

```swift
public enum Preset: String, Sendable {
    case subscriptions
    case ecommerce
    case gaming
    case custom
}
```

> **Note**: SKAN is typically managed server-side via remote config. The server's `skan` section drives which preset or custom rules are applied, so you usually don't need to call `setPreset()` or `setRules()` manually.

## Deep Links

Access the deep links module via `Layers.shared.deepLinks`.

### Deep Links API

```swift
// Handle an incoming deep link URL
@discardableResult
func handleDeepLink(_ url: URL) -> SafeResult<Void>

// Parse a URL string without tracking
func parseUrl(_ urlString: String) -> DeepLinksModule.DeepLinkData?

// Register a deep link listener (returns unsubscribe closure)
@discardableResult
func addListener(_ listener: DeepLinksModule.Listener) -> @Sendable () -> Void

// Remove all listeners
func removeAllListeners()
```

### Integration with AppDelegate

```swift
// URL scheme deep links
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) -> Bool {
    Layers.shared.deepLinks.handleDeepLink(url)
    return true
}

// Universal Links
func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if let url = userActivity.webpageURL {
        Layers.shared.deepLinks.handleDeepLink(url)
    }
    return true
}
```

### Integration with SwiftUI

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Layers.shared.deepLinks.handleDeepLink(url)
                }
        }
    }
}
```

### Deep Link Listener

```swift
let unsubscribe = Layers.shared.deepLinks.addListener(
    DeepLinksModule.Listener { data, attribution in
        print("Deep link: \(data.url)")
        print("Source: \(attribution.source ?? "none")")
        print("Campaign: \(attribution.campaign ?? "none")")
        print("Is Universal Link: \(data.isUniversalLink)")

        // UTM parameters
        if let source = attribution.source {
            print("utm_source: \(source)")
        }

        // Click IDs (fbclid, gclid, ttclid, etc.)
        for (key, value) in attribution.clickIds {
            print("\(key): \(value)")
        }
    }
)

// Later: unsubscribe()
```

### DeepLinkData

```swift
public struct DeepLinkData: Sendable {
    public let url: URL
    public let scheme: String?
    public let host: String?
    public let path: String
    public let queryParameters: [String: String]
    public let isUniversalLink: Bool
}
```

### AttributionData

Automatically extracted from deep link query parameters:

```swift
public struct AttributionData: Sendable {
    public let source: String?     // utm_source
    public let medium: String?     // utm_medium
    public let campaign: String?   // utm_campaign
    public let content: String?    // utm_content
    public let term: String?       // utm_term
    public let clickIds: [String: String]  // gclid, fbclid, ttclid, etc.
}
```

When `handleDeepLink()` is called, the SDK automatically tracks a `deep_link_opened` event with the URL, UTM params, and click IDs as properties.

## Commerce (StoreKit)

Access the commerce module via `Layers.shared.commerce`.

### Commerce API

```swift
// Track a purchase
@discardableResult
func trackPurchase(transaction: CommerceModule.Transaction) -> SafeResult<Void>

// Track an order with multiple items
@discardableResult
func trackOrder(_ order: CommerceModule.Order) -> SafeResult<Void>

// Track add to cart
@discardableResult
func trackAddToCart(_ item: CommerceModule.CartItem) -> SafeResult<Void>

// Track remove from cart
@discardableResult
func trackRemoveFromCart(_ item: CommerceModule.CartItem) -> SafeResult<Void>

// Track checkout initiation
@discardableResult
func trackBeginCheckout(items: [CommerceModule.CartItem], currency: String = "USD") -> SafeResult<Void>

// Track product view
@discardableResult
func trackViewProduct(productId: String, name: String, price: Decimal, currency: String = "USD", category: String? = nil) -> SafeResult<Void>

// Track refund
@discardableResult
func trackRefund(transactionId: String, amount: Decimal, currency: String, reason: String? = nil) -> SafeResult<Void>

// Track a StoreKit 2 transaction directly (iOS 15+)
@discardableResult
func trackStoreKit2Transaction(_ skTransaction: StoreKit.Transaction) -> SafeResult<Void>
```

### Purchase Tracking

```swift
let transaction = CommerceModule.Transaction(
    transactionId: "txn_abc123",
    productId: "com.myapp.premium",
    price: 9.99,
    currency: "USD",
    quantity: 1,
    subscriptionGroupId: "group_1"
)
Layers.shared.commerce.trackPurchase(transaction: transaction)
```

### StoreKit 2 Integration

```swift
// Observe StoreKit 2 transactions
for await result in StoreKit.Transaction.updates {
    guard case .verified(let transaction) = result else { continue }
    Layers.shared.commerce.trackStoreKit2Transaction(transaction)
    await transaction.finish()
}
```

### Order Tracking

```swift
let order = CommerceModule.Order(
    orderId: "order_456",
    items: [
        CommerceModule.CartItem(productId: "sku_1", name: "T-Shirt", price: 29.99),
        CommerceModule.CartItem(productId: "sku_2", name: "Hoodie", price: 59.99, quantity: 2)
    ],
    subtotal: 149.97,
    tax: 12.00,
    shipping: 5.99,
    discount: 10.00,
    currency: "USD",
    couponCode: "SAVE10"
)
Layers.shared.commerce.trackOrder(order)
```

## AdServices Attribution

Access the AdServices module via `Layers.shared.adServices`. This collects the Apple Search Ads attribution token (iOS 14.3+) without requiring ATT consent. The token is automatically included in the `app_open` event.

```swift
// Check if AdServices is available
Layers.shared.adServices.isAvailable()  // true on iOS 14.3+

// The token is auto-collected during init. Access the cached value:
let token = Layers.shared.adServices.cachedToken
```

## Clipboard Attribution (Deferred Deep Links)

Access the clipboard module via `Layers.shared.clipboard`. On iOS, when a user clicks an ad, the landing page may copy a click URL to the clipboard. On first launch, the SDK reads the clipboard for a Layers attribution URL and includes it in the `app_open` event.

This feature is controlled by the server's remote config (`clipboard_attribution_enabled`). On iOS 16+, the system shows a paste consent dialog.

```swift
// The cached URL after init, if found:
let url = Layers.shared.clipboard.cachedUrl
```

## Automatic Behaviors

The SDK handles the following automatically:

- **app_open event**: Tracked on init with AdServices token and clipboard attribution (if enabled).
- **Background flush**: Events are flushed when the app enters the background.
- **Periodic flush**: Events are flushed on a timer (configurable via `flushIntervalSecs`).
- **Remote config polling**: Server-driven configuration is fetched every 5 minutes.
- **SKAN auto-config**: SKAN preset/rules are applied from remote config.
- **Device context**: OS version, device model, locale, screen size, timezone, install ID, IDFV, and ATT status are collected automatically.
- **Event persistence**: Events are persisted to disk and rehydrated on restart.
- **Retry with backoff**: Failed network requests are retried with exponential backoff.
- **Circuit breaker**: Repeated failures temporarily disable network calls to protect your app.

## Privacy Manifest

The SDK includes a `PrivacyInfo.xcprivacy` file that declares the data types collected and the reasons for collection, as required by Apple's privacy requirements.

## Error Handling

All methods return `SafeResult<T>`. The SDK never throws or crashes.

```swift
public enum LayersError: Error, LocalizedError, Sendable, Equatable {
    case notInitialized
    case invalidConfig(String)
    case networkError(String)
    case persistenceError(String)
    case queueFull
    case circuitBreakerOpen
    case rateLimited
    case unknown(String)
}
```

```swift
let result = Layers.track("event_name")
switch result {
case .success:
    break // Event queued
case .failure(let error):
    print("Error: \(error.localizedDescription)")
}
```

## Thread Safety

The `Layers` class and all its modules are thread-safe. You can call any method from any thread or queue.
