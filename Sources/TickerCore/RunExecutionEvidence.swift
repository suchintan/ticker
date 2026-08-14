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
        guard result == 0 else { return unavailableBootSessionID }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
        #endif
    }

    public static func processIsAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        return Darwin.kill(processID, 0) == 0 || errno == EPERM
    }
}

public struct LaunchdRuntimeSnapshot: Equatable {
    public let processID: Int32?
    public let lastExitStatus: ExitStatus?
    public let runCount: Int64?

    public init(processID: Int32?, lastExitStatus: ExitStatus?, runCount: Int64?) {
        self.processID = processID; self.lastExitStatus = lastExitStatus; self.runCount = runCount
    }

    public static func parse(_ output: String) -> LaunchdRuntimeSnapshot {
        var processID: Int32?
        var lastExitStatus: ExitStatus?
        var runCount: Int64?
        var depth = 0
        var hasRootRecord = false

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let openingBraces = trimmed.filter { $0 == "{" }.count
            let closingBraces = trimmed.filter { $0 == "}" }.count
            let serviceLevel = hasRootRecord ? depth == 1 : depth == 0
            let normalized = trimmed.lowercased()
            if serviceLevel, let equals = trimmed.firstIndex(of: "="),
               let token = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\t\r\n"))
                .split(whereSeparator: \.isWhitespace).first {
                if normalized.hasPrefix("pid =") { processID = Int32(token) }
                else if normalized.hasPrefix("runs =") { runCount = Int64(token) }
                else if normalized.contains("last exit code") || normalized.contains("lastexitstatus"),
                        let raw = Int32(token) { lastExitStatus = ExitStatus(raw: raw) }
            }
            if !hasRootRecord, openingBraces > 0 { hasRootRecord = true }
            depth = max(0, depth + openingBraces - closingBraces)
        }
        return LaunchdRuntimeSnapshot(processID: processID, lastExitStatus: lastExitStatus,
                                      runCount: runCount)
    }
}

public enum LaunchdOwnershipStatus: Equatable {
    case owned(LaunchdRuntimeSnapshot)
    case serviceNotPublished(LaunchdRuntimeSnapshot)
}

public struct LaunchdRuntimeProbeError: Error, LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum LaunchdInvocationIdentity {
    public static func resolve(
        claimedJobID: String,
        jobs: [Job],
        canonicalize: (String) throws -> String
    ) throws -> Job {
        let canonicalClaim = try canonicalize(claimedJobID)
        let matches = try jobs.filter { try canonicalize($0.id) == canonicalClaim }
        guard matches.count == 1, let job = matches.first,
              job.source == .launchd, job.managed, job.configPath != nil,
              job.launchdDomain != nil else {
            throw LaunchdRuntimeProbeError(
                message: "scheduled wrapper identity '\(claimedJobID)' does not resolve to exactly one discovered versioned launchd plist"
            )
        }
        let serviceMatches = jobs.filter {
            $0.launchdDomain == job.launchdDomain && $0.label == job.label
        }
        guard serviceMatches.count == 1 else {
            throw LaunchdRuntimeProbeError(
                message: "launchd service identity for \(job.id) is ambiguous across \(serviceMatches.count) discovered plists"
            )
        }
        return job
    }
}

public enum LaunchdRuntimeProbe {
    public static func ownership(job: Job, processID: Int32,
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl")
    ) throws -> LaunchdOwnershipStatus {
        try ownership(job: job, processID: processID, attempts: 5, retryDelay: 0.05,
                      commandRunner: { try runAdapterCommand(executable: $0, arguments: $1) },
                      launchctlURL: launchctlURL)
    }

    static func ownership(job: Job, processID: Int32,
        attempts: Int = 5,
        retryDelay: TimeInterval = 0.05,
        commandRunner: AdapterCommandRunner = {
            try runAdapterCommand(executable: $0, arguments: $1)
        },
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl")
    ) throws -> LaunchdOwnershipStatus {
        guard job.source == .launchd, job.configPath != nil,
              let domain = job.launchdDomain else {
            throw LaunchdRuntimeProbeError(
                message: "scheduled wrapper identity '\(job.id)' is not path- and domain-qualified"
            )
        }
        let target = domain == .userAgent
            ? "gui/\(geteuid())/\(job.label)" : "system/\(job.label)"
        var snapshot = LaunchdRuntimeSnapshot(processID: nil, lastExitStatus: nil, runCount: nil)
        for attempt in 0..<max(1, attempts) {
            let result = try commandRunner(launchctlURL, ["print", target])
            guard result.status == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LaunchdRuntimeProbeError(
                    message: "launchd service \(target) could not be inspected"
                        + (detail.isEmpty ? "" : ": \(detail)")
                )
            }
            snapshot = LaunchdRuntimeSnapshot.parse(result.stdout)
            if snapshot.processID == processID { return .owned(snapshot) }
            if let reportedPID = snapshot.processID {
                throw LaunchdRuntimeProbeError(
                    message: "launchd service \(target) reports pid \(reportedPID), not this wrapper pid \(processID)"
                )
            }
            if attempt + 1 < max(1, attempts) { Thread.sleep(forTimeInterval: retryDelay) }
        }
        return .serviceNotPublished(snapshot)
    }
}
