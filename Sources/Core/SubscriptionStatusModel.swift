import Foundation
import Observation

enum SubscriptionProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case claude
    case codex

    var id: Self { self }

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

}

struct SubscriptionUsageWindow: Equatable, Sendable {
    let name: String
    let usedPercent: Double
    /// OAuth 사용량 구간에는 리셋 시각이 없을 수 있으며, 없으면 nil로 둔다.
    let resetsAt: Date?
}

/// 사용량 퍼센트를 "사용한 양" 또는 "남은 양"으로 표시할지 정하는 표시 전용 선택지.
enum UsagePercentageDisplay: String, CaseIterable, Sendable {
    case used
    case remaining

    /// 사용률을 0...100으로 보정하고 반올림한 뒤 표시 기준에 맞게 변환한다(Orca와 동일).
    /// 비유한 입력은 두 모드 모두 0으로 표시하며, 변환은 표시 시점에만 수행한다.
    func percent(usedPercent: Double) -> Double {
        guard usedPercent.isFinite else { return 0 }
        let roundedUsed = min(max(usedPercent, 0), 100).rounded()
        switch self {
        case .used:
            return roundedUsed
        case .remaining:
            return 100 - roundedUsed
        }
    }
}

struct SubscriptionUsage: Equatable, Sendable {
    let primary: SubscriptionUsageWindow
    let secondary: SubscriptionUsageWindow?
    let fableWeekly: SubscriptionUsageWindow?
    let observedAt: Date?

    init(
        primary: SubscriptionUsageWindow,
        secondary: SubscriptionUsageWindow? = nil,
        fableWeekly: SubscriptionUsageWindow? = nil,
        observedAt: Date? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.fableWeekly = fableWeekly
        self.observedAt = observedAt
    }

    var windows: [SubscriptionUsageWindow] {
        [primary, secondary, fableWeekly].compactMap { $0 }
    }
}

enum SubscriptionProviderState: Equatable, Sendable {
    case disabled
    case loading
    case available(SubscriptionUsage)
    case unavailable(message: String)
}

@MainActor
@Observable
final class SubscriptionStatusModel {
    typealias Loader = @Sendable () async throws -> SubscriptionUsage
    typealias PollWait = @Sendable (TimeInterval) async -> Void
    typealias PollWake = @Sendable () async -> Void

    static let enabledProvidersDefaultsKey = "MarkAgent.subscriptionStatus.registeredProviders"
    static let usagePercentageDisplayDefaultsKey = "MarkAgent.subscriptionStatus.usagePercentageDisplay"
    static let pollInterval: TimeInterval = 15 * 60
    static let startupRefreshDelay: TimeInterval = 1
    static let minimumRefetchInterval: TimeInterval = 5 * 60
    static let initialFailureRetryInterval: TimeInterval = 30
    static let maximumFailureRetryInterval: TimeInterval = 15 * 60

    private(set) var enabledProviders: [SubscriptionProvider]
    /// 사용량 표시 기준. 변경 즉시 UserDefaults에 저장된다.
    var usagePercentageDisplay: UsagePercentageDisplay {
        didSet {
            defaults.set(usagePercentageDisplay.rawValue, forKey: Self.usagePercentageDisplayDefaultsKey)
        }
    }
    private var states: [SubscriptionProvider: SubscriptionProviderState]
    private let defaults: UserDefaults
    private let loaders: [SubscriptionProvider: Loader]
    private let now: @Sendable () -> Date
    private let pollWait: PollWait
    private let pollWake: PollWake
    private var refreshGenerations: [SubscriptionProvider: Int]
    private var lastAttemptDates: [SubscriptionProvider: Date]
    private var failureStreaks: [SubscriptionProvider: Int]
    private var retryDates: [SubscriptionProvider: Date]
    private var refreshTasks: [SubscriptionProvider: Task<SubscriptionUsage, Error>]
    private var pollingTask: Task<Void, Never>?
    /// 앱 시작 후 첫 지연 갱신이 아직 수행되지 않았는지 나타낸다.
    private var isStartupRefreshPending = true

