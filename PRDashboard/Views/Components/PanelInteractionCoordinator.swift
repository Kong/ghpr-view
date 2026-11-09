import AppKit
import SwiftUI

enum PRPanelUpdateReason { case background, userIntent }
enum InteractionLock: Hashable { case pointer, menu, scroll, composition }
enum PanelFocusTarget: Hashable { case row(PRPanelRowID), section(PRSectionID), refresh }

enum PanelGeometryID: Hashable {
    case row(PRPanelRowID), control(PRPanelRowID, String), section(PRSectionID), summary, error, list

    var isScrollContent: Bool {
        switch self {
        case .list: return false
        case .row, .control, .section, .summary, .error: return true
        }
    }
}

struct PanelGeometrySample: Equatable {
    let frame: CGRect
    let scrollOrigin: CGFloat?
}

struct PanelGeometryPreferenceKey: PreferenceKey {
    static var defaultValue: [PanelGeometryID: PanelGeometrySample] = [:]
    static func reduce(value: inout [PanelGeometryID: PanelGeometrySample], nextValue: () -> [PanelGeometryID: PanelGeometrySample]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
final class PanelMenuCapture {
    fileprivate var facts: [Int: PullRequest] = [:]
    func fact(for id: Int) -> PullRequest? { facts[id] }
}

@MainActor
final class PanelInteractionCoordinator: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var isWindowActive = false
    @Published private(set) var selectedCategory: PRPanelCategory = .all
    @Published private(set) var categoryRevealRevision: UInt64 = 0
    @Published private(set) var categoryRevealTarget: PanelFocusTarget?
    @Published var selectedRowID: PRPanelRowID?
    @Published private(set) var expandedSections = Set(PRSectionID.allCases)
    private(set) var locks: Set<InteractionLock> = []
    @Published private(set) var displayedStructure: PRPanelProjection?
    private(set) var pendingStructure: PRPanelProjection?
    private(set) var pendingUserIntent = false
    @Published private(set) var displayedSnapshot: PRPanelSnapshot?
    private(set) var latestSnapshot: PRPanelSnapshot?
    @Published private(set) var searchFocusRequest: UInt64 = 0
    @Published private(set) var focusTarget: PanelFocusTarget?
    @Published private(set) var scrollAnchor: PanelFocusTarget?
    @Published private(set) var keyboardRevealTarget: PanelFocusTarget?
    @Published private(set) var keyboardRevealRevision: UInt64 = 0
    private var pendingKeyboardReveal = false
    private(set) var scrollAnchorOffset: CGFloat = 0
    private(set) var pendingAnchorRestoration: PanelFocusTarget?
    private weak var scrollView: NSScrollView?
    @Published private(set) var commitRevision: UInt64 = 0
    @Published private(set) var displayedSearchText = ""
    @Published private(set) var displayedFacetPanel = false
    /// Space the current window top leaves for the panel, capped at full height.
    @Published private(set) var maximumContentHeight: CGFloat = PanelMetrics.expandedHeight
    private var requestedContentSize = NSSize(width: PanelMetrics.width, height: PanelMetrics.height)
    private var pendingSearchText: String?
    private var pendingFacetPanel: Bool?
    private var latestLayoutSearchText = ""
    private var latestLayoutFacetPanel = false
    private(set) var pointerInsideList = false
    private(set) var latestFacts: [Int: PullRequest] = [:]
    private var rowActionCache: [PRPanelRowID: PRRowActions] = [:]
    private(set) var geometry: [PanelGeometryID: CGRect] = [:]
    private(set) var protectedGeometry: [PanelGeometryID: CGRect] = [:]
    private(set) var protectedFacts: [Int: PullRequest] = [:]
    private(set) var protectedActivityReminderCount: Int?
    private(set) var menuCapture = PanelMenuCapture()
    private var removedRowFallbacks: [PRPanelRowID: PanelFocusTarget] = [:]
    private var renderedFacts: [Int: PullRequest] = [:]
    private var renderedActivityReminderCount: Int?
    private var pendingExpandedSections: Set<PRSectionID>?
    private var desiredExpandedSections = Set(PRSectionID.allCases)
    private var pendingSnapshot: PRPanelSnapshot?
    private var awaitingUserIntentSnapshot = false
    private var menuDepth = 0
    private var liveScrolling = false
    private var gestureScrolling = false
    private var momentumScrolling = false
    private var wheelGeneration: UInt64 = 0
    private var pointerGeneration: UInt64 = 0
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var keyObserver: NSObjectProtocol?
    private weak var window: NSWindow?
    private weak var focusView: NSView?
    private weak var popover: NSPopover?
    private var keyboardPresentationPending = false

    var onRequestClose: (() -> Void)?
    var onPointerDown: ((Int?) -> Void)?
    var onMenuBegin: (() -> Void)?
    var onMenuTrackingChanged: ((Bool) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenRow: ((Int) -> Void)?
    var onClearSearch: (() -> Void)?
    var searchIsEmpty: () -> Bool = { true }

    var hasPendingOrder: Bool { pendingStructure != nil }
    var isComposing: Bool { locks.contains(.composition) }
    var protectsLayout: Bool { !locks.isEmpty }
    var installedMonitorCount: Int { monitors.count }
    var installedObserverCount: Int { observers.count + (keyObserver == nil ? 0 : 1) }

    func setPresented(_ presented: Bool) {
        isPresented = presented
        isWindowActive = presented && (NSApp?.isActive ?? false)
        if presented {
            pendingSearchText = latestLayoutSearchText
            pendingFacetPanel = latestLayoutFacetPanel
            pendingExpandedSections = desiredExpandedSections
            if let latestSnapshot {
                pendingSnapshot = latestSnapshot
                pendingStructure = latestSnapshot.projection
            }
            requestCommit(reason: .userIntent)
            installMonitors()
        } else {
            removeMonitors()
            locks.removeAll()
            protectedGeometry.removeAll()
            protectedFacts.removeAll()
            protectedActivityReminderCount = nil
            pendingAnchorRestoration = nil
            pendingKeyboardReveal = false
            menuCapture = PanelMenuCapture()
            removedRowFallbacks.removeAll()
            renderedFacts.removeAll(keepingCapacity: true)
            renderedActivityReminderCount = nil
            geometry.removeAll(keepingCapacity: true)
            pointerInsideList = false
            menuDepth = 0
            liveScrolling = false
            gestureScrolling = false
            momentumScrolling = false
            pointerGeneration &+= 1
            wheelGeneration &+= 1
            pendingStructure = nil
            pendingSnapshot = nil
            pendingUserIntent = false
            pendingExpandedSections = nil
            pendingSearchText = nil
            pendingFacetPanel = nil
            awaitingUserIntentSnapshot = false
            keyboardPresentationPending = false
            rowActionCache.removeAll(keepingCapacity: true)
            PRRowView.closeDetails()
        }
    }

    func prepareForPresentation(keyboard: Bool) {
        keyboardPresentationPending = keyboard
        guard keyboard else { return }
        focusFirstRow()
    }

    func bind(window: NSWindow?, focusView: NSView? = nil) {
        if self.window !== window {
            removeMonitors()
            self.window = window
            if isPresented { installMonitors() }
        }
        if let focusView { self.focusView = focusView }
        if window == nil { self.focusView = nil }
        if keyboardPresentationPending { focusFirstRow() }
        updateMaximumContentHeight()
        applyRequestedContentSize()
    }

    func bind(popover: NSPopover?) {
        self.popover = popover
        applyRequestedContentSize()
    }

    /// The panel keeps its top edge; only the space below it can vary.
    func updateMaximumContentHeight() {
        guard let window, window.isVisible, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        guard frame.height > 0, visible.height > 0, frame.maxY > visible.minY else { return }
        let chrome = max(0, frame.height - (window.contentView?.bounds.height ?? frame.height))
        let available = min(frame.maxY, visible.maxY) - visible.minY - chrome - 8
        let budget = min(max(available, 0), PanelMetrics.expandedHeight)
        guard abs(budget - maximumContentHeight) >= 0.5 else { return }
        maximumContentHeight = budget
    }

    func resizePanel(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        requestedContentSize = size
        applyRequestedContentSize()
    }

    private func applyRequestedContentSize() {
        let size = requestedContentSize
        if let popover {
            guard popover.isShown else { return }
            let current = popover.contentSize
            guard abs(current.width - size.width) >= 0.5 || abs(current.height - size.height) >= 0.5 else { return }
            // The interpolated SwiftUI layout already eases this size; AppKit must
            // not start a second animation for the same frame.
            let animates = popover.animates
            popover.animates = false
            popover.contentSize = size
            popover.animates = animates
            return
        }
        // Only the explicit DEBUG component window owns its frame directly.
        guard let window, window.isVisible else { return }
        let contentRect = window.contentRect(forFrameRect: window.frame)
        guard abs(contentRect.width - size.width) >= 0.5 || abs(contentRect.height - size.height) >= 0.5 else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: contentRect.origin, size: size))
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height),
                        display: true, animate: false)
    }

    func receive(_ projection: PRPanelProjection, reason: PRPanelUpdateReason) {
        if !locks.contains(.menu) { objectWillChange.send() }
        latestFacts = Dictionary(projection.sourcePRs.lazy.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        pendingStructure = projection
        if reason == .userIntent {
            pendingUserIntent = true
            awaitingUserIntentSnapshot = true
        }
        requestCommit(reason: reason)
    }

    func receive(snapshot: PRPanelSnapshot, reason: PRPanelUpdateReason = .background) {
        if let latestSnapshot {
            let advance = snapshot.presentationRevision &- latestSnapshot.presentationRevision
            // Revisions wrap, while equal revisions remain valid for fixed-value hosts.
            guard advance == 0 || advance <= UInt64.max / 2 else { return }
        }
        latestSnapshot = snapshot
        pendingSnapshot = snapshot
        let effectiveReason: PRPanelUpdateReason = awaitingUserIntentSnapshot ? .userIntent : reason
        receive(snapshot.projection, reason: effectiveReason)
        awaitingUserIntentSnapshot = false
    }

    /// The only place that publishes layout, section expansion, or row order.
    func requestCommit(reason: PRPanelUpdateReason) {
        guard let next = pendingStructure else { return }
        if reason == .userIntent { pendingUserIntent = true }
        guard locks.isEmpty else { return }
        guard !pointerInsideList || pendingUserIntent || !isPresented else { return }
        let previous = visibleRows(in: displayedStructure)
        let expanded = pendingExpandedSections ?? expandedSections
        let nextRows = selectedCategory.sections.filter { expanded.contains($0) }
            .flatMap { next.displayedRowIDs(for: $0) }
        for (id, target) in removedRowFallbacks {
            if case let .row(targetID) = target, !nextRows.contains(targetID) {
                removedRowFallbacks[id] = fallback(for: targetID, previous: previous, available: nextRows)
            }
        }
        for id in previous where !nextRows.contains(id) {
            removedRowFallbacks[id] = fallback(for: id, previous: previous, available: nextRows)
        }
        if let selectedRowID, !nextRows.contains(selectedRowID) {
            focusTarget = fallback(for: selectedRowID, previous: previous, available: nextRows)
            self.selectedRowID = rowID(focusTarget)
        }
        if case let .row(anchor)? = scrollAnchor, !nextRows.contains(anchor) {
            scrollAnchor = fallback(for: anchor, previous: previous, available: nextRows)
        }
        pendingAnchorRestoration = scrollAnchor
        expandedSections = expanded
        pendingExpandedSections = nil
        displayedStructure = next
        rowActionCache.removeAll(keepingCapacity: true)
        pendingStructure = nil
        if let pendingSnapshot {
            displayedSnapshot = pendingSnapshot
            self.pendingSnapshot = nil
        }
        pendingUserIntent = false
        protectedGeometry.removeAll()
        protectedFacts.removeAll(keepingCapacity: true)
        protectedActivityReminderCount = nil
        if let pendingSearchText { displayedSearchText = pendingSearchText; self.pendingSearchText = nil }
        if let pendingFacetPanel { displayedFacetPanel = pendingFacetPanel; self.pendingFacetPanel = nil }
        commitRevision &+= 1
        if keyboardPresentationPending { focusFirstRow() }
    }

    func setInteraction(_ lock: InteractionLock, active: Bool) {
        guard locks.contains(lock) != active else { return }
        if active {
            if locks.isEmpty {
                protectedGeometry = geometry
                protectedFacts = latestFacts.merging(renderedFacts, uniquingKeysWith: { _, rendered in rendered })
                protectedActivityReminderCount = renderedActivityReminderCount ?? latestSnapshot?.activityReminderCount
            }
            locks.insert(lock)
        } else {
            locks.remove(lock)
            requestCommit(reason: .background)
            publishKeyboardRevealIfReady()
        }
        if !locks.contains(.menu) { objectWillChange.send() }
    }

    func updateSearchText(_ text: String) {
        guard text != latestLayoutSearchText else { return }
        latestLayoutSearchText = text
        pendingSearchText = text
        pendingStructure = pendingStructure ?? displayedStructure
        requestCommit(reason: .userIntent)
    }

    func updateFacetPanel(_ presented: Bool) {
        guard presented != latestLayoutFacetPanel else { return }
        latestLayoutFacetPanel = presented
        pendingFacetPanel = presented
        pendingStructure = pendingStructure ?? displayedStructure
        requestCommit(reason: .userIntent)
    }

    /// Single entry point for the Filter control. The intent commits on the next
    /// main turn, so the same press also completes its own pointer lock.
    func toggleFacetPanel() {
        updateFacetPanel(!latestLayoutFacetPanel)
        endPointerInteractionAfterDispatch()
    }

    func setPointerInsideList(_ inside: Bool) {
        guard inside != pointerInsideList else { return }
        pointerInsideList = inside
        if !inside { requestCommit(reason: .background) }
        if !locks.contains(.menu) { objectWillChange.send() }
    }

    var nativeScrollOrigin: CGFloat? { scrollView?.contentView.bounds.minY }

    func recordGeometrySamples(_ samples: [PanelGeometryID: PanelGeometrySample]) {
        let currentOrigin = nativeScrollOrigin
        var normalized: [PanelGeometryID: CGRect] = [:]
        normalized.reserveCapacity(samples.count)
        for (id, sample) in samples {
            if id.isScrollContent, let measuredOrigin = sample.scrollOrigin, let currentOrigin {
                normalized[id] = sample.frame.offsetBy(dx: 0, dy: measuredOrigin - currentOrigin)
            } else {
                normalized[id] = sample.frame
            }
        }
        recordGeometry(normalized)
    }

    func recordGeometry(_ frames: [PanelGeometryID: CGRect]) {
        var frames = frames
        geometry = frames
        if let displacement = scrollDisplacement(in: frames) {
            guard abs(displacement) <= 0.5 || scrollView != nil else { return }
            _ = consumeScrollDisplacement(in: frames)
            if let scrollView, abs(displacement) > 0.5 {
                let clip = scrollView.contentView
                let previousOrigin = clip.bounds.minY
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + displacement))
                scrollView.reflectScrolledClipView(clip)
                let appliedDelta = clip.bounds.minY - previousOrigin
                for (id, frame) in frames where id.isScrollContent {
                    frames[id] = frame.offsetBy(dx: 0, dy: -appliedDelta)
                }
                geometry = frames
            }
        }
        guard pendingAnchorRestoration == nil else { return }
        guard locks.isEmpty, let viewport = frames[.list] else { return }
        var first: (id: PRPanelRowID, minY: CGFloat)?
        for (key, rect) in frames {
            guard case let .row(id) = key, rect.intersects(viewport), rect.maxY > viewport.minY else { continue }
            if let first, first.minY <= rect.minY { continue }
            first = (id, rect.minY)
        }
        if let first, scrollAnchor != .row(first.id) { scrollAnchor = .row(first.id) }
        if let first { scrollAnchorOffset = first.minY - viewport.minY }
    }
    func bind(scrollView: NSScrollView?) {
        self.scrollView = scrollView
        if scrollView != nil, pendingAnchorRestoration != nil { recordGeometry(geometry) }
    }

    /// A positive displacement scrolls only the amount by which the anchor moved.
    func consumeScrollDisplacement(in frames: [PanelGeometryID: CGRect]) -> CGFloat? {
        guard let displacement = scrollDisplacement(in: frames) else { return nil }
        pendingAnchorRestoration = nil
        return displacement
    }

    private func scrollDisplacement(in frames: [PanelGeometryID: CGRect]) -> CGFloat? {
        guard locks.isEmpty, let target = pendingAnchorRestoration, let viewport = frames[.list] else { return nil }
        let key: PanelGeometryID
        switch target {
        case let .row(id): key = .row(id)
        case let .section(id): key = .section(id)
        case .refresh: return nil
        }
        guard let frame = frames[key] else { return nil }
        return frame.minY - viewport.minY - scrollAnchorOffset
    }


    func selectCategory(_ category: PRPanelCategory) {
        guard selectedCategory != category else { return }
        selectedCategory = category
        let nextRows = visibleRows(in: displayedStructure)
        if let selectedRowID, !nextRows.contains(selectedRowID) {
            self.selectedRowID = nil
            focusTarget = nil
        }
        if case let .row(anchor)? = scrollAnchor, !nextRows.contains(anchor) {
            scrollAnchor = nil
        }
        let sections = category.sections
        let targetSection = sections.first { displayedStructure?.displayedRowIDs(for: $0).isEmpty == false }
            ?? sections.first
        if let targetSection {
            let target = PanelFocusTarget.section(targetSection)
            categoryRevealTarget = target
            scrollAnchor = target
        } else {
            categoryRevealTarget = nil
            scrollAnchor = nil
        }
        removedRowFallbacks.removeAll()
        pendingAnchorRestoration = nil
        categoryRevealRevision &+= 1
        commitRevision &+= 1
    }
    func toggleSection(_ section: PRSectionID) {
        var expanded = desiredExpandedSections
        if expanded.remove(section) == nil {
            expanded.insert(section)
        } else if selectedRowID?.section == section {
            selectedRowID = nil
            focusTarget = .section(section)
            focusList()
        }
        desiredExpandedSections = expanded
        pendingExpandedSections = expanded
        pendingStructure = pendingStructure ?? displayedStructure
        requestCommit(reason: .userIntent)
    }

    func rowActions(for id: PRPanelRowID, factory: (Int) -> PRRowActions) -> PRRowActions {
        guard locks.contains(.menu) else { return factory(id.prID) }
        if let cached = rowActionCache[id] { return cached }
        let actions = factory(id.prID)
        rowActionCache[id] = actions
        return actions
    }


    func renderedFact(for id: Int, fallback: PullRequest) -> PullRequest {
        if protectsLayout { return protectedFacts[id] ?? fallback }
        let fact = latestFacts[id] ?? fallback
        renderedFacts[id] = fact
        return fact
    }

    var activityReminderCountForLayout: Int {
        if protectsLayout { return protectedActivityReminderCount ?? displayedSnapshot?.activityReminderCount ?? 0 }
        let count = latestSnapshot?.activityReminderCount ?? displayedSnapshot?.activityReminderCount ?? 0
        renderedActivityReminderCount = count
        return count
    }
    func isAvailable(_ id: PRPanelRowID) -> Bool { latestFacts[id.prID] != nil }
    func activate(_ id: PRPanelRowID) {
        guard isAvailable(id) else { return }
        onOpenRow?(id.prID)
    }

    func select(_ id: PRPanelRowID) {
        guard isAvailable(id) else { return }
        selectedRowID = id
        focusTarget = .row(id)
    }

    func moveSelection(_ delta: Int) {
        let rows = visibleRows(in: displayedStructure).filter(isAvailable)
        guard !rows.isEmpty else { return }
        let current = selectedRowID.flatMap { rows.firstIndex(of: $0) }
        let index = current.map { min(max($0 + delta, 0), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        select(rows[index])
        pendingKeyboardReveal = true
        publishKeyboardRevealIfReady()
        focusList()
    }

    private func publishKeyboardRevealIfReady() {
        guard pendingKeyboardReveal, locks.isEmpty else { return }
        pendingKeyboardReveal = false
        // Explicit navigation supersedes preserving the old reading position.
        pendingAnchorRestoration = nil
        keyboardRevealTarget = focusTarget
        keyboardRevealRevision &+= 1
    }

    func focusSearch() { searchFocusRequest &+= 1 }

    func escape() {
        guard menuDepth == 0, !isComposing, window?.attachedSheet == nil else { return }
        if !searchIsEmpty() { onClearSearch?() } else { onRequestClose?() }
    }

    func restoreRowFocus(origin: PRPanelRowID? = nil, in returnWindow: NSWindow? = nil) {
        guard returnWindow == nil || returnWindow === window else { return }
        if let origin {
            let rows = visibleRows(in: displayedStructure).filter(isAvailable)
            let target = removedRowFallbacks[origin] ?? fallback(for: origin, previous: visibleRows(in: displayedStructure), available: rows)
            if case let .row(id) = target, !rows.contains(id) {
                focusTarget = fallback(for: id, previous: visibleRows(in: displayedStructure), available: rows)
            } else {
                focusTarget = rows.contains(origin) ? .row(origin) : target
            }
            selectedRowID = rowID(focusTarget)
        } else if let selectedRowID, isAvailable(selectedRowID) {
            focusTarget = .row(selectedRowID)
        }
        window?.makeKey()
        if case .section = focusTarget { return }
        focusList()
    }

    private func visibleRows(in projection: PRPanelProjection?) -> [PRPanelRowID] {
        guard let projection else { return [] }
        return selectedCategory.sections.filter { expandedSections.contains($0) }
            .flatMap { projection.displayedRowIDs(for: $0) }
    }

    private func fallback(for id: PRPanelRowID, previous: [PRPanelRowID], available: [PRPanelRowID]) -> PanelFocusTarget {
        let available = Set(available)
        guard let index = previous.firstIndex(of: id) else { return .section(id.section) }
        if let next = previous.dropFirst(index + 1).first(where: available.contains) { return .row(next) }
        if let previous = previous.prefix(index).reversed().first(where: available.contains) { return .row(previous) }
        return .section(id.section)
    }

    private func rowID(_ target: PanelFocusTarget?) -> PRPanelRowID? {
        if case let .row(id)? = target { return id }
        return nil
    }

    private func focusFirstRow() {
        guard focusView != nil, displayedStructure != nil else { return }
        keyboardPresentationPending = false
        if visibleRows(in: displayedStructure).filter(isAvailable).isEmpty {
            focusTarget = .refresh
        } else {
            if selectedRowID == nil { moveSelection(1) }
            focusList()
        }
    }

    private func focusList() {
        if let focusView { window?.makeFirstResponder(focusView) }
    }

    private func installMonitors() {
        guard monitors.isEmpty, let window else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel, .keyDown]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event)
        }) { monitors.append(monitor) }
        let center = NotificationCenter.default
        if keyObserver == nil {
            keyObserver = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isPresented else { return }
                    self.isWindowActive = true
                    self.installMonitors()
                    self.updateMaximumContentHeight()
                }
            }
        }
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented, self.window?.isVisible == true else { return }
                self.beginMenuTracking()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endMenuTracking() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.menuDepth == 0 else { return }
                self.cancelGestures(closingDetails: !PRRowView.isPresentingFocusedDetails)
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelGestures() }
        })
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSScrollView)?.window === self.window else { return }
                self.setLiveScrolling(true)
            }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSScrollView)?.window === self.window else { return }
                self.setLiveScrolling(false)
            }
        })
        // A budget that no longer matches the screen must follow the panel, not
        // each resize, so animating the height cannot feed itself.
        for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMaximumContentHeight() }
            })
        }
    }

    private func removeMonitors(keepingKeyObserver: Bool = false) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if !keepingKeyObserver, let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
    }

    private func cancelGestures(closingDetails: Bool = true) {
        isWindowActive = false
        pendingKeyboardReveal = false
        liveScrolling = false
        gestureScrolling = false
        momentumScrolling = false
        pointerGeneration &+= 1
        wheelGeneration &+= 1
        let abandonedMenus = menuDepth
        menuDepth = 0
        for _ in 0..<abandonedMenus { onMenuTrackingChanged?(false) }
        if closingDetails { PRRowView.closeDetails() }
        locks.removeAll()
        protectedGeometry.removeAll()
        protectedFacts.removeAll(keepingCapacity: true)
        protectedActivityReminderCount = nil
        menuCapture = PanelMenuCapture()
        rowActionCache.removeAll(keepingCapacity: true)
        setPointerInsideList(false)
        requestCommit(reason: .background)
        removeMonitors(keepingKeyObserver: true)
    }

    private func updateScrollLock() {
        setInteraction(.scroll, active: liveScrolling || gestureScrolling || momentumScrolling)
    }

    func beginMenuTracking() {
        if menuDepth == 0 {
            rowActionCache.removeAll(keepingCapacity: true)
            menuCapture.facts = latestFacts
        }
        menuDepth += 1
        setInteraction(.menu, active: true)
        onMenuTrackingChanged?(true)
        onMenuBegin?()
    }

    func endMenuTracking() {
        guard menuDepth > 0 else { return }
        menuDepth -= 1
        onMenuTrackingChanged?(false)
        guard menuDepth == 0 else { return }
        // Selected actions may dispatch after didEndTracking. Their captured reference
        // retains this menu's facts even after another menu opens.
        menuCapture = PanelMenuCapture()
        rowActionCache.removeAll(keepingCapacity: true)
        setInteraction(.menu, active: false)
        DispatchQueue.main.async { [weak self] in
            guard NSEvent.pressedMouseButtons == 0 else { return }
            self?.setInteraction(.pointer, active: false)
        }
    }

    func beginPointerInteraction(at point: CGPoint) {
        pointerGeneration &+= 1
        setInteraction(.pointer, active: true)
        let id = geometry.first { key, rect in
            if case .row = key { return rect.contains(point) }
            return false
        }.flatMap { key, _ -> PRPanelRowID? in
            if case let .row(id) = key { return id }
            return nil
        }
        if let id { select(id); focusList() }
        onPointerDown?(id?.prID)
    }

    func endPointerInteractionAfterDispatch() {
        let generation = pointerGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pointerGeneration == generation else { return }
            // A native borderless button may run its action without the local
            // mouse-up monitor; only a released button may end this press.
            guard NSEvent.pressedMouseButtons == 0 else { return }
            self.setInteraction(.pointer, active: false)
        }
    }

    func setLiveScrolling(_ active: Bool) {
        liveScrolling = active
        updateScrollLock()
    }

    func receiveScroll(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        wheelGeneration &+= 1
        let generation = wheelGeneration
        setInteraction(.scroll, active: true)
        if !phase.isEmpty { gestureScrolling = !phase.contains(.ended) && !phase.contains(.cancelled) }
        if !momentumPhase.isEmpty { momentumScrolling = !momentumPhase.contains(.ended) && !momentumPhase.contains(.cancelled) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wheelGeneration == generation else { return }
            self.updateScrollLock()
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            // Lock before returning the event to AppKit for Button dispatch.
            let coordinateView = focusView ?? window?.contentView
            let point = coordinateView?.convert(event.locationInWindow, from: nil) ?? .zero
            let flippedPoint = coordinateView?.isFlipped == true ? point : CGPoint(x: point.x, y: (coordinateView?.bounds.height ?? 0) - point.y)
            beginPointerInteraction(at: flippedPoint)
        case .leftMouseUp, .rightMouseUp:
            endPointerInteractionAfterDispatch()
        case .scrollWheel:
            receiveScroll(phase: event.phase, momentumPhase: event.momentumPhase)
        case .keyDown:
            if handleKey(event) { return nil }
        default: break
        }
        return event
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard menuDepth == 0, window?.attachedSheet == nil else { return false }
        let editor = window?.firstResponder as? NSTextView
        guard editor?.hasMarkedText() != true, !isComposing else { return false }
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        let characters = event.charactersIgnoringModifiers?.lowercased()
        if command {
            switch characters {
            case "f": focusSearch(); return true
            case ",": onOpenSettings?(); return true
            case "r": onRefresh?(); return true
            default: return false
            }
        }
        if event.keyCode == 53 { escape(); return true }
        let editing = editor != nil || window?.firstResponder is NSTextField
        if characters == "/", !editing, event.modifierFlags.intersection([.control, .option, .command]).isEmpty {
            focusSearch()
            return true
        }
        guard !editing, window?.firstResponder === focusView else { return false }
        switch event.keyCode {
        case 125: moveSelection(1); return true
        case 126: moveSelection(-1); return true
        case 36, 76:
            if let selectedRowID { activate(selectedRowID) }
            return true
        default: return false
        }
    }
}

