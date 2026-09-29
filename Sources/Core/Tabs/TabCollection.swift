import Foundation

@MainActor
@Observable
final class TabCollection {
    private struct WorkspaceState {
        var rootDirectory: URL?
        var tabIDs: [UUID] = []
        var activeTabID: UUID?
        var lastActiveGroupID: TabGroupID?
    }

    private(set) var allTabs: [any MarkAgentTab] = []
    private var allTabGroups: [TabGroupID: TabGroupState] = [:]
    private var workspaces: [TabWorkspaceID: WorkspaceState]
    private(set) var activeWorkspaceID: TabWorkspaceID
    /// 상단 탭 바를 숨긴 workspace 집합. 탭 데이터와 분리해 두어 아직 열리지 않은 프로젝트의 설정도 보존한다.
    private var hiddenTabBarWorkspaceIDs: Set<TabWorkspaceID>
    private let defaults: UserDefaults
    weak var dirtyPrompter: DirtyDocumentPrompting?

    init(unscopedRootDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        let rootDirectory = unscopedRootDirectory?.standardizedFileURL
        self.activeWorkspaceID = .unscoped
        self.workspaces = [
            .unscoped: WorkspaceState(rootDirectory: rootDirectory)
        ]
        self.defaults = defaults
        self.hiddenTabBarWorkspaceIDs = Self.loadHiddenTabBarWorkspaceIDs(from: defaults)
    }

    var tabs: [any MarkAgentTab] {
        tabs(in: activeWorkspaceID)
    }

    var tabGroups: [TabGroupID: TabGroupState] {
        let visibleGroupIDs = Set(tabs.compactMap(\.groupID))
        return allTabGroups.filter { visibleGroupIDs.contains($0.key) }
    }

    var activeTabID: UUID? {
        workspaces[activeWorkspaceID]?.activeTabID
    }

    var activeTab: (any MarkAgentTab)? {
        guard let activeTabID else { return nil }
        return tab(withID: activeTabID)
    }

    var activeTerminalTab: TerminalTab? {
        activeTab as? TerminalTab
    }

    var activeTabGroup: TabGroupState? {
        if let groupID = activeTab?.groupID {
            return allTabGroups[groupID]
        }
        if let groupID = workspaces[activeWorkspaceID]?.lastActiveGroupID {
            return allTabGroups[groupID]
        }
        return nil
    }

    var activeMarkdownTab: MarkdownTab? {
        activeTab as? MarkdownTab
    }

    var activeGitDiffTab: GitDiffTab? {
        activeTab as? GitDiffTab
    }

    var activeSettingsTab: SettingsTab? {
        activeTab as? SettingsTab
    }

    var activeAboutTab: AboutTab? {
        activeTab as? AboutTab
    }

    var hasTabs: Bool {
        !tabs.isEmpty
    }

    /// 활성 workspace의 상단 탭 바 숨김 여부. workspace를 전환하면 해당 workspace의 설정으로 바뀐다.
    var isTabBarHidden: Bool {
        isTabBarHidden(in: activeWorkspaceID)
    }

    var activeWorkingDirectory: URL? {
        if let terminalTab = activeTerminalTab {
            return terminalTab.state.workingDirectory
        }
        if let markdownTab = activeMarkdownTab,
           let fileURL = markdownTab.fileURL {
            return fileURL.deletingLastPathComponent().standardizedFileURL
        }
        return activeTabGroup?.workingDirectory
            ?? workspaces[activeWorkspaceID]?.rootDirectory
    }

    var orderedGroupIDs: [TabGroupID] {
        var seen: Set<TabGroupID> = []
        var ordered: [TabGroupID] = []

        for tab in tabs {
            guard let groupID = tab.groupID,
                  !seen.contains(groupID) else {
                continue
            }
            seen.insert(groupID)
            ordered.append(groupID)
        }

        return ordered
    }

