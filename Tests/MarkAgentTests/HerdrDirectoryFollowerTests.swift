import Darwin
import XCTest
@testable import ma

final class HerdrDirectoryFollowerTests: XCTestCase {
    func testSnapshotIsRejectedAfterPIDReuseForegroundOrSocketChange() {
        let context = HerdrProcessInspector.Context(foregroundGroup: 42, tty: "/dev/ttys004")
        let identity = HerdrProcessInspector.Identity(pid: 43, startSeconds: 1, startMicroseconds: 2)
        let original = HerdrProcessInspector.Session(identity: identity, context: context, socketPath: "/tmp/herdr.sock")
        let directory = FileManager.default.homeDirectoryForCurrentUser
        for after in [
            HerdrProcessInspector.Inspection.herdr(.init(
                identity: .init(pid: 43, startSeconds: 2, startMicroseconds: 2),
                context: context, socketPath: original.socketPath
            )),
            .herdr(.init(
                identity: identity, context: .init(foregroundGroup: 44, tty: context.tty),
                socketPath: original.socketPath
            )),
            .herdr(.init(identity: identity, context: context, socketPath: "/tmp/other/herdr.sock")),
            .outer(directory), .unavailable
        ] {
            XCTAssertEqual(
                HerdrDirectoryFollower.validatedUpdate(before: .herdr(original), after: after, directory: directory),
                .unchanged
            )
        }
        XCTAssertEqual(
            HerdrDirectoryFollower.validatedUpdate(before: .herdr(original), after: .herdr(original), directory: directory),
            .override(directory)
        )
        XCTAssertEqual(
            HerdrDirectoryFollower.validatedUpdate(before: .herdr(original), after: .herdr(original), directory: nil),
            .unchanged
        )
        XCTAssertEqual(
            HerdrDirectoryFollower.validatedUpdate(before: .outer(directory), after: .outer(directory), directory: nil),
            .restore(directory)
        )
    }

    @MainActor
    func testManualTickSerializesAndRejectsChangedForeground() async throws {
        let started = expectation(description: "요청 시작")
        let gate = HerdrRefreshGate(started: started)
        var context = HerdrProcessInspector.Context(foregroundGroup: 42, tty: "/dev/ttys004")
        var updates: [HerdrDirectoryFollower.Update] = []
        let follower = HerdrDirectoryFollower(
            context: { context }, refresh: { _ in await gate.refresh() },
            onUpdate: { updates.append($0) }
        )
        follower.start(automatically: false)
        let task = try XCTUnwrap(follower.tick())
        XCTAssertNil(follower.tick())
        await fulfillment(of: [started], timeout: 1)
        context = .init(foregroundGroup: 43, tty: context.tty)
        await gate.finish(.override(FileManager.default.temporaryDirectory))
        await task.value
        XCTAssertTrue(updates.isEmpty)
        follower.stop()
    }

    @MainActor
    func testStopAndRestartRejectsOldGenerationWithoutOverlap() async throws {
        let started = expectation(description: "요청 시작")
        let gate = HerdrRefreshGate(started: started)
        var updates: [HerdrDirectoryFollower.Update] = []
        let context = HerdrProcessInspector.Context(foregroundGroup: 42, tty: "/dev/ttys004")
        let follower = HerdrDirectoryFollower(
            context: { context }, refresh: { _ in await gate.refresh() },
            onUpdate: { updates.append($0) }
        )
        XCTAssertNil(follower.tick())
        follower.start(automatically: false)
        let task = try XCTUnwrap(follower.tick())
        await fulfillment(of: [started], timeout: 1)
        follower.stop()
        follower.stop()
        follower.start(automatically: false)
        XCTAssertNil(follower.tick())
        await gate.finish(.override(FileManager.default.temporaryDirectory))
        await task.value
        XCTAssertTrue(updates.isEmpty)
        follower.stop()
        XCTAssertNil(follower.tick())
    }

    @MainActor
    func testManualTickAppliesOnlyLatestResultAndReleasesFollower() async throws {
        var updates: [HerdrDirectoryFollower.Update] = []
        let context = HerdrProcessInspector.Context(foregroundGroup: 42, tty: "/dev/ttys004")
        let directory = FileManager.default.homeDirectoryForCurrentUser
        var follower: HerdrDirectoryFollower? = HerdrDirectoryFollower(
            context: { context }, refresh: { _ in .override(directory) },
            onUpdate: { updates.append($0) }
        )
        weak var weakFollower: HerdrDirectoryFollower?
        weakFollower = follower
        follower?.start(automatically: false)
        let task = try XCTUnwrap(follower?.tick())
        await task.value
        XCTAssertEqual(updates, [.override(directory)])
        follower?.stop()
        follower = nil
        XCTAssertNil(weakFollower)
    }

