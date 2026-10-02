import GhosttyKit

/// 터미널이 요청한 포인터 모양을 호스트 앱에 전달한다.
@MainActor
public protocol TerminalSurfaceMouseShapeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeMouseShape(_ shape: ghostty_action_mouse_shape_e)
}
