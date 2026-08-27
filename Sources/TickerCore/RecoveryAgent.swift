import Darwin
import Foundation

/// Live state of the one-shot recovery helper LaunchAgent.
public enum RecoveryAgentStatus: Equatable {
    case enabled
    case disabled
    case failed(String)

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

/// Installs and verifies the LaunchAgent that invokes Ticker recovery once at login.
///
/// This controller deliberately uses launchctl directly. It does not register a
/// ServiceManagement item, and it never treats an ambiguous launchctl response as
/// proof that the helper is absent or loaded.
public struct RecoveryAgentController {
    public static let agentLabel = "com.suchintan.ticker.recover"
    public static let helperExecutablePath = "/Applications/Ticker.app/Contents/Helpers/ticker"
    public static let programArguments = [helperExecutablePath, "recover"]
    public static let stdoutFileName = "recover.stdout.log"
    public static let stderrFileName = "recover.stderr.log"

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let uid: UInt32
    private let launchctl: ([String]) -> LoginItemCommandResult

    private enum TargetState: Equatable {
        case present(LoginItemCommandResult)
        case absent
        case indeterminate(LoginItemCommandResult)
    }

    private enum PlistEntry: Equatable {
        case absent
        case regularFile
        case symbolicLink
        case unsupported(String)
    }

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: UInt32 = getuid(),
        launchctl: (([String]) -> LoginItemCommandResult)? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.uid = uid
        self.launchctl = launchctl ?? Self.runLaunchctl
    }

