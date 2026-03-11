import Foundation
import Network
import os.log
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SafeResult

/// Result type that guarantees the SDK never throws or crashes the host app.
public enum SafeResult<T: Sendable>: Sendable {
    case success(T)
    case failure(LayersError)
}

// MARK: - ResultBox

/// Thread-safe box for passing a value between a `Task` closure and a blocking caller.
/// Replaces `UnsafeMutablePointer` usage with a Sendable-safe reference type.
// Thread safety is guaranteed by the DispatchSemaphore in flushBlocking() — the Task writes
// before signal(), and the caller reads after wait().
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - LayersError

/// All possible SDK errors. Mapped from Rust UniFfiError at the FFI boundary.
public enum LayersError: Error, LocalizedError, Sendable, Equatable {
    case notInitialized
    case invalidConfig(String)
    case networkError(String)
    case persistenceError(String)
    case queueFull
    case circuitBreakerOpen
    case rateLimited
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Layers SDK has not been initialized. Call Layers.initialize(config:) first."
        case .invalidConfig(let reason):
            return "Invalid configuration: \(reason)"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .persistenceError(let reason):
            return "Persistence error: \(reason)"
        case .queueFull:
            return "Event queue is full. Events are being dropped."
        case .circuitBreakerOpen:
            return "Circuit breaker is open. The SDK is temporarily not sending events."
        case .rateLimited:
            return "Rate limited by the server. Events will be retried later."
        case .unknown(let reason):
            return "Unknown Layers SDK error: \(reason)"
        }
    }
}

// MARK: - CoreError (alias for backward compatibility in tests)

/// Backward-compatible error type used internally.
typealias CoreError = LayersError

// MARK: - Environment

// LayersEnvironment is defined in Generated/LayersCore.swift (UniFFI-generated).
// Named LayersEnvironment (not Environment) to avoid collision with SwiftUI's @Environment.

// MARK: - LayersConfig

public struct LayersConfig: Sendable {
    public let appId: String
    public let environment: LayersEnvironment
    public let enableDebug: Bool
    public let flushQueueSize: UInt32
    public let flushIntervalSecs: UInt32
    public let maxQueueSize: UInt32
    /// Custom base URL for the ingest API. Defaults to the Layers production endpoint.
    public let baseUrl: String?
    /// Whether to automatically fire an `app_open` event during initialization.
    /// Set to `false` if you want to fire the event manually. Defaults to `true`.
    public let autoTrackAppOpen: Bool

    public init(
        appId: String,
        environment: LayersEnvironment = .production,
        enableDebug: Bool = false,
        flushQueueSize: UInt32 = 20,
        flushIntervalSecs: UInt32 = 30,
        maxQueueSize: UInt32 = 10000,
        baseUrl: String? = nil,
        autoTrackAppOpen: Bool = true
    ) {
        self.appId = appId
        self.environment = environment
        self.enableDebug = enableDebug
        self.flushQueueSize = flushQueueSize
        self.flushIntervalSecs = flushIntervalSecs
        self.maxQueueSize = maxQueueSize
        self.baseUrl = baseUrl
        self.autoTrackAppOpen = autoTrackAppOpen
    }
}

// MARK: - ConsentSettings

public struct ConsentSettings: Sendable, Equatable {
    public var analytics: Bool?
    public var advertising: Bool?

    public init(analytics: Bool? = nil, advertising: Bool? = nil) {
        self.analytics = analytics
        self.advertising = advertising
    }

    public static let denied = ConsentSettings(analytics: false, advertising: false)
    public static let full = ConsentSettings(analytics: true, advertising: true)
}

// MARK: - Layers SDK

