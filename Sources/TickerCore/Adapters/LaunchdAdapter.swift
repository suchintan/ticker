import CryptoKit
import Foundation
import Dispatch

internal struct AdapterCommandResult {
    internal let status: Int32
    internal let stdout: String
    internal let stderr: String
}

internal typealias AdapterCommandRunner = (URL, [String]) throws -> AdapterCommandResult

private final class AdapterDataBox {
    var data = Data()
}

internal enum AdapterCommandError: LocalizedError {
    case failed(executable: String, arguments: [String], status: Int32, output: String)

    internal var errorDescription: String? {
        switch self {
        case let .failed(executable, arguments, status, output):
            let command = ([executable] + arguments).joined(separator: " ")
            if output.isEmpty {
                return "\(command) exited with status \(status)"
            }
            return "\(command) exited with status \(status): \(output)"
        }
    }
}

internal func runAdapterCommand(executable: URL, arguments: [String]) throws -> AdapterCommandResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()

    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError

    try process.run()

    let outputData = AdapterDataBox()
    let errorData = AdapterDataBox()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
        outputData.data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
        errorData.data = standardError.fileHandleForReading.readDataToEndOfFile()
        readers.leave()
    }

    process.waitUntilExit()
    readers.wait()
    return AdapterCommandResult(
        status: process.terminationStatus,
        stdout: String(decoding: outputData.data, as: UTF8.self),
        stderr: String(decoding: errorData.data, as: UTF8.self)
    )
}

public enum LaunchdWrapper {
    public static let currentVersion = "1"

    public static func decode(
        _ argv: [String]
    ) -> (label: String, original: [String], argv0: String?)? {
        decode(argv, requiresVersionMarker: true)
    }

    public static func decodeLegacy(
        _ argv: [String]
    ) -> (label: String, original: [String], argv0: String?)? {
        decode(argv, requiresVersionMarker: false)
    }

    private static func decode(
        _ argv: [String],
        requiresVersionMarker: Bool
    ) -> (label: String, original: [String], argv0: String?)? {
        guard argv.count >= 5,
              URL(fileURLWithPath: argv[0]).lastPathComponent == "ticker",
              argv[1] == "run"
        else {
            return nil
        }

        var wrapperVersion: String?
        var label: String?
        var originalArgv0: String?
        var index = 2
        while index < argv.count, argv[index] != "--" {
            switch argv[index] {
            case "--ticker-wrapper-version":
                guard requiresVersionMarker,
                      wrapperVersion == nil,
                      index + 1 < argv.count
                else {
                    return nil
                }
                wrapperVersion = argv[index + 1]
                index += 2
            case "--label":
                guard index + 1 < argv.count else {
                    return nil
                }
                label = argv[index + 1]
                index += 2
            case "--argv0":
                guard index + 1 < argv.count else {
                    return nil
                }
                originalArgv0 = argv[index + 1]
                index += 2
            default:
                return nil
            }
        }

        guard (!requiresVersionMarker || wrapperVersion == currentVersion),
              let label,
              index < argv.count,
              argv[index] == "--",
              index + 1 < argv.count
        else {
            return nil
        }
        return (label, Array(argv[(index + 1)...]), originalArgv0)
    }
}

public final class LaunchdAdapter: JobSourceAdapter {
    public let source: JobSource = .launchd

    private struct ParsedConfiguration {
        let label: String
        let schedule: Schedule
        let command: [String]
        let argv0: String?
        let environment: [String: String]
        let managed: Bool
        let cwd: String?
        let standardOutPath: String?
        let standardErrorPath: String?
        let runAtLoad: Bool
        let keepAlive: Bool
        let disabled: Bool
        let manuallyDisabled: Bool
        let configPath: String
    }

    private let searchDirectories: [URL]
    private let launchctlURL: URL
    private let commandRunner: AdapterCommandRunner

