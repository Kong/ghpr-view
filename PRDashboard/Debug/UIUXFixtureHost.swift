#if DEBUG
import AppKit
import SwiftUI
import Darwin

/// Retained by AppDelegate's first DEBUG launch branch, before production services exist.
@MainActor
final class UIUXFixtureHost {
    private let model = UIUXFixtureModel()
    private let popover = NSPopover()
    private var statusBar: StatusBarController?
    private var controls: NSWindow?
    private var componentWindow: UIUXSmokeComponentWindow?
    private var settingsWindow: NSWindow?
    private var activityWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private let activityNavigation = ActivityNavigation()
    private var auxiliarySmokeIndex: Int?
    private var auxiliaryRenderToken: String?
    private var auxiliaryCaptureScheduled = false
    private var smokeTargetID: Int?
    private var smokeCoordinatorEvidence: [String: Any] = [:]
    private var usesSmokeWindow = false
    private var hostedView: NSView? {
        usesSmokeWindow ? componentWindow?.contentViewController?.view : popover.contentViewController?.view
    }
    private var hostIsShown: Bool { usesSmokeWindow ? componentWindow?.isVisible == true : popover.isShown }
    private var smokeDirectory: URL?
    private var smokeStages: [[String: Any]] = []
    private var syntheticPressEvidence: [String: Any] = [:]
    private var syntheticPressTarget: Int?
    private var syntheticPressLogStart = 0
    private var syntheticMouseUpMonitor: Any?
    private var pendingSmokeStage: Int?
    private var smokeCaptureScheduled = false
    private var smokeDidShowObserver: NSObjectProtocol?
    private var lastSmokeProgress: String?


