import Foundation
import Darwin
import os.log

/// Tier 5 iOS exception + crash auto-capture.
///
/// Two ingestion paths:
///
/// 1. **Obj-C uncaught exceptions** via `NSSetUncaughtExceptionHandler`. Runs in
///    a normal Foundation context, so we can capture `callStackSymbols`,
///    `callStackReturnAddresses`, `name`, and `reason`. On by default through
///    `LayersConfig.automaticExceptionTrackingEnabled`.
/// 2. **POSIX signals** (`SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGFPE`, `SIGILL`,
///    `SIGTRAP`) via `signal()`. Opt-in through
///    `LayersConfig.signalCrashCaptureEnabled`. The handler collects
///    `backtrace()` addresses, writes a minimal record with POSIX `write()` to a
///    path resolved at install time, chains to the handler that was installed
///    before it, and then always hands the signal to the default action so the
///    OS still produces its crash log. The handler is not yet async-signal-safe:
///    it allocates while formatting the record, so a crash that already holds
///    the malloc lock (heap corruption) can deadlock inside it instead of
///    crashing. That is why it stays off until it is rewritten with
///    pre-allocated buffers.
///
/// Crash records persist to `<persistenceDir>/layers-pending-crash.json`.
/// On the **next** launch, `flushPendingCrashes` reads, deletes, and emits an
/// `$exception` event with `$exception_handled = false`,
/// `$exception_fatal = true`, and `$exception_occurred_at` taken from the
/// record, so the crash keeps its own time rather than the next launch's.
///
/// Property names follow the canonical `$exception_*` set every other platform
/// emits (`docs/internal/tier-5-server-handoff.md`). The ingest service
/// rejects an `$exception` that lacks `$exception_type` or
/// `$exception_message`, and a rejected batch is dropped whole, so a record
/// missing either is discarded here instead of emitted.
///
/// **Symbolication is server-side.** We emit raw return addresses so a
/// server-side dSYM resolver can produce human-readable stacks.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class ExceptionModule: @unchecked Sendable {

    // MARK: - Constants

    public static let pendingCrashFilename = "layers-pending-crash.json"

    /// Fatal signals the opt-in signal capture traps. `SIGPIPE` is absent on
    /// purpose: networking stacks ignore it process-wide, and a handler that
    /// re-raises it would turn a write to a closed socket into an app kill.
    static let trappedSignals: [Int32] = [
        SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP,
    ]

    /// Caps that keep one crash from producing a payload the ingest rejects.
    static let maxMessageChars = 4_000
    static let maxStackTraceChars = 10_000
    static let maxReturnAddresses = 64
    static let maxUserInfoChars = 1_000

    /// Closure-based emitter used for unit tests and the production wiring.
    public typealias Emitter = (_ event: String, _ properties: [String: Any]) -> Void

    // MARK: - Static State (signal handlers can't capture instance state)

    /// C string for the crash file path. Resolved on the first install and
    /// never reassigned while handlers are installed: the signal handler
    /// holds a pointer into this buffer.
    private static var crashFilePathCString: [CChar] = []

    /// `true` once the NSException handler is installed.
    private static var handlersInstalled = false
    /// `true` once the (opt-in) signal handlers are installed.
    private static var signalHandlersInstalled = false
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
    private var automaticCaptureEnabled = false

    /// Directory provided at attach time. Internal so tests can verify.
    var attachedPersistenceDir: String?

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "exception")

    // MARK: - Init

    public init() {}

    // MARK: - Attach / Detach

    /// Attach to the Layers singleton. Production entry point.
    ///
    /// The emitter is always wired, so `captureException` works whatever the
    /// flags say. The process-wide handlers and the pending-crash drain follow
    /// `automaticCapture`; the signal handlers additionally need
    /// `captureSignals`.
    func attach(
        sdk: Layers,
        persistenceDir: String,
        automaticCapture: Bool = true,
        captureSignals: Bool = false
    ) {
        attach(
            emitter: { [weak sdk] event, props in
                _ = sdk?.track(event, properties: props)
            },
            persistenceDir: persistenceDir,
            automaticCapture: automaticCapture,
            captureSignals: captureSignals
        )
    }

    /// Attach with an explicit emitter — used by both production and tests.
    /// `persistenceDir` is where the pending-crash file lives between launches.
    func attach(
        emitter: @escaping Emitter,
        persistenceDir: String,
        automaticCapture: Bool = true,
        captureSignals: Bool = false
    ) {
        lock.lock()
        self.emitter = emitter
        attachedPersistenceDir = persistenceDir
        enabled = true
        automaticCaptureEnabled = automaticCapture
        lock.unlock()

        Self.setActive(self)
        guard automaticCapture else { return }
        Self.installHandlers(persistenceDir: persistenceDir, captureSignals: captureSignals)
        // Drain any pending crash from the previous launch.
        flushPendingCrashes(persistenceDir: persistenceDir)
    }

    func detach() {
        lock.lock()
        enabled = false
        automaticCaptureEnabled = false
        emitter = nil
        attachedPersistenceDir = nil
        lock.unlock()
        // The C handlers stay installed: uninstalling signal handlers mid-run
        // risks losing crash data, and the SDK is normally process-lifetime.
        // They keep writing the record for the next launch to drain; nothing
        // is emitted from a detached instance, and the active reference is
        // cleared so no handler can reach it.
        Self.setActive(nil)
    }

    /// Whether `attach` has run and `detach` has not. Internal so the wiring
    /// tests can assert what `Layers.initialize` did.
    var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Whether this attach installed the process-wide handlers and drained
    /// the pending crash, as opposed to wiring the emitter alone.
    var isAutomaticCaptureEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return automaticCaptureEnabled
    }

    // MARK: - Active Singleton (for handlers to find)

    private static let activeLock = NSLock()
    private static var _active: ExceptionModule?

    static var active: ExceptionModule? {
        activeLock.lock()
        defer { activeLock.unlock() }
        return _active
    }

    private static func setActive(_ module: ExceptionModule?) {
        activeLock.lock()
        _active = module
        activeLock.unlock()
    }

    // MARK: - Handler Installation

    static func installHandlers(persistenceDir: String, captureSignals: Bool = false) {
        installLock.lock()
        defer { installLock.unlock() }

        if !handlersInstalled {
            // Resolved once. Re-attaching with another directory keeps the
            // first path: the signal handler may hold a pointer into it.
            let path = (persistenceDir as NSString).appendingPathComponent(pendingCrashFilename)
            crashFilePathCString = path.utf8CString.map { CChar($0) }
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
        }

        // 2) Signal handlers (opt-in)
        if captureSignals && !signalHandlersInstalled {
            signalHandlersInstalled = true
            for sig in trappedSignals {
                let prior = signal(sig, ExceptionModule.handleSignal)
                // sig_t (a `@convention(c)` function pointer) is not Equatable, so
                // we go through an unsafe bit-pattern compare to filter out
                // SIG_DFL (NULL), SIG_IGN, and SIG_ERR.
                if let prior = prior, isChainable(prior) {
                    previousSignalHandlers[sig] = prior
                }
            }
        }
    }

    /// `true` when `handler` is a real function we can chain to: not `SIG_DFL`,
    /// `SIG_IGN`, or the `SIG_ERR` that `signal()` returns on failure, which
    /// must never be called as a function pointer.
    static func isChainable(_ handler: sig_t) -> Bool {
        let raw = unsafeBitCast(handler, to: UnsafeRawPointer.self)
        let dfl = unsafeBitCast(SIG_DFL, to: UnsafeRawPointer?.self)
        let ign = unsafeBitCast(SIG_IGN, to: UnsafeRawPointer.self)
        let err = unsafeBitCast(SIG_ERR, to: UnsafeRawPointer.self)
        if let dfl = dfl, raw == dfl { return false }
        if raw == ign { return false }
        if raw == err { return false }
        return true
    }

    // MARK: - NSException Handler

    fileprivate static func handleNSException(_ exception: NSException) {
        // Snapshot the relevant data before we forward to a chained handler.
        let addresses = exception.callStackReturnAddresses
            .prefix(maxReturnAddresses)
            .map { $0.stringValue }
        let report: [String: Any] = [
            "$exception_source": "nsexception",
            "$exception_type": exception.name.rawValue,
            "$exception_message": truncate(exception.reason ?? "", to: maxMessageChars),
            "$exception_stack_trace_raw": truncate(
                exception.callStackSymbols.joined(separator: "\n"),
                to: maxStackTraceChars
            ),
            "$exception_return_addresses": Array(addresses),
            "$exception_handled": false,
            "$exception_fatal": true,
            "$exception_occurred_at": iso8601(Date()),
            "$exception_user_info": truncate(exception.userInfo?.description ?? "", to: maxUserInfoChars),
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
    /// Not yet async-signal-safe (see the type doc); installed only when the
    /// host opts in.
    private static let handleSignal: sig_t = { sig in
        // Capture backtrace addresses (async-signal-safe per Darwin docs).
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: maxReturnAddresses)
        let count = backtrace(&addresses, Int32(maxReturnAddresses))

        writeSignalCrashRecord(signal: sig, addresses: addresses, count: count)

        // Chain to the handler that was installed before us, then always hand
        // the signal to the default action. A chained handler that returns
        // (Crashlytics and Sentry do, on several paths) would otherwise resume
        // the faulting instruction and fault again forever.
        if let prior = previousSignalHandlers[sig], isChainable(prior) {
            prior(sig)
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// Writer for the signal path. Hand-rolled JSON because Foundation is not
    /// safe here; `write()` and `time()` are async-signal-safe.
    private static func writeSignalCrashRecord(
        signal sig: Int32,
        addresses: [UnsafeMutableRawPointer?],
        count: Int32
    ) {
        // Buffer big enough for header + 64 addresses formatted as 0x...
        let bufferSize = 4096
        var buffer = [CChar](repeating: 0, count: bufferSize)
        var offset = 0

        let header = "{\"$exception_source\":\"signal\",\"$exception_signal\":\(sig),\"$exception_occurred_at_epoch\":"
        offset = appendCString(header, into: &buffer, offset: offset)

        var ts: time_t = 0
        time(&ts)
        offset = appendCString(String(ts), into: &buffer, offset: offset)

        offset = appendCString(
            ",\"$exception_handled\":false,\"$exception_fatal\":true,\"$exception_return_addresses\":[",
            into: &buffer,
            offset: offset
        )

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
    /// in analytics. Works whenever the module is attached, including with
    /// `automaticExceptionTrackingEnabled: false`.
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
        props["$exception_type"] = String(describing: type(of: error))
        props["$exception_message"] = Self.truncate(ns.localizedDescription, to: Self.maxMessageChars)
        props["$exception_handled"] = handled
        props["$exception_fatal"] = false
        props["$exception_error_domain"] = ns.domain
        props["$exception_error_code"] = ns.code
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
        if (raw["$exception_source"] as? String) == "signal" {
            let sigInt: Int?
            if let s = raw["$exception_signal"] as? Int { sigInt = s }
            else if let s = raw["$exception_signal"] as? Int32 { sigInt = Int(s) }
            else if let s = raw["$exception_signal"] as? NSNumber { sigInt = s.intValue }
            else { sigInt = nil }
            if let sig = sigInt {
                let sigName = signalName(Int32(sig))
                props["$exception_type"] = sigName
                props["$exception_message"] = "Crashed on \(sigName) (\(sig))"
            }
            if let epoch = raw["$exception_occurred_at_epoch"] as? NSNumber {
                props["$exception_occurred_at"] = Self.iso8601(Date(timeIntervalSince1970: epoch.doubleValue))
                props.removeValue(forKey: "$exception_occurred_at_epoch")
            }
        }
        props["$exception_handled"] = false
        props["$exception_fatal"] = true

        // The ingest rejects an $exception without a type and a message, and
        // drops the whole batch with it; a partial record is not worth that.
        guard props["$exception_type"] is String, props["$exception_message"] is String else {
            os_log("Discarding pending crash report without a type and message", log: Self.log, type: .error)
            return
        }
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

    static func truncate(_ s: String, to max: Int) -> String {
        s.count > max ? String(s.prefix(max)) : s
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    // MARK: - Test Helpers

    /// Internal hook that stamps the active reference. Tests call this so the
    /// signal handler path can find the module without going through full attach.
    static func _setActiveForTesting(_ module: ExceptionModule?) {
        setActive(module)
    }

    /// Reset all install state. Tests use this so a second `installHandlers`
    /// call actually re-runs.
    static func _resetInstallStateForTesting() {
        installLock.lock()
        handlersInstalled = false
        signalHandlersInstalled = false
        previousNSExceptionHandler = nil
        previousSignalHandlers.removeAll()
        crashFilePathCString = []
        installLock.unlock()
    }
}