/// Main entry point for the Layers SDK.
/// All public methods return `SafeResult` and are guaranteed to never throw or crash.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class Layers: @unchecked Sendable, LayersProtocol {

    // MARK: - Singleton

    public static let shared = Layers()

    // MARK: - Error Listener

    /// Optional callback invoked whenever an SDK method encounters an error.
    /// The first parameter is the method name (e.g. "track", "flush"); the second is a
    /// human-readable error description.
    ///
    /// Set this early (before `initialize`) to capture all errors. Pass `nil` to clear.
    /// The callback is invoked on an arbitrary queue — dispatch to main if you update UI.
    public static var onError: ((String, String) -> Void)?

    // MARK: - Properties

    private let lock = NSLock()
    private var _core: LayersCoreHandle?
    private var _isInitialized = false
    private var _isInitializing = false
    private var _appUserId: String?
    private var _anonymousId: String?
    private var _enableDebug = false
    #if os(iOS) || os(tvOS)
    private var _backgroundObserver: NSObjectProtocol?
    #endif

    /// NWPathMonitor for flush-on-reconnect.
    private var _networkMonitor: NWPathMonitor?
    private let _monitorQueue = DispatchQueue(label: "io.layers.sdk.network-monitor")
    /// Serial queue for HTTP event delivery (drain → send → retry/requeue).
    private let _flushQueue = DispatchQueue(label: "io.layers.sdk.flush")
    /// Tracks previous offline state for flush-on-reconnect. Only accessed on `_monitorQueue`.
    private var _wasOffline = false

    /// Timer for periodic remote config polling (every 300s).
    private var _configTimer: DispatchSourceTimer?
    /// Timer for periodic auto-flush at the configured interval.
    private var _flushTimer: DispatchSourceTimer?
    /// Config poll interval in seconds.
    private static let configPollIntervalSecs: UInt32 = 300

    /// SKAdNetwork integration (iOS only).
    public let skan = SKANModule()
    /// App Tracking Transparency (iOS only).
    public let att = ATTModule()
    /// Deep linking module.
    public let deepLinks = DeepLinksModule()
    /// Commerce / StoreKit integration.
    public let commerce = CommerceModule()
    /// AdServices attribution (iOS 14.3+, no ATT required).
    public let adServices = AdServicesModule()
    /// Clipboard attribution for deferred deep links (iOS only).
    public let clipboard = ClipboardModule()

    public var isInitialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isInitialized
    }

    private var core: LayersCoreHandle? {
        lock.lock()
        defer { lock.unlock() }
        return _core
    }

    private init() {}

    // MARK: - Initialization

    @discardableResult
    public func initialize(config: LayersConfig) -> SafeResult<Void> {
        lock.lock()
        guard !_isInitialized else {
            lock.unlock()
            return .success(())
        }
        guard !_isInitializing else {
            lock.unlock()
            return .success(())
        }
        _isInitializing = true
        lock.unlock()

        if config.appId.isEmpty {
            lock.lock()
            _isInitializing = false
            lock.unlock()
            let err = LayersError.invalidConfig("appId must not be empty")
            reportError(method: "initialize", error: err)
            return .failure(err)
        }

        let persistencePath = Self.persistenceDirectory()
        let uniffiConfig = UniFfiConfig(
            appId: config.appId,
            environment: config.environment,
            baseUrl: config.baseUrl,
            flushIntervalMs: UInt64(config.flushIntervalSecs) * 1000,
            flushThreshold: config.flushQueueSize,
            maxQueueSize: config.maxQueueSize,
            maxBatchSize: nil,
            enableDebug: config.enableDebug,
            sdkVersion: nil,
            persistenceDir: persistencePath
        )

        let handle: LayersCoreHandle
        do {
            handle = try LayersCoreHandle.`init`(config: uniffiConfig)

            let deviceContext = UniFfiDeviceContext(
                platform: .ios,
                osVersion: Self.osVersion(),
                appVersion: Self.appVersion(),
                deviceModel: Self.deviceModel(),
                locale: Locale.current.identifier,
                buildNumber: Self.buildNumber(),
                screenSize: Self.screenSize(),
                installId: Self.getOrCreateInstallId(),
                idfa: att.getAdvertisingId(),
                idfv: att.getVendorId(),
                attStatus: att.getStatus().rawValue,
                timezone: TimeZone.current.identifier
            )
            try handle.setDeviceContext(context: deviceContext)
        } catch {
            lock.lock()
            _isInitializing = false
            lock.unlock()
            let mapped = Self.mapError(error)
            reportError(method: "initialize", error: mapped)
            return .failure(mapped)
        }

        skan.attach(core: handle)
        att.attach(core: handle)
        deepLinks.attach(core: handle)
        commerce.attach(core: handle, skan: skan)

        // If ATT is already authorized, sync IDFA/IDFV to core immediately
        if att.getStatus() == .authorized {
            att.syncToCore()
        }

        lock.lock()
        _core = handle
        _anonymousId = _anonymousId ?? UUID().uuidString
        _isInitialized = true
        _isInitializing = false
        _enableDebug = config.enableDebug
        lock.unlock()

        #if os(iOS) || os(tvOS)
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.flush() }
        }
        lock.lock()
        _backgroundObserver = observer
        lock.unlock()
        #endif

        // Fetch remote config synchronously (up to 2s) so we can check clipboard_attribution_enabled
        fetchRemoteConfigSync(timeoutSecs: 2.0)

        // Read remote config and apply server-driven settings
        let clipboardEnabled: Bool
        let remoteConfigDict: [String: Any]?
        if let configJson = try? handle.getRemoteConfigJson(),
           let data = configJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            remoteConfigDict = parsed
            clipboardEnabled = parsed["clipboard_attribution_enabled"] as? Bool ?? false
        } else {
            remoteConfigDict = nil
            clipboardEnabled = false
        }

        // Auto-configure SKAN from remote config (iOS only).
        // The server's remote config `skan` section drives preset/rules so consumers
        // don't need to call skan.setPreset() manually.
        #if os(iOS)
        configureSkanFromRemoteConfig(remoteConfigDict)
        #endif

        // Collect attribution signals and fire app_open with them (if enabled)
        trackAttributionSignals(core: handle, clipboardAttributionEnabled: clipboardEnabled, autoTrackAppOpen: config.autoTrackAppOpen)

        // Start periodic remote config polling
        startConfigPolling()

        // Start periodic auto-flush timer
        startPeriodicFlush(intervalSecs: config.flushIntervalSecs)

        // Start network reachability monitor for flush-on-reconnect
        startNetworkMonitor()

        return .success(())
    }

    // MARK: - Event Tracking

    @discardableResult
    public func track(_ event: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "track", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("track('%{public}@', properties: %d keys)", log: Self.log, type: .debug, event, properties.count)
        }
        do {
            try core.track(
                eventName: event,
                propertiesJson: Self.jsonString(from: properties),
                userId: nil,
                anonymousId: nil
            )
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "track", error: mapped)
            return .failure(mapped)
        }
    }

    /// Track a typed event conforming to `LayersEvent`.
    @discardableResult
    public func track(_ event: some LayersEvent) -> SafeResult<Void> {
        return track(event.eventName, properties: event.properties)
    }

    @discardableResult
    public func screen(_ name: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "screen", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("screen('%{public}@', properties: %d keys)", log: Self.log, type: .debug, name, properties.count)
        }
        do {
            try core.screen(
                screenName: name,
                propertiesJson: Self.jsonString(from: properties),
                userId: nil,
                anonymousId: nil
            )
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "screen", error: mapped)
            return .failure(mapped)
        }
    }

    // MARK: - User Identity

    // Note: identify and setUserProperties are separate calls to the Rust core.
    // If setUserProperties fails, the user is already identified. Callers who need
    // atomicity should call identify() and setUserProperties() separately.
    @discardableResult
    public func identify(userId: String, traits: [String: Any] = [:]) -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "identify", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("identify(userId: '%{public}@', traits: %d keys)", log: Self.log, type: .debug, userId, traits.count)
        }
        do {
            try core.identify(userId: userId)
            lock.lock()
            _appUserId = userId.isEmpty ? nil : userId
            lock.unlock()
            if !traits.isEmpty {
                try core.setUserProperties(propertiesJson: Self.jsonString(from: traits) ?? "{}")
            }
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "identify", error: mapped)
            return .failure(mapped)
        }
    }

    @discardableResult
    public func setAppUserId(_ userId: String) -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "setAppUserId", error: err)
            return .failure(err)
        }
        do {
            try core.identify(userId: userId)
            lock.lock()
            _appUserId = userId.isEmpty ? nil : userId
            lock.unlock()
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "setAppUserId", error: mapped)
            return .failure(mapped)
        }
    }

    @discardableResult
    public func clearAppUserId() -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "clearAppUserId", error: err)
            return .failure(err)
        }
        do {
            try core.identify(userId: "")
            lock.lock()
            _appUserId = nil
            lock.unlock()
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "clearAppUserId", error: mapped)
            return .failure(mapped)
        }
    }

    @discardableResult
    public func setUserProperties(_ properties: [String: Any]) -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "setUserProperties", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("setUserProperties(%d keys)", log: Self.log, type: .debug, properties.count)
        }
        do {
            try core.setUserProperties(propertiesJson: Self.jsonString(from: properties) ?? "{}")
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "setUserProperties", error: mapped)
            return .failure(mapped)
        }
    }

    /// Set user properties with "set once" semantics — only properties whose keys
    /// have **not** been previously set via this method are forwarded.
    ///
    /// Typical use: `first_seen_date`, `initial_utm_source`, etc.
    ///
    /// The set of already-set keys is persisted by the Rust core so that "once"
    /// semantics survive app restarts.
    @discardableResult
    public func setUserPropertiesOnce(_ properties: [String: Any]) -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "setUserPropertiesOnce", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("setUserPropertiesOnce(%d keys)", log: Self.log, type: .debug, properties.count)
        }
        do {
            try core.setUserPropertiesOnce(propertiesJson: Self.jsonString(from: properties) ?? "{}")
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "setUserPropertiesOnce", error: mapped)
            return .failure(mapped)
        }
    }

    public var appUserId: String? {
        lock.lock()
        defer { lock.unlock() }
        return _appUserId
    }

    public var anonymousId: String {
        lock.lock()
        defer { lock.unlock() }
        return _anonymousId ?? ""
    }

    public var sessionId: String? {
        lock.lock()
        let c = _core
        lock.unlock()
        guard let c else { return nil }
        do {
            return try c.getSessionId()
        } catch {
            os_log("getSessionId failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            return nil
        }
    }

    public var queueDepth: Int? {
        guard let core = lockedCoreIfInitialized() else { return nil }
        return Int(core.queueDepth())
    }

    // MARK: - Consent

    @discardableResult
    public func setConsent(_ consent: ConsentSettings) -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "setConsent", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("setConsent(analytics: %{public}@, advertising: %{public}@)", log: Self.log, type: .debug, String(describing: consent.analytics), String(describing: consent.advertising))
        }
        do {
            try core.setConsent(consent: UniFfiConsent(
                analytics: consent.analytics,
                advertising: consent.advertising
            ))
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "setConsent", error: mapped)
            return .failure(mapped)
        }
    }

    // MARK: - Flush & Reset

    /// Maximum number of retry attempts for a single batch delivery.
    private static let maxRetries = 3
    /// Default batch size for drain operations.
    private static let defaultBatchSize: UInt32 = 1000

    /// Flush queued events to the server (async version — preferred).
    /// Drains events from the Rust core queue, sends them over HTTP via URLSession,
    /// retries on transient failures, and requeues events if all retries are exhausted.
    public func flush() async -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "flush", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("flush()", log: Self.log, type: .debug)
        }
        return await withCheckedContinuation { continuation in
            _flushQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .success(()))
                    return
                }
                let result = self.deliverBatch(core: core)
                continuation.resume(returning: result)
            }
        }
    }

    /// Flush queued events to the server (synchronous version).
    /// Blocks the calling thread until events are sent.
    ///
    /// - Warning: Do not call from the main thread in production. Prefer `flush()` instead.
    @discardableResult
    public func flushBlocking() -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "flushBlocking", error: err)
            return .failure(err)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<SafeResult<Void>>(.success(()))
        _flushQueue.async { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            box.value = self.deliverBatch(core: core)
            semaphore.signal()
        }
        // Cap at 45s (3 retries × 10s timeout + backoff)
        let result = semaphore.wait(timeout: .now() + 45)
        if result == .timedOut {
            os_log("flushBlocking timed out after 45s", log: Self.log, type: .error)
            return .failure(LayersError.networkError("flushBlocking timed out"))
        }
        return box.value
    }

    /// Core drain-and-deliver loop. Must be called on `_flushQueue` (serial).
    /// The serial queue guarantees mutual exclusion — no additional lock needed.
    /// Drains a batch from the Rust queue, sends via URLSession with retry,
    /// and requeues events on exhausted retries.
    private func deliverBatch(core: LayersCoreHandle) -> SafeResult<Void> {
        // Drain a batch from the Rust queue
        let batchJson: String
        do {
            guard let json = try core.drainBatch(count: Self.defaultBatchSize) else {
                return .success(()) // Queue empty
            }
            batchJson = json
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "flush", error: mapped)
            return .failure(mapped)
        }

        // Get URL and headers from the Rust core
        let urlString: String
        let headersJson: String
        do {
            urlString = try core.eventsUrl()
            headersJson = try core.flushHeadersJson()
        } catch {
            // Cannot deliver without URL/headers — requeue events
            requeueSilently(core: core, batchJson: batchJson)
            let mapped = Self.mapError(error)
            reportError(method: "flush", error: mapped)
            return .failure(mapped)
        }

        guard let url = URL(string: urlString) else {
            requeueSilently(core: core, batchJson: batchJson)
            let err = LayersError.networkError("Invalid events URL: \(urlString)")
            reportError(method: "flush", error: err)
            return .failure(err)
        }

        // Build URLRequest with headers from Rust core
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpBody = batchJson.data(using: .utf8)
        guard Self.applyHeaders(from: headersJson, to: &request) else {
            requeueSilently(core: core, batchJson: batchJson)
            let err = LayersError.networkError("Failed to parse flush headers")
            reportError(method: "flush", error: err)
            return .failure(err)
        }

        // Retry loop with exponential backoff + jitter
        for attempt in 0..<Self.maxRetries {
            let semaphore = DispatchSemaphore(value: 0)
            var responseStatus: Int?
            var networkError: Error?

            let task = URLSession.shared.dataTask(with: request) { _, response, error in
                networkError = error
                responseStatus = (response as? HTTPURLResponse)?.statusCode
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()

            if let error = networkError {
                os_log("Flush attempt %d failed (network): %{public}@", log: Self.log, type: .error, attempt + 1, error.localizedDescription)
                if attempt < Self.maxRetries - 1 {
                    Thread.sleep(forTimeInterval: Self.retryDelay(attempt: attempt))
                    continue
                }
            } else if let status = responseStatus {
                if status >= 200 && status < 300 {
                    if enableDebug {
                        os_log("Flush succeeded (HTTP %d)", log: Self.log, type: .debug, status)
                    }
                    return .success(())
                }

                if status == 429 || status >= 500 {
                    // Retryable
                    os_log("Flush attempt %d: HTTP %d (retryable)", log: Self.log, type: .error, attempt + 1, status)
                    if attempt < Self.maxRetries - 1 {
                        Thread.sleep(forTimeInterval: Self.retryDelay(attempt: attempt))
                        continue
                    }
                } else {
                    // Non-retryable (4xx other than 429) — drop events
                    os_log("Flush failed: HTTP %d (non-retryable, events dropped)", log: Self.log, type: .error, status)
                    let err = LayersError.networkError("HTTP \(status)")
                    reportError(method: "flush", error: err)
                    return .failure(err)
                }
            }
        }

        // All retries exhausted — requeue events
        os_log("Flush: all retries exhausted, requeuing events", log: Self.log, type: .error)
        requeueSilently(core: core, batchJson: batchJson)
        let err = LayersError.networkError("All retries exhausted")
        reportError(method: "flush", error: err)
        return .failure(err)
    }

    /// Requeue a drained batch back into the Rust core queue. Errors are swallowed.
    private func requeueSilently(core: LayersCoreHandle, batchJson: String) {
        do {
            _ = try core.requeueEvents(eventsJson: batchJson)
        } catch {
            os_log("Requeue failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
        }
    }

    /// Calculate retry delay: base 1s, multiply by 2^attempt, add jitter 0-250ms, cap at 30s.
    private static func retryDelay(attempt: Int) -> TimeInterval {
        let base = 1.0 * pow(2.0, Double(attempt))
        let delay = base
        let jitter = delay * 0.25 * Double.random(in: 0...1.0)
        return min(delay + jitter, 30.0)
    }

    /// Reset the SDK state, clearing user identity and properties.
    ///
    /// Note: This performs two separate calls to the core (clear identity, clear user properties).
    /// If the first succeeds but the second fails, the SDK may be in a partially-reset state.
    /// The returned result reflects the first failure encountered.
    @discardableResult
    public func reset() -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "reset", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("reset()", log: Self.log, type: .debug)
        }
        do {
            try core.identify(userId: "")
            try core.setUserProperties(propertiesJson: "{}")
            lock.lock()
            _appUserId = nil
            lock.unlock()
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "reset", error: mapped)
            return .failure(mapped)
        }
    }

    @discardableResult
    public func shutdown() -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "shutdown", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("shutdown()", log: Self.log, type: .debug)
        }
        do {
            try core.shutdown()

            // Cancel periodic timers
            lock.lock()
            _configTimer?.cancel()
            _configTimer = nil
            _flushTimer?.cancel()
            _flushTimer = nil
            lock.unlock()

            // Stop network monitor
            stopNetworkMonitor()

            #if os(iOS) || os(tvOS)
            lock.lock()
            if let observer = _backgroundObserver {
                NotificationCenter.default.removeObserver(observer)
                _backgroundObserver = nil
            }
            lock.unlock()
            #endif
            lock.lock()
            _core = nil
            _isInitialized = false
            _appUserId = nil
            lock.unlock()
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "shutdown", error: mapped)
            return .failure(mapped)
        }
    }

    // MARK: - Debug

    /// Returns a formatted string describing the current SDK state. Useful for debugging.
    public func debugStatus() -> String {
        lock.lock()
        let initialized = _isInitialized
        let userId = _appUserId
        let anonId = _anonymousId
        let debug = _enableDebug
        let hasCore = _core != nil
        lock.unlock()

        let sid = sessionId ?? "nil"

        var lines: [String] = []
        lines.append("Layers SDK Status")
        lines.append("  initialized: \(initialized)")
        lines.append("  hasCore: \(hasCore)")
        lines.append("  enableDebug: \(debug)")
        lines.append("  appUserId: \(userId ?? "nil")")
        lines.append("  anonymousId: \(anonId ?? "nil")")
        lines.append("  sessionId: \(sid)")
        lines.append("  queueDepth: \(queueDepth.map(String.init) ?? "nil")")
        lines.append("  skan.supported: \(skan.isSupported())")
        lines.append("  skan.version: \(skan.getVersion())")
        lines.append("  att.status: \(att.getStatus().rawValue)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Remote Config Polling

    /// Parse a JSON array of `[key, value]` header pairs and apply them to a URLRequest.
    /// Returns `true` if headers were parsed and applied, `false` on parse failure.
    @discardableResult
    private static func applyHeaders(from json: String, to request: inout URLRequest) -> Bool {
        guard let data = json.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[String]] else {
            os_log("Failed to parse header JSON", log: log, type: .error)
            return false
        }
        for pair in pairs {
            guard pair.count == 2 else { continue }
            request.setValue(pair[1], forHTTPHeaderField: pair[0])
        }
        return true
    }

    /// Fetch remote config from the server synchronously, blocking up to `timeoutSecs`.
    /// Used during initialization so the SDK can read server-driven flags (e.g.
    /// `clipboard_attribution_enabled`) before firing the first `app_open` event.
    private func fetchRemoteConfigSync(timeoutSecs: TimeInterval = 2.0) {
        guard let core = lockedCoreIfInitialized() else { return }

        let url: String
        let configHeaders: String
        do {
            url = try core.configUrl()
            configHeaders = try core.configHeadersJson()
        } catch {
            os_log("Failed to get config URL/headers: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            return
        }

        guard let requestUrl = URL(string: url) else {
            os_log("Invalid config URL: %{public}@", log: Self.log, type: .error, url)
            return
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "GET"
        if !Self.applyHeaders(from: configHeaders, to: &request) {
            os_log("Failed to parse config headers", log: Self.log, type: .error)
            return
        }
        request.timeoutInterval = timeoutSecs

        let group = DispatchGroup()
        group.enter()

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer { group.leave() }
            guard self != nil else { return }

            if let error = error {
                os_log("Config fetch (sync) failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else { return }

            switch httpResponse.statusCode {
            case 200:
                guard let data = data, let body = String(data: data, encoding: .utf8) else {
                    os_log("Config fetch (sync): empty body on 200", log: Self.log, type: .error)
                    return
                }
                let responseEtag = httpResponse.value(forHTTPHeaderField: "ETag")
                do {
                    try core.updateRemoteConfig(configJson: body, etag: responseEtag)
                    if self?.enableDebug == true {
                        os_log("Remote config updated (sync, ETag: %{public}@)", log: Self.log, type: .debug, responseEtag ?? "nil")
                    }
                } catch {
                    os_log("updateRemoteConfig (sync) failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                }
            case 304:
                do {
                    try core.markConfigNotModified()
                    if self?.enableDebug == true {
                        os_log("Remote config not modified (sync, 304)", log: Self.log, type: .debug)
                    }
                } catch {
                    os_log("markConfigNotModified (sync) failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                }
            default:
                os_log("Config fetch (sync) returned HTTP %d", log: Self.log, type: .error, httpResponse.statusCode)
            }
        }
        task.resume()

        // Block until the fetch completes or the timeout elapses.
        _ = group.wait(timeout: .now() + timeoutSecs)
    }

    /// Fetch remote config from the server (best-effort).
    /// On 200, updates the Rust core with the new config and ETag.
    /// On 304, marks the config as not modified (refreshes TTL).
    private func fetchRemoteConfig() {
        guard let core = lockedCoreIfInitialized() else { return }

        let url: String
        let configHeaders: String
        do {
            url = try core.configUrl()
            configHeaders = try core.configHeadersJson()
        } catch {
            os_log("Failed to get config URL/headers: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            return
        }

        guard let requestUrl = URL(string: url) else {
            os_log("Invalid config URL: %{public}@", log: Self.log, type: .error, url)
            return
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "GET"
        if !Self.applyHeaders(from: configHeaders, to: &request) {
            os_log("Failed to parse config headers", log: Self.log, type: .error)
            return
        }
        request.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard self != nil else { return }
            if let error = error {
                os_log("Config fetch failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else { return }

            switch httpResponse.statusCode {
            case 200:
                guard let data = data, let body = String(data: data, encoding: .utf8) else {
                    os_log("Config fetch: empty body on 200", log: Self.log, type: .error)
                    return
                }
                let responseEtag = httpResponse.value(forHTTPHeaderField: "ETag")
                do {
                    try core.updateRemoteConfig(configJson: body, etag: responseEtag)
                    if self?.enableDebug == true {
                        os_log("Remote config updated (ETag: %{public}@)", log: Self.log, type: .debug, responseEtag ?? "nil")
                    }
                } catch {
                    os_log("updateRemoteConfig failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                }
            case 304:
                do {
                    try core.markConfigNotModified()
                    if self?.enableDebug == true {
                        os_log("Remote config not modified (304)", log: Self.log, type: .debug)
                    }
                } catch {
                    os_log("markConfigNotModified failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                }
            default:
                os_log("Config fetch returned HTTP %d", log: Self.log, type: .error, httpResponse.statusCode)
            }
        }
        task.resume()
    }

    /// Start the repeating config poll timer (every 300s).
    private func startConfigPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + .seconds(Int(Self.configPollIntervalSecs)),
            repeating: .seconds(Int(Self.configPollIntervalSecs))
        )
        timer.setEventHandler { [weak self] in
            self?.fetchRemoteConfig()
        }
        lock.lock()
        _configTimer = timer
        lock.unlock()
        timer.resume()
    }

    // MARK: - Periodic Auto-Flush

    /// Start the repeating flush timer at the configured interval.
    private func startPeriodicFlush(intervalSecs: UInt32) {
        guard intervalSecs > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + .seconds(Int(intervalSecs)),
            repeating: .seconds(Int(intervalSecs))
        )
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard let core = self.lockedCoreIfInitialized() else { return }
            guard core.queueDepth() > 0 else { return }
            self._flushQueue.async {
                _ = self.deliverBatch(core: core)
            }
        }
        lock.lock()
        _flushTimer = timer
        lock.unlock()
        timer.resume()
    }

    // MARK: - Network Reachability (Flush on Reconnect)

    /// Start monitoring network path changes. When the device transitions from
    /// offline to online, trigger a flush to deliver any queued events.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        // Reset to prevent spurious flush-on-reconnect after re-initialization
        _wasOffline = false

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isOnline = path.status == .satisfied
            if self._wasOffline && isOnline {
                if self.enableDebug {
                    os_log("Network reconnected — triggering flush", log: Self.log, type: .debug)
                }
                Task { await self.flush() }
            }
            self._wasOffline = !isOnline
        }

        lock.lock()
        _networkMonitor = monitor
        lock.unlock()
        monitor.start(queue: _monitorQueue)
    }

    /// Stop the network path monitor and release it.
    private func stopNetworkMonitor() {
        lock.lock()
        let monitor = _networkMonitor
        _networkMonitor = nil
        lock.unlock()
        monitor?.cancel()
    }

    /// Whether the network monitor is currently running. Exposed for testing.
    var isNetworkMonitorRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _networkMonitor != nil
    }

    // MARK: - Internal Helpers

    /// Whether debug logging is enabled. Thread-safe.
    private var enableDebug: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _enableDebug
    }

    /// Thread-safe accessor: returns the core handle if initialized, nil otherwise.
    private func lockedCoreIfInitialized() -> LayersCoreHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard _isInitialized else { return nil }
        return _core
    }

    /// Report an error through the `onError` callback and debug logger.
    private func reportError(method: String, error: LayersError) {
        let description = error.errorDescription ?? String(describing: error)
        if enableDebug {
            os_log("%{public}@ failed: %{public}@", log: Self.log, type: .error, method, description)
        }
        Self.onError?(method, description)
    }

    static func mapError(_ error: Error) -> LayersError {
        guard let uniffiError = error as? UniFfiError else {
            return .unknown(error.localizedDescription)
        }
        switch uniffiError {
        case .NotInitialized, .ShutDown:
            return .notInitialized
        case .AlreadyInitialized:
            return .unknown("Already initialized")
        case .InvalidConfig(let reason):
            return .invalidConfig(reason)
        case .InvalidArgument(let reason):
            return .invalidConfig(reason)
        case .QueueFull:
            return .queueFull
        case .Serialization(let reason):
            return .unknown(reason)
        case .Network(let reason):
            return .networkError(reason)
        case .Http(_, let message):
            return .networkError(message)
        case .CircuitOpen:
            return .circuitBreakerOpen
        case .RateLimited:
            return .rateLimited
        case .ConsentNotGranted(let reason):
            return .unknown(reason)
        case .Persistence(let reason):
            return .persistenceError(reason)
        case .RemoteConfig(let reason):
            return .unknown(reason)
        case .EventDenied(let reason):
            return .unknown(reason)
        case .Internal(let reason):
            return .unknown(reason)
        }
    }

    private static let log = OSLog(subsystem: "io.layers.sdk", category: "Layers")

    private static let installIdKey = "com.layers.installId"

    /// Returns a persistent install ID, generating one on first launch.
    static func getOrCreateInstallId() -> String {
        if let existing = UserDefaults.standard.string(forKey: installIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: installIdKey)
        return newId
    }

    /// Auto-configure SKAN from the remote config `skan` section.
    /// If the config contains `{ "skan": { "preset": "iap" } }` or
    /// `{ "skan": { "customRules": [...] } }`, the SDK sets the preset or rules
    /// on the SKAN module so consumers don't have to do it manually.
    private func configureSkanFromRemoteConfig(_ remoteConfig: [String: Any]?) {
        guard let skanConfig = remoteConfig?["skan"] as? [String: Any] else { return }

        // Respect an explicit `enabled: false`
        if skanConfig["enabled"] as? Bool == false { return }

        if let preset = skanConfig["preset"] as? String {
            let mapped: SKANModule.Preset
            switch preset.lowercased() {
            case "subscriptions": mapped = .subscriptions
            case "ecommerce":    mapped = .ecommerce
            case "gaming":       mapped = .gaming
            case "iap":          mapped = .ecommerce
            default:             mapped = .custom
            }
            skan.setPreset(mapped)
            skan.registerForAttribution()
            if enableDebug {
                os_log("SKAN auto-configured from remote config: preset=%{public}@", log: Self.log, type: .debug, preset)
            }
        } else if let rulesJson = skanConfig["customRules"] {
            if let data = try? JSONSerialization.data(withJSONObject: rulesJson),
               let rulesStr = String(data: data, encoding: .utf8) {
                skan.setRules(rulesStr)
                skan.registerForAttribution()
                if enableDebug {
                    os_log("SKAN auto-configured from remote config: custom rules", log: Self.log, type: .debug)
                }
            }
        }
    }

    /// Collect AdServices token, clipboard URL, and timezone, then fire an `app_open` event
    /// with attribution signals as properties (unless `autoTrackAppOpen` is false).
    private func trackAttributionSignals(core: LayersCoreHandle, clipboardAttributionEnabled: Bool, autoTrackAppOpen: Bool) {
        guard autoTrackAppOpen else { return }

        var props: [String: Any] = [
            "timezone": TimeZone.current.identifier,
        ]

        if let token = adServices.requestAttributionToken() {
            props["adservices_token"] = token
        }

        if clipboardAttributionEnabled, let clipboardUrl = clipboard.checkClipboard() {
            props["clipboard_attribution_url"] = clipboardUrl
        }

        let json = Self.jsonString(from: props)
        do {
            try core.track(
                eventName: "app_open",
                propertiesJson: json,
                userId: nil,
                anonymousId: nil
            )
        } catch {
            os_log("app_open attribution track failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
        }
    }

    static func jsonString(from dict: [String: Any]) -> String? {
        if dict.isEmpty { return nil }
        guard JSONSerialization.isValidJSONObject(dict) else {
            os_log(
                "Properties dropped: could not serialize to JSON. Keys: %{public}@",
                log: Self.log,
                type: .error,
                dict.keys.sorted().joined(separator: ", ")
            )
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            os_log(
                "Properties dropped: could not serialize to JSON. Keys: %{public}@",
                log: Self.log,
                type: .error,
                dict.keys.sorted().joined(separator: ", ")
            )
            return nil
        }
        return str
    }

    private static func persistenceDirectory() -> String {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let baseUrl = urls.first else {
            os_log(
                "Application Support directory not found; falling back to temporary directory for persistence.",
                log: Self.log,
                type: .error
            )
            let fallback = NSTemporaryDirectory() + "io.layers.sdk"
            do {
                try FileManager.default.createDirectory(atPath: fallback, withIntermediateDirectories: true)
            } catch {
                os_log("Failed to create fallback persistence directory: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            }
            return fallback
        }
        let dir = baseUrl.appendingPathComponent("io.layers.sdk", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            os_log("Failed to create persistence directory: %{public}@", log: Self.log, type: .error, error.localizedDescription)
        }
        return dir.path
    }

    private static func deviceModel() -> String {
        #if os(iOS) || os(tvOS) || os(watchOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
        #elseif os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #else
        return "unknown"
        #endif
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private static func buildNumber() -> String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    private static func screenSize() -> String? {
        #if os(iOS) || os(tvOS)
        if #available(iOS 16.0, tvOS 16.0, *) {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else {
                return nil
            }
            let screen = windowScene.screen.bounds
            let scale = windowScene.screen.scale
            return "\(Int(screen.width * scale))x\(Int(screen.height * scale))"
        } else {
            let screen = UIScreen.main.bounds
            let scale = UIScreen.main.scale
            return "\(Int(screen.width * scale))x\(Int(screen.height * scale))"
        }
        #else
        return nil
        #endif
    }
}

// MARK: - Static Convenience Methods

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public extension Layers {
    /// Initialize the shared Layers SDK instance. Delegates to ``Layers/initialize(config:)``.
    @discardableResult
    static func initialize(config: LayersConfig) -> SafeResult<Void> {
        shared.initialize(config: config)
    }

    /// Track a custom event with optional properties. Delegates to ``Layers/track(_:properties:)``.
    @discardableResult
    static func track(_ event: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        shared.track(event, properties: properties)
    }

    /// Track a typed event. Delegates to ``Layers/track(_:)-7k2x3``.
    @discardableResult
    static func track(_ event: some LayersEvent) -> SafeResult<Void> {
        shared.track(event)
    }

    /// Record a screen view with optional properties. Delegates to ``Layers/screen(_:properties:)``.
    @discardableResult
    static func screen(_ name: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        shared.screen(name, properties: properties)
    }

    /// Identify a user and optionally set traits. Delegates to ``Layers/identify(userId:traits:)``.
    @discardableResult
    static func identify(userId: String, traits: [String: Any] = [:]) -> SafeResult<Void> {
        shared.identify(userId: userId, traits: traits)
    }

    /// Set the app-scoped user ID for attribution. Delegates to ``Layers/setAppUserId(_:)``.
    @discardableResult
    static func setAppUserId(_ userId: String) -> SafeResult<Void> {
        shared.setAppUserId(userId)
    }

    /// Clear the current app-scoped user ID. Delegates to ``Layers/clearAppUserId()``.
    @discardableResult
    static func clearAppUserId() -> SafeResult<Void> {
        shared.clearAppUserId()
    }

    /// Set custom user properties on the current user. Delegates to ``Layers/setUserProperties(_:)``.
    @discardableResult
    static func setUserProperties(_ properties: [String: Any]) -> SafeResult<Void> {
        shared.setUserProperties(properties)
    }

    /// Set user properties with "set once" semantics. Delegates to ``Layers/setUserPropertiesOnce(_:)``.
    @discardableResult
    static func setUserPropertiesOnce(_ properties: [String: Any]) -> SafeResult<Void> {
        shared.setUserPropertiesOnce(properties)
    }

    /// Update consent settings for analytics and advertising. Delegates to ``Layers/setConsent(_:)``.
    @discardableResult
    static func setConsent(_ consent: ConsentSettings) -> SafeResult<Void> {
        shared.setConsent(consent)
    }

    /// Flush queued events to the server asynchronously. Delegates to ``Layers/flush()``.
    static func flush() async -> SafeResult<Void> {
        await shared.flush()
    }

    /// Flush queued events synchronously, blocking the calling thread. Delegates to ``Layers/flushBlocking()``.
    /// - Warning: Do not call from async contexts or the main actor. See ``Layers/flushBlocking()``.
    @discardableResult
    static func flushBlocking() -> SafeResult<Void> {
        shared.flushBlocking()
    }

    /// Reset the SDK state, clearing user identity and properties. Delegates to ``Layers/reset()``.
    @discardableResult
    static func reset() -> SafeResult<Void> {
        shared.reset()
    }

    /// Shut down the SDK and release resources. Delegates to ``Layers/shutdown()``.
    @discardableResult
    static func shutdown() -> SafeResult<Void> {
        shared.shutdown()
    }

    /// Returns a formatted string describing the current SDK state. Delegates to ``Layers/debugStatus()``.
    static func debugStatus() -> String {
        shared.debugStatus()
    }
}
