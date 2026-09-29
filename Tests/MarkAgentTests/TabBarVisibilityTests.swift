import XCTest
@testable import ma

final class TabBarVisibilityTests: XCTestCase {
    private let hiddenWorkspacesDefaultsKey = "hiddenTabBarWorkspaceIDs"

    func testStorageKeyRoundTripsForUnscopedAndProjectWorkspaces() {
        let projectID = UUID()

        XCTAssertEqual(TabWorkspaceID.unscoped.storageKey, "unscoped")
        XCTAssertEqual(TabWorkspaceID.project(projectID).storageKey, projectID.uuidString)
        XCTAssertEqual(TabWorkspaceID(storageKey: "unscoped"), .unscoped)
        XCTAssertEqual(TabWorkspaceID(storageKey: projectID.uuidString), .project(projectID))
        XCTAssertNil(TabWorkspaceID(storageKey: "not-a-workspace"))
    }

    @MainActor
    func testTabBarIsShownByDefaultForEveryWorkspace() throws {
        try withDefaults { defaults in
            let tabs = TabCollection(defaults: defaults)

            XCTAssertFalse(tabs.isTabBarHidden)
            XCTAssertFalse(tabs.isTabBarHidden(in: .unscoped))
            XCTAssertFalse(tabs.isTabBarHidden(in: .project(UUID())))
            XCTAssertNil(defaults.stringArray(forKey: hiddenWorkspacesDefaultsKey))
        }
    }

    @MainActor
    func testHidingTabBarIsIsolatedPerWorkspaceAndFollowsWorkspaceSwitches() throws {
        try withDefaults { defaults in
            let tabs = TabCollection(defaults: defaults)
            let firstWorkspace = TabWorkspaceID.project(UUID())
            let secondWorkspace = TabWorkspaceID.project(UUID())
            XCTAssertTrue(tabs.ensureWorkspace(firstWorkspace, rootDirectory: URL(fileURLWithPath: "/tmp/first")))
            XCTAssertTrue(tabs.ensureWorkspace(secondWorkspace, rootDirectory: URL(fileURLWithPath: "/tmp/second")))

            XCTAssertTrue(tabs.selectWorkspace(firstWorkspace))
            tabs.setTabBarHidden(true, in: firstWorkspace)

            XCTAssertTrue(tabs.isTabBarHidden)
            XCTAssertFalse(tabs.isTabBarHidden(in: secondWorkspace))
            XCTAssertFalse(tabs.isTabBarHidden(in: .unscoped))

            XCTAssertTrue(tabs.selectWorkspace(secondWorkspace))
            XCTAssertFalse(tabs.isTabBarHidden)

            XCTAssertTrue(tabs.selectWorkspace(.unscoped))
            XCTAssertFalse(tabs.isTabBarHidden)

            XCTAssertTrue(tabs.selectWorkspace(firstWorkspace))
            XCTAssertTrue(tabs.isTabBarHidden)
        }
    }

    @MainActor
    func testUnscopedWorkspaceHidesIndependentlyOfProjects() throws {
        try withDefaults { defaults in
            let tabs = TabCollection(defaults: defaults)
            let projectWorkspace = TabWorkspaceID.project(UUID())
            XCTAssertTrue(tabs.ensureWorkspace(projectWorkspace, rootDirectory: URL(fileURLWithPath: "/tmp/project")))

            tabs.setTabBarHidden(true, in: .unscoped)

            XCTAssertTrue(tabs.isTabBarHidden)
            XCTAssertFalse(tabs.isTabBarHidden(in: projectWorkspace))

            XCTAssertTrue(tabs.selectWorkspace(projectWorkspace))
            XCTAssertFalse(tabs.isTabBarHidden)
            XCTAssertTrue(tabs.isTabBarHidden(in: .unscoped))
        }
    }

    @MainActor
    func testHiddenTabBarPersistsAcrossReload() throws {
        try withDefaults { defaults in
            let projectID = UUID()
            let firstSession = TabCollection(defaults: defaults)
            firstSession.setTabBarHidden(true, in: .project(projectID))
            firstSession.setTabBarHidden(true, in: .unscoped)

            let secondSession = TabCollection(defaults: defaults)
            XCTAssertTrue(secondSession.isTabBarHidden(in: .project(projectID)))
            XCTAssertTrue(secondSession.isTabBarHidden(in: .unscoped))
            XCTAssertFalse(secondSession.isTabBarHidden(in: .project(UUID())))

            secondSession.setTabBarHidden(false, in: .unscoped)

            let thirdSession = TabCollection(defaults: defaults)
            XCTAssertFalse(thirdSession.isTabBarHidden(in: .unscoped))
            XCTAssertTrue(thirdSession.isTabBarHidden(in: .project(projectID)))
        }
    }

