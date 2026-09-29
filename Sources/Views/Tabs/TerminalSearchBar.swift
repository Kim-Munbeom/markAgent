import AppKit

@MainActor
final class TerminalSearchBar: NSVisualEffectView, NSSearchFieldDelegate {
    weak var terminalView: SearchAwareTerminalView?
    let searchField = NSSearchField()
    let resultLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityIdentifier("terminal-search")

        searchField.placeholderString = String(localized: "Search terminal")
        searchField.setAccessibilityLabel(String(localized: "Search terminal"))
        searchField.setAccessibilityIdentifier("terminal-search-field")
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        resultLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.alignment = .right
        resultLabel.setAccessibilityIdentifier("terminal-search-result")
        resultLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configure(previousButton, symbol: "chevron.up", label: String(localized: "Previous result"),
                  identifier: "terminal-search-previous", action: #selector(previousResult))
        configure(nextButton, symbol: "chevron.down", label: String(localized: "Next result"),
                  identifier: "terminal-search-next", action: #selector(nextResult))
        let closeButton = NSButton()
        configure(closeButton, symbol: "xmark", label: String(localized: "Close search"),
                  identifier: "terminal-search-close", action: #selector(closeSearch))

        let stack = NSStackView(views: [searchField, resultLabel, previousButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var ownsFirstResponder: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let view = responder as? NSView, view.isDescendant(of: self) { return true }
        return searchField.currentEditor() === responder
    }

    func focus() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func update(from state: TerminalSearchState) {
        isHidden = !state.isPresented
        if searchField.stringValue != state.query {
            searchField.stringValue = state.query
        }
        switch state.result {
        case .idle:
            resultLabel.stringValue = ""
        case .searching:
            resultLabel.stringValue = String(localized: "Searching...")
        case .unavailable:
            resultLabel.stringValue = String(localized: "Unavailable")
        case .noMatches:
            resultLabel.stringValue = String(localized: "No results")
        case .matches(let current, let total):
            resultLabel.stringValue = "\(current.map(String.init) ?? "-") / \(total)"
        }
        previousButton.isEnabled = state.canNavigate
        nextButton.isEnabled = state.canNavigate
    }

    func controlTextDidChange(_ notification: Notification) {
        // 한글 조합 중에는 검색을 보내지 않고 확정된 문자열만 전달한다.
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        terminalView?.searchState?.updateQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            terminalView?.dismissTerminalSearch()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            terminalView?.searchState?.navigate(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        default:
            return false
        }
    }

    private func configure(_ button: NSButton, symbol: String, label: String, identifier: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func previousResult() { terminalView?.searchState?.navigate(backwards: true) }
    @objc private func nextResult() { terminalView?.searchState?.navigate(backwards: false) }
    @objc private func closeSearch() { terminalView?.dismissTerminalSearch() }
}
