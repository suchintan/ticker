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
    @Published var health: [String: Run] = [:]
    @Published var lastRefresh: Date = Date()
    @Published var errors: [String] = []
    @Published private(set) var skipStorms: [String: SkipStormSummary] = [:]
    @Published private(set) var runsByJob: [String: [Run]] = [:]
    @Published private(set) var recoveryStates: [String: JobRecoveryState] = [:]
    @Published private(set) var recoveryStateErrors: [String: String] = [:]
    @Published private(set) var actionMessages: [String: String] = [:]
    @Published private(set) var busyJobIDs: Set<String> = []

    private let wrapper: JobWrapper
    private let tickerPathOverride: String?
    private let workQueue = DispatchQueue(label: "com.suchintan.ticker.work", qos: .userInitiated)
    private var refreshInProgress = false
    private var refreshPending = false
    private var runningProcesses: [String: Process] = [:]
    private var refreshTimer: Timer?

    init(
        registry: JobRegistry,
        store: SQLiteRunStore,
        wrapper: JobWrapper? = nil,
        tickerPathOverride: String? = nil
    ) {
        self.registry = registry
        self.store = store
        self.wrapper = wrapper ?? JobWrapper(store: store)
        self.tickerPathOverride = tickerPathOverride
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
            refreshPending = true
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

            var latestHealth: [String: Run]?
            var latestRecoveryStates: [String: JobRecoveryState] = [:]
            var latestRecoveryErrors: [String: String] = [:]

            do {
                latestHealth = try self.store.scheduledHealthRuns()
            } catch {
                refreshErrors.append("Could not read job health: \(error.localizedDescription)")
            }
            do {
                refreshErrors += try self.store.recorderDiagnostics().map {
                    "Recorder diagnostic for \($0.claimedJobID): \($0.message)"
                }
            } catch {
                refreshErrors.append("Could not read recorder diagnostics: \(error.localizedDescription)")
            }

            for job in discovery.jobs where job.source == .launchd && job.configPath != nil {
                do {
                    latestRecoveryStates[job.id] = try self.wrapper.recoveryState(job: job)
                } catch {
                    let message = "Could not verify wrapper recovery for \(job.label): \(error.localizedDescription)"
                    latestRecoveryErrors[job.id] = message
                    refreshErrors.append(message)
                }
            }

            let publishedErrors = refreshErrors
            let publishedHealth = latestHealth
            let publishedRecoveryStates = latestRecoveryStates
            let publishedRecoveryErrors = latestRecoveryErrors
            DispatchQueue.main.async {
                self.jobs = discovery.jobs
                self.skipStorms = summaries
                if let publishedHealth = publishedHealth {
                    self.health = publishedHealth
                }
                self.recoveryStates = publishedRecoveryStates
                self.recoveryStateErrors = publishedRecoveryErrors
                self.errors = publishedErrors
                self.refreshInProgress = false
                self.lastRefresh = Date()
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    func outcome(for job: Job) -> Outcome {
        JobHealthPolicy.outcome(
            for: job,
            scheduledHistory: health[job.id]
        )
    }

    func isManaged(_ job: Job) -> Bool {
        switch recoveryStates[job.id] {
        case .wrappedConsistent, .identityChanged, .wrappedMissingBackup,
             .wrappedBackupContentMismatch:
            return true
        case .unwrapped, .wrappedForeignLabel, .ambiguousTickerInvocation, .staleManagedRow, .none:
            return false
        }
    }

    func recoveryState(for job: Job) -> JobRecoveryState? {
        recoveryStates[job.id]
    }

    func recoveryStateError(for job: Job) -> String? {
        recoveryStateErrors[job.id]
    }

    func canToggleWrapping(_ job: Job) -> Bool {
        guard job.source == .launchd, job.configPath != nil,
              recoveryStateErrors[job.id] == nil,
              let state = recoveryStates[job.id]
        else {
            return false
        }
        switch state {
        case .wrappedForeignLabel, .wrappedBackupContentMismatch,
             .ambiguousTickerInvocation:
            return false
        case .unwrapped, .wrappedConsistent, .identityChanged,
             .wrappedMissingBackup, .staleManagedRow:
            return true
        }
    }

    func wrappingButtonTitle(for job: Job) -> String {
        if recoveryStateErrors[job.id] != nil {
            return "Wrapper unavailable"
        }
        switch recoveryStates[job.id] {
        case .unwrapped, .staleManagedRow:
            return "Wrap for history"
        case .wrappedConsistent:
            return "Unwrap for history"
        case .identityChanged:
            return "Reconcile history identity"
        case .wrappedMissingBackup:
            return "Repair history wrapper"
        case .wrappedBackupContentMismatch:
            return "Unsafe backup"
        case .ambiguousTickerInvocation:
            return "Unverified ticker command"
        case .wrappedForeignLabel:
            return "Unsafe wrapper"
        case .none:
            return "Checking wrapper state…"
        }
    }

    func wrappingButtonIcon(for job: Job) -> String {
        switch recoveryStates[job.id] {
        case .wrappedConsistent:
            return "arrow.uturn.backward"
        case .identityChanged:
            return "arrow.triangle.2.circlepath"
        case .wrappedMissingBackup:
            return "wrench.and.screwdriver"
        case .wrappedBackupContentMismatch, .ambiguousTickerInvocation,
             .wrappedForeignLabel:
            return "exclamationmark.triangle"
        case .unwrapped, .staleManagedRow, .none:
            return "clock.arrow.2.circlepath"
        }
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
    func runEnvironment(for job: Job) -> [String: String] {
        SchedulerEnvironment.effectiveEnvironment(for: job)
    }


    func runNow(_ job: Job) {
        guard job.canRunNow else {
            let reason = job.runNowUnavailableReason
                ?? "Ticker does not have a faithful command for this job."
            appendError("Cannot run \(job.label): \(reason)")
            return
        }

        setBusy(true, for: job.id)
        actionMessages[job.id] = nil

        do {
            guard let tickerPath = resolveTickerCLIPath() else {
                throw TickerAppError.tickerCLINotFound
            }
            var processCommand = [tickerPath, "run", "--manual", "--label", job.id]
            if let argv0 = job.argv0 {
                processCommand += ["--argv0", argv0]
            }
            processCommand += ["--"] + job.command

            guard let executable = resolveExecutable(processCommand[0]) else {
                throw TickerAppError.executableNotFound(processCommand[0])
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = Array(processCommand.dropFirst())
            process.environment = runEnvironment(for: job)
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
        guard canToggleWrapping(job), let recoveryState = recoveryStates[job.id] else {
            appendError(
                recoveryStateErrors[job.id]
                    ?? "Could not change history wrapping for \(job.label): wrapper recovery is unsafe or unavailable."
            )
            return
        }

        setBusy(true, for: job.id)
        actionMessages[job.id] = nil

        workQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            do {
                let commands: ReloadCommands
                let verb: String

                switch recoveryState {
                case .wrappedConsistent:
                    commands = try self.wrapper.unwrap(job: job)
                    verb = "Restored"
                case .identityChanged:
                    guard let tickerPath = self.resolveTickerCLIPath() else {
                        throw TickerAppError.tickerCLINotFound
                    }
                    commands = try self.wrapper.reconcileIdentityChange(
                        job: job,
                        tickerPath: tickerPath
                    )
                    verb = "Reconciled"
                case .unwrapped, .staleManagedRow, .wrappedMissingBackup:
                    guard let tickerPath = self.resolveTickerCLIPath() else {
                        throw TickerAppError.tickerCLINotFound
                    }
                    commands = try self.wrapper.wrap(job: job, tickerPath: tickerPath)
                    verb = recoveryState == .wrappedMissingBackup ? "Repaired" : "Wrapped"
                case .wrappedBackupContentMismatch, .ambiguousTickerInvocation,
                     .wrappedForeignLabel:
                    throw TickerAppError.unsafeWrapper
                }

                let message = "\(verb) the configuration. Reload it with:\n\(commands.unload)\n\(commands.load)"
                DispatchQueue.main.async {
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
        if let tickerPathOverride {
            return tickerPathOverride
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
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
    case unsafeWrapper

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let command):
            return "Executable not found: \(command)"
        case .tickerCLINotFound:
            return "The ticker CLI was not found in the app bundle or PATH."
        case .unsafeWrapper:
            return "This plist contains a Ticker wrapper for another job; refusing to modify it."
        }
    }
}
