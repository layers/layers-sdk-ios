import Foundation
import os.log
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// Tier 6 iOS performance integration via Apple's MetricKit framework.
///
/// On iOS 13+, the OS aggregates application performance metrics — launch time,
/// hang duration, disk write bytes, memory peak, CPU time, etc. — and delivers
/// them to subscribers roughly **once per day** (typically the morning after).
/// This module conforms to `MXMetricManagerSubscriber` and translates each
/// payload into `$performance` events.
///
/// **MetricKit is iOS-only** (and macOS 12+ via `MetricKit.framework`, but with
/// a different surface). On non-iOS platforms this module is a no-op — `attach`
/// returns immediately, no subscription is registered.
///
/// Custom traces: ``trace(name:_:)`` on `Layers` wraps a closure, measures
/// duration, and emits a `$performance_trace` event. That API is the
/// always-on counterpart to the OS-driven `$performance` reports.
///
/// **Default: ON** when `automaticPerformanceTrackingEnabled = true` (default),
/// however the OS only delivers payloads on real devices in production builds —
/// XCTest doesn't generate them. Tests focus on the payload→event mapping.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class MetricKitModule: NSObject, @unchecked Sendable {

    /// Closure-based emitter for unit tests.
    public typealias Emitter = (_ event: String, _ properties: [String: Any]) -> Void

    // MARK: - Properties

    private let lock = NSLock()
    private var emitter: Emitter?
    private var enabled = false

    /// Optional callback for crash diagnostics — set when an `ExceptionModule`
    /// is attached so MetricKit's `MXCrashDiagnostic` can be re-emitted there.
    private var diagnosticForwarder: ((_ payload: [String: Any]) -> Void)?

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "metric-kit")

    // MARK: - Init

    public override init() {
        super.init()
    }

    // MARK: - Attach / Detach

    /// Attach to the Layers singleton.
    func attach(sdk: Layers) {
        attach(emitter: { [weak sdk] event, props in
            _ = sdk?.track(event, properties: props)
        })
    }

    /// Attach with an explicit emitter — used by both production and tests.
    func attach(emitter: @escaping Emitter) {
        lock.lock()
        self.emitter = emitter
        enabled = true
        lock.unlock()

        #if canImport(MetricKit) && os(iOS)
        if #available(iOS 13.0, *) {
            MXMetricManager.shared.add(self)
        }
        #endif
    }

    /// Set a forwarder so MetricKit's crash diagnostics can flow into the
    /// `$exception` pipeline.
    func setDiagnosticForwarder(_ forwarder: @escaping ([String: Any]) -> Void) {
        lock.lock()
        diagnosticForwarder = forwarder
        lock.unlock()
    }

    func detach() {
        lock.lock()
        enabled = false
        emitter = nil
        diagnosticForwarder = nil
        lock.unlock()

        #if canImport(MetricKit) && os(iOS)
        if #available(iOS 13.0, *) {
            MXMetricManager.shared.remove(self)
        }
        #endif
    }

    // MARK: - Emit Helpers

    private func emit(_ event: String, properties: [String: Any]) {
        lock.lock()
        let isEnabled = enabled
        let e = emitter
        lock.unlock()
        guard isEnabled, let e = e else { return }
        e(event, properties)
    }

    // MARK: - MetricKit Payload → $performance Event

    #if canImport(MetricKit) && os(iOS)
    // Availability must not exceed the enclosing class (iOS 14) — iOS 13
    // here was a compile error on every iOS build (macOS CI never sees it).
    @available(iOS 14.0, *)
    func emitMetricPayload(_ payload: MXMetricPayload) {
        let props = Self.metricProperties(from: payload)
        emit("$performance", properties: props)
    }

    @available(iOS 14.0, *)
    func emitDiagnosticPayload(_ payload: MXDiagnosticPayload) {
        if let crashes = payload.crashDiagnostics {
            lock.lock()
            let forwarder = diagnosticForwarder
            lock.unlock()

            for crash in crashes {
                let props = Self.crashDiagnosticProperties(from: crash)
                if let forwarder = forwarder {
                    forwarder(props)
                } else {
                    emit("$exception", properties: props)
                }
            }
        }
        if let hangs = payload.hangDiagnostics {
            for hang in hangs {
                let props = Self.hangDiagnosticProperties(from: hang)
                emit("$performance", properties: props)
            }
        }
    }

    /// Extract the relevant fields from an `MXMetricPayload`. Static so unit
    /// tests can hand-roll a payload-shaped dictionary equivalent and assert
    /// on the mapping without instantiating MetricKit types (their initializers
    /// are not public).
    @available(iOS 14.0, *)
    static func metricProperties(from payload: MXMetricPayload) -> [String: Any] {
        var props: [String: Any] = [
            "metric_kind": "metric_payload",
            "begin_time": ISO8601DateFormatter().string(from: payload.timeStampBegin),
            "end_time": ISO8601DateFormatter().string(from: payload.timeStampEnd),
            "app_version": payload.latestApplicationVersion,
            "include_subprocess_metrics": payload.includesMultipleApplicationVersions,
        ]

        if let app = payload.applicationLaunchMetrics {
            props["launch_time_avg_ms"] = app.histogrammedTimeToFirstDraw.totalBucketCount
            props["resume_time_avg_ms"] = app.histogrammedApplicationResumeTime.totalBucketCount
        }
        if let resp = payload.applicationResponsivenessMetrics {
            props["hang_time_avg_ms"] = resp.histogrammedApplicationHangTime.totalBucketCount
        }
        if let cpu = payload.cpuMetrics {
            props["cpu_time_seconds"] = cpu.cumulativeCPUTime.value
        }
        if let mem = payload.memoryMetrics {
            props["peak_memory_bytes"] = mem.peakMemoryUsage.value
            props["avg_suspended_memory_bytes"] = mem.averageSuspendedMemory.averageMeasurement.value
        }
        if let disk = payload.diskIOMetrics {
            props["disk_writes_bytes"] = disk.cumulativeLogicalWrites.value
        }
        if let display = payload.displayMetrics, let lum = display.averagePixelLuminance {
            props["avg_pixel_luminance"] = lum.averageMeasurement.value
        }
        return props
    }

    @available(iOS 14.0, *)
    static func crashDiagnosticProperties(from crash: MXCrashDiagnostic) -> [String: Any] {
        var props: [String: Any] = [
            "exception_type": "MXCrashDiagnostic",
            "exception_message": "MetricKit crash diagnostic",
            "exception_handled": false,
            "metric_kind": "crash_diagnostic",
            "termination_reason": crash.terminationReason ?? "",
            "virtual_memory_region_info": crash.virtualMemoryRegionInfo ?? "",
        ]
        if let exType = crash.exceptionType {
            props["mach_exception_type"] = exType.intValue
        }
        if let signal = crash.signal {
            props["mach_signal"] = signal.intValue
        }
        if let exCode = crash.exceptionCode {
            props["exception_code"] = exCode.intValue
        }
        // Encode the stack tree as JSON (it's an Apple-private structure but
        // jsonRepresentation() is part of the public API).
        let json = crash.callStackTree.jsonRepresentation()
        props["call_stack_tree"] = String(data: json, encoding: .utf8) ?? ""
        return props
    }

    @available(iOS 14.0, *)
    static func hangDiagnosticProperties(from hang: MXHangDiagnostic) -> [String: Any] {
        var props: [String: Any] = [
            "metric_kind": "hang_diagnostic",
            "hang_duration_seconds": hang.hangDuration.value,
        ]
        let json = hang.callStackTree.jsonRepresentation()
        props["call_stack_tree"] = String(data: json, encoding: .utf8) ?? ""
        return props
    }
    #endif
}

// MARK: - MXMetricManagerSubscriber

#if canImport(MetricKit) && os(iOS)
@available(iOS 14.0, *)
extension MetricKitModule: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            emitMetricPayload(payload)
        }
    }

    @available(iOS 14.0, *)
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            emitDiagnosticPayload(payload)
        }
    }
}
#endif
