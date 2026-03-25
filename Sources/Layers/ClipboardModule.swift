import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Reads clipboard for Layers attribution URL on first launch.
/// iOS 16+ will show a paste consent dialog automatically when UIPasteboard is read.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class ClipboardModule: @unchecked Sendable {

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "ClipboardModule")

    private let lock = NSLock()
    private var _cachedUrl: String?
    private var _hasChecked = false

    init() {}

    /// Check clipboard for a Layers attribution URL.
    /// Returns the URL string if found, nil otherwise.
    /// Only reads once — subsequent calls return the cached result.
    public func checkClipboard() -> String? {
        lock.lock()
        if _hasChecked {
            let cached = _cachedUrl
            lock.unlock()
            return cached
        }
        _hasChecked = true
        lock.unlock()

        let url = Self.readClipboard()

        lock.lock()
        _cachedUrl = url
        lock.unlock()

        if let url {
            os_log("Clipboard attribution URL found: %{public}@", log: Self.log, type: .debug, url)
        } else {
            os_log("No Layers attribution URL on clipboard", log: Self.log, type: .debug)
        }

        return url
    }

    /// The cached URL, if previously checked. Does not trigger a new read.
    public var cachedUrl: String? {
        lock.lock()
        defer { lock.unlock() }
        return _cachedUrl
    }

    // MARK: - Private

    private static func readClipboard() -> String? {
        #if os(iOS)
        guard let content = UIPasteboard.general.string else { return nil }
        guard content.contains("in.layers.com/c/") || content.contains("link.layers.com/c/") else { return nil }
        return content
        #else
        return nil
        #endif
    }
}
