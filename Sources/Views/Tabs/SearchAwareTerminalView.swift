import AppKit
import GhosttyTerminal

final class SearchAwareTerminalView: AppTerminalView {
    var onSearchShortcut: ((SidebarSearchMode) -> Void)?
    var onSnippetShortcut: ((String) -> Void)?
    var selectedTextProvider: (() -> String?)?
    var isActiveTerminal: @MainActor () -> Bool = { true }
    private(set) weak var searchState: TerminalSearchState?
    private(set) var searchBar: TerminalSearchBar?
    private(set) var hoveredLink: String?
    private var pendingLinkClick: String?

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        pendingLinkClick = isActiveTerminal() && modifiers.isEmpty && event.clickCount == 1 ? hoveredLink : nil
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        pendingLinkClick = nil
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let url = pendingLinkClick
        pendingLinkClick = nil
        super.mouseUp(with: event)
        guard isActiveTerminal(), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let url else { return }
        (delegate as? any TerminalSurfaceOpenURLDelegate)?.terminalDidRequestOpenURL(url, kind: .unknown)
    }

    func updateHoverLink(_ url: String?) {
        hoveredLink = url
        guard isActiveTerminal() else { return }
        (url == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    override func mouseMoved(with event: NSEvent) {
        // 상위 뷰의 드래그 처리도 이 메서드를 호출하므로 선택 중에는 수정키를 바꾸지 않는다.
        guard event.type == .mouseMoved else {
            super.mouseMoved(with: event)
            return
        }
        // Ghostty의 링크 탐지는 macOS에서 Command 수정키가 있어야 활성화된다.
        let linkEvent = NSEvent.mouseEvent(
            with: event.type, location: event.locationInWindow,
            modifierFlags: event.modifierFlags.union(.command),
            timestamp: event.timestamp, windowNumber: event.windowNumber,
            context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount,
            pressure: event.pressure
        )
        super.mouseMoved(with: linkEvent ?? event)
        guard isActiveTerminal() else { return }
        (hoveredLink == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredLink = nil
        pendingLinkClick = nil
        NSCursor.arrow.set()
    }

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
        hoveredLink = nil
        pendingLinkClick = nil
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
