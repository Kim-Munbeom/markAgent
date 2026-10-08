import AppKit
import SwiftUI
import WebKit

struct EditorWebView: NSViewRepresentable {
    let document: MarkdownDocument
    @Binding var selectedRange: NSRange
    var isActive = true
    var assetURL: URL? = nil
    var onToggleViewMode: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalAppTheme) private var terminalAppTheme

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func makeNSView(context: Context) -> NSView {
        let container = EditorContainerView()
        let configuration = configuration
        let asset = assetURL ?? document.editorAssetURL
            ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")
        let coordinator = context.coordinator
        coordinator.lastConfiguration = configuration
        let range = $selectedRange
        coordinator.mount = Task {
            await document.editorDrain?.value
            guard !Task.isCancelled else { return }
            let session = EditorSession(document: document)
            document.editorSession = session
            coordinator.session = session
            session.onSelection = { range.wrappedValue = $0 }
            session.onToggleViewMode = onToggleViewMode
            session.onFormat = { action in
                guard document.supportsPreview, document.viewMode == .rawEdit else { return }
                MarkdownEditingController.apply(action, to: document, selectedRange: range)
            }
            let retainedRange = range.wrappedValue
            let textLength = document.editableContent.utf16.count
            let location = min(max(0, retainedRange.location), textLength)
            session.setHostSelection(NSRange(
                location: location,
                length: min(max(0, retainedRange.length), textLength - location)
            ))
            session.mount(in: container, assetURL: asset, configuration: configuration)
        }
        document.editorMount = coordinator.mount
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let configuration = configuration
        let coordinator = context.coordinator
        if !isActive, let webView = coordinator.session?.webView,
           let window = webView.window, window.firstResponder === webView {
            window.makeFirstResponder(nil)
        }
        if let previous = coordinator.lastConfiguration,
           NSDictionary(dictionary: previous).isEqual(to: configuration) {
            return
        }
        let becameActive = isActive && coordinator.lastConfiguration?["active"] as? Bool == false
        coordinator.lastConfiguration = configuration
        Task {
            await coordinator.mount?.value
            guard let session = coordinator.session else { return }
            if becameActive, coordinator.lastConfiguration?["active"] as? Bool == true {
                session.webView?.window?.makeFirstResponder(session.webView)
            }
            await document.withEditorSnapshot {
                try await session.configure(configuration)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.mount?.cancel()
        if let session = coordinator.session {
            coordinator.document.drainEditor(session)
        }
    }

    private var configuration: [String: Any] {
        let colors = terminalAppTheme?.colors(for: colorScheme)
        return [
            "mode": document.supportsPreview && document.viewMode == .preview ? "preview" : "raw",
            "showsModeToggle": document.supportsPreview && onToggleViewMode != nil,
            "baseURL": document.fileURL?.deletingLastPathComponent().absoluteString ?? "",
            "language": CodeHighlightLanguage(fileURL: document.fileURL)?.rawValue
                ?? (document.supportsPreview ? "markdown" : "text"),
            "active": isActive,
            "theme": [
                "dark": colorScheme == .dark,
                "background": css(colors?.textBackground ?? .textBackgroundColor),
                "foreground": css(colors?.textForeground ?? .textColor),
                "accent": css(colors?.insertionPoint ?? .controlAccentColor),
                "keyword": css(colors?.syntaxMagenta ?? .systemPurple),
                "string": css(colors?.syntaxGreen ?? .systemGreen),
                "number": css(colors?.syntaxYellow ?? .systemOrange),
                "tag": css(colors?.syntaxBlue ?? .systemBlue)
            ]
        ]
    }

    private func css(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return "rgba(\(Int(rgb.redComponent * 255)),\(Int(rgb.greenComponent * 255)),\(Int(rgb.blueComponent * 255)),\(rgb.alphaComponent))"
    }

    @MainActor
    final class Coordinator {
        let document: MarkdownDocument
        var session: EditorSession?
        var mount: Task<Void, Never>?
        var lastConfiguration: [String: Any]?
        init(document: MarkdownDocument) { self.document = document }
    }
}

@MainActor
final class EditorContainerView: NSView {
    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }
}
