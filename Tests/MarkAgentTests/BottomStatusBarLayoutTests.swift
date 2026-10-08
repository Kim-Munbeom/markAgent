import AppKit
import SwiftUI
import XCTest
@testable import ma

@MainActor
final class BottomStatusBarLayoutTests: XCTestCase {
    func testCaffeinateToggleReflectsAppOwnershipWhenExternalActivityStaysEnabled() async throws {
        let suiteName = "BottomStatusBarLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let subscriptions = SubscriptionStatusModel(defaults: defaults, loaders: [:])
        let system = SystemStatusModel(operations: SystemStatusModel.Operations(
            createAssertion: { 1 },
            releaseAssertion: { _ in },
            sampleCaffeinateActivity: { true },
            sampleResidentMemory: { 0 }
        ))
        let view = BottomStatusBar(
            subscriptionStatus: subscriptions,
            systemStatus: system,
            onOpenSettings: {}
        )

        await system.sampleCaffeinateActivity()
        XCTAssertTrue(system.isCaffeinateEnabled)
        XCTAssertFalse(view.isCaffeinateToggleOn)
        await system.setCaffeinateEnabled(true)
        XCTAssertTrue(view.isCaffeinateToggleOn)
        await system.setCaffeinateEnabled(false)
        XCTAssertTrue(system.isCaffeinateEnabled)
        XCTAssertFalse(view.isCaffeinateToggleOn)
    }

    func testUsageViewsFitWithFableAndMissingResetInBothDisplayModes() async throws {
        _ = NSApplication.shared
        XCTAssertNotNil(NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil))
        let suiteName = "BottomStatusBarLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let usage = SubscriptionUsage(
            primary: SubscriptionUsageWindow(
                name: "5 hours",
                usedPercent: 20.5,
                resetsAt: Date(timeIntervalSince1970: 1_791_360_000)
            ),
            secondary: SubscriptionUsageWindow(
                name: "7 days",
                usedPercent: 73,
                resetsAt: Date(timeIntervalSince1970: 1_791_705_600)
            ),
            fableWeekly: SubscriptionUsageWindow(
                name: "Fable",
                usedPercent: 64,
                resetsAt: nil
            ),
            observedAt: Date(timeIntervalSince1970: 1_791_336_000)
        )
        let codexUsage = SubscriptionUsage(primary: usage.primary, secondary: usage.secondary)
        let subscriptions = SubscriptionStatusModel(
            defaults: defaults,
            loaders: [.claude: { usage }, .codex: { codexUsage }]
        )
        subscriptions.setEnabled(true, for: .claude)
        subscriptions.setEnabled(true, for: .codex)
        await subscriptions.refreshAll()
        defer { subscriptions.stopPolling() }

        for externalActivity in [false, true] {
            let system = SystemStatusModel(operations: SystemStatusModel.Operations(
                createAssertion: { 1 },
                releaseAssertion: { _ in },
                sampleCaffeinateActivity: { externalActivity },
                sampleResidentMemory: { 64 * 1_024 * 1_024 }
            ))
            await system.sampleCaffeinateActivity()
            for display in UsagePercentageDisplay.allCases {
                subscriptions.usagePercentageDisplay = display
                for scheme in [ColorScheme.light, .dark] {
                    for width: CGFloat in [640, 980] {
                        let view = BottomStatusBar(
                            subscriptionStatus: subscriptions,
                            systemStatus: system,
                            onOpenSettings: {}
                        )
                        let probe = NSHostingController(rootView: view)
                        let size = probe.sizeThatFits(in: CGSize(width: width, height: 28))
                        XCTAssertLessThanOrEqual(size.width, width + 0.5)
                        XCTAssertEqual(size.height, 28, accuracy: 0.5)
                        try capture(
                            view,
                            width: width,
                            scheme: scheme,
                            name: "bar-\(display.rawValue)-\(externalActivity ? "on" : "off")"
                        )
                    }
                }
            }
        }

        for display in UsagePercentageDisplay.allCases {
            subscriptions.usagePercentageDisplay = display
            for scheme in [ColorScheme.light, .dark] {
                let view = UsagePopover(subscriptionStatus: subscriptions, onOpenSettings: {})
                let probe = NSHostingController(rootView: view)
                XCTAssertLessThanOrEqual(
                    probe.sizeThatFits(in: CGSize(width: 420, height: 1_000)).width,
                    420.5
                )
                try capture(view, width: 420, scheme: scheme, name: "popover-\(display.rawValue)")
            }
        }
    }

    private func capture<V: View>(
        _ view: V,
        width: CGFloat,
        scheme: ColorScheme,
        name: String
    ) throws {
        guard let directory = ProcessInfo.processInfo.environment["MARKAGENT_USAGE_QA_DIR"] else {
            return
        }
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, scheme))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1_000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(name)-\(scheme)-\(Int(width)).png"))
    }
}
