import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ma

final class MarkdownTabLayoutTests: XCTestCase {
    @MainActor
    func testTabRoundTripRetainsReadyEditorUndoSelectionAndScroll() async throws {
        _ = NSApplication.shared
        let suiteName = "MarkdownTabLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tabs = TabCollection(defaults: defaults)
        let markdown = tabs.createMarkdownTab(fileURL: nil)
        let document = markdown.state.document
        document.editorAssetURL = EditorWebViewTests.assetURL
        document.editableContent = (1...80).map { "line \($0)" }.joined(separator: "\n")
        let switched = expectation(description: "About 탭 렌더링")
        let returned = expectation(description: "Markdown 탭 렌더링")
        let closedRender = expectation(description: "닫기 뒤 탭 렌더링")
        var stage = 0
        let root = TabSwitchTestHost(
            tabs: tabs, subscriptionStatus: SubscriptionStatusModel(defaults: defaults, loaders: [:])
        ) { id in
            if stage == 1, id != markdown.id { stage = 0; switched.fulfill() }
            if stage == 2, id == markdown.id { stage = 0; returned.fulfill() }
            if stage == 3, id != markdown.id { stage = 0; closedRender.fulfill() }
        }
        var hosting: NSHostingView? = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting?.layoutSubtreeIfNeeded()
        await document.editorMount?.value
        try await XCTUnwrap(document.editorSession).waitUntilReady()
        weak let originalSession = document.editorSession
        weak let originalWebView = document.editorSession?.webView
        let released = expectation(description: "닫힌 탭의 WKWebView 해제")
        try XCTUnwrap(originalWebView as? EditorWKWebView).onRelease = { released.fulfill() }
        window.makeFirstResponder(originalWebView)
        _ = try await originalWebView?.evaluateJavaScript("""
            (() => {
                const v = window.markAgentEditorView;
                v.focus();
                v.dispatch(v.state.tr.insertText('😀', 1));
                document.querySelector('#editor').scrollTop = 200;
            })()
            """)
        let scroll = try await originalWebView?.evaluateJavaScript("document.querySelector('#editor').scrollTop") as? Double
        XCTAssertGreaterThan(try XCTUnwrap(scroll), 0)
        let selected = originalSession?.selection
        stage = 1
        _ = tabs.showAboutTab()
        await fulfillment(of: [switched], timeout: 5)
        hosting?.layoutSubtreeIfNeeded()
        await document.editorDrain?.value
        let inactiveFlushed = await document.withEditorSnapshot {}
        XCTAssertTrue(inactiveFlushed)
        XCTAssertTrue(document.editorSession === originalSession, "탭 비활성화가 편집기를 해제함")
        XCTAssertFalse(window.firstResponder === originalWebView)
        let hiddenFocused = try await originalWebView?.evaluateJavaScript(
            "document.activeElement === window.markAgentEditorView.dom"
        ) as? Bool
        XCTAssertEqual(hiddenFocused, false)
        stage = 2
        tabs.selectTab(id: markdown.id)
        await fulfillment(of: [returned], timeout: 5)
        hosting?.layoutSubtreeIfNeeded()
        await document.editorMount?.value
        try await XCTUnwrap(document.editorSession).waitUntilReady()
        let activeFlushed = await document.withEditorSnapshot {}
        XCTAssertTrue(activeFlushed)
        XCTAssertTrue(document.editorSession === originalSession, "탭 재진입이 편집기를 다시 생성함")
        XCTAssertTrue(document.editorSession?.webView === originalWebView)
        let activeFocused = try await originalWebView?.evaluateJavaScript(
            "document.activeElement === window.markAgentEditorView.dom"
        ) as? Bool
        XCTAssertEqual(activeFocused, true)
        XCTAssertTrue(window.firstResponder === originalWebView)
        XCTAssertEqual(document.editorSession?.selection, selected)
        let restoredScroll = try await document.editorSession?.webView?.evaluateJavaScript(
            "document.querySelector('#editor').scrollTop"
        ) as? Double
        XCTAssertEqual(restoredScroll, scroll)
        _ = try await document.editorSession?.webView?.evaluateJavaScript("""
            window.markAgentEditorView.dom.dispatchEvent(new KeyboardEvent('keydown',
                {key:'z',code:'KeyZ',metaKey:true,bubbles:true}))
            """)
        let flushed = await document.withEditorSnapshot {}
        XCTAssertTrue(flushed)
        XCTAssertFalse(document.editableContent.hasPrefix("😀"), "탭 전환 후 undo 기록 손실")
        document.content = document.editableContent
        stage = 3
        let closed = await tabs.closeTab(id: markdown.id)
        XCTAssertTrue(closed)
        await fulfillment(of: [closedRender], timeout: 5)
        await document.editorDrain?.value
        await fulfillment(of: [released], timeout: 5)
        XCTAssertNil(document.editorSession)
        XCTAssertNil(originalSession)
        XCTAssertNil(originalWebView)
        window.contentView = nil
        hosting = nil
    }