    func groupShortcutNumber(for groupID: TabGroupID?) -> Int? {
        guard let groupID,
              let index = orderedGroupIDs.firstIndex(of: groupID),
              index < 9 else {
            return nil
        }
        return index + 1
    }

    @discardableResult
    func ensureWorkspace(_ workspaceID: TabWorkspaceID, rootDirectory: URL?) -> Bool {
        let standardizedRoot = rootDirectory?.standardizedFileURL
        if var workspace = workspaces[workspaceID] {
            if workspace.rootDirectory == nil, let standardizedRoot {
                workspace.rootDirectory = standardizedRoot
                workspaces[workspaceID] = workspace
            }
            return true
        }

        workspaces[workspaceID] = WorkspaceState(rootDirectory: standardizedRoot)
        return true
    }

    @discardableResult
    func selectWorkspace(_ workspaceID: TabWorkspaceID) -> Bool {
        guard workspaces[workspaceID] != nil else { return false }
        activeWorkspaceID = workspaceID
        syncLastActiveGroup(in: workspaceID)
        return true
    }

    @discardableResult
    func updateWorkspaceRoot(_ rootDirectory: URL, for workspaceID: TabWorkspaceID) -> Bool {
        guard var workspace = workspaces[workspaceID] else { return false }
        let standardizedRoot = rootDirectory.standardizedFileURL
        guard workspace.rootDirectory != standardizedRoot else { return false }
        workspace.rootDirectory = standardizedRoot
        workspaces[workspaceID] = workspace
        return true
    }

    func workspaceRoot(for workspaceID: TabWorkspaceID) -> URL? {
        workspaces[workspaceID]?.rootDirectory
    }

    /// 지정 workspace의 상단 탭 바가 숨겨져 있는지 여부.
    /// 아직 `ensureWorkspace`로 만들어지지 않은 프로젝트에 대해서도 저장된 설정을 그대로 돌려준다.
    func isTabBarHidden(in workspaceID: TabWorkspaceID) -> Bool {
        hiddenTabBarWorkspaceIDs.contains(workspaceID)
    }

    /// 지정 workspace의 상단 탭 바 숨김 여부를 바꾸고 즉시 영속화한다.
    /// 탭 목록, 활성 탭, 그룹 상태는 건드리지 않으므로 숨겨진 동안에도 세션과 키보드 탐색이 그대로 유지된다.
    func setTabBarHidden(_ isHidden: Bool, in workspaceID: TabWorkspaceID) {
        let didChange: Bool
        if isHidden {
            didChange = hiddenTabBarWorkspaceIDs.insert(workspaceID).inserted
        } else {
            didChange = hiddenTabBarWorkspaceIDs.remove(workspaceID) != nil
        }
        guard didChange else { return }
        saveHiddenTabBarWorkspaceIDs()
    }

    /// 활성 workspace(또는 지정 workspace)의 탭 바 표시 상태를 반전하고, 반전 후의 숨김 여부를 돌려준다.
    /// macOS View 메뉴의 토글 항목이 이 API를 사용한다.
    @discardableResult
    func toggleTabBarHidden(in workspaceID: TabWorkspaceID? = nil) -> Bool {
        let targetID = workspaceID ?? activeWorkspaceID
        let isHidden = !isTabBarHidden(in: targetID)
        setTabBarHidden(isHidden, in: targetID)
        return isHidden
    }

    func tabs(in workspaceID: TabWorkspaceID) -> [any MarkAgentTab] {
        guard let tabIDs = workspaces[workspaceID]?.tabIDs else { return [] }
        let tabByID = Dictionary(uniqueKeysWithValues: allTabs.map { ($0.id, $0) })
        return tabIDs.compactMap { tabByID[$0] }
    }

    func activeTabID(in workspaceID: TabWorkspaceID) -> UUID? {
        workspaces[workspaceID]?.activeTabID
    }

