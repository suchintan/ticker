import Darwin
import Dispatch
import Foundation
import TickerCore

private let tickerVersion = "0.1.0"
private let defaultTailBytes = 8 * 1_024
private let maxTailBytes = 1_024 * 1_024
private let postExitDrainTimeout = DispatchTimeInterval.seconds(2)
private let postExitForwardTimeout = DispatchTimeInterval.milliseconds(250)
private let maxPendingForwardBytes = 1_024 * 1_024
private let humanDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = .current
    formatter.locale = .current
    formatter.timeZone = .current
    formatter.dateFormat = "EEE d MMM HH:mm"
    return formatter
}()


private enum CLIError: Error {
    case usage(String)
    case operation(String)

    var message: String {
        switch self {
        case .usage(let message), .operation(let message):
            return message
        }
    }
}

private struct ExitStatusRecord: Encodable {
    let raw: Int32
    let code: Int32
    let meaning: String

    init(_ status: ExitStatus) {
        raw = status.raw
        code = status.code
        meaning = status.meaning
    }
}

private struct ListRecord: Encodable {
    let id: String
    let source: JobSource
    let provenance: JobProvenance
    let attention: JobAttention?
    let isBroken: Bool
    let needsAttention: Bool
    let label: String
    let schedule: String
    let command: [String]
    let argv0: String?
    let environment: [String: String]
    let cwd: String?
    let enabled: Bool
    let runtimeStatusAttribution: RuntimeStatusAttribution?
    let runtimeStatusExplanation: String?
    let configPath: String?
    let launchdDomain: LaunchdDomain?
    let launchdUserName: String?
    let launchdGroupName: String?
    let runNowUnavailableReason: String?
    let lastKnownExit: ExitStatusRecord?
    let nativeStatusObservedAt: Date?
    let lastRunAt: Date?
    let lastScheduledFor: Date?
    let managed: Bool
    let nextFireAt: Date?
    let skew: TimeInterval?
    let lastOutcome: Outcome

    init(job: Job, lastOutcome: Outcome) {
        id = job.id
        source = job.source
        provenance = job.provenance
        attention = job.attention
        isBroken = job.isBroken
        needsAttention = job.isBroken
            || job.runtimeStatusAttribution == .ambiguous
            || (job.enabled
                && (lastOutcome == .failure
                    || lastOutcome == .interrupted))
        label = job.label
        schedule = job.schedule.humanDescription
        command = job.command
        argv0 = job.argv0
        environment = job.environment
        cwd = job.cwd
        enabled = job.enabled
        runtimeStatusAttribution = job.runtimeStatusAttribution
        runtimeStatusExplanation = job.runtimeStatusExplanation
        launchdDomain = job.launchdDomain
        launchdUserName = job.launchdUserName
        launchdGroupName = job.launchdGroupName
        runNowUnavailableReason = job.runNowUnavailableReason
        configPath = job.configPath
        lastKnownExit = job.lastKnownExit.map(ExitStatusRecord.init)
        nativeStatusObservedAt = job.nativeStatusObservedAt
        lastRunAt = job.lastRunAt
        lastScheduledFor = job.lastScheduledFor
        managed = job.managed
        nextFireAt = job.nextFireAt
        skew = job.skew
        self.lastOutcome = lastOutcome
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encode(provenance, forKey: .provenance)
        try encode(attention, into: &container, forKey: .attention)
        try container.encode(isBroken, forKey: .isBroken)
        try container.encode(needsAttention, forKey: .needsAttention)
        try container.encode(label, forKey: .label)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(command, forKey: .command)
        try container.encode(environment, forKey: .environment)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(managed, forKey: .managed)
        try container.encode(lastOutcome, forKey: .lastOutcome)
        try encode(argv0, into: &container, forKey: .argv0)
        try encode(cwd, into: &container, forKey: .cwd)
        try encode(runtimeStatusAttribution, into: &container, forKey: .runtimeStatusAttribution)
        try encode(runtimeStatusExplanation, into: &container, forKey: .runtimeStatusExplanation)
        try encode(launchdDomain, into: &container, forKey: .launchdDomain)
        try encode(launchdUserName, into: &container, forKey: .launchdUserName)
        try encode(launchdGroupName, into: &container, forKey: .launchdGroupName)
        try encode(runNowUnavailableReason, into: &container, forKey: .runNowUnavailableReason)
        try encode(configPath, into: &container, forKey: .configPath)
        try encode(lastKnownExit, into: &container, forKey: .lastKnownExit)
        try encode(nativeStatusObservedAt, into: &container, forKey: .nativeStatusObservedAt)
        try encode(lastRunAt, into: &container, forKey: .lastRunAt)
        try encode(lastScheduledFor, into: &container, forKey: .lastScheduledFor)
        try encode(nextFireAt, into: &container, forKey: .nextFireAt)
        try encode(skew, into: &container, forKey: .skew)
    }

    private func encode<Value: Encodable>(
        _ value: Value?,
        into container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case provenance
        case attention
        case isBroken
        case needsAttention
        case label
        case schedule
        case command
        case argv0
        case environment
        case cwd
        case enabled
        case runtimeStatusAttribution
        case runtimeStatusExplanation
        case launchdDomain
        case launchdUserName
        case launchdGroupName
        case runNowUnavailableReason
        case configPath
        case lastKnownExit
        case nativeStatusObservedAt
        case lastRunAt
        case lastScheduledFor
        case managed
        case nextFireAt
        case skew
        case lastOutcome
    }
}

private struct HistoryRecord: Encodable {
    let id: Int64
    let jobID: String
    let startedAt: Date
    let finishedAt: Date?
    let duration: TimeInterval?
    let exitCode: Int32?
    let trigger: RunTrigger
    let outcome: Outcome
    let stdoutTail: String?
    let stderrTail: String?
}

private struct InterruptedRecord: Encodable {
    let id: Int64
    let jobID: String
    let startedAt: Date
    let duration: TimeInterval?
    let trigger: RunTrigger
    let processID: Int32?
    let bootSessionID: String?
    let outcome: Outcome

    init(_ run: Run) {
        id = run.id
        jobID = run.jobID
        startedAt = run.startedAt
        duration = nil
        trigger = run.trigger
        processID = run.processID
        bootSessionID = run.bootSessionID
        outcome = .interrupted
    }
}

private struct RecoveryPolicyRecord: Encodable {
    let jobID: String
    let policy: RecoveryPolicy
}

private struct RecoveryRecord: Encodable {
    let runID: Int64
    let jobID: String
    let status: String
    let policy: RecoveryPolicy?
    let dateKey: String?
    let exitCode: Int32?
    let claimID: String?
    let message: String?
}

