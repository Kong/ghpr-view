import XCTest
import CoreGraphics

/// Runs only the isolated DEBUG host. Intent log assertions never imply a remote action occurred.
final class MacOSUIUXTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(count: Int = 20, appearance: String? = nil, reduceMotion: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-uiux", "--uiux-count=\(count)"]
        if let appearance { app.launchArguments.append("--uiux-appearance=\(appearance)") }
        if reduceMotion { app.launchArguments.append("--uiux-reduce-motion") }
        // Pin the language so translated settings labels stay the strings these tests match.
        app.launchArguments.append(contentsOf: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
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

    private func logText(_ app: XCUIApplication) -> String {
        let log = element(app, "uiux-action-log")
        return (log.value as? String) ?? log.label
    }

    private func occurrences(_ app: XCUIApplication, of text: String) -> Int {
        logText(app).components(separatedBy: text).count - 1
    }

    /// Waits for the animated panel height to settle before frames are measured.
    private func waitForHeight(_ element: XCUIElement, _ height: CGFloat,
                               file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in abs(element.frame.height - height) <= 2 }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected height \(height), measured \(element.frame.height)",
                       file: file, line: line)
    }

    /// The hosted panel stops at the visible screen budget, so a short runner
    /// cannot reach the 680-point expanded height.
    private func waitForStableHeight(_ element: XCUIElement) -> CGFloat {
        let deadline = Date().addingTimeInterval(5)
        var last = element.frame.height
        var stableSince: Date?
        while Date() < deadline {
            let height = element.frame.height
            if abs(height - last) <= 0.5 {
                if stableSince == nil { stableSince = Date() }
                if let stableSince, Date().timeIntervalSince(stableSince) >= 0.3, height > 1 {
                    return height
                }
            } else {
                last = height
                stableSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.frame.height
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
        let panel = element(app, "uiux-panel")
        element(app, "panel-search").hover()
        let restingImage = XCTAttachment(screenshot: panel.screenshot())
        restingImage.name = "Glass resting baseline"
        restingImage.lifetime = .keepAlways
        add(restingImage)
        element(app, "panel-category-all").hover()
        XCTAssertEqual(element(app, "panel-category-all").value as? String, "Selected")
        let selectedHover = XCTAttachment(screenshot: panel.screenshot())
        selectedHover.name = "Light glass selected hover"
        selectedHover.lifetime = .keepAlways
        add(selectedHover)
        element(app, "panel-category-reviews").hover()
        XCTAssertEqual(element(app, "panel-category-all").value as? String, "Selected", "Hover must not select a category")
        XCTAssertTrue(element(app, "pr-row-1001").exists)
        let hoverImage = XCTAttachment(screenshot: panel.screenshot())
        hoverImage.name = "Glass category hover"
        hoverImage.lifetime = .keepAlways
        add(hoverImage)

        element(app, "panel-category-reviews").click()
        XCTAssertTrue(element(app, "pr-row-1002").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "pr-row-1001").waitForNonExistence(timeout: 3), "My PRs must leave the visible list in Reviews")

        element(app, "panel-category-mentions").click()
        XCTAssertTrue(element(app, "pr-row-1003").waitForExistence(timeout: 5))
        let mentionedHeading = element(app, "panel-section-mentioned")
        XCTAssertTrue(mentionedHeading.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["panel-section-mentioned"].exists,
                       "Mention headings are fixed labels, not collapse buttons")
        XCTAssertFalse(app.buttons["Direct Mentions"].exists, "A mention heading must not expose a button role")
        XCTAssertTrue(element(app, "pr-row-1002").waitForNonExistence(timeout: 3))

        element(app, "panel-category-myPRs").click()
        XCTAssertTrue(element(app, "pr-row-1001").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "pr-row-1002").waitForNonExistence(timeout: 3))

        element(app, "panel-category-all").click()
        XCTAssertEqual(element(app, "panel-category-all").value as? String, "Selected")
        XCTAssertTrue(element(app, "pr-row-1001").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "pr-row-1002").waitForExistence(timeout: 5))
    }

    func testSectionCollapseCommitsOnOneClickAndStaysScopedToAll() {
        let app = launch(count: 20)
        defer { app.terminate() }
        open(app)
        let panel = element(app, "uiux-panel")
        let authoredHeader = element(app, "panel-section-authored")
        let authoredRow = element(app, "pr-row-1006")
        XCTAssertTrue(authoredHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(authoredRow.waitForExistence(timeout: 5))
        XCTAssertEqual(authoredHeader.value as? String, "Expanded")

        authoredHeader.click()
        XCTAssertTrue(authoredRow.waitForNonExistence(timeout: 5),
                      "One header click must collapse the section without another input")
        XCTAssertEqual(authoredHeader.value as? String, "Collapsed")
        XCTAssertTrue(element(app, "pr-row-1002").exists, "Other All sections stay visible")

        authoredHeader.click()
        XCTAssertTrue(authoredRow.waitForExistence(timeout: 5), "A second click restores the rows")
        XCTAssertEqual(authoredHeader.value as? String, "Expanded")

        authoredHeader.click()
        XCTAssertTrue(authoredRow.waitForNonExistence(timeout: 5))

        // A scoped tab is independent of All's remembered collapse.
        element(app, "panel-category-myPRs").click()
        XCTAssertTrue(authoredRow.waitForExistence(timeout: 5), "My PRs keeps its rows visible")
        XCTAssertTrue(element(app, "panel-section-authored").waitForNonExistence(timeout: 3),
                      "My PRs must not repeat its section title")
        authoredRow.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.1)).click()
        expectLog(app, "openPR(1006)")

        element(app, "panel-category-reviews").click()
        XCTAssertTrue(element(app, "pr-row-1002").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "panel-section-reviewRequests").waitForNonExistence(timeout: 3),
                      "Reviews must not repeat its section title")

        element(app, "panel-category-all").click()
        XCTAssertTrue(authoredRow.waitForNonExistence(timeout: 5), "All keeps the collapsed section after tab switches")
        XCTAssertEqual(element(app, "panel-section-authored").value as? String, "Collapsed")
        let collapsed = XCTAttachment(screenshot: panel.screenshot())
        collapsed.name = "All with collapsed authored section"
        collapsed.lifetime = .keepAlways
        add(collapsed)
    }

    func testMentionsKeepsFixedSeparateHeadings() {
        let app = launch(count: 20)
        defer { app.terminate() }
        open(app)
        // Narrow both mention roles to a few rows so both fixed headings and a
        // direct-mention row are visible together.
        element(app, "panel-category-mentions").click()
        app.typeKey("f", modifierFlags: .command)
        app.typeText("example/project")
        let panel = element(app, "uiux-panel")
        let mentionedHeading = element(app, "panel-section-mentioned")
        let directHeading = element(app, "panel-section-directMentions")
        XCTAssertTrue(mentionedHeading.waitForExistence(timeout: 5))
        XCTAssertTrue(directHeading.waitForExistence(timeout: 5))
        XCTAssertNotEqual(mentionedHeading.frame.minY, directHeading.frame.minY,
                          "Mention roles keep separate fixed headings")
        XCTAssertFalse(app.buttons["panel-section-mentioned"].exists,
                       "Mention headings are fixed labels, not collapse buttons")
        XCTAssertFalse(app.buttons["panel-section-directMentions"].exists)
        let directRow = element(app, "pr-row-1004")
        XCTAssertTrue(directRow.waitForExistence(timeout: 5))
        directHeading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(directRow.exists, "A fixed mention heading cannot collapse its rows")
        let mentions = XCTAttachment(screenshot: panel.screenshot())
        mentions.name = "Mentions fixed headings"
        mentions.lifetime = .keepAlways
        add(mentions)
    }
    func testCachedPanelRendersInNativePopover() {
        let app = launch(count: 3, appearance: "dark")
        defer { app.terminate() }
        open(app)
        XCTAssertTrue(element(app, "pr-row-1001").waitForExistence(timeout: 5))
        let panel = element(app, "uiux-panel")
        XCTAssertEqual(panel.frame.width, 400, accuracy: 2)
        XCTAssertEqual(panel.frame.height, 500, accuracy: 2)
        let attachment = XCTAttachment(screenshot: panel.screenshot())
        attachment.name = "Dark glass resting foreground"
        attachment.lifetime = .keepAlways
        add(attachment)
        for id in ["panel-category-all", "panel-category-reviews", "panel-filter", "panel-refresh"] {
            element(app, id).hover()
            let hover = XCTAttachment(screenshot: panel.screenshot())
            hover.name = "Dark glass hover \(id)"
            hover.lifetime = .keepAlways
            add(hover)
        }
        element(app, "panel-category-reviews").press(forDuration: 0.2)
        XCTAssertEqual(element(app, "panel-category-reviews").value as? String, "Selected")
        XCTAssertTrue(element(app, "pr-row-1002").waitForExistence(timeout: 3))
        element(app, "panel-search").hover()
        let selected = XCTAttachment(screenshot: panel.screenshot())
        selected.name = "Dark glass selected foreground"
        selected.lifetime = .keepAlways
        add(selected)
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
        element(app, "pr-row-1001").coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.1)).click()
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

    func testFilterFirstClickRevealsContentAndPreservesListViewport() {
        let app = launch(count: 20)
        defer { app.terminate() }
        open(app)
        let panel = element(app, "uiux-panel")
        let list = element(app, "panel-pr-list")
        let filter = element(app, "panel-filter")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        waitForHeight(panel, 500)
        XCTAssertEqual(panel.frame.width, 400, accuracy: 2)
        XCTAssertEqual(filter.value as? String, "Collapsed")
        XCTAssertFalse(element(app, "panel-facet-panel").exists)

        let firstRow = element(app, "pr-row-1001")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let footer = element(app, "panel-quota")
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertTrue(footer.isHittable, "The footer starts inside the popover")
        let rowIDBefore = firstRow.identifier
        let listHeightBefore = list.frame.height
        let rowOffsetBefore = firstRow.frame.minY - list.frame.minY
        let topBefore = panel.frame.minY
        let footerBefore = footer.frame.minY

        filter.click()
        let facet = element(app, "panel-facet-panel")
        XCTAssertTrue(facet.waitForExistence(timeout: 5), "One click alone must reveal the filter section")
        let saveView = app.buttons["Save View"]
        XCTAssertTrue(saveView.waitForExistence(timeout: 5), "The revealed section must be the real filter panel")
        let clickable = NSPredicate { _, _ in saveView.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: clickable, object: nil)], timeout: 5), .completed,
                       "Revealed filters must accept clicks without a tab switch")
        XCTAssertEqual(filter.value as? String, "Expanded")

        let expanded = waitForStableHeight(panel)
        let growth = expanded - 500
        XCTAssertGreaterThan(growth, 0, "The host must grow when the screen has room below the collapsed panel")
        XCTAssertLessThanOrEqual(growth, 180.5, "Growth cannot exceed the filter section")
        XCTAssertLessThanOrEqual(expanded, 682, "The expanded panel never exceeds 680")
        let listShrink = 180 - growth
        XCTAssertEqual(list.frame.height, listHeightBefore - listShrink, accuracy: 2,
                       "Only a short screen may compress the list, and only by the growth the screen refused")
        XCTAssertEqual(firstRow.frame.minY - list.frame.minY, rowOffsetBefore, accuracy: 2,
                       "The list must keep its scroll position")
        XCTAssertEqual(panel.frame.minY, topBefore, accuracy: 2, "Only the bottom edge may move")
        XCTAssertEqual(footer.frame.minY - footerBefore, growth, accuracy: 2, "The footer moves down by the actual growth")
        XCTAssertTrue(footer.isHittable, "The host window must grow, or the footer would be clipped")
        XCTAssertEqual(element(app, "pr-row-1001").identifier, rowIDBefore)
        XCTAssertEqual(element(app, "panel-category-all").value as? String, "Selected")

        filter.click()
        XCTAssertTrue(facet.waitForNonExistence(timeout: 5), "The second click must remove the filter section")
        XCTAssertEqual(filter.value as? String, "Collapsed")
        waitForHeight(panel, 500)
        XCTAssertEqual(list.frame.height, listHeightBefore, accuracy: 2)
        XCTAssertEqual(firstRow.frame.minY - list.frame.minY, rowOffsetBefore, accuracy: 2)
        XCTAssertEqual(footer.frame.minY, footerBefore, accuracy: 2)
        XCTAssertEqual(panel.frame.minY, topBefore, accuracy: 2)

        filter.click()
        XCTAssertTrue(facet.waitForExistence(timeout: 5))
        XCTAssertEqual(waitForStableHeight(panel), expanded, accuracy: 2)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        open(app)
        XCTAssertTrue(element(app, "panel-facet-panel").waitForExistence(timeout: 5),
                      "Reopening must keep the expanded filters without a tab switch")
        XCTAssertEqual(element(app, "panel-filter").value as? String, "Expanded")
        XCTAssertEqual(waitForStableHeight(element(app, "uiux-panel")), expanded, accuracy: 2)
    }

    func testRefreshClickAndShortcutShowBusyStateAndRecover() {
        let app = launch(count: 20)
        defer { app.terminate() }
        open(app)
        let refresh = element(app, "panel-refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertEqual(refresh.value as? String, "Ready")
        XCTAssertTrue(refresh.isEnabled)
        app.typeKey("f", modifierFlags: .command)
        app.typeText("jira:DEMO-42")
        XCTAssertTrue(element(app, "pr-row-1001").waitForExistence(timeout: 5))
        let before = occurrences(app, of: "scenario Refresh")

        refresh.click()
        expectLog(app, "scenario Refresh")
        XCTAssertEqual(occurrences(app, of: "scenario Refresh"), before + 1,
                       "One click must produce exactly one refresh")
        XCTAssertEqual(refresh.value as? String, "Refreshing")
        XCTAssertFalse(refresh.isEnabled, "The control stays disabled while the request is busy")
        XCTAssertEqual(element(app, "panel-search").value as? String, "jira:DEMO-42")
        XCTAssertEqual(element(app, "panel-category-all").value as? String, "Selected")
        XCTAssertTrue(element(app, "pr-row-1001").exists, "Refreshing keeps the rows that were already visible")

        // First Escape clears the query, the next closes the panel.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "uiux-panel").waitForNonExistence(timeout: 5))
        app.windows["UIUX Fixtures"].buttons["uiux-scenario-Recover"].click()
        open(app)
        let reopened = element(app, "panel-refresh")
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        let ready = NSPredicate { _, _ in (reopened.value as? String) == "Ready" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5), .completed,
                       "Recovered data must re-enable the control")
        XCTAssertTrue(reopened.isEnabled)

        let afterRecover = occurrences(app, of: "scenario Refresh")
        app.typeKey("r", modifierFlags: .command)
        let shortcut = NSPredicate { _, _ in self.occurrences(app, of: "scenario Refresh") == afterRecover + 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shortcut, object: nil)], timeout: 5), .completed,
                       "Cmd-R must produce exactly one refresh")
    }

    func testFilterAndRefreshRespectReducedMotion() {
        let app = launch(count: 20, reduceMotion: true)
        defer { app.terminate() }
        open(app)
        let panel = element(app, "uiux-panel")
        let filter = element(app, "panel-filter")
        waitForHeight(panel, 500)
        XCTAssertEqual(filter.value as? String, "Collapsed")

        filter.click()
        let facet = element(app, "panel-facet-panel")
        XCTAssertTrue(facet.waitForExistence(timeout: 5))
        let immediate = panel.frame.height
        let settled = waitForStableHeight(panel)
        XCTAssertEqual(immediate, settled, accuracy: 2, "Reduced motion applies the final layout")
        XCTAssertGreaterThan(settled, 502, "The final layout must include the opened filters")
        XCTAssertLessThanOrEqual(settled, 682, "The final layout stays within 680 or the screen budget")

        filter.click()
        XCTAssertTrue(facet.waitForNonExistence(timeout: 5))
        XCTAssertEqual(panel.frame.height, 500, accuracy: 2)

        element(app, "panel-refresh").click()
        expectLog(app, "scenario Refresh")
        XCTAssertEqual(element(app, "panel-refresh").value as? String, "Refreshing")
        XCTAssertFalse(element(app, "panel-refresh").isEnabled)
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
            ("general", "settings-launch-at-login"), ("pullRequests", "settings-show-drafts"),
            ("alerts", "settings-enable-notifications"), ("integrations", "settings-jira"),
            ("advanced", "settings-show-onboarding-again")
        ]
        for (page, landmark) in pages {
            selectSettingsPage(app, rawValue: page)
            XCTAssertTrue(element(app, landmark).waitForExistence(timeout: 5), "Missing settings landmark \(landmark)")
        }
        selectSettingsPage(app, rawValue: "general")
        for (_, landmark) in pages.dropFirst() {
            app.typeKey(.downArrow, modifierFlags: [])
            XCTAssertTrue(element(app, landmark).waitForExistence(timeout: 5),
                "Native sidebar arrow navigation must select \(landmark)")
            XCTAssertTrue(element(app, "settings-sidebar").exists)
        }
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(element(app, "settings-jira").waitForExistence(timeout: 5))
        controls.buttons["uiux-open-settings"].click()
        XCTAssertEqual(app.windows.matching(identifier: "Settings").count, 1)
        XCTAssertTrue(element(app, "settings-launch-at-login").waitForExistence(timeout: 5))
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
        let showDrafts = element(app, "settings-show-drafts")
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

        // Enter through the padding, where compact glyph-sized trackers used to miss.
        for (id, explanation) in [
            ("pr-cmux-1001", "This PR is currently open as a tab in cmux."),
            ("pr-ci-1001", "1 workflows passed"),
            ("pr-jira-1001", jiraExplanation)
        ] {
            let target = element(app, id)
            XCTAssertTrue(target.exists)
            let edgeOffset: CGFloat = id == "pr-cmux-1001" ? -3 : 2
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: edgeOffset)).hover()
            XCTAssertTrue(panel.staticTexts[explanation].waitForExistence(timeout: 2), "Hover near the upper edge of \(id)")
            let image = XCTAttachment(screenshot: panel.screenshot())
            image.name = "Hover target \(id)"
            image.lifetime = .keepAlways
            add(image)
        }

        element(app, "panel-category-mentions").click()
        let conflict = element(app, "pr-conflict-1003")
        XCTAssertTrue(conflict.waitForExistence(timeout: 3))
        conflict.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -3)).hover()
        XCTAssertTrue(panel.staticTexts["This PR has conflicts with the base branch."].waitForExistence(timeout: 2))
        let conflictImage = XCTAttachment(screenshot: panel.screenshot())
        conflictImage.name = "Conflict tooltip in native popover"
        conflictImage.lifetime = .keepAlways
        add(conflictImage)
        element(app, "pr-jira-1003").hover()
        XCTAssertTrue(panel.staticTexts[jiraExplanation].waitForExistence(timeout: 2))
        element(app, "panel-category-all").click()
        element(app, "panel-search").hover()
        XCTAssertTrue(panel.staticTexts[jiraExplanation].waitForNonExistence(timeout: 2))

        // Native UI closure covers a visible tooltip; pending cancellation is also
        // exercised without XCTest's per-action idle wait by HoverTooltipLifecycleTests.
        jira.hover()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "Escape must close the panel while hovering")
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
        element(app, "pr-row-1001").coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.1)).rightClick()
        XCTAssertTrue(app.menuItems["Details…"].waitForExistence(timeout: 3))
        app.menuItems["Details…"].click()
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "pr-row-1001").exists)
        app.typeKey(.return, modifierFlags: [])
        expectLog(app, "openPR(1001)")
    }
}
