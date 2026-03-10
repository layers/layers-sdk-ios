import Foundation
import Layers

/// In-memory mock of the Layers SDK for unit tests.
///
/// All calls are recorded and can be inspected via the `*Calls` arrays.
/// Methods return `.success(())` by default; override with `stubbedResult` to simulate errors.
///
/// Usage:
/// ```swift
/// let mock = MockLayers()
/// viewModel.analytics = mock
/// viewModel.doSomething()
/// XCTAssertEqual(mock.trackCalls.count, 1)
/// XCTAssertEqual(mock.trackCalls[0].event, "button_tapped")
/// ```
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class MockLayers: LayersProtocol, @unchecked Sendable {

    // MARK: - Stub Control

    /// Default result returned by all methods. Set to `.failure(...)` to simulate errors.
    public var stubbedResult: SafeResult<Void> = .success(())

    // MARK: - Recorded Calls

    public private(set) var trackCalls: [(event: String, properties: [String: Any])] = []
    /// Typed events recorded via `track(_ event: some LayersEvent)`, preserving the original event type.
    public private(set) var typedTrackCalls: [any LayersEvent] = []
    public private(set) var screenCalls: [(name: String, properties: [String: Any])] = []
    public private(set) var identifyCalls: [(userId: String, traits: [String: Any])] = []
    public private(set) var setUserPropertiesCalls: [[String: Any]] = []
    public private(set) var setUserPropertiesOnceCalls: [[String: Any]] = []
    public private(set) var setAppUserIdCalls: [String] = []
    public private(set) var clearAppUserIdCallCount: Int = 0
    public private(set) var setConsentCalls: [ConsentSettings] = []
    public private(set) var flushCallCount: Int = 0
    public private(set) var flushBlockingCallCount: Int = 0
    public private(set) var resetCallCount: Int = 0
    public private(set) var shutdownCallCount: Int = 0

    // MARK: - State

    public var sessionId: String?
    public var isInitialized: Bool = true
    public var appUserId: String?
    public var anonymousId: String = "mock-anonymous-id"
    public var queueDepth: Int? = 0

    // MARK: - Init

    public init() {}

    // MARK: - Reset Recorded State

    /// Clear all recorded calls. Useful in `setUp()`.
    public func resetMock() {
        trackCalls = []
        typedTrackCalls = []
        screenCalls = []
        identifyCalls = []
        setUserPropertiesCalls = []
        setUserPropertiesOnceCalls = []
        setAppUserIdCalls = []
        clearAppUserIdCallCount = 0
        setConsentCalls = []
        flushCallCount = 0
        flushBlockingCallCount = 0
        resetCallCount = 0
        shutdownCallCount = 0
    }

    // MARK: - LayersProtocol

    @discardableResult
    public func initialize(config: LayersConfig) -> SafeResult<Void> {
        isInitialized = true
        return stubbedResult
    }

    @discardableResult
    public func track(_ event: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        trackCalls.append((event, properties))
        return stubbedResult
    }

    /// Track a typed event. Records to both `trackCalls` (flattened) and `typedTrackCalls` (preserving type).
    @discardableResult
    public func track(_ event: some LayersEvent) -> SafeResult<Void> {
        typedTrackCalls.append(event)
        return track(event.eventName, properties: event.properties)
    }

    @discardableResult
    public func screen(_ name: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        screenCalls.append((name, properties))
        return stubbedResult
    }

    @discardableResult
    public func identify(userId: String, traits: [String: Any] = [:]) -> SafeResult<Void> {
        identifyCalls.append((userId, traits))
        appUserId = userId.isEmpty ? nil : userId
        return stubbedResult
    }

    @discardableResult
    public func setUserProperties(_ properties: [String: Any]) -> SafeResult<Void> {
        setUserPropertiesCalls.append(properties)
        return stubbedResult
    }

    @discardableResult
    public func setUserPropertiesOnce(_ properties: [String: Any]) -> SafeResult<Void> {
        setUserPropertiesOnceCalls.append(properties)
        return stubbedResult
    }

    @discardableResult
    public func setAppUserId(_ userId: String) -> SafeResult<Void> {
        setAppUserIdCalls.append(userId)
        appUserId = userId.isEmpty ? nil : userId
        return stubbedResult
    }

    @discardableResult
    public func clearAppUserId() -> SafeResult<Void> {
        clearAppUserIdCallCount += 1
        appUserId = nil
        return stubbedResult
    }

    @discardableResult
    public func setConsent(_ consent: ConsentSettings) -> SafeResult<Void> {
        setConsentCalls.append(consent)
        return stubbedResult
    }

    public func flush() async -> SafeResult<Void> {
        flushCallCount += 1
        return stubbedResult
    }

    @discardableResult
    public func flushBlocking() -> SafeResult<Void> {
        flushBlockingCallCount += 1
        return stubbedResult
    }

    @discardableResult
    public func reset() -> SafeResult<Void> {
        resetCallCount += 1
        appUserId = nil
        return stubbedResult
    }

    @discardableResult
    public func shutdown() -> SafeResult<Void> {
        shutdownCallCount += 1
        isInitialized = false
        return stubbedResult
    }

    public func debugStatus() -> String {
        return "MockLayers(initialized: \(isInitialized), appUserId: \(appUserId ?? "nil"))"
    }
}
