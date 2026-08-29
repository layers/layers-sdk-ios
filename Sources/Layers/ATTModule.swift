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

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "ATTModule")

    /// Info.plist key iOS requires before an app may request tracking consent.
    /// Absent it, `requestTrackingAuthorization` terminates the process rather
    /// than returning an error — see the guard in `requestTracking()`.
    static let trackingUsageDescriptionKey = "NSUserTrackingUsageDescription"

    /// Whether the host app declares the ATT usage description.
    static var hasTrackingUsageDescription: Bool {
        let value = Bundle.main.object(
            forInfoDictionaryKey: trackingUsageDescriptionKey
        ) as? String
        return !(value?.isEmpty ?? true)
    }

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
    /// Legacy opt-in mirroring from ATT status to Layers ad consent.
    private var _drivesAdvertisingConsent = false
    /// Set once the host app sets any ad category itself — from then on the
    /// app owns them and ATT stops writing them.
    private var _appOwnsAdConsent = false
    /// Owns `_lastDeviceContext`, which ATT updates must be layered onto —
    /// `setDeviceContext` replaces the core's context wholesale.
    private weak var _sdk: Layers?

    private var lockedCore: LayersCoreHandle? {
        lock.lock()
        defer { lock.unlock() }
        return _core
    }

    private var lockedSdk: Layers? {
        lock.lock()
        defer { lock.unlock() }
        return _sdk
    }

    init() {}

    func attach(core: LayersCoreHandle, sdk: Layers, drivesAdvertisingConsent: Bool) {
        lock.lock()
        _core = core
        _sdk = sdk
        _drivesAdvertisingConsent = drivesAdvertisingConsent
        // A fresh `initialize` starts a fresh consent conversation.
        _appOwnsAdConsent = false
        lock.unlock()
    }

    /// Record that the host app set an ad-consent category explicitly.
    /// Called by ``Layers/setConsent(_:)``; after this, ATT answers no longer
    /// touch `ad_storage` / `ad_user_data` / `ad_personalization`.
    func appDidSetAdvertisingConsent() {
        lock.lock()
        _appOwnsAdConsent = true
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

            // Calling this without NSUserTrackingUsageDescription in the host
            // app's Info.plist does not fail — iOS terminates the process with
            // SIGABRT (TCC: "attempted to access privacy-sensitive data
            // without a usage description"). There is no error to catch and
            // nothing to recover, so the only defence is not calling it.
            // An analytics SDK must never be able to crash the app it measures.
            guard Self.hasTrackingUsageDescription else {
                NSLog("""
                    [Layers] ATT request skipped: Info.plist is missing \
                    NSUserTrackingUsageDescription. iOS terminates any app \
                    that requests tracking authorization without it, so the \
                    SDK did not make the request. Add the key with a short \
                    explanation of how your app uses tracking.
                    """)
                // No prompt was shown, so consent genuinely is undetermined.
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

    /// Push current ATT state into the Rust core.
    ///
    /// Delegates to ``Layers/applyATTDeviceContext(idfa:idfv:attStatus:core:)``
    /// because the update is PARTIAL: `setDeviceContext` replaces the core's
    /// context wholesale, and only `Layers` holds the last full context to
    /// layer these three fields onto.
    func syncToCore(status: Status? = nil) {
        guard let core = lockedCore, let sdk = lockedSdk else { return }
        let currentStatus = status ?? getStatus()
        sdk.applyATTDeviceContext(
            idfa: currentStatus == .authorized ? getAdvertisingId() : nil,
            idfv: getVendorId(),
            attStatus: currentStatus.rawValue,
            core: core
        )

        mirrorToAdvertisingConsent(status: currentStatus, core: core)
    }

    // MARK: - Legacy ATT → advertising consent compatibility

    /// The legacy Consent Mode v2 ad-category verdict for an ATT answer.
    ///
    /// `nil` means "no verdict": the user has not answered the prompt, so
    /// consent must be left exactly as it is rather than manufacturing a
    /// decision nobody made.
    static func advertisingConsent(forATT status: Status) -> Bool? {
        switch status {
        case .authorized:
            return true
        // `.restricted` is an OS-level block (parental controls / MDM) — the
        // user cannot grant tracking, which is a denial, not an absence.
        case .denied, .restricted:
            return false
        case .notDetermined, .unknown:
            return nil
        }
    }

    /// Write an ATT-derived verdict into the core's three ad categories,
    /// leaving the analytics categories exactly as they were.
    ///
    /// The analytics carry-through is load-bearing: `set_consent` REPLACES the
    /// whole consent state in the core (`core/src/consent.rs`
    /// `ConsentManager::set` — `*state = next`), so an ad-only update that
    /// omitted `analytics_storage` would silently revoke an explicit analytics
    /// grant and, under `consentRequired: true`, close the flush gate.
    static func applyAdvertisingConsent(_ granted: Bool, to core: LayersCoreHandle) throws {
        let current = try? core.getConsentState()
        try core.setConsent(consent: UniFfiConsent(
            analyticsStorage: current?.analyticsStorage,
            adStorage: granted,
            adUserData: granted,
            adPersonalization: granted,
            analytics: current?.analytics,
            advertising: nil
        ))
    }

    /// Preserve the deprecated opt-in behavior that mirrors an ATT answer into
    /// Layers ad consent. New configurations leave this disabled: ATT status
    /// and IDFA availability are recorded independently, while the host app
    /// updates Layers consent explicitly. If the app has already set an ad
    /// category, its explicit decision wins in both directions.
    private func mirrorToAdvertisingConsent(status: Status, core: LayersCoreHandle) {
        lock.lock()
        let enabled = _drivesAdvertisingConsent
        let appOwns = _appOwnsAdConsent
        lock.unlock()

        // The host app's own decision wins in both directions.
        guard enabled, !appOwns else { return }
        guard let granted = Self.advertisingConsent(forATT: status) else { return }

        do {
            try Self.applyAdvertisingConsent(granted, to: core)
        } catch {
            os_log(
                "ATT consent mirror failed: %{public}@",
                log: Self.log, type: .error, error.localizedDescription
            )
        }
    }
}
