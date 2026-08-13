import Darwin
import Foundation

public enum RunExecutionEvidence {
    public static let unavailableBootSessionID = "unavailable"

    public static func currentBootSessionID() -> String {
        #if TICKER_TESTING
        return "ticker-testing-boot-session"
        #else
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        guard result == 0 else {
            return unavailableBootSessionID
        }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
        #endif
    }

    public static func processIsAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else {
            return false
        }
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}

public struct LaunchdRuntimeSnapshot: Equatable {
    public let processID: Int32?
    public let lastExitStatus: ExitStatus?
    public let runCount: Int64?

    public init(processID: Int32?, lastExitStatus: ExitStatus?, runCount: Int64?) {
        self.processID = processID
        self.lastExitStatus = lastExitStatus
        self.runCount = runCount
    }

    public static func parse(_ output: String) -> LaunchdRuntimeSnapshot {
        var processID: Int32?
        var lastExitStatus: ExitStatus?
        var runCount: Int64?

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.lowercased()
            guard let equals = trimmed.firstIndex(of: "=") else {
                continue
            }
            let rawValue = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\t\r\n"))
            guard let token = rawValue.split(whereSeparator: \.isWhitespace).first else {
                continue
            }
            if normalized.hasPrefix("pid =") {
                processID = Int32(token)
            } else if normalized.hasPrefix("runs =") {
                runCount = Int64(token)
            } else if normalized.contains("last exit code")
                        || normalized.contains("lastexitstatus") {
                if let raw = Int32(token) {
                    lastExitStatus = ExitStatus(raw: raw)
                }
            }
        }
        return LaunchdRuntimeSnapshot(
            processID: processID,
            lastExitStatus: lastExitStatus,
            runCount: runCount
        )
    }
}

public struct LaunchdRuntimeProbeError: Error, LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public enum LaunchdRuntimeProbe {
    public static func snapshot(
        jobID: String,
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl")
    ) throws -> LaunchdRuntimeSnapshot {
        guard let label = label(from: jobID) else {
            throw LaunchdRuntimeProbeError(
                message: "scheduled wrapper identity '\(jobID)' is not a launchd job id"
            )
        }
        let target = "gui/\(geteuid())/\(label)"
        let result = try runAdapterCommand(
            executable: launchctlURL,
            arguments: ["print", target]
        )
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchdRuntimeProbeError(
                message: "launchd service \(target) could not be inspected"
                    + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
        return LaunchdRuntimeSnapshot.parse(result.stdout)
    }

    public static func label(from jobID: String) -> String? {
        let prefix = "launchd:"
        guard jobID.hasPrefix(prefix),
              let separator = jobID.lastIndex(of: "#"),
              separator > jobID.index(jobID.startIndex, offsetBy: prefix.count) else {
            return nil
        }
        return String(jobID[jobID.index(jobID.startIndex, offsetBy: prefix.count)..<separator])
    }
}
