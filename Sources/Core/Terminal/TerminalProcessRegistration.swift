import Darwin
import Foundation

final class TerminalProcessRegistration: Sendable {
    let url: URL

    init(terminalID: UUID) {
        url = Self.url(for: terminalID)
    }

    static func url(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("markagent-terminals-\(getpid())", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("pty")
    }

    func command(userConfig: GhosttyConfig?) -> String {
        let configured = userConfig.flatMap { GhosttyConfig.parseLastValue(forKey: "command", from: $0.contents) }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let original = configured ?? Self.quote(shell) + " -l"
        let temporary = url.appendingPathExtension("tmp")
        // -f는 등록용 zsh가 사용자 시작 파일을 실행하지 않게 한다. exec 이후 원래 셸이 한 번 실행한다.
        let script = "umask 077; /bin/mkdir -p \(Self.quote(url.deletingLastPathComponent().path)); "
            + "printf '%s\\n%s\\n' \"$$\" \"$(/usr/bin/tty)\" > \(Self.quote(temporary.path)) "
            + "&& /bin/mv -f \(Self.quote(temporary.path)) \(Self.quote(url.path)); exec \(original)"
        return "/bin/zsh -f -c " + Self.quote(script)
    }

    func shellIntegration(userConfig: GhosttyConfig?) -> String {
        if let configured = userConfig.flatMap({ GhosttyConfig.parseLastValue(forKey: "shell-integration", from: $0.contents) }),
           configured != "detect" {
            return configured
        }
        let command = userConfig.flatMap { GhosttyConfig.parseLastValue(forKey: "command", from: $0.contents) }
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
        let shell = URL(fileURLWithPath: executable.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))).lastPathComponent
        return ["bash", "fish", "zsh", "elvish"].contains(shell) ? shell : "none"
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    deinit {
        remove()
    }
}
