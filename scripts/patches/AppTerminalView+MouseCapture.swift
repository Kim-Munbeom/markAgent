#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import GhosttyKit

extension AppTerminalView {
    public var isMouseCaptured: Bool {
        guard let surface = surface?.rawValue else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    public func invalidateMousePosition(modifiers: NSEvent.ModifierFlags = []) {
        guard let surface = surface?.rawValue else { return }
        // 임베디드 엔진은 같은 좌표에서 수정키만 바뀐 이벤트를 무시한다.
        ghostty_surface_mouse_pos(surface, -1, -1, TerminalInputModifiers(from: modifiers).ghosttyMods)
    }

    public func updateMousePosition(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard let surface = surface?.rawValue else { return }
        ghostty_surface_mouse_pos(
            surface, point.x, bounds.height - point.y,
            TerminalInputModifiers(from: modifiers).ghosttyMods
        )
    }
}
#endif
