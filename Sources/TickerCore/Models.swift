import Foundation

public enum JobSource: String, Codable, CaseIterable {
    case launchd
    case crontab
    case claudeRoutine
}

public enum RunTrigger: String, Codable, Hashable {
    case scheduled
    case manual
}

public enum LaunchdDomain: String, Codable, Hashable {
    case userAgent
    case systemDaemon
}

public enum Outcome: String, Codable {
    case running
    case success
    case failure
    case unknown
}

public enum RuntimeStatusAttribution: String, Codable, Hashable {
    case resolved
    case neverExited
    case ambiguous
    case unavailable
    case recordWithoutExit
}

public enum JobHealthPolicy {
    public static func outcome(
        for job: Job,
        scheduledHistory: Run?
    ) -> Outcome {
        let nativeOutcome = job.lastKnownExit.map {
            $0.isSuccess ? Outcome.success : Outcome.failure
        }

        if job.source == .launchd, !job.managed {
            return nativeOutcome ?? scheduledHistory?.outcome ?? .unknown
        }

        guard job.source == .launchd, job.managed,
              let scheduledHistory else {
            return scheduledHistory?.outcome ?? nativeOutcome ?? .unknown
        }

        if scheduledHistory.outcome == .running {
            return scheduledHistory.isCorroboratedRunning
                    && scheduledHistory.processID == job.launchdProcessID
                ? .running
                : (nativeOutcome ?? .unknown)
        }

        if nativeOutcome == .failure, scheduledHistory.outcome == .success {
            guard scheduledHistory.bootSessionID == RunExecutionEvidence.currentBootSessionID()
            else {
                return .failure
            }
            guard scheduledHistory.nativeExitStatusAtStart == job.lastKnownExit?.raw else {
                return .failure
            }
            guard let currentRunCount = job.launchdRunCount,
                  let startingRunCount = scheduledHistory.launchdRunCountAtStart,
                  currentRunCount == startingRunCount else {
                return .failure
            }
        }
        return scheduledHistory.outcome
    }
}

public struct Job: Identifiable, Codable, Hashable {
    public let id: String
    public let source: JobSource
    public let label: String
    public let schedule: Schedule
    public let command: [String]
    public let argv0: String?
    public let environment: [String: String]
    public let cwd: String?
    public let enabled: Bool
    public let runtimeStatusAttribution: RuntimeStatusAttribution?
    public let launchdDomain: LaunchdDomain?
    public let launchdUserName: String?
    public let launchdGroupName: String?
    public let runNowUnavailableReason: String?
    public let configPath: String?
    public let lastKnownExit: ExitStatus?
    public let nativeStatusObservedAt: Date?
    public let launchdProcessID: Int32?
    public let launchdRunCount: Int64?
    public let lastRunAt: Date?
    public let lastScheduledFor: Date?
    public let managed: Bool

    public init(
        id: String,
        source: JobSource,
        label: String,
        schedule: Schedule,
        command: [String],
        argv0: String? = nil,
        environment: [String: String] = [:],
        cwd: String?,
        enabled: Bool,
        launchdDomain: LaunchdDomain? = nil,
        launchdUserName: String? = nil,
        launchdGroupName: String? = nil,
        runNowUnavailableReason: String? = nil,
        runtimeStatusAttribution: RuntimeStatusAttribution? = nil,
        configPath: String?,
        lastKnownExit: ExitStatus?,
        nativeStatusObservedAt: Date? = nil,
        launchdProcessID: Int32? = nil,
        launchdRunCount: Int64? = nil,
        lastRunAt: Date?,
        lastScheduledFor: Date?,
        managed: Bool
    ) {
        self.id = id
        self.source = source
        self.label = label
        self.schedule = schedule
        self.command = command
        self.argv0 = argv0
        self.environment = environment
        self.cwd = cwd
        self.enabled = enabled
        self.runtimeStatusAttribution = runtimeStatusAttribution
        self.launchdDomain = launchdDomain
        self.launchdUserName = launchdUserName
        self.launchdGroupName = launchdGroupName
        self.runNowUnavailableReason = runNowUnavailableReason
        self.configPath = configPath
        self.lastKnownExit = lastKnownExit
        self.nativeStatusObservedAt = nativeStatusObservedAt
        self.launchdProcessID = launchdProcessID
        self.launchdRunCount = launchdRunCount
        self.lastRunAt = lastRunAt
        self.lastScheduledFor = lastScheduledFor
        self.managed = managed
    }

