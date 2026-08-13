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
    public static func decode(_ argv: [String]) -> (label: String, original: [String])? {
        guard argv.count >= 5,
              URL(fileURLWithPath: argv[0]).lastPathComponent == "ticker",
              argv[1] == "run",
              argv[2] == "--label",
              argv[4] == "--"
        else {
            return nil
        }
        return (argv[3], Array(argv.dropFirst(5)))
    }
}

public final class LaunchdAdapter: JobSourceAdapter {
    public let source: JobSource = .launchd

    private struct ParsedConfiguration {
        let label: String
        let schedule: Schedule
        let command: [String]
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
            .map(\.standardizedFileURL)
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
        let labelCounts = Dictionary(grouping: configurations, by: \.label).mapValues(\.count)
        let labelsNeedingStatus = Set(configurations.map(\.label)).intersection(loadedLabels)
        var exitStatuses: [String: ExitStatus] = [:]

        for label in labelsNeedingStatus.sorted() {
            guard let status = loadExitStatus(label: label) else {
                continue
            }
            exitStatuses[label] = status
        }

        return configurations.map { configuration in
            let isLoaded = loadedLabels.contains(configuration.label)
            return Job(
                id: jobID(
                    label: configuration.label,
                    configPath: configuration.configPath,
                    hasCollision: labelCounts[configuration.label, default: 0] > 1
                ),
                source: .launchd,
                label: configuration.label,
                schedule: configuration.schedule,
                command: configuration.command,
                environment: configuration.environment,
                cwd: configuration.cwd,
                enabled: isLoaded && !configuration.disabled && !configuration.manuallyDisabled,
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

            let literalCommand: [String]
            if let arguments = dictionary["ProgramArguments"] as? [String], !arguments.isEmpty {
                literalCommand = arguments
            } else if let program = dictionary["Program"] as? String, !program.isEmpty {
                literalCommand = [program]
            } else {
                literalCommand = []
            }
            let decodedWrapper = LaunchdWrapper.decode(literalCommand)

            return ParsedConfiguration(
                label: label,
                schedule: parseSchedule(dictionary),
                command: decodedWrapper?.original ?? literalCommand,
                environment: parseEnvironment(dictionary["EnvironmentVariables"]),
                managed: decodedWrapper != nil,
                cwd: dictionary["WorkingDirectory"] as? String,
                standardOutPath: dictionary["StandardOutPath"] as? String,
                standardErrorPath: dictionary["StandardErrorPath"] as? String,
                runAtLoad: (dictionary["RunAtLoad"] as? Bool) ?? false,
                keepAlive: parseKeepAlive(dictionary["KeepAlive"]),
                disabled: (dictionary["Disabled"] as? Bool) ?? false,
                manuallyDisabled: manuallyDisabled,
                configPath: file.standardizedFileURL.path
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
    private func jobID(label: String, configPath: String, hasCollision: Bool) -> String {
        let base = "launchd:\(label)"
        guard hasCollision else {
            return base
        }

        let digest = SHA256.hash(data: Data(configPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(base)#\(digest.prefix(12))"
    }


    private func commandOutput(_ result: AdapterCommandResult) -> String {
        let output = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
