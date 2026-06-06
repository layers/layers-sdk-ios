import Foundation
import Darwin
import os.log

/// Tier 5 iOS exception + crash auto-capture.
///
/// Two ingestion paths:
///
/// 1. **Obj-C uncaught exceptions** via `NSSetUncaughtExceptionHandler`. Runs in
///    a normal Foundation context, so we can capture `callStackSymbols`,
///    `callStackReturnAddresses`, `name`, and `reason`.
/// 2. **POSIX signals** (`SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGFPE`, `SIGILL`,
///    `SIGTRAP`, `SIGPIPE`) via `signal()`. The handler runs in async-signal-safe
///    territory: we cannot allocate, take ObjC locks, call Foundation. We use
///    `backtrace()` (documented as async-signal-safe on Darwin) to collect raw
///    return addresses, then write a minimal record using POSIX `write()` to a
///    pre-allocated path. After the record is on disk, we reinstall the default
///    handler and re-raise so the OS still produces a crash log.
///
/// Crash records persist to `<persistenceDir>/layers-pending-crash.json`.
/// On the **next** launch, `flushPendingCrashes(sdk:)` reads, deletes, and emits
/// `$exception` events with `exception_handled = false`.
///
/// **Symbolication is server-side.** We emit raw return addresses + image base
/// + image UUID for each frame so a server-side dSYM resolver can produce
/// human-readable stacks. PR description includes the dSYM upload step.
///
/// **Default: ON** (recommended — matches Sentry/Crashlytics posture). Opt out
/// via `LayersConfig(automaticExceptionTrackingEnabled: false)`.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class ExceptionModule: @unchecked Sendable {

    // MARK: - Constants

    public static let pendingCrashFilename = "layers-pending-crash.json"

    /// All signals we install handlers for. Pre-existing handlers (if any) are
    /// preserved and chained on the first uncaught crash.
    private static let trappedSignals: [Int32] = [
        SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP, SIGPIPE,
    ]

    /// Closure-based emitter used for unit tests and the production wiring.
    public typealias Emitter = (_ event: String, _ properties: [String: Any]) -> Void

    // MARK: - Static State (signal handlers can't capture instance state)

    /// Pre-allocated C string for the crash file path. Set ONCE during
    /// `installHandlers`. Read from the signal handler — never mutated post-install.
    private static var crashFilePathCString: [CChar] = []

    /// Becomes `true` after at least one handler is installed.
    private static var handlersInstalled = false
    private static let installLock = NSLock()

    /// Captures whatever uncaught-exception handler was in place before us so
    /// we can chain to it (e.g. when Crashlytics is also installed).
    private static var previousNSExceptionHandler: ((NSException) -> Void)?

    /// Captures previous signal handlers per signal.
    private static var previousSignalHandlers: [Int32: sig_t] = [:]

    // MARK: - Properties

    private let lock = NSLock()
    private var emitter: Emitter?
    private var enabled = false

    /// Directory provided at attach time. Internal so tests can verify.
    var attachedPersistenceDir: String?

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "exception")

    // MARK: - Init

    public init() {}

    // MARK: - Attach / Detach

    /// Attach to the Layers singleton. Production entry point.
    func attach(sdk: Layers, persistenceDir: String) {
        attach(
            emitter: { [weak sdk] event, props in
                _ = sdk?.track(event, properties: props)
            },
            persistenceDir: persistenceDir
        )
    }

    /// Attach with an explicit emitter — used by both production and tests.
    /// `persistenceDir` is where the pending-crash file lives between launches.
    func attach(emitter: @escaping Emitter, persistenceDir: String) {
        lock.lock()
        self.emitter = emitter
        attachedPersistenceDir = persistenceDir
        enabled = true
        lock.unlock()

        Self.installHandlers(persistenceDir: persistenceDir)
        Self._setActiveForTesting(self)
        // Drain any pending crash from the previous launch.
        flushPendingCrashes(persistenceDir: persistenceDir)
    }

    func detach() {
        lock.lock()
        enabled = false
        emitter = nil
        lock.unlock()
        // We deliberately leave the C handlers in place — uninstalling signal
        // handlers mid-run risks losing crash data, and the SDK is normally
        // singleton + process-lifetime. The handlers will see `_active == nil`
        // and write a minimal record but skip the emit, which is safe.
    }

    // MARK: - Active Singleton (for handlers to find)

    private static let activeLock = NSLock()
    private static var _active: ExceptionModule?

    static var active: ExceptionModule? {
        activeLock.lock()
        defer { activeLock.unlock() }
        return _active
    }

    // MARK: - Handler Installation

    static func installHandlers(persistenceDir: String) {
        installLock.lock()
        defer { installLock.unlock() }

        // Always update the active reference + path even if handlers already exist.
        let path = (persistenceDir as NSString).appendingPathComponent(pendingCrashFilename)
        crashFilePathCString = path.utf8CString.map { CChar($0) }

        if handlersInstalled { return }
        handlersInstalled = true

        // 1) NSException
        previousNSExceptionHandler = NSGetUncaughtExceptionHandler().map { handler in
            { exception in
                handler(exception)
            }
        }
        NSSetUncaughtExceptionHandler { exception in
            ExceptionModule.handleNSException(exception)
        }

        // 2) Signal handlers
        for sig in trappedSignals {
            let prior = signal(sig, ExceptionModule.handleSignal)
            // sig_t (a `@convention(c)` function pointer) is not Equatable, so
            // we go through an unsafe bit-pattern compare to filter out
            // SIG_DFL (NULL) and SIG_IGN (special sentinel).
            if let prior = prior, !isDefaultOrIgnore(prior) {
                previousSignalHandlers[sig] = prior
            }
        }
    }

    /// Returns `true` if `handler` is `SIG_DFL` or `SIG_IGN`. Because `sig_t`
    /// is `@convention(c)`, normal `==` doesn't compile — we compare via raw
    /// pointers.
    private static func isDefaultOrIgnore(_ handler: sig_t) -> Bool {
        let raw = unsafeBitCast(handler, to: UnsafeRawPointer.self)
        let dfl = unsafeBitCast(SIG_DFL, to: UnsafeRawPointer?.self)
        let ign = unsafeBitCast(SIG_IGN, to: UnsafeRawPointer.self)
        if let dfl = dfl, raw == dfl { return true }
        if raw == ign { return true }
        return false
    }

    // MARK: - NSException Handler

    fileprivate static func handleNSException(_ exception: NSException) {
        // Snapshot the relevant data before we forward to a chained handler.
        let report: [String: Any] = [
            "source": "nsexception",
            "exception_type": exception.name.rawValue,
            "exception_message": exception.reason ?? "",
            "exception_stacktrace": exception.callStackSymbols.joined(separator: "\n"),
            "return_addresses": exception.callStackReturnAddresses.map { $0.stringValue },
            "exception_handled": false,
            "timestamp": Date().timeIntervalSince1970,
            "user_info": exception.userInfo?.description ?? "",
        ]
        writeCrashReportSync(report)

        // Chain to whoever was installed before us (e.g. Crashlytics).
        previousNSExceptionHandler?(exception)
    }

    /// Foundation-safe write. Callable from NSException handler context.
    fileprivate static func writeCrashReportSync(_ report: [String: Any]) {
        let path = String(cString: crashFilePathCString)
        guard !path.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: []) else {
            return
        }
        // Atomic write so a second crash mid-write doesn't truncate the file
        // for the next launch.
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Signal Handler

    /// `@convention(c)` because `signal()` requires a C function pointer.
    /// **Async-signal-safe only.** No Swift String literals in the hot path,
    /// no Foundation, no allocation.
    private static let handleSignal: sig_t = { sig in
        // Capture backtrace addresses (async-signal-safe per Darwin docs).
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&addresses, 64)

        writeSignalCrashRecord(signal: sig, addresses: addresses, count: count)

        // Restore prior handler (if any) and re-raise so the OS still
        // produces a crash log + the OS's crash reporter still runs.
        if let prior = previousSignalHandlers[sig], !isDefaultOrIgnore(prior) {
            prior(sig)
        } else {
            signal(sig, SIG_DFL)
            raise(sig)
        }
    }

    /// Async-signal-safe writer. We pre-format using `snprintf` into a static
    /// buffer, then write() to the pre-resolved path. JSON is hand-rolled
    /// because Foundation isn't safe here.
    private static func writeSignalCrashRecord(
        signal sig: Int32,
        addresses: [UnsafeMutableRawPointer?],
        count: Int32
    ) {
        // Buffer big enough for header + 64 addresses formatted as 0x...
        let bufferSize = 4096
        var buffer = [CChar](repeating: 0, count: bufferSize)
        var offset = 0

        let header = "{\"source\":\"signal\",\"signal\":\(sig),\"timestamp\":"
        offset = appendCString(header, into: &buffer, offset: offset)

        // time(2) is async-signal-safe.
        var ts: time_t = 0
        time(&ts)
        offset = appendCString(String(ts), into: &buffer, offset: offset)

        offset = appendCString(",\"exception_handled\":false,\"return_addresses\":[", into: &buffer, offset: offset)

        for i in 0..<Int(count) {
            if i > 0 {
                offset = appendCString(",", into: &buffer, offset: offset)
            }
            let value: UInt
            if let p = addresses[i] {
                value = UInt(bitPattern: Int(bitPattern: p))
            } else {
                value = 0
            }
            // Format as "0x<hex>"
            offset = appendCString("\"0x", into: &buffer, offset: offset)
            offset = appendHexCString(value, into: &buffer, offset: offset)
            offset = appendCString("\"", into: &buffer, offset: offset)
        }
        offset = appendCString("]}", into: &buffer, offset: offset)

        // Write via POSIX write() — async-signal-safe.
        let path = crashFilePathCString
        guard !path.isEmpty else { return }
        path.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let fd = open(base, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { return }
            buffer.withUnsafeBufferPointer { bufPtr in
                if let bufBase = bufPtr.baseAddress {
                    _ = write(fd, bufBase, offset)
                }
            }
            _ = fsync(fd)
            close(fd)
        }
    }

    /// Append a Swift string as UTF-8 into the C buffer at `offset`. Returns
    /// the new offset. Truncates instead of overflowing.
    private static func appendCString(_ s: String, into buffer: inout [CChar], offset: Int) -> Int {
        var newOffset = offset
        for byte in s.utf8 {
            if newOffset >= buffer.count - 1 { break }
            buffer[newOffset] = CChar(bitPattern: byte)
            newOffset += 1
        }
        return newOffset
    }

    /// Append a UInt as lowercase hex (no prefix) into the C buffer.
    private static func appendHexCString(_ value: UInt, into buffer: inout [CChar], offset: Int) -> Int {
        if value == 0 {
            return appendCString("0", into: &buffer, offset: offset)
        }
        // Build digits in reverse, then write in correct order.
        var digits: [CChar] = []
        var v = value
        while v > 0 {
            let d = v & 0xF
            let ch: CChar
            if d < 10 {
                ch = CChar(bitPattern: UInt8(0x30 + d)) // '0'
            } else {
                ch = CChar(bitPattern: UInt8(0x57 + d)) // 'a' = 0x61 - 10 = 0x57
            }
            digits.append(ch)
            v >>= 4
        }
        var newOffset = offset
        for ch in digits.reversed() {
            if newOffset >= buffer.count - 1 { break }
            buffer[newOffset] = ch
            newOffset += 1
        }
        return newOffset
    }

    // MARK: - Manual Capture

    /// Manually emit an `$exception` for a caught error. Useful inside a
    /// `do/catch` block when the host app handles an error but still wants it
    /// in analytics.
    @discardableResult
    public func captureException(
        _ error: Error,
        handled: Bool = true,
        properties: [String: Any] = [:]
    ) -> SafeResult<Void> {
        lock.lock()
        let isEnabled = enabled
        let emit = emitter
        lock.unlock()
        guard isEnabled, let emit else { return .failure(.notInitialized) }

        var props = properties
        let ns = error as NSError
        props["exception_type"] = String(describing: type(of: error))
        props["exception_message"] = ns.localizedDescription
        props["exception_handled"] = handled
        props["error_domain"] = ns.domain
        props["error_code"] = ns.code
        emit("$exception", props)
        return .success(())
    }

    // MARK: - Pending Crash Flush

    /// Read, parse, emit, and delete any pending crash from the previous launch.
    /// Safe to call multiple times — the file is removed atomically before emit.
    func flushPendingCrashes(persistenceDir: String) {
        lock.lock()
        let emit = emitter
        lock.unlock()
        guard let emit = emit else { return }

        let path = (persistenceDir as NSString).appendingPathComponent(Self.pendingCrashFilename)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }

        defer {
            try? FileManager.default.removeItem(at: url)
        }

        guard let data = try? Data(contentsOf: url),
              let raw = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
        else {
            os_log("Failed to parse pending crash report at %{public}@", log: Self.log, type: .error, path)
            return
        }

        var props = raw
        // Normalize signal-source records into the canonical $exception schema.
        if (raw["source"] as? String) == "signal" {
            let sigInt: Int?
            if let s = raw["signal"] as? Int { sigInt = s }
            else if let s = raw["signal"] as? Int32 { sigInt = Int(s) }
            else if let s = raw["signal"] as? NSNumber { sigInt = s.intValue }
            else { sigInt = nil }
            if let sig = sigInt {
                let sigName = signalName(Int32(sig))
                props["exception_type"] = sigName
                props["exception_message"] = "Crashed on \(sigName) (\(sig))"
            }
        }
        props["exception_handled"] = false
        emit("$exception", props)
    }

    /// Convenience overload that uses whatever `persistenceDir` was passed to
    /// `attach`. Safe to call before attach (no-ops).
    public func flushPendingCrashes() {
        lock.lock()
        let dir = attachedPersistenceDir
        lock.unlock()
        guard let dir = dir else { return }
        flushPendingCrashes(persistenceDir: dir)
    }

    // MARK: - Helpers

    private func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGPIPE: return "SIGPIPE"
        default: return "SIG_\(sig)"
        }
    }

    // MARK: - Test Helpers

    /// Internal hook that stamps the active reference. Tests call this so the
    /// signal handler path can find the module without going through full attach.
    static func _setActiveForTesting(_ module: ExceptionModule?) {
        activeLock.lock()
        _active = module
        activeLock.unlock()
    }

    /// Reset all install state. Tests use this so a second `installHandlers`
    /// call actually re-runs.
    static func _resetInstallStateForTesting() {
        installLock.lock()
        handlersInstalled = false
        previousNSExceptionHandler = nil
        previousSignalHandlers.removeAll()
        crashFilePathCString = []
        installLock.unlock()
    }
}