    init(
        defaults: UserDefaults = .standard,
        loaders: [SubscriptionProvider: Loader],
        now: @escaping @Sendable () -> Date = Date.init,
        pollWait: PollWait? = nil,
        pollWake: PollWake? = nil
    ) {
        let wakeSignal = PollingWakeSignal()
        self.defaults = defaults
        self.loaders = loaders
        self.now = now
        self.pollWait = pollWait ?? { interval in
            await wakeSignal.wait(for: interval)
        }
        self.pollWake = pollWake ?? {
            wakeSignal.signal()
        }
        self.refreshGenerations = [:]
        self.lastAttemptDates = [:]
        self.failureStreaks = [:]
        self.retryDates = [:]
        self.refreshTasks = [:]
        self.usagePercentageDisplay = defaults.string(forKey: Self.usagePercentageDisplayDefaultsKey)
            .flatMap(UsagePercentageDisplay.init(rawValue:)) ?? .used

        let initialEnabledProviders: [SubscriptionProvider]
        if let storedProviders = defaults.stringArray(forKey: Self.enabledProvidersDefaultsKey) {
            initialEnabledProviders = SubscriptionProvider.allCases.filter {
                storedProviders.contains($0.rawValue)
            }
        } else {
            initialEnabledProviders = []
            defaults.set([], forKey: Self.enabledProvidersDefaultsKey)
        }
        self.enabledProviders = initialEnabledProviders

        self.states = Dictionary(
            uniqueKeysWithValues: SubscriptionProvider.allCases.map { provider in
                (
                    provider,
                    initialEnabledProviders.contains(provider)
                        ? .unavailable(message: "Not refreshed yet.")
                        : .disabled
                )
            }
        )
    }

    func state(for provider: SubscriptionProvider) -> SubscriptionProviderState {
        states[provider] ?? .disabled
    }

    func setEnabled(_ isEnabled: Bool, for provider: SubscriptionProvider) {
        let isAlreadyEnabled = enabledProviders.contains(provider)
        guard isEnabled != isAlreadyEnabled else { return }

        refreshGenerations[provider, default: 0] += 1
        lastAttemptDates[provider] = nil
        failureStreaks[provider] = nil
        retryDates[provider] = nil

        if isEnabled {
            enabledProviders = SubscriptionProvider.allCases.filter {
                $0 == provider || enabledProviders.contains($0)
            }
            states[provider] = .unavailable(message: "Not refreshed yet.")
        } else {
            refreshTasks.removeValue(forKey: provider)?.cancel()
            enabledProviders.removeAll { $0 == provider }
            states[provider] = .disabled
        }

        defaults.set(enabledProviders.map(\.rawValue), forKey: Self.enabledProvidersDefaultsKey)
    }

