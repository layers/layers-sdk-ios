#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// A draggable, collapsible floating overlay that displays real-time SDK state.
///
/// Built entirely with programmatic UIKit APIs (no storyboards, no SwiftUI)
/// to maintain iOS 13+ compatibility and keep the SDK dependency-light.
/// Intended for integration testing only -- the overlay only works when
/// `enableDebug = true`.
///
/// Usage:
/// ```swift
/// Layers.showDebugOverlay(in: window)
/// Layers.hideDebugOverlay()
/// ```
@available(iOS 14.0, tvOS 14.0, *)
internal final class DebugOverlayView: NSObject {

    // MARK: - Constants

    private static let refreshIntervalSecs: TimeInterval = 1.5
    private static let collapseChar = "\u{25BC}" // down triangle
    private static let expandChar = "\u{25B6}"   // right triangle
    private static let overlayMaxWidth: CGFloat = 340
    private static let recentEventsHeight: CGFloat = 120
    private static let backgroundColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.9)
    private static let labelColor = UIColor(white: 1.0, alpha: 0.63)
    private static let valueColor = UIColor(red: 0, green: 1.0, blue: 136 / 255, alpha: 0.9)
    private static let errorColor = UIColor(red: 1.0, green: 69 / 255, blue: 58 / 255, alpha: 0.9)
    private static let dimColor = UIColor(white: 1.0, alpha: 0.63)
    private static let accentColor = UIColor(red: 0, green: 122 / 255, blue: 1.0, alpha: 1.0)
    private static let dividerColor = UIColor(white: 1.0, alpha: 0.24)

    // MARK: - Properties

    private weak var sdk: Layers?
    private var containerView: UIView?
    private var contentStack: UIStackView?
    private var refreshTimer: Timer?
    private var isCollapsed = false

    // Data row value labels for live-updating
    private var sdkVersionLabel: UILabel?
    private var statusLabel: UILabel?
    private var environmentLabel: UILabel?
    private var appIdLabel: UILabel?
    private var userIdLabel: UILabel?
    private var sessionIdLabel: UILabel?
    private var queueDepthLabel: UILabel?
    private var installIdLabel: UILabel?
    private var consentLabel: UILabel?
    private var attLabel: UILabel?
    private var lastFlushLabel: UILabel?
    private var networkLabel: UILabel?
    private var recentEventsContainer: UIStackView?
    private var collapseIndicator: UILabel?

    // Drag state
    private var dragStartCenter: CGPoint = .zero
    private var dragStartTouch: CGPoint = .zero

    // MARK: - Init

    init(sdk: Layers) {
        self.sdk = sdk
        super.init()
    }

    // MARK: - Show / Hide

    func show(in window: UIWindow) {
        let container = buildOverlay(in: window)
        containerView = container
        window.addSubview(container)

        // Position: top-left with margin
        container.frame.origin = CGPoint(x: 16, y: 60)

        refreshData()
        startRefreshTimer()
    }

    func hide() {
        stopRefreshTimer()
        containerView?.removeFromSuperview()
        containerView = nil
        contentStack = nil
        sdkVersionLabel = nil
        statusLabel = nil
        environmentLabel = nil
        appIdLabel = nil
        userIdLabel = nil
        sessionIdLabel = nil
        queueDepthLabel = nil
        installIdLabel = nil
        consentLabel = nil
        attLabel = nil
        lastFlushLabel = nil
        networkLabel = nil
        recentEventsContainer = nil
        collapseIndicator = nil
    }

    // MARK: - Timer

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: Self.refreshIntervalSecs, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Build Overlay

    private func buildOverlay(in window: UIWindow) -> UIView {
        let screenWidth = window.bounds.width
        let maxWidth = min(Self.overlayMaxWidth, screenWidth - 32)

        let container = UIView()
        container.backgroundColor = Self.backgroundColor
        container.layer.cornerRadius = 8
        container.clipsToBounds = true

        // Calculate size after building content
        let outerStack = UIStackView()
        outerStack.axis = .vertical
        outerStack.spacing = 0
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(outerStack)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            outerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            outerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            outerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            outerStack.widthAnchor.constraint(equalToConstant: maxWidth - 24),
        ])

        // Header (draggable + tap-to-collapse)
        let header = buildHeader()
        outerStack.addArrangedSubview(header)

        // Content area
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 2
        contentStack = content

        // SDK state rows
        sdkVersionLabel = addRow(to: content, label: "SDK Version")
        statusLabel = addRow(to: content, label: "Status")
        environmentLabel = addRow(to: content, label: "Environment")
        appIdLabel = addRow(to: content, label: "App ID")
        userIdLabel = addRow(to: content, label: "User ID")
        sessionIdLabel = addRow(to: content, label: "Session ID")
        queueDepthLabel = addRow(to: content, label: "Queue Depth")
        installIdLabel = addRow(to: content, label: "Install ID")
        consentLabel = addRow(to: content, label: "Consent")
        // iOS-specific: shows App Tracking Transparency status and IDFA.
        // Android shows GAID instead; Flutter/RN overlays omit ad tracking
        // since they are cross-platform and delegate to native modules.
        attLabel = addRow(to: content, label: "ATT / IDFA")
        lastFlushLabel = addRow(to: content, label: "Last Flush")
        networkLabel = addRow(to: content, label: "Network")

        // Divider before recent events
        content.addArrangedSubview(makeDivider())

        // Recent events header
        let eventsLabel = UILabel()
        eventsLabel.text = "Recent Events"
        eventsLabel.textColor = Self.labelColor
        eventsLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        content.addArrangedSubview(eventsLabel)

        // Scrollable recent events list
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: Self.recentEventsHeight).isActive = true

        let eventsStack = UIStackView()
        eventsStack.axis = .vertical
        eventsStack.spacing = 1
        eventsStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(eventsStack)

        NSLayoutConstraint.activate([
            eventsStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            eventsStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            eventsStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            eventsStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            eventsStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        recentEventsContainer = eventsStack
        content.addArrangedSubview(scrollView)

        // Divider before button
        content.addArrangedSubview(makeDivider())

        // Flush Now button
        let flushButton = UIButton(type: .system)
        flushButton.setTitle("Flush Now", for: .normal)
        flushButton.setTitleColor(.white, for: .normal)
        flushButton.backgroundColor = Self.accentColor
        flushButton.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        flushButton.layer.cornerRadius = 4
        flushButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        flushButton.addTarget(self, action: #selector(flushTapped), for: .touchUpInside)
        content.addArrangedSubview(flushButton)

        outerStack.addArrangedSubview(content)

        // Add drag gesture to header
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        header.addGestureRecognizer(panGesture)

        // Size to fit
        container.setNeedsLayout()
        container.layoutIfNeeded()
        let fittedSize = outerStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        container.frame.size = CGSize(width: fittedSize.width + 24, height: fittedSize.height + 20)

        return container
    }

    private func buildHeader() -> UIView {
        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 4

        let title = UILabel()
        title.text = "Layers SDK Debug"
        title.textColor = .white
        title.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(title)

        let indicator = UILabel()
        indicator.text = Self.collapseChar
        indicator.textColor = Self.labelColor
        indicator.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        collapseIndicator = indicator
        header.addArrangedSubview(indicator)

        // Tap to toggle collapse
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(toggleCollapse))
        header.addGestureRecognizer(tapGesture)
        header.isUserInteractionEnabled = true

        // Add bottom padding
        let wrapper = UIStackView(arrangedSubviews: [header])
        wrapper.axis = .vertical
        wrapper.isLayoutMarginsRelativeArrangement = true
        wrapper.layoutMargins = UIEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)

        return wrapper
    }

    // MARK: - Row Builder

    @discardableResult
    private func addRow(to parent: UIStackView, label: String) -> UILabel {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8

        let labelView = UILabel()
        labelView.text = label
        labelView.textColor = Self.labelColor
        labelView.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        labelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        labelView.setContentHuggingPriority(.required, for: .horizontal)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(labelView)

        let valueView = UILabel()
        valueView.text = "--"
        valueView.textColor = Self.valueColor
        valueView.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        valueView.lineBreakMode = .byTruncatingTail
        valueView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(valueView)

        parent.addArrangedSubview(row)
        return valueView
    }

    private func makeDivider() -> UIView {
        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.heightAnchor.constraint(equalToConstant: 13).isActive = true

        let line = UIView()
        line.backgroundColor = Self.dividerColor
        line.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(line)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])

        return wrapper
    }

    // MARK: - Actions

    @objc private func toggleCollapse() {
        isCollapsed.toggle()
        contentStack?.isHidden = isCollapsed
        collapseIndicator?.text = isCollapsed ? Self.expandChar : Self.collapseChar

        if !isCollapsed {
            refreshData()
        }

        // Re-size container to fit the (now hidden/shown) content
        if let container = containerView, let outerStack = container.subviews.first {
            container.setNeedsLayout()
            container.layoutIfNeeded()
            let fittedSize = outerStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let origin = container.frame.origin
            container.frame = CGRect(
                origin: origin,
                size: CGSize(width: fittedSize.width + 24, height: fittedSize.height + 20)
            )
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let container = containerView else { return }

        switch gesture.state {
        case .began:
            dragStartCenter = container.center
            dragStartTouch = gesture.translation(in: container.superview)
        case .changed:
            let translation = gesture.translation(in: container.superview)
            container.center = CGPoint(
                x: dragStartCenter.x + translation.x - dragStartTouch.x,
                y: dragStartCenter.y + translation.y - dragStartTouch.y
            )
        default:
            break
        }
    }

    @objc private func flushTapped() {
        guard let sdk = sdk else { return }
        Task {
            await sdk.flush()
        }
        // Refresh immediately to show updated queue depth
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshData()
        }
    }

    // MARK: - Data Refresh

    private func refreshData() {
        guard !isCollapsed, let sdk = sdk else { return }

        let state = sdk.debugOverlayState()

        sdkVersionLabel?.text = sdkVersion()
        statusLabel?.text = state.isInitialized ? "Initialized" : "Not initialized"
        statusLabel?.textColor = state.isInitialized ? Self.valueColor : Self.errorColor

        environmentLabel?.text = state.environment
        appIdLabel?.text = state.appId ?? "--"
        userIdLabel?.text = state.userId ?? "(anonymous)"
        sessionIdLabel?.text = state.sessionId.map { truncate($0, maxLength: 8) } ?? "--"
        queueDepthLabel?.text = state.queueDepth.map(String.init) ?? "--"
        installIdLabel?.text = state.installId.map { truncate($0, maxLength: 8) } ?? "--"

        // Consent
        consentLabel?.text = "analytics=\(state.consentAnalytics) ads=\(state.consentAdvertising)"

        // ATT / IDFA
        if let idfa = state.idfa {
            attLabel?.text = "\(state.attStatus) / \(truncate(idfa, maxLength: 8))"
        } else {
            attLabel?.text = state.attStatus
        }

        // Last flush
        let flushText = state.lastFlushResult ?? "never"
        lastFlushLabel?.text = flushText
        if flushText == "never" {
            lastFlushLabel?.textColor = Self.dimColor
        } else if flushText.contains("ok") {
            lastFlushLabel?.textColor = Self.valueColor
        } else {
            lastFlushLabel?.textColor = Self.errorColor
        }

        // Network — read cached status from SDK (non-blocking)
        networkLabel?.text = state.networkOnline ? "online" : "offline"
        networkLabel?.textColor = state.networkOnline ? Self.valueColor : Self.errorColor

        // Recent events
        refreshRecentEvents(state.recentEvents)
    }

    private func refreshRecentEvents(_ events: [(timestamp: Date, name: String, propertyCount: Int)]) {
        guard let container = recentEventsContainer else { return }

        // Remove all existing event labels
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if events.isEmpty {
            let empty = UILabel()
            empty.text = "(no events tracked)"
            empty.textColor = UIColor(white: 1.0, alpha: 0.47)
            empty.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            container.addArrangedSubview(empty)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        for event in events {
            let time = formatter.string(from: event.timestamp)
            var text = "\(time)  \(event.name)"
            if event.propertyCount > 0 {
                text += " (\(event.propertyCount)p)"
            }

            let label = UILabel()
            label.text = text
            label.textColor = UIColor(white: 1.0, alpha: 0.78)
            label.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            container.addArrangedSubview(label)
        }
    }

    // MARK: - Helpers

    private func truncate(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength { return string }
        return String(string.prefix(maxLength)) + "..."
    }

    private func sdkVersion() -> String {
        // Read from the bundle's infoDictionary or fall back to a constant
        if let version = Bundle(for: Layers.self).infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "unknown"
    }

}
#endif
