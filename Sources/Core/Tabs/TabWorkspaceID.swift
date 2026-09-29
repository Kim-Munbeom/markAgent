import Foundation

enum TabWorkspaceID: Hashable, Identifiable, Sendable {
    case unscoped
    case project(Project.ID)

    var id: Self { self }
}

extension TabWorkspaceID {
    /// UserDefaults 같은 영속 저장소에 쓰는 안정적인 키.
    /// 미분류 workspace는 고정 문자열, 프로젝트 workspace는 프로젝트 UUID 문자열을 사용해 서로 충돌하지 않는다.
    var storageKey: String {
        switch self {
        case .unscoped:
            return Self.unscopedStorageKey
        case .project(let projectID):
            return projectID.uuidString
        }
    }

    /// `storageKey`로 저장된 값을 복원한다. 알 수 없는 문자열은 nil을 돌려주어 호출자가 무시하게 한다.
    init?(storageKey: String) {
        if storageKey == Self.unscopedStorageKey {
            self = .unscoped
        } else if let projectID = UUID(uuidString: storageKey) {
            self = .project(projectID)
        } else {
            return nil
        }
    }

    private static let unscopedStorageKey = "unscoped"
}
