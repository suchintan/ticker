import AppKit
import Combine
import Foundation
import TickerCore

struct SkipStormSummary: Hashable {
    let count: Int
    let reason: String
    let firstSkipAt: Date
    let lastSkipAt: Date

    var span: TimeInterval {
        max(0, lastSkipAt.timeIntervalSince(firstSkipAt))
    }

    var displayText: String {
        let formattedCount = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return "\(formattedCount) skips over \(Self.formatSpan(span)) — \(reason)"
    }

    static func make(from records: [SkipRecord]) -> SkipStormSummary? {
        guard records.count >= 3 else {
            return nil
        }

        let dates = records.map(\.at)
        guard let first = dates.min(), let last = dates.max() else {
            return nil
        }

        let reasonCounts = Dictionary(grouping: records, by: \.reason).mapValues(\.count)
        let mostCommonReason = reasonCounts.sorted { left, right in
            if left.value == right.value {
                return left.key < right.key
            }
            return left.value > right.value
        }.first?.key ?? "unknown"

        return SkipStormSummary(
            count: records.count,
            reason: mostCommonReason,
            firstSkipAt: first,
            lastSkipAt: last
        )
    }

    private static func formatSpan(_ interval: TimeInterval) -> String {
        let hours = interval / 3_600
        if hours >= 10 {
            return String(format: "%.0fh", hours)
        }
        if hours >= 1 {
            return String(format: "%.1fh", hours)
        }
        return String(format: "%.0fm", interval / 60)
    }
}

@MainActor
final class AppBootstrap: ObservableObject {
    @Published private(set) var model: AppModel?
    @Published private(set) var errorMessage: String?

    private let bootstrapQueue = DispatchQueue(label: "com.suchintan.ticker.bootstrap", qos: .userInitiated)

    init() {
        bootstrapQueue.async { [weak self] in
            guard let bootstrap = self else {
                return
            }
            do {
                let store = try SQLiteRunStore(path: SQLiteRunStore.defaultPath())
                let registry = JobRegistry.standard()
                DispatchQueue.main.async {
                    let model = AppModel(registry: registry, store: store)
                    bootstrap.model = model
                    model.start()
                }
            } catch {
                let message = "Could not open the run-history database: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    bootstrap.errorMessage = message
                }
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let registry: JobRegistry
    let store: SQLiteRunStore

    @Published var jobs: [Job] = []
    @Published var health: [String: Outcome] = [:]
    @Published var lastRefresh: Date = Date()
    @Published var errors: [String] = []
    @Published private(set) var skipStorms: [String: SkipStormSummary] = [:]
    @Published private(set) var runsByJob: [String: [Run]] = [:]
    @Published private(set) var managedJobIDs: Set<String> = []
    @Published private(set) var actionMessages: [String: String] = [:]
    @Published private(set) var busyJobIDs: Set<String> = []

    private let wrapper: JobWrapper
    private let workQueue = DispatchQueue(label: "com.suchintan.ticker.work", qos: .userInitiated)
    private var refreshInProgress = false
    private var runningProcesses: [String: Process] = [:]
    private var refreshTimer: Timer?

    init(registry: JobRegistry, store: SQLiteRunStore) {
        self.registry = registry
        self.store = store
        self.wrapper = JobWrapper(store: store)
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let model = self else {
                return
            }
            DispatchQueue.main.async {
                model.refresh()
            }
        }
    }

    func refresh() {
        guard !refreshInProgress else {
            return
        }
        refreshInProgress = true
        workQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            let discovery = self.registry.discoverAll()
            let rawSkips = self.registry.skips()
            let summaries = rawSkips.reduce(into: [String: SkipStormSummary]()) { result, entry in
                if let summary = SkipStormSummary.make(from: entry.value) {
                    result[entry.key] = summary
                }
            }

            var refreshErrors = discovery.errors.map { $0.localizedDescription }
            var latestHealth: [String: Outcome]?
            var managedIDs: Set<String>?

            do {
                latestHealth = try self.store.health()
            } catch {
                refreshErrors.append("Could not read job health: \(error.localizedDescription)")
            }

            do {
                managedIDs = try self.store.managedJobIDs()
            } catch {
                refreshErrors.append("Could not read wrapped jobs: \(error.localizedDescription)")
            }

            let publishedErrors = refreshErrors
            let publishedHealth = latestHealth
            let publishedManagedIDs = managedIDs
            DispatchQueue.main.async {
                self.jobs = discovery.jobs
                self.skipStorms = summaries
                if let publishedHealth = publishedHealth {
                    self.health = publishedHealth
                }
                if let publishedManagedIDs = publishedManagedIDs {
                    self.managedJobIDs = publishedManagedIDs
                }
                self.errors = publishedErrors
                self.refreshInProgress = false
                self.lastRefresh = Date()
            }
        }
    }

