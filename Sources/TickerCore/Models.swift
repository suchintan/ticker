import Foundation

public enum JobSource: String, Codable, CaseIterable {
    case launchd
    case crontab
    case claudeRoutine
}

public enum Outcome: String, Codable {
    case running
    case success
    case failure
    case unknown
}

public struct Job: Identifiable, Codable, Hashable {
    public let id: String
    public let source: JobSource
    public let label: String
    public let schedule: Schedule
    public let command: [String]
    public let environment: [String: String]
    public let cwd: String?
    public let enabled: Bool
    public let configPath: String?
    public let lastKnownExit: ExitStatus?
    public let lastRunAt: Date?
    public let lastScheduledFor: Date?
    public let managed: Bool

    public init(
        id: String,
        source: JobSource,
        label: String,
        schedule: Schedule,
        command: [String],
        environment: [String: String] = [:],
        cwd: String?,
        enabled: Bool,
        configPath: String?,
        lastKnownExit: ExitStatus?,
        lastRunAt: Date?,
        lastScheduledFor: Date?,
        managed: Bool
    ) {
        self.id = id
        self.source = source
        self.label = label
        self.schedule = schedule
        self.command = command
        self.environment = environment
        self.cwd = cwd
        self.enabled = enabled
        self.configPath = configPath
        self.lastKnownExit = lastKnownExit
        self.lastRunAt = lastRunAt
        self.lastScheduledFor = lastScheduledFor
        self.managed = managed
    }

    public var nextFireAt: Date? {
        schedule.nextFire(after: Date(), calendar: .current)
    }

    public var canRunNow: Bool {
        !command.isEmpty
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
        case environment
        case cwd
        case enabled
        case configPath
        case lastKnownExit
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

    public init(
        id: Int64,
        jobID: String,
        startedAt: Date,
        finishedAt: Date?,
        exitCode: Int32?,
        stdoutTail: String?,
        stderrTail: String?
    ) {
        self.id = id
        self.jobID = jobID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
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

    private enum CodingKeys: String, CodingKey {
        case id
        case jobID
        case startedAt
        case finishedAt
        case exitCode
        case stdoutTail
        case stderrTail
    }
}

public protocol JobSourceAdapter {
    var source: JobSource { get }
    func discover() throws -> [Job]
}

public protocol RunStore: AnyObject {
    func beginRun(jobID: String, startedAt: Date) throws -> Int64
    func finishRun(
        id: Int64,
        exitCode: Int32,
        stdoutTail: String,
        stderrTail: String,
        finishedAt: Date
    ) throws
    func runs(jobID: String, limit: Int) throws -> [Run]
    func latestRun(jobID: String) throws -> Run?
    func health() throws -> [String: Outcome]
    func markManaged(jobID: String, backupPath: String?) throws
    func unmarkManaged(jobID: String) throws
    func managedJobIDs() throws -> Set<String>
}
