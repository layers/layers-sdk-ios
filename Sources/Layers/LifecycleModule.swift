import Foundation
import os.log
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Auto-capture of canonical lifecycle events.
///
/// On `attach`, this module:
///   1. Fires `$app_install` once per install.
///   2. Fires `$first_open` once per install.
///   3. Fires `$app_update` whenever `CFBundleVersion` changes.
///   4. Fires the initial `$app_open`.
///   5. Subscribes to `UIApplication` notifications to fire subsequent
///      `$app_open` (foreground), `$app_background`, and `$app_terminate`.
///
/// All persisted state lives in `UserDefaults` under the `layers.*` namespace.
/// The persisted keys are intentionally separate from the legacy `com.layers.*`
/// keys so the new namespace doesn't interact with existing install gating.
///
/// Opt out via `LayersConfig(automaticLifecycleTrackingEnabled: false)`.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class LifecycleModule: @unchecked Sendable {

    // MARK: - UserDefaults Keys

    /// `Bool` — set to `true` after the first `$first_open` is emitted.
    public static let firstOpenEmittedKey = "layers.first_open_emitted"

    /// `Bool` — set to `true` after the first `$app_install` is emitted.
    public static let appInstallEmittedKey = "layers.app_install_emitted"

    /// `String` — last seen `CFBundleVersion`. Compared on attach to detect `$app_update`.
    public static let lastBundleVersionKey = "layers.last_bundle_version"

    // MARK: - Tracker Abstraction

    /// Closure-based tracker injection. Exists so unit tests can run without
    /// a fully initialized `Layers` singleton (which requires the Rust core
    /// XCFramework). Production callers use ``attach(sdk:)``.
    public typealias Tracker = (_ event: String, _ properties: [String: Any]) -> Void

    // MARK: - Properties

    private let lock = NSLock()
    private var tracker: Tracker?
    private var observers: [NSObjectProtocol] = []
    private var isAttached = false

    /// When `true`, the very next `didBecomeActive` notification is ignored —
    /// we already fired `$app_open` from `attach`, and on iOS the SDK is typically
    /// initialized inside `application(_:didFinishLaunchingWithOptions:)`, so
    /// `didBecomeActive` fires moments later. Without this guard we'd double-fire.
    private var initialActiveSuppressed = false

    /// Injected `UserDefaults` (defaults to `.standard`). Internal to allow tests
    /// to use a sandboxed suite.
    let userDefaults: UserDefaults

    /// Injected `CFBundleVersion`. `nil` outside of a real app bundle. Internal
    /// to allow tests to control the value.
    let bundleVersion: String?

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "lifecycle")

    // MARK: - Init

    public convenience init() {
        self.init(userDefaults: .standard, bundleVersion: Self.currentBundleVersion())
    }

    init(userDefaults: UserDefaults, bundleVersion: String?) {
        self.userDefaults = userDefaults
        self.bundleVersion = bundleVersion
    }

    deinit {
        // Synchronous cleanup; deinit cannot call `detach()` safely because
        // `detach()` takes the lock and may dispatch — but observers must go.
        let pending = observers
        observers = []
        for o in pending {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: - Attach / Detach

    /// Attach to the Layers singleton. Production entry point.
    func attach(sdk: Layers) {
        attach(tracker: { [weak sdk] event, props in
            _ = sdk?.track(event, properties: props)
        })
    }

    /// Attach with an explicit tracker closure. Internal — used by both production
    /// (`attach(sdk:)`) and unit tests.
    func attach(tracker: @escaping Tracker) {
        lock.lock()
        if isAttached {
            lock.unlock()
            return
        }
        self.tracker = tracker
        isAttached = true
        lock.unlock()

        emitInitialEvents()
        registerObservers()
    }

    /// Stop observing and clear the tracker. Idempotent.
    func detach() {
        lock.lock()
        let pending = observers
        observers = []
        tracker = nil
        isAttached = false
        initialActiveSuppressed = false
        lock.unlock()

        for o in pending {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: - Initial Burst

    private func emitInitialEvents() {
        let baseProps: [String: Any] = lifecycleBaseProperties()

        let alreadyInstalled = userDefaults.bool(forKey: Self.appInstallEmittedKey)
        let storedVersion = userDefaults.string(forKey: Self.lastBundleVersionKey)

        // $app_install — fires exactly once per install (ever).
        if !alreadyInstalled {
            emit("$app_install", properties: baseProps)
            userDefaults.set(true, forKey: Self.appInstallEmittedKey)
        }

        // $first_open is emitted by the Rust core during init() — owned there
        // because the per-install gate (`PersistedIdentity.first_open_emitted`)
        // lives in the same persistence record as device_id / anonymous_id /
        // first_open_time. Emitting it here too would double-fire on first
        // install (the two persistence stores — UserDefaults and Rust file
        // backend — don't share state). Keep the constant for backward
        // compatibility but stop using it.

        // $app_update — fires when CFBundleVersion has changed since last launch.
        if let prev = storedVersion, let cur = bundleVersion, prev != cur {
            var updateProps = baseProps
            updateProps["previous_app_version"] = prev
            emit("$app_update", properties: updateProps)
        }

        if let cur = bundleVersion {
            userDefaults.set(cur, forKey: Self.lastBundleVersionKey)
        }

        // $app_open — fires every time the SDK attaches (i.e., every cold launch).
        emit("$app_open", properties: baseProps)
    }

    // MARK: - Notification Handlers

    private func registerObservers() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default

        let didLaunch = center.addObserver(
            forName: UIApplication.didFinishLaunchingNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleDidFinishLaunching()
        }
        let didBecomeActive = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleDidBecomeActive()
        }
        let didEnterBackground = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleDidEnterBackground()
        }
        let willTerminate = center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWillTerminate()
        }

        lock.lock()
        observers.append(contentsOf: [didLaunch, didBecomeActive, didEnterBackground, willTerminate])
        lock.unlock()
        #endif
    }

    /// `didFinishLaunching` is mostly unreachable in practice — the SDK is
    /// usually initialized synchronously inside `didFinishLaunchingWithOptions`,
    /// so by the time we register the observer the notification has already
    /// fired. Kept for symmetry with the protocol contract.
    func handleDidFinishLaunching() {
        // No-op; $app_open was already emitted in `emitInitialEvents`.
    }

    /// `didBecomeActive` fires every time the app comes to the foreground.
    /// We suppress the first one (it racy-fires alongside cold-launch init)
    /// and emit `$app_open` on each subsequent foregrounding.
    func handleDidBecomeActive() {
        lock.lock()
        if !initialActiveSuppressed {
            initialActiveSuppressed = true
            lock.unlock()
            return
        }
        lock.unlock()
        emit("$app_open", properties: lifecycleBaseProperties())
    }

    func handleDidEnterBackground() {
        emit("$app_background", properties: lifecycleBaseProperties())
    }

    func handleWillTerminate() {
        emit("$app_terminate", properties: lifecycleBaseProperties())
    }

    // MARK: - Internals

    private func emit(_ event: String, properties: [String: Any]) {
        lock.lock()
        let t = tracker
        lock.unlock()
        guard let t else {
            os_log("LifecycleModule emit before attach: %{public}@", log: Self.log, type: .debug, event)
            return
        }
        t(event, properties)
    }

    private func lifecycleBaseProperties() -> [String: Any] {
        var props: [String: Any] = [:]
        if let v = bundleVersion {
            props["app_version"] = v
        }
        return props
    }

    // MARK: - Test Helpers

    /// Internal hook for unit tests. Resets `initialActiveSuppressed` so a test
    /// can simulate `didBecomeActive` after attach without the "first" suppression.
    func _resetInitialActiveSuppressionForTesting() {
        lock.lock()
        initialActiveSuppressed = true
        lock.unlock()
    }

    /// Internal hook for unit tests. Returns whether the module currently has
    /// observers registered.
    var _observerCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return observers.count
    }

    // MARK: - Bundle Version Lookup

    static func currentBundleVersion() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}
