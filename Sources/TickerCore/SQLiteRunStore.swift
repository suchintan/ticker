import Dispatch
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum RunStorePathPolicy {
    public static func configuredPath(
        environment: [String: String],
        scheduledWrapperInvocation: Bool,
        defaultPath: String
    ) -> String {
        if scheduledWrapperInvocation {
            return defaultPath
        }
        return environment["TICKER_STORE_PATH"] ?? defaultPath
    }
}

public struct SQLiteRunStoreError: Error, LocalizedError {
    public let operation: String
    public let code: Int32
    public let message: String

    public var errorDescription: String? {
        return "SQLite \(operation) failed (code \(code)): \(message)"
    }
}

public struct JobIdentityMigrationReport: Equatable {
    public let performed: Bool
    public let migratedJobIDs: [String: String]
    public let orphanedLegacyJobIDs: [String]

    public init(
        performed: Bool,
        migratedJobIDs: [String: String],
        orphanedLegacyJobIDs: [String]
    ) {
        self.performed = performed
        self.migratedJobIDs = migratedJobIDs
        self.orphanedLegacyJobIDs = orphanedLegacyJobIDs
    }
}

public final class SQLiteRunStore: RunStore {
    private static let schemaVersion = "4"
    private static let jobIdentityMigrationKey = "job_identity_v2"
    private static let runTriggerHealthMigrationKey = "run_trigger_health_v3"

    private let database: OpaquePointer
    private let queue = DispatchQueue(label: "com.ticker.SQLiteRunStore")

    public static func defaultPath() -> String {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ticker", isDirectory: true)
            .appendingPathComponent("ticker.db", isDirectory: false)
            .path
    }

    public convenience init() throws {
        try self.init(path: Self.defaultPath())
    }

    public convenience init(databaseURL: URL) throws {
        try self.init(path: databaseURL.path)
    }

    public convenience init(path: String) throws {
        try self.init(path: path, beforeRunsTriggerMigration: nil)
    }

