import Foundation
import os.log
#if canImport(StoreKit)
import StoreKit
#endif

/// SKAdNetwork module for iOS install attribution.
/// Thin wrapper: the Rust core evaluates SKAN rules and returns conversion values.
/// This module only calls the OS-level SKAdNetwork APIs.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class SKANModule: @unchecked Sendable {

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "SKANModule")

    // MARK: - Types

    public enum Preset: String, Sendable {
        case subscriptions
        case engagement
        case iap
        case custom
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var _core: LayersCoreHandle?
    /// Whether Apple's postback window has been armed this launch. Arm exactly
    /// once — re-registering resets the OS conversion value to 0.
    private var _armed = false

    private var lockedCore: LayersCoreHandle? {
        lock.lock()
        defer { lock.unlock() }
        return _core
    }

    init() {}

    func attach(core: LayersCoreHandle) {
        lock.lock()
        _core = core
        // A fresh core attach is a new launch for arming purposes (e.g. after
        // shutdown + re-init), so allow arming again for the new window.
        _armed = false
        lock.unlock()
    }

    // MARK: - Public API

    /// Apply a built-in preset; the Rust core loads the canonical rule table.
    /// `.custom` is a no-op — supply rules via ``setRules(_:)`` instead.
    @discardableResult
    public func setPreset(_ preset: Preset) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        if preset == .custom { return .success(()) }
        do {
            try core.skanSetPreset(preset: preset.rawValue)
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    /// Set custom conversion rules as a JSON array string. The Rust core parses,
    /// validates, clamps (0–63), and sorts them by priority.
    @discardableResult
    public func setRules(_ rulesJson: String) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        do {
            try core.skanSetRules(rulesJson: rulesJson)
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    /// Apply the `skan` block (preset / customRules / enabled) from the cached
    /// remote config. Called automatically during SDK init.
    @discardableResult
    public func configureFromRemoteConfig() -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        do {
            try core.skanConfigureFromRemoteConfig()
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    /// Apply the cached remote-config `skan` block AND arm Apple's postback
    /// window exactly once — on the first config that actually enables SKAN,
    /// whether at init or a later polled refresh (so a first success after a
    /// failed/timed-out init fetch still arms). Re-arming would reset the OS
    /// conversion value to 0, so this is one-shot per launch. Used internally
    /// by the SDK's init + config-refresh paths.
    @discardableResult
    func configureAndArmFromRemoteConfig() -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        do {
            try core.skanConfigureFromRemoteConfig()
        } catch {
            return .failure(Layers.mapError(error))
        }
        // Arm whenever SKAN is enabled (a non-disabled config applied) — including
        // a bare `{"enabled":true}` with no rules, which still opens Apple's window.
        let enabled = core.skanIsEnabled()
        lock.lock()
        let shouldArm = enabled && !_armed
        if shouldArm { _armed = true }
        lock.unlock()
        if shouldArm { registerForAttribution() }
        return .success(())
    }

    /// Evaluate an event through the SKAN rule engine (in the Rust core). If the
    /// conversion value increases, push it to StoreKit and return the new fine
    /// value; otherwise return the current value. Events tracked via
    /// `Layers.track`/`Layers.screen` are forwarded here automatically.
    @discardableResult
    public func processEvent(eventName: String, properties: [String: String] = [:]) -> SafeResult<Int> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        let propsJson =
            (try? JSONSerialization.data(withJSONObject: properties))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            if let update = try core.skanProcessEvent(eventName: eventName, propertiesJson: propsJson) {
                updateOSConversionValue(
                    fineValue: Int(update.fineValue),
                    coarseValue: update.coarseValue,
                    lockWindow: update.lockWindow
                )
            }
            // The native StoreKit apply + floor commit happen asynchronously (see
            // updateOSConversionValue → recordConversionResult), so report the
            // CONFIRMED floor rather than the just-decided value — if the native
            // call fails, the floor never advanced and the caller must not see the
            // higher value as if the post succeeded.
            return .success(Int(core.skanCurrentValue()))
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    /// Internal: forward a tracked event (with already-serialized JSON
    /// properties) to the SKAN engine. Best-effort — never throws, never
    /// disrupts tracking, and is a cheap no-op when SKAN is unconfigured.
    func processEventJson(eventName: String, propertiesJson: String?) {
        guard let core = lockedCore else { return }
        do {
            if let update = try core.skanProcessEvent(
                eventName: eventName,
                propertiesJson: propertiesJson ?? "{}"
            ) {
                updateOSConversionValue(
                    fineValue: Int(update.fineValue),
                    coarseValue: update.coarseValue,
                    lockWindow: update.lockWindow
                )
            }
        } catch {
            // Best-effort — SKAN must never disrupt event tracking.
        }
    }

    /// Register app for SKAN attribution.
    @discardableResult
    public func registerForAttribution() -> SafeResult<Void> {
        #if os(iOS) && canImport(StoreKit)
        if #available(iOS 15.4, *) {
            Task {
                do {
                    try await SKAdNetwork.updatePostbackConversionValue(0)
                } catch {
                    os_log("SKAdNetwork.updatePostbackConversionValue failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                }
            }
        } else if #available(iOS 14.0, *) {
            SKAdNetwork.registerAppForAdNetworkAttribution()
        }
        #endif
        return .success(())
    }

    /// Whether SKAdNetwork is supported on this device.
    public func isSupported() -> Bool {
        #if os(iOS) && canImport(StoreKit)
        if #available(iOS 14.0, *) { return true }
        #endif
        return false
    }

    /// The highest SKAN version supported by this OS.
    public func getVersion() -> String {
        #if os(iOS) && canImport(StoreKit)
        if #available(iOS 16.1, *) { return "4.0" }
        if #available(iOS 15.4, *) { return "3.0" }
        if #available(iOS 14.6, *) { return "2.2" }
        if #available(iOS 14.5, *) { return "2.1" }
        if #available(iOS 14.0, *) { return "2.0" }
        #endif
        return "unsupported"
    }

    /// Whether SKAN 4.0 (coarse values, multiple postbacks) is available.
    public func supportsSKAN4() -> Bool {
        #if os(iOS) && canImport(StoreKit)
        if #available(iOS 16.1, *) { return true }
        #endif
        return false
    }

    // MARK: - Private

    private func updateOSConversionValue(fineValue: Int, coarseValue: String?, lockWindow: Bool) {
        #if os(iOS) && canImport(StoreKit)
        if #available(iOS 16.1, *), let coarseValue {
            let coarse = mapCoarseValue(coarseValue)
            Task {
                do {
                    try await SKAdNetwork.updatePostbackConversionValue(fineValue, coarseValue: coarse, lockWindow: lockWindow)
                    recordConversionResult(fineValue: fineValue, success: true)
                } catch {
                    os_log("SKAdNetwork.updatePostbackConversionValue(fine:coarse:lock:) failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                    recordConversionResult(fineValue: fineValue, success: false)
                }
            }
        } else if #available(iOS 15.4, *) {
            Task {
                do {
                    try await SKAdNetwork.updatePostbackConversionValue(fineValue)
                    recordConversionResult(fineValue: fineValue, success: true)
                } catch {
                    os_log("SKAdNetwork.updatePostbackConversionValue(fine:) failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                    recordConversionResult(fineValue: fineValue, success: false)
                }
            }
        } else if #available(iOS 14.0, *) {
            // Legacy void API — no failure surface, so treat the apply as committed.
            SKAdNetwork.updateConversionValue(fineValue)
            recordConversionResult(fineValue: fineValue, success: true)
        }
        #else
        // No StoreKit (e.g. macOS unit tests): there is no native postback to fail,
        // so commit the floor in the core so its monotonic state stays consistent.
        recordConversionResult(fineValue: fineValue, success: true)
        #endif
    }

    /// Report the StoreKit apply outcome back to the core so it commits the
    /// monotonic floor only on success (and re-issues on failure). Best-effort —
    /// SKAN must never disrupt tracking. See `core/src/skan.rs` record_conversion_result.
    private func recordConversionResult(fineValue: Int, success: Bool) {
        guard let core = lockedCore, (0...255).contains(fineValue) else { return }
        try? core.skanRecordConversionResult(value: UInt8(fineValue), success: success)
    }

    #if os(iOS) && canImport(StoreKit)
    /// Map a core-supplied coarse value onto Apple's enum.
    ///
    /// `.low` remains the fallback — it is Apple's most conservative bucket and
    /// the long-standing behaviour — but an unrecognised string is now logged
    /// instead of being indistinguishable from a genuine `"low"`. That mattered
    /// little while the core sent `nil` for every preset rule and this function
    /// was only reached for explicitly-configured values; now that the core
    /// derives a coarse value for every match, this is on the path of every
    /// SKAN-configured install, and a server-side typo in `coarseValue` would
    /// otherwise silently post every install as low-value.
    @available(iOS 16.1, *)
    private func mapCoarseValue(_ value: String) -> SKAdNetwork.CoarseConversionValue {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high":   return .high
        case "medium": return .medium
        case "low":    return .low
        default:
            os_log(
                "unknown SKAN coarse value %{public}@ — posting 'low'",
                log: Self.log,
                type: .error,
                value
            )
            return .low
        }
    }
    #endif
}
