import AppKit
import SwiftUI

struct EditorView: View {
    @Bindable var document: MarkdownDocument
    var showsInlineToolbar = true
    var rendersMarkdownStyle = false
    var isActive = true

    var externalSelectedRange: Binding<NSRange>? = nil
    var onToggleViewMode: (() -> Void)? = nil
    @State private var internalSelectedRange: NSRange = NSRange(location: 0, length: 0)
    @State private var cursorPosition = CursorPosition(line: 1, column: 1)

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                EditorWebView(
                    document: document,
                    selectedRange: selectedRangeBinding,
                    isActive: isActive,
                    onToggleViewMode: onToggleViewMode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: selectedRangeBinding.wrappedValue) { _, range in
                    cursorPosition = CursorPosition(EditorLineIndex(text: document.editableContent).cursorPosition(for: range.location))
                }

                if showsInlineToolbar,
                   document.supportsPreview,
                   document.viewMode == .rawEdit,
                   selectedRangeBinding.wrappedValue.length > 0 {
                    InlineEditToolbar { action in
                        apply(action)
                    }
                    .padding(.top, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }

            if !rendersMarkdownStyle {
                EditorStatusBar(
                    fileURL: document.fileURL,
                    cursorPosition: cursorPosition
                )
            }
        }
    }

    private func apply(_ action: MarkdownEditAction) {
        MarkdownEditingController.apply(action, to: document, selectedRange: selectedRangeBinding)
    }

    private var selectedRangeBinding: Binding<NSRange> {
        externalSelectedRange ?? $internalSelectedRange
    }
}

private struct CursorPosition: Equatable {
    var line: Int
    var column: Int

    init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    init(_ position: EditorCursorPosition) {
        line = position.line
        column = position.column
    }
}

private struct EditorStatusBar: View {
    let fileURL: URL?
    let cursorPosition: CursorPosition

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalAppTheme) private var terminalAppTheme

    var body: some View {
        HStack {
            Spacer()
            Text("\(displayPath):\(cursorPosition.line):\(cursorPosition.column)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
        }
        .frame(height: 24)
        .background(appColors?.panel ?? Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .top) {
            Divider().overlay(appColors?.border ?? Color.clear)
        }
    }

    private var appColors: TerminalAppColors? {
        terminalAppTheme?.colors(for: colorScheme)
    }

    private var displayPath: String {
        if let fileURL {
            return fileURL.path
        }
        return String(localized: "Untitled")
    }
}

enum MarkdownEditAction {
    case heading
    case bold
    case italic
    case link
    case unorderedList
    case orderedList
    case checklist
    case quote
    case inlineCode
}

@MainActor
enum MarkdownEditingController {
    static func apply(_ action: MarkdownEditAction, to document: MarkdownDocument, selectedRange: Binding<NSRange>) {
        guard let session = document.editorSession else {
            applySnapshot(action, to: document, selectedRange: selectedRange)
            return
        }
        Task {
            await document.withEditorSnapshot(preservingUndo: true) {
                selectedRange.wrappedValue = session.selection
                applySnapshot(action, to: document, selectedRange: selectedRange)
                session.setHostSelection(selectedRange.wrappedValue)
            }
        }
    }