private struct RecoveryChildResult {
    let terminationStatus: Int32?
    let launchError: String?
}
private final class TailBuffer {
    private let capacity: Int
    private let lock = NSLock()
    private var data = Data()

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }

        if newData.count >= capacity {
            data = Data(newData.suffix(capacity))
            return
        }

        let excess = data.count + newData.count - capacity
        if excess > 0 {
            data.removeFirst(excess)
        }
        data.append(newData)
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class OutputForwarder {
    private let parentHandle: FileHandle
    private let queue: DispatchQueue
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var pendingBytes = 0

    init(parentHandle: FileHandle, label: String) {
        self.parentHandle = parentHandle
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func forward(_ data: Data) {
        lock.lock()
        let available = max(0, maxPendingForwardBytes - pendingBytes)
        guard available > 0 else {
            lock.unlock()
            return
        }
        let forwarded = data.count <= available ? data : Data(data.prefix(available))
        pendingBytes += forwarded.count
        group.enter()
        lock.unlock()

        queue.async {
            self.parentHandle.write(forwarded)
            self.lock.lock()
            self.pendingBytes -= forwarded.count
            self.lock.unlock()
            self.group.leave()
        }
    }

    func flush(timeout: DispatchTimeInterval) {
        _ = group.wait(timeout: .now() + timeout)
    }
}

private final class SignalForwarder {
    private let lock = NSLock()
    private let interruptSource: DispatchSourceSignal
    private let terminateSource: DispatchSourceSignal
    // A live process-group id is read and signalled only while this lock is held.
    // The child stays unreaped until the same lock clears the id, so the kernel
    // cannot reuse the numeric process-group id during a forwarding send.
    private var processGroupIdentifier: pid_t?
    private var pendingSignals: [Int32] = []
    private var restoreDisposition: () -> Void = {}
    private var stopped = false
    private var disposed = false

    init() {
        let previousInterruptHandler = Darwin.signal(SIGINT, SIG_IGN)
        let previousTerminateHandler = Darwin.signal(SIGTERM, SIG_IGN)
        restoreDisposition = {
            Darwin.signal(SIGINT, previousInterruptHandler)
            Darwin.signal(SIGTERM, previousTerminateHandler)
        }

        interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interruptSource.setEventHandler { [weak self] in
            self?.forward(SIGINT)
        }
        terminateSource.setEventHandler { [weak self] in
            self?.forward(SIGTERM)
        }
        interruptSource.resume()
        terminateSource.resume()
    }

    func attach(processGroupIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else {
            return
        }
        self.processGroupIdentifier = processGroupIdentifier
        for signal in pendingSignals {
            _ = Darwin.kill(-processGroupIdentifier, signal)
        }
        pendingSignals.removeAll(keepingCapacity: false)
    }

    func reap(processIdentifier: pid_t) throws -> Int32 {
        waitForChildExitWithoutReaping(processIdentifier)

        lock.lock()
        stopped = true
        processGroupIdentifier = nil
        pendingSignals.removeAll(keepingCapacity: false)
        do {
            let status = try reapChild(processIdentifier)
            lock.unlock()
            return status
        } catch {
            lock.unlock()
            throw error
        }
    }

    func stop() {
        lock.lock()
        guard !disposed else {
            lock.unlock()
            return
        }
        disposed = true
        stopped = true
        processGroupIdentifier = nil
        pendingSignals.removeAll(keepingCapacity: false)
        lock.unlock()
        finish()
    }

    private func finish() {
        interruptSource.cancel()
        terminateSource.cancel()
        restoreDisposition()
    }

    private func forward(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else {
            return
        }
        guard let processGroupIdentifier else {
            pendingSignals.append(signal)
            return
        }
        _ = Darwin.kill(-processGroupIdentifier, signal)
    }
}

private struct TickerCLI {
    func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            print(Self.help)
            return
        }

        let remaining = Array(arguments.dropFirst())
        switch command {
        case "--help", "-h", "help":
            print(Self.help)
        case "--version", "-v":
            print("ticker \(tickerVersion)")
        case "run":
            try runChild(arguments: remaining)
        case "list":
            try list(arguments: remaining)
        case "history":
            try history(arguments: remaining)
        case "interrupted":
            try interrupted(arguments: remaining)
        case "wrap":
            try wrap(arguments: remaining)
        case "unwrap":
            try unwrap(arguments: remaining)
        case "doctor":
            try doctor(arguments: remaining)
        case "login-item":
            try loginItem(arguments: remaining)
        case "recovery-policy":
            try recoveryPolicy(arguments: remaining)
        case "recovery-agent":
            try recoveryAgent(arguments: remaining)
        case "recover":
            try recover(arguments: remaining)
        default:
            throw CLIError.usage("Unknown command '\(command)'. Run 'ticker --help' for usage.")
        }
    }

    private func runChild(arguments: [String]) throws {
        if arguments.first == "--recovery" {
            try runRecoveryChild(arguments: Array(arguments.dropFirst()))
            return
        }
        guard let separator = arguments.firstIndex(of: "--") else {
            throw CLIError.usage("run requires '--' before the child command")
        }

        let options = Array(arguments[..<separator])
        let childArguments = Array(arguments[arguments.index(after: separator)...])
        guard !childArguments.isEmpty else {
            throw CLIError.usage("run requires a child command after '--'")
        }

        var label: String?
        var originalArgv0: String?
        var tailBytes = defaultTailBytes
        var trigger: RunTrigger = .scheduled
        var wrapperVersionSeen = false
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--manual":
                guard trigger != .manual else {
                    throw CLIError.usage("--manual may be specified only once")
                }
                trigger = .manual
                index += 1
            case "--label":
                guard index + 1 < options.count else {
                    throw CLIError.usage("--label requires a job id")
                }
                label = options[index + 1]
                index += 2
            case "--ticker-wrapper-version":
                wrapperVersionSeen = true
                guard index + 1 < options.count,
                      options[index + 1] == LaunchdWrapper.currentVersion else {
                    throw CLIError.usage(
                        "--ticker-wrapper-version requires supported version \(LaunchdWrapper.currentVersion)"
                    )
                }
                index += 2
            case "--argv0":
                guard index + 1 < options.count else {
                    throw CLIError.usage("--argv0 requires a value")
                }
                originalArgv0 = options[index + 1]
                index += 2
            case "--tail-bytes":
                guard index + 1 < options.count,
                      let parsed = Int(options[index + 1]), parsed > 0 else {
                    throw CLIError.usage("--tail-bytes requires a positive integer")
                }
                tailBytes = min(parsed, maxTailBytes)
                index += 2
            default:
                throw CLIError.usage("Unknown run option '\(options[index])'")
            }
        }

        guard let jobID = label, !jobID.isEmpty else {
            throw CLIError.usage("run requires --label <id>")
        }
        guard trigger == .manual || wrapperVersionSeen else {
            throw CLIError.usage(
                "scheduled run requires --ticker-wrapper-version \(LaunchdWrapper.currentVersion)"
            )
        }
        var childEnvironment: [String: String]?
        var childWorkingDirectory: String?
        var wrapperRuntimeSnapshot: LaunchdRuntimeSnapshot?
        var scheduledRun: (store: SQLiteRunStore, id: Int64)?

        if trigger == .manual {
            guard !wrapperVersionSeen else {
                throw CLIError.usage("--manual cannot be combined with --ticker-wrapper-version")
            }
            let discovery = JobRegistry.standard().discoverAll()
            guard let job = discovery.jobs.first(where: { $0.id == jobID }) else {
                throw CLIError.operation(
                    "Cannot run \(jobID) manually because it is not a currently discovered job."
                )
            }
            guard job.canRunNow else {
                throw CLIError.operation(
                    "Cannot run \(job.label) manually: "
                        + (job.effectiveRunNowUnavailableReason
                            ?? "Ticker cannot faithfully reproduce its scheduled execution context.")
                )
            }
            guard childArguments == job.command, originalArgv0 == job.argv0 else {
                throw CLIError.operation(
                    "Cannot run \(job.label) manually because the supplied command does not match the discovered job."
                )
            }
            childEnvironment = SchedulerEnvironment.effectiveEnvironment(for: job)
            childWorkingDirectory = job.cwd
        } else {
            var authorizedStore: SQLiteRunStore?
            do {
                let store = try SQLiteRunStore(
                    path: configuredStorePath(scheduledWrapperInvocation: true)
                )
                authorizedStore = store
                let launchdJobs = try LaunchdAdapter().discover()
                let job = try LaunchdInvocationIdentity.resolve(
                    claimedJobID: jobID,
                    jobs: launchdJobs,
                    canonicalize: store.canonicalJobID
                )
                guard childArguments == job.command, originalArgv0 == job.argv0 else {
                    throw LaunchdRuntimeProbeError(
                        message: "scheduled command does not match the discovered wrapper for \(job.id)"
                    )
                }
                let status = try LaunchdRuntimeProbe.ownership(
                    job: job,
                    processID: getpid(),
                    launchctlURL: scheduledLaunchctlURL()
                )
                switch status {
                case .owned(let snapshot):
                    wrapperRuntimeSnapshot = snapshot
                case .serviceNotPublished:
                    throw LaunchdRuntimeProbeError(
                        message: "launchd service exists but has not published this wrapper pid yet"
                    )
                }
            } catch {
                let message = "scheduled wrapper authorization failed for \(jobID); "
                    + "child was not executed: \(error.localizedDescription)"
                if let authorizedStore {
                    try? authorizedStore.recordRecorderDiagnostic(
                        claimedJobID: jobID,
                        message: message
                    )
                }
                throw CLIError.operation(message)
            }

            guard let authorizedStore, let wrapperRuntimeSnapshot else {
                throw CLIError.operation(
                    "scheduled wrapper authorization failed for \(jobID); child was not executed"
                )
            }
            do {
                let runID = try authorizedStore.beginRun(
                    jobID: jobID,
                    startedAt: Date(),
                    trigger: trigger,
                    context: RunStartContext(
                        processID: getpid(),
                        bootSessionID: RunExecutionEvidence.currentBootSessionID(),
                        nativeExitStatusAtStart: wrapperRuntimeSnapshot.lastExitStatus?.raw,
                        launchdRunCountAtStart: wrapperRuntimeSnapshot.runCount
                    )
                )
                scheduledRun = (authorizedStore, runID)
                do {
                    try authorizedStore.clearRecorderDiagnostic(claimedJobID: jobID)
                } catch {
                    writeStandardError(
                        "ticker: could not clear resolved recorder diagnostic: "
                            + "\(error.localizedDescription)\n"
                    )
                }
            } catch {
                let message = "scheduled durable run-start failed for \(jobID); "
                    + "child was not executed: \(error.localizedDescription)"
                try? authorizedStore.recordRecorderDiagnostic(
                    claimedJobID: jobID,
                    message: message
                )
                throw CLIError.operation(message)
            }
        }

        executeChild(
            jobID: jobID,
            arguments: childArguments,
            originalArgv0: originalArgv0,
            tailBytes: tailBytes,
            trigger: trigger,
            scheduledRun: scheduledRun,
            environment: childEnvironment,
            currentDirectory: childWorkingDirectory
        )
    }
    private func runRecoveryChild(arguments: [String]) throws {
        guard let separator = arguments.firstIndex(of: "--") else {
            throw CLIError.usage(
                "recovery run requires --recovery-claim, --recovery-task, "
                    + "--recovery-date, --label, and '--' before the child command"
            )
        }
        let options = Array(arguments[..<separator])
        let childArguments = Array(arguments[arguments.index(after: separator)...])
        guard !childArguments.isEmpty else {
            throw CLIError.usage("recovery run requires a child command after '--'")
        }

        var claimID: String?
        var taskID: String?
        var dateKey: String?
        var jobID: String?
        var originalArgv0: String?
        var argv0Seen = false
        var index = 0
        while index < options.count {
            let option = options[index]
            guard index + 1 < options.count else {
                throw CLIError.usage("recovery run option \(option) requires a value")
            }
            let value = options[index + 1]
            guard !value.isEmpty else {
                throw CLIError.usage("recovery run option \(option) requires a non-empty value")
            }
            switch option {
            case "--recovery-claim":
                guard claimID == nil else {
                    throw CLIError.usage("--recovery-claim may be specified only once")
                }
                claimID = value
            case "--recovery-task":
                guard taskID == nil else {
                    throw CLIError.usage("--recovery-task may be specified only once")
                }
                taskID = value
            case "--recovery-date":
                guard dateKey == nil else {
                    throw CLIError.usage("--recovery-date may be specified only once")
                }
                dateKey = value
            case "--label":
                guard jobID == nil else {
                    throw CLIError.usage("--label may be specified only once")
                }
                jobID = value
            case "--argv0":
                guard !argv0Seen else {
                    throw CLIError.usage("--argv0 may be specified only once")
                }
                argv0Seen = true
                originalArgv0 = value
            default:
                throw CLIError.usage(
                    "recovery run does not accept \(option); wrapper and manual flags are forbidden"
                )
            }
            index += 2
        }

        guard let claimID, let taskID, let dateKey, let jobID else {
            throw CLIError.usage(
                "recovery run requires exact --recovery-claim, --recovery-task, "
                    + "--recovery-date, and --label options"
            )
        }

        let store = try SQLiteRunStore(path: configuredStorePath())
        let discovery = discoverJobs()
        guard discovery.complete else {
            throw CLIError.operation("recovery job discovery was incomplete; child was not executed")
        }
        let canonicalJobID = try store.canonicalJobID(jobID)
        let matchingJobs = discovery.jobs.filter { job in
            guard let candidate = try? store.canonicalJobID(job.id) else {
                return false
            }
            return candidate == canonicalJobID
        }
        guard matchingJobs.count == 1, let job = matchingJobs.first, job.managed else {
            throw CLIError.operation(
                "recovery label \(jobID) does not resolve to exactly one current managed job"
            )
        }

        guard let storedPolicy = try store.recoveryPolicy(jobID: canonicalJobID),
              case .retryIdempotent(let storedTaskID, let timeZone) = storedPolicy,
              storedTaskID == taskID else {
            throw CLIError.operation(
                "recovery policy for \(canonicalJobID) does not authorize task \(taskID)"
            )
        }
        guard let claim = try store.recoveryAttempt(claimID: claimID),
              claim.claimID == claimID,
              claim.jobID == canonicalJobID,
              claim.taskID == taskID,
              claim.dateKey == dateKey,
              claim.status == .claimed,
              let interruptedRunID = claim.interruptedRunID else {
            throw CLIError.operation("recovery claim is missing, forged, or no longer claimable")
        }

        let runs = try store.runs(jobID: canonicalJobID, limit: Int.max)
        guard let interruptedRun = runs.first(where: { $0.id == interruptedRunID }),
              interruptedRun.finishedAt == nil,
              interruptedRun.observedOutcome(for: job) == .interrupted else {
            throw CLIError.operation("recovery claim does not reference a current interrupted run")
        }
        let expectedDate = try RecoveryDate.key(
            for: interruptedRun.startedAt,
            timeZoneIdentifier: timeZone
        )
        guard expectedDate == dateKey else {
            throw CLIError.operation("recovery date does not match the interrupted run")
        }
        guard childArguments == job.command + ["--recovery-date", expectedDate],
              originalArgv0 == job.argv0 else {
            throw CLIError.operation("recovery child command does not match the current job")
        }

        _ = try store.startRecoveryAttempt(
            claimID: claimID,
            jobID: canonicalJobID,
            taskID: taskID,
            dateKey: dateKey,
            startedAt: Date()
        )
        let runID = try store.beginRun(
            jobID: canonicalJobID,
            startedAt: Date(),
            trigger: .recovery,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: RunExecutionEvidence.currentBootSessionID(),
                nativeExitStatusAtStart: nil,
                launchdRunCountAtStart: nil
            )
        )
        executeChild(
            jobID: canonicalJobID,
            arguments: childArguments,
            originalArgv0: originalArgv0,
            tailBytes: defaultTailBytes,
            trigger: .recovery,
            scheduledRun: (store, runID),
            environment: SchedulerEnvironment.effectiveEnvironment(for: job),
            currentDirectory: job.cwd
        )
    }


    private func executeChild(
        jobID: String,
        arguments: [String],
        originalArgv0: String?,
        tailBytes: Int,
        trigger: RunTrigger,
        scheduledRun: (store: SQLiteRunStore, id: Int64)?,
        environment: [String: String]?,
        currentDirectory: String?
    ) -> Never {
        let startedAt = Date()
        var store = scheduledRun?.store
        var runID = scheduledRun?.id

        if trigger == .scheduled, scheduledRun == nil {
            writeStandardError(
                "ticker: scheduled durable run-start is missing for \(jobID); "
                    + "child was not executed\n"
            )
            Darwin.exit(1)
        }

        if trigger == .manual {
            do {
                let openedStore = try SQLiteRunStore(path: configuredStorePath())
                store = openedStore
                do {
                    runID = try openedStore.beginRun(
                        jobID: jobID,
                        startedAt: startedAt,
                        trigger: trigger,
                        context: RunStartContext(
                            processID: getpid(),
                            bootSessionID: RunExecutionEvidence.currentBootSessionID(),
                            nativeExitStatusAtStart: nil,
                            launchdRunCountAtStart: nil
                        )
                    )
                } catch {
                    writeStandardError("ticker: could not record run start: \(error.localizedDescription)\n")
                }
            } catch {
                writeStandardError("ticker: could not open run store: \(error.localizedDescription)\n")
            }
        }

        let stdoutTail = TailBuffer(capacity: tailBytes)
        let stderrTail = TailBuffer(capacity: tailBytes)

        let effectiveEnvironment = environment ?? ProcessInfo.processInfo.environment
        let effectiveDirectory = currentDirectory ?? FileManager.default.currentDirectoryPath
        guard let executablePath = resolveExecutable(
            arguments[0],
            environment: effectiveEnvironment,
            currentDirectory: effectiveDirectory
        ) else {
            let message = "ticker: could not execute \(arguments[0]): command not found\n"
            let messageData = Data(message.utf8)
            stderrTail.append(messageData)
            FileHandle.standardError.write(messageData)
            let finalization = finishRun(
                store: store,
                runID: runID,
                exitCode: 127,
                stdoutTail: stdoutTail.string(),
                stderrTail: stderrTail.string()
            )
            Darwin.exit(exitCodeAfterFinalization(
                childExitCode: 127,
                trigger: trigger,
                jobID: jobID,
                result: finalization
            ))
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let forwarder = SignalForwarder()
        let processIdentifier: pid_t
        do {
            processIdentifier = try spawnChild(
                executablePath: executablePath,
                arguments: arguments,
                originalArgv0: originalArgv0,
                environment: effectiveEnvironment,
                currentDirectory: currentDirectory,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
            forwarder.attach(processGroupIdentifier: processIdentifier)
        } catch {
            forwarder.stop()
            let message = "ticker: could not execute \(arguments[0]): \(error.localizedDescription)\n"
            let messageData = Data(message.utf8)
            stderrTail.append(messageData)
            FileHandle.standardError.write(messageData)
            let finalization = finishRun(
                store: store,
                runID: runID,
                exitCode: 127,
                stdoutTail: stdoutTail.string(),
                stderrTail: stderrTail.string()
            )
            Darwin.exit(exitCodeAfterFinalization(
                childExitCode: 127,
                trigger: trigger,
                jobID: jobID,
                result: finalization
            ))
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let stdoutForwarder = OutputForwarder(
            parentHandle: FileHandle.standardOutput,
            label: "com.ticker.stdout-forwarder"
        )
        let stderrForwarder = OutputForwarder(
            parentHandle: FileHandle.standardError,
            label: "com.ticker.stderr-forwarder"
        )
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(pipe: stdoutPipe, forwarder: stdoutForwarder, tail: stdoutTail)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(pipe: stderrPipe, forwarder: stderrForwarder, tail: stderrTail)
            readers.leave()
        }

        let rawStatus: Int32
        do {
            rawStatus = try forwarder.reap(processIdentifier: processIdentifier)
        } catch {
            let messageData = Data("ticker: \(error.localizedDescription)\n".utf8)
            stderrTail.append(messageData)
            FileHandle.standardError.write(messageData)
            rawStatus = 127 << 8
        }

        if readers.wait(timeout: .now() + postExitDrainTimeout) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + .milliseconds(250))
        }
        stdoutForwarder.flush(timeout: postExitForwardTimeout)
        stderrForwarder.flush(timeout: postExitForwardTimeout)

        let exitCode = childExitCode(rawStatus)
        let finalization = finishRun(
            store: store,
            runID: runID,
            exitCode: exitCode,
            stdoutTail: stdoutTail.string(),
            stderrTail: stderrTail.string()
        )
        Darwin.exit(exitCodeAfterFinalization(
            childExitCode: exitCode,
            trigger: trigger,
            jobID: jobID,
            result: finalization
        ))
    }

    private func list(arguments: [String]) throws {
        let json = try parseJSONOnlyOption(arguments, command: "list")
        let discovery = JobRegistry.standard().discoverAll()
        for error in discovery.errors {
            writeStandardError("ticker: discovery warning: \(error.localizedDescription)\n")
        }

        let store = try SQLiteRunStore(path: configuredStorePath())
        let health = try store.scheduledHealthRuns()
        let records = discovery.jobs.sorted { left, right in
            if left.source.rawValue == right.source.rawValue {
                return left.label.localizedCaseInsensitiveCompare(right.label) == .orderedAscending
            }
            return left.source.rawValue < right.source.rawValue
        }.map { job in
            ListRecord(
                job: job,
                lastOutcome: JobHealthPolicy.outcome(
                    for: job,
                    scheduledHistory: health[job.id]
                )
            )
        }

        if json {
            try printJSON(records)
            return
        }
        let rows = records.map { record in
            [
                record.provenance.displayName,
                record.source.rawValue,
                record.isBroken
                    ? "broken"
                    : (record.runtimeStatusAttribution == .ambiguous
                        ? "needs-attention"
                        : (record.enabled ? "on" : "off")),
                record.id,
                record.label + (record.managed ? "*" : ""),
                record.schedule,
                record.nextFireAt.map(formatDate) ?? "—",
                record.lastOutcome.rawValue,
                record.runtimeStatusAttribution?.rawValue ?? "—",
                record.attention?.summary ?? "—",
            ]
        }
        printTable(
            headers: [
                "OWNER", "SOURCE", "STATE", "ID", "JOB", "SCHEDULE", "NEXT FIRE",
                "OUTCOME", "RUNTIME", "ATTENTION",
            ],
            rows: rows
        )
        print("\n* managed by Ticker")
        for record in records {
            if let attention = record.attention {
                let level = attention.requiresAttention ? "broken" : "info"
                print("\(record.id) [\(level)]: \(attention.diagnosticDescription)")
            }
        }
        for record in records where record.source == .launchd {
            if let attribution = record.runtimeStatusAttribution,
               let explanation = record.runtimeStatusExplanation {
                print("\(record.id) [\(attribution.rawValue)]: \(explanation)")
            }
        }
    }

    private func history(arguments: [String]) throws {
        guard let jobID = arguments.first, !jobID.hasPrefix("-") else {
            throw CLIError.usage("history requires <job-id>")
        }

        var limit = 20
        var json = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--limit":
                guard index + 1 < arguments.count,
                      let parsed = Int(arguments[index + 1]), parsed > 0 else {
                    throw CLIError.usage("--limit requires a positive integer")
                }
                limit = parsed
                index += 2
            case "--json":
                json = true
                index += 1
            default:
                throw CLIError.usage("Unknown history option '\(arguments[index])'")
            }
        }

        let store = try SQLiteRunStore(path: configuredStorePath())
        let runs = try store.runs(jobID: jobID, limit: limit)
        let currentJobs = jobsByCanonicalID(discoverJobs().jobs, store: store)
        let canonicalJobID = try store.canonicalJobID(jobID)
        let currentJob = currentJobs[canonicalJobID]
        if json {
            let records = runs.map { run in
                HistoryRecord(
                    id: run.id,
                    jobID: run.jobID,
                    startedAt: run.startedAt,
                    finishedAt: run.finishedAt,
                    duration: run.duration,
                    exitCode: run.exitCode,
                    trigger: run.trigger,
                    outcome: run.observedOutcome(for: currentJob),
                    stdoutTail: run.stdoutTail,
                    stderrTail: run.stderrTail
                )
            }
            try printJSON(records)
            return
        }

        let rows = runs.map { run in
            let outcome = run.observedOutcome(for: currentJob)
            let duration: String
            switch outcome {
            case .running:
                duration = "running"
            case .interrupted:
                duration = "interrupted"
            case .success, .failure, .unknown:
                duration = run.duration.map { String(format: "%.3fs", $0) } ?? "—"
            }
            return [
                formatDate(run.startedAt),
                run.trigger.rawValue,
                duration,
                run.exitCode.map(String.init) ?? "—",
                outcome.rawValue,
            ]
        }
        printTable(
            headers: ["STARTED", "TRIGGER", "DURATION", "EXIT", "OUTCOME"],
            rows: rows
        )

        for run in runs {
            if let stdout = run.stdoutTail, !stdout.isEmpty {
                print("\nrun \(run.id) stdout tail:")
                print(stdout, terminator: stdout.hasSuffix("\n") ? "" : "\n")
            }
            if let stderr = run.stderrTail, !stderr.isEmpty {
                print("\nrun \(run.id) stderr tail:")
                print(stderr, terminator: stderr.hasSuffix("\n") ? "" : "\n")
            }
        }
    }

    private func interrupted(arguments: [String]) throws {
        let json = try parseJSONOnlyOption(arguments, command: "interrupted")
        let store = try SQLiteRunStore(path: configuredStorePath())
        let currentJobs = jobsByCanonicalID(discoverJobs().jobs, store: store)
        let runs = try store.unfinishedRuns().filter { run in
            let canonicalJobID = (try? store.canonicalJobID(run.jobID)) ?? run.jobID
            return run.observedOutcome(for: currentJobs[canonicalJobID]) == .interrupted
        }

        if json {
            try printJSON(runs.map(InterruptedRecord.init))
            return
        }

        let rows = runs.map { run in
            [
                String(run.id),
                run.jobID,
                formatDate(run.startedAt),
                run.trigger.rawValue,
                run.processID.map(String.init) ?? "—",
                run.bootSessionID ?? "—",
                Outcome.interrupted.rawValue,
            ]
        }
        printTable(
            headers: ["ID", "JOB", "STARTED", "TRIGGER", "PID", "BOOT SESSION", "OUTCOME"],
            rows: rows
        )
    }

    private func recoveryPolicy(arguments: [String]) throws {
        guard let requestedJobID = arguments.first, !requestedJobID.isEmpty,
              !requestedJobID.hasPrefix("-") else {
            throw CLIError.usage(
                "recovery-policy requires <job-id> [alert-only|retry-idempotent ...]"
            )
        }
        let tail = Array(arguments.dropFirst())
        let json: Bool
        let requestedPolicy: RecoveryPolicy?
        switch tail.first {
        case nil:
            json = false
            requestedPolicy = nil
        case "--json":
            guard tail.count == 1 else {
                throw CLIError.usage("recovery-policy accepts only one trailing --json flag")
            }
            json = true
            requestedPolicy = nil
        case "alert-only":
            guard tail.dropFirst().isEmpty || tail.dropFirst().elementsEqual(["--json"]) else {
                throw CLIError.usage("alert-only accepts only the optional --json flag")
            }
            json = tail.count == 2
            requestedPolicy = .alertOnly
        case "retry-idempotent":
            guard tail.count == 5 || tail.count == 6 else {
                throw CLIError.usage(
                    "retry-idempotent requires --task-id <id> --time-zone <iana> [--json]"
                )
            }
            guard tail[1] == "--task-id", !tail[2].isEmpty,
                  tail[3] == "--time-zone", !tail[4].isEmpty else {
                throw CLIError.usage(
                    "retry-idempotent requires --task-id <id> --time-zone <iana> [--json]"
                )
            }
            if tail.count == 6, tail[5] != "--json" {
                throw CLIError.usage("retry-idempotent accepts only the optional --json flag")
            }
            do {
                requestedPolicy = try RecoveryPolicy(taskID: tail[2], timeZone: tail[4])
            } catch {
                throw CLIError.usage(error.localizedDescription)
            }
            json = tail.count == 6
        default:
            throw CLIError.usage(
                "recovery-policy requires alert-only or retry-idempotent with its exact options"
                )
        }
        let store = try SQLiteRunStore(path: configuredStorePath())
        let canonicalJobID = try store.canonicalJobID(requestedJobID)
        let policy: RecoveryPolicy
        if let requestedPolicy {
            do {
                try store.setRecoveryPolicy(jobID: canonicalJobID, policy: requestedPolicy)
            } catch let error as RecoveryStoreError {
                throw CLIError.operation(error.localizedDescription)
            }
            policy = requestedPolicy
        } else {
            guard let currentPolicy = try store.recoveryPolicy(jobID: canonicalJobID) else {
                throw CLIError.operation("Recovery policy requires managed job \(canonicalJobID).")
            }
            policy = currentPolicy
        }

        if json {
            try printJSON(RecoveryPolicyRecord(jobID: canonicalJobID, policy: policy))
            return
        }
        switch policy {
        case .alertOnly:
            print("\(canonicalJobID)\talert-only")
        case .retryIdempotent(let taskID, let timeZone):
            print("\(canonicalJobID)\tretry-idempotent\ttask=\(taskID)\ttime-zone=\(timeZone)")
        }
    }

    private func recoveryAgent(arguments: [String]) throws {
        guard arguments.count <= 1 else {
            throw CLIError.usage("recovery-agent accepts no arguments or exactly one of status, enable, or disable")
        }
        let action = arguments.first ?? "status"
        guard ["status", "enable", "disable"].contains(action) else {
            throw CLIError.usage("recovery-agent accepts no arguments or exactly one of status, enable, or disable")
        }
        let controller = makeRecoveryAgentController()
        let state: RecoveryAgentStatus
        switch action {
        case "enable":
            state = controller.enable()
        case "disable":
            state = controller.disable()
        default:
            state = controller.status()
        }
        switch state {
        case .enabled:
            print("enabled")
        case .disabled:
            print("disabled")
        case .failed(let reason):
            print("failed: \(reason)")
            throw CLIError.operation("could not change the recovery agent")
        }
    }

    private func recover(arguments: [String]) throws {
        let json = try parseJSONOnlyOption(arguments, command: "recover")
        let store = try SQLiteRunStore(path: configuredStorePath())
        let discovery = discoverJobs()
        let unfinishedRuns = try store.unfinishedRuns().sorted {
            if $0.id == $1.id { return $0.startedAt > $1.startedAt }
            return $0.id > $1.id
        }
        var records: [RecoveryRecord] = []
        records.reserveCapacity(unfinishedRuns.count)

        func append(
            run: Run,
            jobID: String,
            status: String,
            policy: RecoveryPolicy? = nil,
            dateKey: String? = nil,
            exitCode: Int32? = nil,
            claimID: String? = nil,
            message: String? = nil
        ) {
            records.append(RecoveryRecord(
                runID: run.id,
                jobID: jobID,
                status: status,
                policy: policy,
                dateKey: dateKey,
                exitCode: exitCode,
                claimID: claimID,
                message: message
            ))
        }

        guard discovery.complete else {
            for run in unfinishedRuns {
                append(
                    run: run,
                    jobID: run.jobID,
                    status: "skipped",
                    message: "current job discovery was incomplete"
                )
            }
            return try finishRecoveryOutput(records: records, json: json)
        }

        var currentJobs: [String: Job] = [:]
        var ambiguousJobIDs = Set<String>()
        for job in discovery.jobs {
            guard let canonicalJobID = try? store.canonicalJobID(job.id) else { continue }
            if currentJobs[canonicalJobID] != nil {
                currentJobs.removeValue(forKey: canonicalJobID)
                ambiguousJobIDs.insert(canonicalJobID)
            } else if !ambiguousJobIDs.contains(canonicalJobID) {
                currentJobs[canonicalJobID] = job
            }
        }

        for run in unfinishedRuns {
            guard let canonicalJobID = try? store.canonicalJobID(run.jobID) else {
                append(
                    run: run,
                    jobID: run.jobID,
                    status: "skipped",
                    message: "run job identity could not be canonicalized"
                )
                continue
            }
            guard !ambiguousJobIDs.contains(canonicalJobID),
                  let currentJob = currentJobs[canonicalJobID],
                  currentJob.managed else {
                append(
                    run: run,
                    jobID: canonicalJobID,
                    status: "skipped",
                    message: "run does not resolve to exactly one current managed job"
                )
                continue
            }
            guard run.observedOutcome(for: currentJob) == .interrupted else {
                continue
            }

            let policy: RecoveryPolicy
            do {
                guard let storedPolicy = try store.recoveryPolicy(jobID: canonicalJobID) else {
                    append(
                        run: run,
                        jobID: canonicalJobID,
                        status: "skipped",
                        message: "managed recovery policy is missing"
                    )
                    continue
                }
                policy = storedPolicy
            } catch {
                append(
                    run: run,
                    jobID: canonicalJobID,
                    status: "skipped",
                    message: "managed recovery policy is malformed"
                )
                continue
            }

            switch policy {
            case .alertOnly:
                append(
                    run: run,
                    jobID: canonicalJobID,
                    status: "reported",
                    policy: policy,
                    message: "alert-only policy does not launch recovery"
                )
                continue
            case .retryIdempotent(let taskID, let timeZone):
                let dateKey: String
                do {
                    dateKey = try RecoveryDate.key(
                        for: run.startedAt,
                        timeZoneIdentifier: timeZone
                    )
                } catch {
                    append(
                        run: run,
                        jobID: canonicalJobID,
                        status: "skipped",
                        policy: policy,
                        message: "recovery date could not be derived"
                    )
                    continue
                }

                guard let claim = try store.claimRecoveryAttempt(
                    jobID: canonicalJobID,
                    taskID: taskID,
                    dateKey: dateKey,
                    interruptedRunID: run.id,
                    claimedAt: Date()
                ) else {
                    append(
                        run: run,
                        jobID: canonicalJobID,
                        status: "duplicate",
                        policy: policy,
                        dateKey: dateKey,
                        message: "recovery attempt was already claimed"
                    )
                    continue
                }

                var invocation = [
                    "run",
                    "--recovery",
                    "--recovery-claim", claim.claimID,
                    "--recovery-task", taskID,
                    "--recovery-date", dateKey,
                    "--label", canonicalJobID,
                ]
                if let argv0 = currentJob.argv0 {
                    invocation.append(contentsOf: ["--argv0", argv0])
                }
                invocation.append("--")
                invocation.append(contentsOf: currentJob.command)
                invocation.append(contentsOf: ["--recovery-date", dateKey])

                let child = launchRecoveryChild(arguments: invocation)
                guard let terminationStatus = child.terminationStatus else {
                    append(
                        run: run,
                        jobID: canonicalJobID,
                        status: "claimed",
                        policy: policy,
                        dateKey: dateKey,
                        claimID: claim.claimID,
                        message: child.launchError ?? "recovery child could not be launched"
                    )
                    continue
                }

                do {
                    guard let currentAttempt = try store.recoveryAttempt(claimID: claim.claimID) else {
                        append(
                            run: run,
                            jobID: canonicalJobID,
                            status: "unknown",
                            policy: policy,
                            dateKey: dateKey,
                            exitCode: terminationStatus,
                            claimID: claim.claimID,
                            message: "recovery attempt disappeared after child exit"
                        )
                        continue
                    }
                    guard currentAttempt.status == .running else {
                        append(
                            run: run,
                            jobID: canonicalJobID,
                            status: currentAttempt.status.rawValue,
                            policy: policy,
                            dateKey: dateKey,
                            exitCode: terminationStatus,
                            claimID: claim.claimID,
                            message: "recovery child rejected the claim before execution"
                        )
                        continue
                    }
                    let terminalStatus: RecoveryAttemptStatus =
                        terminationStatus == 0 ? .succeeded : .failed
                    let terminal = try store.finishRecoveryAttempt(
                        claimID: claim.claimID,
                        jobID: canonicalJobID,
                        taskID: taskID,
                        dateKey: dateKey,
                        status: terminalStatus,
                        finishedAt: Date(),
                        exitCode: terminationStatus
                    )
                    append(
                        run: run,
                        jobID: canonicalJobID,
                        status: terminal.status.rawValue,
                        policy: policy,
                        dateKey: dateKey,
                        exitCode: terminal.exitCode,
                        claimID: claim.claimID
                    )
                } catch {
                    append(
                        run: run,
                        jobID: canonicalJobID,
                        status: "unknown",
                        policy: policy,
                        dateKey: dateKey,
                        exitCode: terminationStatus,
                        claimID: claim.claimID,
                        message: "recovery attempt terminal transition failed"
                    )
                }
            }
        }
        try finishRecoveryOutput(records: records, json: json)
    }

    private func finishRecoveryOutput(records: [RecoveryRecord], json: Bool) throws {
        if json {
            try printJSON(records)
            return
        }
        printTable(
            headers: ["RUN", "JOB", "STATUS", "DATE", "EXIT", "MESSAGE"],
            rows: records.map {
                [
                    String($0.runID),
                    $0.jobID,
                    $0.status,
                    $0.dateKey ?? "—",
                    $0.exitCode.map(String.init) ?? "—",
                    $0.message ?? "—",
                ]
            }
        )
    }

    private func launchRecoveryChild(arguments: [String]) -> RecoveryChildResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: runningExecutablePath())
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return RecoveryChildResult(
                terminationStatus: nil,
                launchError: "recovery child launch failed"
            )
        }
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        process.waitUntilExit()
        _ = outputGroup.wait(timeout: .now() + postExitDrainTimeout)
        return RecoveryChildResult(
            terminationStatus: process.terminationStatus,
            launchError: nil
        )
    }

    private func wrap(arguments: [String]) throws {
        guard arguments.count == 1 else {
            throw CLIError.usage("wrap requires exactly one <job-id>")
        }
        let discovery = discoverJobs()
        let job = try findJob(id: arguments[0], in: discovery.jobs)
        let store = try SQLiteRunStore(path: configuredStorePath())
        let wrapper = JobWrapper(store: store)
        let commands = try wrapper.wrap(job: job, tickerPath: currentExecutablePath())
        print(commands.unload)
        print(commands.load)
    }

    private func unwrap(arguments: [String]) throws {
        guard arguments.count == 1 else {
            throw CLIError.usage("unwrap requires exactly one <job-id>")
        }
        let discovery = discoverJobs()
        let job = try findJob(id: arguments[0], in: discovery.jobs)
        let store = try SQLiteRunStore(path: configuredStorePath())
        let wrapper = JobWrapper(store: store)
        let commands = try wrapper.unwrap(job: job)
        print(commands.unload)
        print(commands.load)
    }

    private func doctor(arguments: [String]) throws {
        let discovery = discoverJobs()
        let discoveredJobs = discovery.jobs
        let store = try SQLiteRunStore(path: configuredStorePath())
        if arguments.count == 2, arguments[0] == "--clear-stale" {
            let job = try findJob(id: arguments[1], in: discoveredJobs)
            let state = try JobWrapper(store: store).recoveryState(job: job)
            guard state == .staleManagedRow else {
                throw CLIError.operation(
                    "Refusing to clear \(job.id): recovery state is \(state.description), not stale-row"
                )
            }
            try store.unmarkManaged(jobID: job.id)
            print("\(job.id)\tunwrapped")
            return
        }
        guard arguments.isEmpty else {
            throw CLIError.usage("doctor accepts no arguments or --clear-stale <job-id>")
        }
        let wrapper = JobWrapper(store: store)
        for job in discoveredJobs.filter({ $0.source == .launchd }).sorted(by: { $0.id < $1.id }) {
            if let attention = job.attention,
               attention.isConfigurationDiagnostic {
                let status = attention.requiresAttention
                    ? "configuration-error\tbroken"
                    : "configuration-info"
                print("\(job.id)\t\(status): \(attention.diagnosticDescription)")
                continue
            }
            do {
                let recovery = try wrapper.recoveryState(job: job).description
                let attention = job.attention.map {
                    "\tbroken: \($0.diagnosticDescription)"
                } ?? ""
                if job.runtimeStatusAttribution == .ambiguous {
                    print("\(job.id)\t\(recovery)\tambiguous-runtime\(attention)")
                    if let explanation = job.runtimeStatusExplanation {
                        print("\t\(explanation)")
                    }
                } else {
                    print("\(job.id)\t\(recovery)\(attention)")
                }
            } catch {
                print("\(job.id)\terror: \(error.localizedDescription)")
            }
        }
        for diagnostic in try store.recorderDiagnostics() {
            print("recorder-diagnostic\t\(diagnostic.claimedJobID)\t\(diagnostic.message)")
        }
    }

    private func discoverJobs() -> (jobs: [Job], complete: Bool) {
        let discovery = JobRegistry.standard().discoverAll()
        for error in discovery.errors {
            writeStandardError("ticker: discovery warning: \(error.localizedDescription)\n")
        }
        #if TICKER_TESTING
        let jobs = discovery.jobs.map(testingRuntimeJob)
        #else
        let jobs = discovery.jobs
        #endif
        return (jobs, discovery.errors.isEmpty)
    }

    #if TICKER_TESTING
    private func testingRuntimeJob(_ job: Job) -> Job {
        guard job.source == .launchd,
              let domain = job.launchdDomain else {
            return job
        }
        let target = domain == .userAgent
            ? "gui/\(geteuid())/\(job.label)"
            : "system/\(job.label)"
        let result = runRecoveryLaunchctl(["print", target])
        guard result.status == 0 else {
            return job
        }
        let snapshot = LaunchdRuntimeSnapshot.parse(result.stdout)
        let attribution: RuntimeStatusAttribution?
        if snapshot.lastExitStatus != nil {
            attribution = .resolved
        } else if snapshot.processID != nil || snapshot.runCount != nil {
            attribution = .recordWithoutExit
        } else {
            attribution = job.runtimeStatusAttribution
        }
        return Job(
            id: job.id,
            source: job.source,
            provenance: job.provenance,
            attention: job.attention,
            label: job.label,
            schedule: job.schedule,
            command: job.command,
            argv0: job.argv0,
            environment: job.environment,
            cwd: job.cwd,
            enabled: job.enabled,
            launchdDomain: job.launchdDomain,
            launchdUserName: job.launchdUserName,
            launchdGroupName: job.launchdGroupName,
            runNowUnavailableReason: job.runNowUnavailableReason,
            runtimeStatusAttribution: attribution,
            configPath: job.configPath,
            lastKnownExit: snapshot.lastExitStatus ?? job.lastKnownExit,
            nativeStatusObservedAt: snapshot.lastExitStatus == nil
                ? job.nativeStatusObservedAt
                : Date(),
            launchdProcessID: snapshot.processID ?? job.launchdProcessID,
            launchdRunCount: snapshot.runCount ?? job.launchdRunCount,
            lastRunAt: job.lastRunAt,
            lastScheduledFor: job.lastScheduledFor,
            managed: job.managed
        )
    }
    #endif


    private func jobsByCanonicalID(
        _ jobs: [Job],
        store: SQLiteRunStore
    ) -> [String: Job] {
        var result: [String: Job] = [:]
        result.reserveCapacity(jobs.count)
        for job in jobs {
            guard let canonicalJobID = try? store.canonicalJobID(job.id) else {
                continue
            }
            result[canonicalJobID] = job
        }
        return result
    }

    private func findJob(id: String, in jobs: [Job]) throws -> Job {
        guard let job = jobs.first(where: { $0.id == id }) else {
            throw CLIError.operation("No discovered job has id '\(id)'")
        }
        return job
    }

    private func parseJSONOnlyOption(_ arguments: [String], command: String) throws -> Bool {
        if arguments.isEmpty {
            return false
        }
        if arguments == ["--json"] {
            return true
        }
        throw CLIError.usage("\(command) accepts only the optional --json flag")
    }

    private func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }


    private func currentExecutablePath() -> String {
        if let resolved = resolveExecutable(
            CommandLine.arguments[0],
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: FileManager.default.currentDirectoryPath
        ) {
            return resolved
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(CommandLine.arguments[0])
            .standardizedFileURL.path
    }

    static let help = """
        Ticker tracks scheduled jobs on this Mac.

        Usage:
          ticker run --label <id> [--manual] [--ticker-wrapper-version VERSION] [--argv0 VALUE] [--tail-bytes N] -- <argv>...
          ticker list [--json]
          ticker history <job-id> [--limit N] [--json]
          ticker interrupted [--json]
          ticker recovery-policy <job-id> [--json]
          ticker recovery-policy <job-id> alert-only [--json]
          ticker recovery-policy <job-id> retry-idempotent --task-id <id> --time-zone <iana> [--json]
          ticker recovery-agent [status|enable|disable]
          ticker recover [--json]
          ticker wrap <job-id>
          ticker unwrap <job-id>
          ticker doctor [--clear-stale <job-id>]
          ticker --help
          ticker --version

        Recovery runs are internal and require an exact recovery claim, task,
        date, label, and discovered child command.
        --manual records a Run Now invocation without changing scheduled health.
        --argv0 preserves a launchd job's original process name when it differs
        from the executable. --tail-bytes is clamped to 1,048,576 bytes.

        wrap and unwrap rewrite a launchd plist but do not reload it. They print
        the exact launchctl unload and load commands to run next.
        """
}

