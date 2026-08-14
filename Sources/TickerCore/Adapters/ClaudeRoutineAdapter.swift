import CryptoKit
import Foundation

public struct SkipRecord: Codable, Hashable {
    public let at: Date
    public let reason: String
}

public protocol SkipSourceAdapter {
    func skips() throws -> [String: [SkipRecord]]
}

public final class ClaudeRoutineAdapter: JobSourceAdapter, SkipSourceAdapter {
    public let source: JobSource = .claudeRoutine

    private struct ParsedTask {
        let taskID: String
        let accountDirectoryPath: String
        let job: Job
        let createdAt: Date?
        let snapshotModifiedAt: Date?
        let snapshotPath: String
    }

    private struct TaskKey: Hashable {
        let taskID: String
        let accountDirectoryPath: String
    }

    private struct ScheduledTaskFile {
        let url: URL
        let accountDirectoryPath: String
    }

    private let searchRoots: [URL]

    public convenience init() {
        #if TICKER_TESTING
        if let paths = ProcessInfo.processInfo.environment["TICKER_TEST_CLAUDE_ROOTS"],
           !paths.isEmpty {
            self.init(searchRoots: paths.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
            })
            return
        }
        #endif
        let claude = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        self.init(
            searchRoots: [
                claude.appendingPathComponent("claude-code-sessions", isDirectory: true),
                claude.appendingPathComponent("local-agent-mode-sessions", isDirectory: true),
            ]
        )
    }

    internal init(searchRoots: [URL]) {
        var seenPaths = Set<String>()
        self.searchRoots = searchRoots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seenPaths.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    public func discover() throws -> [Job] {
        let files = scheduledTaskFiles()
        var tasksByKey: [TaskKey: ParsedTask] = [:]

        for snapshot in files {
            guard let root = loadRootDictionary(snapshot.url) else {
                continue
            }
            guard let rawTasks = root["scheduledTasks"] as? [Any] else {
                continue
            }
            let snapshotModifiedAt = try? snapshot.url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let snapshotPath = snapshot.url.standardizedFileURL.resolvingSymlinksInPath().path

            for rawTask in rawTasks {
                guard let dictionary = rawTask as? [String: Any],
                      let task = parseTask(
                          dictionary,
                          accountDirectoryPath: snapshot.accountDirectoryPath,
                          snapshotModifiedAt: snapshotModifiedAt,
                          snapshotPath: snapshotPath
                      )
                else {
                    continue
                }
                let key = TaskKey(taskID: task.taskID, accountDirectoryPath: task.accountDirectoryPath)
                if let existing = tasksByKey[key] {
                    if isMoreRecent(task, than: existing) {
                        tasksByKey[key] = task
                    }
                } else {
                    tasksByKey[key] = task
                }
            }
        }

        return tasksByKey.values.map { task in
            reidentifiedJob(
                task.job,
                id: jobID(
                    taskID: task.taskID,
                    accountDirectoryPath: task.accountDirectoryPath
                )
            )
        }.sorted { $0.id < $1.id }
    }

    public func skips() throws -> [String: [SkipRecord]] {
        let files = scheduledTaskFiles()
        var recordsByJobID: [String: Set<SkipRecord>] = [:]

        for snapshot in files {
            guard let root = loadRootDictionary(snapshot.url),
                  let recordedSkips = root["recordedSkips"] as? [String: Any]
            else {
                continue
            }

            for (taskID, rawRecords) in recordedSkips {
                guard let values = rawRecords as? [Any] else {
                    continue
                }
                let jobID = jobID(
                    taskID: taskID,
                    accountDirectoryPath: snapshot.accountDirectoryPath
                )
                for value in values {
                    guard let dictionary = value as? [String: Any],
                          let milliseconds = milliseconds(dictionary["at"]),
                          let reason = dictionary["reason"] as? String
                    else {
                        continue
                    }
                    recordsByJobID[jobID, default: []].insert(
                        SkipRecord(
                            at: Date(timeIntervalSince1970: milliseconds / 1_000),
                            reason: reason
                        )
                    )
                }
            }
        }

        return recordsByJobID.mapValues { records in
            records.sorted { left, right in
                if left.at == right.at {
                    return left.reason < right.reason
                }
                return left.at < right.at
            }
        }
    }

    private func scheduledTaskFiles() -> [ScheduledTaskFile] {
        var files: [ScheduledTaskFile] = []

        for root in searchRoots {
            let firstLevel = directoryContents(root)
            for accountDirectory in firstLevel where isDirectory(accountDirectory) {
                let accountDirectoryPath = accountDirectory.standardizedFileURL.resolvingSymlinksInPath().path
                let secondLevel = directoryContents(accountDirectory)
                for sessionDirectory in secondLevel where isDirectory(sessionDirectory) {
                    let candidate = sessionDirectory.appendingPathComponent("scheduled-tasks.json")
                    var isDirectoryValue: ObjCBool = false
                    if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectoryValue),
                       !isDirectoryValue.boolValue
                    {
                        files.append(
                            ScheduledTaskFile(
                                url: candidate.standardizedFileURL.resolvingSymlinksInPath(),
                                accountDirectoryPath: accountDirectoryPath
                            )
                        )
                    }
                }
            }
        }

        return files.sorted { $0.url.path < $1.url.path }
    }

    private func directoryContents(_ directory: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            return false
        }
    }

    private func loadRootDictionary(_ file: URL) -> [String: Any]? {
        do {
            let data = try Data(contentsOf: file)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }


    private func parseTask(
        _ dictionary: [String: Any],
        accountDirectoryPath: String,
        snapshotModifiedAt: Date?,
        snapshotPath: String
    ) -> ParsedTask? {
        guard let taskID = dictionary["id"] as? String, !taskID.isEmpty,
              let cronExpression = dictionary["cronExpression"] as? String, !cronExpression.isEmpty,
              let filePath = dictionary["filePath"] as? String, !filePath.isEmpty
        else {
            return nil
        }

        let lastRunAt = parseISO8601(dictionary["lastRunAt"] as? String)
        let lastScheduledFor = parseISO8601(dictionary["lastScheduledFor"] as? String)
        let createdAt = milliseconds(dictionary["createdAt"]).map {
            Date(timeIntervalSince1970: $0 / 1_000)
        }

        return ParsedTask(
            taskID: taskID,
            accountDirectoryPath: accountDirectoryPath,
            job: Job(
                id: "claude:\(taskID)",
                source: .claudeRoutine,
                provenance: .yours,
                label: taskID,
                schedule: .cron(cronExpression),
                command: [],
                cwd: dictionary["cwd"] as? String,
                enabled: (dictionary["enabled"] as? Bool) ?? false,
                configPath: filePath,
                lastKnownExit: nil,
                lastRunAt: lastRunAt,
                lastScheduledFor: lastScheduledFor,
                managed: false
            ),
            createdAt: createdAt,
            snapshotModifiedAt: snapshotModifiedAt,
            snapshotPath: snapshotPath
        )
    }
    private func jobID(
        taskID: String,
        accountDirectoryPath: String
    ) -> String {
        let digest = SHA256.hash(data: Data(accountDirectoryPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "claude:\(taskID)#\(digest.prefix(12))"
    }

    private func reidentifiedJob(_ job: Job, id: String) -> Job {
        Job(
            id: id,
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
            runtimeStatusAttribution: job.runtimeStatusAttribution,
            configPath: job.configPath,
            lastKnownExit: job.lastKnownExit,
            lastRunAt: job.lastRunAt,
            lastScheduledFor: job.lastScheduledFor,
            managed: job.managed
        )
    }


    private func isMoreRecent(_ candidate: ParsedTask, than existing: ParsedTask) -> Bool {
        if let result = compare(candidate.job.lastRunAt, existing.job.lastRunAt) {
            return result
        }
        if let result = compare(candidate.createdAt, existing.createdAt) {
            return result
        }
        if let result = compare(candidate.snapshotModifiedAt, existing.snapshotModifiedAt) {
            return result
        }
        return candidate.snapshotPath > existing.snapshotPath
    }

    private func compare(_ candidate: Date?, _ existing: Date?) -> Bool? {
        guard let candidate, let existing, candidate != existing else {
            return nil
        }
        return candidate > existing
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value = value else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func milliseconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int64 {
            return Double(value)
        }
        return nil
    }
}
