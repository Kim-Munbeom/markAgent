import AppKit
import GhosttyTerminal
import SwiftUI
import XCTest
@testable import ma

final class TerminalSearchLayoutTests: XCTestCase {
    @MainActor
    func testSearchOverlayDoesNotExpandTerminalBeyondNarrowViewport() throws {
        _ = NSApplication.shared
        let state = TerminalTabState(
            workingDirectory: FileManager.default.temporaryDirectory,
            userConfigProvider: { nil }
        )
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        state.didStart = true
        state.terminalViewState.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let root = TerminalTabView(state: state, isActive: true, isStillActive: { true })
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            state.close()
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()
        let terminal = try XCTUnwrap(state.terminalView as? SearchAwareTerminalView)
        terminal.presentTerminalSearch()
        terminal.dismissTerminalSearch()

        window.setContentSize(NSSize(width: 320, height: 240))
        hostingView.layoutSubtreeIfNeeded()

        let terminalFrame = terminal.convert(terminal.bounds, to: hostingView)
        XCTAssertEqual(hostingView.bounds.width, 320, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(terminalFrame.minX, -0.5)
        XCTAssertLessThanOrEqual(terminalFrame.maxX, hostingView.bounds.maxX + 0.5)
        XCTAssertEqual(terminal.bounds.width, 320, accuracy: 0.5)

        terminal.presentTerminalSearch()
        hostingView.layoutSubtreeIfNeeded()
        let searchBar = try XCTUnwrap(terminal.searchBar)
        let searchFrame = searchBar.convert(searchBar.bounds, to: hostingView)
        XCTAssertGreaterThanOrEqual(searchFrame.minX, -0.5)
        XCTAssertLessThanOrEqual(searchFrame.maxX, hostingView.bounds.maxX + 0.5)
    }
}