    private static func applySnapshot(_ action: MarkdownEditAction, to document: MarkdownDocument, selectedRange: Binding<NSRange>) {
        let text = document.editableContent
        let nsText = text as NSString
        let safeRange = NSIntersectionRange(
            selectedRange.wrappedValue,
            NSRange(location: 0, length: nsText.length)
        )

        guard safeRange.location != NSNotFound else { return }

        switch action {
        case .heading:
            replaceLineRange(in: nsText, document: document, selectedRange: selectedRange, selection: safeRange) { lines in
                lines
                    .components(separatedBy: "\n")
                    .map { line in
                        line.hasPrefix("# ") ? String(line.dropFirst(2)) : "# \(line)"
                    }
                    .joined(separator: "\n")
            }
        case .bold:
            wrapSelection(prefix: "**", suffix: "**", placeholder: String(localized: "굵은 텍스트"), in: document, selectedRange: selectedRange, range: safeRange)
        case .italic:
            wrapSelection(prefix: "*", suffix: "*", placeholder: String(localized: "기울임 텍스트"), in: document, selectedRange: selectedRange, range: safeRange)
        case .link:
            wrapSelection(prefix: "[", suffix: "](url)", placeholder: String(localized: "링크"), in: document, selectedRange: selectedRange, range: safeRange)
        case .unorderedList:
            prefixSelectedLines("- ", in: document, selectedRange: selectedRange, range: safeRange)
        case .orderedList:
            prefixSelectedLines(numbered: true, in: document, selectedRange: selectedRange, range: safeRange)
        case .checklist:
            prefixSelectedLines("- [ ] ", in: document, selectedRange: selectedRange, range: safeRange)
        case .quote:
            prefixSelectedLines("> ", in: document, selectedRange: selectedRange, range: safeRange)
        case .inlineCode:
            wrapSelection(prefix: "`", suffix: "`", placeholder: String(localized: "code"), in: document, selectedRange: selectedRange, range: safeRange)
        }
    }

    private static func wrapSelection(
        prefix: String,
        suffix: String,
        placeholder: String,
        in document: MarkdownDocument,
        selectedRange: Binding<NSRange>,
        range: NSRange
    ) {
        let nsText = document.editableContent as NSString
        let selected = range.length > 0 ? nsText.substring(with: range) : placeholder
        let replacement = "\(prefix)\(selected)\(suffix)"
        document.editableContent = nsText.replacingCharacters(in: range, with: replacement)
        selectedRange.wrappedValue = NSRange(location: range.location + prefix.utf16.count, length: selected.utf16.count)
    }

    private static func prefixSelectedLines(
        _ prefix: String,
        in document: MarkdownDocument,
        selectedRange: Binding<NSRange>,
        range: NSRange
    ) {
        replaceLineRange(in: document.editableContent as NSString, document: document, selectedRange: selectedRange, selection: range) { lines in
            lines
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? prefix : "\(prefix)\($0)" }
                .joined(separator: "\n")
        }
    }

    private static func prefixSelectedLines(
        numbered: Bool,
        in document: MarkdownDocument,
        selectedRange: Binding<NSRange>,
        range: NSRange
    ) {
        guard numbered else { return }
        replaceLineRange(in: document.editableContent as NSString, document: document, selectedRange: selectedRange, selection: range) { lines in
            lines
                .components(separatedBy: "\n")
                .enumerated()
                .map { index, line in "\(index + 1). \(line)" }
                .joined(separator: "\n")
        }
    }

    private static func replaceLineRange(
        in nsText: NSString,
        document: MarkdownDocument,
        selectedRange: Binding<NSRange>,
        selection: NSRange,
        transform: (String) -> String
    ) {
        let lineRange = nsText.lineRange(for: selection)
        let selectedLines = nsText.substring(with: lineRange)
        let replacement = transform(selectedLines)
        document.editableContent = nsText.replacingCharacters(in: lineRange, with: replacement)
        selectedRange.wrappedValue = NSRange(location: lineRange.location, length: (replacement as NSString).length)
    }
}

private struct InlineEditToolbar: View {
    var onAction: (MarkdownEditAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            toolbarButton("H", help: String(localized: "제목"), action: .heading)
            toolbarButton("B", help: String(localized: "굵게"), action: .bold)
            toolbarButton("I", help: String(localized: "기울임"), action: .italic)
                .italic()
            toolbarButton(systemImage: "link", help: String(localized: "링크"), action: .link)
            toolbarButton(systemImage: "list.bullet", help: String(localized: "글머리 기호"), action: .unorderedList)
            toolbarButton(systemImage: "list.number", help: String(localized: "번호 목록"), action: .orderedList)
            toolbarButton(systemImage: "checklist", help: String(localized: "체크리스트"), action: .checklist)
            toolbarButton(systemImage: "quote.opening", help: String(localized: "인용"), action: .quote)
            toolbarButton(systemImage: "chevron.left.forwardslash.chevron.right", help: String(localized: "인라인 코드"), action: .inlineCode)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func toolbarButton(_ title: String, help: String, action: MarkdownEditAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toolbarButton(systemImage: String, help: String, action: MarkdownEditAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
