import Foundation

@MainActor
final class TerminalSearchState {
    enum Result: Equatable {
        case idle
        case searching
        case unavailable
        case noMatches
        case matches(current: Int?, total: Int)
    }

    private(set) var isPresented = false
    private(set) var query = ""
    private(set) var total: Int?
    private(set) var selected: Int?
    private var isUnavailable = false
    private var needsInitialSelection = false
    private var performAction: ((String) -> Bool)?
    private var onChange: (() -> Void)?

    var result: Result {
        guard !query.isEmpty else { return .idle }
        guard !isUnavailable else { return .unavailable }
        guard let total else { return .searching }
        guard total > 0 else { return .noMatches }
        let current = selected.flatMap { (1...total).contains($0) ? $0 : nil }
        return .matches(current: current, total: total)
    }

    var canNavigate: Bool {
        guard isPresented, !isUnavailable, !query.isEmpty, let total else { return false }
        return total > 0
    }

    func connect(
        performAction: @escaping (String) -> Bool,
        onChange: @escaping () -> Void
    ) {
        self.performAction = performAction
        self.onChange = onChange
    }

    func present() {
        isPresented = true
        onChange?()
    }

    func updateQuery(_ query: String) {
        guard isPresented, self.query != query else { return }
        // Ghostty는 ASCII 대소문자만 바뀐 검색어에는 새 콜백을 보내지 않는다.
        let sameNeedle = self.query.utf8.elementsEqual(query.utf8) { lhs, rhs in
            let left = (65...90).contains(lhs) ? lhs + 32 : lhs
            let right = (65...90).contains(rhs) ? rhs + 32 : rhs
            return left == right
        }
        self.query = query
        if sameNeedle, !isUnavailable {
            onChange?()
            return
        }
        total = nil
        selected = nil
        isUnavailable = false
        needsInitialSelection = !query.isEmpty
        if query.isEmpty {
            _ = performAction?("end_search")
        } else {
            // 반환값은 명령 전달 여부일 뿐 검색 결과 수가 아니다.
            isUnavailable = performAction?("search:\(query)") != true
        }
        onChange?()
    }

    func navigate(backwards: Bool) {
        guard canNavigate else { return }
        _ = performAction?(backwards ? "navigate_search:previous" : "navigate_search:next")
    }

    func receiveTotal(_ total: Int?) {
        guard isPresented, !query.isEmpty, !isUnavailable else { return }
        self.total = total
        if total == 0 { selected = nil }
        // 화면 밖 스크롤백 검색은 일치 개수만 보고하므로 첫 결과를 실제로 선택한다.
        if let total, total > 0, needsInitialSelection {
            needsInitialSelection = false
            _ = performAction?("navigate_search:next")
        }
        onChange?()
    }

    func receiveSelected(_ selected: Int?) {
        guard isPresented, !query.isEmpty, !isUnavailable else { return }
        self.selected = selected
        if selected != nil { needsInitialSelection = false }
        onChange?()
    }

    func dismiss() {
        let wasPresented = isPresented
        isPresented = false
        query = ""
        total = nil
        selected = nil
        isUnavailable = false
        needsInitialSelection = false
        if wasPresented { _ = performAction?("end_search") }
        onChange?()
    }

    func disconnect() {
        dismiss()
        performAction = nil
        onChange = nil
    }
}
