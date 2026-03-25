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
        case ecommerce
        case gaming
        case custom
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var _core: LayersCoreHandle?

    private var lockedCore: LayersCoreHandle? {
        lock.lock()
        defer { lock.unlock() }
        return _core
    }

    init() {}

    func attach(core: LayersCoreHandle) {
        lock.lock()
        _core = core
        lock.unlock()
    }

    // MARK: - Public API

    /// Set a preset configuration. Rules are stored in the Rust core.
    @discardableResult
    public func setPreset(_ preset: Preset) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: ["preset": preset.rawValue])
            let json = String(data: jsonData, encoding: .utf8) ?? "{}"
            try core.setUserProperties(propertiesJson: json)
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    /// Set custom conversion rules as a JSON array string.
    @discardableResult
    public func setRules(_ rulesJson: String) -> SafeResult<Void> {
        guard let core = lockedCore else { return .failure(.notInitialized) }
        do {
            try core.setUserProperties(propertiesJson: "{\"skan_rules\":\(rulesJson)}")
            return .success(())
        } catch {
            return .failure(Layers.mapError(error))
        }
    }

    /// Process an event through SKAN rules and update the OS conversion value.
    /// The Rust core evaluates SKAN rules server-side. This method triggers a local
    /// OS-level conversion value update based on the event properties.
    @discardableResult
    public func processEvent(eventName: String, properties: [String: String] = [:]) -> SafeResult<Int> {
        guard lockedCore != nil else { return .failure(.notInitialized) }

        // Extract conversion value from properties if the Rust core / caller provided one.
        // The "skan_conversion_value" property is set by the core or by commerce tracking.
        let fineValue = properties["skan_conversion_value"].flatMap(Int.init) ?? 0
        let coarseValue = properties["skan_coarse_value"]
        let lockWindow = properties["skan_lock_window"] == "true"

        updateOSConversionValue(fineValue: fineValue, coarseValue: coarseValue, lockWindow: lockWindow)
        return .success(fineValue)
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
                } catch {
                    os_log("SKAdNetwork.updatePostbackConversionValue(fine:coarse:lock:) failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                }
            }
        } else if #available(iOS 15.4, *) {
            Task {
                do {
                    try await SKAdNetwork.updatePostbackConversionValue(fineValue)
                } catch {
                    os_log("SKAdNetwork.updatePostbackConversionValue(fine:) failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                }
            }
        } else if #available(iOS 14.0, *) {
            SKAdNetwork.updateConversionValue(fineValue)
        }
        #endif
    }

    #if os(iOS) && canImport(StoreKit)
    @available(iOS 16.1, *)
    private func mapCoarseValue(_ value: String) -> SKAdNetwork.CoarseConversionValue {
        switch value.lowercased() {
        case "high":   return .high
        case "medium": return .medium
        default:       return .low
        }
    }
    #endif
}
