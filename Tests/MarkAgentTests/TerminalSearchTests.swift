import AppKit
import GhosttyKit
@testable import GhosttyTerminal
import XCTest
@testable import ma

final class TerminalSearchTests: XCTestCase {
    @MainActor
    func testDispatchSuccessDoesNotInventMatchesAndQueryChangeClearsResults() {
        let search = TerminalSearchState()
        var actions: [String] = []
        search.connect(performAction: { actions.append($0); return true }, onChange: {})
        search.present()
        search.updateQuery("a:b 한글")
        XCTAssertEqual(actions, ["search:a:b 한글"])
        XCTAssertEqual(search.result, .searching)
        XCTAssertFalse(search.canNavigate)

        search.receiveTotal(3)
        search.receiveSelected(2)
        XCTAssertEqual(search.result, .matches(current: 2, total: 3))
        search.updateQuery("a:b 한글")
        XCTAssertEqual(actions, ["search:a:b 한글", "navigate_search:next"])
        search.updateQuery("other")
        XCTAssertEqual(search.result, .searching)
        XCTAssertNil(search.selected)
    }

    @MainActor
    func testInitialSelectionRunsOnceAndCaseOnlyEditRetainsResults() {
        let search = TerminalSearchState()
        var actions: [String] = []
        search.connect(performAction: { actions.append($0); return true }, onChange: {})
        search.present()
        search.updateQuery("needle")
        search.receiveTotal(2)
        search.receiveTotal(3)
        XCTAssertEqual(actions, ["search:needle", "navigate_search:next"])
        XCTAssertEqual(search.result, .matches(current: nil, total: 3))
        search.receiveSelected(1)
        search.updateQuery("NEEDLE")
        XCTAssertEqual(search.query, "NEEDLE")
        XCTAssertEqual(search.result, .matches(current: 1, total: 3))
        XCTAssertEqual(actions, ["search:needle", "navigate_search:next"])
    }

    @MainActor
    func testNoResultsUnknownSelectionAndNavigationFollowCallbacks() {
        let search = TerminalSearchState()
        var actions: [String] = []
        search.connect(performAction: { actions.append($0); return true }, onChange: {})
        search.present()
        search.updateQuery("needle")
        search.receiveTotal(0)
        XCTAssertEqual(search.result, .noMatches)
        search.navigate(backwards: false)
        XCTAssertEqual(actions, ["search:needle"])

        search.receiveTotal(4)
        XCTAssertEqual(search.result, .matches(current: nil, total: 4))
        search.receiveSelected(3)
        search.navigate(backwards: false)
        search.navigate(backwards: true)
        XCTAssertEqual(Array(actions.suffix(2)), ["navigate_search:next", "navigate_search:previous"])
        XCTAssertEqual(search.result, .matches(current: 3, total: 4))
        search.receiveSelected(4)
        XCTAssertEqual(search.result, .matches(current: 4, total: 4))
        search.receiveTotal(2)
        XCTAssertEqual(search.result, .matches(current: nil, total: 2))
    }

    @MainActor
    func testUnavailableSurfaceIsNotReportedAsNoResults() {
        let search = TerminalSearchState()
        search.connect(performAction: { _ in false }, onChange: {})
        search.present()
        search.updateQuery("needle")
        XCTAssertEqual(search.result, .unavailable)
        search.receiveTotal(0)
        XCTAssertEqual(search.result, .unavailable)
        XCTAssertFalse(search.canNavigate)
    }

    @MainActor
    func testClearAndDismissEndSearchAndIgnoreLateCallbacks() {
        let search = TerminalSearchState()
        var actions: [String] = []
        search.connect(performAction: { actions.append($0); return true }, onChange: {})
        search.present()
        search.updateQuery("first")
        search.updateQuery("")
        search.receiveTotal(9)
        XCTAssertEqual(search.result, .idle)
        XCTAssertNil(search.total)
        search.updateQuery("second")
        search.dismiss()
        search.receiveTotal(5)
        search.receiveSelected(2)
        XCTAssertEqual(actions, ["search:first", "end_search", "search:second", "end_search"])
        XCTAssertFalse(search.isPresented)
        XCTAssertNil(search.total)
        XCTAssertNil(search.selected)
    }

    @MainActor
    func testGhosttyCallbackBridgeDeliversTotalsAndOneBasedSelection() {
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
        let coordinator = TerminalTabView.Coordinator()
        coordinator.observeState(state)
        let bridge = TerminalCallbackBridge(delegate: coordinator)
        state.search.connect(performAction: { _ in true }, onChange: {})
        state.search.present()
        state.search.updateQuery("needle")

        var total = ghostty_action_s()
        total.tag = GHOSTTY_ACTION_SEARCH_TOTAL
        total.action.search_total.total = 7
        bridge.handleAction(total)
        var selected = ghostty_action_s()
        selected.tag = GHOSTTY_ACTION_SEARCH_SELECTED
        selected.action.search_selected.selected = 0
        bridge.handleAction(selected)
        XCTAssertEqual(state.search.result, .matches(current: 1, total: 7))

        selected.action.search_selected.selected = 6
        bridge.handleAction(selected)
        XCTAssertEqual(state.search.result, .matches(current: 7, total: 7))

        selected.action.search_selected.selected = -1
        bridge.handleAction(selected)
        XCTAssertEqual(state.search.result, .matches(current: nil, total: 7))
        total.action.search_total.total = -1
        bridge.handleAction(total)
        XCTAssertEqual(state.search.result, .searching)
        total.action.search_total.total = 0
        bridge.handleAction(total)
        XCTAssertEqual(state.search.result, .noMatches)
    }