    @MainActor
    func testProductionTimerDoesNotRetainFollower() {
        weak var weakFollower: HerdrDirectoryFollower?
        autoreleasepool {
            let follower = HerdrDirectoryFollower(context: { nil }, onUpdate: { _ in
                XCTFail("surface가 없는 추적기의 콜백")
            })
            follower.start()
            weakFollower = follower
        }
        XCTAssertNil(weakFollower)
    }

    @MainActor
    func testInFlightTaskDoesNotRetainFollower() async throws {
        let started = expectation(description: "요청 시작")
        let gate = HerdrRefreshGate(started: started)
        let context = HerdrProcessInspector.Context(foregroundGroup: 42, tty: "/dev/ttys004")
        var follower: HerdrDirectoryFollower? = HerdrDirectoryFollower(
            context: { context }, refresh: { _ in await gate.refresh() },
            onUpdate: { _ in XCTFail("해제된 추적기의 콜백") }
        )
        weak var weakFollower: HerdrDirectoryFollower?
        weakFollower = follower
        follower?.start(automatically: false)
        let task = try XCTUnwrap(follower?.tick())
        await fulfillment(of: [started], timeout: 1)
        follower = nil
        XCTAssertNil(weakFollower)
        await gate.finish(.restore(nil))
        await task.value
    }

    func testRealSocketSnapshotUsesFocusedPaneForegroundAndCwdFallback() async throws {
        for foreground in [NSHomeDirectory(), "/definitely/missing", "relative", "file:///tmp"] {
            let listener = try HerdrTestListener()
            defer { listener.closeListener() }
            let server = Task.detached {
                try listener.respond { request in
                    XCTAssertEqual(request["method"] as? String, "session.snapshot")
                    XCTAssertEqual((request["params"] as? [String: String])?.count, 0)
                    return [
                        "id": try XCTUnwrap(request["id"] as? String),
                        "result": [
                            "type": "session_snapshot",
                            "snapshot": [
                                "focused_pane_id": "focused",
                                "panes": [
                                    ["pane_id": "other", "cwd": "/"],
                                    ["pane_id": "focused", "cwd": "/tmp", "foreground_cwd": foreground]
                                ]
                            ]
                        ]
                    ]
                }
            }
            let request = HerdrSnapshotRequest()
            let directory = await Task.detached { request.directory(socketPath: listener.path, timeout: 1) }.value
            try await server.value
            XCTAssertEqual(directory, HerdrProcessInspector.localDirectory(foreground == NSHomeDirectory() ? foreground : "/tmp"))
        }
    }

    func testDecoderRejectsWrongIDMissingFocusTypeAndDuplicatePane() throws {
        for response: [String: Any] in [
            ["id": "other", "result": ["type": "session_snapshot", "snapshot": ["focused_pane_id": "p", "panes": [["pane_id": "p", "cwd": "/tmp"]]]]],
            ["id": "id", "result": ["type": "other", "snapshot": ["focused_pane_id": "p", "panes": [["pane_id": "p", "cwd": "/tmp"]]]]],
            ["id": "id", "result": ["type": "session_snapshot", "snapshot": ["panes": [["pane_id": "p", "cwd": "/tmp"]]]]],
            ["id": "id", "result": ["type": "session_snapshot", "snapshot": ["focused_pane_id": "p", "panes": [["pane_id": "p", "cwd": "/tmp"], ["pane_id": "p", "cwd": "/"]]]]]
        ] {
            XCTAssertNil(HerdrSnapshotRequest.decode(try JSONSerialization.data(withJSONObject: response), id: "id"))
        }
        XCTAssertNil(HerdrSnapshotRequest.decode(Data("not JSON".utf8), id: "id"))
        XCTAssertNil(HerdrSnapshotRequest.address(String(repeating: "x", count: 200)))
    }

    func testExpiredDeadlineDoesNotSendRequest() async throws {
        let listener = try HerdrTestListener()
        defer { listener.closeListener() }
        let result = await Task.detached {
            HerdrSnapshotRequest().directory(socketPath: listener.path, timeout: 0)
        }.value
        XCTAssertNil(result)
        let client = try listener.acceptClient()
        defer { close(client) }
        try listener.wait(client, events: POLLIN)
        var byte: UInt8 = 0
        XCTAssertEqual(recv(client, &byte, 1, 0), 0)
    }