    @MainActor
    func testHidingTabBarKeepsTabsActiveSelectionAndGroupNavigation() throws {
        try withDefaults { defaults in
            let tabs = TabCollection(defaults: defaults)
            let workspace = TabWorkspaceID.project(UUID())
            let directory = URL(fileURLWithPath: "/tmp/project")
            XCTAssertTrue(tabs.ensureWorkspace(workspace, rootDirectory: directory))
            XCTAssertTrue(tabs.selectWorkspace(workspace))
            let firstTerminal = tabs.createTerminalTab(workingDirectory: directory)
            let markdown = tabs.createMarkdownTab(fileURL: directory.appendingPathComponent("note.md"))
            let secondTerminal = tabs.createTerminalTab(workingDirectory: directory)
            tabs.selectTab(id: markdown.id)
            let tabIDsBeforeHiding = tabs.tabs.map(\.id)

            tabs.setTabBarHidden(true, in: workspace)

            XCTAssertTrue(tabs.isTabBarHidden)
            XCTAssertEqual(tabs.tabs.map(\.id), tabIDsBeforeHiding)
            XCTAssertEqual(tabs.activeTabID, markdown.id)
            XCTAssertTrue(tabs.isActiveTab(id: markdown.id))
            XCTAssertTrue(tabs.activeTabGroup === firstTerminal.groupState)

            XCTAssertTrue(tabs.selectGroup(shortcutNumber: 2))
            XCTAssertEqual(tabs.activeTabID, secondTerminal.id)
            tabs.selectTab(at: 0)
            XCTAssertEqual(tabs.activeTabID, firstTerminal.id)
            XCTAssertTrue(tabs.isTabBarHidden)

            tabs.setTabBarHidden(false, in: workspace)

            XCTAssertFalse(tabs.isTabBarHidden)
            XCTAssertEqual(tabs.tabs.map(\.id), tabIDsBeforeHiding)
            XCTAssertEqual(tabs.activeTabID, firstTerminal.id)
        }
    }

    @MainActor
    func testToggleFlipsTargetWorkspaceAndReportsNewState() throws {
        try withDefaults { defaults in
            let tabs = TabCollection(defaults: defaults)

            XCTAssertTrue(tabs.toggleTabBarHidden())
            XCTAssertTrue(tabs.isTabBarHidden(in: .unscoped))
            XCTAssertEqual(defaults.stringArray(forKey: hiddenWorkspacesDefaultsKey), ["unscoped"])

            XCTAssertFalse(tabs.toggleTabBarHidden())
            XCTAssertFalse(tabs.isTabBarHidden(in: .unscoped))
            XCTAssertNil(defaults.stringArray(forKey: hiddenWorkspacesDefaultsKey))

            let projectWorkspace = TabWorkspaceID.project(UUID())
            XCTAssertTrue(tabs.toggleTabBarHidden(in: projectWorkspace))
            XCTAssertTrue(tabs.isTabBarHidden(in: projectWorkspace))
            XCTAssertFalse(tabs.isTabBarHidden)
        }
    }

    @MainActor
    func testRemovingWorkspaceClearsItsHiddenTabBarSetting() throws {
        try withDefaults { defaults in
            let tabs = TabCollection(defaults: defaults)
            let workspace = TabWorkspaceID.project(UUID())
            let directory = URL(fileURLWithPath: "/tmp/project")
            XCTAssertTrue(tabs.ensureWorkspace(workspace, rootDirectory: directory))
            XCTAssertTrue(tabs.selectWorkspace(workspace))
            let terminal = tabs.createTerminalTab(workingDirectory: directory)
            tabs.setTabBarHidden(true, in: workspace)

            XCTAssertTrue(tabs.removeWorkspace(workspace))

            XCTAssertEqual(tabs.activeWorkspaceID, .unscoped)
            XCTAssertFalse(tabs.isTabBarHidden)
            XCTAssertEqual(tabs.tabs.map(\.id), [terminal.id])
            XCTAssertNil(defaults.stringArray(forKey: hiddenWorkspacesDefaultsKey))
            XCTAssertFalse(TabCollection(defaults: defaults).isTabBarHidden(in: workspace))
        }
    }

    @MainActor
    func testRemovingUnopenedWorkspaceClearsItsSavedVisibility() throws {
        try withDefaults { defaults in
            let tabs = TabCollection(defaults: defaults)
            let workspace = TabWorkspaceID.project(UUID())
            tabs.setTabBarHidden(true, in: workspace)

            XCTAssertFalse(tabs.removeWorkspace(workspace))

            XCTAssertFalse(TabCollection(defaults: defaults).isTabBarHidden(in: workspace))
            XCTAssertNil(defaults.stringArray(forKey: hiddenWorkspacesDefaultsKey))
        }
    }

    @MainActor
    func testUnreadableStoredEntriesAreIgnoredAndDroppedOnNextSave() throws {
        try withDefaults { defaults in
            let projectID = UUID()
            defaults.set(["not-a-workspace", projectID.uuidString, "unscoped"], forKey: hiddenWorkspacesDefaultsKey)

            let tabs = TabCollection(defaults: defaults)

            XCTAssertTrue(tabs.isTabBarHidden(in: .project(projectID)))
            XCTAssertTrue(tabs.isTabBarHidden(in: .unscoped))

            tabs.setTabBarHidden(false, in: .unscoped)

            XCTAssertEqual(defaults.stringArray(forKey: hiddenWorkspacesDefaultsKey), [projectID.uuidString])
        }
    }

    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "TabBarVisibilityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
