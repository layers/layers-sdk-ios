import Foundation

/// Where a deferred deep link came from.
///
/// - `clickResolve`: the `deeplink` field `POST /clicks/resolve` returns on a
///   match for a Layers tracking link (`/l/`) click. The probe runs only where
///   the existing gates already allow it: the server's
///   `fingerprint_resolve_enabled` remote config (default OFF) and the core's
///   consent / delivery gate. Nothing here turns either on.
/// - `installReferrer`: Android only; never produced on Apple platforms.
///   Listed so the value set matches every Layers SDK.
/// - `clipboard`: reserved. The pasteboard carries only a click id
///   (`https://in.layers.com/c/<clickId>`), and no server endpoint yet turns a
///   pasted click id into a payload, so no current path produces it. Clipboard
///   attribution stays opt-in and off.
public enum DeferredDeepLinkSource: String, Sendable, Equatable {
    case installReferrer = "install_referrer"
    case clickResolve = "click_resolve"
    case clipboard
}

/// The payload of the Layers tracking link (`in.layers.com/l/tlnk_…`) that led
/// to this install, delivered once per install.
///
/// Treat `payload` as untrusted input, exactly like any URL the app is opened
/// with: route on keys you know and validate values before acting on them.
public struct DeferredDeepLink: Sendable, Equatable {
    /// The link's flat key/value payload (at most 24 keys, 512 bytes server-side).
    public let payload: [String: String]
    public let source: DeferredDeepLinkSource
    /// The Layers click id, when the source carried one.
    public let clickId: String?

    public init(payload: [String: String], source: DeferredDeepLinkSource, clickId: String? = nil) {
        self.payload = payload
        self.source = source
        self.clickId = clickId
    }
}

extension DeferredDeepLink {
    /// A tracking-link payload as a flat `[String: String]`, or nil when it
    /// holds nothing usable.
    ///
    /// The server stores a flat string map. A number or a boolean is kept as
    /// its string form; anything nested is dropped rather than stringified, so
    /// an app never receives a value it has to parse twice. Same rule as the
    /// React Native and Android SDKs.
    static func normalizePayload(_ raw: Any?) -> [String: String]? {
        var value = raw
        if let string = value as? String {
            guard let data = string.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
            value = parsed
        }
        guard let dict = value as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, element) in dict {
            if let string = element as? String {
                out[key] = string
            } else if let number = element as? NSNumber {
                // JSONSerialization hands back booleans as NSNumber too; tell
                // them apart so `true` stays "true" rather than "1".
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    out[key] = number.boolValue ? "true" : "false"
                } else if number.doubleValue.isFinite {
                    out[key] = number.stringValue
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Persisted form (UserDefaults): the link plus whether it was delivered.
    func storageDictionary(delivered: Bool) -> [String: Any] {
        var dict: [String: Any] = [
            "payload": payload,
            "source": source.rawValue,
            "delivered": delivered,
        ]
        if let clickId = clickId { dict["click_id"] = clickId }
        return dict
    }

    /// Inverse of ``storageDictionary(delivered:)``. `link` is nil when the
    /// record holds no usable link (a delivered flag can stand alone).
    static func fromStorage(_ dict: [String: Any]) -> (link: DeferredDeepLink?, delivered: Bool) {
        let delivered = dict["delivered"] as? Bool ?? false
        guard let payload = normalizePayload(dict["payload"]),
              let rawSource = dict["source"] as? String,
              let source = DeferredDeepLinkSource(rawValue: rawSource) else {
            return (nil, delivered)
        }
        let clickId = (dict["click_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (DeferredDeepLink(payload: payload, source: source, clickId: clickId), delivered)
    }
}
