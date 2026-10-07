import Darwin
import Foundation

struct HerdrProcessInspector: Sendable {
    struct Context: Equatable, Sendable {
        let foregroundGroup: pid_t
        let tty: String
        let terminalID: UUID?

        init(foregroundGroup: pid_t, tty: String, terminalID: UUID? = nil) {
            self.foregroundGroup = foregroundGroup
            self.tty = tty
            self.terminalID = terminalID
        }
    }

    struct Identity: Equatable, Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct Session: Equatable, Sendable {
        let identity: Identity
        let context: Context
        let socketPath: String
    }

    struct ProcessEvidence: Sendable {
        let identity: Identity
        let group: pid_t
        let foregroundGroup: pid_t
        let ttyDevice: UInt32
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let peers: [String]
        let cwd: URL?
    }

    enum Inspection: Equatable, Sendable {
        case herdr(Session)
        case outer(URL?)
        case unavailable
    }

    func inspect(_ input: Context) -> Inspection {
        let context: Context
        if input.foregroundGroup > 0, input.tty.hasPrefix("/dev/") {
            context = input
        } else if let id = input.terminalID, let discovered = Self.terminalContext(id) {
            context = discovered
        } else {
            return .unavailable
        }
        guard context.foregroundGroup > 0, context.tty.hasPrefix("/dev/") else { return .unavailable }
        var tty = stat()
        guard stat(context.tty, &tty) == 0,
              tty.st_mode & S_IFMT == S_IFCHR else { return .unavailable }
        guard let members = Self.processGroupMembers(context.foregroundGroup) else { return .unavailable }
        let evidence = members.compactMap { Self.process($0) }
        // 조회가 일부 실패한 그룹을 다른 쉘로 오인하지 않는다.
        guard evidence.count == members.count else { return .unavailable }
        return Self.select(context, ttyDevice: UInt32(bitPattern: tty.st_rdev), processes: evidence)
    }

    static func terminalContext(_ id: UUID) -> Context? {
        let url = TerminalProcessRegistration.url(for: id)
        guard let data = try? Data(contentsOf: url), data.count < 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = text.split(separator: "\n")
        guard fields.count == 2, let pid = pid_t(fields[0]), pid > 0,
              let info = bsdInfo(pid) else { return nil }
        var children = [pid_t](repeating: 0, count: 4096)
        let count = proc_listchildpids(getpid(), &children, Int32(children.count * MemoryLayout<pid_t>.stride))
        guard count > 0, count < children.count else { return nil }
        let owned = children.prefix(Int(count))
        // login은 setuid 프로세스라 역방향 조회가 제한될 수 있다. 앱 자신의 자식 목록으로 소유권을 확인한다.
        guard owned.contains(pid) || owned.contains(pid_t(info.pbi_ppid)) else { return nil }
        let ttyPath = String(fields[1])
        let name = ttyPath.dropFirst("/dev/ttys".count)
        guard ttyPath.hasPrefix("/dev/ttys"), !name.isEmpty, name.allSatisfy(\.isNumber) else { return nil }
        var device = stat()
        guard stat(ttyPath, &device) == 0, device.st_mode & S_IFMT == S_IFCHR,
              UInt32(bitPattern: device.st_rdev) == info.e_tdev else { return nil }
        // GUI 앱의 controlling TTY는 다르므로 tcgetpgrp 대신 자식 프로세스의 BSD 정보를 읽는다.
        let group = pid_t(bitPattern: info.e_tpgid)
        guard group > 0 else { return nil }
        return Context(foregroundGroup: group, tty: ttyPath)
    }

