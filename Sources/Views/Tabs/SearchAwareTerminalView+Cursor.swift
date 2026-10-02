import AppKit
import GhosttyKit

extension SearchAwareTerminalView {
    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        if #available(macOS 15, *) {
            switch shape {
            case GHOSTTY_MOUSE_SHAPE_COL_RESIZE: return .columnResize
            case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: return .rowResize
            case GHOSTTY_MOUSE_SHAPE_N_RESIZE: return .frameResize(position: .top, directions: .outward)
            case GHOSTTY_MOUSE_SHAPE_E_RESIZE: return .frameResize(position: .right, directions: .outward)
            case GHOSTTY_MOUSE_SHAPE_S_RESIZE: return .frameResize(position: .bottom, directions: .outward)
            case GHOSTTY_MOUSE_SHAPE_W_RESIZE: return .frameResize(position: .left, directions: .outward)
            case GHOSTTY_MOUSE_SHAPE_NE_RESIZE: return .frameResize(position: .topRight, directions: .outward)
            case GHOSTTY_MOUSE_SHAPE_NW_RESIZE: return .frameResize(position: .topLeft, directions: .outward)
            case GHOSTTY_MOUSE_SHAPE_SE_RESIZE: return .frameResize(position: .bottomRight, directions: .outward)
            case GHOSTTY_MOUSE_SHAPE_SW_RESIZE: return .frameResize(position: .bottomLeft, directions: .outward)
            case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return .frameResize(position: .left, directions: .all)
            case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return .frameResize(position: .top, directions: .all)
            case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: return .frameResize(position: .topRight, directions: .all)
            case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return .frameResize(position: .topLeft, directions: .all)
            case GHOSTTY_MOUSE_SHAPE_ZOOM_IN: return .zoomIn
            case GHOSTTY_MOUSE_SHAPE_ZOOM_OUT: return .zoomOut
            default: break
            }
        }
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_CELL, GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return .dragLink
        case GHOSTTY_MOUSE_SHAPE_COPY: return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_MOVE, GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NO_DROP, GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: return .resizeDown
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: return .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_NE_RESIZE, GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_SE_RESIZE, GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NESW_RESIZE, GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return .crosshair
        // AppKit이 제공하지 않는 모양은 시스템 기본 포인터를 사용한다.
        default: return .arrow
        }
    }
}
