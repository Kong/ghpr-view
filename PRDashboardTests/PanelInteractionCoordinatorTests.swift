import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PRDashboard

@MainActor
final class PanelInteractionCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCategorySelectionLimitsKeyboardRowsAndAllRestoresEveryRole() {
        let authored = pr(1)
        let review = pr(2, category: .reviewRequest)
        let mention = pr(3)
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([authored, review], mentions: [mention], directMentions: [mention]), reason: .userIntent)

        coordinator.selectCategory(.reviews)
        coordinator.moveSelection(1)
        XCTAssertEqual(coordinator.selectedRowID?.section, .reviewRequests)

        coordinator.selectCategory(.mentions)
        XCTAssertNil(coordinator.selectedRowID, "A row hidden by a category switch must lose keyboard selection")
        coordinator.moveSelection(1)
        XCTAssertEqual(coordinator.selectedRowID?.section, .mentioned)
        coordinator.moveSelection(1)
        XCTAssertEqual(coordinator.selectedRowID?.section, .directMentions)

        coordinator.selectCategory(.myPRs)
        coordinator.moveSelection(1)
        XCTAssertEqual(coordinator.selectedRowID?.section, .authored)
        coordinator.selectCategory(.all)
        coordinator.moveSelection(1)
        XCTAssertEqual(coordinator.selectedRowID?.section, .reviewRequests)
    }

    func testEveryLockDefersUserIntentAndOnlyLatestSnapshotCommits() {
        for firstLock in [InteractionLock.pointer, .menu, .scroll, .composition] {
            let coordinator = PanelInteractionCoordinator()
            coordinator.receive(snapshot: snapshot([pr(1)]))
            coordinator.setInteraction(firstLock, active: true)
            coordinator.receive(snapshot: snapshot([pr(2)]), reason: .userIntent)
            coordinator.receive(snapshot: snapshot([pr(3)]))
            coordinator.requestCommit(reason: .userIntent)
            XCTAssertEqual(ids(coordinator), [1], "Active \(firstLock) must gate user intent")
            XCTAssertEqual(coordinator.pendingStructure?.displayedRowIDs(for: .authored).map(\.prID), [3])
            coordinator.setInteraction(firstLock, active: false)
            XCTAssertEqual(ids(coordinator), [3])
            XCTAssertNil(coordinator.pendingStructure)
        }
    }

    func testNestedMenuEndCannotBypassPointerScrollOrComposition() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.beginMenuTracking()
        coordinator.beginMenuTracking()
        coordinator.setInteraction(.pointer, active: true)
        coordinator.setInteraction(.scroll, active: true)
        coordinator.setInteraction(.composition, active: true)
        coordinator.receive(snapshot: snapshot([pr(2)]), reason: .userIntent)
        coordinator.endMenuTracking()
        XCTAssertTrue(coordinator.locks.contains(.menu))
        coordinator.endMenuTracking()
        XCTAssertFalse(coordinator.locks.contains(.menu))
        XCTAssertEqual(ids(coordinator), [1])
        coordinator.setInteraction(.pointer, active: false)
        coordinator.setInteraction(.scroll, active: false)
        XCTAssertEqual(ids(coordinator), [1])
        coordinator.setInteraction(.composition, active: false)
        XCTAssertEqual(ids(coordinator), [2])
    }

    func testBackgroundHoverDefersOrderButUserIntentStillWaitsForScroll() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.setPresented(true)
        coordinator.setPointerInsideList(true)
        coordinator.receive(snapshot: snapshot([pr(2)]))
        XCTAssertTrue(coordinator.hasPendingOrder)
        XCTAssertEqual(ids(coordinator), [1])
        coordinator.setInteraction(.scroll, active: true)
        coordinator.requestCommit(reason: .userIntent)
        XCTAssertEqual(ids(coordinator), [1])
        coordinator.setInteraction(.scroll, active: false)
        XCTAssertEqual(ids(coordinator), [2], "Explicit intent may commit while hovering once every lock ends")
        coordinator.receive(snapshot: snapshot([pr(3)]))
        XCTAssertEqual(ids(coordinator), [2])
        coordinator.setPointerInsideList(false)
        XCTAssertEqual(ids(coordinator), [3])
        coordinator.setPresented(false)
    }

    func testSameIDFactsAdvanceWithoutChangingLockedLayoutOrControlGeometry() {
        let coordinator = PanelInteractionCoordinator()
        let row = rowID(1)
        let old = pr(1)
        coordinator.receive(snapshot: snapshot([old]))
        let frames: [PanelGeometryID: CGRect] = [
            .list: CGRect(x: 0, y: 40, width: 400, height: 420),
            .row(row): CGRect(x: 8, y: 100, width: 384, height: 80),
            .control(row, "jira"): CGRect(x: 48, y: 146, width: 72, height: 28),
            .summary: CGRect(x: 8, y: 40, width: 384, height: 36),
            .error: CGRect(x: 8, y: 76, width: 384, height: 24)
        ]
        coordinator.recordGeometry(frames)
        coordinator.setInteraction(.pointer, active: true)
        var changed = pr(1, title: String(repeating: "Long changed title ", count: 12))
        changed.ciStatus = .failure
        var next = snapshot([changed, pr(2)])
        next.actionError = "A new error must not displace the held target"
        coordinator.receive(snapshot: next)
        XCTAssertEqual(coordinator.latestFacts[1]?.title, changed.title)
        XCTAssertEqual(coordinator.latestFacts[1]?.ciStatus, .failure)
        XCTAssertEqual(coordinator.displayedStructure?.pr(for: row)?.title, old.title)
        XCTAssertEqual(coordinator.displayedSnapshot?.projection.summaryCIFailing, 0)
        XCTAssertEqual(coordinator.latestSnapshot?.projection.summaryCIFailing, 1)
        XCTAssertNil(coordinator.displayedSnapshot?.actionError)
        XCTAssertEqual(ids(coordinator).count, 1, "Displayed section count must stay tied to displayed rows")
        coordinator.recordGeometry([.row(row): CGRect(x: 8, y: 120, width: 384, height: 160)])
        XCTAssertEqual(coordinator.protectedGeometry, frames)
        coordinator.setInteraction(.pointer, active: false)
        XCTAssertEqual(coordinator.displayedStructure?.pr(for: row)?.title, changed.title)
        XCTAssertEqual(coordinator.displayedSnapshot?.actionError, next.actionError)
        XCTAssertTrue(coordinator.protectedGeometry.isEmpty)
    }

    func testVanishedSlotCannotActivateOrFallThroughToNeighbor() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1), pr(2)]))
        var opened: [Int] = []
        coordinator.onOpenRow = { opened.append($0) }
        coordinator.setInteraction(.pointer, active: true)
        coordinator.receive(snapshot: snapshot([pr(2)]))
        XCTAssertEqual(Set(ids(coordinator)), [1, 2])
        XCTAssertFalse(coordinator.isAvailable(rowID(1)))
        coordinator.activate(rowID(1))
        XCTAssertTrue(opened.isEmpty)
        coordinator.activate(rowID(2))
        XCTAssertEqual(opened, [2])
        coordinator.setInteraction(.pointer, active: false)
        XCTAssertEqual(ids(coordinator), [2])
    }

    func testPinRetainsIdentitySelectionAndFirstVisibleAnchor() {
        let coordinator = PanelInteractionCoordinator()
        let first = pr(1, age: 20)
        let second = pr(2, age: 10)
        coordinator.receive(snapshot: snapshot([first, second]))
        coordinator.select(rowID(1))
        coordinator.recordGeometry([
            .list: CGRect(x: 0, y: 0, width: 400, height: 400),
            .row(rowID(1)): CGRect(x: 0, y: 0, width: 400, height: 80),
            .row(rowID(2)): CGRect(x: 0, y: 80, width: 400, height: 80)
        ])
        coordinator.receive(snapshot: snapshot([first, second], pins: [first.pinIdentifier]), reason: .userIntent)
        XCTAssertEqual(ids(coordinator), [1, 2])
        XCTAssertEqual(coordinator.selectedRowID, rowID(1))
        XCTAssertEqual(coordinator.scrollAnchor, .row(rowID(1)))
        coordinator.receive(snapshot: snapshot([first, second]), reason: .userIntent)
        XCTAssertEqual(ids(coordinator), [2, 1])
        XCTAssertEqual(coordinator.selectedRowID, rowID(1))
        XCTAssertEqual(coordinator.scrollAnchor, .row(rowID(1)))
    }

    func testSelectionAndAnchorFallBackNextThenPreviousThenHeader() {
        let coordinator = PanelInteractionCoordinator()
        let prs = [pr(1, age: 0), pr(2, age: 10), pr(3, age: 20)]
        coordinator.receive(snapshot: snapshot(prs))
        coordinator.select(rowID(2))
        coordinator.recordGeometry([
            .list: CGRect(x: 0, y: 0, width: 400, height: 400),
            .row(rowID(2)): CGRect(x: 0, y: 0, width: 400, height: 80)
        ])
        coordinator.receive(snapshot: snapshot([prs[0], prs[2]]))
        XCTAssertEqual(coordinator.selectedRowID, rowID(3))
        XCTAssertEqual(coordinator.scrollAnchor, .row(rowID(3)))
        coordinator.receive(snapshot: snapshot([prs[0]]))
        XCTAssertEqual(coordinator.selectedRowID, rowID(1))
        XCTAssertEqual(coordinator.scrollAnchor, .row(rowID(1)))
        coordinator.receive(snapshot: snapshot([]))
        XCTAssertNil(coordinator.selectedRowID)
        XCTAssertEqual(coordinator.focusTarget, .section(.authored))
        XCTAssertEqual(coordinator.scrollAnchor, .section(.authored))
    }

    func testCollapseMovesFocusToHeaderAndDefersExpansionChangeUntilUnlock() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.select(rowID(1))
        coordinator.setInteraction(.pointer, active: true)
        coordinator.toggleSection(.authored)
        XCTAssertTrue(coordinator.expandedSections.contains(.authored))
        XCTAssertNil(coordinator.selectedRowID)
        XCTAssertEqual(coordinator.focusTarget, .section(.authored))
        coordinator.setInteraction(.pointer, active: false)
        XCTAssertFalse(coordinator.expandedSections.contains(.authored))
    }

    func testMouseUpReleaseRunsAfterAppKitDispatchTurn() async {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.beginPointerInteraction(at: .zero)
        coordinator.receive(snapshot: snapshot([pr(2)]), reason: .userIntent)
        coordinator.endPointerInteractionAfterDispatch()
        XCTAssertTrue(coordinator.locks.contains(.pointer))
        XCTAssertEqual(ids(coordinator), [1], "Button activation must finish before structural publication")
        await nextMainTurn()
        XCTAssertFalse(coordinator.locks.contains(.pointer))
        XCTAssertEqual(ids(coordinator), [2])
    }

    func testFacetToggleCommitsAfterItsOwnPressWithoutChangingRows() async {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.setPresented(true)
        coordinator.beginPointerInteraction(at: .zero)
        coordinator.toggleFacetPanel()
        XCTAssertFalse(coordinator.displayedFacetPanel, "The filter section must wait for the press to finish")
        await nextMainTurn()
        XCTAssertFalse(coordinator.locks.contains(.pointer))
        XCTAssertTrue(coordinator.displayedFacetPanel, "One click must reveal the filter section with no other input")
        XCTAssertEqual(ids(coordinator), [1], "Revealing filters must not change rows")
        coordinator.toggleFacetPanel()
        await nextMainTurn()
        XCTAssertFalse(coordinator.displayedFacetPanel)
        coordinator.setPresented(false)
    }

    func testFilterGrowthPreservesBaseHeightAndCapsAtScreenBudget() {
        let cases: [(budget: CGFloat, expected: [CGFloat])] = [
            (800, [500, 590, 680]),
            (600, [500, 550, 600]),
            (450, [450, 450, 450])
        ]
        for testCase in cases {
            let heights: [CGFloat] = [0, 90, 180].map {
                PanelMetrics.contentHeight(facetHeight: CGFloat($0), maximumHeight: testCase.budget)
            }
            XCTAssertEqual(heights, testCase.expected, "Screen budget \(testCase.budget)")
        }
        // A short screen keeps the full filter section; the list is what compresses.
        XCTAssertEqual(PanelMetrics.facetPanelHeight, 180)
        XCTAssertEqual(PanelMetrics.contentHeight(facetHeight: 180, maximumHeight: 450),
                       PanelMetrics.contentHeight(facetHeight: 0, maximumHeight: 450),
                       "Growth must stop at the screen budget instead of clipping the filters")
    }

    func testLiveGestureMomentumAndPhaseLessWheelHaveIndependentLifetimes() async {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.setLiveScrolling(true)
        coordinator.receiveScroll(phase: .began, momentumPhase: [])
        coordinator.receive(snapshot: snapshot([pr(2)]), reason: .userIntent)
        coordinator.receiveScroll(phase: .ended, momentumPhase: .began)
        coordinator.setLiveScrolling(false)
        await nextMainTurn()
        XCTAssertTrue(coordinator.locks.contains(.scroll), "Momentum must outlive live/gesture scroll")
        XCTAssertEqual(ids(coordinator), [1])
        coordinator.receiveScroll(phase: [], momentumPhase: .ended)
        XCTAssertEqual(ids(coordinator), [1])
        await nextMainTurn()
        XCTAssertEqual(ids(coordinator), [2])
        coordinator.receiveScroll(phase: [], momentumPhase: [])
        coordinator.receive(snapshot: snapshot([pr(3)]), reason: .userIntent)
        XCTAssertTrue(coordinator.locks.contains(.scroll))
        XCTAssertEqual(ids(coordinator), [2])
        await nextMainTurn()
        XCTAssertFalse(coordinator.locks.contains(.scroll))
        XCTAssertEqual(ids(coordinator), [3])
    }

    func testPressCallbackRunsWithLockBeforeRemovedTargetCanDispatch() async {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1), pr(2)]))
        coordinator.recordGeometry([
            .row(rowID(1)): CGRect(x: 0, y: 0, width: 100, height: 80)
        ])
        var pressed: Int?
        var opened: [Int] = []
        coordinator.onOpenRow = { opened.append($0) }
        coordinator.onPointerDown = { id in
            XCTAssertTrue(coordinator.locks.contains(.pointer))
            pressed = id
            coordinator.receive(snapshot: self.snapshot([self.pr(2)]))
        }
        coordinator.beginPointerInteraction(at: CGPoint(x: 20, y: 20))
        coordinator.onPointerDown = nil
        XCTAssertEqual(pressed, 1)
        coordinator.activate(rowID(1))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(Set(ids(coordinator)), [1, 2])
        coordinator.endPointerInteractionAfterDispatch()
        await nextMainTurn()
        XCTAssertEqual(ids(coordinator), [2])
    }

    func testEscapePreservesCompositionAndMenuThenClearsOnlyQueryBeforeClosing() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        var query = "ci:failure"
        var closeCount = 0
        coordinator.searchIsEmpty = { query.isEmpty }
        coordinator.onClearSearch = { query = "" }
        coordinator.onRequestClose = { closeCount += 1 }
        coordinator.setInteraction(.composition, active: true)
        coordinator.escape()
        XCTAssertEqual(query, "ci:failure")
        coordinator.setInteraction(.composition, active: false)
        coordinator.beginMenuTracking()
        coordinator.escape()
        XCTAssertEqual(query, "ci:failure")
        coordinator.endMenuTracking()
        coordinator.escape()
        XCTAssertTrue(query.isEmpty)
        XCTAssertEqual(closeCount, 0)
        coordinator.escape()
        XCTAssertEqual(closeCount, 1)
    }

    func testTwentyPresentationCyclesRemovePanelResourcesAndPendingState() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let coordinator = PanelInteractionCoordinator()
        coordinator.bind(window: window)
        for cycle in 0..<20 {
            coordinator.receive(snapshot: snapshot([pr(1)]))
            coordinator.setPresented(true)
            XCTAssertEqual(coordinator.installedMonitorCount, 1, "Cycle \(cycle)")
            XCTAssertGreaterThan(coordinator.installedObserverCount, 0)
            coordinator.setInteraction(.pointer, active: true)
            coordinator.setInteraction(.scroll, active: true)
            coordinator.receive(snapshot: snapshot([pr(2)]))
            coordinator.setPresented(false)
            XCTAssertEqual(coordinator.installedMonitorCount, 0)
            XCTAssertEqual(coordinator.installedObserverCount, 0)
            XCTAssertTrue(coordinator.locks.isEmpty)
            XCTAssertNil(coordinator.pendingStructure)
            XCTAssertFalse(coordinator.pendingUserIntent)
            XCTAssertFalse(coordinator.pointerInsideList)
            XCTAssertTrue(coordinator.protectedGeometry.isEmpty)
            XCTAssertEqual(PRRowView.detailUIResourceCount, 0)
        }
        coordinator.bind(window: nil)
    }

    func testReopeningUsesLatestSourceAndInputIntentsWithoutPendingFrames() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.setPresented(true)
        coordinator.setInteraction(.composition, active: true)
        coordinator.updateSearchText("ci:failure")
        coordinator.updateFacetPanel(true)
        coordinator.toggleSection(.authored)
        coordinator.receive(snapshot: snapshot([pr(2)]), reason: .userIntent)
        XCTAssertEqual(coordinator.displayedSearchText, "")
        XCTAssertFalse(coordinator.displayedFacetPanel)
        XCTAssertEqual(ids(coordinator), [1])
        coordinator.setPresented(false)
        XCTAssertNil(coordinator.pendingStructure)
        coordinator.setPresented(true)
        XCTAssertEqual(ids(coordinator), [2])
        XCTAssertEqual(coordinator.displayedSearchText, "ci:failure")
        XCTAssertTrue(coordinator.displayedFacetPanel)
        XCTAssertFalse(coordinator.expandedSections.contains(.authored))
        XCTAssertNil(coordinator.pendingStructure)
        coordinator.setPresented(false)
    }

    func testHoverFactsAreCapturedAtPressWithoutRevertingTitleOrJiraTarget() {
        let coordinator = PanelInteractionCoordinator()
        let original = pr(1, title: "Short")
        coordinator.receive(snapshot: snapshot([original]))
        coordinator.setPresented(true)
        coordinator.setPointerInsideList(true)
        let rendered = pr(1, title: "Long title already rendered before mouse down", body: "DEMO-42")
        coordinator.receive(snapshot: snapshot([rendered, pr(2)]))
        XCTAssertEqual(coordinator.renderedFact(for: 1, fallback: original).title, rendered.title)
        let row = rowID(1)
        let frames: [PanelGeometryID: CGRect] = [
            .list: CGRect(x: 0, y: 40, width: 400, height: 300),
            .row(row): CGRect(x: 8, y: 20, width: 384, height: 112),
            .control(row, "jira"): CGRect(x: 48, y: 100, width: 88, height: 28)
        ]
        coordinator.recordGeometry(frames)
        let reveals = coordinator.keyboardRevealRevision
        // The source can advance again before SwiftUI realizes its next body.
        coordinator.receive(snapshot: snapshot([pr(1, title: "Not rendered yet"), pr(2)]))
        coordinator.beginPointerInteraction(at: CGPoint(x: 60, y: 110))
        XCTAssertEqual(coordinator.selectedRowID, row)
        XCTAssertEqual(coordinator.keyboardRevealRevision, reveals)
        XCTAssertEqual(coordinator.scrollAnchorOffset, -20)
        XCTAssertEqual(coordinator.renderedFact(for: 1, fallback: original).title, rendered.title)
        XCTAssertEqual(coordinator.renderedFact(for: 1, fallback: original).body, rendered.body)
        coordinator.receive(snapshot: snapshot([pr(1, title: "Later update"), pr(3)]))
        coordinator.setInteraction(.menu, active: true)
        XCTAssertEqual(coordinator.protectedGeometry[.control(row, "jira")], frames[.control(row, "jira")])
        XCTAssertEqual(coordinator.renderedFact(for: 1, fallback: original).title, rendered.title)
        coordinator.setInteraction(.menu, active: false)
        coordinator.setInteraction(.pointer, active: false)
        coordinator.moveSelection(1)
        XCTAssertEqual(coordinator.keyboardRevealRevision, reveals + 1)
        coordinator.setPresented(false)
    }

    func testAnchorPreservesPartialOffsetAndOnlyAppliesActualLayoutDisplacement() {
        let coordinator = PanelInteractionCoordinator()
        let original = pr(1)
        coordinator.receive(snapshot: snapshot([original, pr(2)]))
        let row = rowID(1)
        let viewport = CGRect(x: 0, y: 40, width: 400, height: 300)
        let frame = CGRect(x: 8, y: 15, width: 384, height: 90)
        coordinator.recordGeometry([.list: viewport, .row(row): frame])
        XCTAssertEqual(coordinator.scrollAnchorOffset, -25)
        var facts = snapshot([pr(1, title: "Same row with updated facts"), pr(2)])
        facts.prList.isLoading = true
        coordinator.receive(snapshot: facts)
        XCTAssertEqual(coordinator.consumeScrollDisplacement(in: [.list: viewport, .row(row): frame]), 0)
        XCTAssertNil(coordinator.pendingAnchorRestoration)
        coordinator.receive(snapshot: snapshot([original, pr(2)], pins: [original.pinIdentifier]), reason: .userIntent)
        XCTAssertEqual(coordinator.scrollAnchor, .row(row))
        XCTAssertEqual(coordinator.consumeScrollDisplacement(in: [.list: viewport, .row(row): frame.offsetBy(dx: 0, dy: 90)]), 90)
        XCTAssertNil(coordinator.consumeScrollDisplacement(in: [.list: viewport, .row(row): frame]))
    }

    func testAnchorCorrectionMovesNativeClipViewOnlyByRequiredDelta() {
        let coordinator = PanelInteractionCoordinator()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        coordinator.bind(scrollView: scroll)
        coordinator.receive(snapshot: snapshot([pr(1)]))
        let viewport = CGRect(x: 0, y: 40, width: 400, height: 300)
        let row = CGRect(x: 8, y: 15, width: 384, height: 90)
        coordinator.recordGeometry([.list: viewport, .row(rowID(1)): row])
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.recordGeometry([.list: viewport, .row(rowID(1)): row])
        XCTAssertEqual(scroll.contentView.bounds.minY, 200)
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.recordGeometry([.list: viewport, .row(rowID(1)): row.offsetBy(dx: 0, dy: 60)])
        XCTAssertEqual(scroll.contentView.bounds.minY, 260)
        XCTAssertEqual(coordinator.scrollAnchorOffset, -25)
    }

    func testFooterCountGeometryUsesPressCaptureWhileAccessibleFactsAdvance() {
        let coordinator = PanelInteractionCoordinator()
        var first = snapshot([pr(1)])
        first.activityReminderCount = 9
        coordinator.receive(snapshot: first)
        XCTAssertEqual(coordinator.activityReminderCountForLayout, 9)
        coordinator.setInteraction(.pointer, active: true)
        var second = snapshot([pr(1)])
        second.activityReminderCount = 100
        coordinator.receive(snapshot: second)
        XCTAssertEqual(coordinator.activityReminderCountForLayout, 9)
        XCTAssertEqual(coordinator.latestSnapshot?.activityReminderCount, 100)
        coordinator.setInteraction(.scroll, active: true)
        coordinator.setInteraction(.pointer, active: false)
        XCTAssertEqual(coordinator.activityReminderCountForLayout, 9)
        coordinator.setInteraction(.scroll, active: false)
        XCTAssertEqual(coordinator.activityReminderCountForLayout, 100)
    }

    func testDetailsOriginOverridesOldSelectionAndFallsBackAfterRemoval() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1), pr(2, age: 10), pr(3, age: 20)]))
        coordinator.select(rowID(1))
        coordinator.restoreRowFocus(origin: rowID(2))
        XCTAssertEqual(coordinator.selectedRowID, rowID(2))
        var opened: [Int] = []
        coordinator.onOpenRow = { opened.append($0) }
        coordinator.activate(coordinator.selectedRowID!)
        XCTAssertEqual(opened, [2])
        coordinator.select(rowID(1))
        coordinator.receive(snapshot: snapshot([pr(1), pr(3, age: 20)]))
        coordinator.restoreRowFocus(origin: rowID(2))
        XCTAssertEqual(coordinator.selectedRowID, rowID(3))
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.restoreRowFocus(origin: rowID(2))
        XCTAssertEqual(coordinator.selectedRowID, rowID(1))
        coordinator.receive(snapshot: snapshot([]))
        coordinator.restoreRowFocus(origin: rowID(2))
        XCTAssertEqual(coordinator.focusTarget, .section(.authored))
        XCTAssertNil(coordinator.selectedRowID)
    }

    func testNewMenuCapturesCurrentHoverFactsOnceForNestedTrackingLifetime() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.setPresented(true)
        coordinator.setPointerInsideList(true)
        let firstMenu = coordinator.menuCapture // Row closure is built before tracking begins.
        var changed = pr(1)
        changed.headCommitOid = "head-B"
        coordinator.receive(snapshot: snapshot([changed]))
        coordinator.beginMenuTracking()
        XCTAssertEqual(firstMenu.fact(for: 1)?.headCommitOid, "head-B")
        XCTAssertEqual(firstMenu.fact(for: 1)?.headCommitOid, coordinator.latestFacts[1]?.headCommitOid)
        changed.headCommitOid = "head-C"
        coordinator.receive(snapshot: snapshot([changed]))
        coordinator.beginMenuTracking()
        XCTAssertNotEqual(firstMenu.fact(for: 1)?.headCommitOid, coordinator.latestFacts[1]?.headCommitOid)
        coordinator.endMenuTracking()
        XCTAssertTrue(firstMenu === coordinator.menuCapture)
        coordinator.endMenuTracking()
        // AppKit may dispatch the selected action after didEndTracking.
        XCTAssertEqual(firstMenu.fact(for: 1)?.headCommitOid, "head-B")
        let nextMenu = coordinator.menuCapture
        XCTAssertFalse(firstMenu === nextMenu)
        coordinator.beginMenuTracking()
        XCTAssertEqual(nextMenu.fact(for: 1)?.headCommitOid, "head-C")
        XCTAssertEqual(firstMenu.fact(for: 1)?.headCommitOid, "head-B")
        XCTAssertNotEqual(firstMenu.fact(for: 1)?.headCommitOid, coordinator.latestFacts[1]?.headCommitOid)
        coordinator.endMenuTracking()
        changed.headCommitOid = nil
        coordinator.receive(snapshot: snapshot([changed]))
        let nilHeadMenu = coordinator.menuCapture
        coordinator.beginMenuTracking()
        XCTAssertNotNil(nilHeadMenu.fact(for: 1))
        XCTAssertNil(nilHeadMenu.fact(for: 1)?.headCommitOid)
        coordinator.endMenuTracking()
        XCTAssertNotNil(nilHeadMenu.fact(for: 1))
        XCTAssertNil(nilHeadMenu.fact(for: 1)?.headCommitOid)
        coordinator.setPresented(false)
    }

    func testKeyboardRevealWaitsForEveryLockAndReplaysOnlyLatestSelectionOnce() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1), pr(2, age: 10), pr(3, age: 20)]))
        coordinator.select(rowID(1))
        let initialRevision = coordinator.keyboardRevealRevision
        coordinator.setInteraction(.scroll, active: true)
        coordinator.setInteraction(.pointer, active: true)
        coordinator.moveSelection(1)
        coordinator.moveSelection(1)
        XCTAssertEqual(coordinator.selectedRowID, rowID(3))
        XCTAssertEqual(coordinator.keyboardRevealRevision, initialRevision)
        XCTAssertNil(coordinator.keyboardRevealTarget)
        coordinator.setInteraction(.scroll, active: false)
        XCTAssertEqual(coordinator.keyboardRevealRevision, initialRevision)
        coordinator.setInteraction(.menu, active: true)
        coordinator.setInteraction(.pointer, active: false)
        XCTAssertEqual(coordinator.keyboardRevealRevision, initialRevision)
        coordinator.setInteraction(.menu, active: false)
        XCTAssertEqual(coordinator.keyboardRevealTarget, .row(rowID(3)))
        XCTAssertEqual(coordinator.keyboardRevealRevision, initialRevision + 1)
        coordinator.setInteraction(.menu, active: false)
        coordinator.setInteraction(.pointer, active: true)
        coordinator.setInteraction(.pointer, active: false)
        XCTAssertEqual(coordinator.keyboardRevealRevision, initialRevision + 1)
    }

    func testGeometryBeforeNativeBindingRetainsOffsetUntilCorrectionCanApply() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        let viewport = CGRect(x: 0, y: 40, width: 400, height: 300)
        let row = CGRect(x: 8, y: 15, width: 384, height: 90)
        coordinator.recordGeometry([.list: viewport, .row(rowID(1)): row])
        coordinator.receive(snapshot: snapshot([pr(1)]))
        let shifted: [PanelGeometryID: CGRect] = [.list: viewport, .row(rowID(1)): row.offsetBy(dx: 0, dy: 60)]
        coordinator.recordGeometry(shifted)
        XCTAssertEqual(coordinator.pendingAnchorRestoration, .row(rowID(1)))
        XCTAssertEqual(coordinator.scrollAnchorOffset, -25)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        coordinator.bind(scrollView: scroll)
        XCTAssertNil(coordinator.pendingAnchorRestoration)
        XCTAssertEqual(scroll.contentView.bounds.minY, 260)
        XCTAssertEqual(coordinator.scrollAnchorOffset, -25)
        coordinator.recordGeometry([.list: viewport, .row(rowID(1)): row])
        XCTAssertEqual(scroll.contentView.bounds.minY, 260)
        XCTAssertEqual(coordinator.scrollAnchorOffset, -25)
    }

    func testDelayedSnapshotCannotReplaceNewerDisplayedOrLockedPendingFacts() {
        let coordinator = PanelInteractionCoordinator()
        var newer = snapshot([pr(2, title: "Current revision")])
        newer.presentationRevision = 2
        coordinator.receive(snapshot: newer, reason: .userIntent)
        var stale = snapshot([pr(1, title: "Delayed onAppear")])
        stale.presentationRevision = 1
        coordinator.receive(snapshot: stale)
        XCTAssertEqual(coordinator.latestSnapshot?.presentationRevision, 2)
        XCTAssertEqual(coordinator.displayedSnapshot?.presentationRevision, 2)
        XCTAssertEqual(ids(coordinator), [2])
        XCTAssertNil(coordinator.latestFacts[1])
        XCTAssertEqual(coordinator.latestFacts[2]?.title, "Current revision")
        coordinator.setInteraction(.pointer, active: true)
        var pending = snapshot([pr(3, title: "Locked newest revision")])
        pending.presentationRevision = 3
        coordinator.receive(snapshot: pending, reason: .userIntent)
        coordinator.receive(snapshot: stale, reason: .userIntent)
        XCTAssertEqual(coordinator.latestSnapshot?.presentationRevision, 3)
        XCTAssertEqual(coordinator.pendingStructure?.sourcePRs.map(\.id), [3])
        XCTAssertNil(coordinator.latestFacts[1])
        XCTAssertEqual(coordinator.latestFacts[3]?.title, "Locked newest revision")
        XCTAssertEqual(ids(coordinator), [2])
        coordinator.setInteraction(.pointer, active: false)
        XCTAssertEqual(coordinator.displayedSnapshot?.presentationRevision, 3)
        XCTAssertEqual(ids(coordinator), [3])
    }

    func testEqualFixedRevisionAndWrappingRevisionStillAcceptCurrentFacts() {
        let coordinator = PanelInteractionCoordinator()
        coordinator.receive(snapshot: snapshot([pr(1)]))
        coordinator.receive(snapshot: snapshot([pr(2)]))
        XCTAssertEqual(ids(coordinator), [2])
        let wrapping = PanelInteractionCoordinator()
        var last = snapshot([pr(1)])
        last.presentationRevision = UInt64.max
        wrapping.receive(snapshot: last)
        wrapping.receive(snapshot: snapshot([pr(2)]))
        XCTAssertEqual(wrapping.latestSnapshot?.presentationRevision, 0)
        XCTAssertEqual(ids(wrapping), [2])
        wrapping.receive(snapshot: last)
        XCTAssertEqual(ids(wrapping), [2])
    }

    func testExplicitKeyboardRevealSupersedesBackgroundAnchorRestoration() {
        let coordinator = PanelInteractionCoordinator()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        coordinator.bind(scrollView: scroll)
        let prs = [pr(1), pr(2, age: 10), pr(3, age: 20)]
        coordinator.receive(snapshot: snapshot(prs))
        let viewport = CGRect(x: 0, y: 40, width: 400, height: 300)
        let oldFrame = CGRect(x: 8, y: 15, width: 384, height: 90)
        coordinator.recordGeometry([.list: viewport, .row(rowID(1)): oldFrame])
        coordinator.select(rowID(1))
        coordinator.setInteraction(.scroll, active: true)
        coordinator.setInteraction(.pointer, active: true)
        coordinator.receive(snapshot: snapshot(prs, pins: [prs[2].pinIdentifier]))
        coordinator.moveSelection(1)
        coordinator.setInteraction(.scroll, active: false)
        coordinator.setInteraction(.pointer, active: false)
        XCTAssertEqual(coordinator.keyboardRevealTarget, .row(rowID(2)))
        XCTAssertNil(coordinator.pendingAnchorRestoration)
        // Model the renderer's explicit reveal of row 2. Its resulting geometry
        // must become the new reading position rather than restoring row 1.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 500))
        coordinator.recordGeometry([
            .list: viewport,
            .row(rowID(1)): oldFrame.offsetBy(dx: 0, dy: -300),
            .row(rowID(2)): CGRect(x: 8, y: 60, width: 384, height: 90)
        ])
        XCTAssertEqual(scroll.contentView.bounds.minY, 500)
        XCTAssertEqual(coordinator.scrollAnchor, .row(rowID(2)))
        XCTAssertEqual(coordinator.scrollAnchorOffset, 20)
    }

    func testNativeScrollCorrectionImmediatelyUpdatesHitRectsAndNormalizesDelayedSamples() {
        let coordinator = PanelInteractionCoordinator()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        coordinator.bind(scrollView: scroll)
        let prs = [pr(1), pr(2, age: 10)]
        coordinator.receive(snapshot: snapshot(prs))
        let initial: [PanelGeometryID: CGRect] = [
            .list: CGRect(x: 0, y: 40, width: 400, height: 300),
            .row(rowID(1)): CGRect(x: 8, y: 15, width: 384, height: 90),
            .row(rowID(2)): CGRect(x: 8, y: 105, width: 384, height: 90),
            .control(rowID(2), "jira"): CGRect(x: 48, y: 160, width: 72, height: 28),
            .section(.authored): CGRect(x: 8, y: -15, width: 384, height: 30),
            .summary: CGRect(x: 8, y: -45, width: 384, height: 30),
            .error: CGRect(x: 8, y: -69, width: 384, height: 24)
        ]
        coordinator.recordGeometry(initial)
        coordinator.receive(snapshot: snapshot(prs))
        let preScrollSamples = initial.mapValues { PanelGeometrySample(frame: $0, scrollOrigin: 200) }
        let shiftedSamples = Dictionary(uniqueKeysWithValues: preScrollSamples.map { id, sample in
            (id, PanelGeometrySample(frame: id.isScrollContent ? sample.frame.offsetBy(dx: 0, dy: 60) : sample.frame, scrollOrigin: 200))
        })
        coordinator.recordGeometrySamples(shiftedSamples)
        XCTAssertEqual(scroll.contentView.bounds.minY, 260)
        XCTAssertEqual(coordinator.geometry, initial, "Hit rects must already match the corrected native clip position")
        XCTAssertEqual(coordinator.scrollAnchorOffset, -25)
        // An already-enqueued preference from the old clip generation cannot
        // overwrite the corrected coordinate basis or perform another scroll.
        coordinator.recordGeometrySamples(shiftedSamples)
        XCTAssertEqual(coordinator.geometry, initial)
        XCTAssertEqual(scroll.contentView.bounds.minY, 260)
        let acknowledged = initial.mapValues { PanelGeometrySample(frame: $0, scrollOrigin: 260) }
        coordinator.recordGeometrySamples(acknowledged)
        XCTAssertEqual(coordinator.geometry, initial)
        XCTAssertEqual(scroll.contentView.bounds.minY, 260)
        var pointerTarget: Int?
        coordinator.onPointerDown = { pointerTarget = $0 }
        let jira = coordinator.geometry[.control(rowID(2), "jira")]!
        coordinator.beginPointerInteraction(at: CGPoint(x: jira.midX, y: jira.midY))
        XCTAssertEqual(pointerTarget, 2)
        XCTAssertEqual(coordinator.protectedGeometry[.control(rowID(2), "jira")], initial[.control(rowID(2), "jira")])
        coordinator.setInteraction(.pointer, active: false)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func rowID(_ id: Int) -> PRPanelRowID { PRPanelRowID(section: .authored, prID: id) }
    private func ids(_ coordinator: PanelInteractionCoordinator) -> [Int] {
        coordinator.displayedStructure?.displayedRowIDs(for: .authored).map(\.prID) ?? []
    }

    private func snapshot(
        _ prs: [PullRequest],
        pins: Set<String> = [],
        mentions: [PullRequest] = [],
        directMentions: [PullRequest] = []
    ) -> PRPanelSnapshot {
        var list = PRList(lastUpdated: now, pullRequests: prs, isLoading: false, error: nil)
        list.mentionedPullRequests = mentions
        list.directMentionPullRequests = directMentions
        let projection = PRPanelProjection.make(prList: list, searchText: "", selections: [:],
                                                pinnedIdentifiers: pins, configuration: .default, now: now)
        return PRPanelSnapshot(prList: list, projection: projection, rateLimitInfo: .empty,
                               restRateLimitInfo: .empty, configuration: .default, jiraConnectionState: .configured,
                               pinnedIdentifiers: pins, activeFacetSelections: [:], activityReminderCount: 0,
                               openingPRIDs: [], updatingBranchPRIDs: [], loadingHoverDetailPRIDs: [],
                               facetChips: [], facetOptions: projection.facetOptions, labelSuggestions: [],
                               savedViews: [], now: now, actionError: nil)
    }

    private func pr(_ id: Int, title: String? = nil, age: TimeInterval = 0, body: String? = nil,
                    category: PRCategory = .authored) -> PullRequest {
        let date = now.addingTimeInterval(-age)
        return PullRequest(
            id: id, number: id, title: title ?? "PR \(id)", author: "example", authorAvatarURL: nil,
            repositoryOwner: "example", repositoryName: "project",
            url: URL(string: "https://github.com/example/project/pull/\(id)")!,
            state: .open, isDraft: false, createdAt: date, updatedAt: date, mergedAt: nil,
            body: body, conversationComments: [], lastCommitAt: date, headCommitOid: "sha-\(id)",
            reviewThreads: [], category: category, hasBaseConflicts: false, ciStatus: .success,
            checkSuccessCount: 1, checkFailureCount: 0, checkPendingCount: 0, githubCIState: "success",
            myLastReviewState: nil, myLastReviewAt: nil, reviewRequestedAt: nil, myThreadsAllResolved: false,
            approvalCount: 0, changesRequestedCount: 0, ciExtendedInfo: nil
        )
    }
}
@MainActor
final class HoverTooltipLifecycleTests: XCTestCase {
    func testDestroyingVisibleTooltipHostClearsItAndNextHostCanShow() async throws {
        let presenter = HoverTooltipPresenter()
        let first = makeHost(presenter: presenter)
        defer { first.close() }
        try first.hover()
        await expectTooltip(presenter, text: "Draft explanation")

        weak var releasedHost = first.host
        autoreleasepool { first.close() }
        await expectTooltip(presenter, text: nil)
        XCTAssertNil(releasedHost, "The hovered NSHostingView must be released, exercising graph teardown")

        let second = makeHost(presenter: presenter)
        defer { second.close() }
        try second.hover()
        await expectTooltip(presenter, text: "Draft explanation")
    }

