import Dispatch
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
    private static let schemaVersion = "1"
    private static let jobIdentityMigrationKey = "job_identity_v2"

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

    public init(path: String) throws {
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
                  exit_code INTEGER, stdout_tail TEXT, stderr_tail TEXT);
                CREATE INDEX IF NOT EXISTS idx_runs_job ON runs(job_id, started_at DESC);
                CREATE TABLE IF NOT EXISTS managed_jobs(
                  job_id TEXT PRIMARY KEY, wrapped_at REAL NOT NULL, backup_path TEXT);
                CREATE TABLE IF NOT EXISTS schema_meta(key TEXT PRIMARY KEY, value TEXT);
                """
            )
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

    public func beginRun(jobID: String, startedAt: Date) throws -> Int64 {
        return try queue.sync {
            let statement = try prepare("INSERT INTO runs(job_id, started_at) VALUES(?, ?);")
            defer { sqlite3_finalize(statement) }

            try bind(jobID, to: 1, in: statement)
            try bind(startedAt.timeIntervalSince1970, to: 2, in: statement)
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
            let statement = try prepare(
                """
                SELECT id, job_id, started_at, finished_at, exit_code, stdout_tail, stderr_tail
                FROM runs
                WHERE job_id = ?
                ORDER BY started_at DESC, id DESC
                LIMIT ?;
                """
            )
            defer { sqlite3_finalize(statement) }

            try bind(jobID, to: 1, in: statement)
            try bind(max(0, limit), to: 2, in: statement)
            return try readRuns(statement, operation: "read runs")
        }
    }

    public func latestRun(jobID: String) throws -> Run? {
        return try queue.sync {
            let statement = try prepare(
                """
                SELECT id, job_id, started_at, finished_at, exit_code, stdout_tail, stderr_tail
                FROM runs
                WHERE job_id = ?
                ORDER BY started_at DESC, id DESC
                LIMIT 1;
                """
            )
            defer { sqlite3_finalize(statement) }

            try bind(jobID, to: 1, in: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                return decodeRun(statement)
            }
            if result == SQLITE_DONE {
                return nil
            }
            throw databaseError(operation: "read latest run", code: result)
        }
    }

    public func health() throws -> [String: Outcome] {
        return try queue.sync {
            let statement = try prepare(
                """
                WITH ranked_runs AS (
                  SELECT id, job_id, started_at, finished_at, exit_code, stdout_tail, stderr_tail,
                         ROW_NUMBER() OVER (
                           PARTITION BY job_id
                           ORDER BY started_at DESC, id DESC
                         ) AS position
                  FROM runs
                )
                SELECT id, job_id, started_at, finished_at, exit_code, stdout_tail, stderr_tail
                FROM ranked_runs
                WHERE position = 1;
                """
            )
            defer { sqlite3_finalize(statement) }

            let latestRuns = try readRuns(statement, operation: "read health")
            var result: [String: Outcome] = [:]
            result.reserveCapacity(latestRuns.count)
            for run in latestRuns {
                result[run.jobID] = run.outcome
            }
            return result
        }
    }

    public func markManaged(jobID: String, backupPath: String?) throws {
        try queue.sync {
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

            try bind(jobID, to: 1, in: statement)
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
            let statement = try prepare("DELETE FROM managed_jobs WHERE job_id = ?;")
            defer { sqlite3_finalize(statement) }

            try bind(jobID, to: 1, in: statement)
            try stepDone(statement, operation: "unmark managed job")
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
                        result.insert(jobID)
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
            let statement = try prepare(
                "SELECT backup_path FROM managed_jobs WHERE job_id = ? LIMIT 1;"
            )
            defer { sqlite3_finalize(statement) }

            try bind(jobID, to: 1, in: statement)
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
                    try rekeyRuns(from: legacyID, to: newID)
                    try rekeyManagedJob(from: legacyID, to: newID)
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
                result.append(decodeRun(statement))
            } else if stepResult == SQLITE_DONE {
                return result
            } else {
                throw databaseError(operation: operation, code: stepResult)
            }
        }
    }

    private func decodeRun(_ statement: OpaquePointer) -> Run {
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

        return Run(
            id: sqlite3_column_int64(statement, 0),
            jobID: textColumn(1, in: statement) ?? "",
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            finishedAt: finishedAt,
            exitCode: exitCode,
            stdoutTail: textColumn(5, in: statement),
            stderrTail: textColumn(6, in: statement)
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