private struct POSIXProcessError: Error, LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

private func configuredStorePath(scheduledWrapperInvocation: Bool = false) -> String {
    #if TICKER_TESTING
    let compiledDefaultPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("ticker-compiled-test-default", isDirectory: true)
        .appendingPathComponent("ticker-\(getppid()).db", isDirectory: false)
        .path
    #else
    let compiledDefaultPath = SQLiteRunStore.defaultPath()
    #endif
    return RunStorePathPolicy.configuredPath(
        environment: ProcessInfo.processInfo.environment,
        scheduledWrapperInvocation: scheduledWrapperInvocation,
        defaultPath: compiledDefaultPath
    )
}

private func scheduledLaunchctlURL() -> URL {
    #if TICKER_TESTING
    if let path = ProcessInfo.processInfo.environment["TICKER_TEST_LAUNCHCTL_PATH"],
       !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    #endif
    return URL(fileURLWithPath: "/bin/launchctl")
}

private func spawnChild(
    executablePath: String,
    arguments: [String],
    originalArgv0: String?,
    environment: [String: String],
    currentDirectory: String?,
    stdoutPipe: Pipe,
    stderrPipe: Pipe
) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    var code = posix_spawn_file_actions_init(&fileActions)
    guard code == 0 else {
        throw POSIXProcessError(operation: "posix_spawn_file_actions_init", code: code)
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    code = posix_spawnattr_init(&attributes)
    guard code == 0 else {
        throw POSIXProcessError(operation: "posix_spawnattr_init", code: code)
    }
    defer { posix_spawnattr_destroy(&attributes) }

    func requireSuccess(_ result: Int32, _ operation: String) throws {
        guard result == 0 else {
            throw POSIXProcessError(operation: operation, code: result)
        }
    }

    let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
    let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
    let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
    let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor
    if let currentDirectory {
        try currentDirectory.withCString { path in
            try requireSuccess(
                posix_spawn_file_actions_addchdir_np(&fileActions, path),
                "posix_spawn_file_actions_addchdir_np"
            )
        }
    }
    try requireSuccess(
        posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO),
        "posix_spawn_file_actions_adddup2(stdout)"
    )
    try requireSuccess(
        posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO),
        "posix_spawn_file_actions_adddup2(stderr)"
    )
    try requireSuccess(
        posix_spawn_file_actions_addclose(&fileActions, stdoutRead),
        "posix_spawn_file_actions_addclose(stdout read)"
    )
    try requireSuccess(
        posix_spawn_file_actions_addclose(&fileActions, stderrRead),
        "posix_spawn_file_actions_addclose(stderr read)"
    )
    try requireSuccess(
        posix_spawn_file_actions_addclose(&fileActions, stdoutWrite),
        "posix_spawn_file_actions_addclose(stdout write)"
    )
    try requireSuccess(
        posix_spawn_file_actions_addclose(&fileActions, stderrWrite),
        "posix_spawn_file_actions_addclose(stderr write)"
    )

    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    sigaddset(&defaultSignals, SIGINT)
    sigaddset(&defaultSignals, SIGTERM)
    try requireSuccess(
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
        "posix_spawnattr_setsigdefault"
    )
    try requireSuccess(
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
        ),
        "posix_spawnattr_setflags"
    )
    try requireSuccess(
        posix_spawnattr_setpgroup(&attributes, 0),
        "posix_spawnattr_setpgroup"
    )

    var argvStrings = [originalArgv0 ?? arguments[0]]
    argvStrings.append(contentsOf: arguments.dropFirst())
    var argv = argvStrings.map { strdup($0) }
    argv.append(nil)
    defer {
        for pointer in argv where pointer != nil {
            free(pointer)
        }
    }

    let environmentStrings = environment
        .map { "\($0.key)=\($0.value)" }
        .sorted()
    var environmentPointers: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
    environmentPointers.append(nil)
    defer {
        for pointer in environmentPointers where pointer != nil {
            free(pointer)
        }
    }

    var processIdentifier: pid_t = 0
    code = executablePath.withCString { executable in
        argv.withUnsafeMutableBufferPointer { argvBuffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processIdentifier,
                    executable,
                    &fileActions,
                    &attributes,
                    argvBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
    }
    guard code == 0 else {
        throw POSIXProcessError(operation: "posix_spawn \(executablePath)", code: code)
    }
    return processIdentifier
}

