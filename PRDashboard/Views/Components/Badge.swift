import AppKit
import Combine
import SwiftUI

private enum HoverTooltipPalette {
    private static func darkAware(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let background = darkAware(
        dark: NSColor(calibratedWhite: 0.16, alpha: 0.98),
        light: NSColor(calibratedWhite: 0.97, alpha: 0.98)
    )
    static let foreground = NSColor.labelColor
    static let border = darkAware(
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.10),
        light: NSColor(calibratedWhite: 0.0, alpha: 0.12)
    )
    static let shadow = darkAware(
        dark: NSColor.black.withAlphaComponent(0.32),
        light: NSColor.black.withAlphaComponent(0.16)
    )
}

enum HoverTooltipCoordinateSpace {
    static let name = "hover-tooltip-root"
}

final class HoverTooltipPresenter: ObservableObject {
    struct Tooltip: Equatable {
        let ownerID: UUID
        let text: String
        let point: CGPoint
    }

    @Published private(set) var tooltip: Tooltip?
    @Published private(set) var cancellationRevision: UInt64 = 0

    /// Hosts call this when closing, even if their retained view does not disappear.
    func dismissAll() {
        cancellationRevision &+= 1
        tooltip = nil
    }

    func show(ownerID: UUID, text: String, point: CGPoint) {
        tooltip = Tooltip(ownerID: ownerID, text: text, point: point)
    }

    func update(ownerID: UUID, text: String, point: CGPoint) {
        guard let current = tooltip, current.ownerID == ownerID else { return }
        // Pointer events can arrive frequently. Skip sub-pixel updates so the
        // overlay doesn't re-layout on every movement.
        if current.text == text,
           abs(current.point.x - point.x) < 1,
           abs(current.point.y - point.y) < 1
        {
            return
        }
        tooltip = Tooltip(ownerID: ownerID, text: text, point: point)
    }

    func hide(ownerID: UUID) {
        guard tooltip?.ownerID == ownerID else { return }
        tooltip = nil
    }

    func isVisible(for ownerID: UUID) -> Bool {
        tooltip?.ownerID == ownerID
    }
}

private struct HoverTooltipPresenterKey: EnvironmentKey {
    static let defaultValue: HoverTooltipPresenter?
        = nil
}

extension EnvironmentValues {
    var hoverTooltipPresenter: HoverTooltipPresenter? {
        get { self[HoverTooltipPresenterKey.self] }
        set { self[HoverTooltipPresenterKey.self] = newValue }
    }
}

private struct CompactPRRowBadgeStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactPRRowBadges: Bool {
        get { self[CompactPRRowBadgeStyleKey.self] }
        set { self[CompactPRRowBadgeStyleKey.self] = newValue }
    }
}

private struct PRRowBadgeSurface: ViewModifier {
    @Environment(\.compactPRRowBadges) private var compact
    let color: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if compact {
            content
        } else {
            content
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(Capsule())
        }
    }
}
private extension View {
    func prRowBadgeSurface(_ color: Color) -> some View {
        modifier(PRRowBadgeSurface(color: color))
    }
}

private struct HoverTooltipSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct HoverTooltipOverlay: View {
    @ObservedObject var presenter: HoverTooltipPresenter
    @State private var measuredSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            if let tooltip = presenter.tooltip {
                tooltipBubble(text: tooltip.text)
                    .background(
                        GeometryReader { bubbleGeometry in
                            Color.clear.preference(
                                key: HoverTooltipSizePreferenceKey.self,
                                value: bubbleGeometry.size
                            )
                        }
                    )
                    .onPreferenceChange(HoverTooltipSizePreferenceKey.self) { size in
                        measuredSize = size
                    }
                    .opacity(measuredSize == .zero ? 0 : 1)
                    .position(position(for: tooltip, in: geometry.size))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private func tooltipBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: NSFont.smallSystemFontSize))
            .foregroundColor(Color(nsColor: HoverTooltipPalette.foreground))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: Self.tooltipWidth(for: text), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: HoverTooltipPalette.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: HoverTooltipPalette.border), lineWidth: 0.5)
            )
            .shadow(color: Color(nsColor: HoverTooltipPalette.shadow), radius: 6, y: 2)
    }

    private static let tooltipFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    private static func tooltipWidth(for text: String) -> CGFloat {
        // Real glyph measurement so CJK/emoji widths don't fall back to a
        // Latin-only heuristic. +20 accounts for horizontal padding.
        let attrs: [NSAttributedString.Key: Any] = [.font: tooltipFont]
        let single = (text as NSString).size(withAttributes: attrs).width + 20
        return min(max(single, 140), 260)
    }

    private func position(for tooltip: HoverTooltipPresenter.Tooltip, in containerSize: CGSize) -> CGPoint {
        guard measuredSize != .zero else {
            return CGPoint(x: tooltip.point.x, y: tooltip.point.y)
        }
        let margin: CGFloat = 8
        let originX = axisOrigin(
            point: tooltip.point.x,
            size: measuredSize.width,
            container: containerSize.width,
            offset: 14,
            margin: margin
        )
        let originY = axisOrigin(
            point: tooltip.point.y,
            size: measuredSize.height,
            container: containerSize.height,
            offset: 18,
            margin: margin
        )
        return CGPoint(x: originX + measuredSize.width / 2, y: originY + measuredSize.height / 2)
    }

    private func axisOrigin(
        point: CGFloat,
        size: CGFloat,
        container: CGFloat,
        offset: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        let after = point + offset
        let before = point - size - offset
        if after + size <= container - margin { return after }
        if before >= margin { return before }
        let clampMax = max(margin, container - size - margin)
        return min(max(after, margin), clampMax)
    }
}

