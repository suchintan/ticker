import Darwin
import Foundation
import ServiceManagement

/// Controls whether Ticker starts at login.
///
/// `SMAppService` is the supported macOS 13+ mechanism: it appears in System
/// Settings, survives moves, and unregisters cleanly. A verified live LaunchAgent
/// is authoritative only when a fresh ServiceManagement read is disabled.
/// Concurrent, pending, or indeterminate ServiceManagement state is a conflict.
/// Otherwise an enabled `SMAppService` registration wins over dormant fallback
/// configuration. If registration fails for an ad-hoc signed bundle, a plain
/// LaunchAgent is used as the fallback. Whichever mechanism is live, status is
/// always read back from the system rather than from
/// a stored preference, because a preference that
/// disagrees with reality would tell the owner monitoring starts at login when
/// it does not.
public enum LoginItemState: Equatable {
    case enabled(mechanism: LoginItemMechanism)
    case disabled
    /// macOS is waiting for the user to approve Ticker in System Settings.
    case requiresApproval
    /// The running bundle is not the installed copy, so registering it would
    /// bake in a path that a rebuild deletes.
    case notInstalled(running: String, expected: String)
    case failed(String)

    public var isOn: Bool {
        if case .enabled = self { return true }
        return false
    }
}

public enum LoginItemMechanism: String, Equatable {
    case serviceManagement = "System Settings login item"
    case launchAgent = "LaunchAgent"
}

public enum LoginItemServiceState: Equatable {
    case enabled
    case requiresApproval
    case disabled
    /// ServiceManagement returned a status this version of Ticker cannot interpret.
    case indeterminate
}

public struct LoginItemCommandResult: Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

private struct LoginItemOperationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

public struct LoginItemController {
    public static let installedBundlePath = "/Applications/Ticker.app"
    private static let agentLabel = "com.suchintan.ticker.login"
    private static let reconciliationAttemptLimit = 3
    private static let installedExecutablePath = URL(fileURLWithPath: installedBundlePath)
        .appendingPathComponent("Contents/MacOS/Ticker", isDirectory: false).path
    private static let agentProgramArguments = [installedExecutablePath]

    /// Resolves a helper path, including a CLI symlink, to its actual enclosing app bundle.
    ///
    /// A path outside the exact `Contents/Helpers` bundle layout returns the executable
    /// path itself. Mutation guards will then reject it as a noninstalled helper.
    public static func bundlePath(enclosingHelperExecutableAt executablePath: String) -> String {
        let executableURL = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let helpersDirectory = executableURL.deletingLastPathComponent()
        let contentsDirectory = helpersDirectory.deletingLastPathComponent()
        let bundleURL = contentsDirectory.deletingLastPathComponent()
        guard helpersDirectory.lastPathComponent == "Helpers",
              contentsDirectory.lastPathComponent == "Contents",
              bundleURL.pathExtension == "app"
        else {
            return executableURL.path
        }
        return bundleURL.path
    }

    private let fileManager: FileManager
    private let bundlePath: String
    private let agentPlistURL: URL
    private let launchctl: (_ args: [String]) -> LoginItemCommandResult
    private let serviceState: () -> LoginItemServiceState
    private let registerService: () throws -> Void
    private let unregisterService: () throws -> Void

    private enum LaunchAgentTargetState: Equatable {
        case present(LoginItemCommandResult)
        case knownAbsent
        case indeterminate(LoginItemCommandResult)
    }

    private enum AgentPlistEntry: Equatable {
        case absent
        case regularFile
        case symbolicLink
        case unsupported(String)
    }

    public init(
        fileManager: FileManager = .default,
        bundlePath: String = Bundle.main.bundleURL.standardizedFileURL.path,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        launchctl: ((_ args: [String]) -> LoginItemCommandResult)? = nil,
        serviceState: (() -> LoginItemServiceState)? = nil,
        registerService: (() throws -> Void)? = nil,
        unregisterService: (() throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.bundlePath = bundlePath
        self.agentPlistURL = homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.agentLabel).plist", isDirectory: false)
        self.launchctl = launchctl ?? Self.runLaunchctl
        self.serviceState = serviceState ?? Self.currentServiceState
        self.registerService = registerService ?? Self.registerMainService
        self.unregisterService = unregisterService ?? Self.unregisterMainService
    }

