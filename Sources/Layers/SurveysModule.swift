// SurveysModule.swift
//
// Tier 8 — In-product surveys & messaging on iOS.
//
// Owns:
//   - Delegating to the Rust `SurveyManager` via UniFFI bindings (definitions,
//     targeting, frequency cap, auto-events).
//   - Native chrome rendering via `UIViewController` sheet presentation
//     (NPS/CSAT/CES/Open text/Rating) and `UIAlertController` (multiple choice
//     for simple cases).
//
// **Status:** skeleton. The chrome implementation is intentionally minimal —
// it presents a sheet with the right UI for each survey type but uses a
// neutral palette and no theming. CPTO can theme later. Targeting evaluation,
// frequency capping, and auto-event emission flow through the Rust core.
//
// Mobile platforms ignore `display.position` (the OS picks placement) and
// `targeting.url_match` (web-only).

import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)

/// Public surveys API exposed via `Layers.shared.surveys`.
///
/// `@unchecked Sendable`: this module drives `UIViewController` presentation
/// (`actuallyPresent`/`SurveyViewController`), so by contract every call into it
/// happens on the main thread — the same contract UIKit itself imposes on view
/// controller work. Its mutable state (`lastActives`, `presentingSurveyId`,
/// `pendingTimer`) is only ever touched from that single-threaded context. The
/// conformance exists so `self` can be captured in the `@Sendable` closure
/// `Timer.scheduledTimer(withTimeInterval:repeats:block:)` requires in `show(_:)`;
/// it does not add any new capability to call this class concurrently.
@available(iOS 14.0, tvOS 14.0, macCatalyst 14.0, *)
public final class SurveysModule: @unchecked Sendable {
    private let coreProvider: () -> LayersCoreHandle?

    // Decoded survey-definition cache. We rebuild this every time
    // `getActiveSurveys()` is called so we always have the current shape
    // available for rendering.
    private var lastActives: [SurveyDefinitionDecoded] = []
    private var presentingSurveyId: String?
    private var pendingTimer: Timer?

    init(coreProvider: @escaping () -> LayersCoreHandle?) {
        self.coreProvider = coreProvider
    }

    private var core: LayersCoreHandle? { coreProvider() }

    // MARK: - Public API

    /// All known survey ids (from the latest `/config` response).
    public func knownIds() -> [String] {
        return core?.knownSurveyIds() ?? []
    }

    /// Surveys currently eligible to show given the supplied targeting context.
    /// `personProperties` is forwarded to the Rust evaluator. URL is set to nil
    /// because URL targeting is web-only.
    public func getActive(
        personProperties: [String: Any] = [:],
        featureFlagValues: [String: Bool] = [:],
        eventCounts: [String: Int] = [:]
    ) -> [SurveyDefinitionDecoded] {
        guard let core = core else { return [] }
        let ctx: [String: Any] = [
            "person_properties": personProperties,
            "feature_flag_values": featureFlagValues,
            "event_counts": eventCounts
        ]
        let json = (try? JSONSerialization.data(withJSONObject: ctx))
            .flatMap { String(data: $0, encoding: .utf8) }
        do {
            let surveysJson = try core.getActiveSurveysJson(targetingContextJson: json)
            let data = surveysJson.data(using: .utf8) ?? Data()
            let decoded = (try? JSONDecoder().decode([SurveyDefinitionDecoded].self, from: data)) ?? []
            self.lastActives = decoded
            return decoded
        } catch {
            return []
        }
    }

