import AppKit
import SwiftUI
import XCTest
@testable import ma

@MainActor
final class PromptSnippetsSidebarLayoutTests: XCTestCase {
    func testLongPromptRowsUseOnlyThreePreviewLines() throws {
        _ = NSApplication.shared
        let suiteName = "PromptSnippetsSidebarLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PromptSnippetStore(defaults: defaults)
        let sidebar = PromptSnippetsSidebarView(store: store)
        let threeLines = "미리보기\n미리보기\n미리보기"
        let longBody = (1...60).map {
            "미리보기 \($0): 긴 프롬프트의 내용이 목록 전체를 차지하지 않아야 합니다."
        }.joined(separator: "\n")

        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [240, 800] {
                let reference = try renderRow(sidebar, body: threeLines, width: width, scheme: scheme)
                let preview = try renderRow(sidebar, body: longBody, width: width, scheme: scheme, capture: true)
                XCTAssertEqual(preview.height, reference.height, accuracy: 1,
                               "\(scheme), width=\(width)")
                XCTAssertEqual(preview.width, width, accuracy: 1)
            }
        }
        XCTAssertTrue(store.snippets.isEmpty)
    }

    private func renderRow(
        _ sidebar: PromptSnippetsSidebarView,
        body: String,
        width: CGFloat,
        scheme: ColorScheme,
        capture: Bool = false
    ) throws -> NSSize {
        let date = Date(timeIntervalSince1970: 0)
        let snippet = PromptSnippet(id: UUID(), body: body, createdAt: date, updatedAt: date)
        let root = sidebar.snippetRow(snippet, isCopied: false)
            .frame(width: width)
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        if capture, let directory = ProcessInfo.processInfo.environment["MARKAGENT_PROMPT_PREVIEW_QA_DIR"] {
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(scheme)-\(Int(width)).png"))
        }
        return size
    }
}