private struct HoverTooltipTrackingArea: NSViewRepresentable {
    let presenter: HoverTooltipPresenter
    let text: String
    let delayNanoseconds: UInt64
    let origin: CGPoint
    let reduceMotion: Bool

    func makeNSView(context: Context) -> HoverTooltipTrackingView {
        let view = HoverTooltipTrackingView()
        view.setAccessibilityElement(false)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HoverTooltipTrackingView, context: Context) {
        view.configure(presenter: presenter, text: text, delayNanoseconds: delayNanoseconds,
                       origin: origin, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: HoverTooltipTrackingView, coordinator: ()) {
        view.stopTracking()
    }
}

private final class HoverTooltipTrackingView: NSView {
    private let ownerID = UUID()
    private weak var presenter: HoverTooltipPresenter?
    private var cancellationSubscription: AnyCancellable?
    private var text = ""
    private var delayNanoseconds: UInt64 = 300_000_000
    private var origin: CGPoint = .zero
    private var reduceMotion = false
    private var isHovered = false
    private var latestPoint: CGPoint = .zero
    private var showTask: Task<Void, Never>?
    private var hoverTrackingArea: NSTrackingArea?

    func configure(presenter: HoverTooltipPresenter, text: String, delayNanoseconds: UInt64,
                   origin: CGPoint, reduceMotion: Bool) {
        if self.presenter !== presenter {
            stopTracking()
            self.presenter = presenter
            cancellationSubscription = presenter.$cancellationRevision.dropFirst().sink { [weak self] _ in
                self?.endHover()
            }
        }
        self.text = text
        self.delayNanoseconds = delayNanoseconds
        self.origin = origin
        self.reduceMotion = reduceMotion
    }

    deinit { showTask?.cancel() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeHoverTrackingArea()
        guard window != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { trackHover(with: event) }

    override func mouseMoved(with event: NSEvent) { trackHover(with: event) }

    override func mouseExited(with event: NSEvent) { endHover() }

    private func trackHover(with event: NSEvent) {
        guard window != nil, let presenter else { return }
        let point = convert(event.locationInWindow, from: nil)
        latestPoint = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
        if isHovered {
            presenter.update(ownerID: ownerID, text: text, point: latestPoint)
            return
        }
        isHovered = true
        showTask = Task { @MainActor [weak self, delayNanoseconds] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self, self.isHovered else { return }
            self.showTask = nil
            withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.10)) {
                self.presenter?.show(ownerID: self.ownerID, text: self.text, point: self.latestPoint)
            }
        }
    }

    private func cancelHover() {
        isHovered = false
        showTask?.cancel()
        showTask = nil
    }

    private func endHover() {
        cancelHover()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) {
            presenter?.hide(ownerID: ownerID)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    func stopTracking() {
        removeHoverTrackingArea()
        cancelHover()
        // AppKit can detach/dismantle this view during SwiftUI graph destruction.
        // Cancel work now, but publish removal only after that transaction unwinds.
        guard let presenter, presenter.isVisible(for: ownerID) else { return }
        let ownerID = ownerID
        DispatchQueue.main.async { [weak self, weak presenter] in
            guard self?.isHovered != true else { return }
            presenter?.hide(ownerID: ownerID)
        }
    }

    private func removeHoverTrackingArea() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
    }
}

