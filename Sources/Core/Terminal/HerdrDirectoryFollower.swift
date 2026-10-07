import Darwin
import Foundation

@MainActor
final class HerdrDirectoryFollower {
    enum Update: Equatable, Sendable {
        case override(URL)
        case restore(URL?)
        case unchanged
    }

    typealias Refresh = @Sendable (HerdrProcessInspector.Context) async -> Update
    private let context: () -> HerdrProcessInspector.Context?
    private let refresh: Refresh
    private let onUpdate: (Update) -> Void
    private var timer: DispatchSourceTimer?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var isRunning = false

    init(
        context: @escaping () -> HerdrProcessInspector.Context?,
        refresh: @escaping Refresh = HerdrDirectoryFollower.refreshNative,
        onUpdate: @escaping (Update) -> Void
    ) {
        self.context = context
        self.refresh = refresh
        self.onUpdate = onUpdate
    }

    func start(automatically: Bool = true) {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        guard automatically else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = self?.tick() }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        timer?.cancel()
        timer = nil
        task?.cancel()
        // 완료 전에는 슬롯을 비우지 않아 재활성화와 이전 요청이 겹치지 않는다.
    }

    @discardableResult
    func tick() -> Task<Void, Never>? {
        guard isRunning, task == nil, let input = context() else { return nil }
        let generation = generation
        let refresh = refresh
        let task = Task { [weak self] in
            let update = await refresh(input)
            guard let self else { return }
            self.task = nil
            guard !Task.isCancelled, self.isRunning, self.generation == generation,
                  self.context() == input else { return }
            self.onUpdate(update)
        }
        self.task = task
        return task
    }

    deinit {
        timer?.cancel()
        task?.cancel()
    }

    nonisolated static func refreshNative(_ context: HerdrProcessInspector.Context) async -> Update {
        let request = HerdrSnapshotRequest()
        let worker = Task.detached(priority: .utility) {
            let inspector = HerdrProcessInspector()
            let before = inspector.inspect(context)
            switch before {
            case .herdr(let session):
                let directory = request.directory(socketPath: session.socketPath)
                guard !Task.isCancelled else { return Update.unchanged }
                return validatedUpdate(before: before, after: inspector.inspect(context), directory: directory)
            case .outer:
                guard !Task.isCancelled else { return Update.unchanged }
                return validatedUpdate(before: before, after: inspector.inspect(context), directory: nil)
            case .unavailable:
                return .unchanged
            }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
            request.cancel()
        }
    }

    nonisolated static func validatedUpdate(
        before: HerdrProcessInspector.Inspection,
        after: HerdrProcessInspector.Inspection,
        directory: URL?
    ) -> Update {
        guard before == after else { return .unchanged }
        switch before {
        case .herdr:
            return directory.map { .override($0) } ?? .unchanged
        case .outer(let cwd):
            return .restore(cwd)
        case .unavailable:
            return .unchanged
        }
    }
}

// 취소는 shutdown으로 대기를 깨운다. close는 작업의 defer 한 곳에서만 수행한다.
final class HerdrSnapshotRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    static let readLimit = 1_048_576

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
    }

    func directory(socketPath: String, timeout: TimeInterval = 0.35) -> URL? {
        guard var address = Self.address(socketPath) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        lock.lock()
        if cancelled {
            lock.unlock()
            close(descriptor)
            return nil
        }
        fd = descriptor
        lock.unlock()
        defer {
            lock.lock()
            fd = -1
            close(descriptor)
            lock.unlock()
        }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS, ready(descriptor, POLLOUT, deadline) else { return nil }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return nil }
        }
        let id = UUID().uuidString
        guard var data = try? JSONSerialization.data(withJSONObject: [
            "id": id, "method": "session.snapshot", "params": [:]
        ]) else { return nil }
        data.append(10)
        var offset = 0
        while offset < data.count {
            guard ready(descriptor, POLLOUT, deadline) else { return nil }
            let sent = data.withUnsafeBytes { send(descriptor, $0.baseAddress?.advanced(by: offset), data.count - offset, 0) }
            if sent < 0, errno == EINTR || errno == EAGAIN { continue }
            guard sent > 0 else { return nil }
            offset += sent
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while response.count < Self.readLimit {
            guard ready(descriptor, POLLIN, deadline) else { return nil }
            let count = recv(descriptor, &buffer, min(buffer.count, Self.readLimit - response.count), 0)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return nil }
            response.append(contentsOf: buffer.prefix(count))
            if let newline = response.firstIndex(of: 10) {
                return Self.decode(Data(response[..<newline]), id: id)
            }
        }
        return nil
    }

    private func ready(_ fd: Int32, _ events: Int32, _ deadline: TimeInterval) -> Bool {
        while true {
            lock.lock()
            let cancelled = cancelled
            lock.unlock()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard !cancelled, remaining > 0 else { return false }
            var pollFD = pollfd(fd: fd, events: Int16(events), revents: 0)
            let result = poll(&pollFD, 1, Int32(ceil(remaining * 1000)))
            if result < 0, errno == EINTR { continue }
            return result > 0 && pollFD.revents & Int16(events) != 0
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0),
              bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes)
        }
        return address
    }

    static func decode(_ data: Data, id: String) -> URL? {
        struct Response: Decodable {
            struct Result: Decodable {
                struct Snapshot: Decodable {
                    struct Pane: Decodable {
                        let pane_id: String
                        let cwd: String?
                        let foreground_cwd: String?
                    }
                    let focused_pane_id: String?
                    let panes: [Pane]
                }
                let type: String
                let snapshot: Snapshot
            }
            let id: String
            let result: Result
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.id == id, response.result.type == "session_snapshot",
              let focused = response.result.snapshot.focused_pane_id else { return nil }
        let panes = response.result.snapshot.panes.filter { $0.pane_id == focused }
        guard panes.count == 1, let pane = panes.first else { return nil }
        return HerdrProcessInspector.localDirectory(pane.foreground_cwd)
            ?? HerdrProcessInspector.localDirectory(pane.cwd)
    }
}