private func waitForChildExitWithoutReaping(_ processIdentifier: pid_t) {
    let exited = DispatchSemaphore(value: 0)
    let source = DispatchSource.makeProcessSource(
        identifier: processIdentifier,
        eventMask: .exit,
        queue: .global(qos: .utility)
    )
    source.setEventHandler {
        exited.signal()
    }
    source.resume()
    exited.wait()
    source.cancel()
}

private func reapChild(_ processIdentifier: pid_t) throws -> Int32 {
    var status: Int32 = 0
    while true {
        let result = Darwin.waitpid(processIdentifier, &status, 0)
        if result == processIdentifier {
            return status
        }
        if result == -1, errno == EINTR {
            continue
        }
        throw POSIXProcessError(operation: "waitpid \(processIdentifier)", code: errno)
    }
}

private func childExitCode(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal != 0 {
        return 128 + signal
    }
    return (status >> 8) & 0xff
}

private func drain(pipe: Pipe, forwarder: OutputForwarder, tail: TailBuffer) {
    while true {
        let data = pipe.fileHandleForReading.availableData
        if data.isEmpty {
            return
        }
        tail.append(data)
        forwarder.forward(data)
    }
}

// sysexits EX_IOERR: the child succeeded, but Ticker could not persist its result.
private let scheduledRunFinalizationFailureExitCode: Int32 = 74

