import AppKit
import GhosttyTerminal
import GhosttyKit

final class SearchAwareTerminalView: AppTerminalView {
    var onSearchShortcut: ((SidebarSearchMode) -> Void)?
    var onSnippetShortcut: ((String) -> Void)?
    var selectedTextProvider: (() -> String?)?
    var isActiveTerminal: @MainActor () -> Bool = { true }
    private(set) weak var searchState: TerminalSearchState?
    private(set) var searchBar: TerminalSearchBar?
    private(set) var hoveredLink: String?
    private var pendingLinkClick: String?
    private var isPointerInside = false
    private var requestedCursor = NSCursor.iBeam

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
        guard isActiveTerminal(), isPointerInside else {
            hoveredLink = nil
            return
        }
        hoveredLink = url
        updatePointerCursor()
    }

    func updateMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        requestedCursor = Self.cursor(for: shape)
        updatePointerCursor()
    }

    private func updatePointerCursor() {
        guard isActiveTerminal(), isPointerInside else { return }
        (hoveredLink == nil ? requestedCursor : NSCursor.pointingHand).set()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        super.mouseEntered(with: event)
        updatePointerCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        // 상위 뷰의 드래그 처리도 이 메서드를 호출하므로 선택 중에는 수정키를 바꾸지 않는다.
        guard event.type == .mouseMoved else {
            super.mouseMoved(with: event)
            return
        }
        // 엔진이 빈 칸의 nil 콜백을 보내지 않아도 이전 링크가 클릭되지 않게 한다.
        hoveredLink = nil
        pendingLinkClick = nil
        // first responder에는 터미널 밖의 이동도 전달되므로 다른 영역의 커서를 덮어쓰지 않는다.
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard isPointerInside else { return }
        // TUI에는 원래 이동을 전달하고, 캡처를 해제하는 Shift로 링크도 조회한다.
        // 일반 쉘에서는 Shift가 링크 수정키 조건을 깨므로 캡처 중에만 추가한다.
        var linkModifiers = event.modifierFlags.union(.command)
        if isMouseCaptured {
            super.mouseMoved(with: event)
            linkModifiers.insert(.shift)
        }
        // 같은 링크 안 이동과 같은 좌표 재조회도 새 hover 결과를 받는다.
        invalidateMousePosition()
        // Ghostty의 링크 탐지는 macOS에서 Command 수정키가 있어야 활성화된다.
        let linkEvent = NSEvent.mouseEvent(
            with: event.type, location: event.locationInWindow,
            modifierFlags: linkModifiers,
            timestamp: event.timestamp, windowNumber: event.windowNumber,
            context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount,
            pressure: event.pressure
        )
        super.mouseMoved(with: linkEvent ?? event)
        updatePointerCursor()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
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
        isPointerInside = false
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
