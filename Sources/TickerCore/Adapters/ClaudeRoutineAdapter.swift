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
        let job: Job
        let createdAt: Date?
        let snapshotModifiedAt: Date?
        let snapshotPath: String
    }

    private let searchRoots: [URL]

    public convenience init() {
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
        self.searchRoots = searchRoots
    }

    public func discover() throws -> [Job] {
        var tasksByID: [String: ParsedTask] = [:]

        for file in scheduledTaskFiles() {
            guard let root = loadRootDictionary(file) else {
                continue
            }
            guard let rawTasks = root["scheduledTasks"] as? [Any] else {
                continue
            }
            let snapshotModifiedAt = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let snapshotPath = file.standardizedFileURL.path

            for rawTask in rawTasks {
                guard let dictionary = rawTask as? [String: Any],
                      let task = parseTask(
                          dictionary,
                          snapshotModifiedAt: snapshotModifiedAt,
                          snapshotPath: snapshotPath
                      )
                else {
                    continue
                }
                let taskID = task.job.id
                if let existing = tasksByID[taskID] {
                    if isMoreRecent(task, than: existing) {
                        tasksByID[taskID] = task
                    }
                } else {
                    tasksByID[taskID] = task
                }
            }
        }

        return tasksByID.values.map(\.job).sorted { $0.id < $1.id }
    }

    public func skips() throws -> [String: [SkipRecord]] {
        var recordsByJobID: [String: Set<SkipRecord>] = [:]

        for file in scheduledTaskFiles() {
            guard let root = loadRootDictionary(file),
                  let recordedSkips = root["recordedSkips"] as? [String: Any]
            else {
                continue
            }

            for (taskID, rawRecords) in recordedSkips {
                guard let values = rawRecords as? [Any] else {
                    continue
                }
                let jobID = "claude:\(taskID)"
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

    private func scheduledTaskFiles() -> [URL] {
        var files: [URL] = []

        for root in searchRoots {
            let firstLevel = directoryContents(root)
            for accountDirectory in firstLevel where isDirectory(accountDirectory) {
                let secondLevel = directoryContents(accountDirectory)
                for sessionDirectory in secondLevel where isDirectory(sessionDirectory) {
                    let candidate = sessionDirectory.appendingPathComponent("scheduled-tasks.json")
                    var isDirectoryValue: ObjCBool = false
                    if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectoryValue),
                       !isDirectoryValue.boolValue
                    {
                        files.append(candidate)
                    }
                }
            }
        }

        return files.sorted { $0.path < $1.path }
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
            job: Job(
                id: "claude:\(taskID)",
                source: .claudeRoutine,
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