private enum RunFinalizationResult {
    case recorded
    case unavailable
    case failed(Error)

    var failureDescription: String {
        switch self {
        case .recorded:
            return ""
        case .unavailable:
            return "the durable run-start record is unavailable"
        case .failed(let error):
            return error.localizedDescription
        }
    }
}

private func finishRun(
    store: SQLiteRunStore?,
    runID: Int64?,
    exitCode: Int32,
    stdoutTail: String,
    stderrTail: String
) -> RunFinalizationResult {
    guard let store = store, let runID = runID else {
        return .unavailable
    }
    do {
        try store.finishRun(
            id: runID,
            exitCode: exitCode,
            stdoutTail: stdoutTail,
            stderrTail: stderrTail,
            finishedAt: Date()
        )
        return .recorded
    } catch {
        return .failed(error)
    }
}

private func exitCodeAfterFinalization(
    childExitCode: Int32,
    trigger: RunTrigger,
    jobID: String,
    result: RunFinalizationResult
) -> Int32 {
    if case .recorded = result {
        return childExitCode
    }
    if trigger == .manual, case .unavailable = result {
        return childExitCode
    }
    if trigger == .manual {
        writeStandardError(
            "ticker: could not record run finish: \(result.failureDescription)\n"
        )
        return childExitCode
    }
    if childExitCode != 0 {
        writeStandardError(
            "ticker: scheduled durable run-finish failed for \(jobID); "
                + "preserving child exit \(childExitCode): \(result.failureDescription)\n"
        )
        return childExitCode
    }
    writeStandardError(
        "ticker: scheduled durable run-finish failed for \(jobID); child exited 0; "
            + "wrapper exiting \(scheduledRunFinalizationFailureExitCode): "
            + "\(result.failureDescription)\n"
    )
    return scheduledRunFinalizationFailureExitCode
}