struct PanelWindowBinding: NSViewRepresentable {
    let interaction: PanelInteractionCoordinator
    let contentSize: NSSize
    func makeNSView(context: Context) -> PanelFocusView {
        let view = PanelFocusView()
        view.interaction = interaction
        view.requestedContentSize = contentSize
        return view
    }
    func updateNSView(_ view: PanelFocusView, context: Context) {
        view.interaction = interaction
        view.requestedContentSize = contentSize
        view.applyRequestedContentSize()
    }
    static func dismantleNSView(_ view: PanelFocusView, coordinator: ()) {
        view.interaction?.setPresented(false)
        view.interaction?.bind(window: nil)
    }
}

final class PanelFocusView: NSView {
    weak var interaction: PanelInteractionCoordinator?
    /// The view can be built before it has a window; keep the size until then.
    var requestedContentSize: NSSize = .zero
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        interaction?.bind(window: window, focusView: self)
        applyRequestedContentSize()
    }
    func applyRequestedContentSize() {
        guard window != nil, requestedContentSize.height > 0 else { return }
        interaction?.resizePanel(to: requestedContentSize)
    }
}
struct PanelScrollViewBinding: NSViewRepresentable {
    let interaction: PanelInteractionCoordinator
    func makeNSView(context: Context) -> PanelScrollProbe {
        let view = PanelScrollProbe()
        view.interaction = interaction
        return view
    }
    func updateNSView(_ view: PanelScrollProbe, context: Context) {
        view.interaction = interaction
        interaction.bind(scrollView: view.enclosingScrollView)
    }
}

