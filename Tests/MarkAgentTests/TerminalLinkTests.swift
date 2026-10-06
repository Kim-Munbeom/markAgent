import AppKit
import GhosttyTerminal
import GhosttyKit
import XCTest
@testable import ma

final class TerminalLinkTests: XCTestCase {
    @MainActor
    func testExecTerminalPropagatesHyperlinkCapabilitiesToChildShell() async throws {
        let environment = ProcessInfo.processInfo.environment
        try await assertExecHyperlinkEnvironment(
            configContents: nil,
            expectedTitle: "caps:\(environment["PI_HYPERLINKS"] ?? "1"):\(environment["FORCE_HYPERLINK"] ?? "1")"
        )
    }

    @MainActor
    func testExecTerminalPreservesExplicitHyperlinkOptOut() async throws {
        try await assertExecHyperlinkEnvironment(
            configContents: "env = PI_HYPERLINKS=0\nenv = FORCE_HYPERLINK=0",
            expectedTitle: "caps:0:0"
        )
    }

    @MainActor
    private func assertExecHyperlinkEnvironment(configContents: String?, expectedTitle: String) async throws {
        _ = NSApplication.shared
        let config = configContents.map {
            GhosttyConfig(url: URL(fileURLWithPath: "/tmp/link-capabilities-config"),
                          contents: $0, fontFamilies: [], fontSize: nil, colorTheme: nil, keybinds: [])
        }
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory,
                                     userConfigProvider: { config })
        let coordinator = LinkSignalCoordinator()
        coordinator.observeState(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        let received = expectation(description: "자식 shell의 링크 지원 환경")
        coordinator.onTitle = {
            if $0.hasPrefix("caps:") {
                XCTAssertEqual($0, expectedTitle)
                coordinator.onTitle = nil
                received.fulfill()
            }
        }
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            command: "printf '\\033]2;caps:%s:%s\\007' \"$PI_HYPERLINKS\" \"$FORCE_HYPERLINK\"; exec /bin/cat"
        )
        view.delegate = coordinator
        state.terminalView = view
        view.controller = state.terminalViewState.controller
        window.contentView?.addSubview(view)
        defer {
            coordinator.onTitle = nil
            TerminalTabView.tearDown(view, coordinator: coordinator)
            view.removeFromSuperview()
            window.close()
        }
        await fulfillment(of: [received], timeout: 5)
    }

    @MainActor
    func testActualGhosttyPRLinkWithTUIMouseReporting() async throws {
        _ = NSApplication.shared
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
        let reports = LinkMouseReports()
        let released = expectation(description: "TUI 마우스 release 보고")
        released.expectedFulfillmentCount = 3
        let session = InMemoryTerminalSession(write: {
            let report = String(decoding: $0, as: UTF8.self)
            reports.append(report)
            if report.hasPrefix("\u{1B}[<"), report.hasSuffix("m") {
                released.fulfill()
            }
        }, resize: { _ in })
        let coordinator = LinkSignalCoordinator()
        coordinator.observeState(state)
        let window = MarkAgentWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        let viewportReady = expectation(description: "테스트 창 viewport 크기 적용")
        coordinator.onResize = {
            if $0.widthPixels == UInt32(view.bounds.width * window.backingScaleFactor),
               $0.heightPixels == UInt32(view.bounds.height * window.backingScaleFactor) {
                coordinator.onResize = nil
                viewportReady.fulfill()
            }
        }
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.delegate = coordinator
        state.terminalView = view
        view.controller = state.terminalViewState.controller
        window.contentView?.addSubview(view)
        defer {
            coordinator.onTitle = nil
            coordinator.onHover = nil
            coordinator.onResize = nil
            NSCursor.arrow.set()
            TerminalTabView.tearDown(view, coordinator: coordinator)
            view.removeFromSuperview()
            window.close()
        }
        await fulfillment(of: [viewportReady], timeout: 5)

        let links = [
            ("https://github.com/comento/comento-admin-laravel/pull/4207", "Laravel #4207"),
            ("https://github.com/comento/comento-admin-vue/pull/1423", "Vue #1423"),
        ]
        let parsed = expectation(description: "TUI 링크와 마우스 모드 파싱")
        coordinator.onTitle = { if $0 == "tui-link-ready" { parsed.fulfill() } }
        session.receive("\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h"
                        + links.map { "\u{1B}]8;;\($0.0)\u{1B}\\\($0.1)\u{1B}]8;;\u{1B}\\" }.joined(separator: "\r\n")
                        + "\u{1B}]2;tui-link-ready\u{7}")
        await fulfillment(of: [parsed], timeout: 5)
        coordinator.onTitle = nil
        XCTAssertTrue(view.isMouseCaptured)
        let metrics = try XCTUnwrap(coordinator.metrics)
        for (row, link) in links.enumerated() {
            let url = link.0
            let point = view.convert(NSPoint(x: CGFloat(metrics.cellWidthPixels) / window.backingScaleFactor / 2,
                                            y: view.bounds.height - CGFloat(metrics.cellHeightPixels) / window.backingScaleFactor * (CGFloat(row) + 0.5)), to: nil)
            let hovered = expectation(description: "TUI 링크 hover")
            coordinator.onHover = {
                if $0 == url {
                    coordinator.onHover = nil
                    hovered.fulfill()
                }
            }
            let hover = try XCTUnwrap(NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ))
            view.mouseMoved(with: hover)
            await fulfillment(of: [hovered], timeout: 5)
            XCTAssertEqual(view.hoveredLink, url)
            let opened = expectation(description: "TUI PR 링크 열기")
            coordinator.openExternalURL = {
                XCTAssertEqual($0.absoluteString, url)
                opened.fulfill()
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
                if type == .leftMouseDown { view.mouseDown(with: event) }
                else { view.mouseUp(with: event) }
            }
            await fulfillment(of: [opened], timeout: 5)
        }
        coordinator.openExternalURL = { _ in XCTFail("TUI 드래그는 링크를 열면 안 된다.") }
        let dragY = view.bounds.height - CGFloat(metrics.cellHeightPixels) / window.backingScaleFactor * 1.5
        for (type, column) in [
            (NSEvent.EventType.leftMouseDown, 0.5),
            (.leftMouseDragged, 3.5),
            (.leftMouseUp, 3.5),
        ] {
            let point = view.convert(NSPoint(x: CGFloat(metrics.cellWidthPixels) / window.backingScaleFactor * column,
                                            y: dragY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(reports.values.filter { $0.hasPrefix("\u{1B}[<") }, [
            "\u{1B}[<35;1;1M", "\u{1B}[<0;1;1M", "\u{1B}[<0;1;1m",
            "\u{1B}[<35;1;2M", "\u{1B}[<0;1;2M", "\u{1B}[<0;1;2m",
            "\u{1B}[<0;1;2M", "\u{1B}[<32;4;2M", "\u{1B}[<0;4;2m",
        ])
    }

    @MainActor
    func testMouseMovementOutsideTerminalPreservesDestinationCursor() throws {
        _ = NSApplication.shared
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 150, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        defer { NSCursor.arrow.set() }
        NSCursor.resizeLeftRight.set()
        view.mouseMoved(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
    }

    @MainActor
    func testLateHoverCallbackAfterExitPreservesDestinationCursor() throws {
        _ = NSApplication.shared
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let moved = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        let exited = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: NSPoint(x: 150, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        defer { NSCursor.arrow.set() }
        view.mouseMoved(with: moved)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
        view.mouseExited(with: exited)
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        view.updateHoverLink(nil)
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        NSCursor.resizeLeftRight.set()
        view.updateHoverLink("https://example.com")
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        XCTAssertNil(view.hoveredLink)
        view.updateMouseShape(GHOSTTY_MOUSE_SHAPE_CROSSHAIR)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        view.mouseEntered(with: entered)
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)
        view.updateHoverLink("https://example.com")
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        view.updateHoverLink(nil)
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)
    }

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
            coordinator.onShape = nil
            NSCursor.arrow.set()
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

        let blankPoint = view.convert(NSPoint(x: 200, y: 80), to: nil)
        let blankHover = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: blankPoint, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        view.mouseMoved(with: blankHover)
        for (shape, value, cursor) in [
            ("pointer", GHOSTTY_MOUSE_SHAPE_POINTER, NSCursor.pointingHand),
            ("crosshair", GHOSTTY_MOUSE_SHAPE_CROSSHAIR, NSCursor.crosshair),
            ("default", GHOSTTY_MOUSE_SHAPE_DEFAULT, NSCursor.arrow),
            ("text", GHOSTTY_MOUSE_SHAPE_TEXT, NSCursor.iBeam),
        ] {
            let changed = expectation(description: "OSC 22 \(shape) 커서 요청 처리")
            coordinator.onShape = {
                if $0 == value {
                    coordinator.onShape = nil
                    changed.fulfill()
                }
            }
            session.receive("\u{1B}]22;\(shape)\u{7}")
            await fulfillment(of: [changed], timeout: 5)
            XCTAssertEqual(NSCursor.current, cursor)
            view.mouseMoved(with: blankHover)
            XCTAssertEqual(NSCursor.current, cursor)
        }
    }
}

private final class LinkMouseReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [String] = []

    var values: [String] {
        lock.withLock { reports }
    }

    func append(_ report: String) {
        lock.withLock { reports.append(report) }
    }
}

@MainActor
private final class LinkSignalCoordinator: TerminalTabView.Coordinator, TerminalSurfaceGridResizeDelegate {
    var onTitle: ((String) -> Void)?
    var onHover: ((String?) -> Void)?
    var onShape: ((ghostty_action_mouse_shape_e) -> Void)?
    var onResize: ((TerminalGridMetrics) -> Void)?
    var metrics: TerminalGridMetrics?

    override func terminalDidChangeTitle(_ title: String) {
        super.terminalDidChangeTitle(title)
        onTitle?(title)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        metrics = size
        onResize?(size)
    }

    override func terminalDidUpdateHoverLink(_ url: String?) {
        super.terminalDidUpdateHoverLink(url)
        onHover?(url)
    }

    override func terminalDidChangeMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        super.terminalDidChangeMouseShape(shape)
        onShape?(shape)
    }
}
