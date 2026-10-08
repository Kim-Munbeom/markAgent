import SwiftUI

struct MarkdownTabView: View {
    var state: MarkdownTabState
    var isActive: Bool
    var onOpenFile: () -> Void
    var onDocumentChanged: () -> Void

    @State private var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalAppTheme) private var terminalAppTheme

    var externalUpdateAlertBinding: Binding<Bool> {
        Binding(
            get: { isActive && state.document.isExternalUpdatePending },
            set: { if isActive { state.document.isExternalUpdatePending = $0 } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .alert(
                "파일이 외부에서 수정되었습니다",
                isPresented: externalUpdateAlertBinding
            ) {
                Button("외부 변경 로드") {
                    let document = state.document
                    Task {
                        await document.withEditorSnapshot { document.acceptExternalUpdate() }
                    }
                }
                Button("내 변경 유지") { state.document.rejectExternalUpdate() }
                Button("취소", role: .cancel) { state.document.rejectExternalUpdate() }
            } message: {
                Text("편집 중인 내용과 파일의 내용이 다릅니다. 어떻게 하시겠습니까?")
            }
            .onChange(of: state.document.editableContent) { _, _ in
                onDocumentChanged()
            }
            .background(appColors?.background ?? Color(nsColor: .windowBackgroundColor))
            .foregroundStyle(appColors?.foreground ?? Color.primary)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let errorMessage = state.document.errorMessage {
            errorView(message: errorMessage)
        } else if !state.document.isLoaded {
            loadingView
        } else {
            if state.document.viewMode == .preview,
               state.document.showDiff, let diffResult = state.document.diffResult {
                DiffOverlayView(diffResult: diffResult, baseURL: documentImageBaseURL) {
                    state.document.showDiff = false
                }
            } else {
                rawEditor
            }
        }
    }

    private var rawEditor: some View {
        EditorView(
            document: state.document,
            showsInlineToolbar: false,
            rendersMarkdownStyle: state.document.viewMode == .preview,
            isActive: isActive,
            externalSelectedRange: $selectedRange,
            onToggleViewMode: { Task { await toggleViewMode() } }
        )
    }

    @MainActor
    @discardableResult
    func toggleViewMode() async -> Bool {
        let document = state.document
        return await document.withEditorSnapshot {
            guard document.supportsPreview else { return }
            document.viewMode = document.viewMode == .preview ? .rawEdit : .preview
        }
    }

    private var documentImageBaseURL: URL? {
        state.document.fileURL?.deletingLastPathComponent()
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("파일을 로드하는 중...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDocumentView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("빈 문서입니다.")
                .foregroundStyle(.secondary)
            Button(action: onOpenFile) {
                Label("파일 열기", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appColors: TerminalAppColors? {
        terminalAppTheme?.colors(for: colorScheme)
    }
}