    @MainActor
    func testRawEditLayoutStaysInsideNarrowCenterViewport() async throws {
        _ = NSApplication.shared
        let suiteName = "MarkdownTabLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tabs = TabCollection(defaults: defaults)
        let state = tabs.createMarkdownTab(fileURL: nil).state
        state.document.editorAssetURL = EditorWebViewTests.assetURL
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

        let probeState = MarkdownTabState()
        probeState.document.editorAssetURL = EditorWebViewTests.assetURL
        let probe = NSHostingController(
            rootView: MarkdownTabView(state: probeState, isActive: false, onOpenFile: {}, onDocumentChanged: {})
        )
        XCTAssertLessThanOrEqual(probe.sizeThatFits(in: CGSize(width: 320, height: 480)).width, 320.5)

        XCTAssertEqual(hostingView.bounds.width, 320, accuracy: 0.5)
        // SwiftUI mount Task가 완료하는 정확한 ready 신호를 기다린다.
        await state.document.editorMount?.value
        try await XCTUnwrap(state.document.editorSession).waitUntilReady()
        hostingView.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(state.document.editorSession?.webView)
        assertInsideViewport(editor, of: hostingView)
        XCTAssertEqual(editor.bounds.width, 320, accuracy: 0.5)
        let geometry = try await editor.evaluateJavaScript("""
            (() => {
                const root = document.querySelector('#editor');
                const content = document.querySelector('.ProseMirror');
                const toggle = document.querySelector('#mode-toggle').getBoundingClientRect();
                return {width:root.getBoundingClientRect().width, clientWidth:root.clientWidth,
                    contentWidth:content.getBoundingClientRect().width,
                    scrollWidth:root.scrollWidth, scrollHeight:root.scrollHeight,
                    height:root.clientHeight, toggleRight:toggle.right, toggleLeft:toggle.left,
                    firstLineOffset:document.querySelector('.raw-line-number').getBoundingClientRect().top
                        - window.markAgentEditorView.coordsAtPos(1).top};
            })()
            """) as? [String: Double]
        XCTAssertEqual(geometry?["width"], 320)
        XCTAssertEqual(geometry?["contentWidth"], geometry?["clientWidth"])
        XCTAssertEqual(geometry?["scrollWidth"], geometry?["clientWidth"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry?["clientWidth"]), 298)
        XCTAssertGreaterThan(try XCTUnwrap(geometry?["scrollHeight"]), try XCTUnwrap(geometry?["height"]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(geometry?["toggleRight"]), 320)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry?["toggleLeft"]), 0)
        XCTAssertEqual(try XCTUnwrap(geometry?["firstLineOffset"]), 0, accuracy: 1)
        XCTAssertGreaterThan(editor.frame.height, hostingView.bounds.height / 2)
        let scrollEnd = try await editor.evaluateJavaScript("""
            (() => { const root = document.querySelector('#editor');
                root.scrollTop = root.scrollHeight;
                return root.scrollTop + root.clientHeight === root.scrollHeight; })()
            """) as? Bool
        XCTAssertEqual(scrollEnd, true)

        window.setContentSize(NSSize(width: 900, height: 480))
        hostingView.layoutSubtreeIfNeeded()

        assertInsideViewport(editor, of: hostingView)
        XCTAssertEqual(editor.bounds.width, 900, accuracy: 0.5)
        let wideGeometry = try await editor.evaluateJavaScript("""
            ({width:document.querySelector('#editor').getBoundingClientRect().width,
              clientWidth:document.querySelector('#editor').clientWidth,
              contentWidth:document.querySelector('.ProseMirror').getBoundingClientRect().width})
            """) as? [String: Double]
        XCTAssertEqual(wideGeometry?["width"], 900)
        XCTAssertEqual(wideGeometry?["contentWidth"], wideGeometry?["clientWidth"])
        let session = try XCTUnwrap(state.document.editorSession)
        _ = try await editor.evaluateJavaScript("""
            window.previewConfigured = new Promise((resolve, reject) => {
                const root = document.querySelector('#editor');
                const deadline = setTimeout(() => { observer.disconnect(); reject(new Error('mode timeout')); }, 5000);
                const observer = new MutationObserver(() => {
                    if (root.dataset.mode !== 'preview') return;
                    observer.disconnect(); clearTimeout(deadline); resolve(true);
                });
                observer.observe(root, {attributes:true, attributeFilter:['data-mode']});
            });
            void 0;
            """)
        let tabView = MarkdownTabView(state: state, isActive: false, onOpenFile: {}, onDocumentChanged: {})
        let toggled = await tabView.toggleViewMode()
        XCTAssertTrue(toggled)
        hostingView.layoutSubtreeIfNeeded()
        let configured = try await editor.callAsyncJavaScript(
            "return await window.previewConfigured", arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        XCTAssertEqual(configured, true)
        XCTAssertTrue(state.document.editorSession === session)
        XCTAssertTrue(state.document.editorSession?.webView === editor)
        XCTAssertEqual(state.document.editableContent, (1...40).map { "line \($0) with some raw markdown text" }.joined(separator: "\n"))
        await state.document.editorSession?.dispose()
        await probeState.document.editorMount?.value
        await probeState.document.editorSession?.dispose()
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

}

private struct TabSwitchTestHost: View {
    let tabs: TabCollection
    let subscriptionStatus: SubscriptionStatusModel
    let onRender: (UUID?) -> Void

    var body: some View {
        ActiveTabContentView(
            tabs: tabs, subscriptionStatus: subscriptionStatus,
            onOpenFile: {}, onNewTab: {}, onDocumentChanged: {}, onConfigurationSaved: {}
        ).background(TabRenderProbe(tabID: tabs.activeTabID, onRender: onRender))
    }
}

private struct TabRenderProbe: NSViewRepresentable {
    let tabID: UUID?
    let onRender: (UUID?) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { onRender(tabID) }
}