    func testDestroyingPendingTooltipHostPreventsLatePresentation() async throws {
        let presenter = HoverTooltipPresenter()
        let fixture = makeHost(presenter: presenter, delayNanoseconds: 50_000_000)
        defer { fixture.close() }
        let lateTooltip = expectation(description: "Destroyed host must never publish its pending tooltip")
        lateTooltip.isInverted = true
        let observation = presenter.$tooltip.sink { if $0 != nil { lateTooltip.fulfill() } }
        defer { observation.cancel() }

        try fixture.hover()
        weak var releasedHost = fixture.host
        autoreleasepool { fixture.close() }
        await fulfillment(of: [lateTooltip], timeout: 0.25)
        XCTAssertNil(releasedHost, "Pending hover work must not retain the destroyed hosting view")
    }

    func testPanelDismissalCancelsPendingHoverAndAllowsReentry() async throws {
        let presenter = HoverTooltipPresenter()
        let fixture = makeHost(presenter: presenter, delayNanoseconds: 50_000_000)
        defer { fixture.close() }
        let lateTooltip = expectation(description: "Panel dismissal must cancel hover even when its view is retained")
        lateTooltip.isInverted = true
        let observation = presenter.$tooltip.sink { if $0 != nil { lateTooltip.fulfill() } }
        try fixture.hover()
        presenter.dismissAll()
        await fulfillment(of: [lateTooltip], timeout: 0.25)
        observation.cancel()

        try fixture.hover()
        await expectTooltip(presenter, text: "Draft explanation")
        presenter.dismissAll()
        XCTAssertNil(presenter.tooltip, "Dismissing the panel must also clear an already visible tooltip")
    }