    // MARK: - Reading state

    /// Reads live state. Never consults a cached preference.
    public func state() -> LoginItemState {
        var agentFailure: String?
        do {
            try validateAgentPlistIfPresent()
        } catch {
            agentFailure = error.localizedDescription
        }

        for _ in 0..<Self.reconciliationAttemptLimit {
            let initialTargetState = probeAgentTarget()
            let observedServiceState = serviceState()
            let finalTargetState = probeAgentTarget()

            guard initialTargetState == finalTargetState else {
                continue
            }

            switch finalTargetState {
            case .indeterminate(let result):
                return .failed(launchAgentQueryFailure(result))
            case .present(let result):
                if let agentFailure {
                    return .failed(agentFailure)
                }
                do {
                    try verifyAgentIsLive(result)
                } catch {
                    return .failed(error.localizedDescription)
                }
                guard observedServiceState == .disabled else {
                    return .failed(
                        "Login item conflict: LaunchAgent is live while the System Settings "
                            + "login item is \(serviceStateDescription(observedServiceState))."
                    )
                }
                return .enabled(mechanism: .launchAgent)
            case .knownAbsent:
                switch observedServiceState {
                case .enabled:
                    return .enabled(mechanism: .serviceManagement)
                case .requiresApproval:
                    return .requiresApproval
                case .disabled:
                    if let agentFailure {
                        return .failed(agentFailure)
                    }
                    return .disabled
                case .indeterminate:
                    return .failed("System Settings login item status is indeterminate.")
                }
            }
        }

        return .failed(
            "Login item state did not converge after \(Self.reconciliationAttemptLimit) "
                + "paired observation attempts because the exact LaunchAgent target changed "
                + "between reads."
        )
    }

    /// Whether this bundle may register a login item at all.
    public func installationProblem() -> LoginItemState? {
        let running = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let expected = URL(fileURLWithPath: Self.installedBundlePath).standardizedFileURL.path
        guard running != expected else { return nil }
        return .notInstalled(running: running, expected: expected)
    }

    // MARK: - Mutating state