    func testCancellationWakesRealSocketAndClosesItOnce() async throws {
        let listener = try HerdrTestListener()
        defer { listener.closeListener() }
        let received = expectation(description: "서버가 요청을 수신")
        let disconnected = expectation(description: "클라이언트 소켓 닫힘")
        let server = Task.detached {
            let client = try listener.acceptClient()
            defer { close(client) }
            _ = try listener.readRequest(client)
            received.fulfill()
            var byte: UInt8 = 0
            try listener.wait(client, events: POLLIN)
            XCTAssertEqual(recv(client, &byte, 1, 0), 0)
            disconnected.fulfill()
        }
        let request = HerdrSnapshotRequest()
        let client = Task.detached { request.directory(socketPath: listener.path, timeout: 5) }
        await fulfillment(of: [received], timeout: 2)
        request.cancel()
        request.cancel()
        let result = await client.value
        XCTAssertNil(result)
        try await server.value
        await fulfillment(of: [disconnected], timeout: 1)
        XCTAssertNil(request.directory(socketPath: listener.path))
    }

    func testReadCapAndPeerClosingWithoutResponseFailSafely() async throws {
        for oversized in [true, false] {
            let listener = try HerdrTestListener()
            defer { listener.closeListener() }
            let server = Task.detached {
                let client = try listener.acceptClient()
                defer { close(client) }
                _ = try listener.readRequest(client)
                if oversized {
                    try listener.sendBytes(Data(repeating: 65, count: HerdrSnapshotRequest.readLimit), client: client)
                }
            }
            let result = await Task.detached {
                HerdrSnapshotRequest().directory(socketPath: listener.path, timeout: 2)
            }.value
            try await server.value
            XCTAssertNil(result)
        }
    }
}

private actor HerdrRefreshGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<HerdrDirectoryFollower.Update, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func refresh() async -> HerdrDirectoryFollower.Update {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish(_ update: HerdrDirectoryFollower.Update) {
        continuation?.resume(returning: update)
        continuation = nil
    }
}

final class HerdrTestListener: @unchecked Sendable {
    let path: String
    private let fd: Int32

    init() throws {
        path = "/tmp/ma-herdr-\(UUID().uuidString).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = try XCTUnwrap(HerdrSnapshotRequest.address(path))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EIO)
        }
    }

    func closeListener() {
        close(fd)
        unlink(path)
    }

    func wait(_ descriptor: Int32, events: Int32) throws {
        var pollFD = pollfd(fd: descriptor, events: Int16(events), revents: 0)
        guard poll(&pollFD, 1, 2000) > 0, pollFD.revents & Int16(events) != 0 else { throw POSIXError(.ETIMEDOUT) }
    }

    func acceptClient() throws -> Int32 {
        try wait(fd, events: POLLIN)
        let client = accept(fd, nil, nil)
        guard client >= 0 else { throw POSIXError(.EIO) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, O_NONBLOCK)
        return client
    }

    func readRequest(_ client: Int32) throws -> [String: Any] {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while data.count < 8192 {
            try wait(client, events: POLLIN)
            let count = recv(client, &bytes, bytes.count, 0)
            guard count > 0 else { throw POSIXError(.EIO) }
            data.append(contentsOf: bytes.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data[..<newline])) as? [String: Any])
            }
        }
        throw POSIXError(.EMSGSIZE)
    }

    func sendBytes(_ data: Data, client: Int32) throws {
        var offset = 0
        while offset < data.count {
            try wait(client, events: POLLOUT)
            let count = data.withUnsafeBytes { send(client, $0.baseAddress?.advanced(by: offset), data.count - offset, 0) }
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += count
        }
    }

    func respond(_ response: ([String: Any]) throws -> [String: Any]) throws {
        let client = try acceptClient()
        defer { close(client) }
        let request = try readRequest(client)
        var data = try JSONSerialization.data(withJSONObject: response(request))
        data.append(10)
        // 나뉜 쓰기로 클라이언트가 한 번의 recv에 의존하지 않는지 검증한다.
        try sendBytes(Data(data.prefix(7)), client: client)
        try sendBytes(Data(data.dropFirst(7)), client: client)
    }
}
