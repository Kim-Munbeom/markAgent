import AppKit
import GhosttyTerminal
import UserNotifications
import XCTest
@testable import ma

final class TerminalNotificationTests: XCTestCase {
    @MainActor
    func testInactiveTerminalRoutesItsOwnIdentityAndStopsAfterClose() async throws {
        let suiteName = "TerminalNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tabs = TabCollection(defaults: defaults)
        let source = tabs.createTerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let active = tabs.createTerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let coordinator = TerminalTabView.Coordinator()
        coordinator.observeState(source.state)
        var received: [(UUID, String, String)] = []
        tabs.onTerminalNotification = { received.append(($0, $1, $2)) }

        coordinator.terminalDidRequestDesktopNotification(title: "source", body: "done")

        XCTAssertEqual(received.map(\.0), [source.id])
        XCTAssertEqual(received.map(\.1), ["source"])
        XCTAssertEqual(received.map(\.2), ["done"])
        XCTAssertEqual(tabs.activeTabID, active.id)
        let closed = await tabs.closeTab(id: source.id)
        XCTAssertTrue(closed)
        coordinator.terminalDidRequestDesktopNotification(title: "closed", body: "ignored")
        XCTAssertEqual(received.count, 1)
    }

    @MainActor
    func testClickRestoresExistingProjectTabAndIgnoresClosedTabs() async throws {
        let suiteName = "TerminalNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let delegate = AppDelegate(projectStore: ProjectStore(defaults: defaults))
        let projectWorkspace = TabWorkspaceID.project(UUID())
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let projectTab = delegate.tabs.createTerminalTab(workingDirectory: directory, workspaceID: projectWorkspace)
        let defaultTab = delegate.tabs.createTerminalTab(workingDirectory: directory)

        XCTAssertEqual(delegate.tabs.activeWorkspaceID, .unscoped)
        XCTAssertTrue(delegate.activateTerminalNotification(projectTab.id))
        XCTAssertEqual(delegate.tabs.activeWorkspaceID, projectWorkspace)
        XCTAssertTrue(delegate.tabs.activeTerminalTab === projectTab)
        XCTAssertEqual(delegate.directoryScanner.currentDirectory, directory)
        XCTAssertEqual(delegate.tabs.allTabs.count, 2)

        let closed = await delegate.tabs.closeTab(id: projectTab.id)
        XCTAssertTrue(closed)
        XCTAssertTrue(delegate.tabs.selectWorkspace(.unscoped))
        XCTAssertFalse(delegate.activateTerminalNotification(projectTab.id))
        XCTAssertFalse(delegate.activateTerminalNotification(UUID()))
        XCTAssertTrue(delegate.tabs.activeTerminalTab === defaultTab)
        XCTAssertEqual(delegate.tabs.allTabs.count, 1)
    }

    @MainActor
    func testAuthorizedNotificationPreservesPayloadAndTabIdentity() async throws {
        let recorder = NotificationRecorder(status: .authorized)
        let controller = TerminalNotificationController(operations: recorder.operations, onActivate: { _ in })
        let tabID = UUID()

        let sent = try await controller.send(tabID: tabID, title: "작업 완료", body: "첫 줄\n둘째 줄")

        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.permissionRequests, 0)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertNil(request.trigger)
        XCTAssertEqual(request.content.title, "작업 완료")
        XCTAssertEqual(request.content.body, "첫 줄\n둘째 줄")
        XCTAssertEqual(request.content.userInfo["terminalTabID"] as? String, tabID.uuidString)
        XCTAssertNotNil(request.content.sound)