    static func processGroupMembers(_ group: pid_t) -> [pid_t]? {
        var pids = [pid_t](repeating: 0, count: 4096)
        // proc_listpgrppids는 proc_listpids와 달리 바이트 수가 아닌 PID 개수를 반환한다.
        let count = proc_listpgrppids(group, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0, count < pids.count else { return nil }
        return Array(pids.prefix(Int(count)).filter { $0 > 0 })
    }

    static func select(_ context: Context, ttyDevice: UInt32, processes: [ProcessEvidence]) -> Inspection {
        let foreground = processes.filter {
            $0.group == context.foregroundGroup && $0.foregroundGroup == context.foregroundGroup
                && $0.ttyDevice == ttyDevice
        }
        guard !foreground.isEmpty else { return .unavailable }
        let herd = foreground.filter {
            URL(fileURLWithPath: $0.executable).lastPathComponent == "herdr" && isLocalTUI($0.arguments)
        }
        guard !herd.isEmpty else {
            let leader = foreground.first { $0.identity.pid == context.foregroundGroup }
            return .outer(leader?.cwd ?? foreground.first?.cwd)
        }
        let sessions = herd.compactMap { process -> Session? in
            guard isLocalTUI(process.arguments) else { return nil }
            let paths = Set(process.peers.compactMap {
                apiSocketPath(peer: $0, explicitPath: process.environment["HERDR_SOCKET_PATH"])
            })
            guard paths.count == 1, let path = paths.first else { return nil }
            return Session(identity: process.identity, context: context, socketPath: path)
        }
        guard sessions.count == 1, let session = sessions.first else { return .unavailable }
        return .herdr(session)
    }

    static func isLocalTUI(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        var args = Array(arguments.dropFirst())
        if args.count == 3, args[0] == "session", args[1] == "attach" {
            return !args[2].isEmpty && !args[2].hasPrefix("-")
        }
        var index = 0
        while index < args.count {
            if args[index] == "--session", index + 1 < args.count, !args[index + 1].isEmpty {
                args.removeSubrange(index...index + 1)
            } else if args[index].hasPrefix("--session="), args[index].count > "--session=".count {
                args.remove(at: index)
            } else {
                index += 1
            }
        }
        return args.isEmpty || args == ["client"]
    }

    static func apiSocketPath(peer: String, explicitPath: String?) -> String? {
        guard peer.hasPrefix("/") else { return nil }
        if let explicitPath, explicitPath.hasPrefix("/") {
            let api = URL(fileURLWithPath: explicitPath)
            let client = api.deletingLastPathComponent()
                .appendingPathComponent(api.deletingPathExtension().lastPathComponent + "-client.sock").path
            if peer == client { return explicitPath }
        }
        let url = URL(fileURLWithPath: peer)
        guard url.lastPathComponent == "herdr-client.sock" else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent("herdr.sock").path
    }

    static func identity(_ pid: pid_t) -> Identity? {
        guard let info = bsdInfo(pid) else { return nil }
        return Identity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    static func connectedUNIXPeers(_ pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0, size <= 1_048_576 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 32)
        let capacity = fds.count * stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity))
        guard bytes > 0, bytes < capacity else { return [] }
        return fds.prefix(Int(bytes) / stride).compactMap { fd in
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var socket = socket_fdinfo()
            let size = MemoryLayout<socket_fdinfo>.size
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, Int32(size)) == size,
                  socket.psi.soi_family == AF_UNIX,
                  socket.psi.soi_kind == SOCKINFO_UN else { return nil }
            // unsi_addr는 자신의 주소다. 연결된 서버 주소인 unsi_caddr만 읽는다.
            var peer = socket.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path
            return withUnsafeBytes(of: &peer) { bytes in
                let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                return path.isEmpty ? nil : path
            }
        }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return info
    }

    private static func process(_ pid: pid_t) -> ProcessEvidence? {
        guard let info = bsdInfo(pid) else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var arguments: [String] = []
        var environment: [String: String] = [:]
        if URL(fileURLWithPath: executable).lastPathComponent == "herdr" {
            guard let values = processArguments(pid) else { return nil }
            arguments = values.0
            environment = values.1
        }
        var vnode = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        var cwd: URL?
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(size)) == size {
            var cpath = vnode.pvi_cdir.vip_path
            cwd = withUnsafeBytes(of: &cpath) {
                localDirectory(String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self))
            }
        }
        let identity = Identity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        guard Self.identity(pid) == identity else { return nil }
        return ProcessEvidence(
            identity: identity, group: pid_t(info.pbi_pgid), foregroundGroup: pid_t(bitPattern: info.e_tpgid),
            ttyDevice: info.e_tdev, executable: executable, arguments: arguments, environment: environment,
            peers: arguments.isEmpty ? [] : connectedUNIXPeers(pid), cwd: cwd
        )
    }

    private static func processArguments(_ pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        var size = bytes.count
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard index < size, let end = bytes[index..<size].firstIndex(of: 0) else { return nil }
            let value = String(decoding: bytes[index..<end], as: UTF8.self)
            index = end + 1
            return value
        }
        guard nextString() != nil else { return nil }
        while index < size, bytes[index] == 0 { index += 1 }
        var args: [String] = []
        for _ in 0..<argc {
            guard let arg = nextString() else { return nil }
            args.append(arg)
        }
        var environment: [String: String] = [:]
        while let value = nextString(), !value.isEmpty {
            let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { environment[String(parts[0])] = String(parts[1]) }
        }
        return (args, environment)
    }

    static func localDirectory(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }
}
