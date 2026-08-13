import Darwin
import Dispatch
import Foundation
import TickerCore

private let tickerVersion = "0.1.0"
private let defaultTailBytes = 8 * 1_024
private let maxTailBytes = 1_024 * 1_024
private let postExitDrainTimeout = DispatchTimeInterval.seconds(2)
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
    let label: String
    let schedule: String
    let command: [String]
    let environment: [String: String]
    let cwd: String?
    let enabled: Bool
    let configPath: String?
    let lastKnownExit: ExitStatusRecord?
    let lastRunAt: Date?
    let lastScheduledFor: Date?
    let managed: Bool
    let nextFireAt: Date?
    let skew: TimeInterval?
    let lastOutcome: Outcome

    init(job: Job, lastOutcome: Outcome) {
        id = job.id
        source = job.source
        label = job.label
        schedule = job.schedule.humanDescription
        command = job.command
        environment = job.environment
        cwd = job.cwd
        enabled = job.enabled
        configPath = job.configPath
        lastKnownExit = job.lastKnownExit.map(ExitStatusRecord.init)
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
        try container.encode(label, forKey: .label)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(command, forKey: .command)
        try container.encode(environment, forKey: .environment)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(managed, forKey: .managed)
        try container.encode(lastOutcome, forKey: .lastOutcome)
        try encode(cwd, into: &container, forKey: .cwd)
        try encode(configPath, into: &container, forKey: .configPath)
        try encode(lastKnownExit, into: &container, forKey: .lastKnownExit)
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
    let outcome: Outcome
    let stdoutTail: String?
    let stderrTail: String?
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

private final class SignalForwarder {
    private let lock = NSLock()
    private let interruptSource: DispatchSourceSignal
    private let terminateSource: DispatchSourceSignal
    private var processGroupIdentifier: pid_t?
    private var pendingSignals: [Int32] = []
    private var restoreDisposition: () -> Void = {}
    private var stopped = false

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
        guard !stopped else {
            lock.unlock()
            return
        }
        self.processGroupIdentifier = processGroupIdentifier
        let signals = pendingSignals
        pendingSignals.removeAll(keepingCapacity: false)
        lock.unlock()

        for signal in signals {
            Darwin.kill(-processGroupIdentifier, signal)
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        processGroupIdentifier = nil
        pendingSignals.removeAll(keepingCapacity: false)
        lock.unlock()

        interruptSource.cancel()
        terminateSource.cancel()
        restoreDisposition()
    }

    private func forward(_ signal: Int32) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        guard let processGroupIdentifier else {
            pendingSignals.append(signal)
            lock.unlock()
            return
        }
        lock.unlock()
        Darwin.kill(-processGroupIdentifier, signal)
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
        case "wrap":
            try wrap(arguments: remaining)
        case "unwrap":
            try unwrap(arguments: remaining)
        case "doctor":
            try doctor(arguments: remaining)
        default:
            throw CLIError.usage("Unknown command '\(command)'. Run 'ticker --help' for usage.")
        }
    }

    private func runChild(arguments: [String]) throws {
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
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--label":
                guard index + 1 < options.count else {
                    throw CLIError.usage("--label requires a job id")
                }
                label = options[index + 1]
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

        executeChild(
            jobID: jobID,
            arguments: childArguments,
            originalArgv0: originalArgv0,
            tailBytes: tailBytes
        )
    }

    private func executeChild(
        jobID: String,
        arguments: [String],
        originalArgv0: String?,
        tailBytes: Int
    ) -> Never {
        let startedAt = Date()
        var store: SQLiteRunStore?
        var runID: Int64?

        do {
            let openedStore = try SQLiteRunStore(path: configuredStorePath())
            store = openedStore
            do {
                runID = try openedStore.beginRun(jobID: jobID, startedAt: startedAt)
            } catch {
                writeStandardError("ticker: could not record run start: \(error.localizedDescription)\n")
            }
        } catch {
            writeStandardError("ticker: could not open run store: \(error.localizedDescription)\n")
        }

        let stdoutTail = TailBuffer(capacity: tailBytes)
        let stderrTail = TailBuffer(capacity: tailBytes)

        guard let executablePath = resolveExecutable(arguments[0]) else {
            let message = "ticker: could not execute \(arguments[0]): command not found\n"
            let messageData = Data(message.utf8)
            stderrTail.append(messageData)
            FileHandle.standardError.write(messageData)
            finishRun(
                store: store,
                runID: runID,
                exitCode: 127,
                stdoutTail: stdoutTail.string(),
                stderrTail: stderrTail.string()
            )
            Darwin.exit(127)
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
            finishRun(
                store: store,
                runID: runID,
                exitCode: 127,
                stdoutTail: stdoutTail.string(),
                stderrTail: stderrTail.string()
            )
            Darwin.exit(127)
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(
                pipe: stdoutPipe,
                parentHandle: FileHandle.standardOutput,
                tail: stdoutTail
            )
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(
                pipe: stderrPipe,
                parentHandle: FileHandle.standardError,
                tail: stderrTail
            )
            readers.leave()
        }

        let rawStatus: Int32
        do {
            rawStatus = try waitForChild(processIdentifier)
        } catch {
            let messageData = Data("ticker: \(error.localizedDescription)\n".utf8)
            stderrTail.append(messageData)
            FileHandle.standardError.write(messageData)
            rawStatus = 127 << 8
        }
        forwarder.stop()

        if readers.wait(timeout: .now() + postExitDrainTimeout) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + .milliseconds(250))
        }

        let exitCode = childExitCode(rawStatus)
        finishRun(
            store: store,
            runID: runID,
            exitCode: exitCode,
            stdoutTail: stdoutTail.string(),
            stderrTail: stderrTail.string()
        )
        Darwin.exit(exitCode)
    }

    private func list(arguments: [String]) throws {
        let json = try parseJSONOnlyOption(arguments, command: "list")
        let discovery = JobRegistry.standard().discoverAll()
        for error in discovery.errors {
            writeStandardError("ticker: discovery warning: \(error.localizedDescription)\n")
        }

        let store = try SQLiteRunStore(path: configuredStorePath())
        let health = try store.health()
        let records = discovery.jobs.sorted { left, right in
            if left.source.rawValue == right.source.rawValue {
                return left.label.localizedCaseInsensitiveCompare(right.label) == .orderedAscending
            }
            return left.source.rawValue < right.source.rawValue
        }.map { job in
            ListRecord(
                job: job,
                lastOutcome: health[job.id] ?? outcome(from: job.lastKnownExit)
            )
        }

        if json {
            try printJSON(records)
            return
        }

        let rows = records.map { record in
            [
                record.source.rawValue,
                record.enabled ? "on" : "off",
                record.label + (record.managed ? "*" : ""),
                record.schedule,
                record.nextFireAt.map(formatDate) ?? "—",
                record.lastOutcome.rawValue,
            ]
        }
        printTable(headers: ["SOURCE", "STATE", "JOB", "SCHEDULE", "NEXT FIRE", "OUTCOME"], rows: rows)
        print("\n* managed by Ticker")
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
        if json {
            let records = runs.map { run in
                HistoryRecord(
                    id: run.id,
                    jobID: run.jobID,
                    startedAt: run.startedAt,
                    finishedAt: run.finishedAt,
                    duration: run.duration,
                    exitCode: run.exitCode,
                    outcome: run.outcome,
                    stdoutTail: run.stdoutTail,
                    stderrTail: run.stderrTail
                )
            }
            try printJSON(records)
            return
        }

        let rows = runs.map { run in
            [
                formatDate(run.startedAt),
                run.duration.map { String(format: "%.3fs", $0) } ?? "running",
                run.exitCode.map(String.init) ?? "—",
                run.outcome.rawValue,
            ]
        }
        printTable(headers: ["STARTED", "DURATION", "EXIT", "OUTCOME"], rows: rows)

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

    private func wrap(arguments: [String]) throws {
        guard arguments.count == 1 else {
            throw CLIError.usage("wrap requires exactly one <job-id>")
        }
        let job = try findJob(id: arguments[0])
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
        let job = try findJob(id: arguments[0])
        let store = try SQLiteRunStore(path: configuredStorePath())
        let wrapper = JobWrapper(store: store)
        let commands = try wrapper.unwrap(job: job)
        print(commands.unload)
        print(commands.load)
    }

    private func doctor(arguments: [String]) throws {
        let store = try SQLiteRunStore(path: configuredStorePath())
        if arguments.count == 2, arguments[0] == "--clear-stale" {
            let job = try findJob(id: arguments[1])
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

        let discovery = JobRegistry.standard().discoverAll()
        for error in discovery.errors {
            writeStandardError("ticker: discovery warning: \(error.localizedDescription)\n")
        }
        let wrapper = JobWrapper(store: store)
        for job in discovery.jobs.filter({ $0.source == .launchd }).sorted(by: { $0.id < $1.id }) {
            do {
                print("\(job.id)\t\(try wrapper.recoveryState(job: job).description)")
            } catch {
                print("\(job.id)\terror: \(error.localizedDescription)")
            }
        }
    }

    private func findJob(id: String) throws -> Job {
        let discovery = JobRegistry.standard().discoverAll()
        for error in discovery.errors {
            writeStandardError("ticker: discovery warning: \(error.localizedDescription)\n")
        }
        guard let job = discovery.jobs.first(where: { $0.id == id }) else {
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

    private func outcome(from exitStatus: ExitStatus?) -> Outcome {
        guard let exitStatus = exitStatus else {
            return .unknown
        }
        return exitStatus.isSuccess ? .success : .failure
    }

    private func currentExecutablePath() -> String {
        if let resolved = resolveExecutable(CommandLine.arguments[0]) {
            return resolved
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(CommandLine.arguments[0])
            .standardizedFileURL.path
    }

    static let help = """
        Ticker tracks scheduled jobs on this Mac.

        Usage:
          ticker run --label <id> [--argv0 VALUE] [--tail-bytes N] -- <argv>...
          ticker list [--json]
          ticker history <job-id> [--limit N] [--json]
          ticker wrap <job-id>
          ticker unwrap <job-id>
          ticker doctor [--clear-stale <job-id>]
          ticker --help
          ticker --version

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

private func configuredStorePath() -> String {
    ProcessInfo.processInfo.environment["TICKER_STORE_PATH"] ?? SQLiteRunStore.defaultPath()
}

private func spawnChild(
    executablePath: String,
    arguments: [String],
    originalArgv0: String?,
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

    let environmentStrings = ProcessInfo.processInfo.environment
        .map { "\($0.key)=\($0.value)" }
        .sorted()
    var environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
    environment.append(nil)
    defer {
        for pointer in environment where pointer != nil {
            free(pointer)
        }
    }

    var processIdentifier: pid_t = 0
    code = executablePath.withCString { executable in
        argv.withUnsafeMutableBufferPointer { argvBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
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

private func waitForChild(_ processIdentifier: pid_t) throws -> Int32 {
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

private func drain(pipe: Pipe, parentHandle: FileHandle, tail: TailBuffer) {
    while true {
        let data = pipe.fileHandleForReading.availableData
        if data.isEmpty {
            return
        }
        parentHandle.write(data)
        tail.append(data)
    }
}

private func finishRun(
    store: SQLiteRunStore?,
    runID: Int64?,
    exitCode: Int32,
    stdoutTail: String,
    stderrTail: String
) {
    guard let store = store, let runID = runID else {
        return
    }
    do {
        try store.finishRun(
            id: runID,
            exitCode: exitCode,
            stdoutTail: stdoutTail,
            stderrTail: stderrTail,
            finishedAt: Date()
        )
    } catch {
        writeStandardError("ticker: could not record run finish: \(error.localizedDescription)\n")
    }
}

private func resolveExecutable(_ command: String) -> String? {
    if command.contains("/") {
        let candidate: String
        if command.hasPrefix("/") {
            candidate = URL(fileURLWithPath: command).standardizedFileURL.path
        } else {
            candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(command)
                .standardizedFileURL.path
        }
        return Darwin.access(candidate, X_OK) == 0 ? candidate : nil
    }

    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let base = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
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
