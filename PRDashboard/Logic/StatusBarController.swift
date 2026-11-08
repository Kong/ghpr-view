import Cocoa
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let onWillShow: () -> Void
    private let onWillClose: () -> Void
    private let onCheckForUpdates: () -> Void
    private let defaultPopoverBehavior: NSPopover.Behavior

    private var eventMonitor: Any?
    private var hoverDetailVisibilityObserver: NSObjectProtocol?
    private var isHoverDetailPanelVisible = false
    private(set) var openingFromKeyboard = false
    private var previousApplication: NSRunningApplication?
    private weak var previousWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var shouldRestoreFocus = false

    init(popover: NSPopover, onWillShow: @escaping () -> Void, onWillClose: @escaping () -> Void, onCheckForUpdates: @escaping () -> Void) {
        self.statusBar = NSStatusBar.system
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = popover
        self.onWillShow = onWillShow
        self.onWillClose = onWillClose
        self.onCheckForUpdates = onCheckForUpdates
        self.defaultPopoverBehavior = popover.behavior

        super.init()

        setupStatusBarButton()
        popover.delegate = self
        setupEventMonitor()
        observeHoverDetailVisibility()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let hoverDetailVisibilityObserver {
            NotificationCenter.default.removeObserver(hoverDetailVisibilityObserver)
        }
    }

    private func setupStatusBarButton() {
        guard let button = statusItem.button else { return }

        // Use SF Symbol for menu bar icon (GitHub-like icon)
        if let image = NSImage(
            systemSymbolName: "arrow.triangle.pull",
            accessibilityDescription: String(localized: "Pull Requests")
        ) {
            image.isTemplate = true
            button.image = image
        } else {
            // Fallback to text if SF Symbol not available
            button.title = "PR"
        }

        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupMenu() -> NSMenu {
        let menu = NSMenu()

        // Version info
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let gitVersion = GitVersion.displayString
        let versionItem = NSMenuItem(
            title: String(localized: "PR Dashboard v\(version) (\(build)) \(gitVersion)"),
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(
            title: String(localized: "Check for Updates…"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit PR Dashboard"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates()
    }

    @objc private func handleClick(_ sender: AnyObject) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = setupMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover(sender)
        }
    }

    private func setupEventMonitor() {
        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown, !MenuTracker.shared.isTracking else { return }
            let window = self.popover.contentViewController?.view.window
            guard window?.attachedSheet == nil,
                  (window?.firstResponder as? NSTextView)?.hasMarkedText() != true,
                  window?.childWindows?.contains(where: { $0.isVisible }) != true else { return }
            self.hidePopover(self, restoringFocus: false)
        }
    }

    private func observeHoverDetailVisibility() {
        hoverDetailVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .prHoverDetailPanelVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isVisible = notification.userInfo?[PRHoverDetailPanelVisibilityKey.isVisible] as? Bool == true
            // Delivered on the main queue before a focused Details panel becomes key.
            MainActor.assumeIsolated {
                self?.isHoverDetailPanelVisible = isVisible
                self?.updatePopoverBehaviorForHoverDetail()
            }
        }
    }

    private func updatePopoverBehaviorForHoverDetail() {
        let behavior: NSPopover.Behavior = isHoverDetailPanelVisible ? .semitransient : defaultPopoverBehavior
        if popover.behavior != behavior {
            popover.behavior = behavior
        }
    }

    func updateBadge(prList: PRList) {
        guard let button = statusItem.button else { return }
        let count = prList.menuNotificationCount
        button.setAccessibilityLabel(String(localized: "Pull Requests"))
        button.setAccessibilityValue(
            "\(prList.authoredUnreadUnresolvedCount) unread unresolved threads on your PRs, " +
            "\(prList.unansweredDirectMentionCount) unanswered direct mentions"
        )

        if count > 0 {
            if let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) {
                image.isTemplate = true
                button.image = image
            }

            // Add badge count as title
            button.title = " \(count > 99 ? "99+" : "\(count)")"
        } else {
            button.title = ""
            if let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) {
                image.isTemplate = true
                button.image = image
            }
        }
    }

    @objc func togglePopover(_ sender: AnyObject) {
        if popover.isShown {
            hidePopover(sender, restoringFocus: true)
        } else {
            showPopover(sender)
        }
    }

    func showPopover(_ sender: AnyObject) {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        openingFromKeyboard = event == nil || event?.type == .keyDown
        previousApplication = NSWorkspace.shared.frontmostApplication
        previousWindow = NSApp.keyWindow
        previousResponder = previousWindow?.firstResponder
        shouldRestoreFocus = false

        button.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func hidePopover(_ sender: AnyObject, restoringFocus: Bool) {
        shouldRestoreFocus = restoringFocus
        popover.performClose(sender)
        statusItem.button?.highlight(false)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        onWillShow()
        updatePopoverBehaviorForHoverDetail()
    }

    func popoverWillClose(_ notification: Notification) {
        onWillClose()
        PRRowView.closeDetails()
        isHoverDetailPanelVisible = false
        updatePopoverBehaviorForHoverDetail()
        statusItem.button?.highlight(false)
    }

    func popoverDidClose(_ notification: Notification) {
        defer {
            shouldRestoreFocus = false
            previousApplication = nil
            previousWindow = nil
            previousResponder = nil
        }
        guard shouldRestoreFocus else { return }
        if let application = previousApplication, !application.isTerminated,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            application.activate(options: [])
        } else if let window = previousWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            if let responder = previousResponder {
                window.makeFirstResponder(responder)
            }
        }
    }
}
