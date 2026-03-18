import Foundation
import os.log
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(UIKit)
import UIKit
#endif

/// App Tracking Transparency module for iOS.
/// Thin wrapper that calls OS APIs and feeds results into the Rust core.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class ATTModule: @unchecked Sendable {

    private static let log = OSLog(subsystem: "io.layers.sdk", category: "ATTModule")

    // MARK: - Types

    public enum Status: String, Sendable {
        case notDetermined = "not_determined"
        case restricted
        case denied
        case authorized
        case unknown

        #if os(iOS) && canImport(AppTrackingTransparency)
        @available(iOS 14.0, *)
        init(from status: ATTrackingManager.AuthorizationStatus) {
            switch status {
            case .notDetermined: self = .notDetermined
            case .restricted:    self = .restricted
            case .denied:        self = .denied
            case .authorized:    self = .authorized
            @unknown default:    self = .unknown
            }
        }
        #endif
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

    /// Get the current ATT authorization status.
    public func getStatus() -> Status {
        #if os(iOS) && canImport(AppTrackingTransparency)
        if #available(iOS 14.0, *) {
            return Status(from: ATTrackingManager.trackingAuthorizationStatus)
        }
        #endif
        return .unknown
    }

    /// Request tracking authorization from the user.
    /// Updates the Rust core with the resulting status and IDFA.
    @discardableResult
    public func requestTracking() async -> SafeResult<Status> {
        #if os(iOS) && canImport(AppTrackingTransparency)
        if #available(iOS 14.0, *) {
            let current = ATTrackingManager.trackingAuthorizationStatus
            guard current == .notDetermined else {
                let status = Status(from: current)
                syncToCore(status: status)
                return .success(status)
            }

            let raw = await ATTrackingManager.requestTrackingAuthorization()
            let status = Status(from: raw)
            syncToCore(status: status)
            return .success(status)
        }
        #endif
        return .success(.unknown)
    }

    /// Whether ATT is supported on this device and OS version.
    public func isSupported() -> Bool {
        #if os(iOS) && canImport(AppTrackingTransparency)
        if #available(iOS 14.0, *) { return true }
        #endif
        return false
    }

    /// Whether the user has already been prompted.
    public func hasBeenPrompted() -> Bool {
        #if os(iOS) && canImport(AppTrackingTransparency)
        if #available(iOS 14.0, *) {
            return ATTrackingManager.trackingAuthorizationStatus != .notDetermined
        }
        #endif
        return false
    }

    /// Get the IDFA if tracking is authorized. Returns nil otherwise.
    public func getAdvertisingId() -> String? {
        #if os(iOS) && canImport(AdSupport) && canImport(AppTrackingTransparency)
        if #available(iOS 14.0, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else {
                return nil
            }
            let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            if idfa == "00000000-0000-0000-0000-000000000000" { return nil }
            return idfa
        }
        #endif
        return nil
    }

    /// Get the IDFV (always available, does not require ATT).
    public func getVendorId() -> String? {
        #if os(iOS) && canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    // MARK: - Internal

    /// Push current ATT state into the Rust core via setDeviceContext.
    func syncToCore(status: Status? = nil) {
        guard let core = lockedCore else { return }
        let currentStatus = status ?? getStatus()
        let context = UniFfiDeviceContext(
            platform: nil,
            osVersion: nil,
            appVersion: nil,
            deviceModel: nil,
            locale: nil,
            buildNumber: nil,
            screenSize: nil,
            installId: nil,
            idfa: getAdvertisingId(),
            idfv: getVendorId(),
            attStatus: currentStatus.rawValue,
            deeplinkId: nil,
            gclid: nil,
            timezone: nil
        )
        do {
            try core.setDeviceContext(context: context)
        } catch {
            os_log("setDeviceContext failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
        }
    }
}
