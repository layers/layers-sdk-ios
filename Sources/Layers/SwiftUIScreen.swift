#if canImport(SwiftUI)
import SwiftUI

/// A `ViewModifier` that emits an Layers `$screen_view` event whenever
/// the modified view appears. Use via the `View.layersScreen(name:screenClass:)`
/// extension instead of constructing this directly.
///
/// This is the SwiftUI counterpart to `ScreenTrackingModule`'s UIKit swizzle —
/// SwiftUI views aren't visible to the swizzle (they all live inside generic
/// `UIHostingController` wrappers), so SwiftUI consumers must opt in per-screen.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public struct LayersScreenModifier: ViewModifier {
    public let name: String
    public let screenClass: String?

    /// Test hook — when set, `onAppear` calls this closure instead of
    /// `Layers.shared.screen(...)`. Production callers leave it `nil`.
    let testHook: ((_ name: String, _ properties: [String: Any]) -> Void)?

    public init(name: String, screenClass: String? = nil) {
        self.name = name
        self.screenClass = screenClass
        self.testHook = nil
    }

    init(
        name: String,
        screenClass: String?,
        testHook: @escaping (_ name: String, _ properties: [String: Any]) -> Void
    ) {
        self.name = name
        self.screenClass = screenClass
        self.testHook = testHook
    }

    public func body(content: Content) -> some View {
        content.onAppear {
            var props: [String: Any] = [:]
            if let cls = screenClass {
                props["screen_class"] = cls
            }
            if let hook = testHook {
                hook(name, props)
            } else {
                _ = Layers.shared.screen(name, properties: props)
            }
        }
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 7.0, *)
public extension View {
    /// Emit an Layers `$screen_view` whenever this view appears.
    ///
    /// ```swift
    /// var body: some View {
    ///     ProductDetailView(product: product)
    ///         .layersScreen(name: "Product Detail", screenClass: "ProductDetailView")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: Human-readable screen name (e.g., `"Product Detail"`).
    ///   - screenClass: Optional class-style identifier (e.g., `"ProductDetailView"`).
    ///     Stored under the `screen_class` property and used by the Rust core for
    ///     `previous_screen_class` breadcrumbs.
    func layersScreen(name: String, screenClass: String? = nil) -> some View {
        modifier(LayersScreenModifier(name: name, screenClass: screenClass))
    }
}
#endif