private func resolveExecutable(
    _ command: String,
    environment: [String: String],
    currentDirectory: String
) -> String? {
    if command.contains("/") {
        let candidate: String
        if command.hasPrefix("/") {
            candidate = URL(fileURLWithPath: command).standardizedFileURL.path
        } else {
            candidate = URL(fileURLWithPath: currentDirectory)
                .appendingPathComponent(command)
                .standardizedFileURL.path
        }
        return Darwin.access(candidate, X_OK) == 0 ? candidate : nil
    }

    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let base = directory.isEmpty ? currentDirectory : String(directory)
        let candidate = URL(fileURLWithPath: base)
            .appendingPathComponent(command)
            .standardizedFileURL.path
        if Darwin.access(candidate, X_OK) == 0 {
            return candidate
        }
    }
    return nil
}

private func formatDate(_ date: Date) -> String {
    humanDateFormatter.string(from: date)
}

private func printTable(headers: [String], rows: [[String]]) {
    let widths = headers.indices.map { column in
        rows.reduce(headers[column].count) { width, row in
            max(width, row[column].count)
        }
    }

    func formatted(_ row: [String]) -> String {
        return row.indices.map { column in
            row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }

    print(formatted(headers))
    print(formatted(widths.map { String(repeating: "-", count: $0) }))
    for row in rows {
        print(formatted(row))
    }
}

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

private func runningExecutablePath() -> String {
    var capacity = UInt32(PATH_MAX)
    while capacity > 0 {
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        var requiredCapacity = capacity
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &requiredCapacity)
        }
        if status == 0 {
            return String(cString: buffer)
        }
        guard requiredCapacity > capacity else { break }
        capacity = requiredCapacity
    }

    return resolveExecutable(
        CommandLine.arguments[0],
        environment: ProcessInfo.processInfo.environment,
        currentDirectory: FileManager.default.currentDirectoryPath
    ) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(CommandLine.arguments[0])
        .standardizedFileURL.path
}

