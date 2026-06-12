import Foundation
import os.log
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Background flush support using BGAppRefreshTask.
///
/// Provides a safety-net mechanism for delivering queued events even when
/// the app is backgrounded before an in-process flush completes. This is
/// analogous to Android's WorkManager-based ``FlushWorker``.
///
/// The minimum interval for `BGAppRefreshTask` is 15 minutes (OS-enforced).
///
/// ## Setup
///
/// 1. Add `com.layers.sdk.background-flush` to your app's
///    `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.
///
/// 2. Call ``Layers/initialize(config:)`` — the SDK registers the
///    background task handler automatically. No additional calls needed.
///
/// If the plist entry is absent, background flushes are silently disabled
/// and the app continues to work with foreground-only event delivery.
///
public enum BackgroundFlushTask {

    /// The BGTaskScheduler task identifier.
    /// Must be listed in Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    public static let taskIdentifier = "com.layers.sdk.background-flush"

    /// Minimum interval between background flush attempts (15 minutes).
    /// This is the minimum allowed by the OS for BGAppRefreshTask.
    private static let minimumInterval: TimeInterval = 15 * 60

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "BackgroundFlush")

    /// Guards against double-registration (Apple throws if you register the same identifier twice).
    private static let lock = NSLock()
    private static var _registered = false

    /// Register the background flush task with the system.
    ///
    /// The SDK calls this automatically during ``Layers/initialize(config:)``,
    /// so most apps do **not** need to call it directly. If you want the earliest
    /// possible registration in a SwiftUI app, you may call this from your
    /// `@main App.init()` — repeated calls are safe (no-ops).
    ///
    /// If `BGTaskSchedulerPermittedIdentifiers` in Info.plist does not contain
    /// the task identifier, registration is silently skipped and background
    /// flushes are disabled. The app will **never** crash due to a missing
    /// plist entry.
    ///
    /// - Returns: `true` if registration succeeded (or was already registered).
    ///
    /// This method is safe to call on all platforms. On macOS, tvOS, watchOS,
    /// or iOS < 13, it is a no-op that returns `false`.
    @available(*, deprecated, message: "No longer needed — Layers.initialize() registers automatically. Remove this call.")
    @discardableResult
    public static func registerBackgroundFlush() -> Bool {
        return _registerIfNeeded()
    }

    /// Internal entry point called by ``Layers/initialize(config:)``.
    @discardableResult
    internal static func _registerIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !_registered else { return true }

        #if canImport(BackgroundTasks) && os(iOS)
        if #available(iOS 13.0, *) {
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: taskIdentifier,
                using: nil
            ) { task in
                handleBackgroundTask(task)
            }
            if registered {
                _registered = true
                os_log("Registered background flush task: %{public}@",
                       log: log, type: .info, taskIdentifier)
                return true
            } else {
                os_log("Background flush skipped — '%{public}@' not in Info.plist BGTaskSchedulerPermittedIdentifiers. Add it to enable background event delivery.",
                       log: log, type: .info, taskIdentifier)
                return false
            }
        }
        #endif
        return false
    }

    /// Schedule the next background flush execution.
    ///
    /// Call this after initialization or when you want to ensure a flush
    /// is scheduled. It is safe to call multiple times — the system
    /// deduplicates requests for the same task identifier.
    ///
    /// This method is a no-op on platforms that don't support BGAppRefreshTask.
    public static func scheduleBackgroundFlush() {
        #if canImport(BackgroundTasks) && os(iOS)
        if #available(iOS 13.0, *) {
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)

            do {
                try BGTaskScheduler.shared.submit(request)
                os_log("Scheduled background flush (earliest in %.0f min)",
                       log: log, type: .debug, minimumInterval / 60)
            } catch {
                os_log("Failed to schedule background flush: %{public}@",
                       log: log, type: .error, error.localizedDescription)
            }
        }
        #endif
    }

    // MARK: - Private

    #if canImport(BackgroundTasks) && os(iOS)
    @available(iOS 14.0, *)
    private static func handleBackgroundTask(_ task: BGTask) {
        // Schedule the next execution before we start work
        scheduleBackgroundFlush()

        // Set up expiration handler
        task.expirationHandler = {
            os_log("Background flush task expired", log: log, type: .info)
            task.setTaskCompleted(success: false)
        }

        os_log("Background flush task started", log: log, type: .debug)

        // Flush queued events via the shared Layers instance
        let result = Layers.shared.flushBlocking()
        switch result {
        case .success:
            os_log("Background flush completed successfully", log: log, type: .debug)
            task.setTaskCompleted(success: true)
        case .failure(let error):
            os_log("Background flush failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            task.setTaskCompleted(success: false)
        }
    }
    #endif
}