    internal init(
        path: String,
        beforeRunsTriggerMigration: (() -> Void)?
    ) throws {
        let databaseURL = URL(fileURLWithPath: path)
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SQLiteRunStoreError(
                operation: "create database directory",
                code: -1,
                message: error.localizedDescription
            )
        }

        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &openedDatabase, flags, nil)
        guard openResult == SQLITE_OK, let validDatabase = openedDatabase else {
            let message: String
            if let openedDatabase = openedDatabase {
                message = String(cString: sqlite3_errmsg(openedDatabase))
                sqlite3_close_v2(openedDatabase)
            } else {
                message = "SQLite did not return a database handle"
            }
            throw SQLiteRunStoreError(operation: "open", code: openResult, message: message)
        }

        do {
            try Self.execute(database: validDatabase, sql: "PRAGMA busy_timeout=5000;")
            try Self.execute(database: validDatabase, sql: "PRAGMA journal_mode=WAL;")
            try Self.execute(
                database: validDatabase,
                sql: """
                CREATE TABLE IF NOT EXISTS runs(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  job_id TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL,
                  exit_code INTEGER, stdout_tail TEXT, stderr_tail TEXT,
                  trigger TEXT NOT NULL DEFAULT 'scheduled', process_id INTEGER,
                  boot_session_id TEXT, native_exit_status_at_start INTEGER,
                  launchd_run_count_at_start INTEGER);
                CREATE INDEX IF NOT EXISTS idx_runs_job ON runs(job_id, started_at DESC);
                CREATE TABLE IF NOT EXISTS managed_jobs(
                  job_id TEXT PRIMARY KEY, wrapped_at REAL NOT NULL, backup_path TEXT);
                CREATE TABLE IF NOT EXISTS health_resets(
                  job_id TEXT PRIMARY KEY, reset_after_run_id INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS job_identity_aliases(
                  old_job_id TEXT PRIMARY KEY, new_job_id TEXT NOT NULL,
                  created_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS schema_meta(key TEXT PRIMARY KEY, value TEXT);
                """
            )
            try Self.ensureRunsTriggerColumn(
                database: validDatabase,
                beforeMigration: beforeRunsTriggerMigration
            )
            try Self.ensureRunEvidenceColumns(database: validDatabase)
            try Self.stampSchemaVersion(database: validDatabase)
        } catch {
            sqlite3_close_v2(validDatabase)
            throw error
        }

        database = validDatabase
    }

    deinit {
        queue.sync {
            _ = sqlite3_close_v2(database)
        }
    }

    public func beginRun(
        jobID: String,
        startedAt: Date,
        trigger: RunTrigger,
        context: RunStartContext?
    ) throws -> Int64 {
        return try queue.sync {
            let canonicalID = try canonicalJobIDLocked(jobID)
            let statement = try prepare(
                """
                INSERT INTO runs(
                  job_id, started_at, trigger, process_id, boot_session_id,
                  native_exit_status_at_start, launchd_run_count_at_start
                ) VALUES(?, ?, ?, ?, ?, ?, ?);
                """
            )
            defer { sqlite3_finalize(statement) }

            try bind(canonicalID, to: 1, in: statement)
            try bind(startedAt.timeIntervalSince1970, to: 2, in: statement)
            try bind(trigger.rawValue, to: 3, in: statement)
            if let context {
                try bind(context.processID, to: 4, in: statement)
                try bind(context.bootSessionID, to: 5, in: statement)
                if let nativeExitStatusAtStart = context.nativeExitStatusAtStart {
                    try bind(nativeExitStatusAtStart, to: 6, in: statement)
                } else {
                    try bindNull(to: 6, in: statement)
                }
                if let launchdRunCountAtStart = context.launchdRunCountAtStart {
                    try bind(launchdRunCountAtStart, to: 7, in: statement)
                } else {
                    try bindNull(to: 7, in: statement)
                }
            } else {
                for index in Int32(4)...Int32(7) {
                    try bindNull(to: index, in: statement)
                }
            }
            try stepDone(statement, operation: "insert run")
            return sqlite3_last_insert_rowid(database)
        }
    }

    public func finishRun(
        id: Int64,
        exitCode: Int32,
        stdoutTail: String,
        stderrTail: String,
        finishedAt: Date
    ) throws {
        try queue.sync {
            let statement = try prepare(
                """
                UPDATE runs
                SET finished_at = ?, exit_code = ?, stdout_tail = ?, stderr_tail = ?
                WHERE id = ?;
                """
            )
            defer { sqlite3_finalize(statement) }

            try bind(finishedAt.timeIntervalSince1970, to: 1, in: statement)
            try bind(exitCode, to: 2, in: statement)
            try bind(stdoutTail, to: 3, in: statement)
            try bind(stderrTail, to: 4, in: statement)
            try bind(id, to: 5, in: statement)
            try stepDone(statement, operation: "finish run")

            guard sqlite3_changes(database) == 1 else {
                throw SQLiteRunStoreError(
                    operation: "finish run",
                    code: SQLITE_NOTFOUND,
                    message: "No run exists with id \(id)"
                )
            }
        }
    }

    public func runs(jobID: String, limit: Int) throws -> [Run] {
        return try queue.sync {
            let canonicalID = try canonicalJobIDLocked(jobID)
            let statement = try prepare(
                """
                SELECT id, job_id, started_at, finished_at, exit_code, stdout_tail, stderr_tail,
                       trigger, process_id, boot_session_id, native_exit_status_at_start,
                       launchd_run_count_at_start
                FROM runs
                WHERE job_id = ?
                ORDER BY started_at DESC, id DESC
                LIMIT ?;
                """
            )
            defer { sqlite3_finalize(statement) }

            try bind(canonicalID, to: 1, in: statement)
            try bind(max(0, limit), to: 2, in: statement)
            return try readRuns(statement, operation: "read runs")
        }
    }

    public func latestRun(jobID: String) throws -> Run? {
        return try queue.sync {
            let canonicalID = try canonicalJobIDLocked(jobID)
            let statement = try prepare(
                """
                SELECT id, job_id, started_at, finished_at, exit_code, stdout_tail, stderr_tail,
                       trigger, process_id, boot_session_id, native_exit_status_at_start,
                       launchd_run_count_at_start
                FROM runs
                WHERE job_id = ?
                ORDER BY started_at DESC, id DESC
                LIMIT 1;
                """
            )
            defer { sqlite3_finalize(statement) }

            try bind(canonicalID, to: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                return try decodeRun(statement)
            }
            if result == SQLITE_DONE {
                return nil
            }
            throw databaseError(operation: "read latest run", code: result)
        }
    }

    public func scheduledHealthRuns() throws -> [String: Run] {
        return try queue.sync {
            let statement = try prepare(
                """
                WITH eligible_runs AS (
                  SELECT r.id, r.job_id, r.started_at, r.finished_at, r.exit_code,
                         r.stdout_tail, r.stderr_tail, r.trigger, r.process_id,
                         r.boot_session_id, r.native_exit_status_at_start,
                         r.launchd_run_count_at_start
                  FROM runs AS r
                  LEFT JOIN health_resets AS reset ON reset.job_id = r.job_id
                  WHERE r.trigger = 'scheduled'
                    AND (reset.reset_after_run_id IS NULL OR r.id > reset.reset_after_run_id)
                ),
                ranked_runs AS (
                  SELECT id, job_id, started_at, finished_at, exit_code, stdout_tail,
                         stderr_tail, trigger, process_id, boot_session_id,
                         native_exit_status_at_start, launchd_run_count_at_start,
                         ROW_NUMBER() OVER (
                           PARTITION BY job_id
                           ORDER BY started_at DESC, id DESC
                         ) AS position
                  FROM eligible_runs
                )
                SELECT id, job_id, started_at, finished_at, exit_code, stdout_tail,
                       stderr_tail, trigger, process_id, boot_session_id,
                       native_exit_status_at_start, launchd_run_count_at_start
                FROM ranked_runs
                WHERE position = 1;
                """
            )
            defer { sqlite3_finalize(statement) }

            let latestRuns = try readRuns(statement, operation: "read health")
            var result: [String: Run] = [:]
            result.reserveCapacity(latestRuns.count)
            for run in latestRuns {
                if let existing = result[run.jobID],
                   (existing.startedAt > run.startedAt
                    || (existing.startedAt == run.startedAt && existing.id > run.id)) {
                    continue
                }
                result[run.jobID] = run
            }
            return result
        }
    }

    public func health() throws -> [String: Outcome] {
        try scheduledHealthRuns().mapValues { run in
            run.outcome == .running && !run.isCorroboratedRunning
                ? .unknown
                : run.outcome
        }
    }

    public func markManaged(jobID: String, backupPath: String?) throws {
        try queue.sync {
            let canonicalID = try canonicalJobIDLocked(jobID)
            let statement = try prepare(
                """
                INSERT INTO managed_jobs(job_id, wrapped_at, backup_path)
                VALUES(?, ?, ?)
                ON CONFLICT(job_id) DO UPDATE SET
                  wrapped_at = excluded.wrapped_at,
                  backup_path = excluded.backup_path;
                """
            )
            defer { sqlite3_finalize(statement) }

            try bind(canonicalID, to: 1, in: statement)
            try bind(Date().timeIntervalSince1970, to: 2, in: statement)
            if let backupPath = backupPath {
                try bind(backupPath, to: 3, in: statement)
            } else {
                try bindNull(to: 3, in: statement)
            }
            try stepDone(statement, operation: "mark managed job")
        }
    }

    public func unmarkManaged(jobID: String) throws {
        try queue.sync {
            let canonicalID = try canonicalJobIDLocked(jobID)
            try Self.execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            var committed = false
            defer {
                if !committed {
                    try? Self.execute(database: database, sql: "ROLLBACK;")
                }
            }

            do {
                let resetStatement = try prepare(
                    """
                    INSERT INTO health_resets(job_id, reset_after_run_id)
                    VALUES(?, COALESCE((SELECT MAX(id) FROM runs WHERE job_id = ?), 0))
                    ON CONFLICT(job_id) DO UPDATE SET
                      reset_after_run_id = excluded.reset_after_run_id;
                    """
                )
                defer { sqlite3_finalize(resetStatement) }
                try bind(canonicalID, to: 1, in: resetStatement)
                try bind(canonicalID, to: 2, in: resetStatement)
                try stepDone(resetStatement, operation: "reset stored job health")
            }

            do {
                let deleteStatement = try prepare("DELETE FROM managed_jobs WHERE job_id = ?;")
                defer { sqlite3_finalize(deleteStatement) }
                try bind(canonicalID, to: 1, in: deleteStatement)
                try stepDone(deleteStatement, operation: "unmark managed job")
            }

            try Self.execute(database: database, sql: "COMMIT;")
            committed = true
        }
    }

    public func migrateJobIdentity(from oldJobID: String, to newJobID: String) throws {
        guard oldJobID != newJobID else {
            return
        }
        try queue.sync {
            try Self.execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            var committed = false
            defer {
                if !committed {
                    try? Self.execute(database: database, sql: "ROLLBACK;")
                }
            }

            try migrateJobIdentityLocked(from: oldJobID, to: newJobID)
            try Self.execute(database: database, sql: "COMMIT;")
            committed = true
        }
    }

    public func canonicalJobID(_ jobID: String) throws -> String {
        try queue.sync {
            try canonicalJobIDLocked(jobID)
        }
    }

    public func managedJobIDs() throws -> Set<String> {
        return try queue.sync {
            let statement = try prepare("SELECT job_id FROM managed_jobs;")
            defer { sqlite3_finalize(statement) }

            var result = Set<String>()
            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_ROW {
                    if let jobID = textColumn(0, in: statement) {
                        result.insert(try canonicalJobIDLocked(jobID))
                    }
                } else if stepResult == SQLITE_DONE {
                    return result
                } else {
                    throw databaseError(operation: "read managed jobs", code: stepResult)
                }
            }
        }
    }

    public func managedBackupPath(jobID: String) throws -> String? {
        return try queue.sync {
            let canonicalID = try canonicalJobIDLocked(jobID)
            let statement = try prepare(
                "SELECT backup_path FROM managed_jobs WHERE job_id = ? LIMIT 1;"
            )
            defer { sqlite3_finalize(statement) }

            try bind(canonicalID, to: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                return textColumn(0, in: statement)
            }
            if result == SQLITE_DONE {
                return nil
            }
            throw databaseError(operation: "read managed job backup", code: result)
        }
    }

    public func migrateLegacyJobIDs(
        discoveredJobs: [Job],
        discoveryComplete: Bool = true
    ) throws -> JobIdentityMigrationReport {
        let candidates = Self.legacyIdentityCandidates(discoveredJobs)
        return try queue.sync {
            if !discoveryComplete {
                return JobIdentityMigrationReport(
                    performed: false,
                    migratedJobIDs: [:],
                    orphanedLegacyJobIDs: try storedLegacyJobIDs()
                )
            }

            try Self.execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
            var committed = false
            defer {
                if !committed {
                    try? Self.execute(database: database, sql: "ROLLBACK;")
                }
            }

            do {
                let legacyIDs = try storedLegacyJobIDs()
                if try schemaMetaValue(forKey: Self.jobIdentityMigrationKey) != nil {
                    try Self.execute(database: database, sql: "COMMIT;")
                    committed = true
                    return JobIdentityMigrationReport(
                        performed: false,
                        migratedJobIDs: [:],
                        orphanedLegacyJobIDs: legacyIDs
                    )
                }

                var migrated: [String: String] = [:]
                for legacyID in legacyIDs {
                    guard let matches = candidates[legacyID], matches.count == 1,
                          let newID = matches.first else {
                        continue
                    }
                    try migrateJobIdentityLocked(from: legacyID, to: newID)
                    migrated[legacyID] = newID
                }
                try setSchemaMetaValue("complete", forKey: Self.jobIdentityMigrationKey)
                let orphaned = try storedLegacyJobIDs()
                try Self.execute(database: database, sql: "COMMIT;")
                committed = true
                return JobIdentityMigrationReport(
                    performed: true,
                    migratedJobIDs: migrated,
                    orphanedLegacyJobIDs: orphaned
                )
            } catch {
                throw error
            }
        }
    }

    private static func legacyIdentityCandidates(_ jobs: [Job]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for job in jobs where job.source == .launchd || job.source == .claudeRoutine {
            guard let separator = job.id.lastIndex(of: "#") else {
                continue
            }
            let suffix = job.id[job.id.index(after: separator)...]
            guard suffix.count == 12,
                  suffix.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                continue
            }
            result[String(job.id[..<separator]), default: []].insert(job.id)
        }
        return result
    }

    private func storedLegacyJobIDs() throws -> [String] {
        let statement = try prepare(
            """
            SELECT job_id FROM runs
            WHERE instr(job_id, '#') = 0
              AND (job_id LIKE 'launchd:%' OR job_id LIKE 'claude:%')
            UNION
            SELECT job_id FROM managed_jobs
            WHERE instr(job_id, '#') = 0
              AND (job_id LIKE 'launchd:%' OR job_id LIKE 'claude:%')
            UNION
            SELECT job_id FROM health_resets
            WHERE instr(job_id, '#') = 0
              AND job_id LIKE 'launchd:%'
            ORDER BY job_id;
            """
        )
        defer { sqlite3_finalize(statement) }

        var result: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                if let jobID = textColumn(0, in: statement) {
                    result.append(jobID)
                }
            } else if stepResult == SQLITE_DONE {
                return result
            } else {
                throw databaseError(operation: "read legacy job ids", code: stepResult)
            }
        }
    }

    private func schemaMetaValue(forKey key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM schema_meta WHERE key = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(key, to: 1, in: statement)
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_ROW {
            return textColumn(0, in: statement)
        }
        if stepResult == SQLITE_DONE {
            return nil
        }
        throw databaseError(operation: "read schema metadata", code: stepResult)
    }

    private func setSchemaMetaValue(_ value: String, forKey key: String) throws {
        let statement = try prepare(
            """
            INSERT INTO schema_meta(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, to: 1, in: statement)
        try bind(value, to: 2, in: statement)
        try stepDone(statement, operation: "write schema metadata")
    }

    private func canonicalJobIDLocked(_ jobID: String) throws -> String {
        var current = jobID
        var visited = Set<String>()
        while visited.insert(current).inserted {
            let statement = try prepare(
                "SELECT new_job_id FROM job_identity_aliases WHERE old_job_id = ? LIMIT 1;"
            )
            try bind(current, to: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                sqlite3_finalize(statement)
                return current
            }
            guard result == SQLITE_ROW, let next = textColumn(0, in: statement) else {
                sqlite3_finalize(statement)
                throw databaseError(operation: "resolve job identity alias", code: result)
            }
            sqlite3_finalize(statement)
            current = next
        }
        throw SQLiteRunStoreError(
            operation: "resolve job identity alias",
            code: SQLITE_CONSTRAINT,
            message: "Identity alias cycle includes \(jobID)"
        )
    }

    private func migrateJobIdentityLocked(from oldJobID: String, to newJobID: String) throws {
        let oldCanonical = try canonicalJobIDLocked(oldJobID)
        let newCanonical = try canonicalJobIDLocked(newJobID)
        guard oldCanonical != newCanonical else {
            if oldJobID != newCanonical {
                try setIdentityAliasLocked(from: oldJobID, to: newCanonical)
            }
            return
        }

        if try managedRowExistsLocked(oldCanonical), try managedRowExistsLocked(newCanonical) {
            throw SQLiteRunStoreError(
                operation: "migrate job identity",
                code: SQLITE_CONSTRAINT,
                message: "Both \(oldCanonical) and \(newCanonical) already own managed-job records"
            )
        }

        try setIdentityAliasLocked(from: oldCanonical, to: newCanonical)
        if oldJobID != oldCanonical {
            try setIdentityAliasLocked(from: oldJobID, to: newCanonical)
        }

        for storedID in try storedIdentityIDsLocked() where storedID != newCanonical {
            guard try canonicalJobIDLocked(storedID) == newCanonical else {
                continue
            }
            try rekeyRuns(from: storedID, to: newCanonical)
            try rekeyManagedJob(from: storedID, to: newCanonical)
            try rekeyHealthReset(from: storedID, to: newCanonical)
        }
    }

    private func setIdentityAliasLocked(from oldJobID: String, to newJobID: String) throws {
        guard oldJobID != newJobID else {
            return
        }
        let statement = try prepare(
            """
            INSERT INTO job_identity_aliases(old_job_id, new_job_id, created_at)
            VALUES(?, ?, ?)
            ON CONFLICT(old_job_id) DO UPDATE SET
              new_job_id = excluded.new_job_id,
              created_at = excluded.created_at;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(oldJobID, to: 1, in: statement)
        try bind(newJobID, to: 2, in: statement)
        try bind(Date().timeIntervalSince1970, to: 3, in: statement)
        try stepDone(statement, operation: "persist job identity alias")
    }

    private func managedRowExistsLocked(_ jobID: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM managed_jobs WHERE job_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(jobID, to: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return true
        }
        if result == SQLITE_DONE {
            return false
        }
        throw databaseError(operation: "check managed job identity", code: result)
    }

    private func storedIdentityIDsLocked() throws -> Set<String> {
        let statement = try prepare(
            """
            SELECT job_id FROM runs
            UNION SELECT job_id FROM managed_jobs
            UNION SELECT job_id FROM health_resets
            UNION SELECT old_job_id FROM job_identity_aliases
            UNION SELECT new_job_id FROM job_identity_aliases;
            """
        )
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                if let jobID = textColumn(0, in: statement) {
                    result.insert(jobID)
                }
            } else if stepResult == SQLITE_DONE {
                return result
            } else {
                throw databaseError(operation: "read stored job identities", code: stepResult)
            }
        }
    }

    private func rekeyRuns(from legacyID: String, to newID: String) throws {
        let statement = try prepare("UPDATE runs SET job_id = ? WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(newID, to: 1, in: statement)
        try bind(legacyID, to: 2, in: statement)
        try stepDone(statement, operation: "migrate run job id")
    }

    private func rekeyManagedJob(from legacyID: String, to newID: String) throws {
        let readStatement = try prepare(
            "SELECT wrapped_at, backup_path FROM managed_jobs WHERE job_id = ? LIMIT 1;"
        )
        try bind(legacyID, to: 1, in: readStatement)
        let readResult = sqlite3_step(readStatement)
        if readResult == SQLITE_DONE {
            sqlite3_finalize(readStatement)
            return
        }
        guard readResult == SQLITE_ROW else {
            sqlite3_finalize(readStatement)
            throw databaseError(operation: "read managed job for migration", code: readResult)
        }
        let wrappedAt = sqlite3_column_double(readStatement, 0)
        let backupPath = textColumn(1, in: readStatement)
        sqlite3_finalize(readStatement)

        let writeStatement = try prepare(
            """
            INSERT INTO managed_jobs(job_id, wrapped_at, backup_path)
            VALUES(?, ?, ?)
            ON CONFLICT(job_id) DO UPDATE SET
              wrapped_at = MAX(managed_jobs.wrapped_at, excluded.wrapped_at),
              backup_path = COALESCE(managed_jobs.backup_path, excluded.backup_path);
            """
        )
        defer { sqlite3_finalize(writeStatement) }
        try bind(newID, to: 1, in: writeStatement)
        try bind(wrappedAt, to: 2, in: writeStatement)
        if let backupPath {
            try bind(backupPath, to: 3, in: writeStatement)
        } else {
            try bindNull(to: 3, in: writeStatement)
        }
        try stepDone(writeStatement, operation: "migrate managed job id")

        let deleteStatement = try prepare("DELETE FROM managed_jobs WHERE job_id = ?;")
        defer { sqlite3_finalize(deleteStatement) }
        try bind(legacyID, to: 1, in: deleteStatement)
        try stepDone(deleteStatement, operation: "delete legacy managed job id")
    }

    private func rekeyHealthReset(from legacyID: String, to newID: String) throws {
        let statement = try prepare(
            """
            INSERT INTO health_resets(job_id, reset_after_run_id)
            SELECT ?, reset_after_run_id FROM health_resets WHERE job_id = ?
            ON CONFLICT(job_id) DO UPDATE SET
              reset_after_run_id = MAX(
                health_resets.reset_after_run_id,
                excluded.reset_after_run_id
              );
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(newID, to: 1, in: statement)
        try bind(legacyID, to: 2, in: statement)
        try stepDone(statement, operation: "migrate job health reset")

        let deleteStatement = try prepare("DELETE FROM health_resets WHERE job_id = ?;")
        defer { sqlite3_finalize(deleteStatement) }
        try bind(legacyID, to: 1, in: deleteStatement)
        try stepDone(deleteStatement, operation: "delete legacy job health reset")
    }

    private static func execute(database: OpaquePointer, sql: String) throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
            if result == SQLITE_OK {
                return
            }

            let message = String(cString: sqlite3_errmsg(database))
            if let errorMessage = errorMessage {
                sqlite3_free(errorMessage)
            }
            if (result == SQLITE_BUSY || result == SQLITE_LOCKED), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            throw SQLiteRunStoreError(
                operation: "execute schema",
                code: result,
                message: message
            )
        }
    }

    private static func stampSchemaVersion(database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO schema_meta(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let validStatement = statement else {
            throw SQLiteRunStoreError(
                operation: "prepare schema version",
                code: prepareResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(validStatement) }

        let keyResult = bindText("schema_version", to: 1, in: validStatement)
        guard keyResult == SQLITE_OK else {
            throw SQLiteRunStoreError(
                operation: "bind schema version key",
                code: keyResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        let versionResult = bindText(schemaVersion, to: 2, in: validStatement)
        guard versionResult == SQLITE_OK else {
            throw SQLiteRunStoreError(
                operation: "bind schema version value",
                code: versionResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }

        let stepResult = sqlite3_step(validStatement)
        guard stepResult == SQLITE_DONE else {
            throw SQLiteRunStoreError(
                operation: "stamp schema version",
                code: stepResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func ensureRunsTriggerColumn(
        database: OpaquePointer,
        beforeMigration: (() -> Void)?
    ) throws {
        guard try !runTriggerHealthMigrationCompleted(database: database) else {
            return
        }
        if try !runsHasTriggerColumn(database: database) {
            beforeMigration?()
        }

        try execute(database: database, sql: "BEGIN IMMEDIATE TRANSACTION;")
        var committed = false
        defer {
            if !committed {
                try? execute(database: database, sql: "ROLLBACK;")
            }
        }

        if try !runTriggerHealthMigrationCompleted(database: database) {
            if try !runsHasTriggerColumn(database: database) {
                try execute(
                    database: database,
                    sql: "ALTER TABLE runs ADD COLUMN trigger TEXT NOT NULL DEFAULT 'scheduled';"
                )
            }
            try execute(
                database: database,
                sql: """
                    INSERT INTO health_resets(job_id, reset_after_run_id)
                    SELECT job_id, MAX(id) FROM runs GROUP BY job_id
                    ON CONFLICT(job_id) DO UPDATE SET
                      reset_after_run_id = MAX(
                        health_resets.reset_after_run_id,
                        excluded.reset_after_run_id
                      );
                    """
            )
            try markRunTriggerHealthMigrationCompleted(database: database)
        }

        try execute(database: database, sql: "COMMIT;")
        committed = true
    }

    private static func ensureRunEvidenceColumns(database: OpaquePointer) throws {
        let requiredColumns: [(name: String, declaration: String)] = [
            ("process_id", "INTEGER"),
            ("boot_session_id", "TEXT"),
            ("native_exit_status_at_start", "INTEGER"),
            ("launchd_run_count_at_start", "INTEGER"),
        ]
        let existingColumns = try runColumnNames(database: database)
        for column in requiredColumns where !existingColumns.contains(column.name) {
            try execute(
                database: database,
                sql: "ALTER TABLE runs ADD COLUMN \(column.name) \(column.declaration);"
            )
        }
    }

    private static func runColumnNames(database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(runs);",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let validStatement = statement else {
            throw SQLiteRunStoreError(
                operation: "inspect runs schema",
                code: prepareResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(validStatement) }

        var result = Set<String>()
        while true {
            let stepResult = sqlite3_step(validStatement)
            if stepResult == SQLITE_ROW {
                if let name = sqlite3_column_text(validStatement, 1) {
                    result.insert(String(cString: name))
                }
            } else if stepResult == SQLITE_DONE {
                return result
            } else {
                throw SQLiteRunStoreError(
                    operation: "inspect runs schema",
                    code: stepResult,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
        }
    }

    private static func runTriggerHealthMigrationCompleted(
        database: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM schema_meta WHERE key = ? LIMIT 1;",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let validStatement = statement else {
            throw SQLiteRunStoreError(
                operation: "prepare run-trigger health migration lookup",
                code: prepareResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(validStatement) }

        let bindResult = bindText(runTriggerHealthMigrationKey, to: 1, in: validStatement)
        guard bindResult == SQLITE_OK else {
            throw SQLiteRunStoreError(
                operation: "bind run-trigger health migration key",
                code: bindResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }

        let stepResult = sqlite3_step(validStatement)
        if stepResult == SQLITE_ROW {
            return true
        }
        guard stepResult == SQLITE_DONE else {
            throw SQLiteRunStoreError(
                operation: "read run-trigger health migration marker",
                code: stepResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        return false
    }

    private static func markRunTriggerHealthMigrationCompleted(
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "INSERT OR IGNORE INTO schema_meta(key, value) VALUES(?, '1');",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let validStatement = statement else {
            throw SQLiteRunStoreError(
                operation: "prepare run-trigger health migration marker",
                code: prepareResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(validStatement) }

        let bindResult = bindText(runTriggerHealthMigrationKey, to: 1, in: validStatement)
        guard bindResult == SQLITE_OK else {
            throw SQLiteRunStoreError(
                operation: "bind run-trigger health migration marker",
                code: bindResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        let stepResult = sqlite3_step(validStatement)
        guard stepResult == SQLITE_DONE else {
            throw SQLiteRunStoreError(
                operation: "write run-trigger health migration marker",
                code: stepResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func runsHasTriggerColumn(database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(runs);",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let validStatement = statement else {
            throw SQLiteRunStoreError(
                operation: "inspect runs schema",
                code: prepareResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }

        var hasTriggerColumn = false
        while true {
            let stepResult = sqlite3_step(validStatement)
            if stepResult == SQLITE_ROW {
                if let name = sqlite3_column_text(validStatement, 1),
                   String(cString: name) == "trigger" {
                    hasTriggerColumn = true
                }
                continue
            }
            if stepResult != SQLITE_DONE {
                sqlite3_finalize(validStatement)
                throw SQLiteRunStoreError(
                    operation: "inspect runs schema",
                    code: stepResult,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
            break
        }
        sqlite3_finalize(validStatement)

        return hasTriggerColumn
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let validStatement = statement else {
            throw databaseError(operation: "prepare statement", code: result)
        }
        return validStatement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let result = Self.bindText(value, to: index, in: statement)
        guard result == SQLITE_OK else {
            throw databaseError(operation: "bind text", code: result)
        }
    }

    private static func bindText(
        _ value: String,
        to index: Int32,
        in statement: OpaquePointer
    ) -> Int32 {
        let byteCount = value.utf8.count
        guard byteCount <= Int(Int32.max) else {
            return SQLITE_TOOBIG
        }
        return value.withCString {
            sqlite3_bind_text(statement, index, $0, Int32(byteCount), sqliteTransient)
        }
    }

    private func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else {
            throw databaseError(operation: "bind real", code: result)
        }
    }

    private func bind(_ value: Int, to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_int64(statement, index, Int64(value))
        guard result == SQLITE_OK else {
            throw databaseError(operation: "bind integer", code: result)
        }
    }

    private func bind(_ value: Int32, to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_int(statement, index, value)
        guard result == SQLITE_OK else {
            throw databaseError(operation: "bind integer", code: result)
        }
    }

    private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_int64(statement, index, value)
        guard result == SQLITE_OK else {
            throw databaseError(operation: "bind integer", code: result)
        }
    }

    private func bindNull(to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else {
            throw databaseError(operation: "bind null", code: result)
        }
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw databaseError(operation: operation, code: result)
        }
    }

    private func readRuns(_ statement: OpaquePointer, operation: String) throws -> [Run] {
        var result: [Run] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                result.append(try decodeRun(statement))
            } else if stepResult == SQLITE_DONE {
                return result
            } else {
                throw databaseError(operation: operation, code: stepResult)
            }
        }
    }

    private func decodeRun(_ statement: OpaquePointer) throws -> Run {
        let finishedAt: Date?
        if sqlite3_column_type(statement, 3) == SQLITE_NULL {
            finishedAt = nil
        } else {
            finishedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        }

        let exitCode: Int32?
        if sqlite3_column_type(statement, 4) == SQLITE_NULL {
            exitCode = nil
        } else {
            exitCode = sqlite3_column_int(statement, 4)
        }

        let trigger = textColumn(7, in: statement)
            .flatMap(RunTrigger.init(rawValue:)) ?? .scheduled
        let processID: Int32? = sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil : sqlite3_column_int(statement, 8)
        let bootSessionID = textColumn(9, in: statement)
        let nativeExitStatusAtStart: Int32? = sqlite3_column_type(statement, 10) == SQLITE_NULL
            ? nil : sqlite3_column_int(statement, 10)
        let launchdRunCountAtStart: Int64? = sqlite3_column_type(statement, 11) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 11)
        return Run(
            id: sqlite3_column_int64(statement, 0),
            jobID: try canonicalJobIDLocked(textColumn(1, in: statement) ?? ""),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            finishedAt: finishedAt,
            exitCode: exitCode,
            stdoutTail: textColumn(5, in: statement),
            trigger: trigger,
            stderrTail: textColumn(6, in: statement),
            processID: processID,
            bootSessionID: bootSessionID,
            nativeExitStatusAtStart: nativeExitStatusAtStart,
            launchdRunCountAtStart: launchdRunCountAtStart
        )
    }

    private func textColumn(_ index: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        let buffer = UnsafeBufferPointer(start: text, count: byteCount)
        return String(decoding: buffer, as: UTF8.self)
    }

    private func databaseError(operation: String, code: Int32) -> SQLiteRunStoreError {
        return SQLiteRunStoreError(
            operation: operation,
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
