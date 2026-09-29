import Foundation

/// 검색 결과는 비동기로 전달되며 nil은 아직 알 수 없는 값이다.
@MainActor
public protocol TerminalSurfaceSearchDelegate: TerminalSurfaceViewDelegate {
    func terminalDidUpdateSearchTotal(_ total: Int?)

    /// 선택된 결과는 1부터 시작한다. nil이면 선택된 결과가 없다.
    func terminalDidUpdateSearchSelected(_ selected: Int?)
}