    @discardableResult
    func refresh(_ provider: SubscriptionProvider) async -> Bool {
        guard enabledProviders.contains(provider) else {
            states[provider] = .disabled
            return false
        }

        if refreshTasks[provider] != nil {
            return false
        }

        refreshGenerations[provider, default: 0] += 1
        let generation = refreshGenerations[provider, default: 0]
        states[provider] = .loading

        guard let loader = loaders[provider] else {
            guard generation == refreshGenerations[provider] else { return true }
            await recordFailure(for: provider)
            states[provider] = .unavailable(message: "Unable to load \(provider.displayName) usage.")
            return true
        }

        let refreshTask = Task {
            try await loader()
        }
        refreshTasks[provider] = refreshTask
        defer {
            if generation == refreshGenerations[provider] {
                refreshTasks[provider] = nil
            }
        }

        do {
            let usage = try await refreshTask.value
            guard generation == refreshGenerations[provider],
                  enabledProviders.contains(provider) else {
                return true
            }
            lastAttemptDates[provider] = now()
            failureStreaks[provider] = nil
            retryDates[provider] = nil
            states[provider] = .available(usage)
        } catch {
            guard generation == refreshGenerations[provider],
                  enabledProviders.contains(provider) else {
                return true
            }
            let retryAfter: TimeInterval?
            if let clientError = error as? ProviderUsageClientError,
               case .rateLimited(let interval) = clientError {
                retryAfter = interval
            } else {
                retryAfter = nil
            }
            await recordFailure(for: provider, retryAfter: retryAfter)
            let message: String
            if let statuslineError = error as? ClaudeStatuslineUsageError {
                switch statuslineError {
                case .noData:
                    message = String(localized: "Claude 사용량 정보를 아직 받지 못했습니다.")
                case .staleData:
                    message = String(localized: "Claude 사용량 정보가 만료되었습니다. 다음 갱신 때 다시 불러옵니다.")
                case .malformedData:
                    message = String(localized: "Claude 사용량 정보를 읽을 수 없습니다.")
                }
            } else if error as? ProviderUsageClientError == .unsupportedResponse {
                message = "\(provider.displayName) CLI가 구독 사용량을 제공하지 않습니다."
            } else if provider == .claude,
                      let clientError = error as? ProviderUsageClientError,
                      let description = clientError.errorDescription {
                message = description
            } else {
                message = "Unable to load \(provider.displayName) usage."
            }
            states[provider] = .unavailable(message: message)
        }
        return true
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in enabledProviders {
                group.addTask { [weak self] in
                    _ = await self?.refresh(provider)
                }
            }
        }
    }

    func refreshIfNeeded() async {
        let currentDate = now()
        let dueProviders = enabledProviders.filter { provider in
            if let retryDate = retryDates[provider] {
                return currentDate >= retryDate
            }
            guard let lastAttemptDate = lastAttemptDates[provider] else {
                return true
            }
            return currentDate.timeIntervalSince(lastAttemptDate) >= Self.minimumRefetchInterval
        }

        await withTaskGroup(of: Void.self) { group in
            for provider in dueProviders {
                group.addTask { [weak self] in
                    _ = await self?.refresh(provider)
                }
            }
        }
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        let pollWait = self.pollWait
        let startupPending = isStartupRefreshPending
        pollingTask = Task { [weak self] in
            // 시작 직후에는 1초 지연 후 첫 갱신, 재개 시에는 즉시 갱신한다.
            if startupPending {
                await pollWait(Self.startupRefreshDelay)
                guard !Task.isCancelled, self?.completeStartupDelay() == true else { return }
            }
            await self?.refreshIfNeeded()
            while !Task.isCancelled {
                guard let delay = self?.nextPollingDelay() else { return }
                await pollWait(delay)
                guard !Task.isCancelled else { break }
                await self?.refreshIfNeeded()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        for refreshTask in refreshTasks.values {
            refreshTask.cancel()
        }
        refreshTasks.removeAll()
        for provider in enabledProviders {
            refreshGenerations[provider, default: 0] += 1
        }
    }

    private func completeStartupDelay() -> Bool {
        isStartupRefreshPending = false
        return true
    }

    private func nextPollingDelay() -> TimeInterval {
        let currentDate = now()
        let retryDelay = retryDates
            .compactMap { provider, retryDate -> TimeInterval? in
                guard refreshTasks[provider] == nil else { return nil }
                return max(0, retryDate.timeIntervalSince(currentDate))
            }
            .min()
        return min(Self.pollInterval, retryDelay ?? Self.pollInterval)
    }

    private func recordFailure(
        for provider: SubscriptionProvider,
        retryAfter: TimeInterval? = nil
    ) async {
        let currentDate = now()
        let streak = min(failureStreaks[provider, default: 0] + 1, 8)
        let exponentialDelay = Self.initialFailureRetryInterval * pow(2, Double(streak - 1))
        let delay = min(exponentialDelay, Self.maximumFailureRetryInterval)
        lastAttemptDates[provider] = currentDate
        failureStreaks[provider] = streak
        retryDates[provider] = currentDate.addingTimeInterval(max(delay, retryAfter ?? 0))
        if pollingTask != nil {
            await pollWake()
        }
    }
}

final class PollingWakeSignal: @unchecked Sendable {
    typealias DeadlineScheduler = @Sendable (TimeInterval, DispatchWorkItem) -> Void

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
        let deadline: DispatchWorkItem
    }

    private let lock = NSLock()
    private let scheduleDeadline: DeadlineScheduler
    private var pendingSignal = false
    private var waiters: [UUID: Waiter] = [:]

    init(
        scheduleDeadline: @escaping DeadlineScheduler = { interval, deadline in
            DispatchQueue.global().asyncAfter(
                deadline: .now() + interval,
                execute: deadline
            )
        }
    ) {
        self.scheduleDeadline = scheduleDeadline
    }

    func signal() {
        let resumedWaiters: [Waiter] = lock.withLock {
            guard !waiters.isEmpty else {
                pendingSignal = true
                return []
            }
            let resumedWaiters = Array(waiters.values)
            waiters.removeAll()
            return resumedWaiters
        }
        for waiter in resumedWaiters {
            waiter.deadline.cancel()
            waiter.continuation.resume()
        }
    }

    func wait(for interval: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let deadline = DispatchWorkItem { [weak self] in
                    self?.resumeWaiter(id: id)
                }
                let shouldResumeImmediately = lock.withLock {
                    guard !Task.isCancelled, !pendingSignal else {
                        pendingSignal = false
                        return true
                    }
                    waiters[id] = Waiter(
                        id: id,
                        continuation: continuation,
                        deadline: deadline
                    )
                    return false
                }

                if shouldResumeImmediately {
                    continuation.resume()
                } else {
                    scheduleDeadline(interval, deadline)
                }
            }
        } onCancel: { [weak self] in
            self?.resumeWaiter(id: id)
        }
    }

    private func resumeWaiter(id: UUID) {
        let resumedWaiter: Waiter? = lock.withLock {
            waiters.removeValue(forKey: id)
        }
        resumedWaiter?.deadline.cancel()
        resumedWaiter?.continuation.resume()
    }
}