    @MainActor
    func testSearchShortcutsKeepSidebarAndSnippetRoutes() throws {
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
        let view = SearchAwareTerminalView()
        view.connectSearch(state.search)
        state.terminalView = view
        var modes: [SidebarSearchMode] = []
        var snippets: [String] = []
        view.onSearchShortcut = { modes.append($0) }
        view.selectedTextProvider = { "selected output" }
        view.onSnippetShortcut = { snippets.append($0) }

        let find = try keyEvent(key: "f", code: 3, modifiers: [.command])
        XCTAssertTrue(state.sendConfiguredKeybind(find, key: "f", modifiers: [.command]))
        XCTAssertTrue(state.search.isPresented)
        XCTAssertTrue(view.performKeyEquivalent(with: try keyEvent(key: "f", code: 3, modifiers: [.command, .shift])))
        XCTAssertTrue(view.performKeyEquivalent(with: try keyEvent(key: "g", code: 5, modifiers: [.command, .shift])))
        XCTAssertTrue(view.performKeyEquivalent(with: try keyEvent(key: "c", code: 8, modifiers: [.command, .shift])))
        XCTAssertEqual(modes, [.files, .grep])
        XCTAssertEqual(snippets, ["selected output"])
        view.disconnectSearch()
    }

    @MainActor
    func testSearchFieldKeepsFocusThroughRefreshAndEscapeRestoresTerminal() async throws {
        let window = makeWindow()
        defer { window.close() }
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let search = TerminalSearchState()
        view.connectSearch(search)
        window.contentView?.addSubview(view)
        defer { view.disconnectSearch(); view.removeFromSuperview() }
        XCTAssertTrue(view.performKeyEquivalent(with: try keyEvent(key: "f", code: 3, modifiers: [.command])))
        let bar = try XCTUnwrap(view.searchBar)
        XCTAssertTrue(bar.ownsFirstResponder)
        TerminalFocusPolicy.requestFocus(view) { true }
        let refreshed = expectation(description: "deferred focus completed")
        DispatchQueue.main.async { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertTrue(bar.ownsFirstResponder)

        XCTAssertTrue(bar.control(bar.searchField, textView: NSTextView(),
                                  doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(search.isPresented)
        XCTAssertTrue(window.firstResponder === view)
    }

    @MainActor
    func testInactiveTerminalRelinquishesSearchFieldAndCannotConsumeFind() throws {
        let window = makeWindow()
        defer { window.close() }
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let search = TerminalSearchState()
        view.connectSearch(search)
        window.contentView?.addSubview(view)
        defer { view.disconnectSearch(); view.removeFromSuperview() }
        view.presentTerminalSearch()
        XCTAssertTrue(view.searchBar?.ownsFirstResponder == true)
        view.isActiveTerminal = { false }
        TerminalFocusPolicy.resignIfNeeded(view)
        XCTAssertFalse(view.searchBar?.ownsFirstResponder == true)
        XCTAssertFalse(view.performKeyEquivalent(with: try keyEvent(key: "f", code: 3, modifiers: [.command])))
    }

    @MainActor
    func testTeardownEndsSearchAndReleasesOverlayAndCallbackOwnership() {
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
        let coordinator = TerminalTabView.Coordinator()
        coordinator.observeState(state)
        let bridge = TerminalCallbackBridge(delegate: coordinator)
        weak var weakView: SearchAwareTerminalView?
        weak var weakBar: TerminalSearchBar?
        autoreleasepool {
            let view = SearchAwareTerminalView()
            view.connectSearch(state.search)
            state.terminalView = view
            view.delegate = coordinator
            view.presentTerminalSearch()
            weakView = view
            weakBar = view.searchBar
            TerminalFocusPolicy.requestFocus(view) { false }
            TerminalTabView.tearDown(view, coordinator: coordinator)
            XCTAssertNil(view.searchState)
            XCTAssertNil(view.searchBar)
            XCTAssertNil(view.delegate)
            XCTAssertNil(view.controller)
        }
        XCTAssertNil(weakView)
        XCTAssertNil(weakBar)
        XCTAssertNil(state.terminalView)
        XCTAssertFalse(state.search.isPresented)
        state.search.connect(performAction: { _ in true }, onChange: {})
        state.search.present()
        state.search.updateQuery("detached")
        var total = ghostty_action_s()
        total.tag = GHOSTTY_ACTION_SEARCH_TOTAL
        total.action.search_total.total = 4
        bridge.handleAction(total)
        XCTAssertEqual(state.search.result, .searching)
    }

    @MainActor
    func testViewAndCoordinatorDoNotRetainTabState() {
        let view = SearchAwareTerminalView()
        let coordinator = TerminalTabView.Coordinator()
        weak var weakState: TerminalTabState?
        autoreleasepool {
            let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
            weakState = state
            state.terminalView = view
            view.connectSearch(state.search)
            coordinator.observeState(state)
            view.delegate = coordinator
        }
        XCTAssertNil(weakState)
        XCTAssertNil(view.searchState)
        TerminalTabView.tearDown(view, coordinator: coordinator)
    }

    @MainActor
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func keyEvent(key: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 1, windowNumber: 0, context: nil, characters: key,
                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }
}
