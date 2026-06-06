import Foundation
import os.log
#if canImport(UIKit) && !os(watchOS)
import UIKit
import ObjectiveC
#endif

/// Tier 3 iOS touch autocapture.
///
/// On `attach`, this module installs a one-time `method_exchangeImplementations`
/// swizzle on `UIWindow.sendEvent(_:)`. Every time UIKit dispatches a `UIEvent`
/// to a window, the swizzled implementation forwards the event to the active
/// module. Touch events that finish on a `UIControl` (or any view with a
/// non-empty `accessibilityLabel`/`accessibilityIdentifier`) produce a single
/// `$autocapture` event with:
///
///   - `event_type`: `"touch_up_inside"` (currently the only emitted type)
///   - `target_class`: the deepest interactive view's class name
///   - `accessibility_label`: the view's `accessibilityLabel` if set
///   - `accessibility_identifier`: the view's `accessibilityIdentifier` if set
///   - `elements_chain`: a path of class + identifier from the deepest view up
///     to the window root (matches the spirit of PostHog's web `elements_chain`,
///     adapted for UIKit's responder hierarchy).
///
/// **Default: OFF.** This module is opt-in via
/// `LayersConfig(automaticTouchAutocaptureEnabled: true)` because indiscriminate
/// touch capture can leak PII through `accessibilityLabel` values containing user
/// data (names, emails, account numbers, etc.).
///
/// Tap detection heuristic: a touch is considered a "tap" when its phase reaches
/// `.ended`, the touch's view is non-nil, and the touch traveled a small distance
/// from where it began. We don't try to perfectly replicate `touchUpInside` —
/// `UIControl` itself decides that — but the heuristic captures the same set of
/// events for the purposes of analytics breadcrumbs.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public final class AutocaptureModule: @unchecked Sendable {

    /// Closure-based emitter for unit tests.
    public typealias Emitter = (_ event: String, _ properties: [String: Any]) -> Void

    // MARK: - Properties

    private let lock = NSLock()
    private var emitter: Emitter?
    private var enabled = false

    /// Maximum distance (in points) a touch may travel between `.began` and
    /// `.ended` to still count as a "tap". Larger drags are skipped.
    static let tapDistanceThreshold: CGFloat = 10.0

    private static let log = OSLog(subsystem: "com.layers.sdk", category: "autocapture")

    /// Class names that should never produce an autocapture event — internal
    /// UIKit chrome, gestures we can't reliably attribute, etc.
    private static let suppressedClassNames: Set<String> = [
        "UITransitionView",
        "UIDropShadowView",
        "UILayoutContainerView",
    ]

    // MARK: - Active Singleton

    private static let activeLock = NSLock()
    private static var _active: AutocaptureModule?

    static var active: AutocaptureModule? {
        activeLock.lock()
        defer { activeLock.unlock() }
        return _active
    }

    // MARK: - Init

    public init() {}

    // MARK: - Attach / Detach

    func attach(sdk: Layers) {
        attach(emitter: { [weak sdk] event, props in
            _ = sdk?.track(event, properties: props)
        })
    }

    func attach(emitter: @escaping Emitter) {
        lock.lock()
        self.emitter = emitter
        enabled = true
        lock.unlock()

        Self.activeLock.lock()
        Self._active = self
        Self.activeLock.unlock()

        Self.installSendEventSwizzleIfNeeded()
    }

    func detach() {
        lock.lock()
        enabled = false
        emitter = nil
        lock.unlock()

        Self.activeLock.lock()
        if Self._active === self {
            Self._active = nil
        }
        Self.activeLock.unlock()
        // The swizzle stays installed for the lifetime of the process —
        // method_exchangeImplementations cannot be safely undone. Once
        // `enabled = false`, the swizzled IMP becomes a cheap no-op.
    }

    // MARK: - Swizzle

    private static let swizzleLock = NSLock()
    private static var swizzleInstalled = false

    static func installSendEventSwizzleIfNeeded() {
        #if canImport(UIKit) && !os(watchOS)
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        guard !swizzleInstalled else { return }
        UIWindow.layers_installSendEventSwizzle()
        swizzleInstalled = true
        #endif
    }

    static var _swizzleInstalledForTesting: Bool {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        return swizzleInstalled
    }

    // MARK: - Touch Tracking State

    #if canImport(UIKit) && !os(watchOS)
    /// Track the start position of every active touch so we can compute the
    /// travelled distance on `.ended`. `UITouch` is reference-equal across
    /// phases for the same gesture, so we key on `ObjectIdentifier`.
    private var touchStartPoints: [ObjectIdentifier: CGPoint] = [:]
    #endif

    // MARK: - Event Hook

    #if canImport(UIKit) && !os(watchOS)
    @MainActor
    func handleSendEvent(_ event: UIEvent, in window: UIWindow) {
        guard event.type == .touches else { return }
        guard let touches = event.allTouches else { return }

        lock.lock()
        let isEnabled = enabled
        let emit = emitter
        lock.unlock()
        guard isEnabled, let emit else { return }

        for touch in touches {
            switch touch.phase {
            case .began:
                lock.lock()
                touchStartPoints[ObjectIdentifier(touch)] = touch.location(in: window)
                lock.unlock()
            case .ended:
                lock.lock()
                let start = touchStartPoints.removeValue(forKey: ObjectIdentifier(touch))
                lock.unlock()
                let endPoint = touch.location(in: window)
                if let start = start {
                    let dx = endPoint.x - start.x
                    let dy = endPoint.y - start.y
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance > Self.tapDistanceThreshold {
                        continue
                    }
                }
                guard let target = touch.view else { continue }
                emitTap(target: target, in: window, emit: emit)
            case .cancelled:
                lock.lock()
                touchStartPoints.removeValue(forKey: ObjectIdentifier(touch))
                lock.unlock()
            default:
                break
            }
        }
    }

    @MainActor
    private func emitTap(target: UIView, in window: UIWindow, emit: Emitter) {
        // Walk up the responder chain to find the most semantically meaningful
        // ancestor: prefer a UIControl, then anything with an accessibility
        // label/identifier, falling back to the original target.
        let interactive = Self.interactiveAncestor(of: target) ?? target
        let className = String(describing: type(of: interactive))
        if Self.suppressedClassNames.contains(className) { return }

        var props: [String: Any] = [
            "event_type": "touch_up_inside",
            "target_class": className,
            "elements_chain": Self.elementsChain(from: interactive, root: window),
        ]
        if let label = interactive.accessibilityLabel, !label.isEmpty {
            props["accessibility_label"] = label
        }
        if let identifier = interactive.accessibilityIdentifier, !identifier.isEmpty {
            props["accessibility_identifier"] = identifier
        }
        emit("$autocapture", props)
    }

    /// Returns the deepest ancestor of `view` (inclusive) that is either a
    /// `UIControl` or has a non-empty accessibility label/identifier. Returns
    /// `nil` if no such ancestor exists in the responder chain.
    static func interactiveAncestor(of view: UIView) -> UIView? {
        var current: UIView? = view
        while let v = current {
            if v is UIControl { return v }
            if let label = v.accessibilityLabel, !label.isEmpty { return v }
            if let id = v.accessibilityIdentifier, !id.isEmpty { return v }
            current = v.superview
        }
        return nil
    }

    /// Build a `>`-separated path of class + identifier tokens from `view` up
    /// to (but not including) `root`. e.g. `"UIButton.action_button>UIView.container"`.
    static func elementsChain(from view: UIView, root: UIView?) -> String {
        var parts: [String] = []
        var current: UIView? = view
        while let v = current, v !== root {
            let className = String(describing: type(of: v))
            if let id = v.accessibilityIdentifier, !id.isEmpty {
                parts.append("\(className).\(id)")
            } else {
                parts.append(className)
            }
            current = v.superview
        }
        return parts.joined(separator: ">")
    }
    #endif
}

// MARK: - UIWindow Swizzle

#if canImport(UIKit) && !os(watchOS)
extension UIWindow {

    @objc fileprivate static func layers_installSendEventSwizzle() {
        let originalSelector = #selector(UIWindow.sendEvent(_:))
        let swizzledSelector = #selector(UIWindow.layers_swizzled_sendEvent(_:))

        guard
            let originalMethod = class_getInstanceMethod(UIWindow.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(UIWindow.self, swizzledSelector)
        else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc fileprivate func layers_swizzled_sendEvent(_ event: UIEvent) {
        // After exchange, this calls the *original* sendEvent.
        layers_swizzled_sendEvent(event)
        if let active = AutocaptureModule.active {
            // sendEvent is always invoked on the main thread.
            MainActor.assumeIsolated {
                active.handleSendEvent(event, in: self)
            }
        }
    }
}
#endif