    func start() {
        do {
            let arguments = ProcessInfo.processInfo.arguments
            smokeDirectory = try Self.smokeOutput(arguments: arguments)
            let hostFlags = arguments.filter { $0.hasPrefix("--uiux-smoke-host") }
            guard hostFlags.count <= 1,
                  hostFlags.allSatisfy({ $0 == "--uiux-smoke-host=window" || $0 == "--uiux-smoke-host=popover" }),
                  hostFlags.isEmpty || smokeDirectory != nil else {
                throw SmokeError(message: "Use --uiux-smoke-host=window or =popover with --uiux-smoke-output. The default host is popover.")
            }
            usesSmokeWindow = hostFlags.first == "--uiux-smoke-host=window"
            let appearanceFlags = arguments.filter { $0.hasPrefix("--uiux-appearance=") }
            guard appearanceFlags.count <= 1,
                  appearanceFlags.allSatisfy({ $0 == "--uiux-appearance=light" || $0 == "--uiux-appearance=dark" }) else {
                throw SmokeError(message: "Use --uiux-appearance=light or =dark.")
            }
            if let appearance = appearanceFlags.first {
                NSApp.appearance = NSAppearance(named: appearance.hasSuffix("dark") ? .darkAqua : .aqua)
                model.fixtureColorScheme = appearance.hasSuffix("dark") ? .dark : .light
            }
            let motionFlags = arguments.filter { $0 == "--uiux-reduce-motion" }
            guard motionFlags.count <= 1 else {
                throw SmokeError(message: "Pass --uiux-reduce-motion at most once.")
            }
            // The flag can only force the isolated renderer; the system value is
            // inherited otherwise.
            model.forceReduceMotion = !motionFlags.isEmpty
            let count = try UIUXFixtures.count(arguments: arguments)
            model.setCount(count)
            model.interaction.onPointerDown = { [weak self] id in
                guard let self else { return }
                let before = self.model.interaction.geometry
                self.model.injectArmedUpdate(trigger: "mouseDown", targetID: id)
                if self.syntheticPressTarget != nil {
                    self.syntheticPressEvidence["localMonitorTargetPRID"] = id.map { $0 as Any } ?? NSNull()
                    self.syntheticPressEvidence["pointerLockActiveDuringInjection"] = self.model.interaction.locks.contains(.pointer)
                    self.syntheticPressEvidence["measuredRectsEqualDuringInjection"] = before == self.model.interaction.geometry
                }
            }
            model.interaction.onMenuBegin = { [weak self] in
                self?.model.injectArmedUpdate(trigger: "menuBegin", targetID: nil)
            }
            model.interaction.onMenuTrackingChanged = { [weak self] tracking in self?.model.menuTrackingChanged(tracking) }
            model.interaction.onRequestClose = { [weak self] in
                guard let self else { return }
                if self.usesSmokeWindow { self.componentWindow?.performClose(nil) }
                else { self.statusBar?.hidePopover(self, restoringFocus: true) }
            }
        } catch {
            // This path remains a fixture launch; it must never fall through to production.
            model.parameterError = error.localizedDescription
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uiux-smoke-output") }) {
                failSmoke(error)
            }
        }
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.onOpenActivity = { [weak self] in self?.openActivity() }
        model.onOpenDigest = { [weak self] in self?.openDigest() }
        model.onCloseSettings = { [weak self] in self?.settingsWindow?.close() }
        model.onAuxiliaryRendered = { [weak self] token in self?.auxiliaryRendererAcknowledged(token) }
        popover.contentSize = NSSize(width: PanelMetrics.width, height: PanelMetrics.height)
        popover.behavior = .transient
        let panelController = NSHostingController(rootView:
            UIUXFixturePanel(model: model, interaction: model.interaction).environment(\.allowsRemoteAvatars, false)
                .preferredColorScheme(model.fixtureColorScheme)
        )
        if usesSmokeWindow {
            let window = UIUXSmokeComponentWindow(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width,
                                                                     height: PanelMetrics.height),
                                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "UIUX Component Smoke — Window Host"
            window.isReleasedWhenClosed = false
            window.contentViewController = panelController
            window.center()
            window.onClose = { [weak self] in
                self?.model.interaction.setPresented(false)
                self?.model.clearMenuTracking()
                self?.removeSyntheticMouseUpMonitor()
            }
            componentWindow = window
        } else {
            popover.contentViewController = panelController
        }
        // The smoke window owns its frame; the status-item path resizes the popover.
        model.interaction.bind(popover: usesSmokeWindow ? nil : popover)
        if smokeDirectory != nil && !usesSmokeWindow {
            smokeDidShowObserver = NotificationCenter.default.addObserver(
                forName: NSPopover.didShowNotification, object: popover, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.smokeProgress("popover didShow")
                    self.popover.contentViewController?.view.layoutSubtreeIfNeeded()
                    self.popover.contentViewController?.view.displayIfNeeded()
                    self.captureWhenRendererReady()
                    // Presentation completed: either a renderer acknowledgement permits capture,
                    // or report the exact missing state instead of waiting without another event.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let stage = self.pendingSmokeStage else { return }
                        self.captureWhenRendererReady()
                        if !self.smokeCaptureScheduled && !self.rendererReady(for: stage) {
                            self.failSmoke(SmokeError(message: "Popover presentation completed without a matching renderer acknowledgement. \(self.smokeState)"))
                        }
                    }
                }
            }
        }
        if !usesSmokeWindow {
            statusBar = StatusBarController(
                popover: popover,
                onWillShow: { [weak self] in
                    guard let self else { return }
                    self.model.interaction.prepareForPresentation(keyboard: self.statusBar?.openingFromKeyboard ?? false)
                    self.model.interaction.setPresented(true)
                },
                onWillClose: { [weak self] in
                    self?.model.interaction.setPresented(false)
                    self?.model.clearMenuTracking()
                    self?.removeSyntheticMouseUpMonitor()
                },
                onCheckForUpdates: { [weak self] in self?.model.record("checkForUpdates intent (fixture)") }
            )
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "UIUX Fixtures"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:
            UIUXFixtureControls(model: model, openPanel: { [weak self] in self?.openPanel() },
                                recordEvidence: { [weak self] in self?.recordEvidence() })
                .environment(\.allowsRemoteAvatars, false)
                .preferredColorScheme(model.fixtureColorScheme)
        )
        window.center()
        controls = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if smokeDirectory != nil {
            model.onRendererUpdated = { [weak self] in self?.captureWhenRendererReady() }
            DispatchQueue.main.async { [weak self] in self?.requestSmokeCapture(0) }
        }
    }

    func openPanel() {
        guard model.parameterError == nil else {
            model.record("Panel unavailable: fix the fixture launch parameters and relaunch.")
            return
        }
        if usesSmokeWindow {
            if componentWindow?.isVisible != true {
                model.interaction.prepareForPresentation(keyboard: false)
                model.interaction.setPresented(true)
                componentWindow?.makeKeyAndOrderFront(nil)
            }
            guard componentWindow?.isVisible == true else {
                failSmoke(SmokeError(message: "The explicit native component window could not be presented."))
            }
            return
        }
        // The real status item owns the anchor and invokes the same lifecycle callbacks.
        if !popover.isShown { statusBar?.togglePopover(self) }
        if smokeDirectory != nil && !model.interaction.isPresented && !popover.isShown {
            failSmoke(SmokeError(message: "The status-item popover show request returned without presentation. Real NSStatusItem/NSPopover acceptance is unavailable in this GUI session. Use the explicit --uiux-smoke-host=window option for component-only evidence. \(smokeState)"))
        }
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        settingsNavigation.tab = .general
        model.settingsDraft = model.savedSettingsDraft
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
            window.contentViewController = NSHostingController(rootView:
                UIUXFixtureSettings(model: model, navigation: settingsNavigation)
                    .environment(\.allowsRemoteAvatars, false)
                    .preferredColorScheme(model.fixtureColorScheme))
            window.setContentSize(NSSize(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height))
            window.center()
            settingsWindow = window
        }
        present(settingsWindow!)
        model.record("Settings window reused; page reset to general")
    }

    private func openActivity(batchID: String? = nil) {
        activityNavigation.digestBatchID = batchID
        if activityWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Activity"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 520, height: 420)
            window.contentViewController = NSHostingController(rootView:
                UIUXFixtureActivity(model: model, navigation: activityNavigation)
                    .environment(\.allowsRemoteAvatars, false)
                    .preferredColorScheme(model.fixtureColorScheme))
            window.setContentSize(NSSize(width: 560, height: 560))
            window.center()
            activityWindow = window
        }
        present(activityWindow!)
        model.record("Activity window reused; digest=\(batchID ?? "none")")
    }

    private func openDigest() {
        let payload: [AnyHashable: Any] = ["digest_batch_id": model.digestSelection]
        openActivity(batchID: NotificationManager.activityBatchID(from: payload))
        model.record("digest payload resolved with existing digest_batch_id key")
    }

    /// Optional evidence stays in the control window's in-memory log; no file is written.
    func recordEvidence() {
        let content = hostedView?.bounds.size ?? .zero
        let controlSize = controls?.contentView?.bounds.size ?? .zero
        let screen = hostedView?.window?.screen ?? controls?.screen
        model.record("Evidence: fixedNow=1700000000 count=\(model.count) scenario=\(model.scenario.rawValue) " +
                     "popover=\(popover.contentSize.width)x\(popover.contentSize.height) " +
                     "rendered=\(content.width)x\(content.height) controls=\(controlSize.width)x\(controlSize.height) " +
                     "scale=\(screen?.backingScaleFactor ?? 0) Hz=\(screen?.maximumFramesPerSecond ?? 0) " +
                     "OS=\(ProcessInfo.processInfo.operatingSystemVersionString) " +
                     "build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
    }

    private static func smokeOutput(arguments: [String]) throws -> URL? {
        let flags = arguments.filter { $0.hasPrefix("--uiux-smoke-output") }
        guard !flags.isEmpty else { return nil }
        let prefix = "--uiux-smoke-output="
        guard flags.count == 1, let flag = flags.first, flag.hasPrefix(prefix) else {
            throw SmokeError(message: "Use exactly one --uiux-smoke-output=<absolute directory>.")
        }
        let path = String(flag.dropFirst(prefix.count))
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw SmokeError(message: "Smoke output must be an absolute directory path.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["initial", "query", "restored", "event-press"] +
            ["settings-general", "settings-pullRequests", "settings-alerts", "settings-integrations", "settings-advanced",
             "activity-none", "activity-fixture-digest-6", "activity-fixture-digest-missing", "activity-none-reset"]
        for name in names.map({ "\($0).png" }) + ["evidence.json"] {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw SmokeError(message: "Refusing to overwrite smoke artifact: \(name)")
            }
        }
        return directory
    }

    /// Wait for committed renderer identity and measured row preferences before capture.
    private func requestSmokeCapture(_ stage: Int) {
        pendingSmokeStage = stage
        smokeProgress("request capture")
        openPanel()
        captureWhenRendererReady()
    }

    private func rendererReady(for stage: Int) -> Bool {
        guard let displayed = model.interaction.displayedSnapshot,
              model.renderedRevision == displayed.presentationRevision else { return false }
        if stage < 3, displayed.presentationRevision != model.snapshot.presentationRevision { return false }
        guard let ids = model.committedRowIDs else { return false }
        guard model.renderedRowIDs == ids else { return false }
        return ids.isEmpty ? model.renderedGeometryRowIDs.isEmpty
            : !model.renderedGeometryRowIDs.isDisjoint(with: Set(ids))
    }

    private var smokeState: String {
        "host=\(usesSmokeWindow ? "window-component" : "status-item-popover") stage=\(pendingSmokeStage.map(String.init) ?? "none") shown=\(hostIsShown) presented=\(model.interaction.isPresented) " +
        "sourceRevision=\(model.snapshot.presentationRevision) displayedRevision=\(model.interaction.displayedSnapshot.map { String($0.presentationRevision) } ?? "none") " +
        "rendererRevision=\(model.renderedRevision.map(String.init) ?? "none") sourceRows=\(model.projectionRowIDs.count) " +
        "rendererRows=\(model.renderedRowIDs?.count ?? -1) measuredRows=\(model.renderedGeometryRowIDs.count) " +
        "locks=\(model.interaction.locks.count)"
    }

    private func smokeProgress(_ event: String) {
        guard smokeDirectory != nil else { return }
        let state = smokeState
        guard state != lastSmokeProgress else { return }
        lastSmokeProgress = state
        FileHandle.standardError.write(Data("UIUX smoke [\(event)] \(state)\n".utf8))
    }

    private func captureWhenRendererReady() {
        smokeProgress("renderer/presentation update")
        guard let stage = pendingSmokeStage, !smokeCaptureScheduled,
              hostIsShown, rendererReady(for: stage) else { return }
        smokeCaptureScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.smokeCaptureScheduled = false
            guard self.pendingSmokeStage == stage, self.rendererReady(for: stage) else { return }
            self.pendingSmokeStage = nil
            self.runSmokeStage(stage)
        }
    }

    private func runSmokeStage(_ stage: Int) {
        do {
            // A background launch may lose its transient popover during activation.
            // Re-present for each explicit capture; this does not test focus stability.
            openPanel()
            guard let directory = smokeDirectory,
                  let view = hostedView,
                  let window = view.window, window.isVisible else {
                throw SmokeError(message: "The selected native fixture host is not visible.")
            }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            window.displayIfNeeded()
            let ids = model.projectionRowIDs
            if stage == 1, !ids.isEmpty {
                throw SmokeError(message: "The smoke query did not produce an empty projection.")
            }
            if stage == 2, let initialIDs = smokeStages.first?["projectionRowIDs"] as? [String], ids != initialIDs {
                throw SmokeError(message: "Restoring the query did not restore the initial row IDs.")
            }
            guard view.bounds.width > 0, view.bounds.height > 0,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw SmokeError(message: "Cannot allocate the hosted content bitmap.")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw SmokeError(message: "Cannot encode the hosted content bitmap.")
            }
            let name = ["initial", "query", "restored", "event-press"][stage]
            try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
            smokeStages.append([
                "stage": name, "query": model.searchText, "projectionRowIDs": ids,
                "rendererDisplayedIDs": model.renderedRowIDs ?? [],
                "rendererDisplayedRevision": model.renderedRevision.map { $0 as Any } ?? NSNull(),
                "sourceRevision": model.snapshot.presentationRevision,
                "rendererGeometryRowIDs": model.renderedGeometryRowIDs.sorted(),
                "popoverShown": popover.isShown, "windowVisible": window.isVisible,
                "hostKind": usesSmokeWindow ? "window-component" : "status-item-popover",
                "popoverContentRect": usesSmokeWindow ? NSNull() : Self.rect(NSRect(origin: .zero, size: popover.contentSize)) as Any,
                "hostedViewBounds": Self.rect(view.bounds),
                "hostedViewRectInWindow": Self.rect(view.convert(view.bounds, to: nil)),
                "windowFrame": Self.rect(window.frame),
                "windowContentRect": Self.rect(window.contentRect(forFrameRect: window.frame)),
                "bitmapPixels": [bitmap.pixelsWide, bitmap.pixelsHigh],
                "scale": window.backingScaleFactor, "artifact": "\(name).png", "actionLog": model.log
            ])
            switch stage {
            case 0:
                model.searchText = "uiux-smoke-no-matching-pr-6e99704d"
                model.record("smoke query changed in memory")
            case 1:
                model.searchText = ""
                model.record("smoke query restored in memory")
            case 2:
                try postSyntheticPress(view: view, window: window)
                return // Native mouseUp schedules stage 3 after AppKit finishes dispatch.
            default:
                if let target = syntheticPressTarget {
                    let entries = Array(model.log.dropFirst(syntheticPressLogStart))
                    let opens = entries.filter { $0.contains("openPR(") && !$0.contains("rejected") }
                    let matched = opens.filter { $0.contains("openPR(\(target))") }
                    syntheticPressEvidence["actionLogSinceArming"] = entries
                    syntheticPressEvidence["originalTargetOpenedExactlyOnce"] = matched.count == 1 && opens.count == 1
                    syntheticPressEvidence["refreshInjectedByLocalMonitor"] = entries.contains { $0.contains("during mouseDown") }
                    let monitorTarget = syntheticPressEvidence["localMonitorTargetPRID"] as? Int
                    syntheticPressEvidence["result"] = matched.count == 1 && opens.count == 1 && monitorTarget == target
                        ? "Observed original-target intent and matching monitor target"
                        : "UNVERIFIED: native event delivery/monitor acknowledgement incomplete; inspect event log"
                    guard monitorTarget == nil || monitorTarget == target else {
                        throw SmokeError(message: "Synthetic press geometry mismatch: expected PR \(target), local monitor resolved \(monitorTarget!).")
                    }
                    guard opens.isEmpty || (opens.count == 1 && matched.count == 1) else {
                        throw SmokeError(message: "Synthetic press activated a different or duplicate PR: expected \(target), actual \(opens).")
                    }
                }
                let target = model.snapshot.projection.sourcePRs.first?.id
                if let target {
                    let previousLogCount = model.log.count
                    model.actions.rowActions(target).onOpen()
                    guard model.log.count == previousLogCount + 1,
                          model.log.last?.contains("openPR(\(target))") == true else {
                        throw SmokeError(message: "The fixture row open intent was not recorded for its ID.")
                    }
                }
                smokeTargetID = target
                smokeCoordinatorEvidence = try model.scriptedCoordinatorEvidence()
                requestAuxiliarySmokeCapture(0)
                return
            }
            requestSmokeCapture(stage + 1)
        } catch {
            failSmoke(error)
        }
    }

    private var expectedAuxiliaryToken: String? {
        guard let index = auxiliarySmokeIndex else { return nil }
        if index < SettingsTab.allCases.count { return "settings-\(SettingsTab.allCases[index].rawValue)" }
        switch index - SettingsTab.allCases.count {
        case 0, 3: return "activity-none-request-\(activityNavigation.requestRevision)"
        case 1: return "activity-fixture-digest-6-request-\(activityNavigation.requestRevision)"
        default: return "activity-fixture-digest-missing-request-\(activityNavigation.requestRevision)"
        }
    }

    private func requestAuxiliarySmokeCapture(_ index: Int) {
        auxiliarySmokeIndex = index
        auxiliaryRenderToken = nil
        if index < SettingsTab.allCases.count {
            if index == 0 { openSettings() }
            settingsNavigation.tab = SettingsTab.allCases[index]
        } else {
            switch index - SettingsTab.allCases.count {
            case 0:
                let originalWindow = settingsWindow
                openSettings()
                guard settingsWindow === originalWindow, settingsNavigation.tab == .general else {
                    failSmoke(SmokeError(message: "Settings reuse did not reset navigation."))
                }
                model.record("smoke Settings reuse and navigation reset observed")
                openActivity()
            case 1:
                model.digestSelection = "fixture-digest-6"
                openDigest()
            case 2:
                model.digestSelection = "fixture-digest-missing"
                openDigest()
            default:
                let originalWindow = activityWindow
                openActivity()
                guard activityWindow === originalWindow, activityNavigation.digestBatchID == nil else {
                    failSmoke(SmokeError(message: "Ordinary Activity reuse did not clear digest navigation."))
                }
                model.record("smoke Activity reuse and digest reset observed")
            }
        }
    }

    private func auxiliaryRendererAcknowledged(_ token: String) {
        guard let index = auxiliarySmokeIndex, token == expectedAuxiliaryToken,
              !auxiliaryCaptureScheduled else { return }
        auxiliaryRenderToken = token
        auxiliaryCaptureScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.auxiliaryCaptureScheduled = false
            guard self.auxiliarySmokeIndex == index, self.auxiliaryRenderToken == self.expectedAuxiliaryToken else { return }
            do { try self.captureAuxiliarySmoke(index: index, token: token) }
            catch { self.failSmoke(error) }
        }
    }

    private func captureAuxiliarySmoke(index: Int, token: String) throws {
        let isSettings = index < SettingsTab.allCases.count
        guard let directory = smokeDirectory,
              let window = isSettings ? settingsWindow : activityWindow,
              let view = window.contentViewController?.view, window.isVisible,
              token == expectedAuxiliaryToken else {
            throw SmokeError(message: "Auxiliary smoke is missing the visible, acknowledged native content root.")
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let expectedSize = isSettings
            ? NSSize(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
            : NSSize(width: 560, height: 560)
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        guard abs(contentSize.width - expectedSize.width) < 1, abs(contentSize.height - expectedSize.height) < 1,
              abs(view.bounds.width - expectedSize.width) < 1, abs(view.bounds.height - expectedSize.height) < 1 else {
            throw SmokeError(message: "Auxiliary fixture baseline dimensions disagree: expected \(expectedSize), window \(contentSize), rendered \(view.bounds.size).")
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SmokeError(message: "Cannot allocate auxiliary content bitmap.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SmokeError(message: "Cannot encode auxiliary content bitmap.")
        }
        let stageName = isSettings ? token : "activity-\(activityNavigation.digestBatchID ?? "none")"
        let name = "\(stageName)\(index == SettingsTab.allCases.count + 3 ? "-reset" : "")"
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        smokeStages.append(["stage": name, "sourceToken": expectedAuxiliaryToken ?? "",
            "rendererToken": auxiliaryRenderToken ?? "", "windowNumber": window.windowNumber,
            "hostKind": "native-auxiliary-window", "hostedViewBounds": Self.rect(view.bounds),
            "windowContentRect": Self.rect(window.contentRect(forFrameRect: window.frame)),
            "contentMinimum": ["width": window.contentMinSize.width, "height": window.contentMinSize.height],
            "bitmapPixels": [bitmap.pixelsWide, bitmap.pixelsHigh], "scale": window.backingScaleFactor,
            "digestBatchID": activityNavigation.digestBatchID.map { $0 as Any } ?? NSNull(),
            "digestRequestRevision": activityNavigation.requestRevision,
            "artifact": "\(name).png", "actionLog": model.log])
        if index < SettingsTab.allCases.count + 3 { requestAuxiliarySmokeCapture(index + 1) }
        else { try finishSmoke(directory: directory) }
    }

    private func finishSmoke(directory: URL) throws {
        let evidence: [String: Any] = [
            "schemaVersion": 2, "mode": "DEBUG native hosted-view smoke",
            "hostKind": usesSmokeWindow ? "window-component" : "status-item-popover",
            "statusItemPopoverAcceptance": usesSmokeWindow ? "UNVERIFIED: explicit NSWindow component host; no real status-item anchor/popover acceptance is claimed." : "Real status-item popover host; inspect recorded observations.",
            "count": model.count, "fixedTime": UIUXFixtures.now.timeIntervalSince1970,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "appearance": NSApp.appearance?.name.rawValue ?? "system",
            "productionServices": "AppDelegate DEBUG early-return bypasses production setup; this smoke does not instrument absence of services.",
            "captureLimitation": "NSView cacheDisplay bitmaps of actual native hosted shared components; not composited window/Glass/wallpaper screenshots.",
            "interactionLimitation": "Synthetic AppKit input and in-memory actions do not establish physical mouse, system IME, or remote service success.",
            "rowOpenTargetID": smokeTargetID.map { $0 as Any } ?? NSNull(),
            "coordinatorScenarios": smokeCoordinatorEvidence, "syntheticAppKitPress": syntheticPressEvidence,
            "auxiliaryContent": "Settings five pages, Activity, older selected digest, expired digest, ordinary Activity reset; source tokens must match renderer layout acknowledgements.",
            "stages": smokeStages, "actionLog": model.log]
        let json = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent("evidence.json"), options: .atomic)
        if let smokeDidShowObserver { NotificationCenter.default.removeObserver(smokeDidShowObserver) }
        smokeDidShowObserver = nil
        NSApp.terminate(nil)
    }

    /// Queued NSEvents traverse AppKit and the same local monitor as production.
    private func postSyntheticPress(view: NSView, window: NSWindow) throws {
        let entries = model.interaction.geometry.compactMap { key, rect -> (id: PRPanelRowID, frame: CGRect)? in
            guard case let .row(id) = key, let viewport = model.interaction.geometry[.list],
                  rect.height > 0, rect.minY >= viewport.minY, rect.maxY <= viewport.maxY else { return nil }
            return (id, rect)
        }.sorted { lhs, rhs in
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            if lhs.id.section != rhs.id.section { return String(describing: lhs.id.section) < String(describing: rhs.id.section) }
            return lhs.id.prID < rhs.id.prID
        }
        guard !entries.isEmpty else {
            syntheticPressEvidence = ["result": "Skipped: no measured visible row target"]
            DispatchQueue.main.async { [weak self] in self?.requestSmokeCapture(3) }
            return
        }
        let entry = entries[min(1, entries.count - 1)]
        let id = entry.id
        let frame = entry.frame
        let local = CGPoint(x: frame.minX + 16,
                            y: view.isFlipped ? frame.midY : view.bounds.height - frame.midY)
        let point = view.convert(local, to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 2, clickCount: 1, pressure: 0) else {
            throw SmokeError(message: "Cannot construct native synthetic mouse events.")
        }
        syntheticPressTarget = id.prID
        syntheticPressLogStart = model.log.count
        model.raceUpdate = .reorder
        model.armPress()
        syntheticPressEvidence = ["proofKind": "In-process NSApp.postEvent mouseDown/mouseUp through AppKit; not system mouse/IME proof.",
                                  "targetPRID": id.prID, "rowRectBefore": Self.rect(frame),
                                  "eventLocationInWindow": ["x": point.x, "y": point.y]]
        removeSyntheticMouseUpMonitor()
        syntheticMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            self.removeSyntheticMouseUpMonitor()
            DispatchQueue.main.async { [weak self] in self?.requestSmokeCapture(3) }
            return event
        }
        NSApp.postEvent(down, atStart: false)
        DispatchQueue.main.async { NSApp.postEvent(up, atStart: false) }
    }

    private func removeSyntheticMouseUpMonitor() {
        if let syntheticMouseUpMonitor { NSEvent.removeMonitor(syntheticMouseUpMonitor) }
        syntheticMouseUpMonitor = nil
    }

    private static func rect(_ rect: NSRect) -> [String: Double] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
    }

    private func failSmoke(_ error: Error) -> Never {
        removeSyntheticMouseUpMonitor()
        if let smokeDidShowObserver { NotificationCenter.default.removeObserver(smokeDidShowObserver) }
        smokeDidShowObserver = nil
        let message = "UIUX fixture smoke failed: \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }

    private struct SmokeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// Explicit smoke-only host; closing it performs the same shared UI lifecycle cleanup.
@MainActor
private final class UIUXSmokeComponentWindow: NSWindow {
    var onClose: (() -> Void)?
    override func close() {
        onClose?()
        super.close()
    }
}

@MainActor
private final class UIUXFixtureModel: ObservableObject {
    enum Scenario: String, CaseIterable, Identifiable {
        case cached = "Cached", loading = "Loading", refresh = "Refresh", offline = "Offline"
        case partialFailure = "Partial failure", unauthorized = "Unauthorized", rateLimited = "Rate limited"
        case reorder = "Reorder", remove = "Remove pressed PR", facts = "Same ID facts and error", recover = "Recover"
        var id: String { rawValue }
    }

    enum RaceUpdate: String, CaseIterable, Identifiable {
        case reorder = "Reorder and update facts", remove = "Remove target", facts = "Update facts and error"
        var id: String { rawValue }
    }
    var raceUpdate = RaceUpdate.reorder { didSet { publish() } }
    private(set) var pressArmed = false
    private(set) var menuArmed = false

    func armPress() { pressArmed = true; record("armed refresh on next panel mouseDown") }
    func armMenu() { menuArmed = true; record("armed refresh on next menu begin") }

    func injectArmedUpdate(trigger: String, targetID: Int?) {
        if trigger == "mouseDown" {
            guard pressArmed else { return }
            pressArmed = false
        } else {
            guard menuArmed else { return }
            menuArmed = false
        }
        switch raceUpdate {
        case .reorder:
            snapshot.prList = UIUXFixtures.prList(count: count, reordered: true, changedFacts: true)
            snapshot.prList.error = FixtureError(message: "Fixture background update error; cached rows remain available.")
        case .remove:
            if let id = targetID ?? interaction.selectedRowID?.prID ?? snapshot.projection.sourcePRs.first?.id {
                remove(id)
                record("removed target PR \(id)")
            }
        case .facts:
            snapshot.prList = UIUXFixtures.prList(count: count, changedFacts: true)
            snapshot.prList.error = FixtureError(message: "Fixture background update error; cached rows remain available.")
        }
        rebuildProjection()
        record("injected \(raceUpdate.rawValue) during \(trigger)")
    }

    let interaction = PanelInteractionCoordinator()
    // Acknowledged by renderer updates and geometry preferences, not source changes.
    var renderedRowIDs: [String]?
    var renderedRevision: UInt64?
    var renderedGeometryRowIDs: Set<String> = []
    var onRendererUpdated: (() -> Void)?

    func rendererDidUpdate(geometry: [PanelGeometryID: CGRect]) {
        guard let displayed = interaction.displayedSnapshot else { return }
        renderedRevision = displayed.presentationRevision
        renderedRowIDs = rowIDs(in: displayed.projection)
        renderedGeometryRowIDs = Set(geometry.compactMap { key, _ in
            guard case let .row(id) = key else { return nil }
            return "\(id.section):\(id.prID)"
        })
        onRendererUpdated?()
    }
    var projectionRowIDs: [String] { rowIDs(in: snapshot.projection) }
    /// Rows the renderer should report for the committed snapshot, following
    /// the selected tab and its effective expansion rather than the full projection.
    var committedRowIDs: [String]? {
        interaction.displayedSnapshot.map { rowIDs(in: $0.projection) }
    }
    private func rowIDs(in projection: PRPanelProjection) -> [String] {
        interaction.selectedCategory.sections
            .filter { interaction.isSectionExpanded($0) }
            .flatMap { projection.displayedRowIDs(for: $0).map { "\($0.section):\($0.prID)" } }
    }
    var snapshot: PRPanelSnapshot
    var searchText = "" { didSet { rebuildProjection(reason: .userIntent) } }
    var forceReduceMotion = false { didSet { publish() } }
    var parameterError: String? { didSet { publish() } }
    private(set) var log: [String] = []
    private(set) var count = 20
    private(set) var scenario = Scenario.cached
    private var menuDepth = 0

    private func publish() {
        guard menuDepth == 0 else { return }
        objectWillChange.send()
    }

    func menuTrackingChanged(_ tracking: Bool) {
        menuDepth = tracking ? menuDepth + 1 : max(0, menuDepth - 1)
        if menuDepth == 0 { publish() }
    }

    func clearMenuTracking() { menuDepth = 0; publish() }
    var onOpenActivity: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenDigest: (() -> Void)?
    var onCloseSettings: (() -> Void)?
    var onAuxiliaryRendered: ((String) -> Void)?
    var fixtureColorScheme: ColorScheme?
    private var followUpSequence = 0

    func injectActivityEvent() {
        guard !activitySnapshot.actionItems.isEmpty, let prior = activitySnapshot.events.first else { return }
        followUpSequence += 1
        let id = "fixture-followup-\(followUpSequence)"
        let event = PRActivityEvent(id: id, identityKey: id, kind: prior.kind,
            prNodeID: prior.prNodeID, reference: prior.reference, actor: prior.actor,
            actorNodeID: prior.actorNodeID, isFromViewer: false, subjectIsViewer: true,
            isBotActor: false, containsDirectMention: false, occurredAt: UIUXFixtures.now,
            url: prior.url, revision: prior.revision, sourceChangeSequence: followUpSequence + 1)
        var updated = activitySnapshot
        updated.events.append(event)
        updated.actionItems.append(PRActionItem(id: "fixture-followup-item-\(followUpSequence)",
            prNodeID: prior.prNodeID, reference: prior.reference,
            reasons: [.authoredPRReviewFeedback], actionKinds: [.reviewFeedback], eventIDs: [id],
            revision: prior.revision, state: .open, createdAt: UIUXFixtures.now,
            stateUpdatedAt: UIUXFixtures.now, snoozedUntil: nil, coveredEventIDs: [],
            evidenceURLs: prior.url.map { [$0] } ?? []))
        activitySnapshot = updated
        snapshot.activityReminderCount = activityGroups.reduce(0) { $0 + $1.items.count }
        rebuildProjection(reason: .userIntent)
        auxiliaryIntent("new activity event \(id) in memory; prior covered events retained")
    }
    @Published var settingsDraft = SettingsDraft()
    var savedSettingsDraft = SettingsDraft()
    @Published var activitySnapshot = UIUXFixtures.activitySnapshot
    @Published var mutedIdentifiers: Set<String> = []
    @Published var digestSelection = "fixture-digest-0"
    @Published var auxiliaryFeedback = "Isolated fixture · no external actions"
    @Published var launchAtLogin = false
    @Published var jiraTest: JiraConnectionTestState = .idle
    @Published var slack: SlackSetupState = .idle
    @Published var browserClients = [BrowserClient(id: "fixture-browser", name: "Example Browser",
        version: "1.0", scopes: [], createdAt: UIUXFixtures.now, lastSeenAt: UIUXFixtures.now, revokedAt: nil)]

    func auxiliaryIntent(_ text: String) {
        auxiliaryFeedback = "Fixture action recorded: \(text)"
        record(auxiliaryFeedback)
    }

    var browserPresentation: BrowserIntegrationPresentation {
        BrowserIntegrationPresentation(bridgeStatus: BrowserBridgeStatus(state: .running(port: 49152)),
            pairedClients: browserClients, unhealthySlots: [], unhealthySurfaces: [],
            isGitHubPageConnected: false,
            installUserscriptURL: URL(string: "https://example.com/fixture.user.js"),
            browserTestURL: URL(string: "https://example.com/fixture-test"),
            workbenchURL: URL(string: "https://example.com/fixture-workbench"),
            agentInstallStatuses: [SkillAgent.claudeCode, .codex, .omp].map { agent in
                CodingAgentIntegrationInstallStatus(agent: agent,
                    skillDestination: URL(fileURLWithPath: "/fixture/\(agent.rawValue)/skills"),
                    mcpConfigDestination: URL(fileURLWithPath: "/fixture/\(agent.rawValue)/config.json"),
                    skillInstalled: false, mcpInstalled: false)
            }, agentInstallError: nil)
    }

    var browserActions: BrowserIntegrationActions {
        BrowserIntegrationActions(openURL: { self.auxiliaryIntent("openURL(\($0.absoluteString))") },
            revoke: { client in
                if let index = self.browserClients.firstIndex(where: { $0.id == client.id }) {
                    self.browserClients[index].revokedAt = UIUXFixtures.now
                }
                self.auxiliaryIntent("revoke(\(client.id)) in memory")
            }, installForAllAgents: { self.auxiliaryIntent("installForAllAgents intent; no files written") })
    }

    var settingsStatus: SettingsStatus {
        SettingsStatus(authState: .empty, launchAtLogin: launchAtLogin,
            isValidatingPAT: false, patErrorMessage: nil, currentVersionDescription: "Fixture 1.0",
            updateCheckButtonTitle: "Check for Updates", isUpdateBusy: false, isUpdateCheckInProgress: false,
            jiraConnectionState: .configured, jiraTest: jiraTest, slack: slack,
            isSlackDeliveryConfigured: false, slackWorkspaceName: "Example workspace", connectedSlackUserID: "",
            browser: browserPresentation)
    }

    var settingsActions: SettingsActions {
        SettingsActions(save: { draft in
            self.savedSettingsDraft = draft
            self.auxiliaryIntent("save settings in memory")
            self.onCloseSettings?()
        }, cancel: { self.auxiliaryIntent("cancel settings draft"); self.onCloseSettings?() },
            signOut: { self.auxiliaryIntent("signOut") }, signIn: { self.auxiliaryIntent("signIn") },
            switchToOAuth: { self.auxiliaryIntent("switchToOAuth") },
            clearPATError: { self.auxiliaryIntent("clearPATError") },
            checkForUpdates: { self.auxiliaryIntent("checkForUpdates") },
            resetOnboarding: { self.auxiliaryIntent("resetOnboarding") },
            clearCaches: { self.auxiliaryIntent("clearCaches") },
            resetJiraTest: { self.jiraTest = .idle; self.auxiliaryIntent("resetJiraTest") },
            sendSlackTest: { self.auxiliaryIntent("sendSlackTest") },
            switchToPAT: { _ in self.auxiliaryIntent("switchToPAT; fixture credential omitted") },
            setLaunchAtLogin: { self.launchAtLogin = $0; self.auxiliaryIntent("launchAtLogin(\($0)) in memory") },
            openJiraSetup: { self.auxiliaryIntent("openJiraSetup(\($0))") },
            testJira: { _ in self.jiraTest = .failure("Fixture action recorded; no connection attempted")
                self.auxiliaryIntent("testJira") },
            verifySlack: { _, _ in self.slack = .failure("Fixture action recorded; no connection attempted")
                self.auxiliaryIntent("verifySlack") }, browser: browserActions)
    }

    var activityGroups: [(pr: MonitoredPR, items: [PRActionItem])] {
        activitySnapshot.monitoredPRs.compactMap { pr in
            let items = activitySnapshot.actionItems.filter { $0.prNodeID == pr.prNodeID && $0.isActionable(now: UIUXFixtures.now) }
            return items.isEmpty ? nil : (pr: pr, items: items)
        }
    }

    private func updateActivityItems(_ ids: [String], state: PRActionState, duration: TimeInterval? = nil) {
        var updated = activitySnapshot
        for index in updated.actionItems.indices where ids.contains(updated.actionItems[index].id) {
            updated.actionItems[index].state = state
            updated.actionItems[index].stateUpdatedAt = UIUXFixtures.now
            updated.actionItems[index].coveredEventIDs = updated.actionItems[index].eventIDs
            updated.actionItems[index].snoozedUntil = duration.map { UIUXFixtures.now.addingTimeInterval($0) }
        }
        activitySnapshot = updated
        snapshot.activityReminderCount = activityGroups.reduce(0) { $0 + $1.items.count }
        rebuildProjection(reason: .userIntent)
    }

    var activityActions: PRActivityActions {
        PRActivityActions(observe: {
            self.activitySnapshot.lastPassAt = UIUXFixtures.now
            self.auxiliaryIntent("observe activity in memory")
        }, openURL: { self.auxiliaryIntent("activity openURL(\($0.absoluteString))") },
            markHandled: { self.updateActivityItems($0, state: .handled); self.auxiliaryIntent("dismiss reminder in memory") },
            snooze: { self.updateActivityItems($0, state: .snoozed, duration: $1); self.auxiliaryIntent("snooze \($1) seconds in memory") },
            setMuted: { pr, muted in
                if muted { self.mutedIdentifiers.insert(pr.reference.identifier) }
                else { self.mutedIdentifiers.remove(pr.reference.identifier) }
                self.auxiliaryIntent("mute(\(pr.reference.identifier),\(muted)) in memory")
            }, setTracked: { pr, tracked in
                if let index = self.activitySnapshot.monitoredPRs.firstIndex(where: { $0.prNodeID == pr.prNodeID }) {
                    self.activitySnapshot.monitoredPRs[index].isExplicitlyTracked = tracked
                }
                self.auxiliaryIntent("track(\(pr.reference.identifier),\(tracked)) in memory")
            }, retry: { self.auxiliaryIntent("retry digest(\($0.id)) intent; no delivery attempted") })
    }
    private var nextSavedViewID = 1

    init() {
        let list = UIUXFixtures.prList(count: 20)
        let pinned = Set(list.authoredPRs.prefix(1).map(\.pinIdentifier))
        let projection = PRPanelProjection.make(prList: list, searchText: "", selections: [:],
                                                pinnedIdentifiers: pinned, configuration: UIUXFixtures.configuration,
                                                now: UIUXFixtures.now)
        snapshot = PRPanelSnapshot(
            prList: list, projection: projection,
            rateLimitInfo: RateLimitInfo(limit: 5000, remaining: 4500, resetDate: UIUXFixtures.now.addingTimeInterval(1800)),
            restRateLimitInfo: RateLimitInfo(limit: 5000, remaining: 4900, resetDate: UIUXFixtures.now.addingTimeInterval(2400)),
            configuration: UIUXFixtures.configuration, jiraConnectionState: .configured,
            pinnedIdentifiers: pinned, activeFacetSelections: [:], activityReminderCount: 1,
            openingPRIDs: [], updatingBranchPRIDs: [], loadingHoverDetailPRIDs: [],
            facetChips: projection.facetChips, facetOptions: projection.facetOptions,
            labelSuggestions: projection.searchLabelSuggestions, savedViews: [], now: UIUXFixtures.now,
            rowExtensions: Dictionary(uniqueKeysWithValues: projection.sourcePRs.map { ($0.id, UIUXFixtures.extensionState(for: $0)) }),
            actionError: nil
        )
    }

    func record(_ intent: String) {
        log.append("\(log.count + 1). \(intent)")
        publish()
    }

    func setCount(_ value: Int) {
        count = value
        snapshot.prList = UIUXFixtures.prList(count: value)
        snapshot.pinnedIdentifiers = Set(snapshot.prList.authoredPRs.prefix(1).map(\.pinIdentifier))
        scenario = .cached
        rebuildProjection(reason: .userIntent)
        record("fixture count \(value)")
    }

    func apply(_ value: Scenario) {
        scenario = value
        snapshot.prList.isLoading = false
        snapshot.prList.error = nil
        snapshot.actionError = nil
        snapshot.rateLimitInfo = RateLimitInfo(limit: 5000, remaining: 4500, resetDate: UIUXFixtures.now.addingTimeInterval(1800))
        snapshot.restRateLimitInfo = RateLimitInfo(limit: 5000, remaining: 4900, resetDate: UIUXFixtures.now.addingTimeInterval(2400))
        switch value {
        case .cached, .recover:
            snapshot.prList = UIUXFixtures.prList(count: count)
            snapshot.jiraConnectionState = .configured
        case .loading, .refresh:
            snapshot.prList.isLoading = true
        case .offline:
            snapshot.prList.error = URLError(.notConnectedToInternet)
        case .partialFailure:
            snapshot.prList.error = FixtureError(message: "Fixture partial failure: cached PRs remain available.")
        case .unauthorized:
            snapshot.prList.error = FixtureError(message: "Fixture unauthorized: authentication refresh unavailable in this isolated host.")
            snapshot.jiraConnectionState = .unauthorized
        case .rateLimited:
            snapshot.rateLimitInfo = RateLimitInfo(limit: 5000, remaining: 0, resetDate: UIUXFixtures.now.addingTimeInterval(1800))
            snapshot.prList.error = FixtureError(message: "Fixture API rate limited until the fixed reset time.")
        case .reorder:
            snapshot.prList = UIUXFixtures.prList(count: count, reordered: true)
        case .remove:
            if let id = interaction.selectedRowID?.prID ?? snapshot.projection.sourcePRs.first?.id {
                remove(id)
                record("removed fixture PR \(id); selected row used when available")
            }
        case .facts:
            snapshot.prList = UIUXFixtures.prList(count: count, changedFacts: true)
            snapshot.prList.error = FixtureError(message: "Fixture same-ID update error; cached rows remain available.")
        }
        rebuildProjection(reason: .userIntent)
        record("scenario \(value.rawValue)")
    }

    private func remove(_ id: Int) {
        snapshot.prList.pullRequests.removeAll { $0.id == id }
        snapshot.prList.mentionedPullRequests.removeAll { $0.id == id }
        snapshot.prList.directMentionPullRequests.removeAll { $0.id == id }
        snapshot.prList.mergedPullRequests.removeAll { $0.id == id }
    }

    private func rebuildProjection(reason: PRPanelUpdateReason = .background) {
        let projection = PRPanelProjection.make(prList: snapshot.prList, searchText: searchText,
                                                selections: snapshot.activeFacetSelections,
                                                pinnedIdentifiers: snapshot.pinnedIdentifiers,
                                                configuration: snapshot.configuration, now: snapshot.now)
        snapshot.projection = projection
        snapshot.facetChips = projection.facetChips
        snapshot.facetOptions = projection.facetOptions
        snapshot.labelSuggestions = projection.searchLabelSuggestions
        snapshot.rowExtensions = Dictionary(uniqueKeysWithValues: projection.sourcePRs.map { ($0.id, UIUXFixtures.extensionState(for: $0)) })
        snapshot.presentationRevision &+= 1
        interaction.receive(snapshot: snapshot, reason: reason)
        publish()
    }

    /// Direct calls exercise the production coordinator/resolver, not AppKit input delivery.
    func scriptedCoordinatorEvidence() throws -> [String: Any] {
        let original = snapshot
        let originalQuery = searchText
        interaction.setPointerInsideList(false)
        snapshot.prList = UIUXFixtures.prList(count: count)
        rebuildProjection()
        interaction.receive(snapshot: snapshot, reason: .userIntent)
        let initialRevision = interaction.commitRevision
        let target = original.projection.sourcePRs.first?.id
        let captured = target.map { actions.rowActions($0) }
        let originalGeometry = interaction.geometry
        interaction.setInteraction(.pointer, active: true)
        interaction.setInteraction(.scroll, active: true)
        snapshot.prList = UIUXFixtures.prList(count: count, reordered: true, changedFacts: true)
        rebuildProjection()
        snapshot.prList.error = FixtureError(message: "Scripted fixture error changes banner and summary layout.")
        rebuildProjection()
        interaction.requestCommit(reason: .userIntent)
        guard interaction.commitRevision == initialRevision else {
            throw FixtureError(message: "Coordinator committed while pointer/scroll locks were active.")
        }
        interaction.setInteraction(.pointer, active: false)
        guard interaction.commitRevision == initialRevision else {
            throw FixtureError(message: "Pointer release bypassed the remaining scroll lock.")
        }
        interaction.setInteraction(.scroll, active: false)
        guard interaction.commitRevision > initialRevision,
              interaction.displayedSnapshot?.presentationRevision == snapshot.presentationRevision else {
            throw FixtureError(message: "Coordinator did not commit its latest snapshot after all locks ended.")
        }
        var rejectedRevision = false
        var rejectedMissing = false
        var readOnlyUsedLatestLink = false
        if let target {
            captured?.onCopyURL()
            readOnlyUsedLatestLink = log.last?.contains("copyURL(\(target))") == true && log.last?.contains("?fixture=updated") == true
            guard readOnlyUsedLatestLink else {
                throw FixtureError(message: "The shared read-only resolver did not use the current same-ID URL.")
            }
            captured?.onTogglePin?()
            rejectedRevision = snapshot.actionError == PRPanelActionError.changedRevision.message
            interaction.setInteraction(.composition, active: true)
            remove(target)
            rebuildProjection()
            captured?.onOpen()
            rejectedMissing = snapshot.actionError == PRPanelActionError.unavailable.message
            guard rejectedRevision, rejectedMissing, interaction.latestFacts[target] == nil else {
                throw FixtureError(message: "The shared resolver accepted a changed revision or removed ID.")
            }
            interaction.setInteraction(.composition, active: false)
        }
        let result: [String: Any] = [
            "proofKind": "Direct shared coordinator/resolver calls; no genuine pointer, menu, scroll or IME events.",
            "latestOnlyAndCombinedLocks": true,
            "changedRevisionRejected": target == nil ? "Skipped: empty fixture" : String(rejectedRevision),
            "missingIDRejected": target == nil ? "Skipped: empty fixture" : String(rejectedMissing),
            "readOnlyUsedLatestSameIDLink": target == nil ? "Skipped: empty fixture" : String(readOnlyUsedLatestLink),
            "geometrySampleCount": originalGeometry.count,
            "geometryLimitation": "Samples originate from the renderer; synchronous scripted calls do not prove on-screen target rect stability. Genuine input races require the UI tests."
        ]
        var restored = original
        restored.presentationRevision = snapshot.presentationRevision &+ 1
        snapshot = restored
        searchText = originalQuery
        interaction.requestCommit(reason: .userIntent)
        record("scripted coordinator/resolver scenarios completed; not UI event proof")
        return result
    }

    func openIntegration(_ name: String) {
        let hook: (() -> Void)?
        switch name {
        case "Activity": hook = onOpenActivity
        case "Settings": hook = onOpenSettings
        default: hook = onOpenDigest
        }
        guard let hook else {
            let message = "Fixture window callback missing: \(name)"
            snapshot.actionError = message
            record(message)
            return
        }
        record("open \(name) fixture integration")
        hook()
    }

    private func resolve(_ id: Int, intent: String, revision: String? = nil, write: Bool = false, perform: ((PullRequest) -> Void)? = nil) {
        switch PRPanelActionResolver.resolve(id: id, capturedHeadCommitOID: revision,
                                            requiresUnchangedHead: write, in: snapshot.prList) {
        case .success(let pr):
            record("\(intent)(\(id)) \(pr.url.absoluteString)")
            perform?(pr)
        case .failure(let error):
            snapshot.actionError = error.message
            record("rejected \(intent)(\(id)): \(error.message)")
        }
    }

    private func rowActions(_ id: Int) -> PRRowActions {
        guard let pr = snapshot.prList.allPRs.first(where: { $0.id == id }) else {
            return PRRowActions(onOpen: { self.resolve(id, intent: "openPR") },
                                onOpenJira: { _ in self.resolve(id, intent: "openJira") },
                                onCopyURL: { self.resolve(id, intent: "copyURL") })
        }
        let displayedPR = interaction.displayedSnapshot.flatMap { PRPanelActionResolver.latestPR(id: id, in: $0.prList) } ?? pr
        let revision = displayedPR.headCommitOid
        return PRRowActions(
            onOpen: { self.resolve(id, intent: "openPR") },
            onOpenJira: { _ in self.resolve(id, intent: "openJira", perform: { self.record("Jira intent \($0.jiraTicket ?? "unavailable")") }) },
            onCopyURL: { self.resolve(id, intent: "copyURL") },
            onMarkReviewCommentsRead: pr.unreadUnresolvedCount > 0 ? { self.markThreads(id, read: true, revision: revision) } : nil,
            onMarkReviewCommentsUnread: pr.readUnresolvedCount > 0 ? { self.markThreads(id, read: false, revision: revision) } : nil,
            onRerunFailedCI: pr.ciStatus == .failure ? { self.resolve(id, intent: "rerunFailedCI", revision: revision, write: true) } : nil,
            onUpdateBranchWithRebase: pr.baseNeedsUpdate == true ? { self.resolve(id, intent: "rebase", revision: revision, write: true) } : nil,
            onLoadHoverDetail: nil,
            onTogglePin: {
                self.resolve(id, intent: "togglePin", revision: revision, write: true, perform: { latest in
                    if self.snapshot.pinnedIdentifiers.contains(latest.pinIdentifier) {
                        self.snapshot.pinnedIdentifiers.remove(latest.pinIdentifier)
                    } else { self.snapshot.pinnedIdentifiers.insert(latest.pinIdentifier) }
                    self.rebuildProjection(reason: .userIntent)
                })
            },
            onAnalyzeCIFailure: pr.ciStatus == .failure ? { self.resolve(id, intent: "analyzeCI", revision: revision) } : nil,
            onOpenRawDiagnostics: { self.resolve(id, intent: "rawDiagnostics") },
            onRunSkill: { skill in self.resolve(id, intent: "runSkill:\(skill)", revision: revision, write: true) },
            onInstallBrowserUserscript: { self.resolve(id, intent: "installUserscript") },
            onOpenBrowserIntegrationSettings: { self.openIntegration("Settings") },
            showDetails: nil
        )
    }

    private func markThreads(_ id: Int, read: Bool, revision: String?) {
        resolve(id, intent: read ? "markRead" : "markUnread", revision: revision, write: true) { _ in
            func update(_ prs: inout [PullRequest]) {
                for index in prs.indices where prs[index].id == id {
                    for thread in prs[index].reviewThreads.indices { prs[index].reviewThreads[thread].isRead = read }
                }
            }
            update(&self.snapshot.prList.pullRequests)
            update(&self.snapshot.prList.mentionedPullRequests)
            update(&self.snapshot.prList.directMentionPullRequests)
            update(&self.snapshot.prList.mergedPullRequests)
            self.rebuildProjection(reason: .userIntent)
        }
    }

    var actions: PRPanelActions {
        PRPanelActions(
            refresh: { self.apply(.refresh) }, openActivity: { self.openIntegration("Activity") },
            openSettings: { self.openIntegration("Settings") }, rowActions: { self.rowActions($0) },
            toggleFacet: { field, key in
                var selected = self.snapshot.activeFacetSelections[field] ?? []
                if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
                self.snapshot.activeFacetSelections[field] = selected.isEmpty ? nil : selected
                self.rebuildProjection(reason: .userIntent)
            },
            clearFacetField: { self.snapshot.activeFacetSelections.removeValue(forKey: $0); self.rebuildProjection(reason: .userIntent) },
            clearAllFacets: { self.snapshot.activeFacetSelections = [:]; self.rebuildProjection(reason: .userIntent) },
            selectLabelSuggestion: { option in
                self.snapshot.activeFacetSelections[option.field, default: []].insert(option.key)
                self.searchText = ""
            },
            saveCurrentView: { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let suffix = String(format: "%012d", self.nextSavedViewID)
                self.nextSavedViewID += 1
                let view = SavedView(id: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!, name: trimmed,
                                     selections: self.snapshot.activeFacetSelections.map { ActiveFacetSelection(field: $0.key, selectedKeys: $0.value) },
                                     searchText: self.searchText)
                self.snapshot.savedViews.append(view)
                self.rebuildProjection(reason: .userIntent)
                self.record("saveView(\(trimmed)) in memory")
                return view
            },
            applySavedView: { view in
                self.snapshot.activeFacetSelections = Dictionary(uniqueKeysWithValues: view.selections.map { ($0.field, $0.selectedKeys) })
                self.searchText = view.searchText
            },
            renameSavedView: { view, name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let index = self.snapshot.savedViews.firstIndex(where: { $0.id == view.id }) else { return }
                self.snapshot.savedViews[index].name = trimmed
                self.rebuildProjection(reason: .userIntent)
                self.record("renameView(\(trimmed)) in memory")
            },
            deleteSavedView: { view in self.snapshot.savedViews.removeAll { $0.id == view.id }; self.rebuildProjection(reason: .userIntent); self.record("deleteView in memory") },
            dismissActionError: { self.snapshot.actionError = nil; self.rebuildProjection(reason: .userIntent) }
        )
    }

    private struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

@MainActor
private struct UIUXFixtureSettings: View {
    @ObservedObject var model: UIUXFixtureModel
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        SettingsContent(draft: $model.settingsDraft, status: model.settingsStatus,
            navigation: navigation, actions: model.settingsActions)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uiux-settings-content")
        .background(UIUXAuxiliaryRenderProbe(token: "settings-\(navigation.tab.rawValue)",
            acknowledged: { model.onAuxiliaryRendered?($0) }))
    }
}

@MainActor
private struct UIUXFixtureActivity: View {
    @ObservedObject var model: UIUXFixtureModel
    @ObservedObject var navigation: ActivityNavigation

    var body: some View {
        PRActivityContent(snapshot: model.activitySnapshot, groups: model.activityGroups,
            mutedIdentifiers: model.mutedIdentifiers, actions: model.activityActions, navigation: navigation)
        .accessibilityIdentifier("uiux-activity-content")
        .background(UIUXAuxiliaryRenderProbe(token: "activity-\(navigation.digestBatchID ?? "none")-request-\(navigation.requestRevision)",
            acknowledged: { model.onAuxiliaryRendered?($0) }))
    }
}

/// Preferences acknowledge actual layout of the shared rendering root.
private struct UIUXAuxiliaryRenderProbe: View {
    let token: String
    let acknowledged: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: UIUXAuxiliaryRenderKey.self,
                value: geometry.size.width > 0 && geometry.size.height > 0 ? token : "")
        }
        .onPreferenceChange(UIUXAuxiliaryRenderKey.self) { value in
            if !value.isEmpty { acknowledged(value) }
        }
    }
}

