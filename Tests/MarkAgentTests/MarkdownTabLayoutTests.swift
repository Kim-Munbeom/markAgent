import AppKit
import SwiftUI
import XCTest
@testable import ma

final class MarkdownTabLayoutTests: XCTestCase {
    @MainActor
    func testRawEditLayoutStaysInsideNarrowCenterViewport() throws {
        _ = NSApplication.shared
        let suiteName = "MarkdownTabLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tabs = TabCollection(defaults: defaults)
        let state = tabs.createMarkdownTab(fileURL: nil).state
        state.document.viewMode = .rawEdit
        state.document.editableContent = (1...40).map { "line \($0) with some raw markdown text" }.joined(separator: "\n")
        let root = ActiveTabContentView(
            tabs: tabs,
            subscriptionStatus: SubscriptionStatusModel(defaults: defaults, loaders: [:]),
            onOpenFile: {},
            onNewTab: {},
            onDocumentChanged: {},
            onConfigurationSaved: {}
        )
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()

        let probe = NSHostingController(
            rootView: MarkdownTabView(state: state, isActive: false, onOpenFile: {}, onDocumentChanged: {})
        )
        XCTAssertLessThanOrEqual(probe.sizeThatFits(in: CGSize(width: 320, height: 480)).width, 320.5)

        XCTAssertEqual(hostingView.bounds.width, 320, accuracy: 0.5)
        let scrollViews = allSubviews(of: hostingView).compactMap { $0 as? NSScrollView }
        let editor = try XCTUnwrap(scrollViews.first { $0.documentView is NSTextView })
        assertInsideViewport(editor, of: hostingView)
        XCTAssertEqual(editor.bounds.width, 320, accuracy: 0.5)
        let textView = try XCTUnwrap(editor.documentView as? NSTextView)
        XCTAssertEqual(textView.string, state.document.editableContent)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        let gutter = try XCTUnwrap(editor.contentView.subviews.first { $0 !== editor.documentView })
        assertInsideViewport(gutter, of: hostingView)
        XCTAssertEqual(gutter.frame.height, editor.contentView.bounds.height, accuracy: 0.5)

        let toolbar = try XCTUnwrap(scrollViews.first { $0 !== editor })
        assertInsideViewport(toolbar, of: hostingView)
        let toolbarContent = try XCTUnwrap(toolbar.documentView)
        XCTAssertGreaterThan(toolbarContent.frame.width, toolbar.contentView.bounds.width)
        XCTAssertGreaterThan(editor.frame.height, hostingView.bounds.height / 2)

        toolbar.contentView.scroll(to: NSPoint(
            x: toolbarContent.frame.width - toolbar.contentView.bounds.width,
            y: toolbar.contentView.bounds.minY
        ))
        toolbar.reflectScrolledClipView(toolbar.contentView)
        XCTAssertEqual(toolbar.documentVisibleRect.maxX, toolbarContent.bounds.maxX, accuracy: 0.5)

        window.setContentSize(NSSize(width: 900, height: 480))
        hostingView.layoutSubtreeIfNeeded()

        assertInsideViewport(editor, of: hostingView)
        XCTAssertEqual(editor.bounds.width, 900, accuracy: 0.5)
        assertInsideViewport(toolbar, of: hostingView)
        XCTAssertLessThanOrEqual(toolbarContent.frame.width, toolbar.contentView.bounds.width + 0.5)
    }

    @MainActor
    private func assertInsideViewport(
        _ view: NSView,
        of hostingView: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = view.convert(view.bounds, to: hostingView)
        XCTAssertGreaterThanOrEqual(frame.minX, hostingView.bounds.minX - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, hostingView.bounds.maxX + 0.5, file: file, line: line)
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

}