    public func enable() -> LoginItemState {
        if let problem = installationProblem() { return problem }

        let targetState = probeAgentTarget()
        switch targetState {
        case .indeterminate(let result):
            return .failed(launchAgentQueryFailure(result))
        case .present(let result):
            do {
                try validateAgentPlist()
                try verifyAgentIsLive(result)
                return reconcileExistingLaunchAgent()
            } catch {
                // Repair a stale or unverifiable loaded definition through the
                // same reconciled path used by every other fallback activation.
                return establishLaunchAgentFallback()
            }
        case .knownAbsent:
            break
        }

        let initialServiceState = serviceState()
        switch initialServiceState {
        case .enabled, .requiresApproval, .indeterminate:
            // An enabled service wins. A pending or indeterminate registration
            // must be removed and proven disabled before fallback activation.
            return establishLaunchAgentFallback(initialServiceState: initialServiceState)
        case .disabled:
            break
        }

        do {
            if try agentPlistEntry() != .absent {
                // A dormant fallback remains a fallback. Reconcile
                // ServiceManagement before loading it.
                return establishLaunchAgentFallback(initialServiceState: .disabled)
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        var registrationFailure: Error?
        do {
            try registerService()
        } catch {
            registrationFailure = error
        }

        let result = establishLaunchAgentFallback()
        if case .failed(let fallbackFailure) = result, let registrationFailure {
            return .failed(
                "System Settings login item registration failed: "
                    + "\(registrationFailure.localizedDescription) \(fallbackFailure)"
            )
        }
        return result
    }

    public func disable() -> LoginItemState {
        if let problem = installationProblem() { return problem }

        var failures: [String] = []

        // Remove the fallback before ServiceManagement reconciliation starts.
        // The same exact proof runs again before every successful termination.
        do {
            try removeAgentFallbackAndProveAbsence()
        } catch {
            failures.append(
                "LaunchAgent fallback could not be removed: \(error.localizedDescription)"
            )
        }

        var observedServiceState = serviceState()
        for attempt in 1...Self.reconciliationAttemptLimit {
            if observedServiceState != .disabled {
                do {
                    try unregisterService()
                } catch {
                    failures.append(
                        "System Settings login item unregister attempt \(attempt) failed: "
                            + error.localizedDescription
                    )
                }
                observedServiceState = serviceState()
                if observedServiceState != .disabled {
                    continue
                }
            }

            do {
                try removeAgentFallbackAndProveAbsence()
            } catch {
                failures.append(
                    "LaunchAgent final absence check failed on attempt \(attempt): "
                        + error.localizedDescription
                )
            }

            let finalServiceState = serviceState()
            if finalServiceState == .disabled {
                if failures.isEmpty {
                    return .disabled
                }
                return .failed(failures.joined(separator: " "))
            }
            observedServiceState = finalServiceState
        }

        failures.append(
            "Login item disable did not converge after "
                + "\(Self.reconciliationAttemptLimit) reconciliation attempts."
        )

        // Compensate the last observed ServiceManagement transition, then make
        // one bounded final LA+SM absence proof. A new transition after this
        // proof is reported as failure rather than accepted from a stale read.
        if observedServiceState != .disabled {
            do {
                try unregisterService()
            } catch {
                failures.append(
                    "Final System Settings login item compensation failed: "
                        + error.localizedDescription
                )
            }
            observedServiceState = serviceState()
        }

        do {
            try removeAgentFallbackAndProveAbsence()
        } catch {
            failures.append(
                "Final LaunchAgent compensation failed: \(error.localizedDescription)"
            )
        }

        var finalServiceState = serviceState()
        if finalServiceState != .disabled {
            do {
                try unregisterService()
            } catch {
                failures.append(
                    "Final observed System Settings login item compensation failed: "
                        + error.localizedDescription
                )
            }
            let compensatedServiceState = serviceState()
            do {
                try removeAgentFallbackAndProveAbsence()
            } catch {
                failures.append(
                    "Post-ServiceManagement LaunchAgent absence proof failed: "
                        + error.localizedDescription
                )
            }
            finalServiceState = serviceState()
            if compensatedServiceState != .disabled || finalServiceState != .disabled {
                failures.append(
                    "System Settings login item remains "
                        + "\(serviceStateDescription(finalServiceState)) after final compensation."
                )
            }
        } else if observedServiceState != .disabled {
            failures.append(
                "System Settings login item disabled state was not proven before final compensation."
            )
        }
        return .failed(failures.joined(separator: " "))
    }

    /// Keeps an already-live fallback only after ServiceManagement is proven
    /// disabled. If ServiceManagement is already enabled, it wins and the
    /// fallback is removed. Any failed pending-state cleanup removes the
    /// fallback so a later approval cannot create two login launches.
    private func reconcileExistingLaunchAgent() -> LoginItemState {
        let initialServiceState = serviceState()
        switch initialServiceState {
        case .disabled:
            return verifyExistingLaunchAgentOrEstablishFallback()
        case .enabled:
            do {
                try removeAgentFallbackAndProveAbsence()
            } catch {
                return .failed(
                    "System Settings login item is enabled, but the LaunchAgent "
                        + "fallback could not be removed: \(error.localizedDescription)"
                )
            }
            return reconcileServiceAfterAgentRemoval()
        case .requiresApproval, .indeterminate:
            do {
                try proveServiceDisabledForFallback(from: initialServiceState)
                return verifyExistingLaunchAgentOrEstablishFallback()
            } catch {
                let reconciliationError = error
                do {
                    try removeAgentFallbackAndProveAbsence()
                } catch {
                    return .failed(
                        "\(reconciliationError.localizedDescription) The existing "
                            + "LaunchAgent also could not be removed: "
                            + error.localizedDescription
                    )
                }
                return .failed(
                    "\(reconciliationError.localizedDescription) The existing "
                        + "LaunchAgent was removed to prevent duplicate login launches."
                )
            }
        }
    }

    private func verifyExistingLaunchAgentOrEstablishFallback() -> LoginItemState {
        do {
            try validateAgentPlist()
            try verifyAgentIsLive()
            let finalServiceState = serviceState()
            guard finalServiceState == .disabled else {
                return reconcileFallbackAfterActivation(
                    initialServiceState: finalServiceState
                )
            }
            return finishEnableThroughStableObserver(expecting: .launchAgent)
        } catch {
            // The ServiceManagement read happened before this exact probe. A
            // target that disappeared during that read must be re-established.
            return establishLaunchAgentFallback(initialServiceState: .disabled)
        }
    }

    /// Establishes exactly one login mechanism. Both a dormant fallback and a
    /// failed or pending ServiceManagement registration use this path.
    private func establishLaunchAgentFallback(
        initialServiceState: LoginItemServiceState? = nil
    ) -> LoginItemState {
        let initialServiceState = initialServiceState ?? serviceState()
        if initialServiceState == .enabled {
            do {
                try removeAgentFallbackAndProveAbsence()
            } catch {
                return .failed(
                    "System Settings login item is enabled, but the LaunchAgent "
                        + "fallback could not be removed: \(error.localizedDescription)"
                )
            }
            return reconcileServiceAfterAgentRemoval()
        }

        do {
            try proveServiceDisabledForFallback(from: initialServiceState)
        } catch {
            let reconciliationError = error
            do {
                try removeAgentFallbackAndProveAbsence()
            } catch {
                return .failed(
                    "\(reconciliationError.localizedDescription) The LaunchAgent fallback "
                        + "also could not be removed: \(error.localizedDescription)"
                )
            }
            return .failed(
                "\(reconciliationError.localizedDescription) The LaunchAgent fallback was "
                    + "removed to prevent duplicate login launches."
            )
        }

        do {
            try installAgent()
        } catch {
            return .failed(error.localizedDescription)
        }

        return reconcileFallbackAfterActivation()
    }

    /// Reconciles state changes observed after fallback activation. Three
    /// attempts are enough for an enabled service to win, or for a pending
    /// service to be removed before a verified fallback is re-established.
    private func reconcileFallbackAfterActivation(
        initialServiceState: LoginItemServiceState? = nil
    ) -> LoginItemState {
        var observedServiceState = initialServiceState ?? serviceState()
        var transitionFailures: [String] = []

        for attempt in 1...Self.reconciliationAttemptLimit {
            switch observedServiceState {
            case .disabled:
                do {
                    try validateAgentPlist()
                    try verifyAgentIsLive()
                    let finalServiceState = serviceState()
                    if finalServiceState == .disabled {
                        return finishEnableThroughStableObserver(expecting: .launchAgent)
                    }
                    observedServiceState = finalServiceState
                } catch {
                    transitionFailures.append(
                        "LaunchAgent disappeared during reconciliation attempt \(attempt): "
                            + error.localizedDescription
                    )
                    do {
                        try installAgent()
                    } catch {
                        return compensatedEnableFailure(
                            "LaunchAgent fallback could not be re-established after a fresh probe.",
                            priorFailures: transitionFailures + [error.localizedDescription]
                        )
                    }
                    observedServiceState = serviceState()
                }

            case .enabled:
                do {
                    try removeAgentFallbackAndProveAbsence()
                } catch {
                    return compensatedEnableFailure(
                        "System Settings login item became enabled, but LaunchAgent absence "
                            + "could not be proven.",
                        priorFailures: transitionFailures + [error.localizedDescription]
                    )
                }

                observedServiceState = serviceState()
                if observedServiceState == .enabled {
                    return finishEnableThroughStableObserver(expecting: .serviceManagement)
                }
                if observedServiceState != .disabled {
                    continue
                }

                do {
                    try installAgent()
                } catch {
                    return compensatedEnableFailure(
                        "LaunchAgent fallback could not be restored after ServiceManagement changed.",
                        priorFailures: transitionFailures + [error.localizedDescription]
                    )
                }
                observedServiceState = serviceState()

            case .requiresApproval, .indeterminate:
                do {
                    try removeAgentFallbackAndProveAbsence()
                } catch {
                    return compensatedEnableFailure(
                        "A pending or indeterminate System Settings login item was observed "
                            + "after LaunchAgent activation.",
                        priorFailures: transitionFailures + [error.localizedDescription]
                    )
                }

                do {
                    try unregisterService()
                } catch {
                    transitionFailures.append(
                        "System Settings login item unregister attempt \(attempt) failed: "
                            + error.localizedDescription
                    )
                }
                observedServiceState = serviceState()
                if observedServiceState != .disabled {
                    continue
                }

                do {
                    try installAgent()
                } catch {
                    return compensatedEnableFailure(
                        "LaunchAgent fallback could not be restored after pending-state cleanup.",
                        priorFailures: transitionFailures + [error.localizedDescription]
                    )
                }
                observedServiceState = serviceState()
            }
        }

        return compensatedEnableFailure(
            "Login item enable did not converge after "
                + "\(Self.reconciliationAttemptLimit) reconciliation attempts.",
            priorFailures: transitionFailures
        )
    }

    private func compensatedEnableFailure(
        _ reason: String,
        priorFailures: [String] = []
    ) -> LoginItemState {
        var failures = [reason] + priorFailures

        do {
            try removeAgentFallbackAndProveAbsence()
        } catch {
            failures.append(
                "LaunchAgent compensation failed: \(error.localizedDescription)"
            )
        }

        var compensatedServiceState = serviceState()
        if compensatedServiceState != .disabled {
            do {
                try unregisterService()
            } catch {
                failures.append(
                    "System Settings login item compensation failed: "
                        + error.localizedDescription
                )
            }
            compensatedServiceState = serviceState()
        }

        do {
            try removeAgentFallbackAndProveAbsence()
        } catch {
            failures.append(
                "Final LaunchAgent absence proof failed: \(error.localizedDescription)"
            )
        }

        var terminalServiceState = serviceState()
        if terminalServiceState != .disabled {
            do {
                try unregisterService()
            } catch {
                failures.append(
                    "Final observed System Settings login item compensation failed: "
                        + error.localizedDescription
                )
            }
            let terminalReadback = serviceState()
            do {
                try removeAgentFallbackAndProveAbsence()
            } catch {
                failures.append(
                    "Post-ServiceManagement LaunchAgent absence proof failed: "
                        + error.localizedDescription
                )
            }
            terminalServiceState = serviceState()
            if terminalReadback != .disabled {
                compensatedServiceState = terminalReadback
            }
        }

        if compensatedServiceState != .disabled || terminalServiceState != .disabled {
            failures.append(
                "System Settings login item remains "
                    + "\(serviceStateDescription(terminalServiceState)); compensated disabled "
                    + "state was not proven."
            )
        }
        return .failed(failures.joined(separator: " "))
    }

    private func proveServiceDisabledForFallback(
        from initialState: LoginItemServiceState
    ) throws {
        switch initialState {
        case .disabled:
            return
        case .enabled:
            throw LoginItemOperationError(
                message: "System Settings login item is enabled; LaunchAgent fallback was not activated."
            )
        case .requiresApproval, .indeterminate:
            do {
                try unregisterService()
            } catch {
                throw LoginItemOperationError(
                    message: "System Settings login item could not be unregistered before "
                        + "LaunchAgent fallback activation: \(error.localizedDescription)"
                )
            }
        }

        let verifiedState = serviceState()
        guard verifiedState == .disabled else {
            throw LoginItemOperationError(
                message: "System Settings login item is "
                    + "\(serviceStateDescription(verifiedState)); disabled state was not proven "
                    + "before LaunchAgent fallback activation."
            )
        }
    }

    /// Reconciles a fresh ServiceManagement read after the active LaunchAgent
    /// has been removed. Only a freshly enabled service may succeed directly.
    /// Every other state must establish a proven fallback or return a
    /// compensated failure.
    private func reconcileServiceAfterAgentRemoval() -> LoginItemState {
        let freshServiceState = serviceState()
        guard freshServiceState == .enabled else {
            return establishLaunchAgentFallback(initialServiceState: freshServiceState)
        }
        return finishEnableThroughStableObserver(expecting: .serviceManagement)
    }

    /// No enable path may claim success from a one-sided read. The shared
    /// state observer proves one stable LaunchAgent -> ServiceManagement ->
    /// LaunchAgent observation, retrying a changing exact target at most
    /// `reconciliationAttemptLimit` times.
    private func finishEnableThroughStableObserver(
        expecting mechanism: LoginItemMechanism
    ) -> LoginItemState {
        let observedState = state()
        if observedState == .enabled(mechanism: mechanism) {
            return observedState
        }

        let observedDescription: String
        switch observedState {
        case .enabled(let observedMechanism):
            observedDescription = "enabled via \(observedMechanism.rawValue)"
        case .disabled:
            observedDescription = "disabled"
        case .requiresApproval:
            observedDescription = "requiring approval"
        case .notInstalled(let running, let expected):
            observedDescription = "not installed at \(running); expected \(expected)"
        case .failed(let reason):
            observedDescription = "failed: \(reason)"
        }
        return .failed(
            "Login item enable expected \(mechanism.rawValue), but the bounded paired "
                + "LaunchAgent/System Settings observer reached \(observedDescription)."
        )
    }

    private func serviceStateDescription(_ state: LoginItemServiceState) -> String {
        switch state {
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "registered and requiring approval"
        case .disabled:
            return "disabled"
        case .indeterminate:
            return "indeterminate"
        }
    }

    /// Removes the durable fallback and proves that its exact launchd target is
    /// absent. An unconditional post-unlink bootout closes the race where
    /// launchd loads the plist after an earlier absent query.
    private func removeAgentFallbackAndProveAbsence() throws {
        var failures: [String] = []
        var bootoutFailures: [String] = []
        let initialTargetState = probeAgentTarget()

        if case .present = initialTargetState {
            if let failure = agentBootoutFailure(launchctl(["bootout", agentTarget])) {
                bootoutFailures.append(failure)
            }
        } else if case .indeterminate = initialTargetState {
            // The exact query failed, but compensation must still attempt the
            // exact bootout before it removes the durable source.
            if let failure = agentBootoutFailure(launchctl(["bootout", agentTarget])) {
                bootoutFailures.append(failure)
            }
        }

        do {
            try removeAgentPlistIfPresent()
        } catch {
            failures.append(error.localizedDescription)
        }

        // This exact bootout is an ordering barrier. It always runs after the
        // durable source is unlinked, even when the prior print said absent.
        // An exact not-found response proves that no bootout work remains.
        if let failure = agentBootoutFailure(launchctl(["bootout", agentTarget])) {
            bootoutFailures.append(failure)
        }

        let finalTargetState = probeAgentTarget()
        switch finalTargetState {
        case .knownAbsent:
            break
        case .present:
            failures.append(contentsOf: bootoutFailures)
            failures.append("LaunchAgent target \(agentTarget) remains loaded.")
        case .indeterminate(let result):
            failures.append(contentsOf: bootoutFailures)
            failures.append(launchAgentQueryFailure(result, verifyingAbsence: true))
        }

        do {
            if try agentPlistEntry() != .absent {
                failures.append(
                    "LaunchAgent fallback path remains present after removal; "
                        + "it may have been recreated."
                )
            }
        } catch {
            failures.append(
                "LaunchAgent fallback absence could not be verified: \(error.localizedDescription)"
            )
        }

        if !failures.isEmpty {
            throw LoginItemOperationError(message: failures.joined(separator: " "))
        }
    }

    private func agentBootoutFailure(_ result: LoginItemCommandResult) -> String? {
        guard result.status != 0, !isExactBootoutNotFound(result) else {
            return nil
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "LaunchAgent bootout failed with exit status \(result.status)"
            + (detail.isEmpty ? "." : ": \(detail)")
    }

    private func isExactBootoutNotFound(_ result: LoginItemCommandResult) -> Bool {
        isExactAgentNotFound(result)
            || (result.status == 3 && result.stderr.contains("No such process"))
    }

    // MARK: - LaunchAgent fallback

    private var agentTarget: String {
        "gui/\(getuid())/\(Self.agentLabel)"
    }

    private func probeAgentTarget() -> LaunchAgentTargetState {
        let result = launchctl(["print", agentTarget])
        if result.status == 0 {
            return .present(result)
        }
        if isExactAgentNotFound(result) {
            return .knownAbsent
        }
        return .indeterminate(result)
    }

    private func isExactAgentNotFound(_ result: LoginItemCommandResult) -> Bool {
        result.status == 113 && result.stderr.contains("Could not find service")
    }

    private func launchAgentQueryFailure(
        _ result: LoginItemCommandResult,
        verifyingAbsence: Bool = false
    ) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = verifyingAbsence
            ? "LaunchAgent absence could not be verified"
            : "LaunchAgent exact target query failed"
        return "\(operation) with exit status \(result.status)"
            + (detail.isEmpty ? "." : ": \(detail)")
    }

    private func agentPlistEntry() throws -> AgentPlistEntry {
        var information = stat()
        let status = agentPlistURL.path.withCString { path in
            Darwin.lstat(path, &information)
        }
        guard status == 0 else {
            let errorCode = errno
            if errorCode == ENOENT {
                return .absent
            }
            throw LoginItemOperationError(
                message: "LaunchAgent fallback could not be inspected without following links: "
                    + String(cString: strerror(errorCode))
            )
        }

        switch information.st_mode & S_IFMT {
        case S_IFREG:
            return .regularFile
        case S_IFLNK:
            return .symbolicLink
        case S_IFDIR:
            return .unsupported("directory")
        case S_IFSOCK:
            return .unsupported("socket")
        case S_IFIFO:
            return .unsupported("FIFO")
        case S_IFCHR:
            return .unsupported("character device")
        case S_IFBLK:
            return .unsupported("block device")
        default:
            return .unsupported("nonregular entry")
        }
    }

    private func validateAgentPlistIfPresent() throws {
        guard try agentPlistEntry() != .absent else {
            return
        }
        try validateAgentPlist()
    }

    private func validateAgentPlist() throws {
        switch try agentPlistEntry() {
        case .regularFile:
            break
        case .symbolicLink:
            throw LoginItemOperationError(
                message: "LaunchAgent fallback must be a regular file and must not be a symbolic link."
            )
        case .unsupported(let type):
            throw LoginItemOperationError(
                message: "LaunchAgent fallback must be a regular file; found \(type)."
            )
        case .absent:
            throw LoginItemOperationError(
                message: "LaunchAgent fallback disappeared while it was being inspected."
            )
        }

        let propertyList: Any
        do {
            let data = try Data(contentsOf: agentPlistURL)
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw LoginItemOperationError(
                message: "LaunchAgent fallback plist is malformed: \(error.localizedDescription)"
            )
        }

        guard let dictionary = propertyList as? [String: Any] else {
            throw LoginItemOperationError(
                message: "LaunchAgent fallback plist must contain a dictionary."
            )
        }
        guard dictionary["Label"] as? String == Self.agentLabel else {
            throw LoginItemOperationError(
                message: "LaunchAgent fallback plist does not identify exact label \(Self.agentLabel)."
            )
        }
        guard dictionary["Program"] == nil else {
            throw LoginItemOperationError(
                message: "LaunchAgent fallback plist contains an unsupported Program value."
            )
        }
        guard let arguments = dictionary["ProgramArguments"] as? [String],
              arguments == Self.agentProgramArguments
        else {
            throw LoginItemOperationError(
                message: "LaunchAgent fallback plist must contain only exact executable "
                    + "\(Self.installedExecutablePath)."
            )
        }
    }

    private func verifyAgentIsLive() throws {
        switch probeAgentTarget() {
        case .present(let result):
            try verifyAgentIsLive(result)
        case .knownAbsent:
            throw LoginItemOperationError(
                message: "LaunchAgent verification found that exact target \(agentTarget) is absent."
            )
        case .indeterminate(let result):
            throw LoginItemOperationError(message: launchAgentQueryFailure(result))
        }
    }

    private func verifyAgentIsLive(_ result: LoginItemCommandResult) throws {
        let service = try parseAgentPrintOutput(result.stdout)
        guard service.state == "running" else {
            throw LoginItemOperationError(
                message: "LaunchAgent verification did not report exact live state for \(agentTarget)."
            )
        }
        guard !service.executables.isEmpty,
              service.executables.allSatisfy({ $0 == Self.installedExecutablePath })
        else {
            throw LoginItemOperationError(
                message: "LaunchAgent verification did not report exact executable "
                    + "\(Self.installedExecutablePath)."
            )
        }
    }

    private func parseAgentPrintOutput(
        _ output: String
    ) throws -> (state: String, executables: [String]) {
        let lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var lineIndex = 0
        while lineIndex < lines.count,
              lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lineIndex += 1
        }

        let expectedHeader = "\(agentTarget) = {"
        guard lineIndex < lines.count,
              lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines) == expectedHeader
        else {
            throw LoginItemOperationError(
                message: "LaunchAgent verification did not identify exact service \(agentTarget)."
            )
        }
        lineIndex += 1

        var depth = 1
        var states: [String] = []
        var programs: [String] = []
        var executables: [String] = []
        var foundClosingBrace = false

        while lineIndex < lines.count {
            let line = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            lineIndex += 1
            if line.isEmpty { continue }

            if line == "}" {
                depth -= 1
                guard depth >= 0 else { break }
                if depth == 0 {
                    foundClosingBrace = true
                    break
                }
                continue
            }

            if depth == 1 {
                if line.hasPrefix("state = ") {
                    states.append(String(line.dropFirst("state = ".count)))
                } else if line.hasPrefix("program = ") {
                    programs.append(String(line.dropFirst("program = ".count)))
                } else if line.hasPrefix("executable = ") {
                    executables.append(String(line.dropFirst("executable = ".count)))
                }
            }

            if line.hasSuffix(" = {") {
                depth += 1
            }
        }

        let trailingLinesAreEmpty = lines[lineIndex...].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard foundClosingBrace, trailingLinesAreEmpty else {
            throw LoginItemOperationError(
                message: "LaunchAgent verification did not contain a complete exact service block."
            )
        }
        guard states.count == 1 else {
            throw LoginItemOperationError(
                message: "LaunchAgent verification did not report exact live state for \(agentTarget)."
            )
        }
        guard programs.count <= 1,
              executables.count <= 1,
              !programs.isEmpty || !executables.isEmpty
        else {
            throw LoginItemOperationError(
                message: "LaunchAgent verification did not report exact executable "
                    + "\(Self.installedExecutablePath)."
            )
        }
        return (states[0], programs + executables)
    }