        _ = try await controller.send(tabID: tabID, title: "", body: "다음 알림")
        XCTAssertEqual(recorder.requests.last?.identifier, request.identifier)
        XCTAssertEqual(recorder.requests.last?.content.title, "MarkAgent")
    }

    @MainActor
    func testFirstNotificationRequestsPermissionAndHonorsDenial() async throws {
        for granted in [true, false] {
            let recorder = NotificationRecorder(status: .notDetermined, permissionGranted: granted)
            let controller = TerminalNotificationController(operations: recorder.operations, onActivate: { _ in })

            let sent = try await controller.send(tabID: UUID(), title: "", body: "완료")

            XCTAssertEqual(sent, granted)
            XCTAssertEqual(recorder.permissionRequests, 1)
            XCTAssertEqual(recorder.requests.count, granted ? 1 : 0)
        }
    }

    @MainActor
    func testDeniedAndEmptyNotificationsDoNotPromptOrDeliver() async throws {
        let recorder = NotificationRecorder(status: .denied)
        let controller = TerminalNotificationController(operations: recorder.operations, onActivate: { _ in })
        let denied = try await controller.send(tabID: UUID(), title: "작업", body: "완료")
        let empty = try await controller.send(tabID: UUID(), title: "", body: "")

        XCTAssertFalse(denied)
        XCTAssertFalse(empty)
        XCTAssertEqual(recorder.permissionRequests, 0)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    @MainActor
    func testActivationOnlyRoutesValidTabIDs() {
        let recorder = NotificationRecorder(status: .authorized)
        var activated: [UUID] = []
        let controller = TerminalNotificationController(operations: recorder.operations) { activated.append($0) }
        let tabID = UUID()

        controller.activate(tabIDString: nil)
        controller.activate(tabIDString: "not-a-tab")
        controller.activate(tabIDString: tabID.uuidString)

        XCTAssertEqual(activated, [tabID])
    }

    @MainActor
    func testActualGhosttyOSC9ReachesTheTabAndDetachesCleanly() async throws {
        try await assertOSCNotification("\u{1B}]9;OSC9 body\u{7}", title: "", body: "OSC9 body")
    }

    @MainActor
    func testActualGhosttyOSC777ReachesTheTabAndDetachesCleanly() async throws {
        try await assertOSCNotification(
            "\u{1B}]777;notify;OSC777 title;OSC777 body\u{7}",
            title: "OSC777 title",
            body: "OSC777 body"
        )
    }

    @MainActor
    private func assertOSCNotification(_ sequence: String, title: String, body: String) async throws {
        // Ghostty 앱당 초당 알림 제한과 독립적으로 각 프로토콜을 검증한다.
        _ = NSApplication.shared
        let state = TerminalTabState(workingDirectory: FileManager.default.temporaryDirectory, userConfigProvider: { nil })
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let coordinator = TerminalTabView.Coordinator()
        coordinator.observeState(state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SearchAwareTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160))
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.delegate = coordinator
        state.terminalView = view
        view.controller = state.terminalViewState.controller
        window.contentView?.addSubview(view)
        defer {
            state.close()
            TerminalTabView.tearDown(view, coordinator: coordinator)
            view.removeFromSuperview()
            window.close()
        }

        let received = expectation(description: "OSC notification")
        var notifications: [(String, String)] = []
        state.onDesktopNotification = { title, body in
            notifications.append((title, body))
            received.fulfill()
        }
        session.receive(sequence)
        await fulfillment(of: [received], timeout: 5)

        XCTAssertEqual(notifications.map(\.0), [title])
        XCTAssertEqual(notifications.map(\.1), [body])
        TerminalTabView.tearDown(view, coordinator: coordinator)
        coordinator.terminalDidRequestDesktopNotification(title: "detached", body: "ignored")
        XCTAssertEqual(notifications.count, 1)
    }
}

@MainActor
private final class NotificationRecorder {
    let status: UNAuthorizationStatus
    let permissionGranted: Bool
    var permissionRequests = 0
    var requests: [UNNotificationRequest] = []

    init(status: UNAuthorizationStatus, permissionGranted: Bool = true) {
        self.status = status
        self.permissionGranted = permissionGranted
    }

    var operations: TerminalNotificationController.Operations {
        .init(
            authorizationStatus: { [self] in status },
            requestAuthorization: { [self] in
                permissionRequests += 1
                return permissionGranted
            },
            add: { [self] in requests.append($0) }
        )
    }
}
