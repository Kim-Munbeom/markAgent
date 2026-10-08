import AppKit
import GhosttyTerminal
import GhosttyKit
import XCTest
@testable import ma

final class TerminalScrollIntegrationTests: XCTestCase {
    @MainActor
    func testWheelAfterLinkHoverPreservesActualModifiersInCapturedConversation() async throws {
        _ = NSApplication.shared
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory,
                                     userConfigProvider: { nil })
        let reports = ScrollInputReports()
        let session = InMemoryTerminalSession(write: {
            reports.append(String(decoding: $0, as: UTF8.self))
        }, resize: { _ in })
        let coordinator = ScrollSignalCoordinator()
        coordinator.observeState(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        let resized = expectation(description: "실제 viewport 준비")
        coordinator.onResize = {
            if $0.widthPixels == UInt32(view.bounds.width * window.backingScaleFactor),
               $0.heightPixels == UInt32(view.bounds.height * window.backingScaleFactor) {
                coordinator.onResize = nil
                resized.fulfill()
            }
        }
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.delegate = coordinator
        state.terminalView = view
        view.controller = state.terminalViewState.controller
        window.contentView?.addSubview(view)
        defer {
            coordinator.onTitle = nil
            coordinator.onResize = nil
            NSCursor.arrow.set()
            TerminalTabView.tearDown(view, coordinator: coordinator)
            view.removeFromSuperview()
            window.close()
        }
        await fulfillment(of: [resized], timeout: 5)

        // Claude 전체 화면과 동일한 대체 버퍼·SGR 캡처를 먼저 활성화한다.
        let parsed = expectation(description: "대화 화면과 마우스 모드 파싱")
        coordinator.onTitle = { if $0 == "scroll-fixture-ready" { parsed.fulfill() } }
        session.receive("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1003h\u{1B}[?1006h"
                        + "conversation result\r\n"
                        + "\u{1B}]2;scroll-fixture-ready\u{7}")
        await fulfillment(of: [parsed], timeout: 5)
        coordinator.onTitle = nil
        XCTAssertTrue(view.isMouseCaptured)

        let metrics = try XCTUnwrap(coordinator.metrics)
        let point = view.convert(NSPoint(
            x: CGFloat(metrics.cellWidthPixels) / window.backingScaleFactor * 9.5,
            y: view.bounds.height - CGFloat(metrics.cellHeightPixels) / window.backingScaleFactor * 3.5
        ), to: nil)
        let hover = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0
        ))
        view.mouseMoved(with: hover)

        let screen = try XCTUnwrap(NSScreen.screens.first)
        let step = Int32(metrics.cellHeightPixels)
        for (index, flags, delta, code, column, row) in [
            (0, CGEventFlags(), step, 64, 10, 4),
            (1, CGEventFlags.maskShift, step, 68, 10, 4),
            (2, CGEventFlags(), -step, 65, 14, 6),
            (3, CGEventFlags.maskShift, -step, 69, 14, 6),
        ] {
            view.mouseMoved(with: hover)
            let wheelPoint = view.convert(NSPoint(
                x: CGFloat(metrics.cellWidthPixels) / window.backingScaleFactor * (CGFloat(column) - 0.5),
                y: view.bounds.height - CGFloat(metrics.cellHeightPixels) / window.backingScaleFactor * (CGFloat(row) - 0.5)
            ), to: nil)
            let cgWheel = try XCTUnwrap(CGEvent(
                // 실제 Shift의 세로 modifier를 검사한다. line 휠은 AppKit이
                // Shift를 가로축으로 변환하므로 세로축을 유지하는 pixel 입력을 사용한다.
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: delta, wheel2: 0, wheel3: 0
            ))
            // CGEvent로 만든 NSEvent는 창 번호 0이므로 locationInWindow에
            // 직접 호출할 뷰의 창 좌표가 나오도록 Quartz의 Y축을 변환한다.
            cgWheel.location = NSPoint(x: wheelPoint.x, y: screen.frame.maxY - wheelPoint.y)
            cgWheel.flags = flags
            let wheel = try XCTUnwrap(NSEvent(cgEvent: cgWheel))
            XCTAssertEqual(wheel.locationInWindow, wheelPoint)
            XCTAssertEqual(wheel.modifierFlags.intersection(.deviceIndependentFlagsMask),
                           flags.contains(.maskShift) ? [.shift] : [])
            let completed = expectation(description: "휠 처리 뒤 파서 장벽")
            let title = "wheel-complete-\(index)"
            coordinator.onTitle = { if $0 == title { completed.fulfill() } }
            let before = reports.values.count
            // 수정키 없는 실제 휠은 링크 조회용 Command+Shift를 상속하면 안 된다.
            view.scrollWheel(with: wheel)
            session.receive("\u{1B}]2;\(title)\u{7}")
            await fulfillment(of: [completed], timeout: 5)
            coordinator.onTitle = nil
            let wheelReports = reports.values.dropFirst(before).filter {
                $0.hasPrefix("\u{1B}[<64;") || $0.hasPrefix("\u{1B}[<65;")
                    || $0.hasPrefix("\u{1B}[<68;") || $0.hasPrefix("\u{1B}[<69;")
            }
            XCTAssertFalse(wheelReports.isEmpty, "수신 입력: \(reports.values)")
            XCTAssertEqual(wheelReports, ["\u{1B}[<\(code);\(column);\(row)M"])
        }
    }
}

private final class ScrollInputReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [String] = []
    private var buffer = ""

    var values: [String] { lock.withLock { reports } }

    func append(_ report: String) {
        lock.withLock {
            buffer += report
            while let start = buffer.range(of: "\u{1B}[<"),
                  let end = buffer[start.upperBound...].firstIndex(where: { $0 == "M" || $0 == "m" }) {
                reports.append(String(buffer[start.lowerBound...end]))
                buffer.removeSubrange(...end)
            }
        }
    }
}

@MainActor
private final class ScrollSignalCoordinator: TerminalTabView.Coordinator, TerminalSurfaceGridResizeDelegate {
    var onTitle: ((String) -> Void)?
    var onResize: ((TerminalGridMetrics) -> Void)?
    var metrics: TerminalGridMetrics?

    func terminalDidResize(_ size: TerminalGridMetrics) {
        metrics = size
        onResize?(size)
    }

    override func terminalDidChangeTitle(_ title: String) {
        super.terminalDidChangeTitle(title)
        onTitle?(title)
    }
}