    public var nextFireAt: Date? {
        schedule.nextFire(after: Date(), calendar: .current)
    }

    public var canRunNow: Bool {
        !command.isEmpty && runNowUnavailableReason == nil
    }

    public var runtimeStatusExplanation: String? {
        guard source == .launchd, let runtimeStatusAttribution else {
            return nil
        }

        let domainDescription: String
        switch launchdDomain {
        case .userAgent:
            domainDescription = "the signed-in user's gui domain"
        case .systemDaemon:
            domainDescription = "the system domain"
        case nil:
            domainDescription = "its launchd domain"
        }

        switch runtimeStatusAttribution {
        case .resolved:
            return "Ticker resolved the last-exit status from this job's own domain-qualified launchd record in \(domainDescription)."
        case .neverExited:
            return "Launchd's domain-qualified record for label '\(label)' in \(domainDescription) reports that this job is running and has never exited, so no last-exit record exists yet."
        case .ambiguous:
            return "Another discovered launchd plist also uses label '\(label)' in \(domainDescription), so Ticker cannot determine which plist owns launchd's single runtime record."
        case .unavailable:
            return "Launchd has no domain-qualified runtime record for label '\(label)' in \(domainDescription); the job is not loaded or its record is unavailable."
        case .recordWithoutExit:
            return "Launchd's domain-qualified runtime record for label '\(label)' in \(domainDescription) does not include a usable last-exit status."
        }
    }

    public var skew: TimeInterval? {
        guard let lastRunAt = lastRunAt, let lastScheduledFor = lastScheduledFor else {
            return nil
        }
        return lastRunAt.timeIntervalSince(lastScheduledFor)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case label
        case schedule
        case command
        case argv0
        case environment
        case cwd
        case enabled
        case launchdDomain
        case launchdUserName
        case launchdGroupName
        case runNowUnavailableReason
        case runtimeStatusAttribution
        case configPath
        case lastKnownExit
        case nativeStatusObservedAt
        case launchdProcessID
        case launchdRunCount
        case lastRunAt
        case lastScheduledFor
        case managed
    }
}

public struct Run: Identifiable, Codable, Hashable {
    public let id: Int64
    public let jobID: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let exitCode: Int32?
    public let stdoutTail: String?
    public let stderrTail: String?
    public let trigger: RunTrigger
    public let processID: Int32?
    public let bootSessionID: String?
    public let nativeExitStatusAtStart: Int32?
    public let launchdRunCountAtStart: Int64?

    public init(
        id: Int64,
        jobID: String,
        startedAt: Date,
        finishedAt: Date?,
        exitCode: Int32?,
        stdoutTail: String?,
        trigger: RunTrigger = .scheduled,
        stderrTail: String?,
        processID: Int32? = nil,
        bootSessionID: String? = nil,
        nativeExitStatusAtStart: Int32? = nil,
        launchdRunCountAtStart: Int64? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.stdoutTail = stdoutTail
        self.trigger = trigger
        self.stderrTail = stderrTail
        self.processID = processID
        self.bootSessionID = bootSessionID
        self.nativeExitStatusAtStart = nativeExitStatusAtStart
        self.launchdRunCountAtStart = launchdRunCountAtStart
    }

    public var duration: TimeInterval? {
        guard let finishedAt = finishedAt else {
            return nil
        }
        return finishedAt.timeIntervalSince(startedAt)
    }

