import XCTest
import CoreGraphics

/// Runs only the isolated DEBUG host. Intent log assertions never imply a remote action occurred.
final class MacOSUIUXTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(count: Int = 20) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-uiux", "--uiux-count=\(count)"]
        app.launch()
        XCTAssertTrue(app.windows["UIUX Fixtures"].waitForExistence(timeout: 8))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func open(_ app: XCUIApplication) {
        app.windows["UIUX Fixtures"].buttons["uiux-open-panel"].click()
        XCTAssertTrue(element(app, "panel-search").waitForExistence(timeout: 5))
    }

    private func expectLog(_ app: XCUIApplication, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let log = element(app, "uiux-action-log")
        let predicate = NSPredicate { _, _ in
            log.label.contains(text) || (log.value as? String)?.contains(text) == true
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: log)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected fixture intent: \(text)", file: file, line: line)
    }


    func testCategorySwitchFiltersRowsAndAllRestoresGroups() {
        let app = launch(count: 20)
        defer { app.terminate() }
        open(app)
        let quota = element(app, "panel-quota")
        XCTAssertTrue(quota.waitForExistence(timeout: 5))
        XCTAssertTrue(quota.label.contains("Lowest API quota: GraphQL 4,500/5,000"))
        XCTAssertTrue(quota.label.contains("GraphQL: 4500 remaining of 5000"))
        XCTAssertTrue(quota.label.contains("REST: 4900 remaining of 5000"), "Accessible quota description retains both pools")
        XCTAssertFalse(element(app, "panel-quota-graphql").exists)

        element(app, "panel-category-reviews").click()
        XCTAssertTrue(element(app, "pr-row-1002").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "pr-row-1001").waitForNonExistence(timeout: 3), "My PRs must leave the visible list in Reviews")

        element(app, "panel-category-mentions").click()
        XCTAssertTrue(element(app, "pr-row-1003").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Direct Mentions"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "pr-row-1002").waitForNonExistence(timeout: 3))

        element(app, "panel-category-myPRs").click()
        XCTAssertTrue(element(app, "pr-row-1001").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "pr-row-1002").waitForNonExistence(timeout: 3))

        element(app, "panel-category-all").click()
        XCTAssertEqual(element(app, "panel-category-all").value as? String, "Selected")
    }
    func testCachedPanelRendersInNativePopover() {
        let app = launch(count: 3)
        defer { app.terminate() }
        open(app)
        XCTAssertTrue(element(app, "pr-row-1001").waitForExistence(timeout: 5))
        let panel = element(app, "uiux-panel")
        XCTAssertEqual(panel.frame.width, 400, accuracy: 2)
        XCTAssertEqual(panel.frame.height, 500, accuracy: 2)
        let attachment = XCTAttachment(screenshot: panel.screenshot())
        attachment.name = "UIUX native panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testKeyboardSearchRefreshAndEscapeSequence() {
        let app = launch(count: 3)
        defer { app.terminate() }
        open(app)
        app.typeKey("f", modifierFlags: .command)
        app.typeText("jira:DEMO-42")
        XCTAssertEqual(element(app, "panel-search").value as? String, "jira:DEMO-42")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertEqual(element(app, "panel-search").value as? String, "jira:DEMO-42", "Refresh must preserve the query")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(element(app, "panel-search").value as? String, "")
        XCTAssertTrue(element(app, "uiux-panel").exists, "First Escape clears only the query")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element(app, "uiux-panel").exists, "Next Escape closes the panel")
    }

    func testSearchReturnDoesNotOpenPRAndListReturnDoes() {
        let app = launch(count: 3)
        defer { app.terminate() }
        open(app)
        app.typeKey("f", modifierFlags: .command)
        app.typeText("DEMO-42")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(element(app, "uiux-action-log").label.contains("openPR("))
        app.typeKey(.escape, modifierFlags: [])
        // Tab leaves the native field editor; Down transfers navigation to the list.
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        expectLog(app, "openPR(")
    }

    func testPRJiraAndFocusedDetailsAreSeparateTargets() {
        let app = launch(count: 3)
        defer { app.terminate() }
        open(app)
        element(app, "pr-jira-1001").click()
        expectLog(app, "openJira(1001)")
        XCTAssertFalse(element(app, "uiux-action-log").label.contains("openPR("))
        element(app, "pr-details-1001").click()
        // Focused details must accept Escape and return to the shared row.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "pr-row-1001").exists)
        XCTAssertFalse(element(app, "uiux-action-log").label.contains("openPR("))
        element(app, "pr-row-1001").click()
        expectLog(app, "openPR(1001)")
    }

    func testNoResultAndErrorRecoverWithoutLosingQuery() {
        let app = launch(count: 3)
        defer { app.terminate() }
        open(app)
        app.typeKey("f", modifierFlags: .command)
        app.typeText("uiux-no-result-6e99704d")
        XCTAssertFalse(element(app, "pr-row-1001").exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "pr-row-1001").waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.windows["UIUX Fixtures"].buttons["uiux-scenario-Offline"].click()
        open(app)
        XCTAssertTrue(element(app, "pr-row-1001").exists, "Offline keeps cached data")
        app.typeKey(.escape, modifierFlags: [])
        app.windows["UIUX Fixtures"].buttons["uiux-scenario-Recover"].click()
        open(app)
        XCTAssertTrue(element(app, "pr-row-1001").exists)
    }

    func testPressRaceKeepsOriginalIDAndChildDoesNotOpenPR() {
        let app = launch(count: 20)
        defer { app.terminate() }
        app.windows["UIUX Fixtures"].buttons["uiux-arm-press"].click()
        open(app)
        let jira = element(app, "pr-jira-1001")
        XCTAssertTrue(jira.waitForExistence(timeout: 5))
        jira.press(forDuration: 0.2)
        expectLog(app, "during mouseDown")
        expectLog(app, "openJira(1001)")
        XCTAssertFalse(element(app, "uiux-action-log").label.contains("openPR("))
    }

    func testMenuRaceRejectsOldRevisionAndPreservesMenu() {
        let app = launch(count: 20)
        defer { app.terminate() }
        app.windows["UIUX Fixtures"].buttons["uiux-arm-menu"].click()
        open(app)
        element(app, "pr-row-1001").rightClick()
        // A real NSMenu begin notification injects the update, with no timer.
        let copy = app.menuItems["Copy URL"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Background publication must preserve an open menu")
        let pin = app.menuItems["Unpin"]
        XCTAssertTrue(pin.exists)
        pin.click()
        expectLog(app, "during menuBegin")
        expectLog(app, "PR changed. Reopen the menu and try again.")
    }

    func testPinRetainsRowAndVisibleAnchor() {
        let app = launch(count: 20)
        defer { app.terminate() }
        open(app)
        let row = element(app, "pr-row-1001")
        let before = row.frame
        row.rightClick()
        app.menuItems["Unpin"].click()
        expectLog(app, "togglePin(1001)")
        XCTAssertTrue(row.exists)
        XCTAssertEqual(row.frame.minY, before.minY, accuracy: 2, "Pin mutation preserves the first visible anchor")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        expectLog(app, "openPR(")
    }

    func testRemovalDuringPressCannotOpenNeighbor() {
        let app = launch(count: 20)
        defer { app.terminate() }
        let controls = app.windows["UIUX Fixtures"]
        element(app, "uiux-race-update").click()
        app.menuItems["Remove target"].click()
        controls.buttons["uiux-arm-press"].click()
        open(app)
        element(app, "pr-row-1001").press(forDuration: 0.2)
        expectLog(app, "removed target PR 1001")
        let logElement = element(app, "uiux-action-log")
        let log = (logElement.value as? String) ?? logElement.label
        let successfulOpens = log.components(separatedBy: "\n").filter {
            $0.contains("openPR(") && !$0.contains("rejected")
        }
        XCTAssertTrue(successfulOpens.isEmpty, "A removed pressed slot cannot activate a neighboring PR; rejected intents are allowed")
    }

    private func selectSettingsPage(_ app: XCUIApplication, rawValue: String) {
        let sidebar = element(app, "settings-sidebar")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Settings navigation stays visible")
        let page = element(app, "settings-page-\(rawValue)")
        XCTAssertTrue(page.waitForExistence(timeout: 3), "Missing settings page: \(rawValue)")
        page.click()
    }

    func testSettingsFivePagesAndWindowReuseResetNavigation() {
        let app = launch(count: 3)
        defer { app.terminate() }
        let controls = app.windows["UIUX Fixtures"]
        controls.buttons["uiux-open-settings"].click()
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
        let settingsContent = element(app, "uiux-settings-content")
        XCTAssertTrue(settingsContent.waitForExistence(timeout: 5))
        XCTAssertEqual(settingsContent.frame.width, 620, accuracy: 2)
        XCTAssertEqual(settingsContent.frame.height, 620, accuracy: 2)
        let pages: [(String, String)] = [
            ("general", "Launch at login"), ("pullRequests", "Show draft PRs"),
            ("alerts", "Enable notifications"), ("integrations", "Jira"),
            ("advanced", "Show onboarding again")
        ]
        for (page, landmark) in pages {
            selectSettingsPage(app, rawValue: page)
            XCTAssertTrue(app.windows["Settings"].descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", landmark)).firstMatch.waitForExistence(timeout: 5))
        }
        selectSettingsPage(app, rawValue: "general")
        for (_, landmark) in pages.dropFirst() {
            app.typeKey(.downArrow, modifierFlags: [])
            XCTAssertTrue(app.windows["Settings"].descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", landmark)).firstMatch.waitForExistence(timeout: 5),
                "Native sidebar arrow navigation must select \(landmark)")
            XCTAssertTrue(element(app, "settings-sidebar").exists)
        }
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(app.windows["Settings"].staticTexts["Jira"].waitForExistence(timeout: 5))
        controls.buttons["uiux-open-settings"].click()
        XCTAssertEqual(app.windows.matching(identifier: "Settings").count, 1)
        XCTAssertTrue(app.windows["Settings"].descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Launch at login")).firstMatch.waitForExistence(timeout: 5))
        expectLog(app, "Settings window reused; page reset to general")
        app.windows["Settings"].buttons["Cancel"].click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.windows["Settings"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    }

    func testSettingsDraftSurvivesNavigationAndHonorsCancelSave() {
        let app = launch(count: 3)
        defer { app.terminate() }
        let controls = app.windows["UIUX Fixtures"]
        let settings = app.windows["Settings"]
        controls.buttons["uiux-open-settings"].click()
        selectSettingsPage(app, rawValue: "pullRequests")
        let showDrafts = settings.checkBoxes["Show draft PRs"]
        XCTAssertTrue(showDrafts.waitForExistence(timeout: 5))
        let savedValue = showDrafts.value as? String
        XCTAssertNotNil(savedValue, "The checkbox must expose its saved value")
        showDrafts.click()
        let editedValue = showDrafts.value as? String
        XCTAssertNotEqual(editedValue, savedValue, "Editing must change the draft")
        selectSettingsPage(app, rawValue: "general")
        selectSettingsPage(app, rawValue: "pullRequests")
        XCTAssertEqual(showDrafts.value as? String, editedValue, "Page switches must preserve the same draft")
        settings.buttons["Cancel"].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        controls.buttons["uiux-open-settings"].click()
        selectSettingsPage(app, rawValue: "pullRequests")
        XCTAssertEqual(showDrafts.value as? String, savedValue, "Cancel must discard the draft")
        showDrafts.click()
        settings.buttons["Save"].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        controls.buttons["uiux-open-settings"].click()
        selectSettingsPage(app, rawValue: "pullRequests")
        XCTAssertEqual(showDrafts.value as? String, editedValue, "Save must retain the edited value after reopening")
    }

    func testCustomHoverTooltipsPreserveRowAndChildActions() {
        let app = launch(count: 3)
        defer { app.terminate() }
        open(app)
        let panel = element(app, "uiux-panel")
        let jira = element(app, "pr-jira-1001")
        let jiraExplanation = "This is the Jira ticket linked to this PR."
        let jiraTip = panel.staticTexts[jiraExplanation]
        jira.hover()
        XCTAssertTrue(jiraTip.waitForExistence(timeout: 3), "The custom overlay must appear inside the panel")
        let attachment = XCTAttachment(screenshot: panel.screenshot())
        attachment.name = "Jira custom tooltip in native popover"
        attachment.lifetime = .keepAlways
        add(attachment)
        element(app, "panel-search").hover()
        XCTAssertTrue(jiraTip.waitForNonExistence(timeout: 3), "Leaving Jira must hide its tooltip")
        panel.staticTexts["Draft"].hover()
        let draftTip = panel.staticTexts["This PR is a draft and not ready for review."]
        XCTAssertTrue(draftTip.waitForExistence(timeout: 3), "Passive badges must retain custom tooltips")
        jira.click()
        expectLog(app, "openJira(1001)")
        let log = element(app, "uiux-action-log")
        let logText = (log.value as? String) ?? log.label
        XCTAssertEqual(logText.components(separatedBy: "openJira(1001)").count - 1, 1, "The child action must run exactly once")
        XCTAssertFalse(logText.contains("openPR("), "Jira must not activate the row")
        element(app, "pr-row-1001").coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.1)).click()
        expectLog(app, "openPR(1001)")
        element(app, "panel-search").hover()
        XCTAssertTrue(draftTip.waitForNonExistence(timeout: 3))

        // Post native events together so Escape interrupts the 500ms hover delay,
        // without XCTest's per-action idle wait allowing the tooltip to appear first.
        let point = CGPoint(x: jira.frame.midX, y: jira.frame.midY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "Escape must close the panel during pending hover")
        let lateTip = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.staticTexts[jiraExplanation])
        lateTip.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [lateTip], timeout: 0.8), .completed, "No tooltip may arrive after closure")
        open(app)
        XCTAssertFalse(panel.staticTexts[jiraExplanation].exists, "Reopening must not revive a stale tooltip")
        XCTAssertFalse(panel.staticTexts["This PR is a draft and not ready for review."].exists)
    }

    func testActivityDigestOlderThanFiveExpiredAndOrdinaryWindowReuse() {
        let app = launch(count: 3)
        defer { app.terminate() }
        let controls = app.windows["UIUX Fixtures"]
        controls.buttons["uiux-open-activity"].click()
        XCTAssertTrue(app.windows["Activity"].waitForExistence(timeout: 5))
        let activityContent = element(app, "uiux-activity-content")
        XCTAssertTrue(activityContent.waitForExistence(timeout: 5))
        XCTAssertEqual(activityContent.frame.width, 560, accuracy: 2)
        XCTAssertEqual(activityContent.frame.height, 560, accuracy: 2)
        XCTAssertFalse(element(app, "activity-digest-context").exists)
        let selection = element(app, "uiux-digest-selection")
        selection.click()
        app.menuItems["Older than five batches"].click()
        controls.buttons["uiux-open-digest"].click()
        XCTAssertTrue(element(app, "activity-digest-context").waitForExistence(timeout: 5))
        expectLog(app, "digest=fixture-digest-6")
        selection.click()
        app.menuItems["Expired / missing"].click()
        controls.buttons["uiux-open-digest"].click()
        XCTAssertTrue(app.staticTexts["This notification is no longer available in local history"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(identifier: "Activity").count, 1)
        XCTAssertTrue(app.windows["Activity"].buttons["Observe now"].exists)
        controls.buttons["uiux-open-activity"].click()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "activity-digest-context"))
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
        XCTAssertEqual(app.windows.matching(identifier: "Activity").count, 1)
        expectLog(app, "digest=none")
    }

    func testActivityDismissCommitsInMemoryAndNewEventRestoresReminder() {
        let app = launch(count: 3)
        defer { app.terminate() }
        let controls = app.windows["UIUX Fixtures"]
        controls.buttons["uiux-open-activity"].click()
        let dismiss = app.windows["Activity"].buttons["Dismiss reminder"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.click()
        expectLog(app, "dismiss reminder in memory")
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dismiss)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        controls.buttons["uiux-new-activity-event"].click()
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        expectLog(app, "new activity event")
    }

    func testFocusedDetailsEscapeRestoresOriginForKeyboardReturn() {
        let app = launch(count: 3)
        defer { app.terminate() }
        open(app)
        element(app, "pr-row-1001").rightClick()
        XCTAssertTrue(app.menuItems["Details…"].waitForExistence(timeout: 3))
        app.menuItems["Details…"].click()
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "pr-row-1001").exists)
        app.typeKey(.return, modifierFlags: [])
        expectLog(app, "openPR(1001)")
    }
}