private struct DelayedHoverTooltipModifier: ViewModifier {
    let text: String
    let delayNanoseconds: UInt64

    @Environment(\.hoverTooltipPresenter) private var presenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactPRRowBadges) private var compact

    @ViewBuilder
    func body(content: Content) -> some View {
        // Give compact signals the same vertical target as Jira, including the
        // whitespace around the glyphs. The native tracker still passes clicks through.
        let target = content.frame(minHeight: compact ? PanelMetrics.toolSize : nil)
        if let presenter {
            target
                .background {
                    GeometryReader { geometry in
                        let frame = geometry.frame(in: .named(HoverTooltipCoordinateSpace.name))
                        HoverTooltipTrackingArea(
                            presenter: presenter,
                            text: text,
                            delayNanoseconds: delayNanoseconds,
                            origin: frame.origin,
                            reduceMotion: reduceMotion
                        )
                    }
                }
        } else {
            target
        }
    }
}

extension View {
    func delayedHoverTooltip(_ text: String, delayNanoseconds: UInt64 = 300_000_000) -> some View {
        modifier(DelayedHoverTooltipModifier(text: text, delayNanoseconds: delayNanoseconds))
    }
}

struct Badge: View {
    let count: Int
    var color: Color = .red

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(Capsule())
        }
    }
}

struct DraftBadge: View {
    var body: some View {
        Text("Draft")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .prRowBadgeSurface(Color.secondary.opacity(0.2))
            .delayedHoverTooltip(
                String(localized: "This PR is a draft and not ready for review.")
            )
    }
}

struct MyReviewStatusBadge: View {
    let status: MyReviewStatus

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(textColor)
            .prRowBadgeSurface(backgroundColor)
            .fixedSize(horizontal: true, vertical: false)
            .delayedHoverTooltip(explanation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your review: \(title)")
            .accessibilityValue(explanation)
    }

    private var symbol: String {
        switch status {
        case .waiting: return "clock"
        case .changesRequested: return "exclamationmark.bubble"
        case .changesResolved: return "arrow.clockwise"
        case .approved: return "checkmark.circle"
        }
    }

    private var title: String {
        switch status {
        case .waiting: return String(localized: "Waiting")
        case .changesRequested: return String(localized: "Changes requested")
        case .changesResolved: return String(localized: "Review again")
        case .approved: return String(localized: "Approved")
        }
    }

    private var explanation: String {
        switch status {
        case .waiting:
            return String(localized: "Your review is waiting.")
        case .changesRequested:
            return String(localized: "You requested changes.")
        case .changesResolved:
            return String(localized: "Review again. Model state: changes resolved; new commits, resolved threads, or a review request may require another look.")
        case .approved:
            return String(localized: "You approved this PR.")
        }
    }

    private var textColor: Color {
        switch status {
        case .waiting: return .secondary
        case .changesRequested: return .red
        case .changesResolved: return .orange
        case .approved: return .green
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .waiting: return Color.secondary.opacity(0.15)
        case .changesRequested: return Color.red.opacity(0.15)
        case .changesResolved: return Color.orange.opacity(0.15)
        case .approved: return Color.green.opacity(0.15)
        }
    }
}

struct ApprovalBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(.green)
        .prRowBadgeSurface(Color.green.opacity(0.15))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(count) approvals"))
        .delayedHoverTooltip(
            String(localized: "This shows how many approvals this PR has received.")
        )
    }
}

struct MentionBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "@99+" : "@\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.blue)
                .prRowBadgeSurface(Color.blue.opacity(0.15))
                .accessibilityLabel(String(localized: "\(count) unanswered direct mentions"))
                .delayedHoverTooltip(
                    String(localized: "Unanswered direct mentions: \(count)")
                )
        }
    }
}

struct ConflictBadge: View {
    var body: some View {
        Text("Conflict")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.red)
            .prRowBadgeSurface(Color.red.opacity(0.15))
            .delayedHoverTooltip(
                String(localized: "This PR has conflicts with the base branch.")
            )
    }
}

#if DEBUG
struct Badge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 10) {
            Badge(count: 5)
            Badge(count: 99)
            Badge(count: 100)
            DraftBadge()
            MyReviewStatusBadge(status: .waiting)
            MyReviewStatusBadge(status: .changesRequested)
            MyReviewStatusBadge(status: .changesResolved)
            MyReviewStatusBadge(status: .approved)
            ApprovalBadge(count: 2)
            ConflictBadge()
        }
        .padding()
    }
}
#endif
