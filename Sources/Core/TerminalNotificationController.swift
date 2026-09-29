import Foundation
import UserNotifications

@MainActor
final class TerminalNotificationController: NSObject, UNUserNotificationCenterDelegate {
    struct Operations {
        var authorizationStatus: () async -> UNAuthorizationStatus
        var requestAuthorization: () async throws -> Bool
        var add: (UNNotificationRequest) async throws -> Void

        static func live(center: UNUserNotificationCenter) -> Operations {
            Operations(
                authorizationStatus: { await center.notificationSettings().authorizationStatus },
                requestAuthorization: { try await center.requestAuthorization(options: [.alert, .sound]) },
                add: { try await center.add($0) }
            )
        }
    }

    private let operations: Operations
    private let onActivate: (UUID) -> Void

    init(operations: Operations, onActivate: @escaping (UUID) -> Void) {
        self.operations = operations
        self.onActivate = onActivate
    }

    @discardableResult
    func send(tabID: UUID, title: String, body: String) async throws -> Bool {
        guard !title.isEmpty || !body.isEmpty else { return false }
        switch await operations.authorizationStatus() {
        case .notDetermined:
            guard try await operations.requestAuthorization() else { return false }
        case .authorized, .provisional:
            break
        case .denied:
            return false
        @unknown default:
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "MarkAgent" : title
        content.body = body
        content.sound = .default
        content.userInfo = ["terminalTabID": tabID.uuidString]
        content.threadIdentifier = "terminal-\(tabID.uuidString)"
        // 같은 탭의 반복 알림은 교체하여 알림 센터에 무제한 쌓이지 않게 한다.
        let request = UNNotificationRequest(
            identifier: content.threadIdentifier,
            content: content,
            trigger: nil
        )
        try await operations.add(request)
        return true
    }

    func activate(tabIDString: String?) {
        guard let tabIDString, let tabID = UUID(uuidString: tabIDString) else { return }
        onActivate(tabID)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let tabIDString = response.notification.request.content.userInfo["terminalTabID"] as? String
        await activate(tabIDString: tabIDString)
    }
}