do {
    try TickerCLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIError {
    writeStandardError("ticker: \(error.message)\n")
    if case .usage = error {
        writeStandardError("Run 'ticker --help' for usage.\n")
        Darwin.exit(2)
    }
    Darwin.exit(1)
} catch {
    writeStandardError("ticker: \(error.localizedDescription)\n")
    Darwin.exit(1)
}

private func runRecoveryLaunchctl(_ arguments: [String]) -> LoginItemCommandResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = scheduledLaunchctlURL()
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    do {
        try process.run()
    } catch {
        return LoginItemCommandResult(status: -1, stderr: "launchctl could not be started")
    }
    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return LoginItemCommandResult(
        status: process.terminationStatus,
        stdout: String(decoding: stdout, as: UTF8.self),
        stderr: String(decoding: stderr, as: UTF8.self)
    )
}

private func makeRecoveryAgentController() -> RecoveryAgentController {
    #if TICKER_TESTING
    let environment = ProcessInfo.processInfo.environment
    let testHome = environment["TICKER_TEST_RECOVERY_AGENT_HOME"]
        ?? environment["TICKER_TEST_LOGIN_ITEM_HOME"]
    let testUID = environment["TICKER_TEST_RECOVERY_AGENT_UID"]
        .flatMap(UInt32.init)
        ?? getuid()
    if let testHome, !testHome.isEmpty {
        return RecoveryAgentController(
            homeDirectory: URL(fileURLWithPath: testHome, isDirectory: true),
            uid: testUID,
            launchctl: { runRecoveryLaunchctl($0) }
        )
    }
    #endif
    return RecoveryAgentController()
}

