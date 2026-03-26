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

    // MARK: - Install Event Gating

    /// Maximum age of an app install (in seconds) for which the SDK will emit
    /// `is_first_launch = true`.  If the app was installed longer ago than this
    /// AND the SDK has no prior persisted state, the first `app_open` event
    /// suppresses `is_first_launch` to avoid false positives when the SDK is
    /// added to an already-shipped app.
    static let installEventMaxDiffSecs: TimeInterval = 24 * 60 * 60  // 24 hours

    /// UserDefaults key that records whether the first launch has already been tracked.
    private static let firstLaunchTrackedKey = "com.layers.firstLaunchTracked"

    // MARK: - Init Listener

    /// Listener for SDK initialization timing metrics.
    ///
    /// Set via ``setInitListener(_:)`` **before** calling ``initialize(config:)``
    /// to receive the callback.
    ///
    /// ```swift
    /// Layers.shared.setInitListener { mainThreadMs, totalMs in
    ///     print("SDK init: main=\(mainThreadMs) ms, total=\(totalMs) ms")
    /// }
    /// ```
    private var _initListener: ((Double, Double) -> Void)?

    /// Set a listener to receive SDK initialization timing metrics.
    /// Must be called **before** ``initialize(config:)`` to receive the callback.
    /// Pass `nil` to clear the listener.
    ///
    /// - Parameter listener: A closure receiving `(mainThreadDurationMs, totalDurationMs)`.
    ///   `mainThreadDurationMs` is the time spent on the calling thread before background
    ///   work was launched (Rust core init, device context, lifecycle setup).
    ///   `totalDurationMs` is the total wall-clock time of the ``initialize(config:)`` call,
    ///   including background task scheduling.
    public func setInitListener(_ listener: ((Double, Double) -> Void)?) {
        lock.lock()
        _initListener = listener
        lock.unlock()
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var _core: LayersCoreHandle?
    private var _isInitialized = false
    private var _isInitializing = false
    private var _appUserId: String?
    private var _anonymousId: String?
    private var _enableDebug = false
    /// Stored config values for the debug overlay (not exposed by the Rust core).
    private var _configAppId: String?
    private var _configEnvironment: LayersEnvironment = .production

    #if canImport(UIKit) && !os(watchOS)
    /// The debug overlay instance (iOS/tvOS only).
    private var _debugOverlay: DebugOverlayView?
    #endif

    /// Recent event log for the debug overlay. Thread-safe via `lock`.
    private var _recentEvents: [(timestamp: Date, name: String, propertyCount: Int)] = []
    /// Maximum number of recent events to keep.
    private static let maxRecentEvents = 10
    /// Last flush result description for the debug overlay.
    private var _lastFlushResult: String?

    /// `true` if the SDK had prior state (i.e. `com.layers.installId` already
    /// existed in UserDefaults) at initialization time.  When `false`, the SDK
    /// was freshly added to this app and install event gating applies.
    /// Internal visibility so tests can set this via `@testable import`.
    var _hadPriorSdkState = false

    /// Stored base URL from config, for user properties HTTP POST.
    private var _configBaseUrl: String?

    /// Attribution data stored for attachment to subsequent events.
    private var _attributionDeeplinkId: String?
    /// The current deep link ID for internal use (e.g. DeepLinksModule preserving the value).
    internal var attributionDeeplinkId: String? { _attributionDeeplinkId }
    private var _attributionGclid: String?
    /// The current GCLID for internal use (e.g. DeepLinksModule preserving the value).
    internal var attributionGclid: String? { _attributionGclid }
    private var _attributionFbclid: String?
    /// The current FBCLID for internal use (e.g. DeepLinksModule preserving the value).
    internal var attributionFbclid: String? { _attributionFbclid }
    private var _attributionFbc: String?
    private var _attributionTtclid: String?
    /// The current TTCLID for internal use (e.g. DeepLinksModule preserving the value).
    internal var attributionTtclid: String? { _attributionTtclid }
    private var _attributionMsclkid: String?
    /// The current MSCLKID for internal use (e.g. DeepLinksModule preserving the value).
    internal var attributionMsclkid: String? { _attributionMsclkid }
    /// Last device context sent to the Rust core, cached so incremental updates
    /// (e.g. deeplink_id, IDFA) can preserve existing values.
    private var _lastDeviceContext: UniFfiDeviceContext?
    #if os(iOS) || os(tvOS)
    private var _backgroundObserver: NSObjectProtocol?
    #endif

    /// NWPathMonitor for flush-on-reconnect.
    private var _networkMonitor: NWPathMonitor?
    private let _monitorQueue = DispatchQueue(label: "com.layers.sdk.network-monitor")
    /// Serial queue for HTTP event delivery (drain → send → retry/requeue).
    private let _flushQueue = DispatchQueue(label: "com.layers.sdk.flush")
    /// Tracks previous offline state for flush-on-reconnect. Only accessed on `_monitorQueue`.
    private var _wasOffline = false
    /// Cached network status updated by the existing NWPathMonitor. Thread-safe via `lock`.
    private var _isNetworkOnline = true

    // MARK: - Retry-After State

    /// The `Date` until which flushes should be skipped (server-requested Retry-After).
    /// Only accessed on `_flushQueue` (serial) so no additional lock is needed.
    private var _retryAfterDeadline: Date?

    /// Maximum Retry-After delay the SDK will honour (5 minutes), matching the Rust core.
    static let retryAfterMaxSecs: TimeInterval = 300

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
    /// Optional Superwall paywall event tracking.
    public let superwall = SuperwallModule()
    /// Optional RevenueCat integration.
    public let revenueCat = RevenueCatModule()

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

        let initStartTime = CFAbsoluteTimeGetCurrent()

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
                installId: getOrCreateInstallIdAndRecordState(),
                idfa: att.getAdvertisingId(),
                idfv: att.getVendorId(),
                attStatus: att.getStatus().rawValue,
                deeplinkId: nil,
                gclid: nil,
                timezone: TimeZone.current.identifier
            )
            try handle.setDeviceContext(context: deviceContext)
            _lastDeviceContext = deviceContext
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
        superwall.attach(layers: self)
        revenueCat.attach(core: handle)

        // If ATT is already authorized, sync IDFA/IDFV to core immediately
        if att.getStatus() == .authorized {
            att.syncToCore()
        }

        // Restore persisted attribution data (deeplink_id, gclid) before
        // any events are tracked, so app_open and subsequent events include them.
        restoreAttributionData()

        // Main thread init complete — record timing
        let mainThreadDurationMs = (CFAbsoluteTimeGetCurrent() - initStartTime) * 1000.0

        lock.lock()
        _core = handle
        _anonymousId = _anonymousId ?? UUID().uuidString
        _isInitialized = true
        _isInitializing = false
        _enableDebug = config.enableDebug
        _configAppId = config.appId
        _configEnvironment = config.environment
        _configBaseUrl = config.baseUrl
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
        // Background flush via BGAppRefreshTask is available in
        // BackgroundFlushTask.swift. Consumers opt in by calling
        // BackgroundFlushTask.registerBackgroundFlush() at app launch.
        // Auto-schedule here so consumers who registered get periodic flushes.
        BackgroundFlushTask.scheduleBackgroundFlush()

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

        // Measure total duration (including background task scheduling)
        let totalDurationMs = (CFAbsoluteTimeGetCurrent() - initStartTime) * 1000.0

        if config.enableDebug {
            os_log(
                "Init timing: mainThread=%.2f ms, total=%.2f ms",
                log: Self.log,
                type: .debug,
                mainThreadDurationMs,
                totalDurationMs
            )
        }

        // Notify init listener on a background queue to avoid blocking the caller
        lock.lock()
        let listener = _initListener
        lock.unlock()
        if let listener = listener {
            DispatchQueue.global(qos: .utility).async {
                listener(mainThreadDurationMs, totalDurationMs)
            }
        }

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
        let merged = mergeAttributionProperties(properties)
        do {
            try core.track(
                eventName: event,
                propertiesJson: Self.jsonString(from: merged),
                userId: nil,
                anonymousId: nil
            )
            recordRecentEvent(name: event, propertyCount: merged.count)
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
        let merged = mergeAttributionProperties(properties)
        do {
            try core.screen(
                screenName: name,
                propertiesJson: Self.jsonString(from: merged),
                userId: nil,
                anonymousId: nil
            )
            recordRecentEvent(name: "screen: \(name)", propertyCount: merged.count)
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

    /// Associate all subsequent events with a group (company, team, organization).
    ///
    /// - Parameters:
    ///   - groupId: The group identifier. Pass an empty string to clear the group association.
    ///   - properties: Optional group properties to send with a `group` event.
    /// - Returns: `.success(())` on success, `.failure(LayersError)` on failure.
    @discardableResult
    public func group(groupId: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        guard let core = lockedCoreIfInitialized() else {
            let err = LayersError.notInitialized
            reportError(method: "group", error: err)
            return .failure(err)
        }
        if enableDebug {
            os_log("group(groupId: '%{public}@', properties: %d keys)", log: Self.log, type: .debug, groupId, properties.count)
        }
        do {
            let propsJson = properties.isEmpty ? nil : Self.jsonString(from: properties)
            try core.group(groupId: groupId, propertiesJson: propsJson)
            return .success(())
        } catch {
            let mapped = Self.mapError(error)
            reportError(method: "group", error: mapped)
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
            sendUserPropertiesAsync(properties, setOnce: false)
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
            sendUserPropertiesAsync(properties, setOnce: true)
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

    // MARK: - Attribution Data

    /// Store attribution data that will be attached to all subsequent events.
    ///
    /// The values are persisted in UserDefaults so they survive app restarts.
    /// Pass `nil` for a parameter to clear that value.
    ///
    /// When set, click IDs (`gclid`, `fbclid`, `ttclid`, `msclkid`) are included
    /// in every event's properties. For fbclid, a formatted `$fbc` parameter
    /// (`fb.1.{timestamp}.{fbclid}`) is also included.
    ///
    /// - Parameters:
    ///   - deeplinkId: Deep link identifier for server-side attribution matching.
    ///   - gclid: Google Click Identifier from ad click URLs.
    ///   - fbclid: Facebook Click Identifier from ad click URLs.
    ///   - ttclid: TikTok Click Identifier from ad click URLs.
    ///   - msclkid: Microsoft Click Identifier from ad click URLs.
    @discardableResult
    public func setAttributionData(
        deeplinkId: String? = nil,
        gclid: String? = nil,
        fbclid: String? = nil,
        ttclid: String? = nil,
        msclkid: String? = nil
    ) -> SafeResult<Void> {
        let fbc: String? = fbclid != nil ? Self.formatFbc(fbclid!) : nil

        lock.lock()
        _attributionDeeplinkId = deeplinkId
        _attributionGclid = gclid
        _attributionFbclid = fbclid
        _attributionFbc = fbc
        _attributionTtclid = ttclid
        _attributionMsclkid = msclkid
        lock.unlock()

        // Update the Rust core's DeviceContext with the new deeplink_id so the
        // top-level event field is populated (not just the properties bag).
        if let core = core, let lastCtx = _lastDeviceContext {
            let updatedCtx = UniFfiDeviceContext(
                platform: lastCtx.platform,
                osVersion: lastCtx.osVersion,
                appVersion: lastCtx.appVersion,
                deviceModel: lastCtx.deviceModel,
                locale: lastCtx.locale,
                buildNumber: lastCtx.buildNumber,
                screenSize: lastCtx.screenSize,
                installId: lastCtx.installId,
                idfa: lastCtx.idfa,
                idfv: lastCtx.idfv,
                attStatus: lastCtx.attStatus,
                deeplinkId: deeplinkId,
                gclid: gclid,
                timezone: lastCtx.timezone
            )
            do {
                try core.setDeviceContext(context: updatedCtx)
                _lastDeviceContext = updatedCtx
            } catch {
                // DeviceContext update is best-effort
            }
        }

        // Persist to UserDefaults
        Self.persistOptionalString(deeplinkId, forKey: Self.attributionDeeplinkIdKey)
        Self.persistOptionalString(gclid, forKey: Self.attributionGclidKey)
        Self.persistOptionalString(fbclid, forKey: Self.attributionFbclidKey)
        Self.persistOptionalString(fbc, forKey: Self.attributionFbcKey)
        Self.persistOptionalString(ttclid, forKey: Self.attributionTtclidKey)
        Self.persistOptionalString(msclkid, forKey: Self.attributionMsclkidKey)

        if enableDebug {
            os_log("setAttributionData(deeplinkId: %{public}@, gclid: %{public}@, fbclid: %{public}@, ttclid: %{public}@, msclkid: %{public}@)", log: Self.log, type: .debug, String(describing: deeplinkId), String(describing: gclid), String(describing: fbclid), String(describing: ttclid), String(describing: msclkid))
        }
        return .success(())
    }

    /// Persist an optional string to UserDefaults, removing the key if nil.
    private static func persistOptionalString(_ value: String?, forKey key: String) {
        if let value = value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Format a raw fbclid into the Meta Conversions API `$fbc` parameter format.
    /// Format: `fb.1.{timestamp_ms}.{fbclid}`
    static func formatFbc(_ fbclid: String) -> String {
        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
        return "fb.1.\(timestampMs).\(fbclid)"
    }

    /// Merge attribution properties (click IDs) into the given event properties.
    /// `deeplink_id` flows through DeviceContext on the Rust core; other fields
    /// flow through properties.
    private func mergeAttributionProperties(_ properties: [String: Any]) -> [String: Any] {
        lock.lock()
        let gclid = _attributionGclid
        let fbclid = _attributionFbclid
        let fbc = _attributionFbc
        let ttclid = _attributionTtclid
        let msclkid = _attributionMsclkid
        lock.unlock()

        let hasAttribution = gclid != nil || fbclid != nil || fbc != nil || ttclid != nil || msclkid != nil
        guard hasAttribution else { return properties }

        var merged = properties
        if let gclid = gclid, merged["gclid"] == nil { merged["gclid"] = gclid }
        if let fbclid = fbclid, merged["fbclid"] == nil { merged["fbclid"] = fbclid }
        if let fbc = fbc, merged["$fbc"] == nil { merged["$fbc"] = fbc }
        if let ttclid = ttclid, merged["ttclid"] == nil { merged["ttclid"] = ttclid }
        if let msclkid = msclkid, merged["msclkid"] == nil { merged["msclkid"] = msclkid }
        return merged
    }

    /// Restore persisted attribution data from UserDefaults.
    /// Called during initialization to survive app restarts.
    private func restoreAttributionData() {
        let deeplinkId = UserDefaults.standard.string(forKey: Self.attributionDeeplinkIdKey)
        let gclid = UserDefaults.standard.string(forKey: Self.attributionGclidKey)
        let fbclid = UserDefaults.standard.string(forKey: Self.attributionFbclidKey)
        let fbc = UserDefaults.standard.string(forKey: Self.attributionFbcKey)
        let ttclid = UserDefaults.standard.string(forKey: Self.attributionTtclidKey)
        let msclkid = UserDefaults.standard.string(forKey: Self.attributionMsclkidKey)

        lock.lock()
        _attributionDeeplinkId = deeplinkId
        _attributionGclid = gclid
        _attributionFbclid = fbclid
        _attributionFbc = fbc
        _attributionTtclid = ttclid
        _attributionMsclkid = msclkid
        lock.unlock()

        // Sync restored attribution data to the Rust core's DeviceContext so the
        // top-level event fields are populated from the first event onward.
        if (deeplinkId != nil || gclid != nil), let core = core, let lastCtx = _lastDeviceContext {
            let updatedCtx = UniFfiDeviceContext(
                platform: lastCtx.platform,
                osVersion: lastCtx.osVersion,
                appVersion: lastCtx.appVersion,
                deviceModel: lastCtx.deviceModel,
                locale: lastCtx.locale,
                buildNumber: lastCtx.buildNumber,
                screenSize: lastCtx.screenSize,
                installId: lastCtx.installId,
                idfa: lastCtx.idfa,
                idfv: lastCtx.idfv,
                attStatus: lastCtx.attStatus,
                deeplinkId: deeplinkId,
                gclid: gclid,
                timezone: lastCtx.timezone
            )
            do {
                try core.setDeviceContext(context: updatedCtx)
                _lastDeviceContext = updatedCtx
            } catch {
                // best-effort
            }
        }

        if enableDebug && (deeplinkId != nil || gclid != nil || fbclid != nil || ttclid != nil || msclkid != nil) {
            os_log("Restored attribution data: deeplinkId=%{public}@, gclid=%{public}@, fbclid=%{public}@, ttclid=%{public}@, msclkid=%{public}@", log: Self.log, type: .debug, String(describing: deeplinkId), String(describing: gclid), String(describing: fbclid), String(describing: ttclid), String(describing: msclkid))
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
    ///
    /// Retry-After handling:
    /// - Before draining, checks `_retryAfterDeadline` — skips flush if active.
    /// - On 429/503 responses, reads the `Retry-After` header and sets the deadline.
    /// - On 2xx responses, clears the deadline.
    private func deliverBatch(core: LayersCoreHandle) -> SafeResult<Void> {
        // Check Retry-After gate — skip flush if the server told us to wait
        if isRetryAfterActive() {
            let remainingMs = retryAfterRemainingMs()
            if enableDebug {
                os_log("Flush skipped — Retry-After gate active (remaining: %llu ms)", log: Self.log, type: .debug, remainingMs)
            }
            return .success(()) // Events stay in queue for later
        }

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
            var httpResponse: HTTPURLResponse?
            var networkError: Error?

            let task = URLSession.shared.dataTask(with: request) { _, response, error in
                networkError = error
                httpResponse = response as? HTTPURLResponse
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()

            if let error = networkError {
                os_log("Flush attempt %d failed (network): %{public}@", log: Self.log, type: .error, attempt + 1, error.localizedDescription)
                if attempt < Self.maxRetries - 1 {
                    // Use usleep instead of Thread.sleep to avoid blocking a GCD
                    // thread-pool thread. This runs on the dedicated serial _flushQueue,
                    // so blocking is acceptable but usleep is lighter-weight.
                    usleep(UInt32(Self.retryDelay(attempt: attempt) * 1_000_000))
                    continue
                }
            } else if let response = httpResponse {
                let status = response.statusCode

                if status >= 200 && status < 300 {
                    // Success — clear Retry-After gate
                    clearRetryAfter()
                    recordFlushResult(success: true, message: "HTTP \(status)")
                    if enableDebug {
                        os_log("Flush succeeded (HTTP %d)", log: Self.log, type: .debug, status)
                    }
                    return .success(())
                }

                if status == 429 || (status >= 500 && status < 600) {
                    // Retryable — check for Retry-After header
                    if status == 429 || status == 503 {
                        let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After")
                        updateRetryAfter(status: status, retryAfterHeader: retryAfterHeader)
                    }

                    os_log("Flush attempt %d: HTTP %d (retryable)", log: Self.log, type: .error, attempt + 1, status)
                    if attempt < Self.maxRetries - 1 {
                        // Use usleep instead of Thread.sleep to avoid blocking a GCD
                        // thread-pool thread. This runs on the dedicated serial _flushQueue,
                        // so blocking is acceptable but usleep is lighter-weight.
                        usleep(UInt32(Self.retryDelay(attempt: attempt) * 1_000_000))
                        continue
                    }
                } else {
                    // Non-retryable (4xx other than 429) — drop events
                    os_log("Flush failed: HTTP %d (non-retryable, events dropped)", log: Self.log, type: .error, status)
                    recordFlushResult(success: false, message: "HTTP \(status)")
                    let err = LayersError.networkError("HTTP \(status)")
                    reportError(method: "flush", error: err)
                    return .failure(err)
                }
            }
        }

        // All retries exhausted — requeue events
        os_log("Flush: all retries exhausted, requeuing events", log: Self.log, type: .error)
        requeueSilently(core: core, batchJson: batchJson)
        recordFlushResult(success: false, message: "retries exhausted")
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

    // MARK: - Retry-After Helpers

    /// Parse a `Retry-After` header value into seconds.
    /// Supports integer seconds (e.g. "60") and HTTP-date format
    /// (e.g. "Wed, 21 Oct 2015 07:28:00 GMT"). Returns `nil` if unparseable.
    /// Caps at `retryAfterMaxSecs` (300s / 5 minutes).
    static func parseRetryAfterHeader(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }

        // Try parsing as integer seconds first (most common).
        // RFC 7231 specifies delay-seconds as an integer; reject fractional values
        // (e.g. "1.5") for consistency with the Rust core implementation.
        if let seconds = Int(value), seconds > 0 {
            return min(Double(seconds), retryAfterMaxSecs)
        }

        // Try parsing as HTTP-date (RFC 7231)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        // Preferred format: "Sun, 06 Nov 1994 08:49:37 GMT"
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            let delay = date.timeIntervalSinceNow
            if delay > 0 {
                return min(delay, retryAfterMaxSecs)
            }
            return nil // Date is in the past
        }

        return nil
    }

    /// Update the Retry-After gate from an HTTP response.
    /// Only activates for 429 or 503 responses with a valid `Retry-After` header.
    @discardableResult
    func updateRetryAfter(status: Int, retryAfterHeader: String?) -> TimeInterval? {
        guard status == 429 || status == 503 else { return nil }

        guard let delaySecs = Self.parseRetryAfterHeader(retryAfterHeader) else {
            return nil
        }

        _retryAfterDeadline = Date().addingTimeInterval(delaySecs)
        if enableDebug {
            os_log("Retry-After gate set: %.0fs (until %{public}@)", log: Self.log, type: .debug, delaySecs, String(describing: _retryAfterDeadline))
        }
        return delaySecs
    }

    /// Clear the Retry-After gate (e.g. after a successful flush).
    func clearRetryAfter() {
        _retryAfterDeadline = nil
    }

    /// Check whether a server-requested Retry-After delay is currently active.
    func isRetryAfterActive() -> Bool {
        guard let deadline = _retryAfterDeadline else { return false }
        if Date() >= deadline {
            // Deadline has passed — auto-clear
            _retryAfterDeadline = nil
            return false
        }
        return true
    }

    /// Return the remaining Retry-After delay in milliseconds, or 0.
    func retryAfterRemainingMs() -> UInt64 {
        guard let deadline = _retryAfterDeadline else { return 0 }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            _retryAfterDeadline = nil
            return 0
        }
        return UInt64(remaining * 1000)
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
            // Clear Retry-After gate
            clearRetryAfter()

            lock.lock()
            _core = nil
            _isInitialized = false
            _appUserId = nil
            _hadPriorSdkState = false
            _attributionDeeplinkId = nil
            _attributionGclid = nil
            _attributionFbclid = nil
            _attributionFbc = nil
            _attributionTtclid = nil
            _attributionMsclkid = nil
            _initListener = nil
            _configAppId = nil
            _configEnvironment = .production
            _configBaseUrl = nil
            _recentEvents = []
            _lastFlushResult = nil
            lock.unlock()

            #if canImport(UIKit) && !os(watchOS)
            DispatchQueue.main.async { [weak self] in
                self?.hideDebugOverlay()
            }
            #endif
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
            // Update cached network status for non-blocking reads (e.g. debug overlay)
            self.lock.lock()
            self._isNetworkOnline = isOnline
            self.lock.unlock()
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

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "Layers")

    private static let installIdKey = "com.layers.installId"
    private static let attributionDeeplinkIdKey = "com.layers.deeplinkId"
    private static let attributionGclidKey = "com.layers.gclid"
    private static let attributionFbclidKey = "com.layers.fbclid"
    private static let attributionFbcKey = "com.layers.fbc"
    private static let attributionTtclidKey = "com.layers.ttclid"
    private static let attributionMsclkidKey = "com.layers.msclkid"

    /// Returns a persistent install ID, generating one on first launch.
    /// Also records whether prior SDK state existed (used by install event gating).
    /// The `_hadPriorSdkState` write is guarded by `lock` for thread safety.
    private func getOrCreateInstallIdAndRecordState() -> String {
        if let existing = UserDefaults.standard.string(forKey: Self.installIdKey) {
            lock.lock()
            _hadPriorSdkState = true
            lock.unlock()
            return existing
        }
        lock.lock()
        _hadPriorSdkState = false
        lock.unlock()
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: Self.installIdKey)
        return newId
    }

    /// Returns a persistent install ID, generating one on first launch.
    /// This static variant does not track prior-state for install event gating.
    static func getOrCreateInstallId() -> String {
        if let existing = UserDefaults.standard.string(forKey: installIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: installIdKey)
        return newId
    }

    // MARK: - Install Event Gating

    /// Determine whether this is a genuine new install or an existing app
    /// that just added the Layers SDK.
    ///
    /// Logic:
    /// 1. If the UserDefaults flag says this is NOT the first launch, respect
    ///    that — return `false`.
    /// 2. If the SDK had prior state (`com.layers.installId` already existed),
    ///    trust the flag — this is a returning user whose first-launch flag
    ///    was not yet written (e.g. upgrade from an older SDK version).
    /// 3. If the SDK had NO prior state AND the app was installed more than
    ///    `installEventMaxDiffSecs` (24 hours) ago, this is an existing app
    ///    getting the SDK for the first time — suppress `is_first_launch`.
    /// 4. If the SDK had no prior state AND the app was installed within 24
    ///    hours, this is a genuine new install — allow `is_first_launch`.
    ///
    /// - Parameters:
    ///   - isFirstLaunchByFlag: The raw first-launch flag from UserDefaults.
    ///   - now: The current date (injectable for testing). Defaults to `Date()`.
    ///   - appInstallDate: The app's install date (injectable for testing).
    ///     Defaults to reading the app bundle's creation date.
    /// - Returns: `true` if `is_first_launch` should be set to `true`.
    func shouldTreatAsNewInstall(
        isFirstLaunchByFlag: Bool,
        now: Date = Date(),
        appInstallDate: Date? = Layers.appInstallDate()
    ) -> Bool {
        // If the flag says this isn't the first launch, respect that.
        if !isFirstLaunchByFlag { return false }

        // If the SDK had prior state, trust the flag — this is a real first
        // launch scenario (e.g. flag was never written due to a bug, or state
        // was cleared).
        if _hadPriorSdkState { return true }

        // SDK has no prior state — check whether the app itself is a recent install.
        guard let installDate = appInstallDate else {
            // If we can't determine install time, default to trusting the flag.
            os_log("Install event gating: could not read app install date — trusting flag",
                   log: Layers.log, type: .info)
            return true
        }

        let elapsed = now.timeIntervalSince(installDate)
        let isRecentInstall = elapsed <= Layers.installEventMaxDiffSecs

        if !isRecentInstall && enableDebug {
            os_log(
                "Install event gated: app installed %.0fs ago (threshold=%.0fs), no prior SDK state — suppressing is_first_launch",
                log: Layers.log, type: .debug,
                elapsed, Layers.installEventMaxDiffSecs
            )
        }

        return isRecentInstall
    }

    /// Returns the app's install date by reading the creation date of the
    /// Documents directory.  The Documents directory is created on first install
    /// and persists across app updates, unlike `Bundle.main.bundlePath` which
    /// may get a new creation date on some iOS versions after an update.
    /// Returns `nil` if the date cannot be determined.
    static func appInstallDate() -> Date? {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            os_log("Failed to locate Documents directory",
                   log: Self.log, type: .error)
            return nil
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: documentsURL.path)
            return attrs[.creationDate] as? Date
        } catch {
            os_log("Failed to read Documents directory creation date: %{public}@",
                   log: Self.log, type: .error, error.localizedDescription)
            return nil
        }
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

    /// Collect AdServices token, clipboard URL, timezone, and first-launch flag,
    /// then fire an `app_open` event with attribution signals as properties
    /// (unless `autoTrackAppOpen` is false).
    private func trackAttributionSignals(core: LayersCoreHandle, clipboardAttributionEnabled: Bool, autoTrackAppOpen: Bool) {
        guard autoTrackAppOpen else { return }

        var props: [String: Any] = [
            "timezone": TimeZone.current.identifier,
        ]

        // First launch detection — UserDefaults flag + install event gating
        let isFirstLaunchByFlag = !UserDefaults.standard.bool(forKey: Self.firstLaunchTrackedKey)
        let isFirstLaunch = shouldTreatAsNewInstall(isFirstLaunchByFlag: isFirstLaunchByFlag)
        props["is_first_launch"] = isFirstLaunch
        if isFirstLaunchByFlag {
            // Always persist the flag so subsequent launches are not treated as first
            UserDefaults.standard.set(true, forKey: Self.firstLaunchTrackedKey)
        }

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

    // MARK: - User Properties HTTP POST

    /// Default ingest API base URL.
    private static let defaultBaseUrl = "https://in.layers.com"

    /// Fire-and-forget POST to /users/properties.
    /// Best-effort: errors are silently swallowed.
    private func sendUserPropertiesAsync(_ properties: [String: Any], setOnce: Bool) {
        lock.lock()
        let appId = _configAppId
        let userId = _appUserId
        let anonId = _anonymousId
        let baseUrlConfig = _configBaseUrl
        lock.unlock()

        guard let appId = appId else { return }

        let appUserId = userId ?? anonId ?? ""
        let baseUrl = (baseUrlConfig ?? Self.defaultBaseUrl)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var payload: [String: Any] = [
            "app_id": appId,
            "app_user_id": appUserId,
            "properties": properties,
            "timestamp": Self.iso8601Timestamp()
        ]
        if setOnce {
            payload["set_once"] = true
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }

        guard let url = URL(string: "\(baseUrl)/users/properties") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appId, forHTTPHeaderField: "X-App-Id")
        request.setValue("swift/\(Self.sdkVersionString())", forHTTPHeaderField: "X-SDK-Version")
        request.timeoutInterval = 10

        // Fire-and-forget on a background queue
        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Best-effort — don't throw on network errors
        }.resume()
    }

    /// Return the current timestamp in ISO 8601 format.
    private static func iso8601Timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// Return the SDK version string from the bundle, or a fallback.
    private static func sdkVersionString() -> String {
        if let version = Bundle(for: Layers.self).infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "unknown"
    }

    private static func persistenceDirectory() -> String {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let baseUrl = urls.first else {
            os_log(
                "Application Support directory not found; falling back to temporary directory for persistence.",
                log: Self.log,
                type: .error
            )
            let fallback = NSTemporaryDirectory() + "com.layers.sdk"
            do {
                try FileManager.default.createDirectory(atPath: fallback, withIntermediateDirectories: true)
            } catch {
                os_log("Failed to create fallback persistence directory: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            }
            return fallback
        }
        let dir = baseUrl.appendingPathComponent("com.layers.sdk", isDirectory: true)
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

    // MARK: - Debug Overlay Internal Helpers

    /// Record a tracked event for the debug overlay's recent events list.
    private func recordRecentEvent(name: String, propertyCount: Int) {
        lock.lock()
        _recentEvents.insert((timestamp: Date(), name: name, propertyCount: propertyCount), at: 0)
        if _recentEvents.count > Self.maxRecentEvents {
            _recentEvents.removeLast()
        }
        lock.unlock()
    }

    /// Record a flush result for the debug overlay.
    private func recordFlushResult(success: Bool, message: String?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: Date())
        let status = success ? "ok" : "fail"
        let info = message.map { "\(time) \(status) (\($0))" } ?? "\(time) \(status)"
        lock.lock()
        _lastFlushResult = info
        lock.unlock()
    }

    // MARK: - Debug Overlay State (internal for testing and overlay access)

    /// Snapshot of SDK state for the debug overlay. Avoids exposing internal properties.
    struct DebugOverlayState {
        let isInitialized: Bool
        let enableDebug: Bool
        let appId: String?
        let environment: String
        let userId: String?
        let sessionId: String?
        let queueDepth: Int?
        let installId: String?
        let consentAnalytics: String
        let consentAdvertising: String
        let attStatus: String
        let idfa: String?
        let lastFlushResult: String?
        let recentEvents: [(timestamp: Date, name: String, propertyCount: Int)]
        let networkOnline: Bool
    }

    /// Collect a snapshot of the current SDK state for the debug overlay.
    func debugOverlayState() -> DebugOverlayState {
        lock.lock()
        let initialized = _isInitialized
        let debug = _enableDebug
        let appId = _configAppId
        let env = _configEnvironment
        let userId = _appUserId
        let core = _core
        let recentEvents = _recentEvents
        let lastFlush = _lastFlushResult
        let networkOnline = _isNetworkOnline
        lock.unlock()

        let sid = (try? core?.getSessionId()) ?? nil
        let depth = core.map { Int($0.queueDepth()) }

        // Consent state
        let consentAnalytics: String
        let consentAdvertising: String
        if let consent = try? core?.getConsentState() {
            consentAnalytics = consent.analytics.map { $0 ? "yes" : "no" } ?? "unset"
            consentAdvertising = consent.advertising.map { $0 ? "yes" : "no" } ?? "unset"
        } else {
            consentAnalytics = "--"
            consentAdvertising = "--"
        }

        let envString: String
        switch env {
        case .development: envString = "development"
        case .staging: envString = "staging"
        case .production: envString = "production"
        }

        let installId = UserDefaults.standard.string(forKey: Self.installIdKey)

        return DebugOverlayState(
            isInitialized: initialized,
            enableDebug: debug,
            appId: appId,
            environment: envString,
            userId: userId,
            sessionId: sid,
            queueDepth: depth,
            installId: installId,
            consentAnalytics: consentAnalytics,
            consentAdvertising: consentAdvertising,
            attStatus: att.getStatus().rawValue,
            idfa: att.getAdvertisingId(),
            lastFlushResult: lastFlush,
            recentEvents: recentEvents,
            networkOnline: networkOnline
        )
    }

    // MARK: - Debug Overlay Public API

    #if canImport(UIKit) && !os(watchOS)
    /// Show the debug overlay on the given window.
    ///
    /// The overlay is a draggable, collapsible floating view that displays
    /// real-time SDK state including queue depth, session ID, recent events,
    /// consent state, and more. It auto-refreshes every 1.5 seconds.
    ///
    /// Silently no-ops if `enableDebug` was not set to `true` during
    /// SDK initialization.
    ///
    /// - Parameter window: The UIWindow to attach the overlay to.
    public func showDebugOverlay(in window: UIWindow) {
        guard enableDebug else { return }

        // Hide any existing overlay first
        hideDebugOverlay()

        let overlay = DebugOverlayView(sdk: self)
        overlay.show(in: window)
        lock.lock()
        _debugOverlay = overlay
        lock.unlock()
    }

    /// Hide and remove the debug overlay.
    ///
    /// Safe to call even if no overlay is currently showing.
    public func hideDebugOverlay() {
        lock.lock()
        let overlay = _debugOverlay
        _debugOverlay = nil
        lock.unlock()
        overlay?.hide()
    }

    /// Whether the debug overlay is currently visible.
    public var isDebugOverlayVisible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _debugOverlay != nil
    }
    #endif
}

// MARK: - Static Debug Overlay Convenience Methods

#if canImport(UIKit) && !os(watchOS)
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public extension Layers {
    /// Show the debug overlay on the given window. Delegates to ``Layers/showDebugOverlay(in:)``.
    static func showDebugOverlay(in window: UIWindow) {
        shared.showDebugOverlay(in: window)
    }

    /// Hide the debug overlay. Delegates to ``Layers/hideDebugOverlay()``.
    static func hideDebugOverlay() {
        shared.hideDebugOverlay()
    }
}
#endif

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

    /// Associate all subsequent events with a group. Delegates to ``Layers/group(groupId:properties:)``.
    @discardableResult
    static func group(groupId: String, properties: [String: Any] = [:]) -> SafeResult<Void> {
        shared.group(groupId: groupId, properties: properties)
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

    /// Store attribution data for server-side matching. Delegates to ``Layers/setAttributionData(deeplinkId:gclid:fbclid:ttclid:msclkid:)``.
    @discardableResult
    static func setAttributionData(
        deeplinkId: String? = nil,
        gclid: String? = nil,
        fbclid: String? = nil,
        ttclid: String? = nil,
        msclkid: String? = nil
    ) -> SafeResult<Void> {
        shared.setAttributionData(
            deeplinkId: deeplinkId,
            gclid: gclid,
            fbclid: fbclid,
            ttclid: ttclid,
            msclkid: msclkid
        )
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

    /// Set a listener to receive SDK initialization timing metrics. Delegates to ``Layers/setInitListener(_:)``.
    static func setInitListener(_ listener: ((Double, Double) -> Void)?) {
        shared.setInitListener(listener)
    }

    /// Returns a formatted string describing the current SDK state. Delegates to ``Layers/debugStatus()``.
    static func debugStatus() -> String {
        shared.debugStatus()
    }
}
