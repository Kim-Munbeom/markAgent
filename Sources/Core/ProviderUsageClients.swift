import CryptoKit
import Foundation

enum ProviderUsageClientError: Error, Equatable, Sendable {
    case executableMissing
    case httpStatus(Int)
    case malformedResponse
    case unsupportedResponse
    /// Claude Code 로그인 자격 증명을 키체인/파일에서 찾지 못했다.
    case missingCredentials
    /// 401/403 응답. 토큰이 만료되었거나 거절된 경우다.
    case unauthorized(Int)
    /// 네트워크 계층 실패(연결 불가, 타임아웃 등).
    case requestFailed
    /// HTTP 429 응답. Retry-After를 해석한 상대 대기 시간(초, 최대 24시간)이며 없거나 잘못되면 nil이다.
    case rateLimited(retryAfter: TimeInterval?)
}

extension ProviderUsageClientError: LocalizedError {
    /// 토큰 등 비밀 값은 절대 포함하지 않는 사용자 안내 문구.
    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "실행 파일을 찾을 수 없습니다."
        case .httpStatus(let status):
            return "Claude 사용량 서버가 오류(HTTP \(status))를 반환했습니다. 잠시 후 다시 시도하세요."
        case .malformedResponse:
            return "사용량 응답을 해석할 수 없습니다."
        case .unsupportedResponse:
            return "구독 사용량을 제공하지 않습니다."
        case .missingCredentials:
            return "Claude Code 로그인 정보를 찾을 수 없습니다. Claude Code에 로그인한 뒤 다시 시도하세요."
        case .unauthorized(let status):
            return "Claude 인증이 거절되었습니다(HTTP \(status)). Claude Code에서 다시 로그인한 뒤 새로고침하세요."
        case .requestFailed:
            return "Claude 사용량 서버에 연결하지 못했습니다. 네트워크를 확인하세요."
        case .rateLimited(let retryAfter):
            guard let retryAfter else {
                return "Claude 사용량 요청이 제한되었습니다(HTTP 429). 잠시 후 자동으로 다시 시도합니다."
            }
            let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
            return "Claude 사용량 요청이 제한되었습니다(HTTP 429). 약 \(minutes)분 후 자동으로 다시 시도합니다."
        }
    }
}

