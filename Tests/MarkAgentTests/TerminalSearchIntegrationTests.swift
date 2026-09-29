import AppKit
import GhosttyTerminal
import XCTest
@testable import ma

final class TerminalSearchIntegrationTests: XCTestCase {
    @MainActor
    func testActualGhosttyScrollbackSearchNavigationAndNoResults() async throws {
        _ = NSApplication.shared
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let coordinator = SearchSignalCoordinator()
        coordinator.observeState(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.delegate = coordinator
        view.connectSearch(state.search)
        state.terminalView = view
        view.controller = state.terminalViewState.controller
        window.contentView?.addSubview(view)
        defer {
            coordinator.onTitle = nil
            coordinator.onSearch = nil
            TerminalTabView.tearDown(view, coordinator: coordinator)
            view.removeFromSuperview()
            window.close()
        }

        // 마지막 OSC 제목 콜백을 받아야 출력 파싱이 끝난 것으로 판단한다.
        let outputParsed = expectation(description: "terminal output parsed")
        coordinator.onTitle = { title in
            if title == "search-fixture-ready" { outputParsed.fulfill() }
        }
        session.receive("scrollback-needle first\r\nscrollback-needle second\r\n"
                        + (0..<80).map { "filler \($0)\r\n" }.joined()
                        + "\u{1B}]2;search-fixture-ready\u{7}")
        await fulfillment(of: [outputParsed], timeout: 5)
        coordinator.onTitle = nil
        XCTAssertFalse(try XCTUnwrap(session.readViewportText()).contains("scrollback-needle"))

        let found = expectation(description: "two matches in actual scrollback")
        coordinator.onSearch = {
            if case .matches(let current, 2) = state.search.result, current != nil {
                coordinator.onSearch = nil
                found.fulfill()
            }
        }
        view.presentTerminalSearch()
        let bar = try XCTUnwrap(view.searchBar)
        let editor = try XCTUnwrap(bar.searchField.currentEditor() as? NSTextView)
        editor.insertText("scrollback-needle", replacementRange: NSRange(location: NSNotFound, length: 0))
        await fulfillment(of: [found], timeout: 5)
        XCTAssertEqual(state.search.query, "scrollback-needle")
        XCTAssertEqual(state.search.total, 2, "Search state: \(state.search.result)")
        let initial = try XCTUnwrap(state.search.selected, "Search state: \(state.search.result)")
        XCTAssertTrue((1...2).contains(initial), "Selected index: \(initial)")
        XCTAssertEqual(bar.resultLabel.stringValue, "\(initial) / 2")

        let next = expectation(description: "next search selection callback")
        coordinator.onSearch = {
            if let selected = state.search.selected, selected != initial {
                coordinator.onSearch = nil
                next.fulfill()
            }
        }
        state.search.navigate(backwards: false)
        await fulfillment(of: [next], timeout: 5)
        XCTAssertEqual(state.search.total, 2)

        let previous = expectation(description: "previous search selection callback")
        coordinator.onSearch = {
            if state.search.selected == initial {
                coordinator.onSearch = nil
                previous.fulfill()
            }
        }
        state.search.navigate(backwards: true)
        await fulfillment(of: [previous], timeout: 5)

        let absent = expectation(description: "zero matches callback")
        coordinator.onSearch = {
            if state.search.result == .noMatches {
                coordinator.onSearch = nil
                absent.fulfill()
            }
        }
        state.search.updateQuery("markagent-absent-\(UUID().uuidString)")
        await fulfillment(of: [absent], timeout: 5)
        XCTAssertFalse(state.search.canNavigate)
        view.dismissTerminalSearch()
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertFalse(state.search.isPresented)
    }
}

@MainActor
private final class SearchSignalCoordinator: TerminalTabView.Coordinator {
    var onTitle: ((String) -> Void)?
    var onSearch: (() -> Void)?

    override func terminalDidChangeTitle(_ title: String) {
        super.terminalDidChangeTitle(title)
        onTitle?(title)
    }

    override func terminalDidUpdateSearchTotal(_ total: Int?) {
        super.terminalDidUpdateSearchTotal(total)
        onSearch?()
    }

    override func terminalDidUpdateSearchSelected(_ selected: Int?) {
        super.terminalDidUpdateSearchSelected(selected)
        onSearch?()
    }
}
