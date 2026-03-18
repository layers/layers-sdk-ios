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
/// 2. Call `registerBackgroundFlush()` in
///    `application(_:didFinishLaunchingWithOptions:)` **before** the app
///    finishes launching:
///
///    ```swift
///    func application(
///        _ application: UIApplication,
///        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
///    ) -> Bool {
///        BackgroundFlushTask.registerBackgroundFlush()
///        // ... rest of setup
///        return true
///    }
///    ```
///
/// 3. The SDK automatically schedules the next execution after each run.
///    You can also manually schedule it by calling `scheduleBackgroundFlush()`.
///
public enum BackgroundFlushTask {

    /// The BGTaskScheduler task identifier.
    /// Must be listed in Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    public static let taskIdentifier = "com.layers.sdk.background-flush"

    /// Minimum interval between background flush attempts (15 minutes).
    /// This is the minimum allowed by the OS for BGAppRefreshTask.
    private static let minimumInterval: TimeInterval = 15 * 60

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "BackgroundFlush")

    /// Register the background flush task with the system.
    ///
    /// **Must** be called during `application(_:didFinishLaunchingWithOptions:)`
    /// before the app finishes launching. Calling after launch has no effect
    /// (BGTaskScheduler silently ignores late registrations).
    ///
    /// This method is safe to call on all platforms. On macOS, tvOS, watchOS,
    /// or iOS < 13, it is a no-op.
    public static func registerBackgroundFlush() {
        #if canImport(BackgroundTasks) && os(iOS)
        if #available(iOS 13.0, *) {
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: taskIdentifier,
                using: nil
            ) { task in
                handleBackgroundTask(task)
            }
            if registered {
                os_log("Registered background flush task: %{public}@",
                       log: log, type: .info, taskIdentifier)
            } else {
                os_log("Failed to register background flush task. Ensure '%{public}@' is in Info.plist BGTaskSchedulerPermittedIdentifiers.",
                       log: log, type: .error, taskIdentifier)
            }
        }
        #endif
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
    @available(iOS 13.0, *)
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
