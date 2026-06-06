import Foundation
import os.log
#if canImport(UIKit) && !os(watchOS)
import UIKit
import ObjectiveC
#endif

/// Auto-capture of `$screen_view` events via UIKit method swizzling.
///
/// On `attach`, this module installs a one-time swizzle of
/// `UIViewController.viewDidAppear(_:)`. After every appearance, the swizzled
/// implementation calls back into the active module instance which emits
/// `$screen_view` with `screen_name` and `screen_class`.
///
/// **SwiftUI views are not captured.** SwiftUI hosts views inside generic
/// `UIHostingController` instances whose names aren't useful for analytics.
/// SwiftUI consumers should use the `View.layersScreen(name:screenClass:)`
/// modifier instead.
///
/// Opt out via `LayersConfig(automaticScreenTrackingEnabled: false)`.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class ScreenTrackingModule: @unchecked Sendable {

    /// Closure-based screen tracker injection. Exists so unit tests can run
    /// without a fully initialized `Layers` singleton.
    public typealias ScreenTracker = (_ name: String, _ properties: [String: Any]) -> Void

    // MARK: - Properties

    private let lock = NSLock()
    private var tracker: ScreenTracker?
    private var enabled = false

    /// Class names that should never produce a `$screen_view`. UIKit container
    /// VCs fire `viewDidAppear` constantly and would flood the queue without
    /// providing useful semantic data.
    private static let suppressedClassNames: Set<String> = [
        "UINavigationController",
        "UITabBarController",
        "UISplitViewController",
        "UIPageViewController",
        "UIInputWindowController",
        "UICompatibilityInputViewController",
        "UIPredictionViewController",
        "UIKeyboardCandidateGridCollectionViewController",
        "UISystemKeyboardDockController",
    ]

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "screen-tracking")

    // MARK: - Singleton-Style Active Delegate

    /// The currently-attached module. Static because the swizzled `viewDidAppear`
    /// has no way to thread an instance reference; UIKit calls it on every VC.
    /// In practice the SDK is a singleton, so there's at most one active module.
    private static let activeLock = NSLock()
    private static var _active: ScreenTrackingModule?

    static var active: ScreenTrackingModule? {
        activeLock.lock()
        defer { activeLock.unlock() }
        return _active
    }

    // MARK: - Init

    public init() {}

    // MARK: - Attach / Detach

    /// Attach to the Layers singleton.
    func attach(sdk: Layers) {
        attach(tracker: { [weak sdk] name, props in
            _ = sdk?.screen(name, properties: props)
        })
    }

    /// Attach with an explicit tracker closure.
    func attach(tracker: @escaping ScreenTracker) {
        lock.lock()
        self.tracker = tracker
        enabled = true
        lock.unlock()

        Self.activeLock.lock()
        Self._active = self
        Self.activeLock.unlock()

        Self.swizzleViewDidAppearIfNeeded()
    }

    func detach() {
        lock.lock()
        enabled = false
        tracker = nil
        lock.unlock()

        Self.activeLock.lock()
        if Self._active === self {
            Self._active = nil
        }
        Self.activeLock.unlock()
        // Note: the swizzle stays installed for the lifetime of the process —
        // method_exchangeImplementations cannot be safely undone. Disabled
        // modules simply skip the emit via `enabled = false`.
    }

    // MARK: - Swizzle Bookkeeping

    private static let swizzleLock = NSLock()
    private static var swizzleInstalled = false

    static func swizzleViewDidAppearIfNeeded() {
        #if canImport(UIKit) && !os(watchOS)
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        guard !swizzleInstalled else { return }
        UIViewController.layers_installViewDidAppearSwizzle()
        swizzleInstalled = true
        #endif
    }

    /// Test hook — returns whether the swizzle has been installed in this process.
    static var _swizzleInstalledForTesting: Bool {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        return swizzleInstalled
    }

    // MARK: - Emit Hook

    /// Called from the swizzled `viewDidAppear` for every UIViewController.
    /// Filters out container VCs and routes everything else through the tracker.
    func handleViewDidAppear(_ viewController: AnyObject) {
        lock.lock()
        let isEnabled = enabled
        let t = tracker
        lock.unlock()

        guard isEnabled, let t else { return }

        let className = String(describing: type(of: viewController))
        if Self.suppressedClassNames.contains(className) {
            return
        }

        let title = (viewController.value(forKey: "title") as? String).flatMap { $0.isEmpty ? nil : $0 }
        let screenName = title ?? className
        let props: [String: Any] = ["screen_class": className]
        t(screenName, props)
    }

    /// Direct emit entry point for unit tests — bypasses the swizzle wiring.
    func _testEmit(name: String, screenClass: String) {
        lock.lock()
        let isEnabled = enabled
        let t = tracker
        lock.unlock()
        guard isEnabled, let t else { return }
        t(name, ["screen_class": screenClass])
    }
}

// MARK: - UIViewController Swizzle

#if canImport(UIKit) && !os(watchOS)
extension UIViewController {

    @objc fileprivate static func layers_installViewDidAppearSwizzle() {
        let originalSelector = #selector(UIViewController.viewDidAppear(_:))
        let swizzledSelector = #selector(UIViewController.layers_swizzled_viewDidAppear(_:))

        guard
            let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector)
        else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc fileprivate func layers_swizzled_viewDidAppear(_ animated: Bool) {
        // Because `method_exchangeImplementations` swapped the IMPs, this call
        // resolves to the *original* `viewDidAppear(_:)`.
        layers_swizzled_viewDidAppear(animated)
        ScreenTrackingModule.active?.handleViewDidAppear(self)
    }
}
#endif
