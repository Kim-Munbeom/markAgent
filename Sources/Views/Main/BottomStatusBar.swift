import SwiftUI

@MainActor
struct BottomStatusBar: View {
    var subscriptionStatus: SubscriptionStatusModel
    var systemStatus: SystemStatusModel
    var onOpenSettings: () -> Void

    @State private var isShowingUsage = false
    /// 상태바 새로고침 버튼으로 시작한 전체 갱신이 끝날 때까지 true. 같은 버튼의 중복 클릭을 막는다.
    @State private var isRefreshingUsage = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalAppTheme) private var terminalAppTheme

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isShowingUsage = true
            } label: {
                if subscriptionStatus.enabledProviders.isEmpty {
                    Label("AI 0", systemImage: "waveform.path.ecg")
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            ForEach(subscriptionStatus.enabledProviders) { provider in
                                providerSummary(provider, compact: false)
                            }
                        }

                        Label(
                            "AI \(subscriptionStatus.enabledProviders.count)",
                            systemImage: "waveform.path.ecg"
                        )
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("status-usage")
            .popover(isPresented: $isShowingUsage, arrowEdge: .bottom) {
                UsagePopover(
                    subscriptionStatus: subscriptionStatus,
                    onOpenSettings: {
                        isShowingUsage = false
                        onOpenSettings()
                    }
                )
            }

            usageRefreshButton

            Spacer(minLength: 8)

            Button {
                // 토글은 MarkAgent가 소유한 assertion만 다룬다. 외부 절전 방지는 절대 중지하지 않는다.
                Task {
                    await systemStatus.setCaffeinateEnabled(
                        !systemStatus.isCaffeinateOwnedByApp
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    Image(
                        systemName: systemStatus.isCaffeinateEnabled
                            ? "cup.and.saucer.fill"
                            : "cup.and.saucer"
                    )
                    Text(caffeinateStatusText)
                    Circle()
                        .fill(
                            systemStatus.isCaffeinateEnabled
                                ? (appColors?.accent ?? Color.accentColor)
                                : Color.secondary.opacity(0.5)
                        )
                        .frame(width: 7, height: 7)
                }
            }
            .buttonStyle(.plain)
            .help(caffeinateHelpText)
            .accessibilityLabel("Caffeinate")
            .accessibilityValue(caffeinateStatusText)
            .accessibilityHint(caffeinateHelpText)
            .accessibilityIdentifier("status-caffeinate")

            HStack(spacing: 5) {
                Image(systemName: "memorychip")
                Text(memoryText)
                    .monospacedDigit()
            }
            .foregroundStyle(appColors?.foreground ?? Color.primary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("MarkAgent 메모리 사용량")
            .accessibilityValue(memoryText)
            .accessibilityIdentifier("status-memory")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(appColors?.panel ?? Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(appColors?.border ?? Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .foregroundStyle(appColors?.foreground ?? Color.primary)
        .accessibilityIdentifier("status-bar")
    }

    private var usageRefreshButton: some View {
        Button {
            guard canRefreshUsage else { return }
            isRefreshingUsage = true
            Task {
                await subscriptionStatus.refreshAll()
                isRefreshingUsage = false
            }
        } label: {
            // 아이콘과 스피너를 같은 자리에 겹쳐 두어 갱신 중에도 상태바 폭이 변하지 않게 한다.
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .opacity(isUsageRefreshInProgress ? 0 : 1)
                if isUsageRefreshInProgress {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRefreshUsage)
        .opacity(subscriptionStatus.enabledProviders.isEmpty ? 0.4 : 1)
        .help(String(localized: "사용량 새로고침"))
        .accessibilityLabel("사용량 새로고침")
        .accessibilityValue(isUsageRefreshInProgress ? String(localized: "새로고침 중") : "")
        .accessibilityIdentifier("status-usage-refresh")
    }

    private var isUsageRefreshInProgress: Bool {
        if isRefreshingUsage {
            return true
        }
        return subscriptionStatus.enabledProviders.contains { provider in
            if case .loading = subscriptionStatus.state(for: provider) {
                return true
            }
            return false
        }
    }

    private var canRefreshUsage: Bool {
        !subscriptionStatus.enabledProviders.isEmpty && !isUsageRefreshInProgress
    }

    private func providerSummary(
        _ provider: SubscriptionProvider,
        compact: Bool
    ) -> some View {
        let state = subscriptionStatus.state(for: provider)
        let display = subscriptionStatus.usagePercentageDisplay
        return HStack(spacing: 6) {
            ProviderBrandIcon(provider: provider, size: 14)

            if !compact {
                Text(provider.displayName)
            }

            switch state {
            case .disabled:
                Text("Off")
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView()
                    .controlSize(.mini)
            case .available(let usage):
                UsageProgressBar(
                    usedPercent: usage.primary.usedPercent,
                    display: display,
                    width: 44
                )
                Text(display.percentText(usedPercent: usage.primary.usedPercent))
                    .monospacedDigit()
                if let resetsAt = usage.primary.resetsAt {
                    Text(resetsAt, style: .relative)
                        .foregroundStyle(appColors?.foreground ?? Color.primary)
                }
                if let fable = usage.fableWeekly {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(display.qualifiedPercentText(usedPercent: fable.usedPercent))
                        .monospacedDigit()
                    Text("Fable")
                }
            case .unavailable:
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(providerSummaryAccessibilityValue(state, display: display))
        .accessibilityIdentifier("status-usage-\(provider.rawValue)")
    }

    private func providerSummaryAccessibilityValue(
        _ state: SubscriptionProviderState,
        display: UsagePercentageDisplay
    ) -> String {
        switch state {
        case .disabled:
            return "Off"
        case .loading:
            return String(localized: "사용량을 불러오는 중")
        case .available(let usage):
            var values = [display.accessibilityText(usedPercent: usage.primary.usedPercent)]
            if let resetsAt = usage.primary.resetsAt {
                values.append("reset \(resetsAt.formatted(.relative(presentation: .named)))")
            }
            if let fable = usage.fableWeekly {
                values.append("Fable \(display.accessibilityText(usedPercent: fable.usedPercent))")
            }
            return values.joined(separator: ", ")
        case .unavailable:
            return String(localized: "사용량을 확인할 수 없음")
        }
    }

    private var memoryText: String {
        guard let bytes = systemStatus.residentMemoryBytes else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }

    /// 라벨은 소유 주체와 무관하게 절전 방지가 켜져 있는지만 보여준다. 소유 구분은 도움말이 맡는다.
    private var caffeinateStatusText: String {
        systemStatus.isCaffeinateEnabled ? "On" : "Off"
    }

    private var caffeinateHelpText: String {
        if systemStatus.isCaffeinateOwnedByApp {
            return String(localized: "MarkAgent가 소유한 절전 방지 assertion 끄기")
        }
        if systemStatus.isCaffeinateEnabled {
            return String(localized: "외부 프로세스의 절전 방지는 중지하지 않고 MarkAgent assertion 생성")
        }
        return String(localized: "MarkAgent 절전 방지 assertion 생성")
    }

    private var appColors: TerminalAppColors? {
        terminalAppTheme?.colors(for: colorScheme)
    }
}

@MainActor
struct UsagePopover: View {
    var subscriptionStatus: SubscriptionStatusModel
    var onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalAppTheme) private var terminalAppTheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Usage")
                    .font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()

            if subscriptionStatus.enabledProviders.isEmpty {
                ContentUnavailableView(
                    "등록된 AI 구독이 없습니다.",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Settings에서 Claude 또는 Codex를 활성화하세요.")
                )
                .frame(minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(subscriptionStatus.enabledProviders) { provider in
                        providerDetails(provider)
                        if provider != subscriptionStatus.enabledProviders.last {
                            Divider()
                        }
                    }
                }
            }

            Divider()

            Button(action: onOpenSettings) {
                Label("AI 구독 관리…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(14)
            .accessibilityIdentifier("status-usage-settings")
        }
        .frame(width: 420)
        .foregroundStyle(appColors?.foreground ?? Color.primary)
        .background(appColors?.elevated ?? Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("status-usage-popover")
    }

    @ViewBuilder
    private func providerDetails(_ provider: SubscriptionProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProviderBrandIcon(provider: provider, size: 18)
                Text(provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                stateBadge(subscriptionStatus.state(for: provider))
            }

            switch subscriptionStatus.state(for: provider) {
            case .available(let usage):
                if let observedAt = usage.observedAt {
                    Text(String(
                        format: String(localized: "조회 시각: %@"),
                        observedAt.formatted(date: .omitted, time: .shortened)
                    ))
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
                }
                ForEach(Array(windowsExcludingFable(of: usage).enumerated()), id: \.offset) { _, window in
                    usageWindowRow(provider: provider, window: window)
                }
                if let fableWindow = usage.fableWeekly {
                    usageWindowRow(provider: provider, window: fableWindow)
                        .accessibilityIdentifier("status-usage-fable-\(provider.rawValue)")
                }
            case .disabled:
                Text("Settings에서 활성화할 수 있습니다.")
                    .foregroundStyle(secondaryTextColor)
            case .loading:
                ProgressView("사용량을 불러오는 중…")
                    .controlSize(.small)
            case .unavailable(let message):
                Text(message)
                    .foregroundStyle(secondaryTextColor)
            }
        }
        .padding(16)
    }

    private func windowsExcludingFable(of usage: SubscriptionUsage) -> [SubscriptionUsageWindow] {
        [usage.primary, usage.secondary].compactMap { $0 }
    }

    private func usageWindowRow(
        provider: SubscriptionProvider,
        window: SubscriptionUsageWindow
    ) -> some View {
        let display = subscriptionStatus.usagePercentageDisplay
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.name)
                Spacer()
                Text(display.qualifiedPercentText(usedPercent: window.usedPercent))
                    .monospacedDigit()
            }
            UsageProgressBar(usedPercent: window.usedPercent, display: display)
            if let resetsAt = window.resetsAt {
                HStack {
                    Text("Reset")
                        .foregroundStyle(secondaryTextColor)
                    Text(resetsAt, style: .relative)
                    Spacer()
                    Text(resetsAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(secondaryTextColor)
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            usageWindowAccessibilityLabel(provider: provider, window: window, display: display)
        )
    }

    private func usageWindowAccessibilityLabel(
        provider: SubscriptionProvider,
        window: SubscriptionUsageWindow,
        display: UsagePercentageDisplay
    ) -> String {
        let percentText = display.accessibilityText(usedPercent: window.usedPercent)
        guard let resetsAt = window.resetsAt else {
            return "\(provider.displayName) \(window.name) \(percentText)"
        }
        return "\(provider.displayName) \(window.name) \(percentText), reset \(resetsAt.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder
    private func stateBadge(_ state: SubscriptionProviderState) -> some View {
        switch state {
        case .disabled:
            Text("Off")
                .foregroundStyle(secondaryTextColor)
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(successColor)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(warningColor)
        }
    }

    private var appColors: TerminalAppColors? {
        terminalAppTheme?.colors(for: colorScheme)
    }

    private var secondaryTextColor: Color {
        appColors?.foreground ?? Color.primary
    }

    private var successColor: Color {
        appColors.map { Color(nsColor: $0.syntaxGreen) } ?? Color.green
    }

    private var warningColor: Color {
        appColors.map { Color(nsColor: $0.syntaxYellow) } ?? Color.orange
    }
}

/// 사용량 퍼센트를 화면에 옮길 때 쓰는 표시용 문자열 모음. 변환 규칙은 모델의 `percent(usedPercent:)`가 맡는다.
extension UsagePercentageDisplay {
    var settingsTitle: String {
        switch self {
        case .used:
            return String(localized: "Used")
        case .remaining:
            return String(localized: "Remaining")
        }
    }

    var qualifier: String {
        switch self {
        case .used:
            return String(localized: "사용")
        case .remaining:
            return String(localized: "남음")
        }
    }

    func percentText(usedPercent: Double) -> String {
        String(format: "%.0f%%", percent(usedPercent: usedPercent))
    }

    func qualifiedPercentText(usedPercent: Double) -> String {
        "\(percentText(usedPercent: usedPercent)) \(qualifier)"
    }

    func accessibilityText(usedPercent: Double) -> String {
        String(
            format: String(localized: "%.0f 퍼센트 %@"),
            percent(usedPercent: usedPercent),
            qualifier
        )
    }
}

private struct UsageProgressBar: View {
    let usedPercent: Double
    let display: UsagePercentageDisplay
    var width: CGFloat?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalAppTheme) private var terminalAppTheme

    private var displayedPercent: Double {
        display.percent(usedPercent: usedPercent)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill((appColors?.foreground ?? Color.primary).opacity(0.14))
                Capsule()
                    .fill(appColors?.foreground ?? Color.primary)
                    .frame(
                        width: geometry.size.width * min(100, max(0, displayedPercent)) / 100
                    )
            }
        }
        .frame(width: width, height: 6)
        .accessibilityValue(display.accessibilityText(usedPercent: usedPercent))
    }

    private var appColors: TerminalAppColors? {
        terminalAppTheme?.colors(for: colorScheme)
    }
}
