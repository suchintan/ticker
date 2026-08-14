import CryptoKit
import Darwin
import Foundation
public enum SchedulerEnvironment {
    public static func cronDefaults() -> [String: String] {
        var environment = currentUserIdentity()
        environment["PATH"] = "/usr/bin:/bin"
        environment["SHELL"] = "/bin/sh"
        return environment
    }

    public static func launchdDefaults() -> [String: String] {
        var environment = currentUserIdentity()
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    public static func effectiveEnvironment(for job: Job) -> [String: String] {
        let base: [String: String]
        switch job.source {
        case .crontab:
            base = cronDefaults()
        case .launchd:
            base = launchdDefaults()
        case .claudeRoutine:
            base = [:]
        }

        // Merge order is scheduler defaults first, then the variables declared by the job.
        // The menu-bar app's environment is deliberately never part of the child environment.
        return base.merging(job.environment) { _, declaredValue in declaredValue }
    }

    private static func currentUserIdentity() -> [String: String] {
        guard let record = getpwuid(getuid()) else {
            return [:]
        }

        let name = String(cString: record.pointee.pw_name)
        let home = String(cString: record.pointee.pw_dir)
        return [
            "HOME": home,
            "LOGNAME": name,
            "USER": name,
        ]
    }
}


public final class CrontabAdapter: JobSourceAdapter {
    public let source: JobSource = .crontab
    public private(set) var environment: [String: String] = [:]

    private let crontabURL: URL
    private let commandRunner: AdapterCommandRunner

    public convenience init() {
        let configuredPath = ProcessInfo.processInfo.environment["TICKER_CRONTAB_PATH"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/bin/crontab"
        self.init(
            crontabURL: URL(fileURLWithPath: configuredPath),
            commandRunner: { try runAdapterCommand(executable: $0, arguments: $1) }
        )
    }

    internal init(
        crontabURL: URL = URL(fileURLWithPath: "/usr/bin/crontab"),
        commandRunner: @escaping AdapterCommandRunner
    ) {
        self.crontabURL = crontabURL
        self.commandRunner = commandRunner
    }

    public func discover() throws -> [Job] {
        let result = try commandRunner(crontabURL, ["-l"])
        if result.status != 0 {
            let output = [result.stdout, result.stderr].joined(separator: "\n")
            if result.status == 1 && output.lowercased().contains("no crontab") {
                environment = [:]
                return []
            }
            throw AdapterCommandError.failed(
                executable: crontabURL.path,
                arguments: ["-l"],
                status: result.status,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var parsedEnvironment: [String: String] = [:]
        let schedulerDefaults = SchedulerEnvironment.cronDefaults()
        var jobs: [Job] = []

        for substring in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(substring).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            if let assignment = parseEnvironmentAssignment(line) {
                parsedEnvironment[assignment.name] = assignment.value
                continue
            }

            guard let entry = parseEntry(line) else {
                continue
            }
            // Merge order is cron's documented defaults first, followed by assignments
            // declared above this entry. A crontab assignment always wins unless it
            // makes HOME empty, which cron replaces with the passwd entry.
            var jobEnvironment = schedulerDefaults.merging(parsedEnvironment) {
                _, declaredValue in declaredValue
            }
            let cwd = nonEmpty(jobEnvironment["HOME"]) ?? nonEmpty(schedulerDefaults["HOME"])
            if let cwd {
                jobEnvironment["HOME"] = cwd
            }
            let shell = nonEmpty(jobEnvironment["SHELL"]) ?? "/bin/sh"
            let identityHash = hashPrefix(
                line: rawLine,
                environment: jobEnvironment,
                cwd: cwd,
                shell: shell
            )
            let identifier = "cron:\(identityHash)"
            jobs.append(
                Job(
                    id: identifier,
                    source: .crontab,
                    provenance: .yours,
                    label: entry.command,
                    schedule: entry.schedule,
                    command: [shell, "-c", entry.command],
                    environment: jobEnvironment,
                    cwd: cwd,
                    enabled: true,
                    configPath: nil,
                    lastKnownExit: nil,
                    lastRunAt: nil,
                    lastScheduledFor: nil,
                    managed: false
                )
            )
        }

        environment = schedulerDefaults.merging(parsedEnvironment) {
            _, declaredValue in declaredValue
        }
        if nonEmpty(environment["HOME"]) == nil, let home = nonEmpty(schedulerDefaults["HOME"]) {
            environment["HOME"] = home
        }
        return jobs
    }

    private func parseEnvironmentAssignment(_ line: String) -> (name: String, value: String)? {
        guard let equals = line.firstIndex(of: "=") else {
            return nil
        }
        let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
        guard isEnvironmentName(name) else {
            return nil
        }
        let rawValue = String(line[line.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)
        return (name, unquotedEnvironmentValue(rawValue))
    }
    private func unquotedEnvironmentValue(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }


    private func isEnvironmentName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private func parseEntry(_ line: String) -> (schedule: Schedule, command: String)? {
        if line.hasPrefix("@") {
            let parts = prefixTokens(in: line, count: 1)
            guard parts.tokens.count == 1, !parts.remainder.isEmpty,
                  let schedule = schedule(for: parts.tokens[0])
            else {
                return nil
            }
            return (schedule, parts.remainder)
        }

        let parts = prefixTokens(in: line, count: 5)
        guard parts.tokens.count == 5, !parts.remainder.isEmpty else {
            return nil
        }
        return (.cron(parts.tokens.joined(separator: " ")), parts.remainder)
    }

    private func schedule(for shortcut: String) -> Schedule? {
        switch shortcut.lowercased() {
        case "@yearly", "@annually":
            return .cron("0 0 1 1 *")
        case "@monthly":
            return .cron("0 0 1 * *")
        case "@weekly":
            return .cron("0 0 * * 0")
        case "@daily", "@midnight":
            return .cron("0 0 * * *")
        case "@hourly":
            return .cron("0 * * * *")
        case "@reboot":
            return .atLoad
        default:
            return nil
        }
    }

    private func prefixTokens(in line: String, count: Int) -> (tokens: [String], remainder: String) {
        var tokens: [String] = []
        var index = line.startIndex

        while tokens.count < count {
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
            guard index < line.endIndex else {
                break
            }

            let start = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            tokens.append(String(line[start..<index]))
        }

        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        return (tokens, String(line[index...]))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func hashPrefix(
        line: String,
        environment: [String: String],
        cwd: String?,
        shell: String
    ) -> String {
        var identity = ""
        appendIdentityField(line, to: &identity)
        for key in environment.keys.sorted() {
            appendIdentityField(key, to: &identity)
            appendIdentityField(environment[key] ?? "", to: &identity)
        }
        appendIdentityField(cwd ?? "", to: &identity)
        appendIdentityField(shell, to: &identity)
        return SHA256.hash(data: Data(identity.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func appendIdentityField(_ value: String, to identity: inout String) {
        identity += "\(value.utf8.count):\(value)"
    }
}
