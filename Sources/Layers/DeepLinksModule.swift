import Foundation
import os.log

/// Deep linking module for handling URL schemes and Universal Links.
/// Parses incoming URLs, extracts UTM attribution, and forwards to the Rust core.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class DeepLinksModule: @unchecked Sendable {

    private static let log = OSLog(subsystem: "io.layers.sdk", category: "DeepLinksModule")

    // MARK: - Types

    public struct DeepLinkData: Sendable {
        public let url: URL
        public let scheme: String?
        public let host: String?
        public let path: String
        public let queryParameters: [String: String]
        public let isUniversalLink: Bool

        public init(url: URL) {
            self.url = url
            self.scheme = url.scheme
            self.host = url.host
            self.path = url.path
            self.queryParameters = Self.extractQueryParams(from: url)
            self.isUniversalLink = url.scheme == "https" || url.scheme == "http"
        }

        private static func extractQueryParams(from url: URL) -> [String: String] {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let items = components.queryItems else { return [:] }
            return items.reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
        }
    }

    public struct AttributionData: Sendable {
        public let source: String?
        public let medium: String?
        public let campaign: String?
        public let content: String?
        public let term: String?
        public let clickIds: [String: String]

        init(from params: [String: String]) {
            self.source = params["utm_source"]
            self.medium = params["utm_medium"]
            self.campaign = params["utm_campaign"]
            self.content = params["utm_content"]
            self.term = params["utm_term"]

            var ids: [String: String] = [:]
            for param in Self.clickIdParams {
                if let value = params[param] {
                    ids[param] = value
                }
            }
            self.clickIds = ids
        }

        private static let clickIdParams = [
            "gclid", "gbraid", "wbraid",    // Google
            "fbclid",                         // Meta
            "ttclid",                         // TikTok
            "twclid",                         // X (Twitter)
            "msclkid",                        // Microsoft
            "li_fat_id",                      // LinkedIn
            "sclid",                          // Snapchat
            "irclickid"                       // Impact
        ]
    }

    public struct Listener: Sendable {
        public let onDeepLink: @Sendable (DeepLinkData, AttributionData) -> Void

        public init(onDeepLink: @escaping @Sendable (DeepLinkData, AttributionData) -> Void) {
            self.onDeepLink = onDeepLink
        }
    }

    // MARK: - Properties

    private var _core: LayersCoreHandle?
    private let lock = NSLock()
    private var listeners: [UUID: Listener] = [:]

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

    /// Parse a URL string into deep link data without tracking.
    public func parseUrl(_ urlString: String) -> DeepLinkData? {
        guard let url = URL(string: urlString) else { return nil }
        return DeepLinkData(url: url)
    }

    /// Handle an incoming deep link. Parses the URL, extracts attribution, tracks via Rust core,
    /// and notifies registered listeners.
    @discardableResult
    public func handleDeepLink(_ url: URL) -> SafeResult<Void> {
        let data = DeepLinkData(url: url)
        let attribution = AttributionData(from: data.queryParameters)

        // Track via Rust core as a deep_link_opened event
        if let core = lockedCore {
            var props: [String: String] = ["url": url.absoluteString]
            if let scheme = data.scheme { props["scheme"] = scheme }
            if let host = data.host { props["host"] = host }
            props["path"] = data.path

            // UTM parameters
            if let s = attribution.source { props["utm_source"] = s }
            if let m = attribution.medium { props["utm_medium"] = m }
            if let c = attribution.campaign { props["utm_campaign"] = c }
            if let ct = attribution.content { props["utm_content"] = ct }
            if let t = attribution.term { props["utm_term"] = t }

            // Click ID parameters (fbclid, gclid, ttclid, etc.)
            for (key, value) in attribution.clickIds {
                props[key] = value
            }

            let json = Layers.jsonString(from: props)
            do {
                try core.track(
                    eventName: "deep_link_opened",
                    propertiesJson: json,
                    userId: nil,
                    anonymousId: nil
                )
            } catch {
                os_log("deep_link_opened track failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            }
        }

        // Notify listeners
        let currentListeners: [Listener]
        lock.lock()
        currentListeners = Array(listeners.values)
        lock.unlock()

        for listener in currentListeners {
            listener.onDeepLink(data, attribution)
        }

        return .success(())
    }

    /// Register a listener for incoming deep links.
    /// Returns an unsubscribe closure.
    @discardableResult
    public func addListener(_ listener: Listener) -> @Sendable () -> Void {
        let id = UUID()
        lock.lock()
        listeners[id] = listener
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.listeners.removeValue(forKey: id)
        }
    }

    /// Remove all registered listeners.
    public func removeAllListeners() {
        lock.lock()
        listeners.removeAll()
        lock.unlock()
    }
}