enum ProviderUsageClients {
    static func liveLoaders(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        runner: @escaping GitHistoryCommandRunner = GitHistoryProcessRunner.run,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: @escaping ClaudeUsageTransport = ClaudeOAuthUsageClient.liveTransport,
        readFile: @escaping ClaudeCredentialFileReader = { try? Data(contentsOf: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) -> [SubscriptionProvider: SubscriptionStatusModel.Loader] {
        let credentials = ClaudeOAuthCredentialLookup(
            homeDirectory: homeDirectory,
            environment: environment,
            runner: runner,
            readFile: readFile
        )
        var loaders: [SubscriptionProvider: SubscriptionStatusModel.Loader] = [
            .claude: {
                try await ClaudeOAuthUsageClient.fetch(
                    credentials: credentials,
                    transport: transport,
                    now: now
                )
            },
        ]

        if let codexURL = ProviderExecutableLocator.executableURL(
            for: .codex,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            loaders[.codex] = {
                let request = CodexUsageClient.request(
                    executableURL: codexURL,
                    homeDirectory: homeDirectory
                )
                let output = try await runner(request)
                return try CodexUsageClient.parse(output.stdout)
            }
        }

        return loaders
    }
}

enum ProviderExecutableLocator {
    static func executableURL(
        for provider: SubscriptionProvider,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let executableName = provider.rawValue
        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/\(executableName)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(executableName)"),
            URL(fileURLWithPath: "/usr/local/bin/\(executableName)"),
            URL(fileURLWithPath: "/usr/bin/\(executableName)"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func version(
        executableURL: URL,
        runner: @escaping GitHistoryCommandRunner = GitHistoryProcessRunner.run
    ) async -> String? {
        let request = GitHistoryProcessRequest(
            executableURL: executableURL,
            arguments: ["--version"],
            timeoutSeconds: 3,
            outputByteLimit: 16_384
        )
        guard let output = try? await runner(request),
              let text = String(data: output.stdout, encoding: .utf8) else {
            return nil
        }
        return text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

enum CodexUsageClient {
    static func request(executableURL: URL, homeDirectory: URL) -> GitHistoryProcessRequest {
        let initialize = #"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"mark-agent","title":"MarkAgent","version":"1.0.0"}}}"#
        let initialized = #"{"method":"initialized","params":{}}"#
        let readRateLimits = #"{"method":"account/rateLimits/read","id":2,"params":{}}"#
        let script = """
        set timeout 10
        log_user 0
        spawn -noecho $env(MARKAGENT_CODEX_EXECUTABLE) app-server --stdio
        send -- {\(initialize)\r}
        expect {
            -re {"id":1,"result"} {}
            timeout { exit 124 }
            eof { exit 125 }
        }
        send -- {\(initialized)\r}
        send -- {\(readRateLimits)\r}
        expect {
            -re {"id":2,"result":[^\r\n]*\\}\r?\n} {
                puts $expect_out(buffer)
            }
            timeout { exit 124 }
            eof { exit 125 }
        }
        close
        wait
        exit 0
        """

        return GitHistoryProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/expect"),
            arguments: ["-c", script],
            timeoutSeconds: 15,
            outputByteLimit: 1_048_576,
            environment: providerEnvironment(homeDirectory: homeDirectory) + [
                "MARKAGENT_CODEX_EXECUTABLE=\(executableURL.path)",
            ]
        )
    }

    static func parse(_ data: Data) throws -> SubscriptionUsage {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderUsageClientError.malformedResponse
        }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let message = value as? [String: Any],
                  (message["id"] as? NSNumber)?.intValue == 2,
                  let result = message["result"] as? [String: Any],
                  let snapshot = preferredSnapshot(from: result) else {
                continue
            }
            return try usage(from: snapshot)
        }

        throw ProviderUsageClientError.malformedResponse
    }

    private static func preferredSnapshot(from result: [String: Any]) -> [String: Any]? {
        if let snapshot = result["rateLimits"] as? [String: Any] {
            return snapshot
        }
        if let snapshots = result["rateLimitsByLimitId"] as? [String: Any] {
            for key in snapshots.keys.sorted() {
                if let snapshot = snapshots[key] as? [String: Any],
                   snapshot["primary"] != nil || snapshot["secondary"] != nil {
                    return snapshot
                }
            }
        }
        return nil
    }

    private static func usage(from snapshot: [String: Any]) throws -> SubscriptionUsage {
        let windows = ["primary", "secondary"].compactMap { key -> SubscriptionUsageWindow? in
            guard let value = snapshot[key] as? [String: Any],
                  let percent = (value["usedPercent"] as? NSNumber)?.doubleValue,
                  (0...100).contains(percent),
                  let duration = (value["windowDurationMins"] as? NSNumber)?.intValue,
                  duration > 0,
                  let reset = (value["resetsAt"] as? NSNumber)?.doubleValue,
                  reset > 0 else {
                return nil
            }
            return SubscriptionUsageWindow(
                name: windowName(durationMinutes: duration),
                usedPercent: percent,
                resetsAt: Date(timeIntervalSince1970: reset)
            )
        }

        guard let primary = windows.first else {
            throw ProviderUsageClientError.malformedResponse
        }
        return SubscriptionUsage(primary: primary, secondary: windows.dropFirst().first)
    }

    private static func windowName(durationMinutes: Int) -> String {
        switch durationMinutes {
        case 300:
            return "5 hours"
        case 10_080:
            return "7 days"
        default:
            return "\(durationMinutes) minutes"
        }
    }
}

typealias ClaudeUsageTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
typealias ClaudeCredentialFileReader = @Sendable (URL) -> Data?

/// 기존 Claude Code 자격 증명을 읽기 전용으로 조회한다(Orca 키체인 조회 순서와 동일).
/// 토큰 갱신, 키체인 변경, 로그 출력은 하지 않는다.
struct ClaudeOAuthCredentialLookup: Sendable {
    static let legacyService = "Claude Code-credentials"
    static let fallbackAccount = "claude-code-user"

    let homeDirectory: URL
    let environment: [String: String]
    let runner: GitHistoryCommandRunner
    let readFile: ClaudeCredentialFileReader

    /// 우선순위: (CLAUDE_CONFIG_DIR 지정 시) 범위 키체인 → 레거시 키체인 → .credentials.json.
    /// 취소는 삼키지 않고 전파한다. 다음 키체인/파일로 넘어가거나 HTTP 요청으로 이어지면 안 된다.
    func accessToken() async throws -> String? {
        try Task.checkCancellation()
        let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }

        var services: [String] = []
        if let configDirectory {
            services += Self.configDirectoryCandidates(configDirectory).map(Self.scopedService)
        }
        services.append(Self.legacyService)

        let account = Self.account(environment: environment)
        for service in services {
            if let token = try await keychainToken(service: service, account: account) {
                return token
            }
            try Task.checkCancellation()
        }

        let credentialsFile = (configDirectory.map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true))
            .appendingPathComponent(".credentials.json")
        return readFile(credentialsFile).flatMap(Self.accessToken(fromJSON:))
    }

    static func scopedService(configDirectory: String) -> String {
        let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
        let prefix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(legacyService)-\(prefix)"
    }

    static func account(environment: [String: String]) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["USERNAME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSUserName()
        let isSafe = !name.isEmpty && name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
        }
        return isSafe ? name : fallbackAccount
    }

    /// 지정된 경로와, 심볼릭 링크를 해석한 경로가 다르면 그 경로도 후보로 쓴다.
    private static func configDirectoryCandidates(_ directory: String) -> [String] {
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        return resolved == directory ? [directory] : [directory, resolved]
    }