    /// Manually present a survey by id. Returns false if the id isn't currently
    /// eligible. Respects `display.delay_ms`.
    @discardableResult
    public func show(_ surveyId: String) -> Bool {
        guard presentingSurveyId == nil else { return false }
        let actives = lastActives.isEmpty ? getActive() : lastActives
        guard let survey = actives.first(where: { $0.id == surveyId }) else {
            return false
        }
        let delayMs = survey.display?.delay_ms ?? 0
        let delay = max(0, TimeInterval(delayMs) / 1000.0)
        presentingSurveyId = surveyId
        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.actuallyPresent(survey)
        }
        return true
    }

    /// Dismiss the currently-shown survey (if any).
    public func dismiss(_ surveyId: String? = nil) {
        guard let presenting = presentingSurveyId else { return }
        if let id = surveyId, id != presenting { return }
        pendingTimer?.invalidate()
        pendingTimer = nil
        // The actual UIViewController dismissal happens in the SurveyViewController itself
        // when the user taps the close button. This method just cancels a pending render.
        presentingSurveyId = nil
    }

    // MARK: - Internals

    private func actuallyPresent(_ survey: SurveyDefinitionDecoded) {
        pendingTimer = nil
        guard let rootVC = SurveysModule.topViewController() else {
            presentingSurveyId = nil
            return
        }
        // Mark shown via the Rust core BEFORE presenting so frequency cap
        // is updated even if the user kills the app while looking at chrome.
        try? core?.markSurveyShown(surveyId: survey.id)

        let vc = SurveyViewController(
            survey: survey,
            onSubmit: { [weak self] response in
                self?.handleSubmit(surveyId: survey.id, response: response)
            },
            onDismiss: { [weak self] in
                self?.handleDismiss(surveyId: survey.id)
            }
        )
        if #available(iOS 15.0, *) {
            vc.modalPresentationStyle = .pageSheet
            if let sheet = vc.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
        } else {
            vc.modalPresentationStyle = .formSheet
        }
        rootVC.present(vc, animated: true)
    }

    private func handleSubmit(surveyId: String, response: SurveyResponseEncodable) {
        presentingSurveyId = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(response),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        try? core?.submitSurveyResponse(surveyId: surveyId, responseJson: json)
    }

    private func handleDismiss(surveyId: String) {
        presentingSurveyId = nil
        try? core?.markSurveyDismissed(surveyId: surveyId)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard let window = windowScene?.windows.first(where: { $0.isKeyWindow })
            ?? windowScene?.windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Decoded survey types
//
// These mirror the schema/surveys.schema.json shapes so the Swift renderer
// can drive UIKit without parsing JSON for every field. The Rust side owns
// the canonical definitions; these structs are decode-only.

// All three structs below are plain decoded data — every stored property is a
// String/Bool/Int or another Sendable-conforming struct here, so they're trivially
// safe to share across threads. Public types don't get *implicit* Sendable
// synthesis though, so each needs the explicit conformance (they cross a
// `@Sendable` closure boundary in `show(_:)`'s `Timer.scheduledTimer` callback).
public struct SurveyDefinitionDecoded: Decodable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let active: Bool?
    public let questions: [SurveyQuestionDecoded]
    public let display: SurveyDisplayDecoded?
}

public struct SurveyQuestionDecoded: Decodable, Sendable {
    public let id: String
    public let text: String
    public let type: String
    public let options: [String]?
    public let scale_min: Int?
    public let scale_max: Int?
    public let required: Bool?
    public let link_url: String?
    public let link_label: String?
}

public struct SurveyDisplayDecoded: Decodable, Sendable {
    public let delay_ms: Int?
    public let position: String?
    public let dismissable: Bool?
}

/// Encodable response payload sent back to Rust as JSON.
struct SurveyResponseEncodable: Encodable {
    let answers: [SurveyAnswerEncodable]
    let shown_at: String?
    let completed_at: String?
}

struct SurveyAnswerEncodable: Encodable {
    let question_id: String
    /// Answer is JSON-arbitrary — we encode it as a typed enum so the
    /// generated JSON matches the schema (number/string/bool/array/null).
    let answer: AnyAnswer

    enum AnyAnswer: Encodable {
        case int(Int)
        case double(Double)
        case string(String)
        case bool(Bool)
        case stringArray([String])
        case null

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            case .string(let v): try container.encode(v)
            case .bool(let v): try container.encode(v)
            case .stringArray(let v): try container.encode(v)
            case .null: try container.encodeNil()
            }
        }
    }
}


// MARK: - Survey UIViewController

/// Single-survey presentation controller. Renders the question list in a
/// vertical UIStackView, captures answers, and calls the appropriate callback
/// on submit or dismiss. Self-contained (no third-party UI deps).
@available(iOS 14.0, tvOS 14.0, macCatalyst 14.0, *)
final class SurveyViewController: UIViewController {
    private let survey: SurveyDefinitionDecoded
    private let onSubmit: (SurveyResponseEncodable) -> Void
    private let onDismiss: () -> Void

    private var answers: [String: SurveyAnswerEncodable.AnyAnswer] = [:]
    private let shownAt: String
    private weak var submitButton: UIButton?

    init(
        survey: SurveyDefinitionDecoded,
        onSubmit: @escaping (SurveyResponseEncodable) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.survey = survey
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.shownAt = formatter.string(from: Date())
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // If view disappears without a submit, treat as dismiss.
        if !didSubmit { onDismiss() }
    }

    private var didSubmit = false

