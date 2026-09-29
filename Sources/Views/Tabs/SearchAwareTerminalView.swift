import AppKit
import GhosttyTerminal

final class SearchAwareTerminalView: AppTerminalView {
    var onSearchShortcut: ((SidebarSearchMode) -> Void)?
    var onSnippetShortcut: ((String) -> Void)?
    var selectedTextProvider: (() -> String?)?
    var isActiveTerminal: @MainActor () -> Bool = { true }
    private(set) weak var searchState: TerminalSearchState?
    private(set) var searchBar: TerminalSearchBar?

    func connectSearch(_ state: TerminalSearchState) {
        guard searchState !== state else { return }
        searchState?.disconnect()
        searchState = state
        state.connect(
            performAction: { [weak self] in self?.performBindingAction($0) ?? false },
            onChange: { [weak self, weak state] in
                guard let state else { return }
                self?.searchBar?.update(from: state)
            }
        )
    }

    func presentTerminalSearch() {
        guard isActiveTerminal(), let searchState else { return }
        if searchBar == nil {
            let bar = TerminalSearchBar(frame: NSRect(x: 0, y: 0, width: 440, height: 40))
            bar.terminalView = self
            addSubview(bar)
            searchBar = bar
        }
        searchState.present()
        layoutSearchBar()
        searchBar?.focus()
    }

    override func layout() {
        super.layout()
        layoutSearchBar()
    }

    private func layoutSearchBar() {
        guard let searchBar, !bounds.isEmpty else { return }
        // 부모에 제약을 연결하면 검색창의 최소 폭이 터미널 viewport까지 넓힌다.
        let width = min(440, max(0, bounds.width - 16))
        let height = searchBar.fittingSize.height
        searchBar.frame = NSRect(
            x: bounds.maxX - width - 8,
            y: isFlipped ? bounds.minY + 8 : bounds.maxY - height - 8,
            width: width,
            height: height
        )
        searchBar.layoutSubtreeIfNeeded()
    }

    func dismissTerminalSearch(restoringFocus: Bool = true) {
        searchState?.dismiss()
        if restoringFocus, isActiveTerminal() {
            window?.makeFirstResponder(self)
        }
    }

    func disconnectSearch() {
        searchState?.disconnect()
        searchState = nil
        searchBar?.terminalView = nil
        searchBar?.searchField.delegate = nil
        searchBar?.removeFromSuperview()
        searchBar = nil
        isActiveTerminal = { false }
    }

    @discardableResult
    func handleTerminalSearchShortcut(_ event: NSEvent) -> Bool {
        guard isActiveTerminal(), searchState != nil else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command], key == "f" {
            presentTerminalSearch()
            return true
        }
        guard searchState?.isPresented == true else { return false }
        if key == "g", modifiers == [.command] {
            searchState?.navigate(backwards: false)
            return true
        }
        if event.keyCode == 53, modifiers.isEmpty {
            dismissTerminalSearch()
            return true
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isActiveTerminal() else { return false }
        if handleTerminalSearchShortcut(event) { return true }
        if handleSnippetShortcut(event) {
            return true
        }
        if handleSearchShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleTerminalSearchShortcut(event) { return }
        if handleSnippetShortcut(event) {
            return
        }
        if handleSearchShortcut(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func handleSearchShortcut(_ event: NSEvent) -> Bool {
        guard let mode = sidebarSearchMode(for: event) else { return false }
        onSearchShortcut?(mode)
        return true
    }

    private func handleSnippetShortcut(_ event: NSEvent) -> Bool {
        guard isSnippetShortcut(event) else { return false }
        guard let selectedText = selectedTextForSnippet(),
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return true
        }

        onSnippetShortcut?(selectedText)
        return true
    }

    private func isSnippetShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        return key == "c"
    }

    private func selectedTextForSnippet() -> String? {
        if let selectedTextProvider {
            return selectedTextProvider()
        }

        return TerminalSelectionPasteboardReader.readSelectedText {
            performBindingAction("copy_to_clipboard")
        }
    }

    private func sidebarSearchMode(for event: NSEvent) -> SidebarSearchMode? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return nil }

        switch key {
        case "f":
            return .files
        case "g":
            return .grep
        default:
            return nil
        }
    }
}