    public var plistURL: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.agentLabel + ".plist", isDirectory: false)
    }

    public var target: String { "gui/\(uid)/\(Self.agentLabel)" }

    public var standardOutPath: String {
        homeDirectory.appendingPathComponent(".ticker", isDirectory: true)
            .appendingPathComponent(Self.stdoutFileName, isDirectory: false).path
    }

    public var standardErrorPath: String {
        homeDirectory.appendingPathComponent(".ticker", isDirectory: true)
            .appendingPathComponent(Self.stderrFileName, isDirectory: false).path
    }

    public func status() -> RecoveryAgentStatus {
        do {
            try validatePlistIfPresent()
        } catch {
            return .failed(error.localizedDescription)
        }

        switch probeTarget() {
        case .absent:
            return .disabled
        case .indeterminate(let result):
            return .failed(queryFailure(result))
        case .present(let result):
            do {
                try validatePlist()
                try verifyLoadedTarget(result)
                return .enabled
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    public func state() -> RecoveryAgentStatus { status() }

    public func enable() -> RecoveryAgentStatus {
        switch probeTarget() {
        case .indeterminate(let result):
            return .failed(queryFailure(result))
        case .present(let result):
            do {
                try validatePlist()
                try verifyLoadedTarget(result)
                return .enabled
            } catch {
                return .failed(error.localizedDescription)
            }
        case .absent:
            break
        }

        do {
            try installPlist()
            let bootstrap = launchctl(["bootstrap", "gui/\(uid)", plistURL.path])
            guard bootstrap.status == 0 else {
                let detail = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw RecoveryAgentOperationError(
                    message: "Recovery LaunchAgent bootstrap failed with exit status "
                        + "\(bootstrap.status)"
                        + (detail.isEmpty ? "." : ": \(detail)")
                )
            }
            try validatePlist()
            switch probeTarget() {
            case .present(let result):
                try verifyLoadedTarget(result)
                return .enabled
            case .absent:
                throw RecoveryAgentOperationError(
                    message: "Recovery LaunchAgent target \(target) is absent after bootstrap."
                )
            case .indeterminate(let result):
                throw RecoveryAgentOperationError(message: queryFailure(result))
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func install() throws {
        let result = enable()
        guard case .enabled = result else {
            throw RecoveryAgentOperationError(message: failureDescription(result))
        }
    }

    public func disable() -> RecoveryAgentStatus {
        var failures: [String] = []
        let initialState = probeTarget()
        switch initialState {
        case .present:
            let bootout = launchctl(["bootout", target])
            if !isExactNotFound(bootout), bootout.status != 0 {
                failures.append(commandFailure("Recovery LaunchAgent bootout", bootout))
            }
        case .indeterminate(let result):
            failures.append(queryFailure(result))
            let bootout = launchctl(["bootout", target])
            if !isExactNotFound(bootout), bootout.status != 0 {
                failures.append(commandFailure("Recovery LaunchAgent bootout", bootout))
            }
        case .absent:
            break
        }

        do {
            try removePlistIfPresent()
        } catch {
            failures.append(error.localizedDescription)
        }

        // Run the exact bootout after unlinking as an ordering barrier. This
        // prevents a target loaded between the first probe and the unlink from
        // surviving a successful disable operation.
        let finalBootout = launchctl(["bootout", target])
        if !isExactNotFound(finalBootout), finalBootout.status != 0 {
            failures.append(commandFailure("Recovery LaunchAgent final bootout", finalBootout))
        }

        switch probeTarget() {
        case .present:
            failures.append("Recovery LaunchAgent target \(target) remains loaded.")
        case .indeterminate(let result):
            failures.append(queryFailure(result, verifyingAbsence: true))
        case .absent:
            break
        }

        do {
            guard try plistEntry() == .absent else {
                failures.append("Recovery LaunchAgent plist remains present after disable.")
                return .failed(failures.joined(separator: " "))
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        return failures.isEmpty ? .disabled : .failed(failures.joined(separator: " "))
    }

    private func installPlist() throws {
        try createPrivateDirectory(homeDirectory.appendingPathComponent(".ticker", isDirectory: true))
        try createPrivateDirectory(plistURL.deletingLastPathComponent())
        switch try plistEntry() {
        case .absent:
            break
        case .regularFile:
            try validatePlist()
            return
        case .symbolicLink:
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist must be a regular file; refusing a symbolic link."
            )
        case .unsupported(let type):
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist is a \(type); refusing replacement."
            )
        }

        let propertyList: [String: Any] = [
            "Label": Self.agentLabel,
            "ProgramArguments": Self.programArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": standardOutPath,
            "StandardErrorPath": standardErrorPath,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        let temporaryURL = plistURL.deletingLastPathComponent()
            .appendingPathComponent(".\(plistURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: temporaryURL.path
            )
            let renameResult = temporaryURL.path.withCString { source in
                plistURL.path.withCString { destination in
                    Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
                }
            }
            guard renameResult == 0 else {
                throw RecoveryAgentOperationError(
                    message: "exclusive plist install failed: "
                        + String(cString: strerror(errno))
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist could not be written atomically: "
                    + error.localizedDescription
            )
        }
        try validatePlist()
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private func removePlistIfPresent() throws {
        switch try plistEntry() {
        case .absent:
            return
        case .symbolicLink:
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist must be a regular file; refusing a symbolic link."
            )
        case .unsupported(let type):
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist is a \(type); refusing nonregular removal."
            )
        case .regularFile:
            let custodyDirectory = homeDirectory
                .appendingPathComponent(".ticker", isDirectory: true)
                .appendingPathComponent("recovery-agent-custody", isDirectory: true)
            try createPrivateDirectory(custodyDirectory)
            let custodyURL = custodyDirectory.appendingPathComponent(
                "\(plistURL.lastPathComponent).\(UUID().uuidString).released",
                isDirectory: false
            )
            let renameResult = plistURL.path.withCString { source in
                custodyURL.path.withCString { destination in
                    Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
                }
            }
            guard renameResult == 0 else {
                throw RecoveryAgentOperationError(
                    message: "Recovery LaunchAgent plist could not enter removal custody: "
                        + String(cString: strerror(errno))
                )
            }
            do {
                try validatePlist(at: custodyURL)
            } catch {
                let restoreResult = custodyURL.path.withCString { source in
                    plistURL.path.withCString { destination in
                        Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
                    }
                }
                guard restoreResult == 0 else {
                    throw RecoveryAgentOperationError(
                        message: "Recovery LaunchAgent removal refused \(custodyURL.path), "
                            + "but the original plist could not be restored without overwrite: "
                            + String(cString: strerror(errno))
                    )
                }
                throw error
            }
            guard try plistEntry() == .absent else {
                throw RecoveryAgentOperationError(
                    message: "Recovery LaunchAgent plist was recreated while it was being released."
                )
            }
        }
    }

    private func plistEntry() throws -> PlistEntry {
        try plistEntry(at: plistURL)
    }

    private func plistEntry(at url: URL) throws -> PlistEntry {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        guard result == 0 else {
            let errorCode = errno
            if errorCode == ENOENT { return .absent }
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist could not be inspected: "
                    + String(cString: strerror(errorCode))
            )
        }
        switch information.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFLNK: return .symbolicLink
        case S_IFDIR: return .unsupported("directory")
        case S_IFSOCK: return .unsupported("socket")
        case S_IFIFO: return .unsupported("FIFO")
        case S_IFCHR: return .unsupported("character device")
        case S_IFBLK: return .unsupported("block device")
        default: return .unsupported("nonregular entry")
        }
    }

    private func validatePlistIfPresent() throws {
        guard try plistEntry() != .absent else { return }
        try validatePlist()
    }

    private func validatePlist() throws {
        try validatePlist(at: plistURL)
    }

    private func validatePlist(at url: URL) throws {
        guard try plistEntry(at: url) == .regularFile else {
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist must be a regular, owner-controlled file."
            )
        }
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let dictionary = propertyList as? [String: Any] else {
            throw RecoveryAgentOperationError(message: "Recovery LaunchAgent plist must be a dictionary.")
        }
        let expectedKeys: Set<String> = [
            "Label", "ProgramArguments", "RunAtLoad", "KeepAlive",
            "StandardOutPath", "StandardErrorPath",
        ]
        guard Set(dictionary.keys) == expectedKeys,
              dictionary["Label"] as? String == Self.agentLabel,
              dictionary["ProgramArguments"] as? [String] == Self.programArguments,
              dictionary["RunAtLoad"] as? Bool == true,
              dictionary["KeepAlive"] as? Bool == false,
              dictionary["StandardOutPath"] as? String == standardOutPath,
              dictionary["StandardErrorPath"] as? String == standardErrorPath else {
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist does not match the exact helper contract."
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw RecoveryAgentOperationError(
                message: "Recovery LaunchAgent plist must have owner-only permissions."
            )
        }
    }

    private func probeTarget() -> TargetState {
        let result = launchctl(["print", target])
        if result.status == 0 { return .present(result) }
        if isExactNotFound(result) { return .absent }
        return .indeterminate(result)
    }

    private func verifyLoadedTarget(_ result: LoginItemCommandResult) throws {
        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0
        while index < lines.count,
              lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
        guard index < lines.count,
              lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "\(target) = {" else {
            throw RecoveryAgentOperationError(
                message: "launchctl did not identify exact recovery target \(target)."
            )
        }
        index += 1
        var depth = 1
        var programs: [String] = []
        var arguments: [String] = []
        var collectingArguments = false
        var closed = false
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            if line.isEmpty { continue }
            if line == "}" {
                if depth == 2, collectingArguments {
                    collectingArguments = false
                }
                depth -= 1
                if depth == 0 { closed = true; break }
                continue
            }
            if depth == 1 {
                if line.hasPrefix("program = ") {
                    programs.append(String(line.dropFirst("program = ".count)))
                } else if line.hasPrefix("executable = ") {
                    programs.append(String(line.dropFirst("executable = ".count)))
                } else if line == "arguments = {" {
                    collectingArguments = true
                }
            } else if depth == 2, collectingArguments {
                arguments.append(line)
            }
            if line.hasSuffix(" = {") { depth += 1 }
        }
        guard closed,
              lines[index...].allSatisfy({
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              programs == [Self.helperExecutablePath],
              arguments == Self.programArguments else {
            throw RecoveryAgentOperationError(
                message: "launchctl did not verify exact recovery command "
                    + Self.programArguments.joined(separator: " ")
            )
        }
    }

    private func isExactNotFound(_ result: LoginItemCommandResult) -> Bool {
        (result.status == 113 && result.stderr.contains("Could not find service"))
            || (result.status == 3 && result.stderr.contains("No such process"))
    }

    private func queryFailure(_ result: LoginItemCommandResult, verifyingAbsence: Bool = false) -> String {
        let operation = verifyingAbsence
            ? "Recovery LaunchAgent absence could not be verified"
            : "Recovery LaunchAgent exact target query failed"
        return commandFailure(operation, result)
    }

    private func commandFailure(_ operation: String, _ result: LoginItemCommandResult) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(operation) with exit status \(result.status)"
            + (detail.isEmpty ? "." : ": \(detail)")
    }

    private func failureDescription(_ status: RecoveryAgentStatus) -> String {
        switch status {
        case .enabled: return "Recovery LaunchAgent is already enabled."
        case .disabled: return "Recovery LaunchAgent is disabled."
        case .failed(let message): return message
        }
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
                stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        } catch {
            return LoginItemCommandResult(status: -1, stderr: error.localizedDescription)
        }
    }
}

private struct RecoveryAgentOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