private struct UIUXAuxiliaryRenderKey: PreferenceKey {
    static var defaultValue = ""
    static func reduce(value: inout String, nextValue: () -> String) { value = nextValue() }
}

@MainActor
private struct UIUXFixturePanel: View {
    @ObservedObject var model: UIUXFixtureModel
    @ObservedObject var interaction: PanelInteractionCoordinator
    var body: some View {
        if let error = model.parameterError {
            Text(error).padding().frame(width: PanelMetrics.width, height: PanelMetrics.height)
        } else {
            PRPanelView(snapshot: model.snapshot, actions: model.actions, searchText: $model.searchText,
                        interaction: model.interaction, onboardingManager: nil)
                .environment(\.panelReduceMotionOverride, model.forceReduceMotion ? true : nil)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("uiux-panel")
                .onAppear { model.rendererDidUpdate(geometry: interaction.geometry) }
                .onChange(of: interaction.commitRevision) { _ in model.rendererDidUpdate(geometry: interaction.geometry) }
                .onPreferenceChange(PanelGeometryPreferenceKey.self) { samples in
                    interaction.recordGeometrySamples(samples)
                    model.rendererDidUpdate(geometry: interaction.geometry)
                }
        }
    }
}

@MainActor
private struct UIUXFixtureControls: View {
    @ObservedObject var model: UIUXFixtureModel
    let openPanel: () -> Void
    let recordEvidence: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Isolated DEBUG fixture · fixed time 1700000000").font(.headline)
            if let error = model.parameterError {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("uiux-parameter-error")
            }
            HStack {
                Button("Open panel", action: openPanel).accessibilityIdentifier("uiux-open-panel")
                    .disabled(model.parameterError != nil)
                Picker("PR count", selection: Binding(get: { model.count }, set: { model.setCount($0) })) {
                    ForEach(UIUXFixtures.supportedCounts, id: \.self) { Text("\($0)").tag($0) }
                }.disabled(model.parameterError != nil)
                Button("Record evidence", action: recordEvidence)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], alignment: .leading) {
                ForEach(UIUXFixtureModel.Scenario.allCases) { scenario in
                    Button(scenario.rawValue) { model.apply(scenario) }
                        .disabled(model.parameterError != nil)
                        .accessibilityIdentifier("uiux-scenario-\(scenario.rawValue)")
                }
            }
            Picker("Armed update", selection: $model.raceUpdate) {
                ForEach(UIUXFixtureModel.RaceUpdate.allCases) { Text($0.rawValue).tag($0) }
            }.accessibilityIdentifier("uiux-race-update")
            HStack {
                Button("Arm refresh on next press") { model.armPress() }
                    .accessibilityIdentifier("uiux-arm-press")
                Button("Arm refresh on menu open") { model.armMenu() }
                    .accessibilityIdentifier("uiux-arm-menu")
            }
            Text("Press armed: \(model.pressArmed ? "yes" : "no"); menu armed: \(model.menuArmed ? "yes" : "no")")
                .accessibilityIdentifier("uiux-armed-state")
            HStack {
                Button("Activity") { model.openIntegration("Activity") }.accessibilityIdentifier("uiux-open-activity")
                Button("Settings") { model.openIntegration("Settings") }.accessibilityIdentifier("uiux-open-settings")
                Button("Open digest") { model.openIntegration("Open digest") }.accessibilityIdentifier("uiux-open-digest")
                Button("New activity event") { model.injectActivityEvent() }
                    .accessibilityIdentifier("uiux-new-activity-event")
            }
            Picker("Digest context", selection: $model.digestSelection) {
                Text("Current · all reminder states").tag("fixture-digest-0")
                Text("Older than five batches").tag("fixture-digest-6")
                Text("Expired / missing").tag("fixture-digest-missing")
            }.accessibilityIdentifier("uiux-digest-selection")
            Text("Shared Activity and Settings components use in-memory data only. Every effect records a fixture intent. Refresh stays loading until Recover or another scenario is selected.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Fixture action intents (no external actions)").font(.subheadline)
            Text(model.auxiliaryFeedback).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("uiux-auxiliary-feedback")
            ScrollView {
                Text(model.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("uiux-action-log")
            }
        }
        .padding().frame(minWidth: 520, minHeight: 520)
    }
}
#endif