final class PanelScrollProbe: NSView {
    weak var interaction: PanelInteractionCoordinator?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        interaction?.bind(scrollView: enclosingScrollView)
    }
}

private struct PanelGeometryInteractionKey: EnvironmentKey {
    static let defaultValue: PanelInteractionCoordinator? = nil
}

extension EnvironmentValues {
    var panelGeometryInteraction: PanelInteractionCoordinator? {
        get { self[PanelGeometryInteractionKey.self] }
        set { self[PanelGeometryInteractionKey.self] = newValue }
    }
}

private struct PanelGeometryMeasurement: ViewModifier {
    @Environment(\.panelGeometryInteraction) private var interaction
    let id: PanelGeometryID
    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            let sample = PanelGeometrySample(frame: proxy.frame(in: .named("panel-layout")), scrollOrigin: interaction?.nativeScrollOrigin)
            Color.clear.preference(key: PanelGeometryPreferenceKey.self, value: [id: sample])
        })
    }
}

extension View {
    func panelGeometry(_ id: PanelGeometryID) -> some View {
        modifier(PanelGeometryMeasurement(id: id))
    }
}

private struct PanelDisplayRowIDKey: EnvironmentKey {
    static let defaultValue: PRPanelRowID? = nil
}
extension EnvironmentValues {
    var panelDisplayRowID: PRPanelRowID? {
        get { self[PanelDisplayRowIDKey.self] }
        set { self[PanelDisplayRowIDKey.self] = newValue }
    }
}

private struct PanelControlGeometry: ViewModifier {
    @Environment(\.panelDisplayRowID) private var rowID
    let name: String
    @ViewBuilder func body(content: Content) -> some View {
        if let rowID { content.panelGeometry(.control(rowID, name)) } else { content }
    }
}

extension View {
    func panelControlGeometry(_ name: String) -> some View { modifier(PanelControlGeometry(name: name)) }
}

extension Notification.Name {
    static let panelFocusedDetailsDidClose = Notification.Name("PRDashboard.panelFocusedDetailsDidClose")
}