    func workspaceID(forTabID tabID: UUID) -> TabWorkspaceID? {
        workspaces.first { $0.value.tabIDs.contains(tabID) }?.key
    }

    func isActiveTab(id: UUID) -> Bool {
        activeTabID == id && workspaceID(forTabID: id) == activeWorkspaceID
    }

    @discardableResult
    func createTerminalTab(
        workingDirectory: URL,
        workspaceID: TabWorkspaceID? = nil,
        onDirectoryChanged: ((URL) -> Void)? = nil
    ) -> TerminalTab {
        let targetWorkspaceID = workspaceID ?? activeWorkspaceID
        _ = ensureWorkspace(targetWorkspaceID, rootDirectory: nil)

        let id = UUID()
        let groupState = TabGroupState(workingDirectory: workingDirectory)
        allTabGroups[groupState.id] = groupState
        let state = TerminalTabState(id: id, workingDirectory: workingDirectory)
        let tab = TerminalTab(id: id, workingDirectory: workingDirectory, state: state, groupState: groupState)
        state.onCloseRequested = { [weak self, weak tab] in
            guard let self, let tab else { return }
            Task {
                _ = await self.closeTab(id: tab.id)
            }
        }
        state.onDirectoryChanged = { [weak groupState] url in
            groupState?.updateWorkingDirectory(url)
            onDirectoryChanged?(url)
        }

        append(tab, to: targetWorkspaceID)
        setActiveTab(tab.id, in: targetWorkspaceID)
        return tab
    }

    @discardableResult
    func createMarkdownTab(fileURL: URL?) -> MarkdownTab {
        if let fileURL {
            let standardURL = fileURL.standardizedFileURL
            if let existingTab = tabs.compactMap({ $0 as? MarkdownTab }).first(where: {
                $0.fileURL?.standardizedFileURL == standardURL
            }) {
                setActiveTab(existingTab.id, in: activeWorkspaceID)
                return existingTab
            }
        }

        let id = UUID()
        let state = MarkdownTabState(id: id, fileURL: fileURL)
        let groupState = ensureActiveGroup(workingDirectory: fileURL?.deletingLastPathComponent())
        let tab = MarkdownTab(
            id: id,
            fileURL: fileURL,
            state: state,
            groupState: groupState,
            dirtyPrompter: dirtyPrompter
        )
        insert(tab, in: groupState, workspaceID: activeWorkspaceID)
        setActiveTab(tab.id, in: activeWorkspaceID)
        return tab
    }

    @discardableResult
    func showGitDiffTab(state: GitDiffState) -> GitDiffTab {
        if let tab = tabs.first(where: { $0 is GitDiffTab }) as? GitDiffTab {
            setActiveTab(tab.id, in: activeWorkspaceID)
            return tab
        }

        let tab = GitDiffTab(state: state)
        append(tab, to: activeWorkspaceID)
        setActiveTab(tab.id, in: activeWorkspaceID)
        return tab
    }

    @discardableResult
    func showGitDiffTabForActiveGroup() -> GitDiffTab {
        let groupState = ensureActiveGroup()

        if let tab = tabs.first(where: { tab in
            guard let diffTab = tab as? GitDiffTab else { return false }
            return diffTab.groupState?.id == groupState.id
        }) as? GitDiffTab {
            setActiveTab(tab.id, in: activeWorkspaceID)
            return tab
        }

        let tab = GitDiffTab(state: groupState.gitDiffState, groupState: groupState)
        insert(tab, in: groupState, workspaceID: activeWorkspaceID)
        setActiveTab(tab.id, in: activeWorkspaceID)
        return tab
    }

    @discardableResult
    func showSettingsTab() -> SettingsTab {
        if let tab = tabs.first(where: { $0 is SettingsTab }) as? SettingsTab {
            setActiveTab(tab.id, in: activeWorkspaceID)
            return tab
        }

        let tab = SettingsTab()
        append(tab, to: activeWorkspaceID)
        setActiveTab(tab.id, in: activeWorkspaceID)
        return tab
    }

