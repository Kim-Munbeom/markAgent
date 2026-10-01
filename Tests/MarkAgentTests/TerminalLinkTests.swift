import AppKit
import GhosttyTerminal
import XCTest
@testable import ma

final class TerminalLinkTests: XCTestCase {
    @MainActor
    func testCoordinatorHandlesGhosttyLinkRequests() {
        let delegate: any TerminalSurfaceViewDelegate = TerminalTabView.Coordinator()
        XCTAssertNotNil(delegate as? any TerminalSurfaceOpenURLDelegate)
    }

    @MainActor
    func testLocalLinksResolveAgainstCurrentTerminalDirectoryAndReuseDocumentTab() throws {
        let suite = "TerminalLinkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tabs = TabCollection(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "# Plan".write(to: directory.appendingPathComponent("docs/plan one.md"), atomically: true, encoding: .utf8)
        try "# README".write(to: directory.appendingPathComponent("README.MARKDOWN"), atomically: true, encoding: .utf8)
        let terminal = tabs.createTerminalTab(workingDirectory: directory)
        let coordinator = TerminalTabView.Coordinator()
        coordinator.observeState(terminal.state)
        coordinator.onOpenFile = { tabs.createMarkdownTab(fileURL: $0) }
        var externalURLs: [URL] = []
        coordinator.openExternalURL = { externalURLs.append($0) }

        coordinator.terminalDidRequestOpenURL("docs/plan%20one.md#section", kind: .text)
        let document = try XCTUnwrap(tabs.activeMarkdownTab)
        XCTAssertEqual(document.fileURL, directory.appendingPathComponent("docs/plan one.md"))
        tabs.selectTab(id: terminal.id)
        coordinator.terminalDidRequestOpenURL(document.fileURL?.absoluteString ?? "", kind: .html)
        XCTAssertTrue(tabs.activeMarkdownTab === document)
        XCTAssertEqual(tabs.tabs.count, 2)

        terminal.state.workingDirectory = directory.appendingPathComponent("other", isDirectory: true)
        coordinator.terminalDidRequestOpenURL("../README.MARKDOWN", kind: .unknown)
        XCTAssertEqual(tabs.activeMarkdownTab?.fileURL, directory.appendingPathComponent("README.MARKDOWN"))
        var homeURL: URL?
        coordinator.onOpenFile = { homeURL = $0 }
        coordinator.terminalDidRequestOpenURL("~/notes.md", kind: .text)
        XCTAssertEqual(homeURL, URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("notes.md"))
        coordinator.terminalDidRequestOpenURL("database/migration.php", kind: .text)
        XCTAssertEqual(homeURL, directory.appendingPathComponent("other/database/migration.php"))

        coordinator.terminalDidRequestOpenURL("https://example.com/README.md", kind: .html)
        coordinator.terminalDidRequestOpenURL("https://example.com", kind: .text)
        coordinator.terminalDidRequestOpenURL("image.png", kind: .text)
        XCTAssertEqual(homeURL, directory.appendingPathComponent("other/image.png"))
        XCTAssertEqual(externalURLs.map(\.absoluteString), [
            "https://example.com/README.md", "https://example.com",
        ])
    }

    @MainActor
    func testDetachedCoordinatorReleasesFileCallbackAndTabState() {
        let coordinator = TerminalTabView.Coordinator()
        let view = SearchAwareTerminalView()
        weak var releasedState: TerminalTabState?
        do {
            let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
            releasedState = state
            coordinator.observeState(state)
            coordinator.onOpenFile = { [state] _ in state.title = "opened" }
            coordinator.detach(from: view)
            XCTAssertNil(coordinator.onOpenFile)
        }
        XCTAssertNil(releasedState)
        coordinator.openExternalURL = { _ in XCTFail("분리된 터미널은 링크를 열면 안 된다.") }
        coordinator.terminalDidRequestOpenURL("https://example.com", kind: .text)
    }

    @MainActor
    func testActualGhosttyOSC8PlainClickOpensMarkdownAndDragSelectsText() async throws {
        _ = NSApplication.shared
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let coordinator = LinkSignalCoordinator()
        coordinator.observeState(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.delegate = coordinator
        state.terminalView = view
        view.controller = state.terminalViewState.controller
        window.contentView?.addSubview(view)
        defer {
            coordinator.onTitle = nil
            coordinator.onHover = nil
            TerminalTabView.tearDown(view, coordinator: coordinator)
            view.removeFromSuperview()
            window.close()
        }

        let parsed = expectation(description: "OSC 8 링크 파싱 완료")
        coordinator.onTitle = { if $0 == "link-fixture-ready" { parsed.fulfill() } }
        session.receive("\u{1B}]8;;docs/plan.md\u{1B}\\문서 이름\u{1B}]8;;\u{1B}\\"
                        + "\u{1B}]2;link-fixture-ready\u{7}")
        await fulfillment(of: [parsed], timeout: 5)
        coordinator.onTitle = nil
        let metrics = try XCTUnwrap(coordinator.metrics)
        let opened = expectation(description: "실제 터미널 클릭으로 Markdown 열기")
        coordinator.onOpenFile = {
            XCTAssertEqual($0, state.workingDirectory.appendingPathComponent("docs/plan.md"))
            opened.fulfill()
        }
        coordinator.openExternalURL = { _ in XCTFail("로컬 Markdown은 외부 앱으로 열면 안 된다.") }
        let scale = window.backingScaleFactor
        let point = view.convert(NSPoint(x: CGFloat(metrics.cellWidthPixels) / scale,
                                        y: view.bounds.height - CGFloat(metrics.cellHeightPixels) / scale / 2), to: nil)
        let hover = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        let hovered = expectation(description: "수정키 없이 링크 hover 인식")
        coordinator.onHover = { url in
            if url == "docs/plan.md" {
                coordinator.onHover = nil
                hovered.fulfill()
            }
        }
        view.mouseMoved(with: hover)
        await fulfillment(of: [hovered], timeout: 5)
        XCTAssertEqual(view.hoveredLink, "docs/plan.md")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: 0, windowNumber: window.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else { view.mouseUp(with: event) }
        }
        await fulfillment(of: [opened], timeout: 5)

        coordinator.onOpenFile = { _ in XCTFail("일반 드래그는 링크를 열면 안 된다.") }
        let start = NSPoint(x: CGFloat(metrics.cellWidthPixels) / scale / 4, y: point.y)
        let end = NSPoint(x: CGFloat(metrics.cellWidthPixels) / scale * 10, y: point.y)
        for (type, location) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                       timestamp: 0, windowNumber: window.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        let selection = TerminalSelectionPasteboardReader.readSelectedText {
            view.performBindingAction("copy_to_clipboard")
        }
        XCTAssertEqual(selection?.trimmingCharacters(in: .whitespacesAndNewlines), "문서 이름")
    }
}

@MainActor
private final class LinkSignalCoordinator: TerminalTabView.Coordinator, TerminalSurfaceGridResizeDelegate {
    var onTitle: ((String) -> Void)?
    var onHover: ((String?) -> Void)?
    var metrics: TerminalGridMetrics?

    override func terminalDidChangeTitle(_ title: String) {
        super.terminalDidChangeTitle(title)
        onTitle?(title)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        metrics = size
    }

    override func terminalDidUpdateHoverLink(_ url: String?) {
        super.terminalDidUpdateHoverLink(url)
        onHover?(url)
    }
}