    private static func accessToken(fromJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    /// 키체인 항목이 없거나 조회가 실패하면 nil을 반환해 다음 소스로 넘어간다.
    private func keychainToken(service: String, account: String) async throws -> String? {
        let request = GitHistoryProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"],
            timeoutSeconds: 3,
            outputByteLimit: 65_536
        )
        let output: GitHistoryRawOutput
        do {
            output = try await runner(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch GitHistoryRunnerFailure.cancelled {
            throw CancellationError()
        } catch {
            return nil
        }
        try Task.checkCancellation()
        guard let text = String(data: output.stdout, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Self.accessToken(fromJSON: Data(trimmed.utf8))
    }
}

enum ClaudeOAuthUsageClient {
    static let endpointString = "https://api.anthropic.com/api/oauth/usage"
    static let timeoutSeconds: TimeInterval = 10

    static let liveTransport: ClaudeUsageTransport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    static func request(accessToken: String) throws -> URLRequest {
        guard let endpoint = URL(string: endpointString) else {
            throw ProviderUsageClientError.requestFailed
        }
        var request = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func fetch(
        credentials: ClaudeOAuthCredentialLookup,
        transport: ClaudeUsageTransport,
        now: @Sendable () -> Date
    ) async throws -> SubscriptionUsage {
        guard let token = try await credentials.accessToken() else {
            throw ProviderUsageClientError.missingCredentials
        }
        let urlRequest = try request(accessToken: token)
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw ProviderUsageClientError.requestFailed
        }

        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw ProviderUsageClientError.malformedResponse
        }
        switch http.statusCode {
        case 200..<300:
            return try parse(data, observedAt: now())
        case 401, 403:
            throw ProviderUsageClientError.unauthorized(http.statusCode)
        case 429:
            throw ProviderUsageClientError.rateLimited(
                retryAfter: retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now())
            )
        default:
            throw ProviderUsageClientError.httpStatus(http.statusCode)
        }
    }

    static let maximumRetryAfter: TimeInterval = 24 * 60 * 60

    /// Retry-After를 양수 초 또는 HTTP-date로 해석해 now 기준 상대 초로 바꾸고 24시간으로 제한한다.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let interval: TimeInterval
        if let seconds = Double(text) {
            interval = seconds
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: text) else { return nil }
            interval = date.timeIntervalSince(now)
        }
        guard interval.isFinite, interval > 0 else { return nil }
        return min(interval, maximumRetryAfter)
    }

    static func parse(_ data: Data, observedAt: Date) throws -> SubscriptionUsage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let primary = window(root["five_hour"], name: "5 hours") else {
            throw ProviderUsageClientError.malformedResponse
        }
        return SubscriptionUsage(
            primary: primary,
            secondary: window(root["seven_day"], name: "7 days"),
            fableWeekly: fableWindow(root),
            observedAt: observedAt
        )
    }

    /// 범위 지정 limits 항목을 우선하고, 없으면 별칭 키를 순서대로 확인한다.
    private static func fableWindow(_ root: [String: Any]) -> SubscriptionUsageWindow? {
        if let limits = root["limits"] as? [Any] {
            for case let entry as [String: Any] in limits {
                guard entry["kind"] as? String == "weekly_scoped",
                      let percent = number(entry["percent"]),
                      let scope = entry["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let displayName = model["display_name"] as? String,
                      displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "fable" else {
                    continue
                }
                return SubscriptionUsageWindow(
                    name: "Fable",
                    usedPercent: min(max(percent, 0), 100),
                    resetsAt: resetDate(entry["resets_at"])
                )
            }
        }
        for key in ["fable_weekly", "fable_seven_day", "seven_day_fable"] {
            if let value = window(root[key], name: "Fable") {
                return value
            }
        }
        return nil
    }

    private static func window(_ value: Any?, name: String) -> SubscriptionUsageWindow? {
        guard let object = value as? [String: Any],
              let percent = number(object["utilization"]) ?? number(object["used_percentage"]) else {
            return nil
        }
        return SubscriptionUsageWindow(
            name: name,
            usedPercent: min(max(percent, 0), 100),
            resetsAt: resetDate(object["resets_at"])
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return nil
        }
        return number.doubleValue
    }

    /// 숫자(초/밀리초)·숫자 문자열·ISO8601 문자열을 지원한다. 1e10 초과는 밀리초로 본다.
    private static func resetDate(_ value: Any?) -> Date? {
        if let raw = number(value) {
            return epochDate(raw)
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        if let raw = Double(text), raw.isFinite {
            return epochDate(raw)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func epochDate(_ raw: Double) -> Date {
        Date(timeIntervalSince1970: raw > 1e10 ? raw / 1000 : raw)
    }
}

private func providerEnvironment(homeDirectory: URL) -> [String] {
    [
        "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL=en_US.UTF-8",
        "HOME=\(homeDirectory.path)",
    ]
}
