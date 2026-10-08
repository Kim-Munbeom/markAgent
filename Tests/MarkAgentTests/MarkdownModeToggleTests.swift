import XCTest
@testable import ma

final class MarkdownModeToggleTests: XCTestCase {
    @MainActor
    func testInactiveTabDefersExternalChangeAlertWithoutClearingPendingState() async throws {
        try await withTab { state, activeView in
            state.document.isExternalUpdatePending = true
            let hiddenView = MarkdownTabView(
                state: state, isActive: false, onOpenFile: {}, onDocumentChanged: {}
            )
            XCTAssertFalse(hiddenView.externalUpdateAlertBinding.wrappedValue)
            hiddenView.externalUpdateAlertBinding.wrappedValue = false
            XCTAssertTrue(state.document.isExternalUpdatePending)
            XCTAssertTrue(activeView.externalUpdateAlertBinding.wrappedValue)
        }
    }

    @MainActor
    func testAlertDismissalPreservesPendingExternalContentForAsyncAcceptance() async throws {
        try await withTab { state, view in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at: url) }
            try "external".write(to: url, atomically: true, encoding: .utf8)
            state.document.content = "saved"
            state.document.editableContent = "local"
            state.document.load(from: url)
            XCTAssertTrue(state.document.isExternalUpdatePending)
            view.externalUpdateAlertBinding.wrappedValue = false
            let accepted = await state.document.withEditorSnapshot {
                state.document.acceptExternalUpdate()
            }
            XCTAssertTrue(accepted)
            XCTAssertEqual(state.document.editableContent, "external")
        }
    }

    @MainActor
    func testSingleToggleChangesDocumentModeInBothDirections() async throws {
        try await withTab { state, view in
            state.document.editableContent = "😀\r\n한글"
            XCTAssertEqual(state.document.viewMode, .rawEdit)
            let preview = await view.toggleViewMode()
            XCTAssertTrue(preview)
            XCTAssertEqual(state.document.viewMode, .preview)
            let raw = await view.toggleViewMode()
            XCTAssertTrue(raw)
            XCTAssertEqual(state.document.viewMode, .rawEdit)
            XCTAssertEqual(state.document.editableContent, "😀\r\n한글")
        }
    }

    @MainActor
    func testNonMarkdownDocumentCannotEnterPreview() async throws {
        try await withTab { state, view in
            state.document.supportsPreview = false
            let completed = await view.toggleViewMode()
            XCTAssertTrue(completed)
            XCTAssertEqual(state.document.viewMode, .rawEdit)
        }
    }

    @MainActor
    func testFailedSnapshotKeepsCurrentMode() async throws {
        try await withTab { state, view in
            state.document.editorFailure = EditorSessionError.timeout
            let completed = await view.toggleViewMode()
            XCTAssertFalse(completed)
            XCTAssertEqual(state.document.viewMode, .rawEdit)
        }
    }

    @MainActor
    private func withTab(
        _ body: (MarkdownTabState, MarkdownTabView) async throws -> Void
    ) async throws {
        let suiteName = "MarkdownModeToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tabs = TabCollection(defaults: defaults)
        let state = tabs.createMarkdownTab(fileURL: nil).state
        let view = MarkdownTabView(
            state: state, isActive: true, onOpenFile: {}, onDocumentChanged: {}
        )
        try await body(state, view)
    }
}