    private func buildLayout() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 20, right: 20)
        stack.isLayoutMarginsRelativeArrangement = true
        scrollView.addSubview(stack)

        let title = UILabel()
        title.text = survey.name
        title.font = .preferredFont(forTextStyle: .headline)
        title.numberOfLines = 0
        stack.addArrangedSubview(title)

        for q in survey.questions {
            stack.addArrangedSubview(buildQuestionView(q))
        }

        let submit = UIButton(type: .system)
        submit.setTitle("Submit", for: .normal)
        submit.setTitleColor(.white, for: .normal)
        submit.backgroundColor = .systemBlue
        submit.layer.cornerRadius = 8
        submit.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        submit.isEnabled = false
        submit.alpha = 0.55
        submit.addTarget(self, action: #selector(handleSubmit), for: .touchUpInside)
        stack.addArrangedSubview(submit)
        self.submitButton = submit

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        // Close button (top-right) when dismissable
        if survey.display?.dismissable != false {
            let closeBtn = UIButton(type: .system)
            closeBtn.setTitle("✕", for: .normal)
            closeBtn.titleLabel?.font = .systemFont(ofSize: 24)
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            closeBtn.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
            view.addSubview(closeBtn)
            NSLayoutConstraint.activate([
                closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                closeBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
            ])
        }
    }

    private func buildQuestionView(_ q: SurveyQuestionDecoded) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 8
        let label = UILabel()
        label.text = q.text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        container.addArrangedSubview(label)

        switch q.type {
        case "nps", "csat", "ces":
            let min = q.scale_min ?? (q.type == "nps" ? 0 : 1)
            let max = q.scale_max ?? (q.type == "nps" ? 10 : (q.type == "csat" ? 5 : 7))
            container.addArrangedSubview(buildScale(q: q, minVal: min, maxVal: max))
        case "rating":
            let max = q.scale_max ?? 5
            container.addArrangedSubview(buildScale(q: q, minVal: 1, maxVal: max))
        case "multiple_choice":
            container.addArrangedSubview(buildMultipleChoice(q: q))
        case "open_text":
            container.addArrangedSubview(buildOpenText(q: q))
        case "link":
            container.addArrangedSubview(buildLink(q: q))
        default:
            // Unknown type — render text only.
            break
        }
        return container
    }

    private func buildScale(q: SurveyQuestionDecoded, minVal: Int, maxVal: Int) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4
        for v in minVal...maxVal {
            let btn = UIButton(type: .system)
            btn.setTitle("\(v)", for: .normal)
            btn.layer.borderWidth = 1
            btn.layer.borderColor = UIColor.separator.cgColor
            btn.layer.cornerRadius = 6
            btn.tag = v
            btn.contentEdgeInsets = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            btn.addAction(UIAction { [weak self, weak row] _ in
                guard let self = self, let row = row else { return }
                self.answers[q.id] = .int(v)
                for case let other as UIButton in row.arrangedSubviews {
                    let isSelected = other.tag == v
                    other.backgroundColor = isSelected ? .systemBlue : .clear
                    other.setTitleColor(isSelected ? .white : .systemBlue, for: .normal)
                }
                self.refreshSubmitState()
            }, for: .touchUpInside)
            row.addArrangedSubview(btn)
        }
        return row
    }

    private func buildMultipleChoice(q: SurveyQuestionDecoded) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        for opt in q.options ?? [] {
            let btn = UIButton(type: .system)
            btn.setTitle("○ \(opt)", for: .normal)
            btn.contentHorizontalAlignment = .leading
            btn.titleLabel?.font = .preferredFont(forTextStyle: .body)
            btn.addAction(UIAction { [weak self, weak stack] _ in
                guard let self = self, let stack = stack else { return }
                self.answers[q.id] = .string(opt)
                for case let other as UIButton in stack.arrangedSubviews {
                    let isSelected = other.titleLabel?.text?.contains(opt) == true
                    other.setTitle(isSelected ? "● \(opt)" : "○ \(other.titleLabel?.text?.dropFirst(2) ?? "")", for: .normal)
                }
                self.refreshSubmitState()
            }, for: .touchUpInside)
            stack.addArrangedSubview(btn)
        }
        return stack
    }

    private func buildOpenText(q: SurveyQuestionDecoded) -> UIView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.cornerRadius = 6
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        textView.delegate = self
        textView.accessibilityIdentifier = q.id
        return textView
    }

    private func buildLink(q: SurveyQuestionDecoded) -> UIView {
        let btn = UIButton(type: .system)
        btn.setTitle(q.link_label ?? "Open", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = .systemBlue
        btn.layer.cornerRadius = 8
        btn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        btn.addAction(UIAction { [weak self] _ in
            self?.answers[q.id] = .bool(true)
            if let urlStr = q.link_url, let url = URL(string: urlStr) {
                UIApplication.shared.open(url)
            }
            self?.refreshSubmitState()
            self?.handleSubmit()
        }, for: .touchUpInside)
        return btn
    }

    private func refreshSubmitState() {
        let allAnswered = survey.questions.allSatisfy { q in
            (q.required != true) || answers[q.id] != nil
        }
        submitButton?.isEnabled = allAnswered
        submitButton?.alpha = allAnswered ? 1 : 0.55
    }

    @objc private func handleClose() {
        dismiss(animated: true) // onDismiss fires from viewDidDisappear
    }

    @objc private func handleSubmit() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let answersList: [SurveyAnswerEncodable] = survey.questions.map { q in
            SurveyAnswerEncodable(question_id: q.id, answer: answers[q.id] ?? .null)
        }
        let response = SurveyResponseEncodable(
            answers: answersList,
            shown_at: shownAt,
            completed_at: formatter.string(from: Date())
        )
        didSubmit = true
        onSubmit(response)
        dismiss(animated: true)
    }
}

@available(iOS 14.0, tvOS 14.0, macCatalyst 14.0, *)
extension SurveyViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        guard let qid = textView.accessibilityIdentifier else { return }
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            answers.removeValue(forKey: qid)
        } else {
            answers[qid] = .string(trimmed)
        }
        refreshSubmitState()
    }
}

#endif
