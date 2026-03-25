import Foundation
import os.log
#if canImport(AdServices)
import AdServices
#endif

/// AdServices module for Apple Search Ads attribution.
/// Requests the attribution token from the AdServices framework (iOS 14.3+).
/// This does NOT require ATT consent.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class AdServicesModule: @unchecked Sendable {

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "AdServicesModule")

    private let lock = NSLock()
    private var _token: String?
    private var _hasRequested = false

    init() {}

    /// Request the AdServices attribution token. Safe to call on any platform;
    /// returns nil on non-iOS or iOS < 14.3.
    ///
    /// The token is cached after first successful request. Subsequent calls
    /// return the cached value without hitting the OS API again.
    public func requestAttributionToken() -> String? {
        lock.lock()
        if _hasRequested {
            let cached = _token
            lock.unlock()
            return cached
        }
        // Mark as requested while still holding the lock to prevent
        // concurrent callers from also calling fetchToken().
        _hasRequested = true
        lock.unlock()

        let token = Self.fetchToken()

        lock.lock()
        _token = token
        lock.unlock()

        if token != nil {
            os_log("AdServices attribution token obtained", log: Self.log, type: .debug)
        } else {
            os_log("AdServices attribution token unavailable", log: Self.log, type: .debug)
        }

        return token
    }

    /// Whether AdServices is available on this device.
    public func isAvailable() -> Bool {
        #if os(iOS) && canImport(AdServices)
        if #available(iOS 14.3, *) { return true }
        #endif
        return false
    }

    /// The cached token, if previously requested. Does not trigger a new request.
    public var cachedToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return _token
    }

    // MARK: - Private

    private static func fetchToken() -> String? {
        #if os(iOS) && canImport(AdServices)
        if #available(iOS 14.3, *) {
            do {
                let token = try AAAttribution.attributionToken()
                return token
            } catch {
                os_log(
                    "AAAttribution.attributionToken() failed: %{public}@",
                    log: Self.log,
                    type: .error,
                    error.localizedDescription
                )
                return nil
            }
        }
        #endif
        return nil
    }
}
