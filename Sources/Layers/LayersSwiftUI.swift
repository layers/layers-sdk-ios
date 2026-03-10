#if canImport(SwiftUI) && canImport(Combine)
import SwiftUI
import Combine

// MARK: - LayersObservable

/// ObservableObject wrapper around `Layers.shared` for SwiftUI integration.
///
/// Publishes reactive state that SwiftUI views can observe:
/// ```swift
/// struct ContentView: View {
///     @StateObject private var layers = LayersObservable()
///
///     var body: some View {
///         Text("Session: \(layers.sessionId ?? "none")")
///             .onAppear {
///                 layers.initialize(config: myConfig)
///             }
///             .onOpenURL { url in
///                 LayersObservable.handleDeepLink(url: url)
///             }
///     }
/// }
/// ```
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
@MainActor
public final class LayersObservable: ObservableObject {

    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var sessionId: String?
    @Published public private(set) var appUserId: String?

    private let sdk: Layers

    public init(sdk: Layers = .shared) {
        self.sdk = sdk
        syncState()
    }

    // MARK: - Initialization

    /// Initialize the SDK and update published state.
    @discardableResult
    public func initialize(config: LayersConfig) -> SafeResult<Void> {
        let result = sdk.initialize(config: config)
        syncState()
        return result
    }

    // MARK: - Event Tracking

    @discardableResult
    public func track(_ event: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        sdk.track(event, properties: properties)
    }

    @discardableResult
    public func track(_ event: some LayersEvent) -> SafeResult<Void> {
        sdk.track(event)
    }

    @discardableResult
    public func screen(_ name: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        sdk.screen(name, properties: properties)
    }

    // MARK: - User Identity

    @discardableResult
    public func identify(userId: String, traits: [String: Any] = [:]) -> SafeResult<Void> {
        let result = sdk.identify(userId: userId, traits: traits)
        syncState()
        return result
    }

    @discardableResult
    public func setAppUserId(_ userId: String) -> SafeResult<Void> {
        let result = sdk.setAppUserId(userId)
        syncState()
        return result
    }

    @discardableResult
    public func clearAppUserId() -> SafeResult<Void> {
        let result = sdk.clearAppUserId()
        syncState()
        return result
    }

    @discardableResult
    public func reset() -> SafeResult<Void> {
        let result = sdk.reset()
        syncState()
        return result
    }

    // MARK: - User Properties

    @discardableResult
    public func setUserProperties(_ properties: [String: Any]) -> SafeResult<Void> {
        sdk.setUserProperties(properties)
    }

    // MARK: - Consent

    @discardableResult
    public func setConsent(_ consent: ConsentSettings) -> SafeResult<Void> {
        sdk.setConsent(consent)
    }

    // MARK: - Flush & Shutdown

    public func flush() async -> SafeResult<Void> {
        await sdk.flush()
    }

    @discardableResult
    public func shutdown() -> SafeResult<Void> {
        let result = sdk.shutdown()
        syncState()
        return result
    }

    // MARK: - Deep Link Convenience

    /// Handle a deep link URL via the SDK's DeepLinksModule.
    /// Designed for use with SwiftUI's `.onOpenURL` modifier:
    /// ```swift
    /// .onOpenURL { url in
    ///     LayersObservable.handleDeepLink(url: url)
    /// }
    /// ```
    @discardableResult
    public nonisolated static func handleDeepLink(url: URL) -> SafeResult<Void> {
        Layers.shared.deepLinks.handleDeepLink(url)
    }

    // MARK: - Private

    private func syncState() {
        isInitialized = sdk.isInitialized
        sessionId = sdk.sessionId
        appUserId = sdk.appUserId
    }
}

// MARK: - Environment Key

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
@MainActor
private struct LayersEnvironmentKey: EnvironmentKey {
    static let defaultValue: LayersObservable = LayersObservable()
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public extension EnvironmentValues {
    /// Access the `LayersObservable` instance from the SwiftUI environment.
    ///
    /// Inject via `.environment(\.layers, myLayersObservable)` and read with `@Environment(\.layers)`.
    var layers: LayersObservable {
        get { self[LayersEnvironmentKey.self] }
        set { self[LayersEnvironmentKey.self] = newValue }
    }
}
#endif