    public var outcome: Outcome {
        guard finishedAt != nil else {
            return .running
        }
        guard let exitCode = exitCode else {
            return .unknown
        }
        return exitCode == 0 ? .success : .failure
    }

    public var isCorroboratedRunning: Bool {
        guard finishedAt == nil,
              let processID,
              let bootSessionID,
              bootSessionID != RunExecutionEvidence.unavailableBootSessionID,
              bootSessionID == RunExecutionEvidence.currentBootSessionID() else {
            return false
        }
        return RunExecutionEvidence.processIsAlive(processID)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case jobID
        case startedAt
        case finishedAt
        case exitCode
        case stdoutTail
        case trigger
        case stderrTail
        case processID
        case bootSessionID
        case nativeExitStatusAtStart
        case launchdRunCountAtStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        jobID = try container.decode(String.self, forKey: .jobID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        stdoutTail = try container.decodeIfPresent(String.self, forKey: .stdoutTail)
        stderrTail = try container.decodeIfPresent(String.self, forKey: .stderrTail)
        trigger = try container.decodeIfPresent(RunTrigger.self, forKey: .trigger) ?? .scheduled
        processID = try container.decodeIfPresent(Int32.self, forKey: .processID)
        bootSessionID = try container.decodeIfPresent(String.self, forKey: .bootSessionID)
        nativeExitStatusAtStart = try container.decodeIfPresent(
            Int32.self,
            forKey: .nativeExitStatusAtStart
        )
        launchdRunCountAtStart = try container.decodeIfPresent(
            Int64.self,
            forKey: .launchdRunCountAtStart
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(stdoutTail, forKey: .stdoutTail)
        try container.encodeIfPresent(stderrTail, forKey: .stderrTail)
        try container.encode(trigger, forKey: .trigger)
        try container.encodeIfPresent(processID, forKey: .processID)
        try container.encodeIfPresent(bootSessionID, forKey: .bootSessionID)
        try container.encodeIfPresent(nativeExitStatusAtStart, forKey: .nativeExitStatusAtStart)
        try container.encodeIfPresent(launchdRunCountAtStart, forKey: .launchdRunCountAtStart)
    }
}

public struct RunStartContext: Hashable {
    public let processID: Int32
    public let bootSessionID: String
    public let nativeExitStatusAtStart: Int32?
    public let launchdRunCountAtStart: Int64?

    public init(
        processID: Int32,
        bootSessionID: String,
        nativeExitStatusAtStart: Int32?,
        launchdRunCountAtStart: Int64?
    ) {
        self.processID = processID
        self.bootSessionID = bootSessionID
        self.nativeExitStatusAtStart = nativeExitStatusAtStart
        self.launchdRunCountAtStart = launchdRunCountAtStart
    }
}

public protocol JobSourceAdapter {
    var source: JobSource { get }
    func discover() throws -> [Job]
}

public protocol RunStore: AnyObject {
    func beginRun(
        jobID: String,
        startedAt: Date,
        trigger: RunTrigger,
        context: RunStartContext?
    ) throws -> Int64
    func finishRun(
        id: Int64,
        exitCode: Int32,
        stdoutTail: String,
        stderrTail: String,
        finishedAt: Date
    ) throws
    func runs(jobID: String, limit: Int) throws -> [Run]
    func latestRun(jobID: String) throws -> Run?
    func scheduledHealthRuns() throws -> [String: Run]
    func health() throws -> [String: Outcome]
    func markManaged(jobID: String, backupPath: String?) throws
    func unmarkManaged(jobID: String) throws
    func migrateJobIdentity(from oldJobID: String, to newJobID: String) throws
    func canonicalJobID(_ jobID: String) throws -> String
    func managedJobIDs() throws -> Set<String>
}

public extension RunStore {
    func beginRun(
        jobID: String,
        startedAt: Date,
        trigger: RunTrigger = .scheduled
    ) throws -> Int64 {
        try beginRun(jobID: jobID, startedAt: startedAt, trigger: trigger, context: nil)
    }
}
