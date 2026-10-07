import Darwin
import XCTest
@testable import ma

final class HerdrProcessInspectorTests: XCTestCase {
    private let context = HerdrProcessInspector.Context(foregroundGroup: 40, tty: "/dev/ttys004")

    func testNativeProcessGroupLookupIncludesCurrentProcess() throws {
        let members = try XCTUnwrap(HerdrProcessInspector.processGroupMembers(getpgrp()))
        XCTAssertTrue(members.contains(getpid()))
    }

    func testNativeTerminalLookupRejectsUnrelatedIdentity() {
        XCTAssertNil(HerdrProcessInspector.terminalContext(UUID()))
    }

    func testRealPTYRegistrationResolvesOwnedForegroundWithoutGhosttyGetters() async throws {
        let id = UUID()
        let registration = TerminalProcessRegistration(terminalID: id)
        let config = GhosttyConfig(
            url: URL(fileURLWithPath: "/tmp/ghostty-config"),
            contents: "command = /bin/zsh -f -c 'printf REGISTERED_READY; exec /bin/cat'",
            fontFamilies: [], fontSize: nil, colorTheme: nil, keybinds: []
        )
        let ready = expectation(description: "등록 파일 작성 뒤 셸 준비")
        let ended = expectation(description: "소유 PTY 프로세스 종료")
        let capture = RegistrationReadyCapture(ready: ready)
        let output = Pipe()
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-f", "-c", "exec " + registration.command(userConfig: config)]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in ended.fulfill() }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { capture.receive(data) }
        }
        try process.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            registration.remove()
        }
        await fulfillment(of: [ready], timeout: 5)
        let observedContext = HerdrProcessInspector.terminalContext(id)
        let observedInspection = HerdrProcessInspector().inspect(
            .init(foregroundGroup: 0, tty: "", terminalID: id)
        )
        try input.fileHandleForWriting.write(contentsOf: Data([4]))
        try input.fileHandleForWriting.close()
        await fulfillment(of: [ended], timeout: 5)
        let context = try XCTUnwrap(observedContext)
        XCTAssertGreaterThan(context.foregroundGroup, 0)
        XCTAssertTrue(context.tty.hasPrefix("/dev/ttys"))
        guard case .outer = observedInspection else {
            return XCTFail("실제 PTY의 등록과 foreground 검사가 연결되어야 한다.")
        }
    }

    private func process(
        pid: pid_t = 41, group: pid_t = 40, foreground: pid_t = 40,
        tty: UInt32 = 7, executable: String = "/opt/bin/herdr",
        arguments: [String] = ["herdr"], peers: [String] = ["/tmp/session/herdr-client.sock"],
        environment: [String: String] = [:], start: UInt64 = 10
    ) -> HerdrProcessInspector.ProcessEvidence {
        .init(
            identity: .init(pid: pid, startSeconds: start, startMicroseconds: 123),
            group: group, foregroundGroup: foreground, ttyDevice: tty, executable: executable,
            arguments: arguments, environment: environment, peers: peers,
            cwd: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    func testForegroundGroupMemberNeedNotBeGroupLeader() {
        let member = process()
        XCTAssertEqual(
            HerdrProcessInspector.select(context, ttyDevice: 7, processes: [member]),
            .herdr(.init(identity: member.identity, context: context, socketPath: "/tmp/session/herdr.sock"))
        )
    }

    func testRequiresSameTTYForegroundGroupAndExecutable() {
        for member in [
            process(tty: 8), process(group: 42), process(foreground: 42),
            process(executable: "/bin/herdr-helper")
        ] {
            if case .herdr = HerdrProcessInspector.select(context, ttyDevice: 7, processes: [member]) {
                XCTFail("TTY, foreground 그룹, 실행 파일 증거가 모두 필요하다.")
            }
        }
    }

    func testDaemonCLIAndRemoteLaunchAreNotLocalTUI() {
        for arguments in [
            ["herdr", "server"], ["herdr", "api", "snapshot"], ["herdr", "pane", "list"],
            ["herdr", "--remote", "host"], ["herdr", "--machine", "host"],
            ["herdr", "--version"], ["herdr", "session", "list"], ["herdr", "remote-client-bridge"]
        ] {
            XCTAssertFalse(HerdrProcessInspector.isLocalTUI(arguments))
            if case .herdr = HerdrProcessInspector.select(
                context, ttyDevice: 7, processes: [process(arguments: arguments)]
            ) {
                XCTFail("daemon, API CLI, remote 실행은 추적 대상이 아니다.")
            }
        }
        for arguments in [
            ["herdr"], ["herdr", "client"], ["herdr", "--session", "work"],
            ["herdr", "--session=work"], ["herdr", "session", "attach", "work"]
        ] {
            XCTAssertTrue(HerdrProcessInspector.isLocalTUI(arguments))
        }
    }

    func testActualPeerRequiredAndCustomOverrideMustMatchPeer() {
        XCTAssertEqual(
            HerdrProcessInspector.select(context, ttyDevice: 7, processes: [
                process(peers: [], environment: ["HERDR_SOCKET_PATH": "/tmp/custom.sock"])
            ]),
            .unavailable
        )
        XCTAssertNil(HerdrProcessInspector.apiSocketPath(peer: "/tmp/other-client.sock", explicitPath: "/tmp/custom.sock"))
        XCTAssertNil(HerdrProcessInspector.apiSocketPath(peer: "/tmp/custom-client.sock", explicitPath: nil))
        XCTAssertEqual(
            HerdrProcessInspector.apiSocketPath(peer: "/tmp/custom-client.sock", explicitPath: "/tmp/custom.sock"),
            "/tmp/custom.sock"
        )
        XCTAssertEqual(
            HerdrProcessInspector.apiSocketPath(peer: "/tmp/custom-api-client.sock", explicitPath: "/tmp/custom-api"),
            "/tmp/custom-api"
        )
        XCTAssertEqual(
            HerdrProcessInspector.apiSocketPath(peer: "/tmp/work/herdr-client.sock", explicitPath: "/tmp/unrelated.sock"),
            "/tmp/work/herdr.sock"
        )
    }

    func testAmbiguousSessionsAndPIDReuseAreNotEquivalent() {
        XCTAssertEqual(
            HerdrProcessInspector.select(context, ttyDevice: 7, processes: [process(), process(pid: 42)]),
            .unavailable
        )
        XCTAssertNotEqual(process(start: 10).identity, process(start: 11).identity)
        XCTAssertEqual(
            HerdrProcessInspector.select(context, ttyDevice: 7, processes: [
                process(peers: ["/tmp/a/herdr-client.sock", "/tmp/b/herdr-client.sock"])
            ]),
            .unavailable
        )
    }

    func testOuterForegroundDirectoryRestorationUsesGroupLeader() {
        let shell = process(pid: 40, executable: "/bin/zsh", arguments: ["zsh"], peers: [])
        XCTAssertEqual(
            HerdrProcessInspector.select(context, ttyDevice: 7, processes: [shell]),
            .outer(shell.cwd)
        )
    }

    func testNativeConnectedPeerIsNotListenerBoundAddress() throws {
        let listener = try HerdrTestListener()
        defer { listener.closeListener() }
        XCTAssertFalse(HerdrProcessInspector.connectedUNIXPeers(getpid()).contains(listener.path))
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        guard client >= 0 else { return }
        defer { close(client) }
        var address = try XCTUnwrap(HerdrSnapshotRequest.address(listener.path))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
        XCTAssertTrue(HerdrProcessInspector.connectedUNIXPeers(getpid()).contains(listener.path))
        let first = try XCTUnwrap(HerdrProcessInspector.identity(getpid()))
        XCTAssertEqual(first, HerdrProcessInspector.identity(getpid()))
        XCTAssertGreaterThan(first.startSeconds, 0)
    }
}

private final class RegistrationReadyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var delivered = false
    private let ready: XCTestExpectation

    init(ready: XCTestExpectation) { self.ready = ready }

    func receive(_ bytes: Data) {
        lock.lock()
        data.append(bytes)
        let complete = !delivered && data.range(of: Data("REGISTERED_READY".utf8)) != nil
        if complete { delivered = true }
        lock.unlock()
        if complete { ready.fulfill() }
    }
}
