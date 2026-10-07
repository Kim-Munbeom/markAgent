import CryptoKit
import Foundation
import XCTest
@testable import ma

@MainActor
final class ProviderUsageClientTests: XCTestCase {
    // MARK: - Claude OAuth 사용량

    private let token = "sk-ant-oat-TEST-SECRET"
    private let observedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func credentialJSON(_ accessToken: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"refresh-secret"}}"#
    }

    private nonisolated static func response(
        status: Int = 200,
        headers: [String: String]? = nil,
        body: String
    ) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(URL(string: ClaudeOAuthUsageClient.endpointString))
        let http = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ))
        return (Data(body.utf8), http)
    }

    private func makeLoader(
        recorder: CallRecorder = CallRecorder(),
        environment: [String: String] = ["USER": "tester"],
        keychain: [String: String] = [:],
        files: [String: String] = [:],
        keychainHook: @escaping @Sendable (Int) async throws -> Void = { _ in },
        transport: @escaping ClaudeUsageTransport
    ) throws -> SubscriptionStatusModel.Loader {
        let observed = observedAt
        let loaders = ProviderUsageClients.liveLoaders(
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            runner: { request in
                XCTAssertEqual(request.executableURL.path, "/usr/bin/security")
                XCTAssertEqual(request.timeoutSeconds, 3)
                recorder.recordSecurity(request.arguments)
                try await keychainHook(recorder.securityCalls.count)
                guard let output = keychain[request.arguments[2]] else {
                    throw GitHistoryRunnerFailure.nonZeroExit(exitCode: 44, stderr: Data())
                }
                return GitHistoryRawOutput(stdout: Data((output + "\n").utf8), stderr: Data())
            },
            environment: environment,
            transport: { request in
                recorder.recordRequest(request)
                return try await transport(request)
            },
            readFile: { url in
                recorder.recordFileRead(url.path)
                return files[url.path].map { Data($0.utf8) }
            },
            now: { observed }
        )
        return try XCTUnwrap(loaders[.claude])
    }

    private func sha8(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    func testClaudeOAuthRequestUsesExpectedURLHeadersAndTimeout() async throws {
        let recorder = CallRecorder()
        let loader = try makeLoader(
            recorder: recorder,
            keychain: ["Claude Code-credentials": credentialJSON(token)],
            transport: { _ in try Self.response(body: #"{"five_hour":{"utilization":10}}"#) }
        )

        _ = try await loader()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.0")
        XCTAssertEqual(
            recorder.securityCalls,
            [["find-generic-password", "-s", "Claude Code-credentials", "-a", "tester", "-w"]]
        )
    }

    func testClaudeOAuthLoaderParsesFiveHourSevenDayAndFable() async throws {
        let body = #"{"five_hour":{"utilization":12.5,"resets_at":1790003600},"seven_day":{"used_percentage":40,"resets_at":1790600000},"fable_weekly":{"utilization":7,"resets_at":1790700000}}"#
        let loader = try makeLoader(
            keychain: ["Claude Code-credentials": credentialJSON(token)],
            transport: { _ in try Self.response(body: body) }
        )

        let usage = try await loader()

        XCTAssertEqual(usage.primary.name, "5 hours")
        XCTAssertEqual(usage.primary.usedPercent, 12.5)
        XCTAssertEqual(usage.primary.resetsAt, Date(timeIntervalSince1970: 1_790_003_600))
        XCTAssertEqual(usage.secondary?.name, "7 days")
        XCTAssertEqual(usage.secondary?.usedPercent, 40)
        XCTAssertEqual(usage.fableWeekly?.name, "Fable")
        XCTAssertEqual(usage.fableWeekly?.usedPercent, 7)
        XCTAssertEqual(usage.observedAt, observedAt)
    }

    func testClaudeOAuthScopedKeychainWinsOverLegacyAndFile() async throws {
        let configDirectory = "/custom/claude-config-test"
        let scoped = "Claude Code-credentials-\(sha8(configDirectory))"
        let recorder = CallRecorder()
        let loader = try makeLoader(
            recorder: recorder,
            environment: ["USER": "tester", "CLAUDE_CONFIG_DIR": configDirectory],
            keychain: [
                scoped: credentialJSON("scoped-token"),
                "Claude Code-credentials": credentialJSON("legacy-token"),
            ],
            files: ["\(configDirectory)/.credentials.json": credentialJSON("file-token")],
            transport: { _ in try Self.response(body: #"{"five_hour":{"utilization":1}}"#) }
        )

        _ = try await loader()

        XCTAssertEqual(
            recorder.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer scoped-token"
        )
        XCTAssertEqual(recorder.securityCalls.map { $0[2] }, [scoped])
        XCTAssertTrue(recorder.fileReads.isEmpty)
    }

    func testClaudeOAuthFallsBackFromScopedToLegacyThenConfigFile() async throws {
        let configDirectory = "/custom/claude-config-test"
        let scoped = "Claude Code-credentials-\(sha8(configDirectory))"

        let legacyRecorder = CallRecorder()
        let legacyLoader = try makeLoader(
            recorder: legacyRecorder,
            environment: ["USER": "tester", "CLAUDE_CONFIG_DIR": configDirectory],
            keychain: ["Claude Code-credentials": credentialJSON("legacy-token")],
            files: ["\(configDirectory)/.credentials.json": credentialJSON("file-token")],
            transport: { _ in try Self.response(body: #"{"five_hour":{"utilization":1}}"#) }
        )
        _ = try await legacyLoader()
        XCTAssertEqual(
            legacyRecorder.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer legacy-token"
        )
        XCTAssertEqual(legacyRecorder.securityCalls.map { $0[2] }, [scoped, "Claude Code-credentials"])

        let fileRecorder = CallRecorder()
        let fileLoader = try makeLoader(
            recorder: fileRecorder,
            environment: ["USER": "tester", "CLAUDE_CONFIG_DIR": configDirectory],
            files: ["\(configDirectory)/.credentials.json": credentialJSON("file-token")],
            transport: { _ in try Self.response(body: #"{"five_hour":{"utilization":1}}"#) }
        )
        _ = try await fileLoader()
        XCTAssertEqual(
            fileRecorder.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer file-token"
        )
        XCTAssertEqual(fileRecorder.fileReads, ["\(configDirectory)/.credentials.json"])
    }

    func testClaudeOAuthWithoutConfigDirectoryUsesLegacyThenHomeCredentialsFile() async throws {
        let recorder = CallRecorder()
        let loader = try makeLoader(
            recorder: recorder,
            files: ["/Users/tester/.claude/.credentials.json": credentialJSON("home-file-token")],
            transport: { _ in try Self.response(body: #"{"five_hour":{"utilization":1}}"#) }
        )

        _ = try await loader()

        XCTAssertEqual(recorder.securityCalls.map { $0[2] }, ["Claude Code-credentials"])
        XCTAssertEqual(
            recorder.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer home-file-token"
        )
    }

    func testClaudeOAuthUnsafeUsernameUsesFallbackAccount() async throws {
        let recorder = CallRecorder()
        let loader = try makeLoader(
            recorder: recorder,
            environment: ["USER": "bad user!"],
            keychain: ["Claude Code-credentials": credentialJSON(token)],
            transport: { _ in try Self.response(body: #"{"five_hour":{"utilization":1}}"#) }
        )

        _ = try await loader()

        XCTAssertEqual(recorder.securityCalls.first?[4], "claude-code-user")
    }

    func testClaudeOAuthMissingCredentialsDoesNotCallTransport() async throws {
        let recorder = CallRecorder()
        let loader = try makeLoader(
            recorder: recorder,
            transport: { _ in
                XCTFail("자격 증명이 없으면 요청을 보내면 안 됩니다.")
                throw ProviderUsageClientError.unsupportedResponse
            }
        )

        do {
            _ = try await loader()
            XCTFail("자격 증명이 없으면 실패해야 합니다.")
        } catch {
            XCTAssertEqual(error as? ProviderUsageClientError, .missingCredentials)
            let message = try XCTUnwrap((error as? LocalizedError)?.errorDescription)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("statusline"))
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testClaudeOAuthHTTPFailuresAreActionableAndDoNotExposeToken() async throws {
        for (status, expected) in [
            (401, ProviderUsageClientError.unauthorized(401)),
            (403, .unauthorized(403)),
            (500, .httpStatus(500)),
            (404, .httpStatus(404)),
        ] {
            let loader = try makeLoader(
                keychain: ["Claude Code-credentials": credentialJSON(token)],
                transport: { _ in try Self.response(status: status, body: #"{"error":"x"}"#) }
            )
            do {
                _ = try await loader()
                XCTFail("HTTP \(status)는 실패해야 합니다.")
            } catch {
                XCTAssertEqual(error as? ProviderUsageClientError, expected)
                let message = try XCTUnwrap((error as? LocalizedError)?.errorDescription)
                XCTAssertTrue(message.contains("\(status)"))
                XCTAssertFalse(message.contains(token))
                XCTAssertFalse(message.localizedCaseInsensitiveContains("statusline"))
            }
        }
    }

    func testClaudeOAuth429ParsesRetryAfterRelativeToInjectedNow() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let cases: [(String?, TimeInterval?)] = [
            ("120", 120),
            (" 45 ", 45),
            (formatter.string(from: observedAt.addingTimeInterval(300)), 300),
            ("999999", 86_400),
            (formatter.string(from: observedAt.addingTimeInterval(10 * 86_400)), 86_400),
            ("0", nil),
            ("-5", nil),
            (formatter.string(from: observedAt.addingTimeInterval(-60)), nil),
            ("soon", nil),
            ("", nil),
            (nil, nil),
        ]
        for (header, expected) in cases {
            let headers = header.map { ["Retry-After": $0] }
            let loader = try makeLoader(
                keychain: ["Claude Code-credentials": credentialJSON(token)],
                transport: { _ in try Self.response(status: 429, headers: headers, body: "{}") }
            )
            do {
                _ = try await loader()
                XCTFail("429는 실패해야 합니다.")
            } catch {
                XCTAssertEqual(
                    error as? ProviderUsageClientError,
                    .rateLimited(retryAfter: expected),
                    header ?? "nil"
                )
                let message = try XCTUnwrap((error as? LocalizedError)?.errorDescription)
                XCTAssertTrue(message.contains("429"))
                XCTAssertFalse(message.contains(token))
                XCTAssertFalse(message.localizedCaseInsensitiveContains("statusline"))
            }
        }
    }

    func testClaudeOAuthTransportFailureMapsToRequestFailed() async throws {
        let loader = try makeLoader(
            keychain: ["Claude Code-credentials": credentialJSON(token)],
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )

        do {
            _ = try await loader()
            XCTFail("네트워크 실패는 오류여야 합니다.")
        } catch {
            XCTAssertEqual(error as? ProviderUsageClientError, .requestFailed)
        }
    }

    func testClaudeOAuthParsesUtilizationAliasClampsAndPrefersUtilization() throws {
        let body = #"{"five_hour":{"utilization":150,"used_percentage":5},"seven_day":{"used_percentage":-20}}"#

        let usage = try ClaudeOAuthUsageClient.parse(Data(body.utf8), observedAt: observedAt)

        XCTAssertEqual(usage.primary.usedPercent, 100)
        XCTAssertEqual(usage.secondary?.usedPercent, 0)
        XCTAssertNil(usage.primary.resetsAt)
        XCTAssertNil(usage.fableWeekly)
    }

    func testClaudeOAuthFableScopedLimitHasPriorityOverAliases() throws {
        let body = #"{"five_hour":{"utilization":1},"limits":[{"kind":"weekly_scoped","percent":"90","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":33,"scope":{"model":{"display_name":"Other"}}},{"kind":"weekly_scoped","percent":55,"resets_at":1790600000,"scope":{"model":{"display_name":"  FABLE "}}},{"kind":"weekly_scoped","percent":66,"scope":{"model":{"display_name":"fable"}}}],"fable_weekly":{"utilization":1},"fable_seven_day":{"utilization":2},"seven_day_fable":{"utilization":3}}"#

        let usage = try ClaudeOAuthUsageClient.parse(Data(body.utf8), observedAt: observedAt)

        XCTAssertEqual(usage.fableWeekly?.name, "Fable")
        XCTAssertEqual(usage.fableWeekly?.usedPercent, 55)
        XCTAssertEqual(usage.fableWeekly?.resetsAt, Date(timeIntervalSince1970: 1_790_600_000))
    }

    func testClaudeOAuthFableAliasOrder() throws {
        let all = #"{"five_hour":{"utilization":1},"limits":[],"fable_weekly":{"utilization":10},"fable_seven_day":{"utilization":20},"seven_day_fable":{"utilization":30}}"#
        let withoutFirst = #"{"five_hour":{"utilization":1},"fable_seven_day":{"utilization":20},"seven_day_fable":{"utilization":30}}"#
        let onlyLast = #"{"five_hour":{"utilization":1},"seven_day_fable":{"used_percentage":30}}"#

        XCTAssertEqual(try ClaudeOAuthUsageClient.parse(Data(all.utf8), observedAt: observedAt).fableWeekly?.usedPercent, 10)
        XCTAssertEqual(try ClaudeOAuthUsageClient.parse(Data(withoutFirst.utf8), observedAt: observedAt).fableWeekly?.usedPercent, 20)
        XCTAssertEqual(try ClaudeOAuthUsageClient.parse(Data(onlyLast.utf8), observedAt: observedAt).fableWeekly?.usedPercent, 30)
    }

    func testClaudeOAuthResetTimeFormats() throws {
        let expected = Date(timeIntervalSince1970: 1791374400)
        let bodies = [
            #"{"five_hour":{"utilization":1,"resets_at":"2026-10-07T12:00:00Z"}}"#,
            #"{"five_hour":{"utilization":1,"resets_at":"2026-10-07T12:00:00.000Z"}}"#,
            #"{"five_hour":{"utilization":1,"resets_at":1791374400}}"#,
            #"{"five_hour":{"utilization":1,"resets_at":1791374400000}}"#,
            #"{"five_hour":{"utilization":1,"resets_at":"1791374400"}}"#,
        ]
        for body in bodies {
            let usage = try ClaudeOAuthUsageClient.parse(Data(body.utf8), observedAt: observedAt)
            XCTAssertEqual(usage.primary.resetsAt, expected, body)
        }

        let invalid = #"{"five_hour":{"utilization":1,"resets_at":"not a date"}}"#
        XCTAssertNil(try ClaudeOAuthUsageClient.parse(Data(invalid.utf8), observedAt: observedAt).primary.resetsAt)
    }

    func testClaudeOAuthKeepsValidWindowsWithoutResetTime() throws {
        let scoped = #"{"five_hour":{"utilization":2},"seven_day":{"utilization":3},"limits":[{"kind":"weekly_scoped","percent":0,"scope":{"model":{"display_name":"Fable"}}}]}"#
        let alias = #"{"five_hour":{"utilization":2},"seven_day_fable":{"used_percentage":4}}"#

        let scopedUsage = try ClaudeOAuthUsageClient.parse(Data(scoped.utf8), observedAt: observedAt)
        XCTAssertNil(scopedUsage.primary.resetsAt)
        XCTAssertNil(scopedUsage.secondary?.resetsAt)
        XCTAssertEqual(scopedUsage.secondary?.usedPercent, 3)
        XCTAssertEqual(scopedUsage.fableWeekly?.usedPercent, 0)
        XCTAssertNil(scopedUsage.fableWeekly?.resetsAt)

        let aliasUsage = try ClaudeOAuthUsageClient.parse(Data(alias.utf8), observedAt: observedAt)
        XCTAssertEqual(aliasUsage.fableWeekly?.usedPercent, 4)
        XCTAssertNil(aliasUsage.fableWeekly?.resetsAt)
    }

    func testClaudeOAuthRunnerCancellationStopsLookupAndRequest() async throws {
        let configDirectory = "/custom/claude-config-test"
        let failures: [Error] = [CancellationError(), GitHistoryRunnerFailure.cancelled]
        for failure in failures {
            let recorder = CallRecorder()
            let loader = try makeLoader(
                recorder: recorder,
                environment: ["USER": "tester", "CLAUDE_CONFIG_DIR": configDirectory],
                keychain: ["Claude Code-credentials": credentialJSON("legacy-token")],
                files: ["\(configDirectory)/.credentials.json": credentialJSON("file-token")],
                keychainHook: { _ in throw failure },
                transport: { _ in
                    XCTFail("취소된 뒤에는 요청을 보내면 안 됩니다.")
                    throw ProviderUsageClientError.unsupportedResponse
                }
            )

            do {
                _ = try await loader()
                XCTFail("러너 취소는 조회 취소로 전파되어야 합니다.")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }

            XCTAssertEqual(recorder.securityCalls.count, 1)
            XCTAssertTrue(recorder.fileReads.isEmpty)
            XCTAssertTrue(recorder.requests.isEmpty)
        }
    }

    func testClaudeOAuthTaskCancelledDuringCredentialLookupSkipsRequest() async throws {
        let entered = expectation(description: "자격 증명 조회 시작")
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let recorder = CallRecorder()
        let loader = try makeLoader(
            recorder: recorder,
            keychain: ["Claude Code-credentials": credentialJSON(token)],
            keychainHook: { _ in
                entered.fulfill()
                for await _ in release { break }
            },
            transport: { _ in
                XCTFail("자격 증명 조회 중 취소되면 요청을 보내면 안 됩니다.")
                throw ProviderUsageClientError.unsupportedResponse
            }
        )

        let task = Task { try await loader() }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        releaseSignal.finish()

        do {
            _ = try await task.value
            XCTFail("취소된 조회는 결과를 반환하면 안 됩니다.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testClaudeOAuthTaskCancelledDuringTransportDiscardsResponse() async throws {
        let entered = expectation(description: "사용량 요청 시작")
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let recorder = CallRecorder()
        let loader = try makeLoader(
            recorder: recorder,
            keychain: ["Claude Code-credentials": credentialJSON(token)],
            transport: { _ in
                entered.fulfill()
                for await _ in release { break }
                return try Self.response(body: #"{"five_hour":{"utilization":1}}"#)
            }
        )

        let task = Task { try await loader() }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        releaseSignal.finish()

        do {
            _ = try await task.value
            XCTFail("전송 중 취소되면 응답을 사용하면 안 됩니다.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testClaudeOAuthRejectsMalformedPayloads() {
        let payloads = [
            "not json",
            "[]",
            "{}",
            #"{"seven_day":{"utilization":5}}"#,
            #"{"five_hour":{}}"#,
            #"{"five_hour":{"utilization":"12"}}"#,
            #"{"five_hour":{"utilization":true}}"#,
        ]
        for payload in payloads {
            XCTAssertThrowsError(
                try ClaudeOAuthUsageClient.parse(Data(payload.utf8), observedAt: observedAt),
                payload
            ) { error in
                XCTAssertEqual(error as? ProviderUsageClientError, .malformedResponse)
            }
        }
    }

    func testCodexParsesPrimaryAndSecondaryRateLimitWindows() throws {
        let response = """
        {"id":1,"result":{"userAgent":"codex_cli_rs/0.149.0"}}
        {"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":null}}}
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1787886000},"secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1788480114}},"rateLimitsByLimitId":{}}}
        """

        let usage = try CodexUsageClient.parse(Data(response.utf8))

        XCTAssertEqual(usage.primary.name, "5 hours")
        XCTAssertEqual(usage.primary.usedPercent, 12)
        XCTAssertEqual(usage.primary.resetsAt, Date(timeIntervalSince1970: 1_787_886_000))
        XCTAssertEqual(usage.secondary?.name, "7 days")
        XCTAssertEqual(usage.secondary?.usedPercent, 3)
    }

    func testCodexPrefersAuthoritativeRateLimitsOverModelSpecificSnapshots() throws {
        let response = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":43,"windowDurationMins":10080,"resetsAt":1789103202},"secondary":null},"rateLimitsByLimitId":{"base_model_inference":{"limitId":"base_model_inference","limitName":"gpt-reserve","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1789367878},"secondary":null},"codex":{"limitId":"codex","primary":{"usedPercent":43,"windowDurationMins":10080,"resetsAt":1789103202},"secondary":null},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1788781012},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1789367812}}}}}
        """

        let usage = try CodexUsageClient.parse(Data(response.utf8))

        XCTAssertEqual(usage.primary.name, "7 days")
        XCTAssertEqual(
            usage.primary.usedPercent,
            43,
            "Codex aggregate usage must not be replaced by the first model-specific snapshot"
        )
        XCTAssertEqual(usage.primary.resetsAt, Date(timeIntervalSince1970: 1_789_103_202))
        XCTAssertNil(usage.secondary)
    }

    func testCodexRejectsMissingMatchingResponseAndInvalidPercent() {
        let missing = Data(#"{"id":1,"result":{}}"#.utf8)
        let invalid = Data(
            #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":-1,"windowDurationMins":300,"resetsAt":1787886000}}}}"#.utf8
        )

        XCTAssertThrowsError(try CodexUsageClient.parse(missing))
        XCTAssertThrowsError(try CodexUsageClient.parse(invalid))
    }

    func testCodexRequestUsesProviderOwnedAuthenticationWithoutSecrets() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        let codex = CodexUsageClient.request(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            homeDirectory: home
        )

        XCTAssertEqual(codex.executableURL.path, "/usr/bin/expect")
        XCTAssertTrue(codex.environment.contains("HOME=/Users/example"))
        let script = try XCTUnwrap(codex.arguments.dropFirst().first)
        XCTAssertTrue(script.contains(#""method":"initialize""#))
        XCTAssertTrue(script.contains(#""method":"initialized""#))
        XCTAssertTrue(script.contains(#""method":"account/rateLimits/read""#))
        XCTAssertFalse(script.contains("/opt/homebrew/bin/codex"))
        XCTAssertTrue(
            codex.environment.contains("MARKAGENT_CODEX_EXECUTABLE=/opt/homebrew/bin/codex")
        )
        XCTAssertFalse(script.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("secret"))

        let hostilePath = "/tmp/codex}; exec /usr/bin/false; {"
        let hostile = CodexUsageClient.request(
            executableURL: URL(fileURLWithPath: hostilePath),
            homeDirectory: home
        )
        let hostileScript = try XCTUnwrap(hostile.arguments.dropFirst().first)
        XCTAssertFalse(hostileScript.contains(hostilePath))
        XCTAssertTrue(
            hostile.environment.contains("MARKAGENT_CODEX_EXECUTABLE=\(hostilePath)")
        )
    }

    func testProviderVersionUsesBoundedReadOnlyCommand() async {
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")

        let version = await ProviderExecutableLocator.version(
            executableURL: executableURL,
            runner: { request in
                XCTAssertEqual(request.executableURL, executableURL)
                XCTAssertEqual(request.arguments, ["--version"])
                XCTAssertEqual(request.timeoutSeconds, 3)
                XCTAssertEqual(request.outputByteLimit, 16_384)
                return GitHistoryRawOutput(
                    stdout: Data("codex-cli 0.149.0\n".utf8),
                    stderr: Data()
                )
            }
        )

        XCTAssertEqual(version, "codex-cli 0.149.0")
    }
}

/// 테스트 더블 호출을 기록한다. 잠금으로 보호하며 시간 대기는 사용하지 않는다.
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var storedSecurityCalls: [[String]] = []
    private var storedFileReads: [String] = []

    var requests: [URLRequest] { lock.withLock { storedRequests } }
    var securityCalls: [[String]] { lock.withLock { storedSecurityCalls } }
    var fileReads: [String] { lock.withLock { storedFileReads } }

    func recordRequest(_ request: URLRequest) { lock.withLock { storedRequests.append(request) } }
    func recordSecurity(_ arguments: [String]) { lock.withLock { storedSecurityCalls.append(arguments) } }
    func recordFileRead(_ path: String) { lock.withLock { storedFileReads.append(path) } }
}
