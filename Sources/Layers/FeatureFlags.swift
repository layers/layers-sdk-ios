import Foundation
import os.log

// MARK: - FeatureFlagValue

/// The value of a single feature flag.
///
/// Flags are either binary (`.boolean`) or multivariate (`.string`). Unknown
/// flags resolve to `nil` from `getFeatureFlag(_:)`. The Rust core handles
/// SHA-1-based deterministic bucketing — the wrapper just parses the wire
/// format that core emits.
public enum FeatureFlagValue: Sendable, Equatable {
    case boolean(Bool)
    case string(String)

    /// `true` for `.boolean(true)` or `.string` whose value is non-empty and
    /// not `"false"`. Matches PostHog's `isFeatureEnabled` semantics.
    public var isTruthy: Bool {
        switch self {
        case .boolean(let b): return b
        case .string(let s): return !s.isEmpty && s.lowercased() != "false"
        }
    }

    /// Unwrap to a `String`. Returns `"true"`/`"false"` for boolean flags.
    public var stringValue: String {
        switch self {
        case .boolean(let b): return b ? "true" : "false"
        case .string(let s): return s
        }
    }

    /// Decode from the JSON string format the Rust core returns. Returns `nil`
    /// for `"null"` or any value the parser doesn't recognize.
    static func parse(json: String) -> FeatureFlagValue? {
        if json == "true" { return .boolean(true) }
        if json == "false" { return .boolean(false) }
        if json == "null" || json.isEmpty { return nil }
        // Quoted string — strip outer quotes via a JSONDecoder pass so escape
        // sequences (`\"`, `\\`, `ÿ`) round-trip cleanly.
        if let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return .string(decoded)
        }
        return nil
    }

    /// Encode to the JSON value-shape Rust expects in `BootstrapData.featureFlags`.
    func toJSONFragment() -> String {
        switch self {
        case .boolean(let b): return b ? "true" : "false"
        case .string(let s):
            let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
            return String(data: data, encoding: .utf8) ?? "\"\""
        }
    }
}

// MARK: - BootstrapData

/// Server-side rendered seed data for the feature-flag engine.
///
/// Pass via `LayersConfig(featureFlagBootstrap: ...)` to populate the
/// flag cache before the first `/config` fetch returns. Critical for
/// cold-start UX where you can't wait for a network round-trip — pages
/// rendered server-side embed the seed and the SDK uses it on hydration.
///
/// Wire format (matches the Rust core's `BootstrapData`, which is serialized
/// as camelCase to match the JS-facing `WasmConfig.bootstrap` shape):
///
/// ```json
/// {
///   "featureFlags": {"new_checkout": true, "header_variant": "blue"},
///   "featureFlagPayloads": {"new_checkout": {"copy": "Try it!"}}
/// }
/// ```
public struct BootstrapData: Sendable {
    public let featureFlags: [String: FeatureFlagValue]

    /// Pre-encoded JSON payloads per flag. Stored as strings (rather than
    /// `[String: Any]`) because `Any` isn't `Sendable` — the convenience init
    /// accepts `[String: Any]` and encodes for you.
    public let featureFlagPayloadsJSON: [String: String]

    /// Convenience init accepting raw JSON-compatible payload values.
    /// Anything that JSONSerialization accepts works (NSDictionary, NSArray,
    /// NSNumber, NSString, NSNull). Non-encodable values are silently dropped.
    public init(
        featureFlags: [String: FeatureFlagValue] = [:],
        featureFlagPayloads: [String: Any] = [:]
    ) {
        self.featureFlags = featureFlags
        var encoded: [String: String] = [:]
        for (key, value) in featureFlagPayloads {
            guard JSONSerialization.isValidJSONObject([value]) || value is NSNull else { continue }
            // Wrap in array so primitives (NSNumber etc.) are accepted, then strip.
            if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
               let s = String(data: data, encoding: .utf8),
               s.count >= 2 {
                encoded[key] = String(s.dropFirst().dropLast()) // strip outer [ ]
            }
        }
        self.featureFlagPayloadsJSON = encoded
    }

    /// Direct init for when callers already have JSON strings (e.g. bootstrap
    /// embedded in an HTML page).
    public init(
        featureFlags: [String: FeatureFlagValue],
        featureFlagPayloadsJSON: [String: String]
    ) {
        self.featureFlags = featureFlags
        self.featureFlagPayloadsJSON = featureFlagPayloadsJSON
    }

    /// Serialize to the JSON string the Rust core's
    /// `setFeatureFlagBootstrap(bootstrapJson:)` accepts.
    func toJSONString() -> String {
        var flagFragments: [String] = []
        for (key, value) in featureFlags.sorted(by: { $0.key < $1.key }) {
            let encodedKey = encodeJSONString(key)
            flagFragments.append("\(encodedKey):\(value.toJSONFragment())")
        }

        var payloadFragments: [String] = []
        for (key, jsonValue) in featureFlagPayloadsJSON.sorted(by: { $0.key < $1.key }) {
            let encodedKey = encodeJSONString(key)
            payloadFragments.append("\(encodedKey):\(jsonValue)")
        }

        let flags = "{\(flagFragments.joined(separator: ","))}"
        let payloads = "{\(payloadFragments.joined(separator: ","))}"
        return "{\"featureFlags\":\(flags),\"featureFlagPayloads\":\(payloads)}"
    }

    private func encodeJSONString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

// MARK: - Feature Flag Listener Token

/// Cancellation handle for a feature-flag listener registered via
/// `onFeatureFlags(_:)`. Calling `cancel()` removes the listener so it stops
/// firing. Idempotent.
public final class FeatureFlagListenerToken: @unchecked Sendable {
    private let cancelClosure: () -> Void
    private let cancelled = NSLock()
    private var didCancel = false

    init(_ cancelClosure: @escaping () -> Void) {
        self.cancelClosure = cancelClosure
    }

    public func cancel() {
        cancelled.lock()
        let alreadyCancelled = didCancel
        didCancel = true
        cancelled.unlock()
        if !alreadyCancelled {
            cancelClosure()
        }
    }
}
