import Foundation

/// Protocol abstracting the Layers SDK public API, enabling dependency injection and mocking in tests.
///
/// Inject `any LayersProtocol` into your view models and services instead of calling `Layers.shared`
/// directly. In production pass `Layers.shared`; in tests pass `MockLayers` from the `LayersTesting` library.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public protocol LayersProtocol {

    // MARK: - Initialization

    @discardableResult
    func initialize(config: LayersConfig) -> SafeResult<Void>

    // MARK: - Event Tracking

    @discardableResult
    func track(_ event: String, properties: [String: Any]) -> SafeResult<Void>

    @discardableResult
    func track(_ event: some LayersEvent) -> SafeResult<Void>

    @discardableResult
    func screen(_ name: String, properties: [String: Any]) -> SafeResult<Void>

    // MARK: - User Identity

    @discardableResult
    func identify(userId: String, traits: [String: Any]) -> SafeResult<Void>

    @discardableResult
    func setUserProperties(_ properties: [String: Any]) -> SafeResult<Void>

    @discardableResult
    func setUserPropertiesOnce(_ properties: [String: Any]) -> SafeResult<Void>

    @discardableResult
    func setAppUserId(_ userId: String) -> SafeResult<Void>

    @discardableResult
    func clearAppUserId() -> SafeResult<Void>

    // MARK: - Consent

    @discardableResult
    func setConsent(_ consent: ConsentSettings) -> SafeResult<Void>

    // MARK: - Flush & Reset

    func flush() async -> SafeResult<Void>

    @discardableResult
    func flushBlocking() -> SafeResult<Void>

    @discardableResult
    func reset() -> SafeResult<Void>

    @discardableResult
    func shutdown() -> SafeResult<Void>

    // MARK: - State

    var sessionId: String? { get }
    var isInitialized: Bool { get }
    var appUserId: String? { get }
    var anonymousId: String { get }
    var queueDepth: Int? { get }

    // MARK: - Debug

    func debugStatus() -> String
}
