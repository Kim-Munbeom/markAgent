import SwiftUI
import XCTest
@testable import ma

final class MarkdownEditingControllerTests: XCTestCase {
    @MainActor
    func testNineActionsAndUTF16Selection() {
        let cases: [(MarkdownEditAction, String)] = [
            (.heading, "# 😀한글"), (.bold, "**😀한글**"), (.italic, "*😀한글*"),
            (.link, "[😀한글](url)"), (.unorderedList, "- 😀한글"),
            (.orderedList, "1. 😀한글"), (.checklist, "- [ ] 😀한글"),
            (.quote, "> 😀한글"), (.inlineCode, "`😀한글`")
        ]
        for (action, expected) in cases {
            let document = MarkdownDocument()
            document.editableContent = "😀한글"
            var range = NSRange(location: 0, length: 4)
            MarkdownEditingController.apply(action, to: document, selectedRange: Binding(get: { range }, set: { range = $0 }))
            XCTAssertEqual(document.editableContent, expected)
            XCTAssertLessThanOrEqual(NSMaxRange(range), expected.utf16.count)
            if case .bold = action { XCTAssertEqual(range, NSRange(location: 2, length: 4)) }
        }
    }

    @MainActor
    func testTrailingEmptyLineFormattingIsPreserved() {
        let document = MarkdownDocument()
        document.editableContent = "a\n"
        var range = NSRange(location: 0, length: 2)
        MarkdownEditingController.apply(.quote, to: document, selectedRange: Binding(get: { range }, set: { range = $0 }))
        XCTAssertEqual(document.editableContent, "> a\n> ")
    }
}