    @discardableResult
    func showAboutTab() -> AboutTab {
        if let tab = tabs.first(where: { $0 is AboutTab }) as? AboutTab {
            setActiveTab(tab.id, in: activeWorkspaceID)
            return tab
        }

        let tab = AboutTab()
        append(tab, to: activeWorkspaceID)
        setActiveTab(tab.id, in: activeWorkspaceID)
        return tab
    }

    func selectTab(id: UUID) {
        guard workspaceID(forTabID: id) == activeWorkspaceID else { return }
        setActiveTab(id, in: activeWorkspaceID)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        setActiveTab(tabs[index].id, in: activeWorkspaceID)
    }

    @discardableResult
    func selectGroup(shortcutNumber: Int) -> Bool {
        guard (1...9).contains(shortcutNumber) else { return false }
        let groupIndex = shortcutNumber - 1
        let groupIDs = orderedGroupIDs
        guard groupIDs.indices.contains(groupIndex) else { return false }

        let groupID = groupIDs[groupIndex]
        let groupTabs = tabs.filter { $0.groupID == groupID }
        guard !groupTabs.isEmpty else { return false }

        let selectedTabID: UUID
        if activeTab?.groupID == groupID,
           let activeTabID,
           let activeGroupIndex = groupTabs.firstIndex(where: { $0.id == activeTabID }) {
            let nextIndex = groupTabs.index(after: activeGroupIndex)
            selectedTabID = groupTabs[nextIndex == groupTabs.endIndex ? groupTabs.startIndex : nextIndex].id
        } else {
            selectedTabID = groupTabs[0].id
        }

        setActiveTab(selectedTabID, in: activeWorkspaceID)
        return true
    }

    func closeTab(id: UUID) async -> Bool {
        guard let workspaceID = workspaceID(forTabID: id),
              var workspace = workspaces[workspaceID],
              let workspaceIndex = workspace.tabIDs.firstIndex(of: id),
              let tab = tab(withID: id) else {
            return false
        }

        let workspaceTabs = tabs(in: workspaceID)
        let closedGroupID = tab.groupID
        let replacementTabID = workspace.activeTabID == id
            ? tabToActivateAfterClosingTab(at: workspaceIndex, in: workspaceTabs)
            : nil

        guard await tab.prepareForClose() else { return false }
        allTabs.removeAll { $0.id == id }
        workspace.tabIDs.remove(at: workspaceIndex)
        if workspace.activeTabID == id {
            workspace.activeTabID = replacementTabID
        }
        workspaces[workspaceID] = workspace
        removeGroupIfOrphaned(closedGroupID)
        syncLastActiveGroup(in: workspaceID)
        return true
    }

    func closeActiveTab() async -> Bool {
        guard let activeTabID else { return false }
        return await closeTab(id: activeTabID)
    }

    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var workspace = workspaces[activeWorkspaceID],
              source.allSatisfy(workspace.tabIDs.indices.contains),
              (0...workspace.tabIDs.count).contains(destination) else {
            return
        }