    func outcome(for job: Job) -> Outcome {
        if let storedOutcome = health[job.id] {
            return storedOutcome
        }
        if let exitStatus = job.lastKnownExit {
            return exitStatus.isSuccess ? .success : .failure
        }
        return .unknown
    }

    func isManaged(_ job: Job) -> Bool {
        job.managed || managedJobIDs.contains(job.id)
    }

    func skipStorm(for job: Job) -> SkipStormSummary? {
        skipStorms[job.id]
    }

    func loadRuns(for job: Job) {
        let jobID = job.id
        workQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            do {
                let runs = try self.store.runs(jobID: jobID, limit: 20)
                DispatchQueue.main.async {
                    self.runsByJob[jobID] = runs
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendError("Could not load history for \(job.label): \(error.localizedDescription)")
                }
            }
        }
    }

    func runNow(_ job: Job) {
        guard job.canRunNow else {
            appendError("Cannot run \(job.label): Ticker does not have a faithful command for this job.")
            return
        }

        setBusy(true, for: job.id)
        actionMessages[job.id] = nil

        do {
            guard let tickerPath = resolveTickerCLIPath() else {
                throw TickerAppError.tickerCLINotFound
            }
            let processCommand = [tickerPath, "run", "--label", job.id, "--"] + job.command

            guard let executable = resolveExecutable(processCommand[0]) else {
                throw TickerAppError.executableNotFound(processCommand[0])
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = Array(processCommand.dropFirst())
            process.environment = ProcessInfo.processInfo.environment.merging(job.environment) {
                _, jobValue in jobValue
            }
            if let cwd = job.cwd {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] completedProcess in
                let status = completedProcess.terminationStatus
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }
                    self.runningProcesses[job.id] = nil
                    self.actionMessages[job.id] = "Run finished with exit code \(status)."
                    self.setBusy(false, for: job.id)
                    self.loadRuns(for: job)
                    self.refresh()
                }
            }
            runningProcesses[job.id] = process
            try process.run()
        } catch {
            runningProcesses[job.id] = nil
            appendError("Could not run \(job.label): \(error.localizedDescription)")
            setBusy(false, for: job.id)
        }
    }

    func toggleWrapping(_ job: Job) {
        let currentlyWrapped = isManaged(job)
        setBusy(true, for: job.id)
        actionMessages[job.id] = nil

        workQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            do {
                let commands: ReloadCommands
                let verb: String

                if currentlyWrapped {
                    commands = try self.wrapper.unwrap(job: job)
                    verb = "Restored"
                } else {
                    guard let tickerPath = self.resolveTickerCLIPath() else {
                        throw TickerAppError.tickerCLINotFound
                    }
                    commands = try self.wrapper.wrap(job: job, tickerPath: tickerPath)
                    verb = "Wrapped"
                }

                let managedIDs = try self.store.managedJobIDs()
                let message = "\(verb) the configuration. Reload it with:\n\(commands.unload)\n\(commands.load)"
                DispatchQueue.main.async {
                    self.managedJobIDs = managedIDs
                    self.actionMessages[job.id] = message
                    self.setBusy(false, for: job.id)
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendError("Could not change history wrapping for \(job.label): \(error.localizedDescription)")
                    self.setBusy(false, for: job.id)
                }
            }
        }
    }

    private func setBusy(_ busy: Bool, for jobID: String) {
        if busy {
            busyJobIDs.insert(jobID)
        } else {
            busyJobIDs.remove(jobID)
        }
    }

    private func appendError(_ message: String) {
        if !errors.contains(message) {
            errors.append(message)
        }
    }

    nonisolated private func resolveTickerCLIPath() -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("ticker", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return resolveExecutable("ticker")?.path
    }

    nonisolated private func resolveExecutable(_ command: String) -> URL? {
        if command.contains("/") {
            let expanded = NSString(string: command).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expanded) else {
                return nil
            }
            return URL(fileURLWithPath: expanded)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(command, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

private enum TickerAppError: LocalizedError {
    case executableNotFound(String)
    case tickerCLINotFound

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let command):
            return "Executable not found: \(command)"
        case .tickerCLINotFound:
            return "The ticker CLI was not found in the app bundle or PATH."
        }
    }
}