/// `ticker login-item [status|enable|disable]`
///
/// Shares one implementation with the app's "Open at Login" menu toggle, so the
/// CLI and the GUI can never disagree about whether Ticker starts at login.
private func makeLoginItemController(bundlePath: String) -> LoginItemController {
    #if TICKER_TESTING
    let environment = ProcessInfo.processInfo.environment
    if let testHome = environment["TICKER_TEST_LOGIN_ITEM_HOME"],
       !testHome.isEmpty {
        let testServiceState: LoginItemServiceState
        switch environment["TICKER_TEST_LOGIN_ITEM_SERVICE_STATE"] {
        case "enabled":
            testServiceState = .enabled
        case "requires-approval":
            testServiceState = .requiresApproval
        case "indeterminate":
            testServiceState = .indeterminate
        default:
            testServiceState = .disabled
        }
        return LoginItemController(
            bundlePath: bundlePath,
            homeDirectory: URL(fileURLWithPath: testHome, isDirectory: true),
            launchctl: { arguments in
                if arguments.first == "print" {
                    if environment["TICKER_TEST_LOGIN_ITEM_AGENT_STATE"] == "live" {
                        return LoginItemCommandResult(
                            status: 0,
                            stdout: """
                            gui/\(getuid())/com.suchintan.ticker.login = {
                                state = running
                                program = /Applications/Ticker.app/Contents/MacOS/Ticker
                            }
                            """
                        )
                    }
                    return LoginItemCommandResult(
                        status: 113,
                        stderr: "Could not find service"
                    )
                }
                return LoginItemCommandResult(status: -1, stderr: "unexpected test mutation")
            },
            serviceState: { testServiceState },
            registerService: {},
            unregisterService: {}
        )
    }
    #endif
    return LoginItemController(bundlePath: bundlePath)
}

private func loginItem(arguments: [String]) throws {
    guard arguments.count <= 1 else {
        throw CLIError.usage("login-item accepts no arguments or exactly one of status, enable, or disable")
    }
    let action = arguments.first ?? "status"
    guard ["status", "enable", "disable"].contains(action) else {
        throw CLIError.usage("login-item accepts no arguments or exactly one of status, enable, or disable")
    }

    let controller = makeLoginItemController(
        bundlePath: LoginItemController.bundlePath(
            enclosingHelperExecutableAt: runningExecutablePath()
        )
    )

    let state: LoginItemState
    switch action {
    case "enable":
        state = controller.enable()
    case "disable":
        state = controller.disable()
    default:
        state = controller.state()
    }

    switch state {
    case .enabled(let mechanism):
        print("enabled via \(mechanism.rawValue)")
    case .disabled:
        print("disabled")
    case .requiresApproval:
        print("requires approval — approve Ticker in System Settings › General › Login Items")
    case .notInstalled(let running, let expected):
        print("not installed: running from \(running), expected \(expected)")
        if action != "status" {
            throw CLIError.operation("could not change the login item")
        }
    case .failed(let reason):
        print("failed: \(reason)")
        throw CLIError.operation("could not change the login item")
    }
}