    public convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            searchDirectories: [
                home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
            ],
            launchctlURL: URL(fileURLWithPath: "/bin/launchctl"),
            commandRunner: runAdapterCommand
        )
    }

    internal init(
        searchDirectories: [URL],
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        commandRunner: @escaping AdapterCommandRunner
    ) {
        var seenPaths = Set<String>()
        self.searchDirectories = searchDirectories
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seenPaths.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
        self.launchctlURL = launchctlURL
        self.commandRunner = commandRunner
    }

    public func discover() throws -> [Job] {
        let listResult = try commandRunner(launchctlURL, ["list"])
        guard listResult.status == 0 else {
            throw AdapterCommandError.failed(
                executable: launchctlURL.path,
                arguments: ["list"],
                status: listResult.status,
                output: commandOutput(listResult)
            )
        }

        let loadedLabels = parseLoadedLabels(listResult.stdout)
        let configurations = loadConfigurations()
        let duplicateLabels = Set(
            Dictionary(grouping: configurations, by: \.label)
                .filter { $0.value.count > 1 }
                .keys
        )
        let labelsNeedingStatus = Set(configurations.map(\.label))
            .subtracting(duplicateLabels)
            .intersection(loadedLabels)
        var exitStatuses: [String: ExitStatus] = [:]

        for label in labelsNeedingStatus.sorted() {
            guard let status = loadExitStatus(label: label) else {
                continue
            }
            exitStatuses[label] = status
        }

        return configurations.map { configuration in
            let hasAmbiguousRuntimeStatus = duplicateLabels.contains(configuration.label)
            let isLoaded = !hasAmbiguousRuntimeStatus && loadedLabels.contains(configuration.label)
            return Job(
                id: jobID(label: configuration.label, configPath: configuration.configPath),
                source: .launchd,
                label: configuration.label,
                schedule: configuration.schedule,
                command: configuration.command,
                argv0: configuration.argv0,
                environment: configuration.environment,
                cwd: configuration.cwd,
                enabled: isLoaded && !configuration.disabled && !configuration.manuallyDisabled,
                runtimeStatusAttribution: hasAmbiguousRuntimeStatus ? .ambiguous : nil,
                configPath: configuration.configPath,
                lastKnownExit: isLoaded ? exitStatuses[configuration.label] : nil,
                lastRunAt: nil,
                lastScheduledFor: nil,
                managed: configuration.managed
            )
        }
    }

    private func loadConfigurations() -> [ParsedConfiguration] {
        var configurations: [ParsedConfiguration] = []

        for directory in searchDirectories {
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                continue
            }

            for file in files.sorted(by: { $0.path < $1.path }) {
                guard let classification = classify(file: file) else {
                    continue
                }
                guard let configuration = parse(
                    file: file,
                    manuallyDisabled: classification.manuallyDisabled,
                    filenameLabel: classification.label
                ) else {
                    continue
                }
                configurations.append(configuration)
            }
        }

        return configurations
    }

    private func classify(file: URL) -> (manuallyDisabled: Bool, label: String?)? {
        let filename = file.lastPathComponent
        if let marker = filename.range(of: ".plist.disabled-") {
            let suffix = filename[marker.upperBound...]
            guard !suffix.isEmpty else {
                return nil
            }
            return (true, String(filename[..<marker.lowerBound]))
        }
        if filename.hasSuffix(".plist") {
            return (false, nil)
        }
        return nil
    }

    private func parse(
        file: URL,
        manuallyDisabled: Bool,
        filenameLabel: String?
    ) -> ParsedConfiguration? {
        do {
            let data = try Data(contentsOf: file)
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dictionary = propertyList as? [String: Any] else {
                return nil
            }

            let plistLabel = dictionary["Label"] as? String
            guard let label = filenameLabel ?? plistLabel, !label.isEmpty else {
                return nil
            }

            let program = dictionary["Program"] as? String
            let programArguments = dictionary["ProgramArguments"] as? [String]
            let literalCommand: [String]
            let literalArgv0: String?
            if let program, !program.isEmpty {
                if let programArguments, !programArguments.isEmpty {
                    literalCommand = [program] + programArguments.dropFirst()
                    literalArgv0 = programArguments[0] == program ? nil : programArguments[0]
                } else {
                    literalCommand = [program]
                    literalArgv0 = nil
                }
            } else if let programArguments, !programArguments.isEmpty {
                literalCommand = programArguments
                literalArgv0 = nil
            } else {
                literalCommand = []
                literalArgv0 = nil
            }
            let versionedWrapper = LaunchdWrapper.decode(programArguments ?? [])
            let observedWrapper = versionedWrapper
                ?? LaunchdWrapper.decodeLegacy(programArguments ?? [])

            return ParsedConfiguration(
                label: label,
                schedule: parseSchedule(dictionary),
                command: observedWrapper?.original ?? literalCommand,
                argv0: observedWrapper?.argv0 ?? literalArgv0,
                environment: parseEnvironment(dictionary["EnvironmentVariables"]),
                managed: versionedWrapper != nil,
                cwd: dictionary["WorkingDirectory"] as? String,
                standardOutPath: dictionary["StandardOutPath"] as? String,
                standardErrorPath: dictionary["StandardErrorPath"] as? String,
                runAtLoad: (dictionary["RunAtLoad"] as? Bool) ?? false,
                keepAlive: parseKeepAlive(dictionary["KeepAlive"]),
                disabled: (dictionary["Disabled"] as? Bool) ?? false,
                manuallyDisabled: manuallyDisabled,
                configPath: file.standardizedFileURL.resolvingSymlinksInPath().path
            )
        } catch {
            return nil
        }
    }

    private func parseSchedule(_ dictionary: [String: Any]) -> Schedule {
        if let rawCalendar = dictionary["StartCalendarInterval"] {
            let components = parseCalendarComponents(rawCalendar)
            if !components.isEmpty {
                return .calendar(components)
            }
        }

        if let number = dictionary["StartInterval"] as? NSNumber {
            return .interval(number.doubleValue)
        }
        if let interval = dictionary["StartInterval"] as? Double {
            return .interval(interval)
        }
        if let interval = dictionary["StartInterval"] as? Int {
            return .interval(TimeInterval(interval))
        }

        if parseKeepAlive(dictionary["KeepAlive"]) {
            return .keepAlive
        }
        if (dictionary["RunAtLoad"] as? Bool) == true {
            return .atLoad
        }
        let watchPaths = parsePaths(dictionary["WatchPaths"])
        if !watchPaths.isEmpty {
            return .watchPaths(watchPaths)
        }
        let queueDirectories = parsePaths(dictionary["QueueDirectories"])
        if !queueDirectories.isEmpty {
            return .queueDirectories(queueDirectories)
        }

        return .onDemand
    }

    private func parseCalendarComponents(_ value: Any) -> [CalendarComponents] {
        if let dictionary = value as? [String: Any] {
            return [calendarComponents(from: dictionary)]
        }
        if let dictionaries = value as? [[String: Any]] {
            return dictionaries.map(calendarComponents(from:))
        }
        if let values = value as? [Any] {
            return values.compactMap { item in
                guard let dictionary = item as? [String: Any] else {
                    return nil
                }
                return calendarComponents(from: dictionary)
            }
        }
        return []
    }

    private func calendarComponents(from dictionary: [String: Any]) -> CalendarComponents {
        CalendarComponents(
            minute: integer(dictionary["Minute"]),
            hour: integer(dictionary["Hour"]),
            day: integer(dictionary["Day"]),
            weekday: integer(dictionary["Weekday"]),
            month: integer(dictionary["Month"])
        )
    }

    private func parsePaths(_ value: Any?) -> [String] {
        if let path = value as? String, !path.isEmpty {
            return [path]
        }
        guard let values = value as? [Any] else {
            return []
        }
        return values.compactMap { value in
            guard let path = value as? String, !path.isEmpty else {
                return nil
            }
            return path
        }
    }

    private func parseEnvironment(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else {
            return [:]
        }
        return dictionary.reduce(into: [String: String]()) { environment, entry in
            if let value = entry.value as? String {
                environment[entry.key] = value
            }
        }
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func parseKeepAlive(_ value: Any?) -> Bool {
        if let boolean = value as? Bool {
            return boolean
        }
        return value is [String: Any]
    }

    private func parseLoadedLabels(_ output: String) -> Set<String> {
        var labels: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else {
                continue
            }
            let label = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label != "Label" else {
                continue
            }
            labels.insert(label)
        }
        return labels
    }

    private func loadExitStatus(label: String) -> ExitStatus? {
        guard let result = try? commandRunner(launchctlURL, ["list", label]), result.status == 0 else {
            return nil
        }

        for line in result.stdout.split(whereSeparator: \.isNewline) {
            guard line.contains("LastExitStatus"), let equals = line.firstIndex(of: "=") else {
                continue
            }
            let rawValue = line[line.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\t\r\n"))
            guard let raw = Int32(rawValue) else {
                continue
            }
            return ExitStatus(raw: raw)
        }
        return nil
    }
    private func jobID(label: String, configPath: String) -> String {
        let digest = SHA256.hash(data: Data(configPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "launchd:\(label)#\(digest.prefix(12))"
    }


    private func commandOutput(_ result: AdapterCommandResult) -> String {
        let output = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