        workspace.tabIDs.move(fromOffsets: source, toOffset: destination)
        workspaces[activeWorkspaceID] = workspace
    }

    @discardableResult
    func removeWorkspace(
        _ workspaceID: TabWorkspaceID,
        movingTabsTo destinationID: TabWorkspaceID = .unscoped
    ) -> Bool {
        guard workspaceID != .unscoped,
              var destination = workspaces[destinationID] else {
            return false
        }
        // 열기 전에 숨김 설정만 저장한 프로젝트를 삭제하는 경우도 정리한다.
        setTabBarHidden(false, in: workspaceID)
        guard let source = workspaces[workspaceID] else { return false }

        var migratedIDs: [UUID] = []
        var activeReplacementID: UUID?

        for tabID in source.tabIDs {
            guard let tab = tab(withID: tabID) else { continue }
            if let existingSingletonID = existingSingletonID(matching: tab, in: destinationID) {
                allTabs.removeAll { $0.id == tabID }
                if source.activeTabID == tabID {
                    activeReplacementID = existingSingletonID
                }
                continue
            }
            migratedIDs.append(tabID)
        }

        destination.tabIDs.append(contentsOf: migratedIDs)
        let migratedActiveID = activeReplacementID
            ?? source.activeTabID.flatMap { migratedIDs.contains($0) ? $0 : nil }
        if activeWorkspaceID == workspaceID {
            destination.activeTabID = migratedActiveID
                ?? destination.activeTabID
                ?? migratedIDs.first
            destination.lastActiveGroupID = destination.activeTabID
                .flatMap { tab(withID: $0)?.groupID }
                ?? source.lastActiveGroupID
                ?? destination.lastActiveGroupID
            activeWorkspaceID = destinationID
        } else if destination.activeTabID.flatMap({ destination.tabIDs.contains($0) }) == nil {
            destination.activeTabID = migratedActiveID ?? migratedIDs.first
            destination.lastActiveGroupID = destination.activeTabID
                .flatMap { tab(withID: $0)?.groupID }
                ?? destination.lastActiveGroupID
        }

        workspaces[destinationID] = destination
        workspaces[workspaceID] = nil
        removeOrphanedGroups()
        syncLastActiveGroup(in: destinationID)
        return true
    }

    private func append(_ tab: any MarkAgentTab, to workspaceID: TabWorkspaceID) {
        allTabs.append(tab)
        var workspace = workspaces[workspaceID] ?? WorkspaceState()
        workspace.tabIDs.append(tab.id)
        workspaces[workspaceID] = workspace
    }

    private func insert(
        _ tab: any MarkAgentTab,
        in groupState: TabGroupState,
        workspaceID: TabWorkspaceID
    ) {
        allTabs.append(tab)
        var workspace = workspaces[workspaceID] ?? WorkspaceState()
        if let lastGroupIndex = workspace.tabIDs.lastIndex(where: {
            self.tab(withID: $0)?.groupID == groupState.id
        }) {
            workspace.tabIDs.insert(tab.id, at: workspace.tabIDs.index(after: lastGroupIndex))
        } else {
            workspace.tabIDs.append(tab.id)
        }
        workspaces[workspaceID] = workspace
    }

    private func ensureActiveGroup(workingDirectory: URL? = nil) -> TabGroupState {
        if let groupState = activeTabGroup {
            if let workingDirectory, groupState.workingDirectory == nil {
                groupState.updateWorkingDirectory(workingDirectory)
            }
            return groupState
        }

        let groupState = TabGroupState(
            workingDirectory: workingDirectory
                ?? workspaces[activeWorkspaceID]?.rootDirectory
        )
        allTabGroups[groupState.id] = groupState
        var workspace = workspaces[activeWorkspaceID] ?? WorkspaceState()
        workspace.lastActiveGroupID = groupState.id
        workspaces[activeWorkspaceID] = workspace
        return groupState
    }

    private func setActiveTab(_ tabID: UUID, in workspaceID: TabWorkspaceID) {
        guard var workspace = workspaces[workspaceID],
              workspace.tabIDs.contains(tabID) else {
            return
        }
        workspace.activeTabID = tabID
        if let groupID = tab(withID: tabID)?.groupID {
            workspace.lastActiveGroupID = groupID
        }
        workspaces[workspaceID] = workspace
    }

    private func syncLastActiveGroup(in workspaceID: TabWorkspaceID) {
        guard var workspace = workspaces[workspaceID] else { return }
        if let activeTabID = workspace.activeTabID,
           let groupID = tab(withID: activeTabID)?.groupID,
           allTabGroups[groupID] != nil {
            workspace.lastActiveGroupID = groupID
        } else if workspace.lastActiveGroupID.map({ allTabGroups[$0] == nil }) == true {
            workspace.lastActiveGroupID = tabs(in: workspaceID).compactMap(\.groupID).first
        }
        workspaces[workspaceID] = workspace
    }

    private func tabToActivateAfterClosingTab(
        at closingIndex: Int,
        in workspaceTabs: [any MarkAgentTab]
    ) -> UUID? {
        guard workspaceTabs.indices.contains(closingIndex) else { return nil }

        if let groupID = workspaceTabs[closingIndex].groupID {
            if let previousGroupTab = workspaceTabs[..<closingIndex].last(where: { $0.groupID == groupID }) {
                return previousGroupTab.id
            }

            let nextIndex = workspaceTabs.index(after: closingIndex)
            if nextIndex < workspaceTabs.endIndex,
               let nextGroupTab = workspaceTabs[nextIndex...].first(where: { $0.groupID == groupID }) {
                return nextGroupTab.id
            }
        }

        let nextIndex = workspaceTabs.index(after: closingIndex)
        if workspaceTabs.indices.contains(nextIndex) {
            return workspaceTabs[nextIndex].id
        }

        return workspaceTabs[..<closingIndex].last?.id
    }

    private func existingSingletonID(
        matching tab: any MarkAgentTab,
        in workspaceID: TabWorkspaceID
    ) -> UUID? {
        if tab is SettingsTab {
            return tabs(in: workspaceID).first(where: { $0 is SettingsTab })?.id
        }
        if tab is AboutTab {
            return tabs(in: workspaceID).first(where: { $0 is AboutTab })?.id
        }
        return nil
    }

    private func tab(withID id: UUID) -> (any MarkAgentTab)? {
        allTabs.first { $0.id == id }
    }

    private func removeGroupIfOrphaned(_ groupID: TabGroupID?) {
        guard let groupID else { return }
        guard !allTabs.contains(where: { $0.groupID == groupID }) else { return }
        allTabGroups[groupID] = nil
        for workspaceID in workspaces.keys {
            syncLastActiveGroup(in: workspaceID)
        }
    }

    private func removeOrphanedGroups() {
        let liveGroupIDs = Set(allTabs.compactMap(\.groupID))
        allTabGroups = allTabGroups.filter { liveGroupIDs.contains($0.key) }
    }

    // MARK: - 탭 바 숨김 상태 영속화

    /// 탭 바를 숨긴 workspace 목록을 UserDefaults에 저장할 때 쓰는 키.
    /// 값은 `TabWorkspaceID.storageKey` 문자열 배열이며, 미분류("unscoped")와 프로젝트 UUID가 한 배열에 공존한다.
    private static let hiddenTabBarWorkspacesDefaultsKey = "hiddenTabBarWorkspaceIDs"

    private static func loadHiddenTabBarWorkspaceIDs(from defaults: UserDefaults) -> Set<TabWorkspaceID> {
        let storedKeys = defaults.stringArray(forKey: hiddenTabBarWorkspacesDefaultsKey) ?? []
        // 해석할 수 없는 항목(손상된 값 등)은 조용히 버려 기본값(표시)으로 복원한다.
        return Set(storedKeys.compactMap(TabWorkspaceID.init(storageKey:)))
    }

    private func saveHiddenTabBarWorkspaceIDs() {
        // 저장 순서를 고정해 같은 상태면 항상 같은 값이 기록되도록 한다.
        let storedKeys = hiddenTabBarWorkspaceIDs.map(\.storageKey).sorted()
        if storedKeys.isEmpty {
            defaults.removeObject(forKey: Self.hiddenTabBarWorkspacesDefaultsKey)
        } else {
            defaults.set(storedKeys, forKey: Self.hiddenTabBarWorkspacesDefaultsKey)
        }
    }
}
