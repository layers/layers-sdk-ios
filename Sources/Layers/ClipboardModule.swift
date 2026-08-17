import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Reads clipboard for Layers attribution URL on first launch.
/// iOS 16+ will show a paste consent dialog automatically when UIPasteboard is read.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class ClipboardModule: @unchecked Sendable {

    /// What a single system-pasteboard read produced. Raw values are the wire
    /// strings reported on `app_open` / `app_install` as `clipboard_read_outcome`.
    ///
    /// `attempted` outcomes (`match`, `noMatch`, `empty`) are the denominator of
    /// the clipboard read-rate metric; `match` is the numerator. The remaining
    /// outcomes never touch the pasteboard and are excluded from both.
    public enum ReadOutcome: String {
        /// A Layers click URL was found on the pasteboard.
        case match
        /// The pasteboard held text, but no Layers click URL.
        case noMatch = "no_match"
        /// The pasteboard was read and held no text.
        case empty
        /// Remote config `clipboard_attribution_enabled` is false — no read.
        case disabled
        /// This build has no pasteboard the SDK reads (every non-iOS platform).
        case unavailable
        /// The pasteboard was already read earlier in this process; the earlier
        /// result is returned without reading again.
        case cached
    }

    /// Outcome of one `check()` call, plus whatever attribution data it found.
    public struct CheckResult {
        /// Full clipboard contents, set only when a Layers click URL was found.
        public let url: String?
        /// Click ID extracted from the URL — the segment after `/c/`.
        public let clickId: String?
        /// What the read produced.
        public let outcome: ReadOutcome
        /// True when this call actually read the system pasteboard. This is the
        /// read-rate denominator: a launch that never touched the pasteboard
        /// (feature disabled, non-iOS, already read) is not a failed read.
        public let attempted: Bool

        static let unavailable = CheckResult(
            url: nil, clickId: nil, outcome: .unavailable, attempted: false
        )
    }

    /// What one system-pasteboard read returned. Distinguishes "this platform
    /// has no pasteboard" from "the pasteboard is empty" so the two land on
    /// different telemetry outcomes.
    enum PasteboardRead {
        /// No pasteboard is read on this platform.
        case unavailable
        /// The pasteboard was read; payload is its contents (`nil` = no text).
        case text(String?)
    }

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "ClipboardModule")

    /// Layers click URL pattern. Byte-for-byte the pattern used by every other
    /// platform wrapper — Kotlin `ClipboardAttribution.CLICK_URL_PATTERN`,
    /// Flutter `clipboard_attribution.dart`, Unity `ClipboardAttribution.cs`,
    /// `@layers/react-native`, and `@layers/client`. Capture group 2 is the
    /// click ID. Keep the five in lockstep — a divergence here silently changes
    /// which installs get attributed on one platform only.
    static let clickUrlPattern = "https?://(in\\.layers\\.com|link\\.layers\\.com)/c/([^?\\s]+)"

    private static let clickUrlRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: clickUrlPattern)
    }()

    /// How long a caller waits for an in-flight read before giving up on it.
    ///
    /// The read returns in microseconds unless iOS 16+ puts up its paste-consent
    /// dialog, which is user-paced. So the wait is bounded rather than
    /// indefinite: no caller — the main thread included — is ever parked behind
    /// another thread's dialog for longer than this.
    static let defaultInFlightWaitTimeout: TimeInterval = 2.0

    private let condition = NSCondition()
    private var _hasChecked = false
    private var _readInFlight = false
    private var _cachedResult: CheckResult?
    private let pasteboardReader: () -> PasteboardRead
    private let inFlightWaitTimeout: TimeInterval

    init() {
        self.pasteboardReader = ClipboardModule.readSystemPasteboard
        self.inFlightWaitTimeout = ClipboardModule.defaultInFlightWaitTimeout
    }

    /// Test seam: inject the pasteboard read so the parsing and telemetry paths
    /// can be exercised on hosts with no `UIPasteboard` (`swift test` runs on macOS).
    init(
        pasteboardReader: @escaping () -> PasteboardRead,
        inFlightWaitTimeout: TimeInterval = ClipboardModule.defaultInFlightWaitTimeout
    ) {
        self.pasteboardReader = pasteboardReader
        self.inFlightWaitTimeout = inFlightWaitTimeout
    }

    /// Check the clipboard for a Layers attribution URL and report what happened.
    /// Only reads once per process — subsequent calls return the cached result
    /// with outcome `.cached`.
    ///
    /// Single-flight: a caller that arrives while another thread's read is still
    /// running waits for that read's answer instead of reporting a false
    /// "nothing on the clipboard", which would silently drop the attribution.
    public func check() -> CheckResult {
        condition.lock()
        // Wait out an in-flight read so the answer below is the real one.
        // Bounded by one absolute deadline, computed before the loop so that
        // repeated wakeups cannot extend the wait — on timeout we fall through
        // and report whatever is cached, which is the old behavior and still
        // never triggers a second read.
        let deadline = Date().addingTimeInterval(inFlightWaitTimeout)
        while _readInFlight {
            if !condition.wait(until: deadline) {
                break
            }
        }
        if _hasChecked {
            let cached = _cachedResult
            condition.unlock()
            return CheckResult(
                url: cached?.url,
                clickId: cached?.clickId,
                outcome: .cached,
                attempted: false
            )
        }
        // Claim the single read BEFORE releasing the lock. A concurrent caller
        // must never trigger a second pasteboard read — on iOS 16+ that is a
        // second system paste-consent banner shown to the user.
        _hasChecked = true
        _readInFlight = true
        condition.unlock()

        let result = Self.evaluate(pasteboardReader())

        condition.lock()
        _cachedResult = result
        _readInFlight = false
        condition.broadcast()
        condition.unlock()

        switch result.outcome {
        case .match:
            os_log(
                "Clipboard attribution URL found: %{public}@",
                log: Self.log, type: .debug, result.url ?? ""
            )
        default:
            os_log(
                "No Layers attribution URL on clipboard (%{public}@)",
                log: Self.log, type: .debug, result.outcome.rawValue
            )
        }

        return result
    }

    /// Check clipboard for a Layers attribution URL.
    /// Returns the URL string if found, nil otherwise.
    /// Only reads once — subsequent calls return the cached result.
    public func checkClipboard() -> String? {
        return check().url
    }

    /// The clipboard properties for this launch's `app_open` / `app_install`.
    ///
    /// `enabled` is the remote-config `clipboard_attribution_enabled` gate; when
    /// it is false the pasteboard is never read and the launch is reported as
    /// `disabled` rather than silently omitted. Read telemetry is always
    /// present so the read-rate metric has a denominator.
    ///
    /// `clipboard_attribution_url` + `clipboard_click_id` are the same two keys
    /// Kotlin, Flutter, Unity, and React Native put on `app_open`.
    func attributionProperties(enabled: Bool) -> [String: Any] {
        guard enabled else {
            return [
                "clipboard_read_attempted": false,
                "clipboard_read_outcome": ReadOutcome.disabled.rawValue,
            ]
        }

        let result = check()
        var props: [String: Any] = [
            "clipboard_read_attempted": result.attempted,
            "clipboard_read_outcome": result.outcome.rawValue,
        ]
        if let url = result.url {
            props["clipboard_attribution_url"] = url
        }
        if let clickId = result.clickId {
            props["clipboard_click_id"] = clickId
        }
        return props
    }

    /// The cached URL, if previously checked. Does not trigger a new read,
    /// and does not wait for one that is in flight.
    public var cachedUrl: String? {
        condition.lock()
        defer { condition.unlock() }
        return _cachedResult?.url
    }

    /// The cached click ID, if a previous check found one. Does not trigger a
    /// new read, and does not wait for one that is in flight.
    public var cachedClickId: String? {
        condition.lock()
        defer { condition.unlock() }
        return _cachedResult?.clickId
    }

    // MARK: - Internal

    /// Extract the click ID (the segment after `/c/`) from a Layers click URL
    /// anywhere in `text`. Returns nil when `text` holds no Layers click URL.
    ///
    /// Matching is deliberately identical to the other platforms: the scheme is
    /// required, the host must be `in.layers.com` or `link.layers.com`, matching
    /// is case-sensitive, and the ID stops at the first `?` or whitespace.
    static func extractClickId(from text: String) -> String? {
        guard let regex = clickUrlRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 2,
              let idRange = Range(match.range(at: 2), in: text)
        else {
            return nil
        }
        let clickId = String(text[idRange])
        return clickId.isEmpty ? nil : clickId
    }

    /// Map one pasteboard read onto a `CheckResult`. Pure — the whole
    /// outcome/telemetry decision lives here so tests can drive every branch.
    static func evaluate(_ read: PasteboardRead) -> CheckResult {
        guard case let .text(content) = read else {
            return .unavailable
        }
        guard let content = content, !content.isEmpty else {
            return CheckResult(url: nil, clickId: nil, outcome: .empty, attempted: true)
        }
        guard let clickId = extractClickId(from: content) else {
            return CheckResult(url: nil, clickId: nil, outcome: .noMatch, attempted: true)
        }
        // The full clipboard contents are reported as the attribution URL, the
        // same value Flutter, Unity, React Native, and web report.
        return CheckResult(url: content, clickId: clickId, outcome: .match, attempted: true)
    }

    // MARK: - Private

    private static func readSystemPasteboard() -> PasteboardRead {
        #if os(iOS)
        return .text(UIPasteboard.general.string)
        #else
        return .unavailable
        #endif
    }
}
