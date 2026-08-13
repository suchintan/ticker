import Darwin
import Foundation

public struct ExitStatus: Codable, Hashable {
    public let raw: Int32

    public init(raw: Int32) {
        self.raw = raw
    }

    public var code: Int32 {
        raw > 255 ? raw >> 8 : raw
    }

    public var signal: Int32? {
        let value = raw & 0x7f
        return value == 0 ? nil : value
    }

    public var isSuccess: Bool {
        code == 0 && signal == nil
    }

    public var meaning: String {
        switch code {
        case 0:
            return "ok"
        case 1:
            return "general error"
        case 2:
            return "shell misuse"
        case 126:
            return "not executable"
        case 127:
            return "command not found"
        default:
            break
        }

        if code > 128 && code <= 255 {
            return Self.signalMeaning(code - 128)
        }
        if raw <= 255, let signal = signal {
            return Self.signalMeaning(signal)
        }
        return "exit code \(code)"
    }

    private static func signalMeaning(_ signal: Int32) -> String {
        "killed by \(signalName(signal))"
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP:
            return "SIGHUP"
        case SIGINT:
            return "SIGINT"
        case SIGQUIT:
            return "SIGQUIT"
        case SIGILL:
            return "SIGILL"
        case SIGTRAP:
            return "SIGTRAP"
        case SIGABRT:
            return "SIGABRT"
        case SIGFPE:
            return "SIGFPE"
        case SIGKILL:
            return "SIGKILL"
        case SIGBUS:
            return "SIGBUS"
        case SIGSEGV:
            return "SIGSEGV"
        case SIGPIPE:
            return "SIGPIPE"
        case SIGALRM:
            return "SIGALRM"
        case SIGTERM:
            return "SIGTERM"
        case SIGSTOP:
            return "SIGSTOP"
        case SIGTSTP:
            return "SIGTSTP"
        case SIGCONT:
            return "SIGCONT"
        case SIGCHLD:
            return "SIGCHLD"
        case SIGXCPU:
            return "SIGXCPU"
        case SIGXFSZ:
            return "SIGXFSZ"
        case SIGUSR1:
            return "SIGUSR1"
        case SIGUSR2:
            return "SIGUSR2"
        default:
            return "signal \(signal)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case raw
    }
}
