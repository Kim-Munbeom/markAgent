import GhosttyTerminal
import SwiftUI

struct TerminalTabView: NSViewRepresentable {
    var state: TerminalTabState
    var isActive: Bool
    var isStillActive: @MainActor () -> Bool
    var onSearchShortcut: (SidebarSearchMode) -> Void = { _ in }
    var onSnippetShortcut: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> AppTerminalView {
        let view = SearchAwareTerminalView()
        view.onSearchShortcut = onSearchShortcut
        view.onSnippetShortcut = onSnippetShortcut
        view.isActiveTerminal = isStillActive
        view.connectSearch(state.search)
        context.coordinator.observeState(state)
        state.terminalView = view
        view.delegate = context.coordinator
        view.controller = state.terminalViewState.controller
        view.configuration = state.terminalViewState.configuration
        view.setSurfaceVisible(isActive)

        state.startIfNeeded()

        if isActive {
            TerminalFocusPolicy.requestFocus(view, isActive: isStillActive)
        } else {
            TerminalFocusPolicy.resignIfNeeded(view)
        }

        return view
    }

    func updateNSView(_ nsView: AppTerminalView, context: Context) {
        if let searchAwareView = nsView as? SearchAwareTerminalView {
            searchAwareView.onSearchShortcut = onSearchShortcut
            searchAwareView.onSnippetShortcut = onSnippetShortcut
            searchAwareView.isActiveTerminal = isStillActive
            searchAwareView.connectSearch(state.search)
        }
        if nsView.controller !== state.terminalViewState.controller {
            nsView.controller = state.terminalViewState.controller
        }
        nsView.configuration = state.terminalViewState.configuration
        if nsView.delegate !== context.coordinator {
            nsView.delegate = context.coordinator
        }
        nsView.setSurfaceVisible(isActive)
        context.coordinator.observeState(state)
        state.terminalView = nsView

        if isActive {
            TerminalFocusPolicy.requestFocus(nsView, isActive: isStillActive)
        } else {
            TerminalFocusPolicy.resignIfNeeded(nsView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppTerminalView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        // 검색 오버레이의 fittingSize가 아니라 쉘이 배정한 viewport를 따른다.
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: AppTerminalView, coordinator: Coordinator) {
        tearDown(nsView, coordinator: coordinator)
    }

    static func tearDown(_ view: AppTerminalView, coordinator: Coordinator) {
        TerminalFocusPolicy.resignIfNeeded(view)
        view.setSurfaceVisible(false)
        coordinator.detach(from: view)
        if let searchAwareView = view as? SearchAwareTerminalView {
            searchAwareView.disconnectSearch()
            searchAwareView.onSearchShortcut = nil
            searchAwareView.onSnippetShortcut = nil
            searchAwareView.selectedTextProvider = nil
        }
        view.delegate = nil
        view.controller = nil
    }

    class Coordinator: NSObject, TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate, TerminalSurfacePwdDelegate, TerminalSurfaceSearchDelegate, TerminalSurfaceLifecycleDelegate, TerminalSurfaceDesktopNotificationDelegate {
        private weak var state: TerminalTabState?

        func observeState(_ state: TerminalTabState) {
            self.state = state
        }

        func detach(from view: AppTerminalView) {
            if state?.terminalView === view {
                state?.terminalView = nil
            }
            state = nil
        }

        func terminalDidChangeTitle(_ title: String) {
            state?.title = title
        }

        func terminalDidClose(processAlive: Bool) {
            state?.onCloseRequested?()
        }

        func terminalDidChangeWorkingDirectory(_ path: String) {
            state?.updateWorkingDirectory(path)
        }

        func terminalDidRequestDesktopNotification(title: String, body: String) {
            state?.onDesktopNotification?(title, body)
        }

        func terminalDidUpdateSearchTotal(_ total: Int?) {
            state?.search.receiveTotal(total)
        }

        func terminalDidUpdateSearchSelected(_ selected: Int?) {
            state?.search.receiveSelected(selected)
        }

        func terminalDidAttachSurface(_ surface: TerminalSurface) {}

        func terminalDidDetachSurface() {
            (state?.terminalView as? SearchAwareTerminalView)?.dismissTerminalSearch(restoringFocus: false)
        }
    }
}

@MainActor
enum TerminalFocusPolicy {
    static func resignIfNeeded(_ view: NSView) {
        guard let window = view.window else {
            return
        }
        let ownsSearchFocus = (view as? SearchAwareTerminalView)?.searchBar?.ownsFirstResponder == true
        guard window.firstResponder === view || ownsSearchFocus else { return }
        window.makeFirstResponder(nil)
    }

    static func requestFocus(
        _ view: NSView,
        isActive: @escaping @MainActor () -> Bool
    ) {
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            guard isActive() else {
                resignIfNeeded(view)
                return
            }
            // 검색 UI의 포커스는 SwiftUI 갱신이나 지연된 터미널 포커스 요청보다 우선한다.
            if (view as? SearchAwareTerminalView)?.searchState?.isPresented == true { return }
            view.window?.makeFirstResponder(view)
        }
    }
}