    private func installAgent() throws {
        let plist: [String: Any] = [
            "Label": Self.agentLabel,
            "ProgramArguments": Self.agentProgramArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        do {
            // Bootstrap cannot replace an already-loaded same-label service.
            // Use the shared cleanup contract before activation.
            try removeAgentFallbackAndProveAbsence()
            try fileManager.createDirectory(
                at: agentPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: agentPlistURL, options: .atomic)
            let bootstrap = launchctl(["bootstrap", "gui/\(getuid())", agentPlistURL.path])
            guard bootstrap.status == 0 else {
                let detail = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LoginItemOperationError(
                    message: "LaunchAgent bootstrap failed with exit status \(bootstrap.status)"
                        + (detail.isEmpty ? "." : ": \(detail)")
                )
            }
            try validateAgentPlist()
            try verifyAgentIsLive()
        } catch {
            let installError = error
            do {
                try removeAgentFallbackAndProveAbsence()
            } catch {
                throw LoginItemOperationError(
                    message: "\(installError.localizedDescription) "
                        + "Ticker also could not remove the unusable fallback: "
                        + error.localizedDescription
                )
            }
            throw installError
        }
    }

    private func removeAgentPlistIfPresent() throws {
        switch try agentPlistEntry() {
        case .absent:
            return
        case .regularFile, .symbolicLink:
            break
        case .unsupported(let type):
            throw LoginItemOperationError(
                message: "LaunchAgent fallback is a \(type); refusing nonrecursive removal."
            )
        }

        let removalStatus = agentPlistURL.path.withCString { path in
            Darwin.unlink(path)
        }
        if removalStatus != 0, errno != ENOENT {
            let errorCode = errno
            throw LoginItemOperationError(
                message: "LaunchAgent fallback unlink failed: "
                    + String(cString: strerror(errorCode))
            )
        }

        guard try agentPlistEntry() == .absent else {
            throw LoginItemOperationError(
                message: "LaunchAgent fallback was recreated while it was being removed."
            )
        }
    }

    private static func currentServiceState() -> LoginItemServiceState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .indeterminate
        }
    }

    private static func registerMainService() throws {
        try SMAppService.mainApp.register()
    }

    private static func unregisterMainService() throws {
        try SMAppService.mainApp.unregister()
    }

    private static func runLaunchctl(_ args: [String]) -> LoginItemCommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            return LoginItemCommandResult(
                status: process.terminationStatus,
                stdout: String(
                    decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ),
                stderr: String(
                    decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
            )
        } catch {
            return LoginItemCommandResult(status: -1, stderr: error.localizedDescription)
        }
    }
}