    func testOldHostTeardownDoesNotHideAnotherOwnersTooltip() async throws {
        let presenter = HoverTooltipPresenter()
        let fixture = makeHost(presenter: presenter)
        defer { fixture.close() }
        try fixture.hover()
        await expectTooltip(presenter, text: "Draft explanation")

        let nextOwner = UUID()
        autoreleasepool { fixture.close() }
        presenter.show(ownerID: nextOwner, text: "Next row", point: .zero)
        let drained = expectation(description: "Deferred teardown has run")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(presenter.tooltip?.ownerID, nextOwner, "Old teardown must not dismiss the new row's tooltip")
        presenter.dismissAll()
    }

    private func expectTooltip(_ presenter: HoverTooltipPresenter, text: String?) async {
        let changed = expectation(description: "Tooltip becomes \(text ?? "hidden")")
        let observation = presenter.$tooltip.filter { $0?.text == text }.prefix(1).sink { _ in changed.fulfill() }
        await fulfillment(of: [changed], timeout: 2)
        observation.cancel()
        XCTAssertEqual(presenter.tooltip?.text, text, "Tooltip presentation must match the current hover lifecycle")
    }

    private func makeHost(presenter: HoverTooltipPresenter, delayNanoseconds: UInt64 = 1_000_000) -> TooltipHost {
        let root = Text("Draft")
            .frame(width: 180, height: 44)
            .delayedHoverTooltip("Draft explanation", delayNanoseconds: delayNanoseconds)
            .allowsHitTesting(false)
            .environment(\.hoverTooltipPresenter, presenter)
            .coordinateSpace(name: HoverTooltipCoordinateSpace.name)
            .overlay { HoverTooltipOverlay(presenter: presenter) }
        return TooltipHost(root: AnyView(root))
    }

    @MainActor
    private final class TooltipHost {
        let window: NSWindow
        var host: NSHostingView<AnyView>?

        init(root: AnyView) {
            window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 180, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: root)
            window.contentView = host
            window.orderFront(nil)
            host?.layoutSubtreeIfNeeded()
        }

        func hover() throws {
            let host = try XCTUnwrap(host, "Tooltip host must exist before hover")
            host.layoutSubtreeIfNeeded()
            let tracker = try XCTUnwrap(findTracker(in: host), "The real tooltip tracking view must be mounted")
            let point = tracker.convert(CGPoint(x: tracker.bounds.midX, y: tracker.bounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0), "A native hover event is required")
            tracker.mouseMoved(with: event)
        }

        func close() {
            window.contentView = nil
            host = nil
            window.close()
        }

        private func findTracker(in view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "HoverTooltipTrackingView" { return view }
            for child in view.subviews {
                if let tracker = findTracker(in: child) { return tracker }
            }
            return nil
        }
    }
}
