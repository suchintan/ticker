import Darwin
import CryptoKit
import Foundation
import SQLite3

private final class TestHarness {
    private(set) var passed = 0
    private(set) var failed = 0

    func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if condition() {
            pass(message)
        } else {
            fail(message, detail: "condition was false", file: file, line: line)
        }
    }

    func expectEqual<Value: Equatable>(
        _ actual: @autoclosure () throws -> Value,
        _ expected: @autoclosure () throws -> Value,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let actualValue = try actual()
            let expectedValue = try expected()
            if actualValue == expectedValue {
                pass(message)
            } else {
                fail(
                    message,
                    detail: "expected \(String(reflecting: expectedValue)), got \(String(reflecting: actualValue))",
                    file: file,
                    line: line
                )
            }
        } catch {
            fail(message, detail: "threw \(error)", file: file, line: line)
        }
    }

    func expectNear(
        _ actual: @autoclosure () throws -> TimeInterval,
        _ expected: TimeInterval,
        accuracy: TimeInterval,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let actualValue = try actual()
            if abs(actualValue - expected) <= accuracy {
                pass(message)
            } else {
                fail(
                    message,
                    detail: "expected \(expected) ± \(accuracy), got \(actualValue)",
                    file: file,
                    line: line
                )
            }
        } catch {
            fail(message, detail: "threw \(error)", file: file, line: line)
        }
    }

    func expectThrows<Value>(
        _ expression: @autoclosure () throws -> Value,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            fail(message, detail: "did not throw", file: file, line: line)
        } catch {
            pass(message)
        }
    }

    func run(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
        } catch {
            fail(name, detail: "unexpected error: \(error)", file: file, line: line)
        }
    }

    func finish() -> Never {
        print("SUMMARY \(passed) passed, \(failed) failed")
        Darwin.exit(failed == 0 ? 0 : 1)
    }

    private func pass(_ message: String) {
        passed += 1
        print("PASS \(message)")
    }

    private func fail(_ message: String, detail: String, file: StaticString, line: UInt) {
        failed += 1
        print("FAIL \(message) — \(detail) [\(file):\(line)]")
    }
}

private enum FixtureError: Error {
    case missing(String)
}

private func require<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else {
        throw FixtureError.missing(message)
    }
    return value
}

private func withTemporaryDirectory(
    _ name: String,
    _ body: (URL) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TickerTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
}

private func utcDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0
) throws -> Date {
    try require(
        utcCalendar.date(from: DateComponents(
            calendar: utcCalendar,
            timeZone: utcCalendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        )),
        "invalid fixture date"
    )
}

private func writePropertyList(_ value: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: value,
        format: .xml,
        options: 0
    )
    try data.write(to: url)
}

private func writeScheduledTasks(
    root: URL,
    session: String,
    object: [String: Any]
) throws {
    let directory = root
        .appendingPathComponent("account", isDirectory: true)
        .appendingPathComponent(session, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent("scheduled-tasks.json"))
}

private func testExitStatus(_ tests: TestHarness) {
    let missing = ExitStatus(raw: 32_512)
    tests.expectEqual(missing.code, 127, "wait status 32512 decodes to exit 127")
    tests.expectEqual(missing.meaning, "command not found", "exit 127 means command not found")
    tests.expect(!missing.isSuccess, "command-not-found status is a failure")

    let success = ExitStatus(raw: 0)
    tests.expect(success.isSuccess, "exit zero is successful")
    tests.expectEqual(success.meaning, "ok", "exit zero meaning is ok")

    let signal = ExitStatus(raw: SIGKILL)
    tests.expectEqual(signal.signal, SIGKILL, "raw signal status is decoded")
    tests.expect(signal.meaning.contains("SIGKILL"), "signal meaning names SIGKILL")
    tests.expect(
        ExitStatus(raw: 128 + SIGTERM).meaning.contains("SIGTERM"),
        "shell-style signal status names SIGTERM"
    )
}

private func testCronAndSchedules(_ tests: TestHarness) throws {
    let daily = try CronExpression("55 23 * * *")
    tests.expectEqual(
        daily.nextFire(after: try utcDate(2026, 8, 13, 22, 10), calendar: utcCalendar),
        try utcDate(2026, 8, 13, 23, 55),
        "daily cron finds 23:55"
    )

    let weekdays = try CronExpression("30 8 * * 1-5")
    tests.expectEqual(
        weekdays.nextFire(after: try utcDate(2026, 8, 14, 18), calendar: utcCalendar),
        try utcDate(2026, 8, 17, 8, 30),
        "weekday cron skips the weekend"
    )

    let quarterHour = try CronExpression("*/15 * * * *")
    tests.expectEqual(
        quarterHour.nextFire(after: try utcDate(2026, 8, 13, 10, 7), calendar: utcCalendar),
        try utcDate(2026, 8, 13, 10, 15),
        "step cron finds the next quarter hour"
    )

    let shortcut = try CronExpression("@daily")
    tests.expectEqual(
        shortcut.nextFire(after: try utcDate(2026, 8, 13, 12), calendar: utcCalendar),
        try utcDate(2026, 8, 14),
        "@daily expands to midnight"
    )

    let dayOrWeekday = try CronExpression("0 0 1 * 1")
    tests.expectEqual(
        dayOrWeekday.nextFire(after: try utcDate(2026, 8, 31, 12), calendar: utcCalendar),
        try utcDate(2026, 9, 1),
        "cron day-of-month match fires when weekday does not"
    )
    tests.expectEqual(
        dayOrWeekday.nextFire(after: try utcDate(2026, 9, 1), calendar: utcCalendar),
        try utcDate(2026, 9, 7),
        "cron weekday match fires when day-of-month does not"
    )

    tests.expectThrows(try CronExpression("nonsense"), "invalid cron field count is rejected")
    tests.expectThrows(try CronExpression("60 * * * *"), "out-of-range cron value is rejected")
    tests.expectEqual(
        Schedule.cron("60 * * * *").nextFire(
            after: try utcDate(2026, 8, 13),
            calendar: utcCalendar
        ),
        nil,
        "invalid cron schedule has no next fire"
    )

    tests.expectEqual(
        Schedule.cron("30 8 * * 1-5").humanDescription,
        "weekdays at 08:30",
        "human description covers weekday time"
    )
    tests.expectEqual(
        Schedule.cron("55 23 * * *").humanDescription,
        "every day at 23:55",
        "human description covers daily time"
    )
    tests.expectEqual(
        Schedule.cron("*/30 8-19 * * 1-5").humanDescription,
        "every 30 minutes, 08:00-19:59, weekdays",
        "human description covers stepped weekday range"
    )
    tests.expectEqual(
        Schedule.calendar([CalendarComponents(minute: 30, hour: 4)]).humanDescription,
        "every day at 04:30",
        "human description covers launchd calendar"
    )
    tests.expectEqual(
        Schedule.interval(3_600).humanDescription,
        "every hour",
        "human description covers hourly interval"
    )
    tests.expectEqual(Schedule.onDemand.humanDescription, "on demand", "human description covers on demand")
}

private func launchdRunner(_ executable: URL, _ arguments: [String]) throws -> AdapterCommandResult {
    guard arguments.count == 2, arguments[0] == "print" else {
        return AdapterCommandResult(status: 1, stdout: "", stderr: "unexpected command")
    }
    let raw = arguments[1].hasSuffix("/com.example.dictionary") ? 32_512 : 0
    return AdapterCommandResult(
        status: 0,
        stdout: "state = running\nlast exit code = \(raw)\n",
        stderr: ""
    )
}

private func testLaunchdAdapter(_ tests: TestHarness) throws {
    try withTemporaryDirectory("launchd") { root in
        let directoryA = root.appendingPathComponent("a", isDirectory: true)
        let directoryB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directoryB, withIntermediateDirectories: true)

        try writePropertyList(
            [
                "Label": "com.example.dictionary",
                "ProgramArguments": [
                    "/usr/local/bin/ticker", "run",
                    "--ticker-wrapper-version", LaunchdWrapper.currentVersion,
                    "--label", "launchd:com.example.dictionary",
                    "--", "/usr/bin/true", "--original-flag",
                ],
                "StartCalendarInterval": ["Hour": 4, "Minute": 30, "Weekday": 0],
            ],
            to: directoryA.appendingPathComponent("dictionary.plist")
        )
        try writePropertyList(
            [
                "Label": "com.example.array",
                "Program": "/usr/bin/false",
                "StartCalendarInterval": [
                    ["Hour": 8, "Minute": 15, "Weekday": 7],
                    ["Hour": 9, "Minute": 45, "Weekday": 2],
                ],
            ],
            to: directoryA.appendingPathComponent("array.plist")
        )
        try writePropertyList(
            ["Label": "ignored.label", "ProgramArguments": ["/usr/bin/true"]],
            to: directoryA.appendingPathComponent("com.example.disabled.plist.disabled-20260813")
        )
        try Data("<?xml version=\"1.0\"?><plist><dict>".utf8)
            .write(to: directoryA.appendingPathComponent("malformed.plist"))

        for directory in [directoryA, directoryB] {
            try writePropertyList(
                ["Label": "Cyolo", "ProgramArguments": ["/usr/bin/true"]],
                to: directory.appendingPathComponent("Cyolo.plist")
            )
        }

        let adapter = LaunchdAdapter(searchDirectories: [directoryB, directoryA], commandRunner: launchdRunner)
        let jobs = try adapter.discover()
        tests.expectEqual(
            jobs.count,
            6,
            "test14_malformedLaunchdPlist_isVisibleBesideValidSiblings"
        )
        tests.expectEqual(
            jobs.first { $0.label == "malformed" }?.attention?.kind,
            "malformedConfiguration",
            "test14_malformedLaunchdPlist_hasTypedDiagnostic"
        )
        tests.expectEqual(Set(jobs.map(\.id)).count, jobs.count, "all discovered launchd ids are unique")

        let dictionaryJob = try require(
            jobs.first { $0.label == "com.example.dictionary" },
            "dictionary launchd fixture"
        )
        if case let .calendar(components) = dictionaryJob.schedule {
            tests.expect(
                components.count == 1 && components[0].hour == 4 && components[0].minute == 30,
                "launchd dictionary StartCalendarInterval is parsed"
            )
        } else {
            tests.expect(false, "launchd dictionary StartCalendarInterval is parsed")
        }
        tests.expectEqual(
            dictionaryJob.command,
            ["/usr/bin/true", "--original-flag"],
            "managed launchd wrapper exposes original command"
        )
        tests.expect(dictionaryJob.managed, "wrapped launchd job is marked managed")
        tests.expectEqual(dictionaryJob.lastKnownExit?.code, 127, "launchd wait status is decoded")

        let arrayJob = try require(jobs.first { $0.label == "com.example.array" }, "array launchd fixture")
        if case let .calendar(components) = arrayJob.schedule {
            tests.expectEqual(components.map(\.weekday), [7, 2], "launchd array StartCalendarInterval is parsed")
        } else {
            tests.expect(false, "launchd array StartCalendarInterval is parsed")
        }

        let disabledJob = try require(
            jobs.first { $0.label == "com.example.disabled" },
            "disabled launchd fixture"
        )
        tests.expect(!disabledJob.enabled, ".plist.disabled-* job is disabled")

        let collisions = jobs.filter { $0.label == "Cyolo" }
        tests.expectEqual(collisions.count, 2, "both duplicate-label plists are discovered")
        tests.expect(
            collisions.allSatisfy { $0.id.hasPrefix("launchd:Cyolo#") },
            "duplicate labels receive path digests"
        )
        tests.expectEqual(Set(collisions.map(\.id)).count, 2, "duplicate labels receive distinct ids")

        let reversed = try LaunchdAdapter(
            searchDirectories: [directoryA, directoryB],
            commandRunner: launchdRunner
        ).discover()
        let firstByPath = Dictionary(uniqueKeysWithValues: collisions.map { ($0.configPath ?? "", $0.id) })
        let secondByPath = Dictionary(
            uniqueKeysWithValues: reversed
                .filter { $0.label == "Cyolo" }
                .map { ($0.configPath ?? "", $0.id) }
        )
        tests.expectEqual(firstByPath, secondByPath, "duplicate launchd ids are stable across directory order")
    }
}

private func testLaunchdWrapperDecode(_ tests: TestHarness) throws {
    let decoded = try require(
        LaunchdWrapper.decode([
            "ticker", "run", "--ticker-wrapper-version", LaunchdWrapper.currentVersion,
            "--label", "launchd:com.example", "--", "/bin/bash", "/tmp/job.sh",
        ]),
        "versioned wrapped argv"
    )
    tests.expectEqual(decoded.label, "launchd:com.example", "LaunchdWrapper decodes the job label")
    tests.expectEqual(decoded.original, ["/bin/bash", "/tmp/job.sh"], "LaunchdWrapper decodes original argv")
    tests.expectEqual(
        LaunchdWrapper.decode([
            "ticker", "run", "--label", "launchd:com.example", "--", "/bin/bash",
        ])?.label,
        nil,
        "LaunchdWrapper requires versioned provenance"
    )
    tests.expectEqual(
        LaunchdWrapper.decode(["/bin/bash", "/tmp/job.sh"])?.label,
        nil,
        "LaunchdWrapper rejects unwrapped argv"
    )
    tests.expectEqual(
        LaunchdWrapper.decode([
            "/usr/local/bin/ticker-helper", "run", "--ticker-wrapper-version",
            LaunchdWrapper.currentVersion, "--label", "launchd:com.example", "--", "/bin/bash",
        ])?.label,
        nil,
        "LaunchdWrapper rejects near-miss executables"
    )
}

private func testCrontabAdapter(_ tests: TestHarness) throws {
    let missing = CrontabAdapter { _, arguments in
        tests.expectEqual(arguments, ["-l"], "crontab adapter invokes crontab -l")
        return AdapterCommandResult(status: 1, stdout: "", stderr: "crontab: no crontab for test-user\n")
    }
    tests.expectEqual(try missing.discover(), [], "no crontab is an empty job list")

    let rawLine = "0 4 * * * /usr/local/bin/nightly --quiet"
    let adapter = CrontabAdapter { _, _ in
        AdapterCommandResult(
            status: 0,
            stdout: "SHELL=/bin/zsh\n\(rawLine)\n@daily echo daily\n",
            stderr: ""
        )
    }
    let first = try adapter.discover()
    let second = try adapter.discover()
    let firstNightly = try require(first.first { $0.command.last == "/usr/local/bin/nightly --quiet" }, "nightly cron")
    let secondNightly = try require(second.first { $0.command.last == "/usr/local/bin/nightly --quiet" }, "second nightly cron")
    tests.expectEqual(firstNightly.id, secondNightly.id, "crontab ids are stable")
    tests.expect(
        firstNightly.id.range(of: #"^cron:[0-9a-f]{12}$"#, options: .regularExpression) != nil,
        "crontab id uses a stable digest"
    )
    tests.expectEqual(adapter.environment["SHELL"], "/bin/zsh", "crontab environment is parsed")
    let daily = try require(first.first { $0.command.last == "echo daily" }, "daily cron")
    tests.expectEqual(daily.schedule, .cron("0 0 * * *"), "crontab @daily shortcut is expanded")
}

private func testClaudeAdapter(_ tests: TestHarness) throws {
    try withTemporaryDirectory("claude") { root in
        try writeScheduledTasks(
            root: root,
            session: "older",
            object: [
                "scheduledTasks": [[
                    "id": "daily-summary",
                    "cronExpression": "55 23 * * *",
                    "enabled": true,
                    "filePath": "/tmp/daily-summary/SKILL.md",
                    "createdAt": 1_772_896_263_103 as Int64,
                    "lastRunAt": "2026-08-12T13:51:58.006Z",
                    "lastScheduledFor": "2026-08-12T03:55:00.000Z",
                    "cwd": "/tmp/project-old",
                ] as [String: Any]],
                "recordedSkips": [
                    "daily-summary": [[
                        "at": 1_786_074_929_896 as Int64,
                        "reason": "per_task_limit",
                    ] as [String: Any]],
                ],
            ]
        )
        try writeScheduledTasks(
            root: root,
            session: "newer",
            object: [
                "scheduledTasks": [[
                    "id": "daily-summary",
                    "cronExpression": "55 23 * * *",
                    "enabled": true,
                    "filePath": "/tmp/daily-summary/SKILL.md",
                    "createdAt": 1_772_896_263_103 as Int64,
                    "lastRunAt": "2026-08-13T14:01:02.123Z",
                    "lastScheduledFor": "2026-08-13T03:55:00.000Z",
                    "cwd": "/tmp/project-new",
                ] as [String: Any]],
            ]
        )
        try writeScheduledTasks(root: root, session: "empty-array", object: ["scheduledTasks": [] as [Any]])
        let emptyDirectory = root
            .appendingPathComponent("account", isDirectory: true)
            .appendingPathComponent("empty-file", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        try Data().write(to: emptyDirectory.appendingPathComponent("scheduled-tasks.json"))

        let adapter = ClaudeRoutineAdapter(searchRoots: [root])
        let jobs = try adapter.discover()
        tests.expectEqual(jobs.count, 1, "Claude routines dedupe across files and tolerate empty files")
        let job = try require(jobs.first, "deduped Claude job")
        tests.expect(
            job.id.range(
                of: #"^claude:daily-summary#[0-9a-f]{12}$"#,
                options: .regularExpression
            ) != nil,
            "Claude routine id always includes its account-directory digest"
        )
        tests.expectEqual(job.cwd, "/tmp/project-new", "Claude routine dedupe keeps the newest run")
        tests.expectNear(
            try require(job.lastRunAt, "Claude lastRunAt").timeIntervalSince1970,
            1_786_629_662.123,
            accuracy: 0.001,
            "Claude fractional-second ISO-8601 timestamp is parsed"
        )
        let skipSnapshot = adapter.skipSnapshot()
        let records = try require(skipSnapshot.recordsByJobID[job.id], "Claude skips")
        tests.expectEqual(records.count, 1, "Claude skip records are loaded")
        tests.expectNear(
            try require(records.first, "first Claude skip").at.timeIntervalSince1970,
            1_786_074_929.896,
            accuracy: 0.001,
            "Claude skip epoch milliseconds convert to seconds"
        )
        tests.expect(
            !skipSnapshot.observedJobIDs.contains(job.id),
            "Claude skip snapshots withhold account observations when another file is unreadable"
        )
        tests.expectEqual(
            skipSnapshot.errors.count,
            1,
            "Claude skip snapshots preserve valid records when another file is unreadable"
        )
    }

    try withTemporaryDirectory("claude-skip-read-failure") { root in
        try writeScheduledTasks(
            root: root,
            session: "session",
            object: [
                "scheduledTasks": [[
                    "id": "daily-summary",
                    "cronExpression": "55 23 * * *",
                    "enabled": true,
                    "filePath": "/tmp/daily-summary/SKILL.md",
                ] as [String: Any]],
                "recordedSkips": [
                    "daily-summary": [[
                        "at": 1_786_074_929_896 as Int64,
                        "reason": "per_task_limit",
                    ] as [String: Any]],
                ],
            ]
        )
        let adapter = ClaudeRoutineAdapter(searchRoots: [root])
        let job = try require(try adapter.discover().first, "Claude failure fixture job")
        let healthySnapshot = adapter.skipSnapshot()
        tests.expect(
            healthySnapshot.observedJobIDs.contains(job.id),
            "Claude skip snapshot observes a readable job"
        )

        try Data().write(
            to: test2B_scheduledTasksURL(root: root, session: "session")
        )
        let failedSnapshot = adapter.skipSnapshot()
        tests.expectEqual(
            failedSnapshot.recordsByJobID,
            [:],
            "Claude skip read failure does not publish stale records"
        )
        tests.expect(
            !failedSnapshot.observedJobIDs.contains(job.id),
            "Claude skip read failure cannot declare the job recovered"
        )
        tests.expectEqual(
            failedSnapshot.errors.count,
            1,
            "Claude skip read failure is reported"
        )
    }
}

private func testStore(_ tests: TestHarness) throws {
    try withTemporaryDirectory("store") { directory in
        let databaseURL = directory.appendingPathComponent("ticker.db")
        var store: SQLiteRunStore? = try SQLiteRunStore(path: databaseURL.path)
        let opened = try require(store, "opened store")

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let successID = try opened.beginRun(jobID: "launchd:success", startedAt: startedAt)
        tests.expectEqual(
            try opened.latestRun(jobID: "launchd:success")?.outcome,
            .running,
            "store returns a newly started run as running"
        )
        try opened.finishRun(
            id: successID,
            exitCode: 0,
            stdoutTail: "last stdout",
            stderrTail: "last stderr",
            finishedAt: startedAt.addingTimeInterval(12.5)
        )
        let completed = try require(opened.latestRun(jobID: "launchd:success"), "completed run")
        tests.expect(
            completed.id == successID && completed.outcome == .success && completed.duration == 12.5,
            "store round-trips a completed run"
        )

        let quotedJobID = "cron:O'Brien"
        let quotedID = try opened.beginRun(jobID: quotedJobID, startedAt: Date(timeIntervalSince1970: 200))
        try opened.finishRun(
            id: quotedID,
            exitCode: 0,
            stdoutTail: "quoted",
            stderrTail: "",
            finishedAt: Date(timeIntervalSince1970: 201)
        )
        tests.expectEqual(
            try opened.latestRun(jobID: quotedJobID)?.jobID,
            quotedJobID,
            "store round-trips a job id containing a single quote"
        )

        let orderedJobID = "claude:ordered"
        for second in 1...5 {
            let began = Date(timeIntervalSince1970: TimeInterval(second))
            let runID = try opened.beginRun(jobID: orderedJobID, startedAt: began)
            try opened.finishRun(
                id: runID,
                exitCode: Int32(second),
                stdoutTail: "run \(second)",
                stderrTail: "",
                finishedAt: began.addingTimeInterval(0.5)
            )
        }
        tests.expectEqual(
            try opened.runs(jobID: orderedJobID, limit: 3).map { Int($0.startedAt.timeIntervalSince1970) },
            [5, 4, 3],
            "store returns newest runs first and honors limit"
        )

        let oldID = try opened.beginRun(jobID: "launchd:recovering", startedAt: Date(timeIntervalSince1970: 1_000))
        try opened.finishRun(
            id: oldID,
            exitCode: 1,
            stdoutTail: "",
            stderrTail: "old failure",
            finishedAt: Date(timeIntervalSince1970: 1_001)
        )
        let newID = try opened.beginRun(jobID: "launchd:recovering", startedAt: Date(timeIntervalSince1970: 2_000))
        try opened.finishRun(
            id: newID,
            exitCode: 0,
            stdoutTail: "recovered",
            stderrTail: "",
            finishedAt: Date(timeIntervalSince1970: 2_001)
        )
        tests.expectEqual(
            try opened.health()["launchd:recovering"],
            .success,
            "store health returns the latest outcome"
        )

        store = nil
        let reopened = try SQLiteRunStore(path: databaseURL.path)
        tests.expectEqual(
            try reopened.latestRun(jobID: "launchd:success")?.stdoutTail,
            "last stdout",
            "store persists runs across reopen"
        )
    }
}

private func testJobWrapper(_ tests: TestHarness) throws {
    try withTemporaryDirectory("wrapper") { directory in
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        let wrapper = JobWrapper(store: store, backupDirectory: backupDirectory)
        let plistURL = directory.appendingPathComponent("com.example.fixture.plist")
        let originalArguments = ["/usr/bin/env", "echo", "hello"]
        let fixture: [String: Any] = [
            "EnvironmentVariables": ["FIXTURE": "unchanged"],
            "KeepAlive": false,
            "Label": "com.example.fixture",
            "ProgramArguments": originalArguments,
            "RunAtLoad": true,
            "WorkingDirectory": directory.path,
        ]
        let originalData = try PropertyListSerialization.data(
            fromPropertyList: fixture,
            format: .xml,
            options: 0
        )
        try originalData.write(to: plistURL)

        let job = Job(
            id: "launchd:com.example.fixture",
            source: .launchd,
            label: "com.example.fixture",
            schedule: .onDemand,
            command: originalArguments,
            cwd: directory.path,
            enabled: true,
            configPath: plistURL.path,
            lastKnownExit: nil,
            lastRunAt: nil,
            lastScheduledFor: nil,
            managed: false
        )
        let tickerPath = "/usr/local/bin/ticker"
        let commands = try wrapper.wrap(job: job, tickerPath: tickerPath)
        tests.expect(
            commands.unload.contains(plistURL.path) && commands.load.contains(plistURL.path),
            "JobWrapper returns reload commands"
        )
        tests.expect(wrapper.isWrapped(job: job), "JobWrapper rewrites the plist")

        let backupsAfterFirst = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasSuffix(".metadata.json") }
        tests.expectEqual(backupsAfterFirst.count, 1, "JobWrapper creates one backup")
        tests.expectEqual(
            try Data(contentsOf: try require(backupsAfterFirst.first, "first backup")),
            originalData,
            "JobWrapper backup preserves the original bytes"
        )

        _ = try wrapper.wrap(job: job, tickerPath: tickerPath)
        let backupsAfterSecond = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasSuffix(".metadata.json") }
        tests.expectEqual(backupsAfterSecond.count, 1, "JobWrapper wrap is idempotent")

        _ = try wrapper.unwrap(job: job)
        tests.expectEqual(try Data(contentsOf: plistURL), originalData, "JobWrapper unwrap restores bytes exactly")
        tests.expectEqual(try store.managedBackupPath(jobID: job.id), nil, "JobWrapper clears managed backup state")
    }
}

// MARK: - Round 2A wrapper, CLI, and store regressions

private func test2A_makeLaunchdJob(
    id: String,
    label: String,
    command: [String],
    plistURL: URL
) -> Job {
    Job(
        id: id,
        source: .launchd,
        label: label,
        schedule: .onDemand,
        command: command,
        cwd: nil,
        enabled: true,
        configPath: plistURL.path,
        lastKnownExit: nil,
        lastRunAt: nil,
        lastScheduledFor: nil,
        managed: false
    )
}

private func test2A_readPropertyList(_ url: URL) throws -> [String: Any] {
    var format = PropertyListSerialization.PropertyListFormat.xml
    let value = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url),
        options: [],
        format: &format
    )
    return try require(value as? [String: Any], "property-list dictionary")
}

private func test2A_ProgramKeyWrapping(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round2a-program-only") { directory in
        let plistURL = directory.appendingPathComponent("program-only.plist")
        try writePropertyList([
            "Label": "com.example.program-only",
            "Program": "/bin/echo",
            "RunAtLoad": true,
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.program-only",
            label: "com.example.program-only",
            command: ["/bin/echo"],
            plistURL: plistURL
        )

        _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
        let wrapped = try test2A_readPropertyList(plistURL)
        let wrappedArguments = try require(wrapped["ProgramArguments"] as? [String], "wrapped arguments")
        tests.expect(wrapped["Program"] == nil, "test2A Program-only wrap removes Program")
        tests.expectEqual(
            wrappedArguments.first,
            "/Applications/Ticker.app/Contents/Helpers/ticker",
            "test2A Program-only wrap makes ticker the effective executable"
        )
        tests.expectEqual(
            LaunchdWrapper.decode(wrappedArguments)?.original,
            ["/bin/echo"],
            "test2A Program-only wrap preserves the original command"
        )

        _ = try wrapper.unwrap(job: job)
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test2A Program-only unwrap restores the original bytes"
        )
    }

    try test3A_ProgramAndArgumentsExecution(tests)
}

private func test2A_WrapperPathMigration(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round2a-wrapper-migration") { directory in
        let plistURL = directory.appendingPathComponent("migration.plist")
        let originalArguments = ["/bin/echo", "hello"]
        try writePropertyList([
            "Label": "com.example.migration",
            "ProgramArguments": originalArguments,
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        let wrapper = JobWrapper(store: store, backupDirectory: backupDirectory)
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.migration",
            label: "com.example.migration",
            command: originalArguments,
            plistURL: plistURL
        )

        _ = try wrapper.wrap(job: job, tickerPath: "/a/ticker")
        let originalBackupPath = try require(
            try store.managedBackupPath(jobID: job.id),
            "original managed backup"
        )
        _ = try wrapper.wrap(job: job, tickerPath: "/b/ticker")

        let wrapped = try test2A_readPropertyList(plistURL)
        let wrappedArguments = try require(wrapped["ProgramArguments"] as? [String], "migrated arguments")
        let decoded = try require(LaunchdWrapper.decode(wrappedArguments), "single wrapper")
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasSuffix(".metadata.json") }
        tests.expectEqual(wrappedArguments.first, "/b/ticker", "test2A migration updates argv zero")
        tests.expectEqual(decoded.original, originalArguments, "test2A migration remains singly wrapped")
        tests.expect(
            LaunchdWrapper.decode(decoded.original) == nil,
            "test2A migration does not nest the old wrapper"
        )
        tests.expectEqual(backups.count, 1, "test2A migration keeps exactly one backup")
        tests.expectEqual(
            try store.managedBackupPath(jobID: job.id),
            originalBackupPath,
            "test2A migration keeps the original backup record"
        )

        _ = try wrapper.unwrap(job: job)
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test2A one unwrap restores the true original"
        )
    }
}

private func test2A_DurableBackupPrecedesRewrite(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round2a-durable-backup") { directory in
        let plistURL = directory.appendingPathComponent("durable.plist")
        let originalArguments = ["/bin/echo", "durable"]
        try writePropertyList([
            "Label": "com.example.durable",
            "ProgramArguments": originalArguments,
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: backupDirectory,
            immediatelyBeforeSourceExchange: {
                throw FixtureError.missing("injected failure after durable backup")
            }
        )
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.durable",
            label: "com.example.durable",
            command: originalArguments,
            plistURL: plistURL
        )

        tests.expectThrows(
            try wrapper.wrap(job: job, tickerPath: "/usr/local/bin/ticker"),
            "test2A injected pre-rewrite failure propagates"
        )
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { !$0.lastPathComponent.hasSuffix(".metadata.json") }
        tests.expectEqual(backups.count, 1, "test2A durable backup exists before source rewrite")
        tests.expectEqual(
            try Data(contentsOf: try require(backups.first, "durable backup")),
            originalData,
            "test2A durable backup contains the exact original bytes"
        )
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test2A source remains untouched when post-backup work fails"
        )
        tests.expectEqual(
            try store.managedBackupPath(jobID: job.id),
            nil,
            "test2A managed state is not persisted before the injected failure"
        )
    }
}

private func test2A_SQLiteTextRoundTrip(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round2a-sqlite-text") { directory in
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let rawTail = Data([
            0x62, 0x65, 0x66, 0x6f, 0x72, 0x65,
            0x00, 0xff, 0xfe,
            0x61, 0x66, 0x74, 0x65, 0x72,
        ])
        let tail = String(decoding: rawTail, as: UTF8.self)
        let jobID = "launchd:embedded\u{0}nul"
        let runID = try store.beginRun(
            jobID: jobID,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        try store.finishRun(
            id: runID,
            exitCode: 0,
            stdoutTail: tail,
            stderrTail: "error\u{0}suffix",
            finishedAt: Date(timeIntervalSince1970: 11)
        )

        let stored = try require(try store.latestRun(jobID: jobID), "stored NUL run")
        tests.expectEqual(stored.jobID, jobID, "test2A store round-trips NUL in bound job id")
        tests.expectEqual(stored.stdoutTail, tail, "test2A store round-trips NUL and decoded invalid UTF-8")
        tests.expectEqual(
            stored.stdoutTail?.utf8.count,
            tail.utf8.count,
            "test2A stored tail keeps its full UTF-8 byte length"
        )
        tests.expectEqual(
            stored.stderrTail,
            "error\u{0}suffix",
            "test2A store reads text after an embedded NUL"
        )
    }
}

private func test3A_CLIHardening(_ tests: TestHarness) throws {
    let tickerPath = try test3A_builtCLIPath()
    try withTemporaryDirectory("round3a-cli") { directory in
        let storePath = test10_compiledStorePath()
        test10_removeStore(at: storePath)
        defer { test10_removeStore(at: storePath) }
        let fakeLaunchctl = try test10_fakeLaunchctl(in: directory)
        let store = try SQLiteRunStore(path: storePath)
        let environment = [
            "TICKER_TEST_LAUNCHCTL_PATH": fakeLaunchctl.path,
            "TICKER_TEST_LAUNCHD_DIRECTORIES": directory.path,
        ]

        let invalidTail = try test3A_runProcess(
            tickerPath,
            ["run", "--label", "test3A-invalid", "--tail-bytes", "0", "--", "/usr/bin/true"],
            environment: environment
        )
        tests.expectEqual(invalidTail.status, 2, "test3A zero tail limit exits with usage status")
        tests.expect(
            invalidTail.stderr.contains("--tail-bytes requires a positive integer"),
            "test3A zero tail limit explains the valid range"
        )

        let missingChild = try test3A_runProcess(
            tickerPath,
            ["run", "--label", "test3A-missing-child", "--"],
            environment: environment
        )
        tests.expectEqual(missingChild.status, 2, "test3A run without a child exits with usage status")
        tests.expect(
            missingChild.stderr.contains("run requires a child command after '--'"),
            "test3A run without a child explains the missing command"
        )

        let tailCommand = [
            "/usr/bin/python3", "-c",
            "import sys; sys.stdout.write('A' * (1048576 + 257) + 'END')",
        ]
        let tailInvocation = try test10_wrappedInvocation(
            directory: directory,
            label: "com.example.test3A.tail-clamp",
            command: tailCommand,
            tickerPath: tickerPath,
            store: store
        )
        var tailArguments = Array(tailInvocation.arguments.dropFirst())
        tailArguments.insert(
            contentsOf: ["--tail-bytes", "2000000"],
            at: try require(tailArguments.firstIndex(of: "--"), "test3A wrapper separator")
        )
        let oversized = try test3A_runProcess(
            tickerPath,
            tailArguments,
            environment: environment,
            timeout: 30
        )
        tests.expectEqual(oversized.status, 0, "test3A oversized tail run exits successfully")
        let storedTail = try require(
            try store.latestRun(jobID: tailInvocation.job.id)?.stdoutTail,
            "test3A stored clamped tail"
        )
        tests.expectEqual(
            storedTail.utf8.count,
            1_048_576,
            "test3A oversized tail is behaviorally clamped to one MiB"
        )
        tests.expect(storedTail.hasSuffix("END"), "test3A clamped tail keeps the newest output")

        let shellPIDURL = directory.appendingPathComponent("shell.pid")
        let pipelineOutputURL = directory.appendingPathComponent("pipeline-output.txt")
        _ = FileManager.default.createFile(atPath: pipelineOutputURL.path, contents: nil)
        let pipelineOutput = try FileHandle(forWritingTo: pipelineOutputURL)
        defer { try? pipelineOutput.close() }

        let pipelineCommand = [
            "/bin/sh", "-c", "echo $$ > '\(shellPIDURL.path)'; sleep 600 | cat",
        ]
        let pipelineInvocation = try test10_wrappedInvocation(
            directory: directory,
            label: "com.example.test3A.signal-tree",
            command: pipelineCommand,
            tickerPath: tickerPath,
            store: store
        )
        let pipeline = Process()
        pipeline.executableURL = URL(fileURLWithPath: tickerPath)
        pipeline.arguments = Array(pipelineInvocation.arguments.dropFirst())
        var pipelineEnvironment = ProcessInfo.processInfo.environment
        environment.forEach { pipelineEnvironment[$0.key] = $0.value }
        pipeline.environment = pipelineEnvironment
        pipeline.standardOutput = pipelineOutput
        pipeline.standardError = pipelineOutput
        try pipeline.run()
        defer {
            if pipeline.isRunning {
                _ = Darwin.kill(pipeline.processIdentifier, SIGKILL)
            }
        }

        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: shellPIDURL.path), Date() < readyDeadline {
            usleep(20_000)
        }
        let shellPIDText = String(
            decoding: try Data(contentsOf: shellPIDURL),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let shellPID = try require(pid_t(shellPIDText), "test3A pipeline shell pid")

        let signaledAt = Date()
        tests.expectEqual(
            Darwin.kill(pipeline.processIdentifier, SIGTERM),
            0,
            "test3A sends SIGTERM to a running ticker process"
        )
        let exitDeadline = Date().addingTimeInterval(5)
        while pipeline.isRunning, Date() < exitDeadline {
            usleep(20_000)
        }
        let hung = pipeline.isRunning
        if hung {
            _ = Darwin.kill(pipeline.processIdentifier, SIGKILL)
        }
        pipeline.waitUntilExit()
        let elapsed = Date().timeIntervalSince(signaledAt)

        var groupAlive = false
        let groupDeadline = Date().addingTimeInterval(2)
        repeat {
            errno = 0
            groupAlive = Darwin.kill(-shellPID, 0) == 0 || errno == EPERM
            if groupAlive {
                usleep(20_000)
            }
        } while groupAlive && Date() < groupDeadline

        print(
            "TRANSCRIPT test3A N-006 status=\(pipeline.terminationStatus) "
                + "elapsed=\(String(format: "%.3f", elapsed))s descendantsAlive=\(groupAlive)"
        )
        tests.expect(!hung, "test3A ticker exits promptly after forwarding SIGTERM")
        tests.expect(elapsed < 5, "test3A signal forwarding does not wait on inherited pipeline pipes")
        tests.expectEqual(pipeline.terminationStatus, 143, "test3A ticker reports the child's SIGTERM exit")
        tests.expect(!groupAlive, "test3A SIGTERM reaches every process in the child process group")
    }
}


private struct test3A_ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

private final class test3A_DataBox {
    private let lock = NSLock()
    private var value = Data()

    func store(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private var test3A_cachedCLIPath: String?

private func test10_compiledStorePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ticker-compiled-test-default", isDirectory: true)
        .appendingPathComponent("ticker-\(getpid()).db")
        .path
}

private func test10_removeStore(at path: String) {
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}

private func test10_fakeLaunchctl(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("launchctl")
    try """
    #!/bin/sh
    printf 'gui/test = {\n    pid = %s\n    runs = 1\n    last exit code = 0\n}\n' "$PPID"
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func test10_wrappedInvocation(
    directory: URL,
    label: String,
    command: [String],
    tickerPath: String,
    store: SQLiteRunStore
) throws -> (job: Job, arguments: [String]) {
    let plistURL = directory.appendingPathComponent("\(label).plist")
    try writePropertyList([
        "Label": label,
        "ProgramArguments": command,
    ], to: plistURL)
    let job = try test8_discoverLaunchdJob(in: [directory], label: label)
    let wrapper = JobWrapper(
        store: store,
        backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
    )
    _ = try wrapper.wrap(job: job, tickerPath: tickerPath)
    let arguments = try require(
        try test2A_readPropertyList(plistURL)["ProgramArguments"] as? [String],
        "test10 wrapped invocation \(label)"
    )
    return (job, arguments)
}

private func test3A_builtCLIPath() throws -> String {
    if let test3A_cachedCLIPath {
        return test3A_cachedCLIPath
    }
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let result = try test3A_runProcess(
        "/bin/bash",
        ["Scripts/build-app.sh"],
        environment: ["TICKER_TESTING_BUILD": "1"],
        currentDirectory: repository,
        timeout: 240
    )
    guard result.status == 0, !result.timedOut else {
        throw FixtureError.missing(
            "test3A CLI build failed with \(result.status): \(result.stdout)\(result.stderr)"
        )
    }
    let path = repository.appendingPathComponent(".build/swiftc/ticker").path
    guard FileManager.default.isExecutableFile(atPath: path) else {
        throw FixtureError.missing("test3A built CLI at \(path)")
    }
    test3A_cachedCLIPath = path
    return path
}

private func test3A_runProcess(
    _ executable: String,
    _ arguments: [String],
    environment overrides: [String: String] = [:],
    removingEnvironmentKeys: Set<String> = [],
    currentDirectory: URL? = nil,
    timeout: TimeInterval = 15
) throws -> test3A_ProcessResult {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    var environment = ProcessInfo.processInfo.environment
    for key in removingEnvironmentKeys {
        environment.removeValue(forKey: key)
    }
    for (key, value) in overrides {
        environment[key] = value
    }
    process.environment = environment
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutBox = test3A_DataBox()
    let stderrBox = test3A_DataBox()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        readers.leave()
    }

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    var timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
    if timedOut {
        _ = Darwin.kill(process.processIdentifier, SIGTERM)
        if exited.wait(timeout: .now() + 2) == .timedOut {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
    }
    process.waitUntilExit()
    if readers.wait(timeout: .now() + 5) == .timedOut {
        timedOut = true
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        _ = readers.wait(timeout: .now() + 1)
    }
    return test3A_ProcessResult(
        status: process.terminationStatus,
        stdout: String(decoding: stdoutBox.load(), as: UTF8.self),
        stderr: String(decoding: stderrBox.load(), as: UTF8.self),
        timedOut: timedOut
    )
}

private func test3A_compileProgramProbe(in directory: URL) throws -> URL {
    let source = #"""
    #include <limits.h>
    #include <mach-o/dyld.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <sysexits.h>

    int main(int argc, char *argv[]) {
        if (argc != 2) {
            fputs("usage: ProgramProbe OUTPUT\n", stderr);
            return EX_USAGE;
        }

        char executablePath[PATH_MAX];
        uint32_t executablePathSize = (uint32_t)sizeof(executablePath);
        if (_NSGetExecutablePath(executablePath, &executablePathSize) != 0) {
            fputs("_NSGetExecutablePath failed: executable path is too long\n", stderr);
            return EX_OSERR;
        }

        char actualExecutable[PATH_MAX];
        if (realpath(executablePath, actualExecutable) == NULL) {
            perror("realpath");
            return EX_OSERR;
        }

        FILE *output = fopen(argv[1], "w");
        if (output == NULL) {
            perror("fopen");
            return EX_IOERR;
        }
        if (fprintf(
                output,
                "executable=%s\nargv0=%s\n",
                actualExecutable,
                argv[0]
            ) < 0) {
            perror("fprintf");
            (void)fclose(output);
            return EX_IOERR;
        }
        if (fclose(output) != 0) {
            perror("fclose");
            return EX_IOERR;
        }
        return EX_OK;
    }
    """#
    let sourceURL = directory.appendingPathComponent("ProgramProbe.c")
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    let executableURL = directory.appendingPathComponent("ProgramProbe")
    try test3B_runProcess(
        "/usr/bin/clang",
        [
            "-o", executableURL.path,
            sourceURL.path,
        ]
    )
    return executableURL
}

private func test3A_canonicalPath(_ url: URL) throws -> String {
    errno = 0
    guard let resolvedPath = Darwin.realpath(url.path, nil) else {
        let errorNumber = errno
        throw FixtureError.missing(
            "test3A realpath \(url.path): \(String(cString: strerror(errorNumber)))"
        )
    }
    defer { free(resolvedPath) }
    return String(cString: resolvedPath)
}

private func test3A_ProgramAndArgumentsExecution(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round3a-program-and-arguments") { directory in
        let tickerPath = try test3A_builtCLIPath()
        let storePath = test10_compiledStorePath()
        test10_removeStore(at: storePath)
        defer { test10_removeStore(at: storePath) }
        let fakeLaunchctl = try test10_fakeLaunchctl(in: directory)
        let environment = [
            "TICKER_TEST_LAUNCHCTL_PATH": fakeLaunchctl.path,
            "TICKER_TEST_LAUNCHD_DIRECTORIES": directory.path,
        ]
        let probeURL = try test3A_compileProgramProbe(in: directory)
        let observedURL = directory.appendingPathComponent("observed.txt")
        let plistURL = directory.appendingPathComponent("program-and-arguments.plist")
        try writePropertyList([
            "Label": "com.example.program-and-arguments",
            "Program": probeURL.path,
            "ProgramArguments": ["nightly-shell", observedURL.path],
            "ThrottleInterval": 15,
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)

        let adapter = LaunchdAdapter(searchDirectories: [directory]) { _, _ in
            AdapterCommandResult(status: 0, stdout: "", stderr: "")
        }
        let job = try require(try adapter.discover().first, "test3A combined launchd job")
        tests.expectEqual(
            job.command,
            [probeURL.path, observedURL.path],
            "test3A launchd discovery uses Program as the executable"
        )

        let store = try SQLiteRunStore(path: storePath)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )
        _ = try wrapper.wrap(job: job, tickerPath: tickerPath)
        let wrapped = try test2A_readPropertyList(plistURL)
        let wrappedArguments = try require(
            wrapped["ProgramArguments"] as? [String],
            "test3A wrapped arguments"
        )
        let result = try test3A_runProcess(
            wrappedArguments[0],
            Array(wrappedArguments.dropFirst()),
            environment: environment
        )
        let observed = String(
            decoding: try Data(contentsOf: observedURL),
            as: UTF8.self
        )
        let observedLines = observed.split(whereSeparator: \.isNewline).map(String.init)
        let observedExecutable = try require(
            observedLines.first,
            "test3A probe executable observation"
        )
        let observedArgv0 = try require(
            observedLines.dropFirst().first,
            "test3A probe argv zero observation"
        )
        print(
            "TRANSCRIPT test3A N-001 status=\(result.status) "
                + "command=\(job.command[0]) observed='\(observed)'"
        )
        tests.expectEqual(result.status, 0, "test3A wrapped Program executable runs successfully")
        tests.expectEqual(
            observedExecutable,
            "executable=\(try test3A_canonicalPath(probeURL))",
            "test3A compiled probe observes the actual Program executable identity"
        )
        tests.expectEqual(
            observedArgv0,
            "argv0=nightly-shell",
            "test3A compiled probe observes the explicit launchd argv zero"
        )
        tests.expectEqual(
            observedLines.count,
            2,
            "test3A compiled probe writes only executable identity and argv zero"
        )

        _ = try wrapper.unwrap(job: job)
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test3A combined unwrap restores the original bytes"
        )
    }
}

private func test3A_MissingBackupRepair(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round3a-missing-backup") { directory in
        let plistURL = directory.appendingPathComponent("missing-backup.plist")
        let originalArguments = ["/bin/echo", "recoverable"]
        try writePropertyList([
            "Label": "com.example.missing-backup",
            "ProgramArguments": originalArguments,
            "RunAtLoad": true,
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        let wrapper = JobWrapper(store: store, backupDirectory: backupDirectory)
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.missing-backup",
            label: "com.example.missing-backup",
            command: originalArguments,
            plistURL: plistURL
        )

        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .unwrapped,
            "test3A an untouched plist reports unwrapped recovery state"
        )
        _ = try wrapper.wrap(job: job, tickerPath: "/old/ticker")
        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .wrappedConsistent,
            "test3A a wrapper, row, and verified backup report consistent state"
        )

        try FileManager.default.removeItem(at: backupDirectory)
        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .wrappedMissingBackup,
            "test3A deleting recovery files reports the missing-backup state"
        )
        _ = try wrapper.wrap(job: job, tickerPath: "/new/ticker")
        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .wrappedConsistent,
            "test3A wrap repairs a deleted backup and managed row"
        )
        let repairedPath = try require(
            try store.managedBackupPath(jobID: job.id),
            "test3A repaired backup path"
        )
        tests.expect(
            FileManager.default.fileExists(atPath: repairedPath),
            "test3A repaired recovery backup exists on disk"
        )

        _ = try wrapper.unwrap(job: job)
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test3A repaired backup restores the original plist"
        )
    }
}

private func test3A_ManualRestoreStaleRow(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round3a-stale-row") { directory in
        let plistURL = directory.appendingPathComponent("stale-row.plist")
        try writePropertyList([
            "Label": "com.example.stale-row",
            "ProgramArguments": ["/bin/echo", "old"],
        ], to: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.stale-row",
            label: "com.example.stale-row",
            command: ["/bin/echo", "old"],
            plistURL: plistURL
        )
        _ = try wrapper.wrap(job: job, tickerPath: "/usr/local/bin/ticker")

        try writePropertyList([
            "Label": "com.example.stale-row",
            "ProgramArguments": ["/bin/echo", "old"],
            "ManualRevision": 2,
        ], to: plistURL)
        let manualData = try Data(contentsOf: plistURL)
        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .staleManagedRow,
            "test3A manual restore with a managed row reports stale-row"
        )
        tests.expectThrows(
            try wrapper.unwrap(job: job),
            "test3A stale-row unwrap refuses to overwrite the user's manual restore"
        )
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            manualData,
            "test3A refused stale-row unwrap leaves the manual plist untouched"
        )

        _ = try wrapper.wrap(job: job, tickerPath: "/usr/local/bin/ticker")
        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .wrappedConsistent,
            "test3A wrapping a stale row backs up the current manual configuration"
        )
        _ = try wrapper.unwrap(job: job)
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            manualData,
            "test3A stale-row repair restores the new manual configuration, not the old backup"
        )
    }
}

private func test3A_ForeignWrapperLabel(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round3a-foreign-label") { directory in
        let firstURL = directory.appendingPathComponent("first.plist")
        try writePropertyList([
            "Label": "com.example.first",
            "ProgramArguments": ["/bin/echo", "first"],
        ], to: firstURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )
        let firstJob = test2A_makeLaunchdJob(
            id: "launchd:com.example.first",
            label: "com.example.first",
            command: ["/bin/echo", "first"],
            plistURL: firstURL
        )
        _ = try wrapper.wrap(job: firstJob, tickerPath: "/usr/local/bin/ticker")

        var copied = try test2A_readPropertyList(firstURL)
        copied["Label"] = "com.example.second"
        let secondURL = directory.appendingPathComponent("second.plist")
        try writePropertyList(copied, to: secondURL)
        let copiedData = try Data(contentsOf: secondURL)
        let secondJob = test2A_makeLaunchdJob(
            id: "launchd:com.example.second",
            label: "com.example.second",
            command: ["/bin/echo", "first"],
            plistURL: secondURL
        )

        tests.expectEqual(
            try wrapper.recoveryState(job: secondJob),
            .wrappedForeignLabel(embeddedJobID: firstJob.id),
            "test3A copied wrapper reports its foreign embedded job id"
        )
        tests.expectThrows(
            try wrapper.wrap(job: secondJob, tickerPath: "/usr/local/bin/ticker"),
            "test3A wrap refuses to adopt a foreign embedded job id"
        )
        tests.expectThrows(
            try wrapper.unwrap(job: secondJob),
            "test3A unwrap refuses to restore a foreign embedded job id"
        )
        tests.expectEqual(
            try Data(contentsOf: secondURL),
            copiedData,
            "test3A foreign-wrapper refusals leave the copied plist untouched"
        )
    }
}

private func test3A_DuplicateLabelRecoveryIsolation(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round3a-duplicate-labels") { directory in
        let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstURL = firstDirectory.appendingPathComponent("Cyolo.plist")
        let secondURL = secondDirectory.appendingPathComponent("Cyolo.plist")
        try writePropertyList([
            "Label": "Cyolo",
            "ProgramArguments": ["/bin/echo", "first"],
            "UniqueValue": "first-original",
        ], to: firstURL)
        try writePropertyList([
            "Label": "Cyolo",
            "ProgramArguments": ["/bin/echo", "second"],
            "UniqueValue": "second-original",
        ], to: secondURL)
        let originals = [
            firstURL.standardizedFileURL.path: try Data(contentsOf: firstURL),
            secondURL.standardizedFileURL.path: try Data(contentsOf: secondURL),
        ]

        let adapter = LaunchdAdapter(
            searchDirectories: [firstDirectory, secondDirectory]
        ) { _, _ in
            AdapterCommandResult(status: 0, stdout: "", stderr: "")
        }
        let jobs = try adapter.discover()
        tests.expectEqual(jobs.count, 2, "test3A both duplicate-label jobs are discovered")
        tests.expectEqual(
            Set(jobs.map(\.id)).count,
            2,
            "test3A duplicate-label jobs use distinct path-derived ids"
        )

        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )
        for job in jobs {
            _ = try wrapper.wrap(job: job, tickerPath: "/usr/local/bin/ticker")
        }
        for job in jobs {
            try store.unmarkManaged(jobID: job.id)
            tests.expectEqual(
                try wrapper.recoveryState(job: job),
                .wrappedMissingBackup,
                "test3A missing managed row is reconciled instead of assumed safe"
            )
        }
        for job in jobs {
            _ = try wrapper.unwrap(job: job)
        }
        for job in jobs {
            let path = try require(job.configPath, "test3A duplicate config path")
            tests.expectEqual(
                try Data(contentsOf: URL(fileURLWithPath: path)),
                try require(originals[path], "test3A original bytes for \(path)"),
                "test3A fallback restores the backup whose metadata matches the exact plist path"
            )
        }
    }
}

// End round 2A regression tests

// MARK: - Round 2B adapter and app regressions

private func test2B_scheduledTasksURL(root: URL, session: String) -> URL {
    root
        .appendingPathComponent("account", isDirectory: true)
        .appendingPathComponent(session, isDirectory: true)
        .appendingPathComponent("scheduled-tasks.json")
}

private func test2B_LaunchdAutomaticTriggersAndEnvironment(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round2b-launchd-triggers") { directory in
        let fixtures: [(label: String, values: [String: Any])] = [
            (
                "com.example.at-load",
                [
                    "RunAtLoad": true,
                    "EnvironmentVariables": [
                        "PATH": "/opt/jobs/bin:/usr/bin:/bin",
                        "MODE": "fixture",
                    ],
                ]
            ),
            ("com.example.keep-alive", ["KeepAlive": true]),
            ("com.example.watch", ["WatchPaths": ["/tmp/input", "/tmp/other"]]),
            ("com.example.queue", ["QueueDirectories": ["/tmp/pending"]]),
            ("com.example.on-demand", [:]),
        ]
        for fixture in fixtures {
            var plist = fixture.values
            plist["Label"] = fixture.label
            plist["ProgramArguments"] = ["/usr/bin/true"]
            try writePropertyList(
                plist,
                to: directory.appendingPathComponent("\(fixture.label).plist")
            )
        }

        let adapter = LaunchdAdapter(searchDirectories: [directory]) { _, arguments in
            if arguments == ["list"] {
                return AdapterCommandResult(status: 0, stdout: "PID\tStatus\tLabel\n", stderr: "")
            }
            return AdapterCommandResult(status: 1, stdout: "", stderr: "unexpected command")
        }
        let jobs = try adapter.discover()
        func job(_ label: String) throws -> Job {
            try require(jobs.first { $0.label == label }, label)
        }

        let atLoad = try job("com.example.at-load")
        tests.expectEqual(atLoad.schedule, .atLoad, "test2B RunAtLoad is reported as at load")
        tests.expectEqual(atLoad.schedule.humanDescription, "at load", "test2B at-load description is honest")
        tests.expectEqual(
            atLoad.environment,
            ["PATH": "/opt/jobs/bin:/usr/bin:/bin", "MODE": "fixture"],
            "test2B launchd EnvironmentVariables reach the job"
        )

        let keepAlive = try job("com.example.keep-alive")
        tests.expectEqual(keepAlive.schedule, .keepAlive, "test2B KeepAlive is reported as kept alive")
        tests.expectEqual(
            keepAlive.schedule.humanDescription,
            "kept alive",
            "test2B keep-alive description is honest"
        )

        let watch = try job("com.example.watch")
        tests.expectEqual(
            watch.schedule,
            .watchPaths(["/tmp/input", "/tmp/other"]),
            "test2B WatchPaths retain their watched paths"
        )
        tests.expectEqual(
            watch.schedule.humanDescription,
            "when any of /tmp/input, /tmp/other changes",
            "test2B WatchPaths description names the watched paths"
        )

        let queue = try job("com.example.queue")
        tests.expectEqual(
            queue.schedule,
            .queueDirectories(["/tmp/pending"]),
            "test2B QueueDirectories retain their paths"
        )
        tests.expectEqual(
            queue.schedule.humanDescription,
            "when /tmp/pending is not empty",
            "test2B QueueDirectories description states the launch condition"
        )

        tests.expectEqual(
            try job("com.example.on-demand").schedule,
            .onDemand,
            "test2B a launchd job without an automatic trigger remains on demand"
        )
        for automatic in [atLoad.schedule, keepAlive.schedule, watch.schedule, queue.schedule] {
            tests.expectEqual(
                automatic.nextFire(after: Date(), calendar: utcCalendar),
                nil,
                "test2B non-calendar launchd trigger has no predictable next fire"
            )
            let encoded = try JSONEncoder().encode(automatic)
            tests.expectEqual(
                try JSONDecoder().decode(Schedule.self, from: encoded),
                automatic,
                "test2B new schedule case survives Codable round-trip"
            )
        }

        let legacyForms: [(String, Schedule)] = [
            (#"{"type":"cron","expression":"0 4 * * *"}"#, .cron("0 4 * * *")),
            (#"{"type":"calendar","entries":[{"minute":30,"hour":4}]}"#, .calendar([
                CalendarComponents(minute: 30, hour: 4),
            ])),
            (#"{"type":"interval","seconds":60}"#, .interval(60)),
            (#"{"type":"onDemand"}"#, .onDemand),
        ]
        for (json, expected) in legacyForms {
            tests.expectEqual(
                try JSONDecoder().decode(Schedule.self, from: Data(json.utf8)),
                expected,
                "test2B existing Schedule JSON remains readable"
            )
        }
    }
}

private func test2B_CrontabExecutionContext(_ tests: TestHarness) throws {
    let adapter = CrontabAdapter { _, _ in
        AdapterCommandResult(
            status: 0,
            stdout: """
            PATH=/opt/cron/bin:/usr/bin:/bin
            SHELL=/bin/zsh
            0 4 * * * nightly --quiet
            @reboot restore-cache
            """,
            stderr: ""
        )
    }
    let jobs = try adapter.discover()
    let nightly = try require(jobs.first { $0.label == "nightly --quiet" }, "test2B nightly cron")
    tests.expectEqual(
        nightly.command,
        ["/bin/zsh", "-c", "nightly --quiet"],
        "test2B crontab SHELL selects the Run Now shell"
    )
    tests.expectEqual(
        nightly.environment["PATH"],
        "/opt/cron/bin:/usr/bin:/bin",
        "test2B crontab PATH reaches the job environment"
    )
    tests.expectEqual(
        nightly.environment["SHELL"],
        "/bin/zsh",
        "test2B crontab SHELL reaches the job environment"
    )
    tests.expectEqual(
        try require(jobs.first { $0.label == "restore-cache" }, "test2B reboot cron").schedule,
        .atLoad,
        "test2B crontab @reboot is not mislabeled on demand"
    )
}

private func test2B_ClaudeRunNowDisabled(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round2b-claude-run-now") { root in
        try writeScheduledTasks(
            root: root,
            session: "routine",
            object: [
                "scheduledTasks": [[
                    "id": "daily-summary",
                    "cronExpression": "55 23 * * *",
                    "enabled": true,
                    "filePath": "/tmp/daily-summary/SKILL.md",
                    "cwd": "/tmp/project",
                ] as [String: Any]],
            ]
        )
        let job = try require(
            try ClaudeRoutineAdapter(searchRoots: [root]).discover().first,
            "test2B Claude routine"
        )
        tests.expectEqual(job.command, [], "test2B Claude routine exposes no guessed command")
        tests.expect(!job.canRunNow, "test2B JobDetail Run Now predicate is false for Claude routines")
        tests.expectEqual(
            job.configPath,
            "/tmp/daily-summary/SKILL.md",
            "test2B Claude routine remains observable after Run Now is disabled"
        )
    }

}

private func test2B_ClaudeSnapshotOrdering(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round2b-claude-run-vs-created") { root in
        try writeScheduledTasks(
            root: root,
            session: "a-new-unrun",
            object: [
                "scheduledTasks": [[
                    "id": "snapshot-order",
                    "cronExpression": "0 8 * * *",
                    "enabled": true,
                    "filePath": "/tmp/new/SKILL.md",
                    "createdAt": 2_000 as Int64,
                    "cwd": "/tmp/new-unrun",
                ] as [String: Any]],
            ]
        )
        try writeScheduledTasks(
            root: root,
            session: "z-old-run",
            object: [
                "scheduledTasks": [[
                    "id": "snapshot-order",
                    "cronExpression": "0 7 * * *",
                    "enabled": true,
                    "filePath": "/tmp/old/SKILL.md",
                    "createdAt": 1_000 as Int64,
                    "lastRunAt": "2026-08-12T08:00:00.000Z",
                    "cwd": "/tmp/old-run",
                ] as [String: Any]],
            ]
        )
        let selected = try require(
            try ClaudeRoutineAdapter(searchRoots: [root]).discover().first,
            "test2B newest Claude snapshot"
        )
        tests.expectEqual(
            selected.cwd,
            "/tmp/new-unrun",
            "test2B newer unrun Claude configuration beats an older run snapshot"
        )
    }

    try withTemporaryDirectory("round2b-claude-file-time") { root in
        try writeScheduledTasks(
            root: root,
            session: "a-newer-file",
            object: [
                "scheduledTasks": [[
                    "id": "file-time-order",
                    "cronExpression": "0 8 * * *",
                    "enabled": true,
                    "filePath": "/tmp/newer-file/SKILL.md",
                    "createdAt": 1_000 as Int64,
                    "cwd": "/tmp/newer-file",
                ] as [String: Any]],
            ]
        )
        try writeScheduledTasks(
            root: root,
            session: "z-older-file",
            object: [
                "scheduledTasks": [[
                    "id": "file-time-order",
                    "cronExpression": "0 8 * * *",
                    "enabled": true,
                    "filePath": "/tmp/older-file/SKILL.md",
                    "createdAt": 1_000 as Int64,
                    "cwd": "/tmp/older-file",
                ] as [String: Any]],
            ]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: test2B_scheduledTasksURL(root: root, session: "a-newer-file").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: test2B_scheduledTasksURL(root: root, session: "z-older-file").path
        )
        let selected = try require(
            try ClaudeRoutineAdapter(searchRoots: [root]).discover().first,
            "test2B modification-time Claude snapshot"
        )
        tests.expectEqual(
            selected.cwd,
            "/tmp/newer-file",
            "test2B file modification time wins after run and creation ties"
        )
    }

    try withTemporaryDirectory("round2b-claude-path-tie") { directory in
        let rootA = directory.appendingPathComponent("a-root", isDirectory: true)
        let rootZ = directory.appendingPathComponent("z-root", isDirectory: true)
        for (root, cwd) in [(rootA, "/tmp/path-a"), (rootZ, "/tmp/path-z")] {
            try writeScheduledTasks(
                root: root,
                session: "session",
                object: [
                    "scheduledTasks": [[
                        "id": "path-tie-order",
                        "cronExpression": "0 8 * * *",
                        "enabled": true,
                        "filePath": "\(cwd)/SKILL.md",
                        "cwd": cwd,
                    ] as [String: Any]],
                ]
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000)],
                ofItemAtPath: test2B_scheduledTasksURL(root: root, session: "session").path
            )
        }
        let forward = try ClaudeRoutineAdapter(searchRoots: [rootA, rootZ]).discover()
        let reversed = try ClaudeRoutineAdapter(searchRoots: [rootZ, rootA]).discover()
        tests.expectEqual(
            forward.count,
            2,
            "test2B distinct absolute account directories remain distinct identities"
        )
        tests.expectEqual(
            Set(forward.compactMap(\.cwd)),
            Set(["/tmp/path-a", "/tmp/path-z"]),
            "test2B cross-root account directories retain both snapshots"
        )
        tests.expectEqual(
            forward,
            reversed,
            "test2B account-path identities resolve identically regardless of root order"
        )
    }
}

private func test2B_ClaudeSkipDeduplication(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round2b-claude-skips") { root in
        try writeScheduledTasks(
            root: root,
            session: "snapshot-one",
            object: [
                "recordedSkips": [
                    "daily-summary": [
                        ["at": 1_000 as Int64, "reason": "shared"] as [String: Any],
                        ["at": 2_000 as Int64, "reason": "limit"] as [String: Any],
                    ],
                ],
            ]
        )
        try writeScheduledTasks(
            root: root,
            session: "snapshot-two",
            object: [
                "recordedSkips": [
                    "daily-summary": [
                        ["at": 1_000 as Int64, "reason": "shared"] as [String: Any],
                        ["at": 2_000 as Int64, "reason": "disabled"] as [String: Any],
                    ],
                ],
            ]
        )
        let skips = ClaudeRoutineAdapter(searchRoots: [root]).skipSnapshot().recordsByJobID
        tests.expect(
            skips.keys.first?.range(
                of: #"^claude:daily-summary#[0-9a-f]{12}$"#,
                options: .regularExpression
            ) != nil,
            "test2B skip-only Claude task uses its account-directory digest"
        )
        let records = try require(skips.values.first, "test2B deduplicated skips")
        tests.expectEqual(records.count, 3, "test2B copied snapshot skips are deduplicated")
        tests.expectEqual(
            Set(records.filter { $0.at.timeIntervalSince1970 == 2 }.map(\.reason)),
            Set(["limit", "disabled"]),
            "test2B same-time skips with distinct reasons both survive"
        )
    }
}

private struct test3B_CommandError: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let output: String

    var description: String {
        "\(command) exited \(status):\n\(output)"
    }
}

@discardableResult
private func test3B_runProcess(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil
) throws -> String {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    try process.run()
    process.waitUntilExit()
    let output = String(
        data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    guard process.terminationStatus == 0 else {
        throw test3B_CommandError(
            command: ([executable] + arguments).joined(separator: " "),
            status: process.terminationStatus,
            output: output
        )
    }
    return output
}

private func test3B_writeScheduledTasks(
    root: URL,
    account: String,
    session: String,
    object: [String: Any]
) throws {
    let directory = root
        .appendingPathComponent(account, isDirectory: true)
        .appendingPathComponent(session, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent("scheduled-tasks.json"))
}

private func test3B_CrontabSchedulerEnvironment(_ tests: TestHarness) throws {
    let adapter = CrontabAdapter { _, _ in
        AdapterCommandResult(
            status: 0,
            stdout: "0 4 * * * command-only-on-gui-path\n",
            stderr: ""
        )
    }
    let job = try require(try adapter.discover().first, "test3B default-environment crontab job")
    tests.expectEqual(
        job.environment["PATH"],
        "/usr/bin:/bin",
        "test3B crontab without PATH uses cron's PATH"
    )
    tests.expectEqual(
        job.environment["SHELL"],
        "/bin/sh",
        "test3B crontab without SHELL uses cron's shell"
    )
    tests.expect(
        job.environment["HOME"]?.isEmpty == false
            && job.environment["LOGNAME"]?.isEmpty == false
            && job.environment["USER"]?.isEmpty == false,
        "test3B crontab defaults include passwd user identity"
    )

    let declared = CrontabAdapter { _, _ in
        AdapterCommandResult(
            status: 0,
            stdout: """
            SHELL = /bin/zsh
            PATH = "/opt/cron/bin:/usr/bin"
            FOO='bar baz'
            15 6 * * * quoted-environment
            """,
            stderr: ""
        )
    }
    let declaredJob = try require(
        try declared.discover().first,
        "test3B declared-environment crontab job"
    )
    tests.expectEqual(
        declaredJob.command,
        ["/bin/zsh", "-c", "quoted-environment"],
        "test3B spaced SHELL assignment selects the declared shell"
    )
    tests.expectEqual(
        declaredJob.environment["PATH"],
        "/opt/cron/bin:/usr/bin",
        "test3B quoted PATH is unquoted and overrides cron's default"
    )
    tests.expectEqual(
        declaredJob.environment["FOO"],
        "bar baz",
        "test3B single-quoted assignment preserves interior whitespace"
    )

    let launchdJob = Job(
        id: "launchd:test3B",
        source: .launchd,
        label: "launchd environment",
        schedule: .onDemand,
        command: ["/usr/bin/true"],
        environment: ["PATH": "/custom/launchd/bin", "DECLARED": "yes"],
        cwd: nil,
        enabled: true,
        configPath: nil,
        lastKnownExit: nil,
        lastRunAt: nil,
        lastScheduledFor: nil,
        managed: false
    )
    let launchdEnvironment = SchedulerEnvironment.effectiveEnvironment(for: launchdJob)
    tests.expectEqual(
        launchdEnvironment["PATH"],
        "/custom/launchd/bin",
        "test3B launchd variables override the minimal launchd base"
    )
    tests.expectEqual(
        launchdEnvironment["DECLARED"],
        "yes",
        "test3B launchd declared variables reach Run Now"
    )
}

private func test3B_ClaudeAccountScopedIDs(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round3b-claude-accounts") { root in
        try test3B_writeScheduledTasks(
            root: root,
            account: "account-alpha",
            session: "session-one",
            object: [
                "scheduledTasks": [[
                    "id": "daily-summary",
                    "cronExpression": "5 8 * * *",
                    "enabled": true,
                    "filePath": "/tmp/account-alpha/SKILL.md",
                    "cwd": "/tmp/account-alpha",
                ] as [String: Any]],
                "recordedSkips": [
                    "daily-summary": [[
                        "at": 1_000 as Int64,
                        "reason": "alpha-only",
                    ] as [String: Any]],
                ],
            ]
        )
        try test3B_writeScheduledTasks(
            root: root,
            account: "account-beta",
            session: "session-two",
            object: [
                "scheduledTasks": [[
                    "id": "daily-summary",
                    "cronExpression": "35 18 * * *",
                    "enabled": true,
                    "filePath": "/tmp/account-beta/SKILL.md",
                    "cwd": "/tmp/account-beta",
                ] as [String: Any]],
                "recordedSkips": [
                    "daily-summary": [[
                        "at": 2_000 as Int64,
                        "reason": "beta-only",
                    ] as [String: Any]],
                ],
            ]
        )

        let adapter = ClaudeRoutineAdapter(searchRoots: [root])
        let firstDiscovery = try adapter.discover()
        let secondDiscovery = try adapter.discover()
        tests.expectEqual(firstDiscovery.count, 2, "test3B duplicate Claude task ids both remain visible")
        tests.expectEqual(
            Set(firstDiscovery.map(\.schedule)),
            Set([Schedule.cron("5 8 * * *"), Schedule.cron("35 18 * * *")]),
            "test3B account-scoped Claude tasks keep their distinct schedules"
        )
        tests.expectEqual(
            Set(firstDiscovery.map(\.id)).count,
            2,
            "test3B colliding Claude task ids receive distinct ids"
        )
        tests.expect(
            firstDiscovery.allSatisfy {
                $0.id.range(
                    of: #"^claude:daily-summary#[0-9a-f]{12}$"#,
                    options: .regularExpression
                ) != nil
            },
            "test3B colliding Claude ids use stable digest suffixes"
        )
        tests.expectEqual(
            firstDiscovery.map(\.id),
            secondDiscovery.map(\.id),
            "test3B account-scoped Claude ids are stable across discovery"
        )

        let skips = adapter.skipSnapshot().recordsByJobID
        tests.expectEqual(
            Set(skips.keys),
            Set(firstDiscovery.map(\.id)),
            "test3B Claude skip keys use the same account-scoped ids as jobs"
        )
        tests.expectEqual(
            skips.values.map(\.count).sorted(),
            [1, 1],
            "test3B Claude skip records do not merge across accounts"
        )
        tests.expectEqual(
            Set(skips.values.compactMap(\.first).map(\.reason)),
            Set(["alpha-only", "beta-only"]),
            "test3B each Claude account retains only its own skip reason"
        )
    }
}

private func test4B_LaunchdIdentityExecutionAndAmbiguity(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round4b-launchd") { root in
        let primaryDirectory = root.appendingPathComponent("primary", isDirectory: true)
        let duplicateDirectory = root.appendingPathComponent("duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: duplicateDirectory, withIntermediateDirectories: true)

        let primaryPlist = primaryDirectory.appendingPathComponent("stable.plist")
        try writePropertyList(
            [
                "Label": "com.example.stable",
                "Program": "/bin/sh",
                "ProgramArguments": ["nightly-shell", "-c", "exit 0"],
            ],
            to: primaryPlist
        )

        var detailedStatusQueries = 0
        let runner: AdapterCommandRunner = { _, arguments in
            if arguments.count == 2,
               arguments[0] == "print",
               arguments[1].hasSuffix("/com.example.stable") {
                detailedStatusQueries += 1
                return AdapterCommandResult(
                    status: 0,
                    stdout: "state = exited\nlast exit code = 256\n",
                    stderr: ""
                )
            }
            return AdapterCommandResult(status: 1, stdout: "", stderr: "unexpected launchctl request")
        }

        let adapter = LaunchdAdapter(
            searchDirectories: [primaryDirectory, duplicateDirectory],
            commandRunner: runner
        )
        let initial = try require(adapter.discover().first, "test4B initial launchd job")
        tests.expect(
            initial.id.range(
                of: #"^launchd:com\.example\.stable#[0-9a-f]{12}$"#,
                options: .regularExpression
            ) != nil,
            "test4B unique launchd id always includes a canonical path digest"
        )
        tests.expectEqual(
            initial.command,
            ["/bin/sh", "-c", "exit 0"],
            "test4B launchd Program remains the executable"
        )
        tests.expectEqual(
            initial.argv0,
            "nightly-shell",
            "test4B launchd preserves ProgramArguments[0] as explicit argv0"
        )
        tests.expectEqual(
            initial.lastKnownExit?.code,
            1,
            "test4B unique loaded launchd job receives its exit status"
        )
        let encoded = try JSONEncoder().encode(initial)
        tests.expectEqual(
            try JSONDecoder().decode(Job.self, from: encoded).argv0,
            "nightly-shell",
            "test4B Job Codable preserves explicit argv0"
        )

        let duplicatePlist = duplicateDirectory.appendingPathComponent("stable.plist")
        try writePropertyList(
            [
                "Label": "com.example.stable",
                "ProgramArguments": ["/usr/bin/true"],
            ],
            to: duplicatePlist
        )
        detailedStatusQueries = 0
        let withDuplicate = try adapter.discover().filter { $0.label == "com.example.stable" }
        tests.expectEqual(withDuplicate.count, 2, "test4B duplicate-label launchd jobs both remain visible")
        tests.expectEqual(
            Set(withDuplicate.map(\.id)).count,
            2,
            "test4B same-label launchd plists receive distinct canonical path ids"
        )
        let initialWithDuplicate = try require(
            withDuplicate.first { $0.configPath == initial.configPath },
            "test4B original launchd job after duplicate appears"
        )
        tests.expectEqual(
            initialWithDuplicate.id,
            initial.id,
            "test4B adding a duplicate does not change the original launchd id"
        )
        tests.expect(
            withDuplicate.allSatisfy { $0.runtimeStatusAttribution == .ambiguous },
            "test4B duplicate-label launchd jobs are marked runtime-ambiguous"
        )
        tests.expect(
            withDuplicate.allSatisfy { $0.lastKnownExit == nil },
            "test4B no duplicate-label plist claims the shared launchctl exit status"
        )
        tests.expect(
            withDuplicate.allSatisfy { !$0.enabled },
            "test4B no duplicate-label plist claims the shared launchctl loaded state"
        )
        tests.expectEqual(
            detailedStatusQueries,
            0,
            "test4B ambiguous labels do not query and misattribute label-level exit status"
        )
        tests.expect(
            withDuplicate.allSatisfy {
                $0.runtimeStatusExplanation?.contains("cannot determine which plist") == true
            },
            "test4B ambiguous runtime status includes an explicit explanation"
        )
        let repeatedByPath = Dictionary(
            uniqueKeysWithValues: try adapter.discover()
                .filter { $0.label == "com.example.stable" }
                .map { ($0.configPath ?? "", $0.id) }
        )
        let firstByPath = Dictionary(
            uniqueKeysWithValues: withDuplicate.map { ($0.configPath ?? "", $0.id) }
        )
        tests.expectEqual(
            repeatedByPath,
            firstByPath,
            "test4B duplicate-label launchd ids remain stable across scans"
        )

        try FileManager.default.removeItem(at: duplicatePlist)
        let afterRemoval = try require(adapter.discover().first, "test4B launchd job after duplicate removal")
        tests.expectEqual(
            afterRemoval.id,
            initial.id,
            "test4B removing a duplicate does not change the original launchd id"
        )

        let aliasDirectory = root.appendingPathComponent("primary-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: primaryDirectory)
        let throughSymlink = try require(
            LaunchdAdapter(searchDirectories: [aliasDirectory], commandRunner: runner).discover().first,
            "test4B launchd job through symlinked directory"
        )
        tests.expectEqual(
            throughSymlink.id,
            initial.id,
            "test4B launchd id hashes the symlink-resolved canonical plist path"
        )
    }
}

private func test4B_ClaudeTopologyIndependentIdentity(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round4b-claude") { root in
        try test3B_writeScheduledTasks(
            root: root,
            account: "account-alpha",
            session: "session-one",
            object: [
                "scheduledTasks": [[
                    "id": "daily-summary",
                    "cronExpression": "5 8 * * *",
                    "enabled": true,
                    "filePath": "/tmp/account-alpha/SKILL.md",
                    "cwd": "/tmp/account-alpha",
                ] as [String: Any]],
            ]
        )
        let adapter = ClaudeRoutineAdapter(searchRoots: [root])
        let alphaAlone = try require(adapter.discover().first, "test4B single-account Claude task")
        tests.expect(
            alphaAlone.id.range(
                of: #"^claude:daily-summary#[0-9a-f]{12}$"#,
                options: .regularExpression
            ) != nil,
            "test4B unique Claude task id always includes an account-directory digest"
        )

        try test3B_writeScheduledTasks(
            root: root,
            account: "account-beta",
            session: "session-two",
            object: [
                "scheduledTasks": [[
                    "id": "daily-summary",
                    "cronExpression": "35 18 * * *",
                    "enabled": true,
                    "filePath": "/tmp/account-beta/SKILL.md",
                    "cwd": "/tmp/account-beta",
                ] as [String: Any]],
            ]
        )
        let bothAccounts = try adapter.discover()
        let alphaWithSibling = try require(
            bothAccounts.first { $0.cwd == "/tmp/account-alpha" },
            "test4B alpha Claude task with sibling"
        )
        tests.expectEqual(
            alphaWithSibling.id,
            alphaAlone.id,
            "test4B adding a second Claude account does not change the first task id"
        )
        tests.expectEqual(
            Set(bothAccounts.map(\.id)).count,
            2,
            "test4B same Claude task id in two accounts receives distinct ids"
        )

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("account-beta", isDirectory: true)
        )
        let alphaAfterRemoval = try require(adapter.discover().first, "test4B Claude task after account removal")
        tests.expectEqual(
            alphaAfterRemoval.id,
            alphaAlone.id,
            "test4B removing a second Claude account does not change the first task id"
        )

        let rootAlias = root.deletingLastPathComponent()
            .appendingPathComponent("round4b-claude-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: rootAlias) }
        let throughSymlink = try require(
            ClaudeRoutineAdapter(searchRoots: [rootAlias]).discover().first,
            "test4B Claude task through symlinked root"
        )
        tests.expectEqual(
            throughSymlink.id,
            alphaAlone.id,
            "test4B Claude id hashes the symlink-resolved canonical account path"
        )
    }
}

private func test4B_AppExecutionAndPresentation(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round3b-app-behavior") { buildDirectory in
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let swiftc = "/usr/bin/swiftc"
        let coreDirectory = repository.appendingPathComponent("Sources/TickerCore", isDirectory: true)
        let adaptersDirectory = coreDirectory.appendingPathComponent("Adapters", isDirectory: true)
        let coreSources = try (
            FileManager.default.contentsOfDirectory(
                at: coreDirectory,
                includingPropertiesForKeys: nil
            )
            + FileManager.default.contentsOfDirectory(
                at: adaptersDirectory,
                includingPropertiesForKeys: nil
            )
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }

        let modulePath = buildDirectory.appendingPathComponent("TickerCore.swiftmodule").path
        let libraryPath = buildDirectory.appendingPathComponent("libTickerCore.a").path
        let moduleCachePath = buildDirectory.appendingPathComponent("ModuleCache", isDirectory: true).path
        try test3B_runProcess(
            swiftc,
            [
                "-module-cache-path", moduleCachePath,
                "-target", "arm64-apple-macosx13.0",
                "-parse-as-library",
                "-emit-module", "-module-name", "TickerCore",
                "-emit-module-path", modulePath,
                "-emit-library", "-static", "-o", libraryPath,
            ] + coreSources.map(\.path),
            currentDirectory: repository
        )

        let harnessSource = #"""
        import CryptoKit
        import Darwin
        import Foundation
        import TickerCore

        private enum HarnessFailure: Error {
            case failed(String)
        }

        private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw HarnessFailure.failed(message)
            }
        }

        private final class BlockingAdapter: JobSourceAdapter {
            let source: JobSource = .crontab
            let firstDiscoveryStarted = DispatchSemaphore(value: 0)
            let releaseFirstDiscovery = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var count = 0

            var discoveryCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }

            func discover() throws -> [Job] {
                lock.lock()
                count += 1
                let current = count
                lock.unlock()
                if current == 1 {
                    firstDiscoveryStarted.signal()
                    _ = releaseFirstDiscovery.wait(timeout: .now() + 3)
                }
                return []
            }
        }

        private final class StaticAdapter: JobSourceAdapter {
            let source: JobSource
            let jobs: [Job]

            init(source: JobSource, jobs: [Job]) {
                self.source = source
                self.jobs = jobs
            }

            func discover() throws -> [Job] {
                jobs
            }
        }

        private final class RecordingFailureNotifier: FailureNotificationHandling {
            private(set) var candidates: [AttentionNotificationCandidate] = []

            func start() {}

            func update(
                candidates: [AttentionNotificationCandidate],
                observedIncidentIDs: [AttentionIncidentID]
            ) {
                self.candidates = candidates
            }
        }

        @main
        private enum AppBehaviorHarness {
            @MainActor
            static func main() throws {
                if CommandLine.arguments.count == 3,
                   CommandLine.arguments[1] == "--capture-argv0" {
                    try CommandLine.arguments[0].write(
                        toFile: CommandLine.arguments[2],
                        atomically: true,
                        encoding: .utf8
                    )
                    return
                }
                let harnessPath = CommandLine.arguments[0]

                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TickerAppHarness-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }

                let appOnlyBin = root.appendingPathComponent("gui-only-bin", isDirectory: true)
                try FileManager.default.createDirectory(at: appOnlyBin, withIntermediateDirectories: true)
                let ticker = appOnlyBin.appendingPathComponent("ticker")
                try """
                #!/bin/bash
                argv0=
                while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
                    if [ "$1" = "--argv0" ]; then
                        [ "$#" -ge 2 ] || exit 64
                        argv0=$2
                        shift 2
                    else
                        shift
                    fi
                done
                [ "$#" -gt 0 ] || exit 64
                shift
                if [ -n "$argv0" ]; then
                    exec -a "$argv0" "$@"
                fi
                exec "$@"
                """.write(to: ticker, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: ticker.path
                )
                let guiOnlyCommand = appOnlyBin.appendingPathComponent("gui-only-command")
                try "#!/bin/sh\nexit 0\n".write(
                    to: guiOnlyCommand,
                    atomically: true,
                    encoding: .utf8
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: guiOnlyCommand.path
                )
                setenv("PATH", appOnlyBin.path, 1)
                setenv("GUI_ONLY_VARIABLE", "must-not-leak", 1)

                let adapter = BlockingAdapter()
                let store = try SQLiteRunStore(path: root.appendingPathComponent("runs.sqlite").path)
                try store.recordRecorderDiagnostic(claimedJobID: "launchd:test10-app",
                                                    message: "ownership probe unavailable")
                let model = AppModel(registry: JobRegistry(adapters: [adapter]), store: store)

                model.refresh()
                try check(
                    adapter.firstDiscoveryStarted.wait(timeout: .now() + 2) == .success,
                    "first refresh did not begin"
                )
                model.refresh()
                adapter.releaseFirstDiscovery.signal()
                try check(
                    waitUntil { adapter.discoveryCount >= 2 },
                    "refresh requested during discovery never executed"
                )
                try check(adapter.discoveryCount == 2, "overlapping refreshes did not coalesce to one pass")
                try check(waitUntil { model.errors.contains { $0.contains("ownership probe unavailable") } },
                          "test10_app_refresh_didNotSurfaceRecorderDiagnostic")
                try store.clearRecorderDiagnostic(claimedJobID: "launchd:test10-app")
                model.refresh()
                try check(
                    waitUntil {
                        !model.errors.contains { $0.contains("ownership probe unavailable") }
                    },
                    "test11_app_refresh_didNotClearResolvedRecorderDiagnostic"
                )
                print("APP HARNESS test11_recorderDiagnosticClearing PASS")

                let noPathJob = makeJob(
                    id: "cron:no-path",
                    environment: [:],
                    command: ["/bin/sh", "-c", "gui-only-command"]
                )
                let noPathEnvironment = model.runEnvironment(for: noPathJob)
                try check(noPathEnvironment["PATH"] == "/usr/bin:/bin", "cron PATH inherited from GUI")
                try check(noPathEnvironment["GUI_ONLY_VARIABLE"] == nil, "GUI variable leaked into Run Now")
                model.runNow(noPathJob)
                try check(
                    waitUntil {
                        model.actionMessages[noPathJob.id]?.contains("exit code 127") == true
                    },
                    "GUI-only command unexpectedly resolved without a crontab PATH"
                )

                let declaredPathJob = makeJob(
                    id: "cron:declared-path",
                    environment: ["PATH": "\(appOnlyBin.path):/usr/bin:/bin"],
                    command: ["/bin/sh", "-c", "gui-only-command"]
                )
                model.runNow(declaredPathJob)
                try check(
                    waitUntil {
                        model.actionMessages[declaredPathJob.id]?.contains("exit code 0") == true
                    },
                    "declared crontab PATH did not override the scheduler default"
                )

                let asynchronousJob = makeJob(
                    id: "cron:asynchronous",
                    environment: [:],
                    command: ["/bin/sh", "-c", "sleep 0.5"]
                )
                let callStarted = Date()
                model.runNow(asynchronousJob)
                try check(
                    Date().timeIntervalSince(callStarted) < 0.2,
                    "Run Now blocked on process completion"
                )
                try check(
                    waitUntil {
                        model.actionMessages[asynchronousJob.id]?.contains("exit code 0") == true
                    },
                    "asynchronous Run Now completion was not published"
                )

                let argv0Output = root.appendingPathComponent("observed-argv0.txt")
                let argv0Job = makeJob(
                    id: "launchd:argv0",
                    source: .launchd,
                    environment: [:],
                    command: [harnessPath, "--capture-argv0", argv0Output.path],
                    argv0: "nightly-shell"
                )
                model.runNow(argv0Job)
                try check(
                    waitUntil {
                        model.actionMessages[argv0Job.id]?.contains("exit code 0") == true
                    },
                    "Run Now with explicit argv0 did not finish"
                )
                let observedArgv0 = try String(contentsOf: argv0Output, encoding: .utf8)
                try check(observedArgv0 == "nightly-shell", "Run Now discarded launchd's explicit argv0")

                let claudeJob = makeJob(
                    id: "claude:disabled",
                    source: .claudeRoutine,
                    environment: [:],
                    command: []
                )
                let claudeRunNow = JobRunNowPresentation(job: claudeJob, busy: false)
                try check(!claudeRunNow.isEnabled, "Claude Run Now presentation was enabled")
                try check(
                    claudeRunNow.disabledTitle == "Claude routines cannot run from Ticker",
                    "Claude Run Now disabled title changed"
                )
                try check(
                    claudeRunNow.disabledDetail
                        == "Ticker observes Claude routines but cannot faithfully re-run them. Trigger this routine from Claude.",
                    "Claude Run Now explanation changed"
                )

                let protectedLaunchdJob = makeJob(
                    id: "launchd:test5-protected",
                    source: .launchd,
                    environment: [:],
                    command: ["/usr/bin/true"],
                    runNowUnavailableReason: "test5 scheduled identity differs"
                )
                let protectedRunNow = JobRunNowPresentation(
                    job: protectedLaunchdJob,
                    busy: false
                )
                try check(!protectedRunNow.isEnabled, "test5_identityMismatch_disablesRunNowInUI")
                try check(
                    protectedRunNow.disabledTitle == "Run Now is unavailable",
                    "test5_identityMismatch_usesRunNowDisabledTitle"
                )
                try check(
                    protectedRunNow.disabledDetail == "test5 scheduled identity differs",
                    "test5_identityMismatch_surfacesExactReasonInUI"
                )
                let busyRunNow = JobRunNowPresentation(job: declaredPathJob, busy: true)
                try check(!busyRunNow.isEnabled, "busy Run Now presentation was enabled")

                let identityOriginalDirectory = root.appendingPathComponent(
                    "identity-original",
                    isDirectory: true
                )
                let identityMovedDirectory = root.appendingPathComponent(
                    "identity-moved",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: identityOriginalDirectory,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: identityMovedDirectory,
                    withIntermediateDirectories: true
                )
                let identityOriginalURL = identityOriginalDirectory.appendingPathComponent("job.plist")
                let identityMovedURL = identityMovedDirectory.appendingPathComponent("job.plist")
                let identityLabel = "com.example.test9.app-route"
                let identityPlist = try PropertyListSerialization.data(
                    fromPropertyList: [
                        "Label": identityLabel,
                        "ProgramArguments": ["/usr/bin/true"],
                    ],
                    format: .xml,
                    options: 0
                )
                try identityPlist.write(to: identityOriginalURL)
                func identityID(_ url: URL) -> String {
                    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                    let digest = SHA256.hash(data: Data(path.utf8))
                        .map { String(format: "%02x", $0) }
                        .joined()
                    return "launchd:\(identityLabel)#\(digest.prefix(12))"
                }
                func identityJob(id: String, url: URL, managed: Bool) -> Job {
                    Job(
                        id: id,
                        source: .launchd,
                        label: identityLabel,
                        schedule: .onDemand,
                        command: ["/usr/bin/true"],
                        cwd: nil,
                        enabled: true,
                        configPath: url.path,
                        lastKnownExit: nil,
                        lastRunAt: nil,
                        lastScheduledFor: nil,
                        managed: managed
                    )
                }
                let identityStore = try SQLiteRunStore(
                    path: root.appendingPathComponent("identity.sqlite").path
                )
                let identityWrapper = JobWrapper(
                    store: identityStore,
                    backupDirectory: root.appendingPathComponent("identity-backups", isDirectory: true)
                )
                let identityOldID = identityID(identityOriginalURL)
                let identityOldJob = identityJob(
                    id: identityOldID,
                    url: identityOriginalURL,
                    managed: false
                )
                _ = try identityWrapper.wrap(job: identityOldJob, tickerPath: ticker.path)
                let identityFirstRun = try identityStore.beginRun(
                    jobID: identityOldID,
                    startedAt: Date(timeIntervalSince1970: 2_000)
                )
                try identityStore.finishRun(
                    id: identityFirstRun,
                    exitCode: 0,
                    stdoutTail: "",
                    stderrTail: "",
                    finishedAt: Date(timeIntervalSince1970: 2_001)
                )
                try FileManager.default.moveItem(at: identityOriginalURL, to: identityMovedURL)
                let identityCurrentID = identityID(identityMovedURL)
                let identityCurrentJob = identityJob(
                    id: identityCurrentID,
                    url: identityMovedURL,
                    managed: true
                )
                let identityModel = AppModel(
                    registry: JobRegistry(
                        adapters: [StaticAdapter(source: .launchd, jobs: [identityCurrentJob])]
                    ),
                    store: identityStore,
                    wrapper: identityWrapper,
                    tickerPathOverride: ticker.path
                )
                identityModel.refresh()
                try check(
                    waitUntil {
                        identityModel.recoveryState(for: identityCurrentJob)
                            == .identityChanged(previousJobID: identityOldID)
                    },
                    "test9 app route did not publish identity-changed recovery"
                )
                try check(
                    identityModel.wrappingButtonTitle(for: identityCurrentJob)
                        == "Reconcile history identity",
                    "test9 app route offered unwrap before identity reconciliation"
                )
                identityModel.toggleWrapping(identityCurrentJob)
                try check(
                    waitUntil {
                        identityModel.actionMessages[identityCurrentID]?.contains("Reconciled") == true
                    },
                    "test9 app route did not reconcile identity"
                )
                let reconciledPlist = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: identityMovedURL),
                    options: [],
                    format: nil
                ) as? [String: Any]
                let reconciledArguments = reconciledPlist?["ProgramArguments"] as? [String]
                try check(
                    reconciledArguments.flatMap(LaunchdWrapper.decode)?.label == identityCurrentID,
                    "test9 app route did not rewrite the embedded identity"
                )
                let lateOldRun = try identityStore.beginRun(
                    jobID: identityOldID,
                    startedAt: Date(timeIntervalSince1970: 3_000)
                )
                try identityStore.finishRun(
                    id: lateOldRun,
                    exitCode: 1,
                    stdoutTail: "",
                    stderrTail: "",
                    finishedAt: Date(timeIntervalSince1970: 3_001)
                )
                let identityRunJobIDs = try identityStore.runs(
                    jobID: identityCurrentID,
                    limit: 10
                ).map(\.jobID)
                try check(
                    identityRunJobIDs == [identityCurrentID, identityCurrentID],
                    "test9 late old-id run did not land on the current identity"
                )
                print("APP HARNESS test9_identityRecoveryRoute PASS")

                let nextFireLabels = [
                    JobNextFirePresentation.relativeText(for: .keepAlive, nextFire: nil),
                    JobNextFirePresentation.relativeText(for: .atLoad, nextFire: nil),
                    JobNextFirePresentation.relativeText(
                        for: .watchPaths(["/tmp/watch"]),
                        nextFire: nil
                    ),
                    JobNextFirePresentation.relativeText(
                        for: .queueDirectories(["/tmp/queue"]),
                        nextFire: nil
                    ),
                    JobNextFirePresentation.relativeText(for: .onDemand, nextFire: nil),
                ]
                try check(
                    nextFireLabels.allSatisfy { $0 == nil },
                    "test13_nonTemporalSchedules_omitDuplicateNextFireText"
                )
                try check(
                    nextFireLabels.compactMap { $0 }.isEmpty,
                    "test13_nonTemporalSchedules_haveNoSecondLineValue"
                )

                let recentRunsNewestFirst = [
                    Run(
                        id: 104,
                        jobID: "launchd:history-presentation",
                        startedAt: Date(timeIntervalSince1970: 400),
                        finishedAt: Date(timeIntervalSince1970: 410),
                        exitCode: 9,
                        stdoutTail: "partial output",
                        stderrTail: "failed"
                    ),
                    Run(
                        id: 103,
                        jobID: "launchd:history-presentation",
                        startedAt: Date(timeIntervalSince1970: 300),
                        finishedAt: Date(timeIntervalSince1970: 305),
                        exitCode: nil,
                        stdoutTail: nil,
                        stderrTail: nil
                    ),
                    Run(
                        id: 102,
                        jobID: "launchd:history-presentation",
                        startedAt: Date(timeIntervalSince1970: 200),
                        finishedAt: nil,
                        exitCode: nil,
                        stdoutTail: nil,
                        stderrTail: nil
                    ),
                    Run(
                        id: 101,
                        jobID: "launchd:history-presentation",
                        startedAt: Date(timeIntervalSince1970: 100),
                        finishedAt: Date(timeIntervalSince1970: 104),
                        exitCode: 0,
                        stdoutTail: "done",
                        stderrTail: ""
                    ),
                ]
                let historyCells = JobRunHistoryPresentation.cells(
                    from: recentRunsNewestFirst
                )
                try check(
                    historyCells.map(\.id) == [101, 102, 103, 104],
                    "test13_recentHistory_ordersOldestToNewest"
                )
                try check(
                    historyCells.map(\.statusText)
                        == ["Succeeded", "Running", "Unknown result", "Failed"],
                    "test13_recentHistory_mapsEveryOutcome"
                )
                try check(
                    Set(historyCells.map(\.symbolName)).count == 4,
                    "test13_recentHistory_usesDistinctOutcomeShapes"
                )
                try check(
                    historyCells.last?.accessibilityLabel
                        == "Recent run 4 of 4: Failed, exit code 9",
                    "test13_recentHistory_failureHasNonColorAccessibilityLabel"
                )
                try check(
                    JobRunHistoryPresentation.cells(
                        from: recentRunsNewestFirst,
                        limit: 2
                    ).map(\.id) == [103, 104],
                    "test13_recentHistory_limitsToNewestRecords"
                )
                if let failedCell = historyCells.last {
                    try check(
                        JobRunHistoryPresentation.selection(
                            jobID: "launchd:history-presentation",
                            cell: failedCell
                        ) == JobRunSelection(
                            jobID: "launchd:history-presentation",
                            runID: 104
                        ),
                        "test13_failedHistoryCell_selectsItsJobAndRun"
                    )
                } else {
                    try check(false, "test13_failedHistoryCell_exists")
                }

                var navigationState = JobRunNavigationState()
                navigationState.selectJob("launchd:history-presentation")
                try check(
                    navigationState.selectedJobID == "launchd:history-presentation"
                        && navigationState.selectedRunID(
                            for: "launchd:history-presentation"
                        ) == nil,
                    "test13_jobSelection_opensJobDetailsWithoutAStaleRun"
                )
                if let failedCell = historyCells.last {
                    let failedSelection = JobRunHistoryPresentation.selection(
                        jobID: "launchd:history-presentation",
                        cell: failedCell
                    )
                    navigationState.selectRun(failedSelection)
                    try check(
                        navigationState.selectedJobID == failedSelection.jobID
                            && navigationState.selectedRunID(for: failedSelection.jobID)
                                == failedSelection.runID
                            && navigationState.selectedRun(
                                for: failedSelection.jobID,
                                in: recentRunsNewestFirst
                            )?.id == failedSelection.runID,
                        "test13_historyCellClick_resolvesExactRunInspector"
                    )
                }

                let originalWindow = stride(
                    from: Int64(20),
                    through: Int64(1),
                    by: Int(-1)
                ).map { id in
                    Run(
                        id: id,
                        jobID: "launchd:shifted-history",
                        startedAt: Date(timeIntervalSince1970: TimeInterval(id)),
                        finishedAt: Date(timeIntervalSince1970: TimeInterval(id + 1)),
                        exitCode: 0,
                        stdoutTail: "run \(id)",
                        stderrTail: ""
                    )
                }
                let shiftedWindow = stride(
                    from: Int64(21),
                    through: Int64(2),
                    by: Int(-1)
                ).map { id in
                    Run(
                        id: id,
                        jobID: "launchd:shifted-history",
                        startedAt: Date(timeIntervalSince1970: TimeInterval(id)),
                        finishedAt: Date(timeIntervalSince1970: TimeInterval(id + 1)),
                        exitCode: 0,
                        stdoutTail: "run \(id)",
                        stderrTail: ""
                    )
                }
                navigationState.selectRun(
                    JobRunSelection(jobID: "launchd:shifted-history", runID: 1)
                )
                try check(
                    navigationState.selectedRun(
                        for: "launchd:shifted-history",
                        in: originalWindow
                    )?.id == 1,
                    "test13_historyWindow_selectsOldestVisibleRun"
                )
                navigationState.reconcileRuns(
                    for: "launchd:shifted-history",
                    with: shiftedWindow
                )
                try check(
                    navigationState.selectedRunID(for: "launchd:shifted-history") == 21
                        && navigationState.selectedRun(
                            for: "launchd:shifted-history",
                            in: shiftedWindow
                        )?.id == 21,
                    "test13_shiftedHistoryWindow_selectsNewestReplacement"
                )
                navigationState.reconcileRuns(for: "launchd:shifted-history", with: [])
                try check(
                    navigationState.selectedJobID == "launchd:shifted-history"
                        && navigationState.selectedRunID(for: "launchd:shifted-history") == nil,
                    "test13_emptyReplacementWindow_clearsRunButKeepsVisibleJob"
                )
                navigationState.reconcileJobs([])
                try check(
                    navigationState.selectedJobID == nil,
                    "test13_removedJob_returnsToCompactJobList"
                )

                var historyLoadState = JobHistoryLoadState.idle
                historyLoadState = historyLoadState.reducing(.requested)
                try check(
                    historyLoadState == .loading,
                    "test13_historyLoad_requestShowsLoading"
                )
                historyLoadState = historyLoadState.reducing(.succeeded)
                try check(
                    historyLoadState == .loaded,
                    "test13_historyLoad_successShowsLoaded"
                )
                historyLoadState = historyLoadState.reducing(.requested)
                historyLoadState = historyLoadState.reducing(.failed("database unavailable"))
                try check(
                    historyLoadState == .failed("database unavailable"),
                    "test13_historyLoad_failurePreservesError"
                )

                var historyLoadGenerations = JobHistoryLoadGenerationCoordinator()
                let requestA = historyLoadGenerations.begin(for: "launchd:overlapping-history")
                let requestB = historyLoadGenerations.begin(for: "launchd:overlapping-history")
                try check(
                    historyLoadGenerations.eventIfCurrent(
                        .succeeded,
                        for: "launchd:overlapping-history",
                        generation: requestA
                    ) == nil,
                    "test13_overlappingHistoryLoad_supersededSuccessCannotPublish"
                )
                try check(
                    historyLoadGenerations.eventIfCurrent(
                        .failed("stale database failure"),
                        for: "launchd:overlapping-history",
                        generation: requestA
                    ) == nil,
                    "test13_overlappingHistoryLoad_supersededFailureCannotPublish"
                )
                try check(
                    historyLoadGenerations.eventIfCurrent(
                        .succeeded,
                        for: "launchd:overlapping-history",
                        generation: requestB
                    ) == .succeeded,
                    "test13_overlappingHistoryLoad_newestRequestCanPublish"
                )

                let refreshHistoryJob = makeJob(
                    id: "cron:refresh-history",
                    environment: [:],
                    command: ["/usr/bin/true"]
                )
                let refreshHistoryStore = try SQLiteRunStore(
                    path: root.appendingPathComponent("refresh-history.sqlite").path
                )
                let refreshHistoryModel = AppModel(
                    registry: JobRegistry(
                        adapters: [
                            StaticAdapter(source: .crontab, jobs: [refreshHistoryJob]),
                        ]
                    ),
                    store: refreshHistoryStore
                )
                let initialRefreshRunID = try refreshHistoryStore.beginRun(
                    jobID: refreshHistoryJob.id,
                    startedAt: Date(timeIntervalSince1970: 1_000)
                )
                try refreshHistoryStore.finishRun(
                    id: initialRefreshRunID,
                    exitCode: 0,
                    stdoutTail: "initial",
                    stderrTail: "",
                    finishedAt: Date(timeIntervalSince1970: 1_001)
                )
                refreshHistoryModel.loadRuns(for: refreshHistoryJob)
                try check(
                    waitUntil {
                        refreshHistoryModel.runsByJob[refreshHistoryJob.id]?.map(\.id)
                            == [initialRefreshRunID]
                    },
                    "test16 initial visible history did not load"
                )
                var stableRefreshSelection = JobRunNavigationState()
                stableRefreshSelection.selectRun(
                    JobRunSelection(
                        jobID: refreshHistoryJob.id,
                        runID: initialRefreshRunID
                    )
                )
                let newlyInsertedRunID = try refreshHistoryStore.beginRun(
                    jobID: refreshHistoryJob.id,
                    startedAt: Date(timeIntervalSince1970: 2_000)
                )
                try refreshHistoryStore.finishRun(
                    id: newlyInsertedRunID,
                    exitCode: 0,
                    stdoutTail: "new",
                    stderrTail: "",
                    finishedAt: Date(timeIntervalSince1970: 2_001)
                )
                refreshHistoryModel.refresh()
                try check(
                    waitUntil {
                        refreshHistoryModel.runsByJob[refreshHistoryJob.id]?.map(\.id)
                            == [newlyInsertedRunID, initialRefreshRunID]
                    },
                    "test16 model refresh did not reload the existing history window"
                )
                let refreshedWindow = refreshHistoryModel.runsByJob[refreshHistoryJob.id] ?? []
                stableRefreshSelection.reconcileRuns(
                    for: refreshHistoryJob.id,
                    with: refreshedWindow
                )
                try check(
                    stableRefreshSelection.selectedRunID(for: refreshHistoryJob.id)
                        == initialRefreshRunID,
                    "test16 history refresh discarded a selected run still in the window"
                )
                print("APP HARNESS test16_denseHistoryRefresh PASS")

                try check(
                    JobDisplayName.candidate(for: "com.skyvern.daily-summary") == "Daily summary",
                    "test13_displayName_humanizesSafeFinalComponent"
                )
                try check(
                    JobDisplayName.candidate(for: "com.bjango.istatmenus.fans")
                        == "com.bjango.istatmenus.fans",
                    "test13_displayName_preservesLossySingleComponentLabel"
                )
                let duplicateUser = Job(
                    id: "launchd:cyolo-user",
                    source: .launchd,
                    provenance: .app("Cyolo"),
                    label: "Cyolo",
                    schedule: .atLoad,
                    command: ["open", "/Applications/Cyolo.app"],
                    cwd: nil,
                    enabled: true,
                    configPath: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/LaunchAgents/Cyolo.plist").path,
                    lastKnownExit: nil,
                    lastRunAt: nil,
                    lastScheduledFor: nil,
                    managed: false
                )
                let duplicateLocal = Job(
                    id: "launchd:cyolo-local",
                    source: .launchd,
                    provenance: .app("Cyolo"),
                    label: "Cyolo",
                    schedule: .keepAlive,
                    command: ["/Library/Application Support/cyolo/connect/connect"],
                    cwd: nil,
                    enabled: true,
                    configPath: "/Library/LaunchAgents/Cyolo.plist",
                    lastKnownExit: nil,
                    lastRunAt: nil,
                    lastScheduledFor: nil,
                    managed: false
                )
                try check(
                    JobDisplayName.disambiguated(
                        for: duplicateUser,
                        among: [duplicateUser, duplicateLocal]
                    ) == "Cyolo — User"
                        && JobDisplayName.disambiguated(
                            for: duplicateLocal,
                            among: [duplicateUser, duplicateLocal]
                        ) == "Cyolo — Local",
                    "test13_displayName_disambiguatesIdenticalLabelsWithinGroup"
                )

                let duplicateUserA = Job(
                    id: "launchd:duplicate-user#a11111",
                    source: .launchd,
                    provenance: .yours,
                    label: "com.example.same-label",
                    schedule: .onDemand,
                    command: ["/usr/bin/true"],
                    cwd: nil,
                    enabled: true,
                    configPath: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/LaunchAgents/first.plist").path,
                    lastKnownExit: nil,
                    lastRunAt: nil,
                    lastScheduledFor: nil,
                    managed: false
                )
                let duplicateUserB = Job(
                    id: "launchd:duplicate-user#b22222",
                    source: .launchd,
                    provenance: .yours,
                    label: "com.example.same-label",
                    schedule: .onDemand,
                    command: ["/usr/bin/true"],
                    cwd: nil,
                    enabled: true,
                    configPath: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/LaunchAgents/second.plist").path,
                    lastKnownExit: nil,
                    lastRunAt: nil,
                    lastScheduledFor: nil,
                    managed: false
                )
                try check(
                    JobDisplayName.disambiguated(
                        for: duplicateUserA,
                        among: [duplicateUserA, duplicateUserB]
                    ) != JobDisplayName.disambiguated(
                        for: duplicateUserB,
                        among: [duplicateUserA, duplicateUserB]
                    ),
                    "test14_displayName_sameLocationCollision_remainsUnique"
                )

                let vendorFailure = makeJob(
                    id: "launchd:vendor-failure",
                    source: .launchd,
                    provenance: .app("Vendor"),
                    environment: [:],
                    command: ["/Applications/Vendor.app/Contents/MacOS/Vendor"],
                    lastKnownExit: ExitStatus(raw: 1)
                )
                model.jobs = [vendorFailure]
                try check(
                    !model.hasUrgentAttentionOwnedJobs,
                    "test13_vendorFailure_doesNotSetUrgentMenuBarState"
                )
                let missingPayload = "/tmp/test13-gone.sh"
                let ownerFailure = makeJob(
                    id: "launchd:owner-missing",
                    source: .launchd,
                    provenance: .yours,
                    attention: .missingPayload(missingPayload),
                    environment: [:],
                    command: ["/bin/sh", missingPayload],
                    enabled: false
                )
                model.jobs = [ownerFailure]
                try check(
                    model.hasUrgentAttentionOwnedJobs,
                    "test13_ownerMissingPayload_setsUrgentMenuBarState"
                )
                let unknownFailure = makeJob(
                    id: "launchd:unknown-missing",
                    source: .launchd,
                    provenance: .unknown("no third-party proof"),
                    attention: .missingPayload("/usr/local/bin/missing-user-tool"),
                    environment: [:],
                    command: ["/usr/local/bin/missing-user-tool"],
                    enabled: false
                )
                model.jobs = [unknownFailure]
                try check(
                    model.hasUrgentAttentionOwnedJobs,
                    "test14_unattributedBrokenJob_setsUrgentMenuBarState"
                )

                try check(
                    FailureNotificationController.shouldUseLegacyFallback(
                        isAdHocBuild: true,
                        modernAuthorizationRequested: false
                    ),
                    "test17_adHocBuildWithoutPrompt_usesLegacyNotificationFallback"
                )
                try check(
                    !FailureNotificationController.shouldUseLegacyFallback(
                        isAdHocBuild: true,
                        modernAuthorizationRequested: true
                    ),
                    "test17_explicitModernDenial_disablesLegacyNotificationFallback"
                )
                try check(
                    !FailureNotificationController.shouldUseLegacyFallback(
                        isAdHocBuild: false,
                        modernAuthorizationRequested: false
                    ),
                    "test17_signedBuildNeverUsesLegacyNotificationFallback"
                )

                let ambiguousJob = Job(
                    id: "launchd:ambiguous-disabled#111111111111",
                    source: .launchd,
                    provenance: .yours,
                    label: "ambiguous-disabled",
                    schedule: .onDemand,
                    command: ["/usr/bin/true"],
                    cwd: nil,
                    enabled: false,
                    runtimeStatusAttribution: .ambiguous,
                    configPath: nil,
                    lastKnownExit: nil,
                    lastRunAt: nil,
                    lastScheduledFor: nil,
                    managed: false
                )
                let notificationRecorder = RecordingFailureNotifier()
                let ambiguousModel = AppModel(
                    registry: JobRegistry(
                        adapters: [
                            StaticAdapter(source: .launchd, jobs: [ambiguousJob]),
                        ]
                    ),
                    store: store,
                    failureNotifier: notificationRecorder
                )
                ambiguousModel.refresh()
                try check(
                    waitUntil {
                        notificationRecorder.candidates.contains {
                            $0.incidentID
                                == AttentionIncidentID(
                                    jobID: ambiguousJob.id,
                                    kind: .ambiguousRuntime
                                )
                        }
                    },
                    "test17_disabledAmbiguousRuntime_producesNotificationCandidate"
                )
                try check(
                    ambiguousModel.needsAttention(ambiguousJob),
                    "test17_disabledAmbiguousRuntime_setsUrgentState"
                )
                print("APP HARNESS test17_disabledAmbiguousRuntimeNotification PASS")

                let encodedFailureJob = Job(
                    id: "launchd:encoded-failure#222222222222",
                    source: .launchd,
                    provenance: .yours,
                    label: "encoded-failure",
                    schedule: .onDemand,
                    command: ["/usr/bin/false"],
                    cwd: nil,
                    enabled: true,
                    runtimeStatusAttribution: .resolved,
                    configPath: nil,
                    lastKnownExit: ExitStatus(raw: 32_512),
                    lastRunAt: nil,
                    lastScheduledFor: nil,
                    managed: false
                )
                let encodedFailureRecorder = RecordingFailureNotifier()
                let encodedFailureModel = AppModel(
                    registry: JobRegistry(
                        adapters: [
                            StaticAdapter(source: .launchd, jobs: [encodedFailureJob]),
                        ]
                    ),
                    store: store,
                    failureNotifier: encodedFailureRecorder
                )
                encodedFailureModel.refresh()
                try check(
                    waitUntil {
                        encodedFailureRecorder.candidates.contains {
                            $0.incidentID.kind == .failedRun
                                && $0.reason.contains("exit code 127")
                                && !$0.reason.contains("32512")
                        }
                    },
                    "test17_encodedLaunchdStatus_reportsDecodedExitCode"
                )
                print("APP HARNESS test17_encodedLaunchdExitNotification PASS")

                print("APP HARNESS PASS")
            }

            @MainActor
            private static func waitUntil(
                timeout: TimeInterval = 4,
                _ condition: () -> Bool
            ) -> Bool {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if condition() {
                        return true
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                return condition()
            }

            private static func makeJob(
                id: String,
                source: JobSource = .crontab,
                provenance: JobProvenance? = nil,
                attention: JobAttention? = nil,
                label: String? = nil,
                environment: [String: String],
                command: [String],
                argv0: String? = nil,
                runNowUnavailableReason: String? = nil,
                lastKnownExit: ExitStatus? = nil,
                enabled: Bool = true
            ) -> Job {
                Job(
                    id: id,
                    source: source,
                    provenance: provenance,
                    attention: attention,
                    label: label ?? id,
                    schedule: .cron("* * * * *"),
                    command: command,
                    argv0: argv0,
                    environment: environment,
                    cwd: nil,
                    enabled: enabled,
                    runNowUnavailableReason: runNowUnavailableReason,
                    configPath: nil,
                    lastKnownExit: lastKnownExit,
                    lastRunAt: nil,
                    lastScheduledFor: nil,
                    managed: false
                )
            }
        }
        """#
        let harnessSourceURL = buildDirectory.appendingPathComponent("AppBehaviorHarness.swift")
        try harnessSource.write(to: harnessSourceURL, atomically: true, encoding: .utf8)
        let harnessExecutable = buildDirectory.appendingPathComponent("AppBehaviorHarness").path
        let appSources = [
            repository.appendingPathComponent("Sources/TickerApp/AppModel.swift").path,
            repository.appendingPathComponent("Sources/TickerApp/FailureNotificationController.swift").path,
            repository.appendingPathComponent("Sources/TickerApp/JobListView.swift").path,
            repository.appendingPathComponent("Sources/TickerApp/JobDetailView.swift").path,
            harnessSourceURL.path,
        ]
        try test3B_runProcess(
            swiftc,
            [
                "-module-cache-path", moduleCachePath,
                "-target", "arm64-apple-macosx13.0",
                "-D", "TICKER_TESTING",
                "-parse-as-library",
                "-I", buildDirectory.path,
                "-L", buildDirectory.path,
                "-lTickerCore",
                "-lsqlite3",
                "-o", harnessExecutable,
            ] + appSources,
            currentDirectory: repository
        )
        let output = try test3B_runProcess(
            harnessExecutable,
            [],
            currentDirectory: repository
        )
        tests.expect(
            output.contains("APP HARNESS PASS"),
            "test4B compiled app harness covers argv0 execution, Run Now presentation, refresh, and environment"
        )
        tests.expect(
            output.contains("APP HARNESS test9_identityRecoveryRoute PASS"),
            "test9_appRoute_reconcilesIdentityBeforeUnwrapAndAcceptsLateOldRuns"
        )
        tests.expect(
            output.contains("APP HARNESS test11_recorderDiagnosticClearing PASS"),
            "test11_appRefresh_removesResolvedRecorderDiagnostic"
        )
        tests.expect(
            output.contains("APP HARNESS test16_denseHistoryRefresh PASS"),
            "test16_existingDenseHistory_refreshesWithoutRecreatingModelOrSelection"
        )
    }
}

// End round 3B regression tests


private func test4A_BackupAuthenticity(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round4a-backup-authenticity") { directory in
        let plistURL = directory.appendingPathComponent("authenticated.plist")
        try writePropertyList([
            "Label": "com.example.authenticated",
            "ProgramArguments": ["/bin/echo", "original"],
            "KeepAlive": true,
        ], to: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.authenticated#0123456789ab",
            label: "com.example.authenticated",
            command: ["/bin/echo", "original"],
            plistURL: plistURL
        )

        _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
        let wrappedData = try Data(contentsOf: plistURL)
        let backupPath = try require(
            try store.managedBackupPath(jobID: job.id),
            "test4A authenticated backup path"
        )
        let backupURL = URL(fileURLWithPath: backupPath)
        try Data("unrelated backup bytes".utf8).write(to: backupURL)

        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .wrappedBackupContentMismatch,
            "test4A doctor state reports backup content mismatch"
        )
        tests.expectThrows(
            try wrapper.unwrap(job: job),
            "test4A unwrap refuses a backup whose authenticated bytes changed"
        )
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            wrappedData,
            "test4A refused mismatched restore leaves the live plist unchanged"
        )

    }
}

private func test4A_BlockedParentCapture(_ tests: TestHarness) throws {
    let tickerPath = try test3A_builtCLIPath()
    try withTemporaryDirectory("round4a-blocked-parent") { directory in
        let storePath = test10_compiledStorePath()
        test10_removeStore(at: storePath)
        defer { test10_removeStore(at: storePath) }
        let store = try SQLiteRunStore(path: storePath)
        let fakeLaunchctl = try test10_fakeLaunchctl(in: directory)
        let invocation = try test10_wrappedInvocation(
            directory: directory,
            label: "com.example.test4A.blocked-parent",
            command: [
                "/usr/bin/awk",
                "BEGIN { for (i = 0; i < 300000; i++) printf \"x\"; printf \"TAIL-4A\\n\" }",
            ],
            tickerPath: tickerPath,
            store: store
        )
        let process = Process()
        let blockedOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: tickerPath)
        var processArguments = Array(invocation.arguments.dropFirst())
        processArguments.insert(
            contentsOf: ["--tail-bytes", "64"],
            at: try require(processArguments.firstIndex(of: "--"), "test4A wrapper separator")
        )
        process.arguments = processArguments
        var environment = ProcessInfo.processInfo.environment
        environment["TICKER_TEST_LAUNCHCTL_PATH"] = fakeLaunchctl.path
        environment["TICKER_TEST_LAUNCHD_DIRECTORIES"] = directory.path
        process.environment = environment
        process.standardOutput = blockedOutput
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let timedOut = exited.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        try? blockedOutput.fileHandleForReading.close()

        let stored = try require(
            try store.latestRun(jobID: invocation.job.id),
            "test4A blocked-parent run row"
        )
        print(
            "TRANSCRIPT test4A N-013 status=\(process.terminationStatus) "
                + "timedOut=\(timedOut) tail='\(stored.stdoutTail ?? "nil")'"
        )
        tests.expect(!timedOut, "test4A blocked parent output does not stall child capture")
        tests.expectEqual(process.terminationStatus, 0, "test4A blocked-parent child exits successfully")
        tests.expect(
            stored.stdoutTail?.hasSuffix("TAIL-4A\n") == true,
            "test4A blocked-parent history keeps the newest captured bytes"
        )
    }
}

private func test4A_SignalReapingStress(_ tests: TestHarness) throws {
    let tickerPath = try test3A_builtCLIPath()
    try withTemporaryDirectory("round4a-signal-stress") { directory in
        let storePath = test10_compiledStorePath()
        test10_removeStore(at: storePath)
        defer { test10_removeStore(at: storePath) }
        let store = try SQLiteRunStore(path: storePath)
        let fakeLaunchctl = try test10_fakeLaunchctl(in: directory)
        var unexpectedStatuses: [Int32] = []
        var unfinishedRows = 0
        let iterations = 50

        for iteration in 0..<iterations {
            let jobDirectory = directory.appendingPathComponent(
                "job-\(iteration)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: jobDirectory,
                withIntermediateDirectories: true
            )
            let readyURL = directory.appendingPathComponent("ready-\(iteration)")
            let invocation = try test10_wrappedInvocation(
                directory: jobDirectory,
                label: "com.example.test4A.signal-\(iteration)",
                command: [
                    "/bin/sh", "-c", "printf ready > '\(readyURL.path)'",
                ],
                tickerPath: tickerPath,
                store: store
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tickerPath)
            process.arguments = Array(invocation.arguments.dropFirst())
            var environment = ProcessInfo.processInfo.environment
            environment["TICKER_TEST_LAUNCHCTL_PATH"] = fakeLaunchctl.path
            environment["TICKER_TEST_LAUNCHD_DIRECTORIES"] = jobDirectory.path
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            let readyDeadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: readyURL.path),
                  process.isRunning,
                  Date() < readyDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
            process.waitUntilExit()
            if process.terminationStatus != 0 && process.terminationStatus != 143 {
                unexpectedStatuses.append(process.terminationStatus)
            }

            let row = try store.latestRun(jobID: invocation.job.id)
            if row?.finishedAt == nil || (row?.exitCode != 0 && row?.exitCode != 143) {
                unfinishedRows += 1
            }
        }

        print(
            "TRANSCRIPT test4A N-014 iterations=\(iterations) "
                + "unexpectedStatuses=\(unexpectedStatuses) unfinishedRows=\(unfinishedRows)"
        )
        tests.expectEqual(
            unexpectedStatuses,
            [],
            "test4A signal/reap stress produces no unrelated or wrapper-level signal exits"
        )
        tests.expectEqual(
            unfinishedRows,
            0,
            "test4A signal/reap stress records every short-lived child exactly to completion"
        )
    }
}

private final class test5_StaticAdapter: JobSourceAdapter {
    let source: JobSource
    private let jobs: [Job]

    init(source: JobSource, jobs: [Job]) {
        self.source = source
        self.jobs = jobs
    }

    func discover() throws -> [Job] {
        jobs
    }
}

private func test5_makeJob(
    id: String,
    source: JobSource = .launchd,
    label: String? = nil,
    command: [String] = ["/usr/bin/true"],
    cwd: String? = nil,
    lastKnownExit: ExitStatus? = nil,
    nativeStatusObservedAt: Date? = nil,
    launchdProcessID: Int32? = nil,
    launchdRunCount: Int64? = nil,
    launchdDomain: LaunchdDomain? = nil,
    configPath: String? = nil,
    managed: Bool = false
) -> Job {
    Job(
        id: id,
        source: source,
        label: label ?? id,
        schedule: .onDemand,
        command: command,
        cwd: cwd,
        enabled: true,
        launchdDomain: launchdDomain,
        configPath: configPath,
        lastKnownExit: lastKnownExit,
        nativeStatusObservedAt: nativeStatusObservedAt,
        launchdProcessID: launchdProcessID,
        launchdRunCount: launchdRunCount,
        lastRunAt: nil,
        lastScheduledFor: nil,
        managed: managed
    )
}

private func test5_finish(
    store: SQLiteRunStore,
    jobID: String,
    trigger: RunTrigger,
    startedAt: Date,
    exitCode: Int32,
    context: RunStartContext? = nil
) throws -> Int64 {
    let id = try store.beginRun(
        jobID: jobID,
        startedAt: startedAt,
        trigger: trigger,
        context: context
    )
    try store.finishRun(
        id: id,
        exitCode: exitCode,
        stdoutTail: "",
        stderrTail: "",
        finishedAt: startedAt.addingTimeInterval(1)
    )
    return id
}

private func test5_HealthPrecedenceAndManualIsolation(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round5-health") { directory in
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("runs.db").path)

        let nativeFailureID = "launchd:test5-native-failure"
        _ = try test5_finish(
            store: store,
            jobID: nativeFailureID,
            trigger: .manual,
            startedAt: Date(timeIntervalSince1970: 100),
            exitCode: 0
        )
        let nativeFailure = test5_makeJob(
            id: nativeFailureID,
            lastKnownExit: ExitStatus(raw: 1)
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: nativeFailure,
                scheduledHistory: try store.scheduledHealthRuns()[nativeFailureID]
            ),
            .failure,
            "test5_successThenNativeFailure_usesNativeFailure"
        )

        let nativeSuccessID = "launchd:test5-native-success"
        _ = try test5_finish(
            store: store,
            jobID: nativeSuccessID,
            trigger: .manual,
            startedAt: Date(timeIntervalSince1970: 200),
            exitCode: 1
        )
        let nativeSuccess = test5_makeJob(
            id: nativeSuccessID,
            lastKnownExit: ExitStatus(raw: 0)
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: nativeSuccess,
                scheduledHistory: try store.scheduledHealthRuns()[nativeSuccessID]
            ),
            .success,
            "test5_failureThenNativeSuccess_usesNativeSuccess"
        )

        let manualIsolationID = "cron:test5-manual-isolation"
        _ = try test5_finish(
            store: store,
            jobID: manualIsolationID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 300),
            exitCode: 1
        )
        _ = try test5_finish(
            store: store,
            jobID: manualIsolationID,
            trigger: .manual,
            startedAt: Date(timeIntervalSince1970: 400),
            exitCode: 0
        )
        let cronJob = test5_makeJob(id: manualIsolationID, source: .crontab)
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: cronJob,
                scheduledHistory: try store.scheduledHealthRuns()[manualIsolationID]
            ),
            .failure,
            "test5_manualRun_neverChangesScheduledHealth"
        )
        tests.expectEqual(
            try store.runs(jobID: manualIsolationID, limit: 2).map(\.trigger),
            [.manual, .scheduled],
            "test5_manualRun_remainsVisibleAndLabeledInHistory"
        )

        let wrappedID = "launchd:test5-wrapped"
        _ = try test5_finish(
            store: store,
            jobID: wrappedID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 500),
            exitCode: 0
        )
        let wrappedJob = test5_makeJob(
            id: wrappedID,
            lastKnownExit: ExitStatus(raw: 1),
            nativeStatusObservedAt: Date(timeIntervalSince1970: 600),
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: wrappedJob,
                scheduledHistory: try store.scheduledHealthRuns()[wrappedID]
            ),
            .failure,
            "test5_wrappedJob_nativeFailureVetoesOlderScheduledSuccess"
        )
        _ = try store.beginRun(
            jobID: wrappedID,
            startedAt: Date(timeIntervalSince1970: 501),
            trigger: .scheduled,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: RunExecutionEvidence.currentBootSessionID(),
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: nil
            )
        )
        let wrappedRunningJob = test5_makeJob(
            id: wrappedID,
            lastKnownExit: ExitStatus(raw: 1),
            nativeStatusObservedAt: Date(timeIntervalSince1970: 600),
            launchdProcessID: getpid(),
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: wrappedRunningJob,
                scheduledHistory: try store.scheduledHealthRuns()[wrappedID]
            ),
            .running,
            "test5_wrappedInProgressRun_isNotHiddenByStaleNativeExit"
        )
    }
}

private func test8_WrappedHealthOrdering(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round8-wrapped-health") { directory in
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("runs.db").path)

        let cannotStartID = "launchd:test8-wrapper-cannot-start"
        _ = try test5_finish(
            store: store,
            jobID: cannotStartID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 10),
            exitCode: 0
        )
        let cannotStart = test5_makeJob(
            id: cannotStartID,
            lastKnownExit: ExitStatus(raw: 78),
            nativeStatusObservedAt: Date(timeIntervalSince1970: 20),
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: cannotStart,
                scheduledHistory: try store.scheduledHealthRuns()[cannotStartID]
            ),
            .failure,
            "test8_wrapperCannotStart_nativeFailureCannotRemainGreen"
        )

        let inProgressID = "launchd:test8-in-progress"
        _ = try test5_finish(
            store: store,
            jobID: inProgressID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 30),
            exitCode: 0
        )
        _ = try store.beginRun(
            jobID: inProgressID,
            startedAt: Date(timeIntervalSince1970: 41),
            trigger: .scheduled,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: RunExecutionEvidence.currentBootSessionID(),
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: 4
            )
        )
        let inProgress = test5_makeJob(
            id: inProgressID,
            lastKnownExit: ExitStatus(raw: 1),
            nativeStatusObservedAt: Date(timeIntervalSince1970: 40),
            launchdProcessID: getpid(),
            launchdRunCount: 4,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: inProgress,
                scheduledHistory: try store.scheduledHealthRuns()[inProgressID]
            ),
            .running,
            "test8_inProgressScheduledRun_doesNotFlapToPreviousNativeFailure"
        )

        let newerSuccessID = "launchd:test8-newer-success"
        _ = try test5_finish(
            store: store,
            jobID: newerSuccessID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 51),
            exitCode: 0,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: RunExecutionEvidence.currentBootSessionID(),
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: 8
            )
        )
        let newerSuccess = test5_makeJob(
            id: newerSuccessID,
            lastKnownExit: ExitStatus(raw: 1),
            nativeStatusObservedAt: Date(timeIntervalSince1970: 50),
            launchdRunCount: 8,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: newerSuccess,
                scheduledHistory: try store.scheduledHealthRuns()[newerSuccessID]
            ),
            .success,
            "test8_newerScheduledSuccess_overridesOlderNativeFailure"
        )
    }
}

private func test8_LaunchdRuntimeOrderingEvidence(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round8-launchd-observation") { directory in
        try writePropertyList([
            "Label": "com.example.test8.observed",
            "ProgramArguments": ["/usr/bin/true"],
        ], to: directory.appendingPathComponent("observed.plist"))
        let adapter = LaunchdAdapter(searchDirectories: [directory]) { _, _ in
            AdapterCommandResult(
                status: 0,
                stdout: "pid = 4321\nruns = 17\nlast exit code = 1\n",
                stderr: ""
            )
        }
        let job = try require(try adapter.discover().first, "test8 observed launchd job")
        tests.expectEqual(
            job.launchdProcessID,
            4321,
            "test8_launchdStatus_carriesServicePID"
        )
        tests.expectEqual(
            job.launchdRunCount,
            17,
            "test8_launchdStatus_carriesMonotonicRunCount"
        )
    }
}

private func test5_UnwrapResetsHealthWithoutDeletingHistory(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round5-unwrap") { directory in
        let plistURL = directory.appendingPathComponent("com.example.test5.plist")
        try writePropertyList(
            [
                "Label": "com.example.test5",
                "ProgramArguments": ["/usr/bin/true"],
            ],
            to: plistURL
        )
        let job = Job(
            id: "launchd:com.example.test5#555555555555",
            source: .launchd,
            label: "com.example.test5",
            schedule: .onDemand,
            command: ["/usr/bin/true"],
            cwd: nil,
            enabled: true,
            configPath: plistURL.path,
            lastKnownExit: nil,
            lastRunAt: nil,
            lastScheduledFor: nil,
            managed: false
        )
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("runs.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )

        _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
        _ = try test5_finish(
            store: store,
            jobID: job.id,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 600),
            exitCode: 0
        )
        tests.expectEqual(
            try store.health()[job.id],
            .success,
            "test5_unwrap_fixture_hasStoredScheduledHealthBeforeRestore"
        )

        _ = try wrapper.unwrap(job: job)
        tests.expectEqual(
            try store.health()[job.id],
            nil,
            "test5_unwrap_doesNotResurrectStaleStoredHealth"
        )
        tests.expectEqual(
            try store.runs(jobID: job.id, limit: 10).map(\.outcome),
            [.success],
            "test5_unwrap_preservesHistoryForInspection"
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: job,
                scheduledHistory: try store.scheduledHealthRuns()[job.id]
            ),
            .unknown,
            "test5_unwrap_withoutNativeStatus_reportsUnknown"
        )
    }
}

private func test5_RunTriggerSchemaMigration(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round5-trigger-migration") { directory in
        let databaseURL = directory.appendingPathComponent("legacy.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.missing("test5 legacy sqlite database")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            database,
            """
            CREATE TABLE runs(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL,
              exit_code INTEGER, stdout_tail TEXT, stderr_tail TEXT);
            INSERT INTO runs(job_id, started_at, finished_at, exit_code)
            VALUES('cron:test5-legacy', 10, 11, 0);
            """,
            nil,
            nil,
            &errorMessage
        )
        let sqliteMessage = errorMessage.map { String(cString: $0) }
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        _ = sqlite3_close(database)
        guard result == SQLITE_OK else {
            throw FixtureError.missing(sqliteMessage ?? "test5 legacy schema setup failed")
        }

        let migrated = try SQLiteRunStore(path: databaseURL.path)
        tests.expectEqual(
            try migrated.latestRun(jobID: "cron:test5-legacy")?.trigger,
            .scheduled,
            "test5_existingRunRows_migrateToScheduledTrigger"
        )
        tests.expectEqual(
            try migrated.health()["cron:test5-legacy"],
            nil,
            "test5_migratedLegacyRun_isExcludedFromHealth"
        )
        let reopened = try SQLiteRunStore(path: databaseURL.path)
        tests.expectEqual(
            try reopened.latestRun(jobID: "cron:test5-legacy")?.trigger,
            .scheduled,
            "test5_triggerMigration_isIdempotent"
        )
        tests.expectEqual(
            try reopened.runs(jobID: "cron:test5-legacy", limit: 10).map(\.outcome),
            [.success],
            "test8_legacyRun_remainsVisibleAfterHealthExclusion"
        )
        _ = try test5_finish(
            store: reopened,
            jobID: "cron:test5-legacy",
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 20),
            exitCode: 1
        )
        tests.expectEqual(
            try reopened.health()["cron:test5-legacy"],
            .failure,
            "test8_postMigrationScheduledRun_contributesToHealth"
        )
    }
}

private func test8_ConcurrentTriggerMigration(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round8-concurrent-trigger-migration") { directory in
        let databaseURL = directory.appendingPathComponent("legacy.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.missing("test8 concurrent legacy sqlite database")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let setupResult = sqlite3_exec(
            database,
            """
            CREATE TABLE runs(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL,
              exit_code INTEGER, stdout_tail TEXT, stderr_tail TEXT);
            INSERT INTO runs(job_id, started_at, finished_at, exit_code)
            VALUES('cron:test8-concurrent', 10, 11, 0);
            """,
            nil,
            nil,
            &errorMessage
        )
        let setupMessage = errorMessage.map { String(cString: $0) }
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        _ = sqlite3_close(database)
        guard setupResult == SQLITE_OK else {
            throw FixtureError.missing(setupMessage ?? "test8 concurrent schema setup failed")
        }

        let hookLock = NSLock()
        let releaseHooks = DispatchSemaphore(value: 0)
        var hookCount = 0
        let migrationHook = {
            hookLock.lock()
            hookCount += 1
            let shouldRelease = hookCount == 2
            hookLock.unlock()
            if shouldRelease {
                releaseHooks.signal()
                releaseHooks.signal()
            }
            _ = releaseHooks.wait(timeout: .now() + 5)
        }

        let resultLock = NSLock()
        var errors: [String] = []
        let workers = DispatchGroup()
        for _ in 0..<2 {
            workers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { workers.leave() }
                do {
                    _ = try SQLiteRunStore(
                        path: databaseURL.path,
                        beforeRunsTriggerMigration: migrationHook
                    )
                } catch {
                    resultLock.lock()
                    errors.append(error.localizedDescription)
                    resultLock.unlock()
                }
            }
        }
        let timedOut = workers.wait(timeout: .now() + 10) == .timedOut
        hookLock.lock()
        let observedHookCount = hookCount
        hookLock.unlock()
        resultLock.lock()
        let observedErrors = errors
        resultLock.unlock()

        tests.expect(!timedOut, "test8_concurrentMigration_bothOpenersComplete")
        tests.expectEqual(
            observedHookCount,
            2,
            "test8_concurrentMigration_bothOpenersObserveLegacySchema"
        )
        tests.expectEqual(
            observedErrors,
            [],
            "test8_concurrentMigration_loserToleratesWinner"
        )
        let reopened = try SQLiteRunStore(path: databaseURL.path)
        tests.expectEqual(
            try reopened.health()["cron:test8-concurrent"],
            nil,
            "test8_concurrentMigration_legacyRowRemainsExcludedFromHealth"
        )
    }
}

private func test8_AlreadyTriggeredRowsAreExcludedFromHealth(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round8-already-triggered-migration") { directory in
        let databaseURL = directory.appendingPathComponent("version2.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.missing("test8 version 2 sqlite database")
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let setupResult = sqlite3_exec(
            database,
            """
            CREATE TABLE runs(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL,
              exit_code INTEGER, stdout_tail TEXT, stderr_tail TEXT,
              trigger TEXT NOT NULL DEFAULT 'scheduled');
            CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO schema_meta(key, value) VALUES('schema_version', '2');
            INSERT INTO runs(job_id, started_at, finished_at, exit_code, trigger)
            VALUES('cron:test8-version2', 10, 11, 0, 'scheduled');
            """,
            nil,
            nil,
            &errorMessage
        )
        let setupMessage = errorMessage.map { String(cString: $0) }
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        _ = sqlite3_close(database)
        guard setupResult == SQLITE_OK else {
            throw FixtureError.missing(setupMessage ?? "test8 version 2 schema setup failed")
        }

        let migrated = try SQLiteRunStore(path: databaseURL.path)
        tests.expectEqual(
            try migrated.health()["cron:test8-version2"],
            nil,
            "test8_alreadyTriggeredLegacyRow_isExcludedFromHealth"
        )
        tests.expectEqual(
            try migrated.runs(jobID: "cron:test8-version2", limit: 10).map(\.outcome),
            [.success],
            "test8_alreadyTriggeredLegacyRow_remainsVisibleInHistory"
        )
    }
}

private func test8_StorePathPolicy(_ tests: TestHarness) {
    let defaultPath = "/tmp/test8-canonical/ticker.db"
    let redirectedPath = "/tmp/test8-redirected/ticker.db"
    let environment = ["TICKER_STORE_PATH": redirectedPath]
    tests.expectEqual(
        RunStorePathPolicy.configuredPath(
            environment: environment,
            scheduledWrapperInvocation: true,
            defaultPath: defaultPath
        ),
        defaultPath,
        "test8_provenanceMarkedScheduledWrapper_ignoresInheritedStorePath"
    )
    tests.expectEqual(
        RunStorePathPolicy.configuredPath(
            environment: environment,
            scheduledWrapperInvocation: false,
            defaultPath: defaultPath
        ),
        redirectedPath,
        "test8_nonWrapperCLI_keepsExplicitStorePathTestSeam"
    )
}

private func test5_CrontabContextAndIdentity(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round5-crontab") { directory in
        let fixtureHome = directory.appendingPathComponent("fixture-home", isDirectory: true)
        let bin = fixtureHome.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let backup = bin.appendingPathComponent("backup")
        try "#!/bin/sh\nprintf '%s|%s\\n' \"$PWD\" \"$FOO\"\n".write(
            to: backup,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: backup.path
        )

        let crontab = """
        HOME=\(fixtureHome.path)
        FOO=one
        0 4 * * * ./bin/backup
        FOO=two
        0 4 * * * ./bin/backup
        """
        let adapter = CrontabAdapter { _, arguments in
            guard arguments == ["-l"] else {
                return AdapterCommandResult(status: 1, stdout: "", stderr: "unexpected")
            }
            return AdapterCommandResult(status: 0, stdout: crontab, stderr: "")
        }
        let firstDiscovery = try adapter.discover()
        let secondDiscovery = try adapter.discover()
        tests.expectEqual(
            firstDiscovery.map(\.cwd),
            [fixtureHome.path, fixtureHome.path],
            "test5_crontabJobs_useEffectiveHomeAsWorkingDirectory"
        )
        tests.expectEqual(
            Set(firstDiscovery.map(\.id)).count,
            2,
            "test5_sameCommandDifferentEnvironment_hasDistinctIDs"
        )
        tests.expectEqual(
            firstDiscovery.map(\.id),
            secondDiscovery.map(\.id),
            "test5_environmentAwareCrontabIDs_areStable"
        )

        let firstJob = try require(
            firstDiscovery.first { $0.environment["FOO"] == "one" },
            "test5 first crontab environment"
        )
        let execution = try test3A_runProcess(
            firstJob.command[0],
            Array(firstJob.command.dropFirst()),
            environment: firstJob.environment,
            currentDirectory: URL(fileURLWithPath: try require(firstJob.cwd, "test5 cron cwd"))
        )
        tests.expectEqual(execution.status, 0, "test5_relativeCronCommand_exitsSuccessfully")
        tests.expectEqual(
            execution.stdout.replacingOccurrences(of: "/private/var/", with: "/var/"),
            "\(fixtureHome.path)|one\n",
            "test5_relativeCronCommand_runsFromFixtureHomeNotHarnessDirectory"
        )
    }
}

private func test5_RegistryEnforcesUniqueIDs(_ tests: TestHarness) {
    let first = test5_makeJob(
        id: "collision:test5",
        source: .crontab,
        label: "first"
    )
    let second = test5_makeJob(
        id: "collision:test5",
        source: .launchd,
        label: "second"
    )
    let result = JobRegistry(
        adapters: [
            test5_StaticAdapter(source: .crontab, jobs: [first]),
            test5_StaticAdapter(source: .launchd, jobs: [second]),
        ]
    ).discoverAll()

    tests.expectEqual(result.jobs.map(\.id), ["collision:test5"], "test5_registry_neverEmitsDuplicateIDs")
    tests.expect(
        result.errors.contains {
            ($0 as? DuplicateJobIDError)?.jobID == "collision:test5"
        },
        "test5_registry_reportsDetectedIDCollision"
    )
}

private func test5_LaunchdDomainIdentityAndStatus(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round5-launchd-domain") { directory in
        let daemons = directory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchDaemons", isDirectory: true)
        let agents = directory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

        try writePropertyList(
            [
                "Label": "com.example.test5.system",
                "ProgramArguments": ["/usr/bin/true"],
                "UserName": "root",
                "GroupName": "wheel",
            ],
            to: daemons.appendingPathComponent("com.example.test5.system.plist")
        )
        try writePropertyList(
            [
                "Label": "com.example.test5.agent",
                "ProgramArguments": ["/usr/bin/true"],
            ],
            to: agents.appendingPathComponent("com.example.test5.agent.plist")
        )

        var queriedTargets: [String] = []
        let adapter = LaunchdAdapter(searchDirectories: [daemons, agents]) { _, arguments in
            guard arguments.count == 2, arguments[0] == "print" else {
                return AdapterCommandResult(status: 1, stdout: "", stderr: "unexpected")
            }
            queriedTargets.append(arguments[1])
            return AdapterCommandResult(
                status: 0,
                stdout: "state = running\nlast exit code = 0\n",
                stderr: ""
            )
        }
        let jobs = try adapter.discover()
        let daemon = try require(
            jobs.first { $0.label == "com.example.test5.system" },
            "test5 system daemon"
        )
        let agent = try require(
            jobs.first { $0.label == "com.example.test5.agent" },
            "test5 user agent"
        )

        tests.expectEqual(daemon.launchdDomain, .systemDaemon, "test5_daemon_carriesSystemDomain")
        tests.expectEqual(daemon.launchdUserName, "root", "test5_daemon_carriesUserName")
        tests.expectEqual(daemon.launchdGroupName, "wheel", "test5_daemon_carriesGroupName")
        tests.expect(!daemon.canRunNow, "test5_systemDaemon_isNotRunnableAsSignedInUser")
        tests.expect(
            daemon.runNowUnavailableReason?.contains("system domain") == true
                && daemon.runNowUnavailableReason?.contains("identities differ") == true,
            "test5_systemDaemon_hasExplicitIdentityMismatchReason"
        )
        tests.expectEqual(agent.launchdDomain, .userAgent, "test5_agent_carriesUserDomain")
        tests.expect(agent.canRunNow, "test5_plainCurrentUserAgent_remainsRunnable")
        tests.expectEqual(agent.runNowUnavailableReason, nil, "test5_plainAgent_hasNoRunNowBlockReason")
        tests.expectEqual(daemon.lastKnownExit?.code, 0, "test5_systemStatus_comesFromSystemTarget")
        tests.expectEqual(agent.lastKnownExit?.code, 0, "test5_agentStatus_comesFromGUIUserTarget")
        tests.expect(
            queriedTargets.contains("system/com.example.test5.system"),
            "test5_launchdStatus_queriesSystemDomainExplicitly"
        )
        tests.expect(
            queriedTargets.contains("gui/\(geteuid())/com.example.test5.agent"),
            "test5_launchdStatus_queriesGUIUserDomainExplicitly"
        )
    }
}

private func test6_LaunchdDuplicateStatusIsDomainScoped(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round6-launchd-duplicates") { root in
        let firstAgents = root
            .appendingPathComponent("first", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        let secondAgents = root
            .appendingPathComponent("second", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        let daemons = root.appendingPathComponent("LaunchDaemons", isDirectory: true)
        for directory in [firstAgents, secondAgents, daemons] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try writePropertyList(
            ["Label": "Cyolo", "ProgramArguments": ["/usr/bin/true"]],
            to: firstAgents.appendingPathComponent("cyolo-first.plist")
        )
        try writePropertyList(
            ["Label": "Cyolo", "ProgramArguments": ["/usr/bin/false"]],
            to: secondAgents.appendingPathComponent("cyolo-second.plist")
        )
        try writePropertyList(
            ["Label": "Cyolo", "ProgramArguments": ["/usr/bin/true"]],
            to: daemons.appendingPathComponent("cyolo-system.plist")
        )

        var queriedTargets: [String] = []
        let adapter = LaunchdAdapter(
            searchDirectories: [firstAgents, secondAgents, daemons]
        ) { _, arguments in
            guard arguments.count == 2, arguments[0] == "print" else {
                return AdapterCommandResult(status: 1, stdout: "", stderr: "unexpected command")
            }
            queriedTargets.append(arguments[1])
            if arguments[1] == "system/Cyolo" {
                return AdapterCommandResult(
                    status: 0,
                    stdout: "state = exited\nlast exit code = 256\n",
                    stderr: ""
                )
            }
            return AdapterCommandResult(
                status: 0,
                stdout: "state = exited\nlast exit code = 0\n",
                stderr: ""
            )
        }

        let jobs = try adapter.discover().filter { $0.label == "Cyolo" }
        let userJobs = jobs.filter { $0.launchdDomain == .userAgent }
        let systemJob = try require(
            jobs.first { $0.launchdDomain == .systemDaemon },
            "test6 system Cyolo job"
        )

        tests.expectEqual(userJobs.count, 2, "test6_duplicate_sameDomain_keepsBothJobs")
        tests.expect(
            userJobs.allSatisfy { $0.runtimeStatusAttribution == .ambiguous },
            "test6_duplicate_sameDomain_marksBothAmbiguous"
        )
        tests.expect(
            userJobs.allSatisfy { $0.lastKnownExit == nil },
            "test6_duplicate_sameDomain_attributesNoExitToEitherJob"
        )
        tests.expect(
            userJobs.allSatisfy {
                $0.runtimeStatusExplanation?.contains("label 'Cyolo'") == true
                    && $0.runtimeStatusExplanation?.contains("gui domain") == true
            },
            "test6_duplicate_sameDomain_namesConflictingLabelAndDomain"
        )
        tests.expect(
            !queriedTargets.contains("gui/\(geteuid())/Cyolo"),
            "test6_duplicate_sameDomain_neverQueriesSharedRuntimeRecord"
        )
        tests.expectEqual(
            systemJob.runtimeStatusAttribution,
            .resolved,
            "test6_sameLabel_differentDomain_remainsResolvable"
        )
        tests.expectEqual(
            systemJob.lastKnownExit?.code,
            1,
            "test6_sameLabel_differentDomain_keepsOwnExitStatus"
        )
        tests.expectEqual(
            queriedTargets.filter { $0 == "system/Cyolo" }.count,
            1,
            "test6_sameLabel_differentDomain_queriesOnlyItsOwnRecord"
        )
    }
}

private func test6_LaunchdRuntimeStatusExplanations(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round6-launchd-attribution") { root in
        let agents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

        for label in [
            "com.example.resolved",
            "com.example.never-exited",
            "com.example.unavailable",
            "com.example.record-without-exit",
        ] {
            try writePropertyList(
                ["Label": label, "ProgramArguments": ["/usr/bin/true"]],
                to: agents.appendingPathComponent("\(label).plist")
            )
        }

        let adapter = LaunchdAdapter(searchDirectories: [agents]) { _, arguments in
            guard arguments.count == 2, arguments[0] == "print" else {
                return AdapterCommandResult(status: 1, stdout: "", stderr: "unexpected command")
            }
            switch arguments[1] {
            case "gui/\(geteuid())/com.example.resolved":
                return AdapterCommandResult(
                    status: 0,
                    stdout: "state = exited\nlast exit code = 0\n",
                    stderr: ""
                )
            case "gui/\(geteuid())/com.example.never-exited":
                return AdapterCommandResult(
                    status: 0,
                    stdout: "state = running\nlast exit code = (never exited)\n",
                    stderr: ""
                )
            case "gui/\(geteuid())/com.example.record-without-exit":
                return AdapterCommandResult(status: 0, stdout: "state = waiting\n", stderr: "")
            default:
                return AdapterCommandResult(status: 113, stdout: "", stderr: "Could not find service")
            }
        }
        let jobs = try adapter.discover()
        let byLabel = Dictionary(uniqueKeysWithValues: jobs.map { ($0.label, $0) })
        let resolved = try require(byLabel["com.example.resolved"], "test6 resolved job")
        let neverExited = try require(byLabel["com.example.never-exited"], "test6 never-exited job")
        let unavailable = try require(byLabel["com.example.unavailable"], "test6 unavailable job")
        let recordWithoutExit = try require(
            byLabel["com.example.record-without-exit"],
            "test6 record-without-exit job"
        )

        tests.expect(
            jobs.allSatisfy {
                $0.runtimeStatusAttribution != nil && $0.runtimeStatusExplanation != nil
            },
            "test6_everyLaunchdJob_hasRuntimeAttributionAndExplanation"
        )
        tests.expectEqual(
            resolved.runtimeStatusAttribution,
            .resolved,
            "test6_resolvedRecord_hasResolvedAttribution"
        )
        tests.expect(
            resolved.runtimeStatusExplanation?.contains("own domain-qualified launchd record") == true,
            "test6_resolvedRecord_explainsStatusSource"
        )
        tests.expectEqual(
            neverExited.runtimeStatusAttribution,
            .neverExited,
            "test6_runningNeverExited_hasDedicatedAttribution"
        )
        tests.expectEqual(
            neverExited.lastKnownExit,
            nil,
            "test6_runningNeverExited_hasNoInventedExit"
        )
        tests.expect(neverExited.enabled, "test6_runningNeverExited_remainsLoaded")
        tests.expect(
            neverExited.runtimeStatusExplanation?.contains("running and has never exited") == true,
            "test6_runningNeverExited_explainsWhyExitIsUnknown"
        )
        tests.expectEqual(
            unavailable.runtimeStatusAttribution,
            .unavailable,
            "test6_missingRecord_hasUnavailableAttribution"
        )
        tests.expect(!unavailable.enabled, "test6_missingRecord_isNotLoaded")
        tests.expect(
            unavailable.runtimeStatusExplanation?.contains("not loaded or its record is unavailable") == true,
            "test6_missingRecord_explainsUnavailableStatus"
        )
        tests.expectEqual(
            recordWithoutExit.runtimeStatusAttribution,
            .recordWithoutExit,
            "test6_loadedRecordWithoutExit_hasDedicatedAttribution"
        )
        tests.expect(recordWithoutExit.enabled, "test6_loadedRecordWithoutExit_remainsLoaded")
        tests.expect(
            recordWithoutExit.runtimeStatusExplanation?.contains("does not include a usable last-exit status")
                == true,
            "test6_loadedRecordWithoutExit_explainsMissingValue"
        )
    }
}

private func test7_wrapperFixture(
    directory: URL,
    label: String,
    propertyList: [String: Any]
) throws -> (JobWrapper, SQLiteRunStore, Job, URL) {
    let plistURL = directory.appendingPathComponent("\(label).plist")
    try writePropertyList(propertyList, to: plistURL)
    let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
    let wrapper = JobWrapper(
        store: store,
        backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
    )
    let commandDictionary = try test2A_readPropertyList(plistURL)
    let command: [String]
    let argv0: String?
    if let program = commandDictionary["Program"] as? String {
        let arguments = commandDictionary["ProgramArguments"] as? [String] ?? []
        command = [program] + Array(arguments.dropFirst())
        argv0 = arguments.first
    } else {
        command = try require(
            commandDictionary["ProgramArguments"] as? [String],
            "test7 fixture command"
        )
        argv0 = nil
    }
    let job = Job(
        id: "launchd:\(label)",
        source: .launchd,
        label: label,
        schedule: .onDemand,
        command: command,
        argv0: argv0,
        cwd: nil,
        enabled: true,
        configPath: plistURL.path,
        lastKnownExit: nil,
        lastRunAt: nil,
        lastScheduledFor: nil,
        managed: false
    )
    return (wrapper, store, job, plistURL)
}

private func test7_UnwrapPreservesStartInterval(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round7-start-interval") { directory in
        let (wrapper, _, job, plistURL) = try test7_wrapperFixture(
            directory: directory,
            label: "com.example.test7.interval",
            propertyList: [
                "Label": "com.example.test7.interval",
                "Program": "/bin/echo",
                "ProgramArguments": ["custom-echo", "original"],
                "StartInterval": 3_600,
            ]
        )
        _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
        var edited = try test2A_readPropertyList(plistURL)
        edited["StartInterval"] = 300
        try writePropertyList(edited, to: plistURL)

        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .wrappedConsistent,
            "test7_nonCommandScheduleEdit_remainsConsistent"
        )
        _ = try wrapper.unwrap(job: job)
        let restored = try test2A_readPropertyList(plistURL)
        tests.expectEqual(
            restored["StartInterval"] as? Int,
            300,
            "test7_unwrap_preservesEditedStartInterval"
        )
        tests.expectEqual(
            restored["Program"] as? String,
            "/bin/echo",
            "test7_unwrap_restoresOriginalProgram"
        )
        tests.expectEqual(
            restored["ProgramArguments"] as? [String],
            ["custom-echo", "original"],
            "test7_unwrap_restoresProgramArgumentsAndArgv0"
        )
    }
}

private func test7_UnwrapPreservesEnvironmentVariables(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round7-environment") { directory in
        let (wrapper, _, job, plistURL) = try test7_wrapperFixture(
            directory: directory,
            label: "com.example.test7.environment",
            propertyList: [
                "EnvironmentVariables": ["ORIGINAL": "one"],
                "Label": "com.example.test7.environment",
                "ProgramArguments": ["/bin/echo", "original"],
            ]
        )
        _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
        var edited = try test2A_readPropertyList(plistURL)
        edited["EnvironmentVariables"] = ["ADDED": "two", "ORIGINAL": "changed"]
        try writePropertyList(edited, to: plistURL)

        _ = try wrapper.unwrap(job: job)
        let restored = try test2A_readPropertyList(plistURL)
        tests.expectEqual(
            restored["EnvironmentVariables"] as? [String: String],
            ["ADDED": "two", "ORIGINAL": "changed"],
            "test7_unwrap_preservesEditedEnvironmentVariables"
        )
        tests.expectEqual(
            restored["ProgramArguments"] as? [String],
            ["/bin/echo", "original"],
            "test7_environmentEdit_unwrapRestoresOriginalCommand"
        )
    }
}

private func test7_UnwrapRejectsOwnedKeyConflict(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round7-command-conflict") { directory in
        let (wrapper, store, job, plistURL) = try test7_wrapperFixture(
            directory: directory,
            label: "com.example.test7.conflict",
            propertyList: [
                "Label": "com.example.test7.conflict",
                "ProgramArguments": ["/bin/echo", "original"],
                "StartInterval": 60,
            ]
        )
        _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
        let backupPath = try require(
            try store.managedBackupPath(jobID: job.id),
            "test7 conflict backup path"
        )
        var conflicted = try test2A_readPropertyList(plistURL)
        conflicted["ProgramArguments"] = ["/bin/false", "third-party"]
        try writePropertyList(conflicted, to: plistURL)
        let conflictedData = try Data(contentsOf: plistURL)

        do {
            _ = try wrapper.unwrap(job: job)
            tests.expect(false, "test7_ownedKeyConflict_failsClosed")
        } catch {
            let message = error.localizedDescription
            tests.expect(
                message.contains(plistURL.path) && message.contains(backupPath),
                "test7_ownedKeyConflict_namesPlistAndBackup"
            )
        }
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            conflictedData,
            "test7_ownedKeyConflict_mutatesNothing"
        )
        tests.expectEqual(
            try store.managedBackupPath(jobID: job.id),
            backupPath,
            "test7_ownedKeyConflict_keepsManagedRecoveryState"
        )
    }
}

private func test7_WrapRejectsConcurrentSourceChange(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round7-wrap-toctou") { directory in
        let plistURL = directory.appendingPathComponent("com.example.test7.toctou.plist")
        try writePropertyList([
            "Label": "com.example.test7.toctou",
            "ProgramArguments": ["/bin/echo", "original"],
            "StartInterval": 60,
        ], to: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let changed: [String: Any] = [
            "Label": "com.example.test7.toctou",
            "ProgramArguments": ["/bin/echo", "changed-concurrently"],
            "StartInterval": 300,
        ]
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true),
            immediatelyBeforeSourceExchange: {
                try writePropertyList(changed, to: plistURL)
            }
        )
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.test7.toctou",
            label: "com.example.test7.toctou",
            command: ["/bin/echo", "original"],
            plistURL: plistURL
        )

        do {
            _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
            tests.expect(false, "test7_concurrentSourceChange_abortsWrap")
        } catch {
            tests.expect(
                error.localizedDescription.contains("changed while Ticker"),
                "test7_concurrentSourceChange_hasActionableError"
            )
        }
        tests.expectEqual(
            try test2A_readPropertyList(plistURL)["ProgramArguments"] as? [String],
            ["/bin/echo", "changed-concurrently"],
            "test7_concurrentSourceChange_preservesExternalCommandEdit"
        )
        tests.expectEqual(
            try store.managedBackupPath(jobID: job.id),
            nil,
            "test7_concurrentSourceChange_doesNotMarkJobManaged"
        )
    }
}

private struct test7_FileMetadata: Equatable {
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
}

private func test7_fileMetadata(at url: URL) throws -> test7_FileMetadata {
    var value = stat()
    guard Darwin.lstat(url.path, &value) == 0 else {
        throw FixtureError.missing("test7 stat \(url.path): \(String(cString: strerror(errno)))")
    }
    return test7_FileMetadata(
        owner: value.st_uid,
        group: value.st_gid,
        mode: value.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO)
    )
}

private func test7_aclText(at url: URL) throws -> String {
    guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
        throw FixtureError.missing("test7 read ACL \(url.path): \(String(cString: strerror(errno)))")
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var length: ssize_t = 0
    guard let text = acl_to_text(acl, &length) else {
        throw FixtureError.missing("test7 render ACL \(url.path): \(String(cString: strerror(errno)))")
    }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text)
}

private let test11_metadataAttributeName = "com.ticker.tests.file-metadata"

private func test11_setExtendedAttribute(_ data: Data, at url: URL) throws {
    let result = data.withUnsafeBytes { bytes in
        url.path.withCString { path in
            test11_metadataAttributeName.withCString { name in
                Darwin.setxattr(
                    path,
                    name,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    XATTR_NOFOLLOW
                )
            }
        }
    }
    guard result == 0 else {
        throw FixtureError.missing(
            "test11 set xattr \(url.path): \(String(cString: strerror(errno)))"
        )
    }
}

private func test11_extendedAttribute(at url: URL) throws -> Data {
    let size = url.path.withCString { path in
        test11_metadataAttributeName.withCString { name in
            Darwin.getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        }
    }
    guard size >= 0 else {
        throw FixtureError.missing(
            "test11 size xattr \(url.path): \(String(cString: strerror(errno)))"
        )
    }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { bytes in
        url.path.withCString { path in
            test11_metadataAttributeName.withCString { name in
                Darwin.getxattr(
                    path,
                    name,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    XATTR_NOFOLLOW
                )
            }
        }
    }
    guard read == size else {
        throw FixtureError.missing(
            "test11 read xattr \(url.path): \(String(cString: strerror(errno)))"
        )
    }
    return data
}

private func test11_fileFlags(at url: URL) throws -> UInt32 {
    var value = stat()
    guard Darwin.lstat(url.path, &value) == 0 else {
        throw FixtureError.missing(
            "test11 stat flags \(url.path): \(String(cString: strerror(errno)))"
        )
    }
    return value.st_flags
}

private func test7_WrapAndUnwrapPreserveFileMetadata(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round7-metadata") { directory in
        let (wrapper, _, job, plistURL) = try test7_wrapperFixture(
            directory: directory,
            label: "com.example.test7.metadata",
            propertyList: [
                "Label": "com.example.test7.metadata",
                "ProgramArguments": ["/bin/echo", "metadata"],
            ]
        )
        guard Darwin.chmod(plistURL.path, 0o600) == 0 else {
            throw FixtureError.missing("test7 chmod fixture: \(String(cString: strerror(errno)))")
        }
        let attributeBefore = Data("ticker-metadata-value".utf8)
        try test11_setExtendedAttribute(attributeBefore, at: plistURL)
        guard Darwin.chflags(plistURL.path, UInt32(UF_NODUMP)) == 0 else {
            throw FixtureError.missing(
                "test11 set file flag: \(String(cString: strerror(errno)))"
            )
        }
        let aclSetup = try test3A_runProcess(
            "/bin/chmod",
            ["+a", "user:\(NSUserName()) allow read", plistURL.path]
        )
        guard aclSetup.status == 0 else {
            throw FixtureError.missing("test7 create ACL: \(aclSetup.stderr)")
        }
        let aclBefore = try test7_aclText(at: plistURL)
        let before = try test7_fileMetadata(at: plistURL)
        print(
            "TRANSCRIPT test7 stat before uid=\(before.owner) gid=\(before.group) "
                + "mode=\(String(before.mode, radix: 8)) path=\(plistURL.path)"
        )
        print(
            "TRANSCRIPT test7 acl before "
                + aclBefore.replacingOccurrences(of: "\n", with: "|")
        )

        _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
        let afterWrap = try test7_fileMetadata(at: plistURL)
        print(
            "TRANSCRIPT test7 stat after-wrap uid=\(afterWrap.owner) gid=\(afterWrap.group) "
                + "mode=\(String(afterWrap.mode, radix: 8)) path=\(plistURL.path)"
        )
        tests.expectEqual(afterWrap, before, "test7_wrap_preservesOwnerGroupAndMode")
        tests.expectEqual(
            try test7_aclText(at: plistURL),
            aclBefore,
            "test7_wrap_preservesACL"
        )
        tests.expectEqual(
            try test11_extendedAttribute(at: plistURL),
            attributeBefore,
            "test11_wrap_preservesExtendedAttributes"
        )
        let flagsAfterWrap = try test11_fileFlags(at: plistURL)
        tests.expect(
            flagsAfterWrap & UInt32(UF_NODUMP) != 0,
            "test11_wrap_preservesFileFlags"
        )

        _ = try wrapper.unwrap(job: job)
        let afterUnwrap = try test7_fileMetadata(at: plistURL)
        print(
            "TRANSCRIPT test7 stat after-unwrap uid=\(afterUnwrap.owner) gid=\(afterUnwrap.group) "
                + "mode=\(String(afterUnwrap.mode, radix: 8)) path=\(plistURL.path)"
        )
        tests.expectEqual(afterUnwrap, before, "test7_unwrap_preservesOwnerGroupAndMode")
        tests.expectEqual(
            try test7_aclText(at: plistURL),
            aclBefore,
            "test7_unwrap_preservesACL"
        )
        tests.expectEqual(
            try test11_extendedAttribute(at: plistURL),
            attributeBefore,
            "test11_unwrap_preservesExtendedAttributes"
        )
        let flagsAfterUnwrap = try test11_fileFlags(at: plistURL)
        tests.expect(
            flagsAfterUnwrap & UInt32(UF_NODUMP) != 0,
            "test11_unwrap_preservesFileFlags"
        )
    }
}

private func test7_SystemDaemonWrapIsRejected(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round7-system-daemon") { directory in
        let plistURL = directory.appendingPathComponent("com.example.test7.system.plist")
        try writePropertyList([
            "Label": "com.example.test7.system",
            "ProgramArguments": ["/usr/bin/true"],
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)
        let reason = "launchd runs this job in the system domain as root:wheel, but Ticker runs as the signed-in user. Run Now is disabled because those execution identities differ."
        let job = Job(
            id: "launchd:system:com.example.test7.system",
            source: .launchd,
            label: "com.example.test7.system",
            schedule: .onDemand,
            command: ["/usr/bin/true"],
            cwd: nil,
            enabled: true,
            launchdDomain: .systemDaemon,
            launchdUserName: "root",
            launchdGroupName: "wheel",
            runNowUnavailableReason: reason,
            configPath: plistURL.path,
            lastKnownExit: nil,
            lastRunAt: nil,
            lastScheduledFor: nil,
            managed: false
        )
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )

        do {
            _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker")
            tests.expect(false, "test7_systemDaemon_wrapIsRejected")
        } catch {
            tests.expect(
                error.localizedDescription.contains(reason),
                "test7_systemDaemon_wrapUsesRunNowIdentityReason"
            )
        }
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test7_systemDaemon_wrapMutatesNothing"
        )
    }
}

private func test7_ManualCrontabRunUsesDiscoveredContext(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round7-manual-crontab") { directory in
        let tickerPath = try test3A_builtCLIPath()
        let fixtureHome = directory.appendingPathComponent("fixture-home", isDirectory: true)
        let binDirectory = fixtureHome.appendingPathComponent("bin", isDirectory: true)
        let unrelated = directory.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let relativeCommand = binDirectory.appendingPathComponent("relative-command")
        try """
        #!/bin/sh
        printf '%s|%s|%s\\n' "$PWD" "$TEST7_CONTEXT" "$HOME"
        """.write(to: relativeCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: relativeCommand.path
        )

        let crontabFixture = directory.appendingPathComponent("crontab.txt")
        try """
        HOME=\(fixtureHome.path)
        TEST7_CONTEXT=from-crontab
        * * * * * ./bin/relative-command
        """.write(to: crontabFixture, atomically: true, encoding: .utf8)
        let fakeCrontab = directory.appendingPathComponent("crontab")
        try """
        #!/bin/sh
        cat '\(crontabFixture.path)'
        """.write(to: fakeCrontab, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCrontab.path
        )
        let adapter = CrontabAdapter(
            crontabURL: fakeCrontab,
            commandRunner: { try runAdapterCommand(executable: $0, arguments: $1) }
        )
        let job = try require(try adapter.discover().first, "test7 fixture crontab job")
        let result = try test3A_runProcess(
            tickerPath,
            ["run", "--manual", "--label", job.id, "--"] + job.command,
            environment: [
                "HOME": unrelated.path,
                "TEST7_CONTEXT": "from-parent",
                "TICKER_CRONTAB_PATH": fakeCrontab.path,
                "TICKER_STORE_PATH": directory.appendingPathComponent("ticker.db").path,
            ],
            currentDirectory: unrelated
        )
        let normalizedOutput = result.stdout.replacingOccurrences(of: "/private/var/", with: "/var/")
        tests.expectEqual(result.status, 0, "test7_manualCrontab_relativeCommandSucceeds")
        tests.expectEqual(
            normalizedOutput,
            "\(fixtureHome.path)|from-crontab|\(fixtureHome.path)\n",
            "test7_manualCrontab_usesDiscoveredCwdAndEnvironment"
        )
    }
}

private func test8_discoverLaunchdJob(
    in directories: [URL],
    label: String
) throws -> Job {
    let adapter = LaunchdAdapter(searchDirectories: directories) { _, _ in
        AdapterCommandResult(status: 1, stdout: "", stderr: "not loaded")
    }
    return try require(
        try adapter.discover().first { $0.label == label },
        "test8 launchd job \(label)"
    )
}

private func test9_RunLivenessAndNativeOrdering(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round9-run-liveness") { directory in
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let bootSessionID = RunExecutionEvidence.currentBootSessionID()

        let deadID = "launchd:test9-dead#111111111111"
        _ = try store.beginRun(
            jobID: deadID,
            startedAt: Date(timeIntervalSince1970: 100),
            trigger: .scheduled,
            context: RunStartContext(
                processID: Int32.max,
                bootSessionID: bootSessionID,
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: 10
            )
        )
        let deadJob = test5_makeJob(
            id: deadID,
            lastKnownExit: ExitStatus(raw: 1),
            launchdRunCount: 10,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: deadJob,
                scheduledHistory: try store.scheduledHealthRuns()[deadID]
            ),
            .failure,
            "test9_deadWrapper_nativeFailureWinsOverUnfinishedRow"
        )

        let previousBootID = "launchd:test9-previous-boot#222222222222"
        _ = try store.beginRun(
            jobID: previousBootID,
            startedAt: Date(timeIntervalSince1970: 200),
            trigger: .scheduled,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: "previous-boot-session",
                nativeExitStatusAtStart: 2,
                launchdRunCountAtStart: 20
            )
        )
        let previousBootJob = test5_makeJob(
            id: previousBootID,
            lastKnownExit: ExitStatus(raw: 2),
            launchdRunCount: 20,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: previousBootJob,
                scheduledHistory: try store.scheduledHealthRuns()[previousBootID]
            ),
            .failure,
            "test9_previousBoot_unfinishedRowIsNotRunning"
        )

        let unavailableBootID = "launchd:test9-unavailable-boot#232323232323"
        _ = try store.beginRun(
            jobID: unavailableBootID,
            startedAt: Date(timeIntervalSince1970: 250),
            trigger: .scheduled,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: RunExecutionEvidence.unavailableBootSessionID,
                nativeExitStatusAtStart: 2,
                launchdRunCountAtStart: 25
            )
        )
        let unavailableBootJob = test5_makeJob(
            id: unavailableBootID,
            lastKnownExit: ExitStatus(raw: 2),
            launchdProcessID: getpid(),
            launchdRunCount: 25,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: unavailableBootJob,
                scheduledHistory: try store.scheduledHealthRuns()[unavailableBootID]
            ),
            .failure,
            "test9_unavailableBootEvidence_neverCorroboratesRunning"
        )

        let liveID = "launchd:test9-live#333333333333"
        _ = try store.beginRun(
            jobID: liveID,
            startedAt: Date(timeIntervalSince1970: 300),
            trigger: .scheduled,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: bootSessionID,
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: 30
            )
        )
        let liveJob = test5_makeJob(
            id: liveID,
            lastKnownExit: ExitStatus(raw: 1),
            launchdProcessID: getpid(),
            launchdRunCount: 30,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: liveJob,
                scheduledHistory: try store.scheduledHealthRuns()[liveID]
            ),
            .running,
            "test9_liveLongRunningWrapper_remainsRunning"
        )

        let clockRollbackID = "launchd:test9-clock-rollback#444444444444"
        let earlierFailureID = try test5_finish(
            store: store,
            jobID: clockRollbackID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 100),
            exitCode: 1,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: bootSessionID,
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: 39
            )
        )
        let laterSuccessID = try test5_finish(
            store: store,
            jobID: clockRollbackID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 50),
            exitCode: 0,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: bootSessionID,
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: 40
            )
        )
        tests.expect(laterSuccessID > earlierFailureID, "test10_runID_isMonotonicAcrossClockRollback")
        tests.expectEqual(
            try store.scheduledHealthRuns()[clockRollbackID]?.id,
            laterSuccessID,
            "test10_healthSelection_usesRunIDAcrossClockRollback"
        )
        let clockRollbackJob = test5_makeJob(
            id: clockRollbackID,
            lastKnownExit: ExitStatus(raw: 1),
            nativeStatusObservedAt: Date(timeIntervalSince1970: 5_000),
            launchdRunCount: 40,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: clockRollbackJob,
                scheduledHistory: try store.scheduledHealthRuns()[clockRollbackID]
            ),
            .success,
            "test9_backwardWallClock_cannotReorderNativeAndStoredEvents"
        )

        let rebootID = "launchd:test10-reboot#454545454545"
        _ = try test5_finish(
            store: store,
            jobID: rebootID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 350),
            exitCode: 0,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: "previous-boot-session",
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: 1
            )
        )
        let rebootJob = test5_makeJob(
            id: rebootID,
            lastKnownExit: ExitStatus(raw: 1),
            launchdRunCount: 1,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: rebootJob,
                scheduledHistory: try store.scheduledHealthRuns()[rebootID]
            ),
            .failure,
            "test10_preRebootSuccess_cannotHideCurrentNativeFailure"
        )

        let laterNativeID = "launchd:test9-later-native#555555555555"
        _ = try test5_finish(
            store: store,
            jobID: laterNativeID,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: 400),
            exitCode: 0,
            context: RunStartContext(
                processID: getpid(),
                bootSessionID: bootSessionID,
                nativeExitStatusAtStart: 1,
                launchdRunCountAtStart: 50
            )
        )
        let laterNativeJob = test5_makeJob(
            id: laterNativeID,
            lastKnownExit: ExitStatus(raw: 1),
            launchdRunCount: 51,
            managed: true
        )
        tests.expectEqual(
            JobHealthPolicy.outcome(
                for: laterNativeJob,
                scheduledHistory: try store.scheduledHealthRuns()[laterNativeID]
            ),
            .failure,
            "test9_laterLaunchdRun_nativeFailureVetoesStoredSuccess"
        )
    }
}

private func test9_PersistentIdentityAliases(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round9-identity-aliases") { directory in
        let databasePath = directory.appendingPathComponent("ticker.db").path
        let oldID = "launchd:com.example.test9.alias#111111111111"
        let middleID = "launchd:com.example.test9.alias#222222222222"
        let currentID = "launchd:com.example.test9.alias#333333333333"
        let backupPath = directory.appendingPathComponent("backup.plist").path
        do {
            let store = try SQLiteRunStore(path: databasePath)
            try store.markManaged(jobID: oldID, backupPath: backupPath)
            _ = try test5_finish(store: store, jobID: oldID, trigger: .scheduled,
                                 startedAt: Date(timeIntervalSince1970: 10), exitCode: 0)
        }
        let canonicalized = DispatchSemaphore(value: 0)
        let releaseInsert = DispatchSemaphore(value: 0)
        let migrationFinished = DispatchSemaphore(value: 0)
        let hookedStore = try SQLiteRunStore(path: databasePath, beforeRunsTriggerMigration: nil,
            afterBeginRunCanonicalization: {
                canonicalized.signal(); _ = releaseInsert.wait(timeout: .now() + 5) })
        let migrationStore = try SQLiteRunStore(path: databasePath)
        let resultLock = NSLock()
        var concurrencyErrors: [String] = []
        let workers = DispatchGroup()
        workers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { workers.leave() }
            do {
                _ = try test5_finish(store: hookedStore, jobID: oldID, trigger: .scheduled,
                                     startedAt: Date(timeIntervalSince1970: 20), exitCode: 1)
            } catch {
                resultLock.lock(); concurrencyErrors.append(error.localizedDescription)
                resultLock.unlock()
            }
        }
        tests.expectEqual(canonicalized.wait(timeout: .now() + 5), .success,
                          "test10_lateOldWrapper_pausesAfterCanonicalization")
        workers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { migrationFinished.signal(); workers.leave() }
            do {
                try migrationStore.migrateJobIdentity(from: oldID, to: middleID)
            } catch {
                resultLock.lock(); concurrencyErrors.append(error.localizedDescription)
                resultLock.unlock()
            }
        }
        tests.expectEqual(migrationFinished.wait(timeout: .now() + 0.2), .timedOut,
                          "test10_identityMigration_waitsForInFlightIdentityWrite")
        releaseInsert.signal()
        tests.expectEqual(workers.wait(timeout: .now() + 10), .success,
                          "test10_interleavedIdentityWriteAndMigration_complete")
        resultLock.lock(); let observedErrors = concurrencyErrors; resultLock.unlock()
        tests.expectEqual(observedErrors, [],
                          "test10_interleavedIdentityWriteAndMigration_succeed")
        let reopened = try SQLiteRunStore(path: databasePath)
        tests.expectEqual(try reopened.canonicalJobID(oldID), middleID,
                          "test9_identityAlias_persistsAcrossStoreReopen")
        tests.expectEqual(try reopened.runs(jobID: middleID, limit: 10).map(\.jobID),
                          [middleID, middleID],
                          "test9_lateOldWrapperRun_landsOnCanonicalIdentity")
        try reopened.migrateJobIdentity(from: middleID, to: currentID)
        _ = try test5_finish(store: reopened, jobID: oldID, trigger: .scheduled,
                             startedAt: Date(timeIntervalSince1970: 30), exitCode: 0)
        tests.expectEqual(try reopened.canonicalJobID(oldID), currentID,
                          "test9_subsequentIdentityMigration_resolvesAliasChain")
        tests.expectEqual(try reopened.managedBackupPath(jobID: oldID), backupPath,
                          "test9_backupLookup_canonicalizesOldIdentity")
    }
}

private func test10_LegacyWrapperRemoval(_ tests: TestHarness) throws {
    let id = "launchd:com.example.test10.legacy#111111111111"
    let unversioned = ["/Applications/Ticker.app/Contents/Helpers/ticker", "run",
                       "--label", id, "--", "/usr/bin/true"]
    tests.expect(LaunchdWrapper.decode(unversioned) == nil,
                 "test10_unversionedWrapper_isNotRecognized")
    try withTemporaryDirectory("round10-no-legacy-wrapper") { directory in
        let plistURL = directory.appendingPathComponent("legacy.plist")
        try writePropertyList(["Label": "com.example.test10.legacy",
                               "ProgramArguments": unversioned], to: plistURL)
        let adapter = LaunchdAdapter(searchDirectories: [directory]) { _, _ in
            AdapterCommandResult(status: 1, stdout: "", stderr: "not loaded")
        }
        let job = try require(try adapter.discover().first, "test10 unversioned fixture")
        tests.expect(!job.managed, "test10_unversionedInvocation_isNotManaged")
        tests.expectEqual(job.command, unversioned, "test10_unversionedInvocation_remainsLiteral")
        let marker = directory.appendingPathComponent("unexpected-child.txt")
        let result = try test3A_runProcess(
            try test3A_builtCLIPath(),
            ["run", "--label", job.id, "--", "/bin/sh", "-c",
             "printf unexpected > '\(marker.path)'"]
        )
        tests.expectEqual(result.status, 2, "test10_unversionedScheduledRun_isRejected")
        tests.expect(!FileManager.default.fileExists(atPath: marker.path),
                     "test10_rejectedUnversionedRun_doesNotLaunchChild")
    }
}

private func test10_ConcurrentEvidenceMigration(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round10-concurrent-evidence-migration") { directory in
        let databaseURL = directory.appendingPathComponent("legacy.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database
        else { throw FixtureError.missing("test10 evidence legacy sqlite database") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let setupResult = sqlite3_exec(database, """
            CREATE TABLE runs(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL,
              exit_code INTEGER, stdout_tail TEXT, stderr_tail TEXT,
              trigger TEXT NOT NULL DEFAULT 'scheduled');
            CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO schema_meta(key, value) VALUES('run_trigger_health_v3', '1');
            """, nil, nil, &errorMessage)
        let setupMessage = errorMessage.map { String(cString: $0) }
        if let errorMessage { sqlite3_free(errorMessage) }
        _ = sqlite3_close(database)
        guard setupResult == SQLITE_OK else { throw FixtureError.missing(
            setupMessage ?? "test10 evidence schema setup failed") }
        let hookLock = NSLock()
        let releaseHooks = DispatchSemaphore(value: 0)
        var hookCount = 0
        let migrationHook = {
            hookLock.lock(); hookCount += 1
            let bothObserved = hookCount == 2
            hookLock.unlock()
            if bothObserved { releaseHooks.signal(); releaseHooks.signal() }
            _ = releaseHooks.wait(timeout: .now() + 5)
        }
        let resultLock = NSLock()
        var errors: [String] = []
        let workers = DispatchGroup()
        for _ in 0..<2 {
            workers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { workers.leave() }
                do {
                    _ = try SQLiteRunStore(path: databaseURL.path,
                        beforeRunsTriggerMigration: nil, beforeRunEvidenceMigration: migrationHook)
                } catch {
                    resultLock.lock(); errors.append(error.localizedDescription); resultLock.unlock()
                }
            }
        }
        tests.expectEqual(workers.wait(timeout: .now() + 10), .success,
                          "test10_concurrentEvidenceMigration_bothOpenersComplete")
        hookLock.lock(); let observedHookCount = hookCount; hookLock.unlock()
        resultLock.lock(); let observedErrors = errors; resultLock.unlock()
        tests.expectEqual(observedHookCount, 2,
                          "test10_concurrentEvidenceMigration_bothObserveMissingColumns")
        tests.expectEqual(observedErrors, [],
                          "test10_concurrentEvidenceMigration_rechecksUnderLock")
        let reopened = try SQLiteRunStore(path: databaseURL.path)
        let id = "launchd:test10-evidence#222222222222"
        let context = RunStartContext(processID: getpid(), bootSessionID: "test10-boot",
                                      nativeExitStatusAtStart: 1, launchdRunCountAtStart: 2)
        let runID = try reopened.beginRun(jobID: id, startedAt: Date(timeIntervalSince1970: 1),
                                          trigger: .scheduled, context: context)
        let run = try require(try reopened.runs(jobID: id, limit: 1).first, "test10 evidence run")
        tests.expectEqual(run.id, runID, "test10_evidenceMigration_preservesWritableRunsTable")
        tests.expectEqual(run.processID, getpid(), "test10_evidenceMigration_addsProcessID")
        tests.expectEqual(run.bootSessionID, "test10-boot", "test10_evidenceMigration_addsBootID")
        tests.expectEqual(run.nativeExitStatusAtStart, 1, "test10_evidenceMigration_addsNativeStatus")
        tests.expectEqual(run.launchdRunCountAtStart, 2, "test10_evidenceMigration_addsRunCount")
    }
}

private func test10_ExplicitSingularIdentityReconciliation(_ tests: TestHarness) throws {
    let tickerPath = "/Applications/Ticker.app/Contents/Helpers/ticker"
    try withTemporaryDirectory("round10-two-moves") { directory in
        let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        let thirdDirectory = directory.appendingPathComponent("third", isDirectory: true)
        for item in [firstDirectory, secondDirectory, thirdDirectory] {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true) }
        let firstURL = firstDirectory.appendingPathComponent("job.plist")
        let secondURL = secondDirectory.appendingPathComponent("job.plist")
        let thirdURL = thirdDirectory.appendingPathComponent("job.plist")
        try writePropertyList(["Label": "com.example.test10.twice-moved",
                               "ProgramArguments": ["/bin/echo", "twice-moved"]], to: firstURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true))
        let firstJob = try test8_discoverLaunchdJob(in: [firstDirectory],
                                                     label: "com.example.test10.twice-moved")
        _ = try wrapper.wrap(job: firstJob, tickerPath: tickerPath)
        _ = try test5_finish(store: store, jobID: firstJob.id, trigger: .scheduled,
                             startedAt: Date(timeIntervalSince1970: 1), exitCode: 0)
        try FileManager.default.moveItem(at: firstURL, to: secondURL)
        let secondJob = try test8_discoverLaunchdJob(in: [secondDirectory],
                                                      label: "com.example.test10.twice-moved")
        tests.expectEqual(
            try wrapper.recoveryState(job: secondJob),
            .identityChanged(previousJobID: firstJob.id),
            "test10_firstMove_isAuthenticatedThroughRealWrapperRoute"
        )
        _ = try wrapper.reconcileIdentityChange(job: secondJob, tickerPath: tickerPath)
        var renamedSecond = try test2A_readPropertyList(secondURL)
        renamedSecond["Label"] = "com.example.test10.twice-moved-renamed"
        try writePropertyList(renamedSecond, to: secondURL)
        try FileManager.default.moveItem(at: secondURL, to: thirdURL)
        let thirdJob = try test8_discoverLaunchdJob(in: [thirdDirectory],
            label: "com.example.test10.twice-moved-renamed")
        tests.expectEqual(
            try wrapper.recoveryState(job: thirdJob),
            .identityChanged(previousJobID: secondJob.id),
            "test10_secondMoveAndRename_comparesIdentityThroughAliasChain"
        )
        _ = try wrapper.reconcileIdentityChange(job: thirdJob, tickerPath: tickerPath)
        let args = try require(try test2A_readPropertyList(thirdURL)["ProgramArguments"]
            as? [String], "test10 twice-moved wrapper arguments")
        tests.expectEqual(LaunchdWrapper.decode(args)?.label, thirdJob.id,
                          "test10_secondMove_rebindsVersionedWrapper")
        tests.expectEqual(try store.canonicalJobID(firstJob.id), thirdJob.id,
                          "test10_secondMove_preservesTransitiveAlias")
        tests.expectEqual(try store.runs(jobID: thirdJob.id, limit: 10).map(\.jobID), [thirdJob.id],
                          "test10_secondMove_preservesHistoryThroughRealWrapperRoute")
        tests.expectEqual(
            try wrapper.recoveryState(job: thirdJob), .wrappedConsistent,
            "test10_secondMoveAndRename_remainsRecoverable"
        )
        _ = try wrapper.unwrap(job: thirdJob)
        let restored = try test2A_readPropertyList(thirdURL)
        tests.expectEqual(restored["Label"] as? String, "com.example.test10.twice-moved-renamed",
                          "test10_secondMoveAndRename_unwrapPreservesCurrentLabel")
        tests.expectEqual(restored["ProgramArguments"] as? [String], ["/bin/echo", "twice-moved"],
                          "test10_secondMoveAndRename_unwrapRestoresOriginalCommand")
    }

    try withTemporaryDirectory("round10-ambiguous-claim") { directory in
        let originalDirectory = directory.appendingPathComponent("original", isDirectory: true)
        let copiesDirectory = directory.appendingPathComponent("copies", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copiesDirectory, withIntermediateDirectories: true)
        let originalURL = originalDirectory.appendingPathComponent("original.plist")
        let firstCopyURL = copiesDirectory.appendingPathComponent("first-copy.plist")
        let secondCopyURL = copiesDirectory.appendingPathComponent("second-copy.plist")
        try writePropertyList(["Label": "com.example.test10.ambiguous",
                               "ProgramArguments": ["/usr/bin/true"]], to: originalURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true))
        let originalJob = try test8_discoverLaunchdJob(in: [originalDirectory],
                                                        label: "com.example.test10.ambiguous")
        _ = try wrapper.wrap(job: originalJob, tickerPath: tickerPath)
        let wrappedData = try Data(contentsOf: originalURL)
        try wrappedData.write(to: firstCopyURL)
        var secondCopy = try test2A_readPropertyList(originalURL); secondCopy["Label"] = "com.example.test10.ambiguous-second"
        try writePropertyList(secondCopy, to: secondCopyURL); let secondWrappedData = try Data(contentsOf: secondCopyURL)
        try FileManager.default.removeItem(at: originalURL)
        let discoveredCopies = try LaunchdAdapter(searchDirectories: [copiesDirectory]) { _, _ in
            AdapterCommandResult(status: 1, stdout: "", stderr: "not loaded")
        }.discover()
        let firstCopy = try require(discoveredCopies.first {
            $0.configPath == firstCopyURL.standardizedFileURL.path
        }, "test10 first ambiguous claimant")
        tests.expectEqual(
            try wrapper.recoveryState(job: firstCopy),
            .identityChanged(previousJobID: originalJob.id),
            "test10_ambiguousCopies_reachExplicitReconciliationGate"
        )
        var reconciliationMessage = ""
        do {
            _ = try wrapper.reconcileIdentityChange(job: firstCopy, tickerPath: tickerPath)
            tests.expect(false, "test10_ambiguousIdentityClaim_failsClosed")
        } catch {
            reconciliationMessage = error.localizedDescription
            tests.expect(true, "test10_ambiguousIdentityClaim_failsClosed")
        }
        tests.expect(reconciliationMessage.contains(firstCopyURL.path)
            && reconciliationMessage.contains(secondCopyURL.path),
                     "test10_ambiguousIdentityClaim_namesEveryClaimant")
        tests.expect(reconciliationMessage.contains("Keep exactly the intended plist"),
                     "test10_ambiguousIdentityClaim_givesManualResolution")
        tests.expectEqual(try store.canonicalJobID(originalJob.id), originalJob.id,
                          "test10_ambiguousIdentityClaim_doesNotRetargetHistory")
        let copiesUnchanged = try Data(contentsOf: firstCopyURL) == wrappedData
            && Data(contentsOf: secondCopyURL) == secondWrappedData
        tests.expect(copiesUnchanged, "test10_ambiguousIdentityClaim_doesNotRewriteCopies")
    }
}

private func test10_RuntimeOwnershipAndDiagnostics(_ tests: TestHarness) throws {
    let nested = """
    gui/501/com.example.test10 = {
        pid = 42
        runs = 7
        last exit code = 1
        endpoints = {
            pid = 999
            runs = 999
            last exit code = 0
        }
    }
    """
    let expected = LaunchdRuntimeSnapshot(processID: 42, lastExitStatus: ExitStatus(raw: 1),
                                          runCount: 7)
    tests.expectEqual(LaunchdRuntimeSnapshot.parse(nested), expected,
                      "test10_runtimeParser_ignoresNestedDuplicateFields")
    let probeJob = test5_makeJob(
        id: "launchd:com.example.test10.probe#333333333333",
        label: "com.example.test10.probe",
        launchdDomain: .userAgent,
        configPath: "/tmp/test10-probe.plist",
        managed: true
    )
    var probeCalls = 0
    let ownership = try LaunchdRuntimeProbe.ownership(job: probeJob, processID: 4242,
        attempts: 3, retryDelay: 0, commandRunner: { _, _ in
            probeCalls += 1
            let pidLine = probeCalls == 3 ? "pid = 4242\n" : ""
            return AdapterCommandResult(status: 0,
                stdout: "service = {\n\(pidLine)runs = 1\nlast exit code = 0\n}\n", stderr: "")
        })
    guard case .owned = ownership
    else { throw FixtureError.missing("test10 delayed pid ownership") }
    tests.expectEqual(probeCalls, 3, "test10_serviceWithoutPID_isRetriedBeforeMismatch")

    try withTemporaryDirectory("round10-command-timeout") { directory in
        let slowCommand = directory.appendingPathComponent("slow-command")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: slowCommand, atomically: true,
                                                      encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: slowCommand.path)
        let startedAt = Date()
        do {
            _ = try runAdapterCommand(executable: slowCommand, arguments: [], timeout: 0.1)
            tests.expect(false, "test10_launchctlProbe_timeoutThrows")
        } catch AdapterCommandError.timedOut {
            tests.expect(true, "test10_launchctlProbe_timeoutThrows")
        } catch {
            tests.expect(false, "test10_launchctlProbe_timeoutUsesTypedError")
        }
        tests.expect(Date().timeIntervalSince(startedAt) < 2,
                     "test10_launchctlProbe_timeoutIsBounded")
    }

    try withTemporaryDirectory("round10-recorder-diagnostics") { directory in
        let compiledStorePath = test10_compiledStorePath()
        test10_removeStore(at: compiledStorePath)
        defer { test10_removeStore(at: compiledStorePath) }
        let store = try SQLiteRunStore(path: compiledStorePath)
        let tickerPath = try test3A_builtCLIPath()
        let marker = directory.appendingPathComponent("child-launched.txt")
        let fixture = try test10_wrappedInvocation(directory: directory,
            label: "com.example.test10.no-pid",
            command: ["/bin/sh", "-c", "printf launched > '\(marker.path)'"],
            tickerPath: tickerPath, store: store)
        let launchctl = directory.appendingPathComponent("launchctl")
        try """
        #!/bin/sh
        printf 'gui/test = {\n    runs = 1\n    last exit code = 0\n}\n'
        """.write(to: launchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: launchctl.path)
        let environment = [
            "TICKER_TEST_LAUNCHCTL_PATH": launchctl.path,
            "TICKER_TEST_LAUNCHD_DIRECTORIES": directory.path,
        ]
        let delayedPIDResult = try test3A_runProcess(fixture.arguments[0],
            Array(fixture.arguments.dropFirst()), environment: environment)
        tests.expectEqual(delayedPIDResult.status, 1, "test10_noPIDYet_failsClosed")
        tests.expect(!FileManager.default.fileExists(atPath: marker.path),
                     "test10_noPIDYet_doesNotExecuteChild")
        tests.expect(
            delayedPIDResult.stderr.contains("scheduled wrapper authorization failed")
                && delayedPIDResult.stderr.contains("child was not executed"),
            "test10_noPIDYet_reportsAuthorizationFailure"
        )
        tests.expectEqual(try store.runs(jobID: fixture.job.id, limit: 10).count, 0,
                          "test10_noPIDYet_doesNotCreateRunHistory")
        let delayedPIDDiagnostic = try store.recorderDiagnostics().first?.message
        tests.expect(delayedPIDDiagnostic?.contains("has not published") == true,
                     "test10_noPIDYet_persistsDistinctRecorderDiagnostic")
        var doctorEnvironment = environment; doctorEnvironment["TICKER_STORE_PATH"] = compiledStorePath
        let doctor = try test3A_runProcess(tickerPath, ["doctor"], environment: doctorEnvironment)
        tests.expect(doctor.stdout.contains("recorder-diagnostic")
            && doctor.stdout.contains("has not published"),
                     "test10_doctor_surfacesRecorderDiagnostic")

        let forged = try test3A_runProcess(
            tickerPath,
            [
                "run", "--ticker-wrapper-version", LaunchdWrapper.currentVersion,
                "--label", fixture.job.id, "--", "/usr/bin/false",
            ],
            environment: environment
        )
        tests.expectEqual(forged.status, 1, "test10_handRunScheduledInjection_failsClosed")
        tests.expect(
            forged.stderr.contains("scheduled wrapper authorization failed")
                && forged.stderr.contains("child was not executed"),
            "test10_handRunScheduledInjection_reportsAuthorizationFailure"
        )
        tests.expectEqual(try store.runs(jobID: fixture.job.id, limit: 10).count, 0,
                          "test10_handRunScheduledInjection_cannotForgeHistory")
        let forgedDiagnostic = try store.recorderDiagnostics().first?.message
        tests.expect(forgedDiagnostic?.contains("command does not match") == true,
                     "test10_handRunScheduledInjection_recordsDiagnostic")

        let differentPIDLaunchctl = directory.appendingPathComponent("different-pid-launchctl")
        try """
        #!/bin/sh
        printf 'gui/test = {\n    pid = 1\n    runs = 1\n    last exit code = 0\n}\n'
        """.write(to: differentPIDLaunchctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: differentPIDLaunchctl.path
        )
        var differentPIDEnvironment = environment
        differentPIDEnvironment["TICKER_TEST_LAUNCHCTL_PATH"] = differentPIDLaunchctl.path
        for _ in 0..<3 {
            let differentPIDResult = try test3A_runProcess(
                fixture.arguments[0],
                Array(fixture.arguments.dropFirst()),
                environment: differentPIDEnvironment
            )
            tests.expectEqual(
                differentPIDResult.status,
                1,
                "test11_exactCommandDifferentPID_failsClosed"
            )
        }
        tests.expect(
            !FileManager.default.fileExists(atPath: marker.path),
            "test11_exactCommandDifferentPID_doesNotExecuteChild"
        )
        tests.expectEqual(
            try store.runs(jobID: fixture.job.id, limit: 10).count,
            0,
            "test11_exactCommandDifferentPID_doesNotCreateRunHistory"
        )
        let differentPIDDiagnostic = try store.recorderDiagnostics().first?.message
        tests.expect(
            differentPIDDiagnostic?.contains("reports pid 1") == true,
            "test11_exactCommandDifferentPID_recordsOwnershipFailure"
        )
        tests.expectEqual(
            try test11_recorderDiagnosticRowCount(at: URL(fileURLWithPath: compiledStorePath)),
            1,
            "test11_repeatedPIDFailures_keepOneActiveRow"
        )

        let ownedLaunchctl = try test10_fakeLaunchctl(in: directory)
        var ownedEnvironment = environment
        ownedEnvironment["TICKER_TEST_LAUNCHCTL_PATH"] = ownedLaunchctl.path
        try test10_setRunStartFailure(
            at: URL(fileURLWithPath: compiledStorePath),
            enabled: true
        )
        let failedStartResult = try test3A_runProcess(
            fixture.arguments[0],
            Array(fixture.arguments.dropFirst()),
            environment: ownedEnvironment
        )
        try test10_setRunStartFailure(
            at: URL(fileURLWithPath: compiledStorePath),
            enabled: false
        )
        tests.expectEqual(
            failedStartResult.status,
            1,
            "test11_durableRunStartFailure_failsClosed"
        )
        tests.expect(
            !FileManager.default.fileExists(atPath: marker.path),
            "test11_durableRunStartFailure_doesNotExecuteChild"
        )
        tests.expect(
            failedStartResult.stderr.contains("scheduled durable run-start failed")
                && failedStartResult.stderr.contains("child was not executed"),
            "test11_durableRunStartFailure_reportsFailureClass"
        )
        tests.expectEqual(
            try store.runs(jobID: fixture.job.id, limit: 10).count,
            0,
            "test11_durableRunStartFailure_doesNotCreatePartialHistory"
        )

        try test16_setRunFinishFailure(
            at: URL(fileURLWithPath: compiledStorePath),
            enabled: true
        )
        let failedFinishResult = try test3A_runProcess(
            fixture.arguments[0],
            Array(fixture.arguments.dropFirst()),
            environment: ownedEnvironment
        )
        try test16_setRunFinishFailure(
            at: URL(fileURLWithPath: compiledStorePath),
            enabled: false
        )
        tests.expect(
            FileManager.default.fileExists(atPath: marker.path),
            "test16_durableRunFinishFailure_provesChildExecuted"
        )
        tests.expectEqual(
            failedFinishResult.status,
            74,
            "test16_zeroExitWithDurableRunFinishFailure_usesReservedWrapperExit"
        )
        tests.expect(
            failedFinishResult.stderr.contains("scheduled durable run-finish failed")
                && failedFinishResult.stderr.contains("child exited 0")
                && failedFinishResult.stderr.contains("wrapper exiting 74"),
            "test16_durableRunFinishFailure_reportsFailureClass"
        )
        let unfinalizedRun = try require(
            try store.latestRun(jobID: fixture.job.id),
            "test16 unfinalized scheduled run"
        )
        tests.expect(
            unfinalizedRun.finishedAt == nil
                && unfinalizedRun.exitCode == nil
                && unfinalizedRun.outcome != .success,
            "test16_durableRunFinishFailure_doesNotPublishFalseSuccess"
        )
        try FileManager.default.removeItem(at: marker)

        let nonzeroMarker = directory.appendingPathComponent("nonzero-child-launched.txt")
        let nonzeroFixture = try test10_wrappedInvocation(
            directory: directory,
            label: "com.example.test16.finish-nonzero",
            command: [
                "/bin/sh", "-c",
                "printf launched > '\(nonzeroMarker.path)'; exit 23",
            ],
            tickerPath: tickerPath,
            store: store
        )
        try test16_setRunFinishFailure(
            at: URL(fileURLWithPath: compiledStorePath),
            enabled: true
        )
        let nonzeroFinishResult = try test3A_runProcess(
            nonzeroFixture.arguments[0],
            Array(nonzeroFixture.arguments.dropFirst()),
            environment: ownedEnvironment
        )
        try test16_setRunFinishFailure(
            at: URL(fileURLWithPath: compiledStorePath),
            enabled: false
        )
        tests.expect(
            FileManager.default.fileExists(atPath: nonzeroMarker.path),
            "test16_nonzeroChildWithFinishFailure_provesChildExecuted"
        )
        tests.expectEqual(
            nonzeroFinishResult.status,
            23,
            "test16_nonzeroChildWithFinishFailure_preservesChildExit"
        )
        tests.expect(
            nonzeroFinishResult.stderr.contains("scheduled durable run-finish failed")
                && nonzeroFinishResult.stderr.contains("preserving child exit 23"),
            "test16_nonzeroChildWithFinishFailure_reportsPreservedExit"
        )

        let ownedResult = try test3A_runProcess(
            fixture.arguments[0],
            Array(fixture.arguments.dropFirst()),
            environment: ownedEnvironment
        )
        tests.expectEqual(
            ownedResult.status,
            0,
            "test11_authorizedPersistedStart_executesChild"
        )
        tests.expect(
            FileManager.default.fileExists(atPath: marker.path),
            "test11_authorizedPersistedStart_provesChildExecuted"
        )
        let completedRun = try require(
            try store.latestRun(jobID: fixture.job.id),
            "test11 authorized completed run"
        )
        tests.expect(completedRun.finishedAt != nil,
                     "test11_authorizedPersistedStart_finalizesRun")
        tests.expectEqual(completedRun.exitCode, 0,
                          "test11_authorizedPersistedStart_recordsChildExit")
        tests.expectEqual(completedRun.outcome, .success,
                          "test11_authorizedPersistedStart_recordsSuccess")
        tests.expectEqual(
            try store.recorderDiagnostics(),
            [],
            "test11_authorizedPersistedStart_clearsDiagnostic"
        )
    }
}

private func test11_recorderDiagnosticRowCount(at databaseURL: URL) throws -> Int {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        throw FixtureError.missing("test11 open recorder diagnostic database")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(
        database,
        "SELECT COUNT(*) FROM recorder_diagnostics;",
        -1,
        &statement,
        nil
    )
    guard prepareResult == SQLITE_OK, let statement else {
        throw FixtureError.missing("test11 prepare recorder diagnostic count")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw FixtureError.missing("test11 read recorder diagnostic count")
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func test10_setRunStartFailure(at databaseURL: URL, enabled: Bool) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        throw FixtureError.missing("test10 open database for run-start failure injection")
    }
    defer { sqlite3_close(database) }

    let statement = enabled
        ? """
          CREATE TRIGGER ticker_tests_fail_run_start
          BEFORE INSERT ON runs
          BEGIN
            SELECT RAISE(FAIL, 'injected durable run-start failure');
          END;
          """
        : "DROP TRIGGER IF EXISTS ticker_tests_fail_run_start;"
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, statement, nil, nil, &errorMessage)
    let detail = errorMessage.map { String(cString: $0) }
    if let errorMessage {
        sqlite3_free(errorMessage)
    }
    guard result == SQLITE_OK else {
        throw FixtureError.missing(
            "test10 configure run-start failure injection: \(detail ?? "SQLite error \(result)")"
        )
    }
}

private func test16_setRunFinishFailure(at databaseURL: URL, enabled: Bool) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        throw FixtureError.missing("test10 open database for run-finish failure injection")
    }
    defer { sqlite3_close(database) }

    let statement = enabled
        ? """
          CREATE TRIGGER ticker_tests_fail_run_finish
          BEFORE UPDATE OF finished_at ON runs
          BEGIN
            SELECT RAISE(FAIL, 'injected durable run-finish failure');
          END;
          """
        : "DROP TRIGGER IF EXISTS ticker_tests_fail_run_finish;"
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, statement, nil, nil, &errorMessage)
    let detail = errorMessage.map { String(cString: $0) }
    if let errorMessage {
        sqlite3_free(errorMessage)
    }
    guard result == SQLITE_OK else {
        throw FixtureError.missing(
            "test10 configure run-finish failure injection: \(detail ?? "SQLite error \(result)")"
        )
    }
}

private func test11_RecorderDiagnosticsAreCurrentAndBounded(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round11-recorder-diagnostics") { directory in
        let databaseURL = directory.appendingPathComponent("ticker.db")
        let store = try SQLiteRunStore(path: databaseURL.path)
        let jobID = "launchd:com.example.test11.diagnostic#111111111111"
        let firstRecordedAt = Date()
        for attempt in 1...25 {
            try store.recordRecorderDiagnostic(
                claimedJobID: jobID,
                message: "authorization failure \(attempt)"
            )
        }
        let diagnostics = try store.recorderDiagnostics(limit: 100)
        tests.expectEqual(
            diagnostics.count,
            1,
            "test11_repeatedAuthorizationFailures_haveOneActiveDiagnostic"
        )
        tests.expectEqual(
            diagnostics.first?.message,
            "authorization failure 25",
            "test11_repeatedAuthorizationFailures_replaceTheActiveDiagnostic"
        )
        tests.expect(
            diagnostics.first.map { $0.occurredAt >= firstRecordedAt } == true,
            "test11_activeDiagnostic_returnsItsOccurrenceTime"
        )
        tests.expectEqual(
            try test11_recorderDiagnosticRowCount(at: databaseURL),
            1,
            "test11_repeatedAuthorizationFailures_doNotGrowTheTable"
        )

        try store.clearRecorderDiagnostic(claimedJobID: jobID)
        tests.expectEqual(
            try store.recorderDiagnostics(limit: 100),
            [],
            "test11_resolvedAuthorization_removesTheActiveDiagnostic"
        )
    }
}

private func test11_AmbiguousWrapperExplanationMatchesCause(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round11-ambiguous-wrapper-explanation") { directory in
        let (wrapper, _, job, plistURL) = try test7_wrapperFixture(
            directory: directory,
            label: "com.example.test11.command-disagreement",
            propertyList: [
                "Label": "com.example.test11.command-disagreement",
                "ProgramArguments": ["/bin/echo", "authenticated-command"],
            ]
        )
        _ = try wrapper.wrap(
            job: job,
            tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker"
        )
        var edited = try test2A_readPropertyList(plistURL)
        var arguments = try require(
            edited["ProgramArguments"] as? [String],
            "test11 versioned wrapper arguments"
        )
        let separator = try require(
            arguments.firstIndex(of: "--"),
            "test11 versioned wrapper separator"
        )
        arguments[arguments.index(separator, offsetBy: 2)] = "edited-command"
        edited["ProgramArguments"] = arguments
        try writePropertyList(edited, to: plistURL)

        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .ambiguousTickerInvocation,
            "test11_versionedWrapperCommandEdit_isAmbiguous"
        )
        tests.expectEqual(
            JobRecoveryState.ambiguousTickerInvocationExplanation,
            "Ticker cannot verify that this plist's command matches the authenticated backup "
                + "associated with its wrapper. Program or ProgramArguments changed, or the wrapper "
                + "and backup identify different commands. Compare those fields with the authenticated "
                + "backup, restore the intended command, then run ticker doctor.",
            "test11_ambiguousWrapperExplanation_describesBackupCommandDisagreement"
        )
    }
}

private func test9_CopiedWrapperRuntimeOwnership(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round9-wrapper-ownership") { directory in
        let compiledStorePath = test10_compiledStorePath()
        test10_removeStore(at: compiledStorePath)
        defer { test10_removeStore(at: compiledStorePath) }
        let tickerPath = try test3A_builtCLIPath()
        let label = "com.example.test9.owner"
        let originalURL = directory.appendingPathComponent("\(label).plist")
        let copiedURL = directory.appendingPathComponent("copy.plist")
        let store = try SQLiteRunStore(path: compiledStorePath)
        let owner = try test10_wrappedInvocation(directory: directory, label: label,
            command: ["/bin/echo", "owner"], tickerPath: tickerPath, store: store)
        let fakeLaunchctl = try test10_fakeLaunchctl(in: directory)
        let environment = [
            "TICKER_TEST_LAUNCHCTL_PATH": fakeLaunchctl.path,
            "TICKER_TEST_LAUNCHD_DIRECTORIES": directory.path,
        ]
        let ownerResult = try test3A_runProcess(owner.arguments[0],
            Array(owner.arguments.dropFirst()), environment: environment)
        tests.expectEqual(ownerResult.status, 0, "test9_ownedWrapper_executesNormally")
        tests.expectEqual(try store.runs(jobID: owner.job.id, limit: 10).count, 1,
                          "test9_ownedWrapper_recordsAfterRuntimeOwnershipProof")
        let copied = try test2A_readPropertyList(originalURL)
        try writePropertyList(copied, to: copiedURL)
        let copiedArguments = try require(
            try test2A_readPropertyList(copiedURL)["ProgramArguments"] as? [String],
            "test9 copied wrapper arguments")
        let copiedResult = try test3A_runProcess(copiedArguments[0],
            Array(copiedArguments.dropFirst()), environment: environment)
        tests.expectEqual(copiedResult.status, 1, "test9_copiedWrapper_failsClosed")
        tests.expectEqual(copiedResult.stdout, "",
                          "test10_copiedWrapper_doesNotExecuteChild")
        tests.expect(
            copiedResult.stderr.contains("scheduled wrapper authorization failed")
                && copiedResult.stderr.contains("child was not executed"),
            "test9_copiedWrapper_reportsAuthorizationFailureClearly"
        )
        tests.expectEqual(try store.runs(jobID: owner.job.id, limit: 10).count, 1,
                          "test9_copiedWrapper_leavesVictimHistoryUnchanged")

        let pathBoundCopyURL = directory.appendingPathComponent("path-bound-copy.plist")
        let pathBoundLabel = "com.example.test11.path-bound-copy"
        let originalCanonicalPath = originalURL.standardizedFileURL.resolvingSymlinksInPath().path
        let originalPathDigest = SHA256.hash(data: Data(originalCanonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let forgedPathClaim = "launchd:\(pathBoundLabel)#\(originalPathDigest.prefix(12))"
        var pathBoundCopy = copied
        pathBoundCopy["Label"] = pathBoundLabel
        var pathBoundArguments = try require(
            pathBoundCopy["ProgramArguments"] as? [String],
            "test11 path-bound copied wrapper arguments"
        )
        let labelOption = try require(
            pathBoundArguments.firstIndex(of: "--label"),
            "test11 path-bound copied wrapper label"
        )
        pathBoundArguments[pathBoundArguments.index(after: labelOption)] = forgedPathClaim
        pathBoundCopy["ProgramArguments"] = pathBoundArguments
        try FileManager.default.removeItem(at: originalURL)
        try FileManager.default.removeItem(at: copiedURL)
        try writePropertyList(pathBoundCopy, to: pathBoundCopyURL)

        let pathBoundResult = try test3A_runProcess(
            pathBoundArguments[0],
            Array(pathBoundArguments.dropFirst()),
            environment: environment
        )
        tests.expectEqual(
            pathBoundResult.status,
            1,
            "test11_differentLabelCopiedWrapper_failsClosed"
        )
        tests.expectEqual(
            pathBoundResult.stdout,
            "",
            "test11_differentLabelCopiedWrapper_doesNotExecuteChild"
        )
        tests.expect(
            pathBoundResult.stderr.contains("scheduled wrapper authorization failed")
                && pathBoundResult.stderr.contains("child was not executed"),
            "test11_differentLabelCopiedWrapper_reportsPathIdentityFailure"
        )
        tests.expectEqual(
            try store.runs(jobID: forgedPathClaim, limit: 10).count,
            0,
            "test11_differentLabelCopiedWrapper_canonicalPathPreventsAttribution"
        )
    }
}

private func test9_MetadataOnlyConcurrentChange(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round9-metadata-change") { directory in
        let plistURL = directory.appendingPathComponent("metadata.plist")
        try writePropertyList([
            "Label": "com.example.test9.metadata",
            "ProgramArguments": ["/usr/bin/true"],
        ], to: plistURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: plistURL.path
        )
        let originalData = try Data(contentsOf: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true),
            immediatelyBeforeSourceExchange: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o640],
                    ofItemAtPath: plistURL.path
                )
            }
        )
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.test9.metadata#555555555555",
            label: "com.example.test9.metadata",
            command: ["/usr/bin/true"],
            plistURL: plistURL
        )
        tests.expectThrows(
            try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker"),
            "test9_metadataOnlyConcurrentChange_abortsRewrite"
        )
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test9_metadataOnlyConcurrentChange_preservesPlistBytes"
        )
        tests.expectEqual(
            try test7_fileMetadata(at: plistURL).mode,
            0o640,
            "test9_metadataOnlyConcurrentChange_restoresNewMode"
        )
        let managedIDs = try store.managedJobIDs()
        tests.expect(
            managedIDs.isEmpty,
            "test9_metadataOnlyConcurrentChange_doesNotMarkJobManaged"
        )
    }
}

private func test9_crashAfterFirstExchange(arguments: [String]) -> Never {
    guard arguments.count == 4 else {
        Darwin._exit(64)
    }
    do {
        let plistURL = URL(fileURLWithPath: arguments[1])
        let store = try SQLiteRunStore(path: arguments[2])
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: URL(fileURLWithPath: arguments[3], isDirectory: true),
            immediatelyBeforeSourceExchange: {},
            immediatelyAfterSourceExchange: {
                Darwin._exit(91)
            }
        )
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.test9.crash#666666666666",
            label: "com.example.test9.crash",
            command: ["/usr/bin/true"],
            plistURL: plistURL
        )
        _ = try wrapper.wrap(
            job: job,
            tickerPath: "/Applications/Ticker.app/Contents/Helpers/ticker"
        )
    } catch {
        Darwin._exit(92)
    }
    Darwin._exit(93)
}

private func test9_InterruptedExchangeRecovery(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round9-interrupted-exchange") { directory in
        let plistURL = directory.appendingPathComponent("crash.plist")
        let databasePath = directory.appendingPathComponent("ticker.db").path
        let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        try writePropertyList([
            "Label": "com.example.test9.crash",
            "ProgramArguments": ["/usr/bin/true"],
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)
        let child = try test3A_runProcess(
            CommandLine.arguments[0],
            ["--test9-crash-after-exchange", plistURL.path, databasePath, backupDirectory.path]
        )
        tests.expectEqual(child.status, 91, "test9_crashFixture_stopsAfterFirstExchange")
        let crashedData = try Data(contentsOf: plistURL)
        tests.expect(
            crashedData != originalData,
            "test9_crashFixture_leavesStagedRewriteLive"
        )
        let unrelatedTemporary = directory.appendingPathComponent("unrelated.keep.tmp")
        let unrelatedExchange = directory.appendingPathComponent(
            ".other.plist.ticker-exchange.keep.json"
        )
        try Data("unrelated temporary".utf8).write(to: unrelatedTemporary)
        try Data("unrelated exchange".utf8).write(to: unrelatedExchange)

        let store = try SQLiteRunStore(path: databasePath)
        let wrapper = JobWrapper(store: store, backupDirectory: backupDirectory)
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.test9.crash#666666666666",
            label: "com.example.test9.crash",
            command: ["/usr/bin/true"],
            plistURL: plistURL
        )
        tests.expectEqual(
            try wrapper.recoveryState(job: job),
            .staleManagedRow,
            "test9_recoveryScan_restoresDisplacedPlistAfterCrash"
        )
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test9_recoveryScan_restoresExactDisplacedBytes"
        )
        let residue = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".crash.plist.ticker-exchange.")
                || ($0.lastPathComponent.hasPrefix(".crash.plist.")
                    && $0.lastPathComponent.hasSuffix(".tmp"))
        }
        tests.expectEqual(
            residue.map(\.lastPathComponent),
            [],
            "test9_recoveryScan_removesOnlyItsTransactionResidue"
        )
        tests.expectEqual(
            try Data(contentsOf: unrelatedTemporary),
            Data("unrelated temporary".utf8),
            "test10_recoveryScan_preservesUnrelatedTemporaryFile"
        )
        tests.expectEqual(
            try Data(contentsOf: unrelatedExchange),
            Data("unrelated exchange".utf8),
            "test10_recoveryScan_preservesUnrelatedExchangeRecord"
        )
    }
}

private func test12_BuiltBundlePackaging(_ tests: TestHarness) throws {
    _ = try test3A_builtCLIPath()

    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let bundle = repository.appendingPathComponent("Ticker.app", isDirectory: true)
    let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
    let infoData = try Data(contentsOf: infoURL)
    let info = try require(
        try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any],
        "test12 bundle Info.plist"
    )
    let executableName = try require(
        info["CFBundleExecutable"] as? String,
        "test12 CFBundleExecutable"
    )
    let version = try require(
        info["CFBundleShortVersionString"] as? String,
        "test12 CFBundleShortVersionString"
    )
    tests.expect(
        info["TickerAdHocSigned"] as? Bool == true,
        "test17_adHocBundle_enablesCompatibleNotificationFallback"
    )
    let appExecutable = bundle
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
        .appendingPathComponent(executableName)
    let cliExecutable = bundle
        .appendingPathComponent("Contents/Helpers", isDirectory: true)
        .appendingPathComponent("ticker")

    tests.expect(
        FileManager.default.isExecutableFile(atPath: appExecutable.path),
        "test12_CFBundleExecutable_existsAndIsExecutable"
    )
    tests.expect(
        FileManager.default.isExecutableFile(atPath: cliExecutable.path),
        "test12_bundledCLI_existsAndIsExecutable"
    )
    tests.expect(
        appExecutable.path.lowercased() != cliExecutable.path.lowercased(),
        "test12_GUIAndCLIPaths_doNotCollideCaseInsensitively"
    )

    let appIdentity = try FileManager.default.attributesOfItem(atPath: appExecutable.path)[
        .systemFileNumber
    ] as? NSNumber
    let cliIdentity = try FileManager.default.attributesOfItem(atPath: cliExecutable.path)[
        .systemFileNumber
    ] as? NSNumber
    tests.expect(
        appIdentity != nil && cliIdentity != nil && appIdentity != cliIdentity,
        "test12_GUIAndCLI_areSimultaneouslyDistinctFiles"
    )

    let appLinks = try test3A_runProcess("/usr/bin/otool", ["-L", appExecutable.path])
    let cliLinks = try test3A_runProcess("/usr/bin/otool", ["-L", cliExecutable.path])
    tests.expectEqual(appLinks.status, 0, "test12_CFBundleExecutable_otoolSucceeds")
    tests.expect(
        appLinks.stdout.contains("SwiftUI.framework"),
        "test12_CFBundleExecutable_linksSwiftUI"
    )
    tests.expectEqual(cliLinks.status, 0, "test12_bundledCLI_otoolSucceeds")
    tests.expect(
        !cliLinks.stdout.contains("SwiftUI.framework"),
        "test12_bundledCLI_doesNotLinkSwiftUI"
    )

    let cliVersion = try test3A_runProcess(cliExecutable.path, ["--version"])
    tests.expectEqual(cliVersion.status, 0, "test12_bundledCLI_versionExitsSuccessfully")
    tests.expectEqual(
        cliVersion.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
        "ticker \(version)",
        "test12_bundledCLI_reportsBundleVersion"
    )
}

private func test13_ProvenanceClassificationAndCaching(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round13-provenance") { root in
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let plist = root.appendingPathComponent("signed.plist")
        let signedProgram = root.appendingPathComponent("Signed Helper")
        let teamSignedProgram = root.appendingPathComponent("Team Signed Helper")
        try Data("plist-v1".utf8).write(to: plist)
        try Data("binary-v1".utf8).write(to: signedProgram)
        try Data("binary-team".utf8).write(to: teamSignedProgram)

        var signatureProbeCount = 0
        let classifier = JobProvenanceClassifier(homeDirectory: home) { _, arguments in
            signatureProbeCount += 1
            if arguments.last == signedProgram.path {
                return AdapterCommandResult(
                    status: 0,
                    stdout: "",
                    stderr: "Authority=Developer ID Application: CYOLO SECURITY LTD (ABC123)\n"
                )
            }
            if arguments.last == teamSignedProgram.path {
                return AdapterCommandResult(
                    status: 0,
                    stdout: "",
                    stderr: "Authority=(unavailable)\nTeamIdentifier=Y93TK974AT\n"
                )
            }
            return AdapterCommandResult(status: 1, stdout: "", stderr: "unsigned")
        }

        let first = classifier.classify(
            source: .launchd,
            command: [signedProgram.path, "/missing/app-configuration"],
            configPath: plist.path
        )
        tests.expectEqual(
            first.provenance,
            .app("Cyolo"),
            "test13_signatureAuthority_stripsTeamAndNormalizesCyolo"
        )
        tests.expectEqual(
            signatureProbeCount,
            1,
            "test13_firstClassification_performsOneSignatureProbe"
        )
        tests.expectEqual(
            first.attention,
            nil,
            "test13_signedAppAbsoluteArgument_isNotMistakenForPayload"
        )

        let second = classifier.classify(
            source: .launchd,
            command: [signedProgram.path, "/missing/app-configuration"],
            configPath: plist.path
        )
        tests.expectEqual(second, first, "test13_cachedClassification_preservesTypedResult")
        tests.expectEqual(
            signatureProbeCount,
            1,
            "test13_unchangedClassification_performsNoNewSubprocessWork"
        )
        print(
            "TRANSCRIPT test13 cache firstProbeCount=1 "
                + "repeatProbeCount=\(signatureProbeCount) newSubprocesses=\(signatureProbeCount - 1)"
        )

        try Data("binary-v2-with-new-identity".utf8).write(to: signedProgram)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 2)],
            ofItemAtPath: signedProgram.path
        )
        _ = classifier.classify(
            source: .launchd,
            command: [signedProgram.path, "/missing/app-configuration"],
            configPath: plist.path
        )
        tests.expectEqual(
            signatureProbeCount,
            2,
            "test13_programIdentityChange_invalidatesClassificationCache"
        )

        try Data("plist-v2".utf8).write(to: plist)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 4)],
            ofItemAtPath: plist.path
        )
        _ = classifier.classify(
            source: .launchd,
            command: [signedProgram.path, "/missing/app-configuration"],
            configPath: plist.path
        )
        tests.expectEqual(
            signatureProbeCount,
            3,
            "test13_plistIdentityOrMtimeChange_invalidatesClassificationCache"
        )

        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: [teamSignedProgram.path],
                configPath: root.appendingPathComponent("team-signed.plist").path
            ).provenance,
            .app("Bjango Pty Ltd"),
            "test13_redactedAuthority_usesStableDeveloperTeamIdentity"
        )

        let missingScript = home.appendingPathComponent("scripts/gone.sh").path
        let payloadPlist = root.appendingPathComponent("payload.plist")
        try Data("payload".utf8).write(to: payloadPlist)
        let payload = classifier.classify(
            source: .launchd,
            command: ["/bin/sh", missingScript],
            configPath: payloadPlist.path
        )
        tests.expectEqual(payload.provenance, .yours, "test13_homePayload_isYours")
        tests.expectEqual(
            payload.attention,
            .missingPayload(missingScript),
            "test13_missingPayload_isFirstClassAttentionState"
        )

        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: ["open", "/Applications/Cyolo.app"],
                configPath: root.appendingPathComponent("cyolo.plist").path
            ).provenance,
            .app("Cyolo"),
            "test13_vendorPayload_normalizesToSameCyoloOwner"
        )
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: ["/bin/sh", "/var/lib/oneleet/updater.sh"],
                configPath: root.appendingPathComponent("oneleet.plist").path
            ).provenance,
            .app("oneleet"),
            "test13_vendorPayload_usesFirstVendorPathSegment"
        )
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: ["/opt/homebrew/opt/redis/bin/redis-server"],
                configPath: root.appendingPathComponent("brew.plist").path
            ).provenance,
            .packageManager("Homebrew"),
            "test13_packagePrefix_isHomebrew"
        )
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: ["/usr/libexec/example-helper"],
                configPath: root.appendingPathComponent("system.plist").path
            ).provenance,
            .system,
            "test13_systemPrefix_isSystem"
        )
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: ["/usr/bin/plain-tool"],
                configPath: root.appendingPathComponent("system-program.plist").path
            ).provenance,
            .system,
            "test14_usrBinPath_isPositiveSystemProof"
        )

        let tickerExecutable = "/Applications/Ticker.app/Contents/MacOS/Ticker"
        let tickerLaunchAgents = home.appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true
        )
        let exactTickerFallback = tickerLaunchAgents.appendingPathComponent(
            "com.suchintan.ticker.login.plist"
        )
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: [tickerExecutable],
                configPath: exactTickerFallback.path,
                launchdLabel: "com.suchintan.ticker.login",
                effectiveExecutable: tickerExecutable
            ).provenance,
            .ticker,
            "test13_exactTickerFallback_isTicker"
        )

        for lookalikeLabel in [
            "com.suchintan.ticker",
            "com.suchintan.ticker.login.backup",
        ] {
            tests.expectEqual(
                classifier.classify(
                    source: .launchd,
                    command: [tickerExecutable],
                    configPath: tickerLaunchAgents
                        .appendingPathComponent("\(lookalikeLabel).plist").path,
                    launchdLabel: lookalikeLabel,
                    effectiveExecutable: tickerExecutable
                ).provenance,
                .app("Ticker"),
                "test13_tickerLookalikeLabel_\(lookalikeLabel)_isNotTicker"
            )
        }

        let copyWithTickerArgument = classifier.classify(
            source: .launchd,
            command: ["/bin/cp", tickerExecutable, root.appendingPathComponent("copy").path],
            configPath: exactTickerFallback.path
        )
        tests.expectEqual(
            copyWithTickerArgument.provenance,
            .system,
            "test13_programExecutableWinsOverLaterTickerArgument"
        )
        tests.expectEqual(
            copyWithTickerArgument.attention,
            nil,
            "test13_laterTickerArgument_doesNotCreatePayloadAttention"
        )

        let backupProgram = home.appendingPathComponent("ticker-backup")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: backupProgram)
        let backupClassification = classifier.classify(
            source: .launchd,
            command: [backupProgram.path, tickerExecutable],
            configPath: tickerLaunchAgents
                .appendingPathComponent("com.suchintan.ticker.backup.plist").path
        )
        tests.expectEqual(
            backupClassification.provenance,
            .yours,
            "test13_tickerBackupJob_preservesUserManagedProvenance"
        )
        tests.expectEqual(
            backupClassification.attention,
            nil,
            "test13_tickerBackupJob_preservesHealthyAttentionState"
        )

        tests.expectEqual(
            classifier.classify(source: .crontab, command: [], configPath: nil).provenance,
            .yours,
            "test13_crontab_isAlwaysYours"
        )
        tests.expectEqual(
            classifier.classify(source: .claudeRoutine, command: [], configPath: nil).provenance,
            .yours,
            "test13_claudeRoutine_isAlwaysYours"
        )

        let encodedJob = Job(
            id: "launchd:missing",
            source: .launchd,
            provenance: payload.provenance,
            attention: payload.attention,
            label: "com.example.missing",
            schedule: .onDemand,
            command: ["/bin/sh", missingScript],
            cwd: nil,
            enabled: true,
            configPath: payloadPlist.path,
            lastKnownExit: nil,
            lastRunAt: nil,
            lastScheduledFor: nil,
            managed: false
        )
        let object = try require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(encodedJob))
                as? [String: Any],
            "test13 encoded job object"
        )
        tests.expect(
            !encodedJob.canRunNow
                && encodedJob.effectiveRunNowUnavailableReason?.contains(missingScript) == true,
            "test13_missingPayload_disablesManualRunWithExactReason"
        )
        let encodedProvenance = object["provenance"] as? [String: Any]
        let encodedAttention = object["attention"] as? [String: Any]
        tests.expectEqual(
            encodedProvenance?["kind"] as? String,
            "yours",
            "test13_jobJSON_includesTypedProvenance"
        )
        tests.expectEqual(
            encodedAttention?["kind"] as? String,
            "missingPayload",
            "test13_jobJSON_includesTypedAttention"
        )
    }
}

private func test13_CLISurfacesMissingPayload(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round13-cli") { root in
        let home = root.appendingPathComponent("home", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let claudeRoot = root.appendingPathComponent("claude-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let missingPayload = home.appendingPathComponent(".claude/scripts/gone.sh").path
        try writePropertyList(
            [
                "Label": "com.example.test13.missing",
                "ProgramArguments": ["/bin/sh", missingPayload],
                "StartInterval": 60,
            ],
            to: launchAgents.appendingPathComponent("com.example.test13.missing.plist")
        )
        let launchctl = try test10_fakeLaunchctl(in: root)
        let storePath = root.appendingPathComponent("runs.sqlite").path
        let environment = [
            "TICKER_TEST_HOME_DIRECTORY": home.path,
            "TICKER_TEST_LAUNCHD_DIRECTORIES": launchAgents.path,
            "TICKER_TEST_CLAUDE_ROOTS": claudeRoot.path,
            "TICKER_TEST_LAUNCHCTL_PATH": launchctl.path,
            "TICKER_STORE_PATH": storePath,
        ]
        let tickerPath = try test3A_builtCLIPath()

        let list = try test3A_runProcess(tickerPath, ["list"], environment: environment)
        tests.expectEqual(list.status, 0, "test13_list_missingPayload_exitsSuccessfully")
        tests.expect(
            list.stdout.contains("broken")
                && list.stdout.contains("Missing payload")
                && list.stdout.contains(missingPayload),
            "test13_list_missingPayload_isVisiblyBroken"
        )

        let json = try test3A_runProcess(tickerPath, ["list", "--json"], environment: environment)
        let records = try require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [[String: Any]],
            "test13 list JSON records"
        )
        let record = try require(
            records.first { $0["label"] as? String == "com.example.test13.missing" },
            "test13 list JSON record"
        )
        let provenance = record["provenance"] as? [String: Any]
        let attention = record["attention"] as? [String: Any]
        tests.expectEqual(
            provenance?["kind"] as? String,
            "yours",
            "test13_listJSON_reportsYoursProvenance"
        )
        tests.expectEqual(
            attention?["kind"] as? String,
            "missingPayload",
            "test13_listJSON_reportsMissingPayloadAttention"
        )
        tests.expectEqual(
            record["isBroken"] as? Bool,
            true,
            "test13_listJSON_reportsBrokenState"
        )

        let doctor = try test3A_runProcess(tickerPath, ["doctor"], environment: environment)
        tests.expectEqual(doctor.status, 0, "test13_doctor_missingPayload_exitsSuccessfully")
        tests.expect(
            doctor.stdout.contains("broken: missing payload at \(missingPayload)"),
            "test13_doctor_reportsMissingPayloadAsBroken"
        )
    }
}

private func test13_UIArchitectureContract(_ tests: TestHarness) throws {
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let listSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerApp/JobListView.swift"),
        encoding: .utf8
    )
    let detailSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerApp/JobDetailView.swift"),
        encoding: .utf8
    )
    let appSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerApp/TickerApp.swift"),
        encoding: .utf8
    )

    tests.expect(
        listSource.contains("@AppStorage")
            && listSource.contains("DisclosureGroup")
            && listSource.contains("Section(\"My Jobs\")"),
        "test13_sidebar_persistsProvenanceGroupExpansion"
    )
    tests.expect(
        listSource.contains(".searchable(")
            && listSource.contains("Other Jobs")
            && listSource.contains("Package Managers"),
        "test13_sidebar_searchesAcrossProvenanceGroups"
    )
    tests.expect(
        !listSource.contains("HSplitView")
            && !listSource.contains("private var footer")
            && !listSource.contains("OutcomeChip"),
        "test13_sidebar_removesLegacyChromeAndRoutineCapsules"
    )
    tests.expect(
        detailSource.contains("Run inspector")
            && detailSource.contains("DisclosureGroup(\"Configuration\")")
            && detailSource.contains("DisclosureGroup(\"Advanced\")"),
        "test13_detail_prioritizesDirectRunInspectionAndCollapsesDiagnostics"
    )
    tests.expect(
        detailSource.contains("truncationMode(.middle)")
            && detailSource.contains("textSelection(.enabled)")
            && detailSource.contains("borderedProminent"),
        "test13_detail_usesReviewedPathAndActionPresentation"
    )
    tests.expect(
        appSource.contains("model.hasUrgentAttentionOwnedJobs"),
        "test14_menuBarFailure_includesUnattributedJobs"
    )
    tests.expect(
        listSource.contains("job.command.joined")
            && listSource.contains("job.configPath")
            && listSource.contains("job.provenance.displayName")
            && listSource.contains("isSearching && hasMatches"),
        "test13_search_coversCommandPathOwnerAndExpandsMatches"
    )
    tests.expect(
        listSource.contains("if model.needsAttention(job) { return 0 }")
            && listSource.contains("case .running: return 1")
            && listSource.contains("case .unknown: return 2")
            && listSource.contains("case .success: return 3")
            && listSource.contains("if !job.enabled { return 4 }"),
        "test13_sidebarSort_usesReviewedAttentionEvidenceOrder"
    )
    tests.expect(
        detailSource.contains("RewriteConfirmationSheet")
            && detailSource.contains("plistName:")
            && detailSource.contains("you must run the reload commands")
            && detailSource.contains("showRewriteConfirmation = true"),
        "test13_plistRewrite_requiresNamedReloadConfirmation"
    )
    tests.expect(
        detailSource.contains("Missing payload")
            && detailSource.contains("This job cannot run")
            && detailSource.contains("job.attention"),
        "test13_detail_surfacesMissingPayloadAsBrokenAlert"
    )
}

private func test14_ProvenanceFailsTowardVisibility(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round14-provenance") { root in
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let userScript = bin.appendingPathComponent("backup.py")
        try Data("print('backup')\n".utf8).write(to: userScript)
        let plist = root.appendingPathComponent("job.plist")
        try Data("plist".utf8).write(to: plist)

        let signedInterpreter = root.appendingPathComponent("python3")
        try Data("python".utf8).write(to: signedInterpreter)
        var signatureCalls = 0
        let classifier = JobProvenanceClassifier(homeDirectory: home) { _, arguments in
            signatureCalls += 1
            if arguments.contains("--verify") {
                return AdapterCommandResult(status: 0, stdout: "", stderr: "valid")
            }
            if arguments.last == signedInterpreter.path {
                return AdapterCommandResult(
                    status: 0,
                    stdout: "",
                    stderr: "Authority=Developer ID Application: Vendor Tools LLC (TEAM123)\n"
                )
            }
            return AdapterCommandResult(status: 1, stdout: "", stderr: "unsigned")
        }

        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: ["/opt/homebrew/bin/python3", userScript.path],
                configPath: plist.path
            ).provenance,
            .yours,
            "test14_homebrewInterpreter_userPayloadWins"
        )
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: [signedInterpreter.path, userScript.path],
                configPath: root.appendingPathComponent("signed-interpreter.plist").path
            ).provenance,
            .yours,
            "test14_signedInterpreter_userPayloadWins"
        )
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: [
                    "/Applications/VendorPython.app/Contents/MacOS/python3",
                    userScript.path,
                ],
                configPath: root.appendingPathComponent("vendor-interpreter.plist").path
            ).provenance,
            .yours,
            "test14_vendorPathInterpreter_userPayloadWins"
        )

        let direct = bin.appendingPathComponent("nightly")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: direct)
        let directPlist = root.appendingPathComponent("direct.plist")
        try Data("direct".utf8).write(to: directPlist)
        let healthy = classifier.classify(
            source: .launchd,
            command: [direct.path],
            configPath: directPlist.path
        )
        tests.expectEqual(
            healthy.provenance,
            .yours,
            "test14_bareHomeExecutable_isYours"
        )
        tests.expectEqual(
            healthy.attention,
            nil,
            "test14_bareHomeExecutable_exists"
        )
        try FileManager.default.removeItem(at: direct)
        let deleted = classifier.classify(
            source: .launchd,
            command: [direct.path],
            configPath: directPlist.path
        )
        tests.expectEqual(
            deleted.attention,
            .missingPayload(direct.path),
            "test14_deletedPayload_recheckedWithoutRestart"
        )

        let restored = Data("#!/bin/sh\nexit 0\n".utf8)
        try restored.write(to: direct)
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: [direct.path],
                configPath: directPlist.path
            ).attention,
            nil,
            "test14_restoredPayload_recheckedWithoutRestart"
        )

        let output = home.appendingPathComponent("output.json")
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: ["/usr/bin/curl", "-o", output.path, "https://example.com/data"],
                configPath: root.appendingPathComponent("curl.plist").path
            ).attention,
            nil,
            "test14_arbitraryAbsoluteArgument_isNotPayload"
        )

        if case .unknown = classifier.classify(
            source: .launchd,
            command: ["/opt/custom/nightly"],
            configPath: root.appendingPathComponent("opt-custom.plist").path
        ).provenance {
            tests.expect(true, "test14_unprovedOptPath_isUnattributed")
        } else {
            tests.expect(false, "test14_unprovedOptPath_isUnattributed")
        }
        tests.expectEqual(
            classifier.classify(
                source: .launchd,
                command: ["/opt/local/bin/port-job"],
                configPath: root.appendingPathComponent("macports.plist").path
            ).provenance,
            .packageManager("MacPorts"),
            "test14_macPorts_hasCorrectPackageManagerName"
        )

        let displayOnlyProgram = root.appendingPathComponent("Damaged Signature")
        try Data("damaged".utf8).write(to: displayOnlyProgram)
        let strictClassifier = JobProvenanceClassifier(homeDirectory: home) { _, arguments in
            if arguments.contains("--verify") {
                return AdapterCommandResult(status: 1, stdout: "", stderr: "invalid signature")
            }
            return AdapterCommandResult(
                status: 0,
                stdout: "",
                stderr: "Authority=Developer ID Application: Stale Vendor LLC (STALE123)\n"
            )
        }
        if case .app = strictClassifier.classify(
            source: .launchd,
            command: [displayOnlyProgram.path],
            configPath: root.appendingPathComponent("damaged.plist").path
        ).provenance {
            tests.expect(false, "test14_damagedSignature_isNotTrusted")
        } else {
            tests.expect(true, "test14_damagedSignature_isNotTrusted")
        }

        let symlinkTarget = root.appendingPathComponent("symlink-target")
        let symlinkProgram = root.appendingPathComponent("symlink-program")
        try Data("one".utf8).write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: symlinkProgram, withDestinationURL: symlinkTarget)
        var symlinkProbes = 0
        let symlinkClassifier = JobProvenanceClassifier(homeDirectory: home) { _, arguments in
            if arguments.contains("--verify") {
                return AdapterCommandResult(status: 0, stdout: "", stderr: "valid")
            }
            symlinkProbes += 1
            let data = (try? Data(contentsOf: symlinkProgram)) ?? Data()
            let vendor = data.count > 3 ? "Vendor Two" : "Vendor One"
            return AdapterCommandResult(
                status: 0,
                stdout: "",
                stderr: "Authority=Developer ID Application: \(vendor) (TEAM123)\n"
            )
        }
        let symlinkPlist = root.appendingPathComponent("symlink.plist")
        try Data("symlink".utf8).write(to: symlinkPlist)
        tests.expectEqual(
            symlinkClassifier.classify(
                source: .launchd,
                command: [symlinkProgram.path],
                configPath: symlinkPlist.path
            ).provenance,
            .app("Vendor One"),
            "test14_symlinkTarget_firstClassification"
        )
        try Data("replacement-target".utf8).write(to: symlinkTarget)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 2)],
            ofItemAtPath: symlinkTarget.path
        )
        tests.expectEqual(
            symlinkClassifier.classify(
                source: .launchd,
                command: [symlinkProgram.path],
                configPath: symlinkPlist.path
            ).provenance,
            .app("Vendor Two"),
            "test14_symlinkTargetChange_invalidatesProvenanceCache"
        )
        tests.expectEqual(symlinkProbes, 2, "test14_symlinkTargetChange_reprobesSignature")
        tests.expect(signatureCalls > 0, "test14_signatureFixtures_exerciseSignaturePath")

        let actualHome = root.appendingPathComponent("actual-home", isDirectory: true)
        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        let linkedHomeBin = actualHome.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedHomeBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: actualHome)
        let linkedHomeScript = linkedHomeBin.appendingPathComponent("nightly")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: linkedHomeScript)
        let linkedHomeClassifier = JobProvenanceClassifier(homeDirectory: linkedHome) { _, _ in
            AdapterCommandResult(status: 1, stdout: "", stderr: "unsigned")
        }
        tests.expectEqual(
            linkedHomeClassifier.classify(
                source: .launchd,
                command: [linkedHomeScript.path],
                configPath: root.appendingPathComponent("linked-home.plist").path
            ).provenance,
            .yours,
            "test14_symlinkedHome_resolvedPayloadRemainsYours"
        )

        for attention in [
            JobAttention.malformedConfiguration(path: plist.path, message: "malformed XML"),
            JobAttention.inertConfiguration(path: plist.path, message: "no runnable keys"),
            JobAttention.unreadableConfiguration(path: plist.path, message: "permission denied"),
        ] {
            tests.expectEqual(
                try JSONDecoder().decode(
                    JobAttention.self,
                    from: JSONEncoder().encode(attention)
                ),
                attention,
                "test14_newAttentionState_roundTripsThroughCodable"
            )
        }
    }
}

private func test14_LaunchdFormsAndDiagnostics(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round14-launchd") { root in
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        let work = home.appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let shellPayload = bin.appendingPathComponent("nightly")
        let relativePayload = work.appendingPathComponent("relative.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: shellPayload)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: relativePayload)

        try writePropertyList(
            [
                "Label": "com.example.test14.shell-c",
                "ProgramArguments": ["/bin/sh", "-c", "$HOME/bin/nightly --quiet"],
                "EnvironmentVariables": ["HOME": home.path],
            ],
            to: agents.appendingPathComponent("shell-c.plist")
        )
        try writePropertyList(
            [
                "Label": "com.example.test14.relative",
                "ProgramArguments": ["/bin/sh", "relative.sh"],
                "WorkingDirectory": work.path,
            ],
            to: agents.appendingPathComponent("relative.plist")
        )
        try writePropertyList(
            ["Label": "com.example.test14.empty"],
            to: agents.appendingPathComponent("empty.plist")
        )
        try writePropertyList(
            [
                "Label": "com.example.test14.shell-builtin",
                "ProgramArguments": [
                    "/bin/sh", "-c", "echo ready > /Users/example/status.txt",
                ],
            ],
            to: agents.appendingPathComponent("shell-builtin.plist")
        )

        let tickerExecutable = "/Applications/Ticker.app/Contents/MacOS/Ticker"
        let tickerLabel = "com.suchintan.ticker.login"
        try writePropertyList(
            [
                "Label": "com.example.foreign-ticker-label",
                "ProgramArguments": [tickerExecutable],
            ],
            to: agents.appendingPathComponent("com.suchintan.ticker.login.plist")
        )
        try writePropertyList(
            [
                "Label": tickerLabel,
                "Program": "/bin/false",
                "ProgramArguments": [
                    tickerExecutable,
                    "run",
                    "--ticker-wrapper-version",
                    LaunchdWrapper.currentVersion,
                    "--label",
                    tickerLabel,
                    "--",
                    tickerExecutable,
                ],
            ],
            to: agents.appendingPathComponent("ticker-program-precedence.plist")
        )
        try writePropertyList(
            [
                "Label": "com.suchintan.ticker.login.backup",
                "ProgramArguments": [tickerExecutable],
            ],
            to: agents.appendingPathComponent("com.suchintan.ticker.login.backup.plist")
        )
        try writePropertyList(
            [
                "Label": tickerLabel,
                "ProgramArguments": ["/bin/cp", tickerExecutable, bin.path],
            ],
            to: agents.appendingPathComponent("ticker-reference-only.plist")
        )
        try writePropertyList(
            [
                "Label": tickerLabel,
                "ProgramArguments": [tickerExecutable],
            ],
            to: agents.appendingPathComponent("ticker-positive.plist")
        )

        let adapter = LaunchdAdapter(
            searchDirectories: [agents],
            homeDirectory: home
        ) { _, _ in
            AdapterCommandResult(status: 1, stdout: "", stderr: "not loaded")
        }
        let jobs = try adapter.discover()
        let shellJob = try require(
            jobs.first { $0.label == "com.example.test14.shell-c" },
            "test14 shell -c job"
        )
        tests.expectEqual(shellJob.provenance, .yours, "test14_shellC_homePayload_isYours")
        tests.expectEqual(shellJob.attention, nil, "test14_shellC_statsExecutableNotCommandString")

        let relativeJob = try require(
            jobs.first { $0.label == "com.example.test14.relative" },
            "test14 relative job"
        )
        tests.expectEqual(
            relativeJob.provenance,
            .yours,
            "test14_relativePayload_resolvesAgainstWorkingDirectory"
        )
        tests.expectEqual(relativeJob.attention, nil, "test14_relativePayload_exists")

        let emptyJob = try require(
            jobs.first { $0.label == "com.example.test14.empty" },
            "test14 empty-command job"
        )
        tests.expectEqual(emptyJob.provenance, .yours, "test14_emptyUserAgent_staysOwned")
        tests.expectEqual(
            emptyJob.attention?.kind,
            "inertConfiguration",
            "test14_emptyCommand_isExplicitInertState"
        )
        let shellBuiltin = try require(
            jobs.first { $0.label == "com.example.test14.shell-builtin" },
            "test14 shell builtin job"
        )
        tests.expectEqual(
            shellBuiltin.attention,
            nil,
            "test14_shellC_doesNotStatAbsoluteRedirectionTarget"
        )

        func provenanceForConfiguration(_ filename: String) throws -> JobProvenance {
            try require(
                jobs.first { $0.configPath?.hasSuffix("/\(filename)") == true },
                "test14 launchd provenance fixture \(filename)"
            ).provenance
        }
        tests.expectEqual(
            try provenanceForConfiguration("com.suchintan.ticker.login.plist"),
            .app("Ticker"),
            "test14_adapter_foreignParsedLabelIsNotTicker"
        )
        tests.expectEqual(
            try provenanceForConfiguration("ticker-program-precedence.plist"),
            .system,
            "test14_adapter_programOverridesWrapperShapedProgramArguments"
        )
        let programPrecedenceJob = try require(
            jobs.first {
                $0.configPath?.hasSuffix("/ticker-program-precedence.plist") == true
            },
            "test14 Program precedence job"
        )
        tests.expect(
            programPrecedenceJob.command.first == "/bin/false"
                && !programPrecedenceJob.managed,
            "test14_adapter_programPrecedencePreservesLiteralLogicalCommand"
        )
        tests.expectEqual(
            try provenanceForConfiguration("com.suchintan.ticker.login.backup.plist"),
            .app("Ticker"),
            "test14_adapter_lookalikeConfigurationNameIsNotTicker"
        )
        tests.expectEqual(
            try provenanceForConfiguration("ticker-reference-only.plist"),
            .system,
            "test14_adapter_arbitraryTickerAppReferenceIsNotTicker"
        )
        tests.expectEqual(
            try provenanceForConfiguration("ticker-positive.plist"),
            .ticker,
            "test14_adapter_exactParsedFallbackIdentityIsTicker"
        )

        let directPayload = bin.appendingPathComponent("direct-nightly")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: directPayload)
        try writePropertyList(
            [
                "Label": "com.example.test14.live-delete",
                "ProgramArguments": [directPayload.path],
            ],
            to: agents.appendingPathComponent("live-delete.plist")
        )
        let healthyAttention = try adapter.discover()
            .first { $0.label == "com.example.test14.live-delete" }?.attention
        tests.expectEqual(
            healthyAttention,
            nil,
            "test14_liveAdapter_payloadInitiallyHealthy"
        )
        try FileManager.default.removeItem(at: directPayload)
        let deletedAttention = try adapter.discover()
            .first { $0.label == "com.example.test14.live-delete" }?.attention
        tests.expectEqual(
            deletedAttention,
            .missingPayload(directPayload.path),
            "test14_liveAdapter_deleteBecomesBrokenWithoutRestart"
        )
        print(
            "TRANSCRIPT test14 live-delete first=\(healthyAttention?.kind ?? "none") "
                + "second=\(deletedAttention?.kind ?? "none") adapter=same-instance"
        )
    }

    try withTemporaryDirectory("round14-malformed") { root in
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let malformed = agents.appendingPathComponent("malformed-local-job.plist")
        try Data("<?xml version=\"1.0\"?><plist><dict>".utf8).write(to: malformed)
        let adapter = LaunchdAdapter(
            searchDirectories: [agents],
            homeDirectory: home
        ) { _, _ in
            AdapterCommandResult(status: 1, stdout: "", stderr: "not loaded")
        }
        let jobs = try adapter.discover()
        let diagnostic = try require(jobs.first, "test14 malformed diagnostic job")
        tests.expectEqual(jobs.count, 1, "test14_malformedPlist_producesVisibleEntry")
        tests.expectEqual(
            diagnostic.provenance,
            .yours,
            "test14_malformedUserLaunchAgent_isConservativelyYours"
        )
        tests.expectEqual(
            diagnostic.attention?.kind,
            "malformedConfiguration",
            "test14_malformedPlist_isUrgentMalformedConfiguration"
        )
        tests.expectEqual(
            diagnostic.configPath,
            malformed.path,
            "test14_malformedPlist_preservesDiagnosticPath"
        )
        print(
            "TRANSCRIPT test14 malformed count=\(jobs.count) "
                + "provenance=\(diagnostic.provenance) "
                + "attention=\(diagnostic.attention?.kind ?? "none") "
                + "path=\(diagnostic.configPath ?? "none")"
        )
    }

    try withTemporaryDirectory("round14-unreadable-directory") { root in
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        guard Darwin.chmod(agents.path, 0) == 0 else {
            throw FixtureError.missing("test14 chmod unreadable directory")
        }
        defer { _ = Darwin.chmod(agents.path, S_IRWXU) }
        let adapter = LaunchdAdapter(
            searchDirectories: [agents],
            homeDirectory: home
        ) { _, _ in
            AdapterCommandResult(status: 1, stdout: "", stderr: "not loaded")
        }
        let jobs = try adapter.discover()
        tests.expectEqual(jobs.count, 1, "test14_unreadableDirectory_producesVisibleEntry")
        tests.expectEqual(
            jobs.first?.attention?.kind,
            "unreadableConfiguration",
            "test14_unreadableDirectory_hasInformationalConfigurationState"
        )
        tests.expectEqual(
            jobs.first?.provenance,
            .yours,
            "test14_unreadableUserLaunchAgentsDirectory_isConservativelyYours"
        )
    }
}

private func test15_ConfigurationStatesAndFilenameProvenance(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round15-configuration-states") { root in
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let daemons = root.appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)

        let malformed = agents.appendingPathComponent("broken-local-job.plist")
        try Data("<?xml version=\"1.0\"?><plist><dict>".utf8).write(to: malformed)
        tests.expect(
            FileManager.default.isReadableFile(atPath: malformed.path),
            "test15_malformedFixture_isReadable"
        )

        let inertFixtures: [(String, JobProvenance)] = [
            ("com.google.keystone.agent.plist", .app("Google")),
            ("com.google.keystone.xpcservice.plist", .app("Google")),
            ("io.island.keystone.agent.plist", .app("Island")),
            ("io.island.keystone.xpcservice.plist", .app("Island")),
            ("org.acme.helper.plist", .app("Acme")),
            ("com.home.local-stub.plist", .yours),
        ]
        for (filename, _) in inertFixtures {
            try writePropertyList([:], to: agents.appendingPathComponent(filename))
        }

        let unreadable = daemons.appendingPathComponent(
            "com.microsoft.teams.TeamsUpdaterDaemon.plist"
        )
        try writePropertyList(
            [
                "Label": "com.microsoft.teams.TeamsUpdaterDaemon",
                "ProgramArguments": ["/Library/Application Support/Microsoft/TeamsUpdater"],
            ],
            to: unreadable
        )
        guard Darwin.chmod(unreadable.path, 0) == 0 else {
            throw FixtureError.missing("test15 chmod unreadable daemon")
        }
        defer { _ = Darwin.chmod(unreadable.path, S_IRUSR | S_IWUSR) }
        tests.expect(
            !FileManager.default.isReadableFile(atPath: unreadable.path),
            "test15_unreadableFixture_deniesNormalRead"
        )

        let adapter = LaunchdAdapter(
            searchDirectories: [agents, daemons],
            homeDirectory: home
        ) { _, _ in
            AdapterCommandResult(status: 1, stdout: "", stderr: "not loaded")
        }
        let jobs = try adapter.discover()
        tests.expectEqual(
            jobs.count,
            inertFixtures.count + 2,
            "test15_allMalformedInertAndUnreadableEntries_stayDiscoverable"
        )

        let malformedJob = try require(
            jobs.first { $0.configPath == malformed.path },
            "test15 malformed job"
        )
        tests.expectEqual(
            malformedJob.attention?.kind,
            "malformedConfiguration",
            "test15_malformedReadablePlist_hasMalformedState"
        )
        tests.expectEqual(
            malformedJob.provenance,
            .yours,
            "test15_handBrokenPlistWithoutVendorIdentity_fallsBackToOwnerLocation"
        )
        tests.expect(
            malformedJob.isBroken,
            "test15_malformedReadablePlist_isBrokenAndAlerts"
        )

        for (filename, expectedProvenance) in inertFixtures {
            let path = agents.appendingPathComponent(filename).path
            let job = try require(
                jobs.first { $0.configPath == path },
                "test15 inert job \(filename)"
            )
            tests.expectEqual(
                job.attention?.kind,
                "inertConfiguration",
                "test15_inert_\(filename)_hasInertState"
            )
            tests.expectEqual(
                job.provenance,
                expectedProvenance,
                "test15_inert_\(filename)_usesFilenameIdentityBeforeLocation"
            )
            tests.expect(
                !job.isBroken,
                "test15_inert_\(filename)_isQuiet"
            )
        }

        let unreadableJob = try require(
            jobs.first { $0.configPath == unreadable.path },
            "test15 unreadable job"
        )
        tests.expectEqual(
            unreadableJob.attention?.kind,
            "unreadableConfiguration",
            "test15_permissionDeniedPlist_hasUnreadableState"
        )
        tests.expectEqual(
            unreadableJob.provenance,
            .app("Microsoft"),
            "test15_permissionDeniedVendorPlist_usesFilenameVendor"
        )
        tests.expect(
            !unreadableJob.isBroken,
            "test15_permissionDeniedPlist_isQuiet"
        )
        tests.expect(
            unreadableJob.attention?.detail.localizedCaseInsensitiveContains("elevated access")
                == true,
            "test15_permissionDeniedPlist_plainlyExplainsElevatedAccess"
        )
        tests.expectEqual(
            jobs.filter(\.isBroken).count,
            1,
            "test15_onlyMalformedConfigurationAlertsAcrossThreeStates"
        )
    }
}

private func test15_InformationalStatePresentationContract(_ tests: TestHarness) throws {
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let modelSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerCore/Models.swift"),
        encoding: .utf8
    )
    let appModelSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerApp/AppModel.swift"),
        encoding: .utf8
    )
    let listSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerApp/JobListView.swift"),
        encoding: .utf8
    )
    let detailSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerApp/JobDetailView.swift"),
        encoding: .utf8
    )
    tests.expect(
        modelSource.contains("attention?.requiresAttention ?? false"),
        "test15_isBroken_usesTypedAttentionSeverity"
    )
    tests.expect(
        appModelSource.contains("if job.isBroken"),
        "test15_appAttention_usesBrokenStateInsteadOfDiagnosticPresence"
    )
    tests.expect(
        listSource.contains("attention.requiresAttention"),
        "test15_jobList_rendersInformationalDiagnosticsQuietly"
    )
    tests.expect(
        detailSource.contains("attention.requiresAttention"),
        "test15_jobDetail_rendersInformationalDiagnosticsQuietly"
    )
}

private func test14_UISafetyContract(_ tests: TestHarness) throws {
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let listSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerApp/JobListView.swift"),
        encoding: .utf8
    )
    let modelSource = try String(
        contentsOf: repository.appendingPathComponent("Sources/TickerApp/AppModel.swift"),
        encoding: .utf8
    )
    tests.expect(
        listSource.contains("Section(\"Needs Review\")")
            && !listSource.contains("subgroupHeader(\"Unknown Owners\"")
            && listSource.contains("unattributedJobs"),
        "test14_unattributedJobs_haveVisibleTopLevelGroup"
    )
    tests.expect(
        listSource.contains("matchingJobs.first { $0.id == selectedJobID }")
            && listSource.contains("onChange(of: searchText)"),
        "test14_search_reconcilesHiddenSelection"
    )
    tests.expect(
        listSource.contains("allYourJobs.isEmpty && !allOtherJobs.isEmpty"),
        "test14_onlyOtherJobs_autoExpandsVisibleRows"
    )
    let confirmedThirdPartyRowContracts: [(JobProvenance, [String])] = [
        (.ticker, ["tickerJobs", "jobRows(tickerJobs)", "subgroupHeader(\"Ticker\""]),
        (.app("Example"), ["appJobs", "jobRows(appJobs.filter"]),
        (.packageManager("Example"), ["packageManagerJobs", "jobRows(packageManagerJobs)"]),
        (.system, ["systemJobs", "jobRows(systemJobs)"]),
    ]
    for (provenance, rowPathTokens) in confirmedThirdPartyRowContracts {
        tests.expect(
            provenance.isConfirmedThirdParty
                && rowPathTokens.allSatisfy { listSource.contains($0) },
            "test14_confirmedThirdParty_\(provenance.kind)_hasVisibleRowPath"
        )
    }
    tests.expect(
        listSource.contains("otherJobs.filter { $0.provenance == .ticker }")
            && listSource.contains("Text(\"Other Jobs\")")
            && listSource.contains("allOtherJobs.count"),
        "test14_tickerSubgroup_rowsAndOtherJobsCountUseSamePopulation"
    )
    tests.expect(
        listSource.contains("lastPathComponent")
            && listSource.contains("shortID")
            && listSource.contains("let now = Date()")
            && listSource.contains("nextFire(after: now"),
        "test14_displayCollisionsAndSortBoundary_areDeterministic"
    )
    tests.expect(
        modelSource.contains("provenance.isAttentionOwned")
            && modelSource.contains("needsAttention($0)"),
        "test14_unattributedBrokenJob_canReddenMenuBar"
    )
    tests.expect(
        modelSource.contains("RunStorePathPolicy.configuredPath")
            && modelSource.contains("TICKER_TEST_BACKUP_DIRECTORY")
            && modelSource.contains("#if TICKER_TESTING"),
        "test14_testBuild_canFullyIsolateAppSmokeState"
    )
}


private func test16_LoginAtBootAndFallbackVerification(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round16-login-fallback") { root in
        let agentTarget = "gui/\(getuid())/com.suchintan.ticker.login"
        let agentPlist = root
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.suchintan.ticker.login.plist")
        let installedExecutable = "/Applications/Ticker.app/Contents/MacOS/Ticker"

        func fallbackPlistURL(for home: URL) -> URL {
            home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("com.suchintan.ticker.login.plist")
        }

        func writeFallbackPlist(
            home: URL,
            label: String = "com.suchintan.ticker.login",
            arguments: [String],
            program: String? = nil
        ) throws {
            let url = fallbackPlistURL(for: home)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var propertyList: [String: Any] = [
                "Label": label,
                "ProgramArguments": arguments,
                "RunAtLoad": true,
            ]
            if let program {
                propertyList["Program"] = program
            }
            let data = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )
            try data.write(to: url, options: .atomic)
        }

        func liveServiceOutput(executable: String) -> String {
            """
            \(agentTarget) = {
                state = running
                program = \(executable)
            }
            """
        }

        let stagedBundle = root.appendingPathComponent(
            "staged/Ticker.app",
            isDirectory: true
        )
        let stagedHelper = stagedBundle.appendingPathComponent(
            "Contents/Helpers/ticker",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: stagedHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: stagedHelper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stagedHelper.path
        )
        let stagedCLISymlink = root.appendingPathComponent("bin/ticker")
        try FileManager.default.createDirectory(
            at: stagedCLISymlink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: stagedCLISymlink,
            withDestinationURL: stagedHelper
        )
        let resolvedStagedBundle = LoginItemController.bundlePath(
            enclosingHelperExecutableAt: stagedCLISymlink.path
        )
        let actualStagedBundlePath = stagedBundle
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        tests.expectEqual(
            resolvedStagedBundle,
            actualStagedBundlePath,
            "test16_loginHelper_symlinkResolvesToActualStagedBundle"
        )

        var stagedMutationLaunchctlCalls: [[String]] = []
        var stagedMutationServiceQueries = 0
        var stagedMutationRegisterCalls = 0
        var stagedMutationUnregisterCalls = 0
        let stagedMutationController = LoginItemController(
            bundlePath: resolvedStagedBundle,
            homeDirectory: root.appendingPathComponent("staged-mutation-home"),
            launchctl: { arguments in
                stagedMutationLaunchctlCalls.append(arguments)
                return LoginItemCommandResult(status: 0)
            },
            serviceState: {
                stagedMutationServiceQueries += 1
                return .enabled
            },
            registerService: { stagedMutationRegisterCalls += 1 },
            unregisterService: { stagedMutationUnregisterCalls += 1 }
        )
        let expectedStagedRejection = LoginItemState.notInstalled(
            running: actualStagedBundlePath,
            expected: LoginItemController.installedBundlePath
        )
        tests.expectEqual(
            stagedMutationController.enable(),
            expectedStagedRejection,
            "test16_stagedHelper_enableIsRejectedAsNotInstalled"
        )
        tests.expectEqual(
            stagedMutationController.disable(),
            expectedStagedRejection,
            "test16_stagedHelper_disableIsRejectedAsNotInstalled"
        )
        tests.expect(
            stagedMutationLaunchctlCalls.isEmpty
                && stagedMutationServiceQueries == 0
                && stagedMutationRegisterCalls == 0
                && stagedMutationUnregisterCalls == 0,
            "test16_stagedHelper_mutationsPerformNoServiceManagementOrLaunchctlWork"
        )

        var stagedStatusLaunchctlCalls: [[String]] = []
        var stagedStatusServiceQueries = 0
        var stagedStatusMutationCalls = 0
        let stagedStatusController = LoginItemController(
            bundlePath: resolvedStagedBundle,
            homeDirectory: root.appendingPathComponent("staged-status-home"),
            launchctl: { arguments in
                stagedStatusLaunchctlCalls.append(arguments)
                return LoginItemCommandResult(status: 113, stderr: "Could not find service")
            },
            serviceState: {
                stagedStatusServiceQueries += 1
                return .disabled
            },
            registerService: { stagedStatusMutationCalls += 1 },
            unregisterService: { stagedStatusMutationCalls += 1 }
        )
        tests.expectEqual(
            stagedStatusController.state(),
            .disabled,
            "test16_stagedHelper_statusStillQueriesLiveState"
        )
        tests.expect(
            stagedStatusLaunchctlCalls
                == [["print", agentTarget], ["print", agentTarget]]
                && stagedStatusServiceQueries == 1
                && stagedStatusMutationCalls == 0,
            "test16_stagedHelper_statusIsReadOnly"
        )

        let stagedProcessBundle = root.appendingPathComponent(
            "staged-process/Ticker.app",
            isDirectory: true
        )
        let stagedProcessHelper = stagedProcessBundle.appendingPathComponent(
            "Contents/Helpers/ticker",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: stagedProcessHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            atPath: test3A_builtCLIPath(),
            toPath: stagedProcessHelper.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stagedProcessHelper.path
        )
        let stagedProcessHome = root.appendingPathComponent(
            "staged-process-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagedProcessHome,
            withIntermediateDirectories: true
        )
        let stagedProcessEnvironment = [
            "TICKER_TEST_LOGIN_ITEM_HOME": stagedProcessHome.path
        ]
        let stagedProcessPath = stagedProcessBundle
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let stagedProcessDiagnostic =
            "not installed: running from \(stagedProcessPath), "
            + "expected \(LoginItemController.installedBundlePath)\n"

        let stagedProcessEnable = try test3A_runProcess(
            stagedProcessHelper.path,
            ["login-item", "enable"],
            environment: stagedProcessEnvironment
        )
        tests.expectEqual(
            stagedProcessEnable.status,
            1,
            "test16_stagedCLIProcess_enableReturnsNonzero"
        )
        tests.expectEqual(
            stagedProcessEnable.stdout,
            stagedProcessDiagnostic,
            "test16_stagedCLIProcess_enablePrintsNotInstalledDiagnostic"
        )
        tests.expectEqual(
            stagedProcessEnable.stderr,
            "ticker: could not change the login item\n",
            "test16_stagedCLIProcess_enableReportsRejectedMutation"
        )

        let stagedProcessDisable = try test3A_runProcess(
            stagedProcessHelper.path,
            ["login-item", "disable"],
            environment: stagedProcessEnvironment
        )
        tests.expectEqual(
            stagedProcessDisable.status,
            1,
            "test16_stagedCLIProcess_disableReturnsNonzero"
        )
        tests.expectEqual(
            stagedProcessDisable.stdout,
            stagedProcessDiagnostic,
            "test16_stagedCLIProcess_disablePrintsNotInstalledDiagnostic"
        )
        tests.expectEqual(
            stagedProcessDisable.stderr,
            "ticker: could not change the login item\n",
            "test16_stagedCLIProcess_disableReportsRejectedMutation"
        )

        let stagedProcessStatus = try test3A_runProcess(
            stagedProcessHelper.path,
            ["login-item", "status"],
            environment: stagedProcessEnvironment
        )
        tests.expectEqual(
            stagedProcessStatus.status,
            0,
            "test16_stagedCLIProcess_statusReturnsZero"
        )
        tests.expectEqual(
            stagedProcessStatus.stdout,
            "disabled\n",
            "test16_stagedCLIProcess_statusRemainsReadOnly"
        )
        tests.expectEqual(
            stagedProcessStatus.stderr,
            "",
            "test16_stagedCLIProcess_statusReportsNoError"
        )

        let stagedConflictHome = root.appendingPathComponent(
            "staged-conflict-process-home",
            isDirectory: true
        )
        try writeFallbackPlist(
            home: stagedConflictHome,
            arguments: [installedExecutable]
        )
        var stagedConflictEnvironment = stagedProcessEnvironment
        stagedConflictEnvironment["TICKER_TEST_LOGIN_ITEM_HOME"] =
            stagedConflictHome.path
        stagedConflictEnvironment["TICKER_TEST_LOGIN_ITEM_AGENT_STATE"] = "live"
        stagedConflictEnvironment["TICKER_TEST_LOGIN_ITEM_SERVICE_STATE"] = "enabled"
        let stagedConflictStatus = try test3A_runProcess(
            stagedProcessHelper.path,
            ["login-item", "status"],
            environment: stagedConflictEnvironment
        )
        tests.expectEqual(
            stagedConflictStatus.status,
            1,
            "test16_loginCLI_conflictingMechanismsReturnNonzero"
        )
        tests.expectEqual(
            stagedConflictStatus.stdout,
            "failed: Login item conflict: LaunchAgent is live while the System Settings "
                + "login item is enabled.\n",
            "test16_loginCLI_conflictingMechanismsPrintConflict"
        )
        tests.expectEqual(
            stagedConflictStatus.stderr,
            "ticker: could not change the login item\n",
            "test16_loginCLI_conflictingMechanismsReportOperationFailure"
        )

        let stagedProcessImplicitStatus = try test3A_runProcess(
            stagedProcessHelper.path,
            ["login-item"],
            environment: stagedProcessEnvironment
        )
        tests.expectEqual(
            stagedProcessImplicitStatus.status,
            0,
            "test16_loginCLI_zeroArgumentsDefaultsToStatus"
        )
        tests.expectEqual(
            stagedProcessImplicitStatus.stdout,
            "disabled\n",
            "test16_loginCLI_zeroArgumentsReadsStatus"
        )

        let stagedProcessExtraArgument = try test3A_runProcess(
            stagedProcessHelper.path,
            ["login-item", "enable", "--typo"],
            environment: stagedProcessEnvironment
        )
        tests.expectEqual(
            stagedProcessExtraArgument.status,
            2,
            "test16_loginCLI_extraArgumentReturnsUsageTwo"
        )
        tests.expectEqual(
            stagedProcessExtraArgument.stdout,
            "",
            "test16_loginCLI_extraArgumentProducesNoStateOutput"
        )
        tests.expectEqual(
            stagedProcessExtraArgument.stderr,
            "ticker: login-item accepts no arguments or exactly one of status, enable, or disable\n"
                + "Run 'ticker --help' for usage.\n",
            "test16_loginCLI_extraArgumentReportsUsage"
        )
        tests.expectEqual(
            try FileManager.default.contentsOfDirectory(atPath: stagedProcessHome.path),
            [],
            "test16_loginCLI_extraArgumentLeavesMutationHomeUntouched"
        )

        func assertStalePlistRepair(
            homeName: String,
            staleExecutable: String,
            testName: String
        ) throws {
            let home = root.appendingPathComponent(homeName, isDirectory: true)
            try writeFallbackPlist(home: home, arguments: [staleExecutable])
            var loadedExecutable: String? = staleExecutable
            var calls: [[String]] = []
            let controller = LoginItemController(
                bundlePath: LoginItemController.installedBundlePath,
                homeDirectory: home,
                launchctl: { arguments in
                    calls.append(arguments)
                    switch arguments.first {
                    case "bootstrap":
                        loadedExecutable = installedExecutable
                        return LoginItemCommandResult(status: 0)
                    case "bootout":
                        loadedExecutable = nil
                        return LoginItemCommandResult(status: 0)
                    case "print":
                        guard let loadedExecutable else {
                            return absentAgentResult()
                        }
                        return LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: loadedExecutable)
                        )
                    default:
                        return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                    }
                },
                serviceState: { .disabled },
                registerService: {},
                unregisterService: {}
            )

            tests.expectEqual(
                controller.enable(),
                .enabled(mechanism: .launchAgent),
                "\(testName)_returnsEnabledAfterReplacement"
            )
            tests.expect(
                calls.contains(["bootout", agentTarget]),
                "\(testName)_bootsOutStaleService"
            )
            tests.expect(
                calls.contains(["bootstrap", "gui/\(getuid())", fallbackPlistURL(for: home).path]),
                "\(testName)_bootstrapsReplacementPlist"
            )
            let installedData = try Data(contentsOf: fallbackPlistURL(for: home))
            let installedPropertyList = try PropertyListSerialization.propertyList(
                from: installedData,
                options: [],
                format: nil
            )
            let installedDictionary = installedPropertyList as? [String: Any]
            tests.expect(
                installedDictionary?["Label"] as? String == "com.suchintan.ticker.login"
                    && installedDictionary?["ProgramArguments"] as? [String]
                        == [installedExecutable],
                "\(testName)_writesExactInstalledTarget"
            )
        }

        let bootstrapFailureHome = root.appendingPathComponent(
            "bootstrap-failure-home",
            isDirectory: true
        )
        var bootstrapFailureCalls: [[String]] = []
        var bootstrapFailureAgentIsLoaded = false
        let bootstrapFailureController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: bootstrapFailureHome,
            launchctl: { arguments in
                bootstrapFailureCalls.append(arguments)
                switch arguments.first {
                case "bootstrap":
                    bootstrapFailureAgentIsLoaded = true
                    return LoginItemCommandResult(status: 5, stderr: "permission denied")
                case "bootout":
                    bootstrapFailureAgentIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                case "print":
                    return bootstrapFailureAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let bootstrapFailureState = bootstrapFailureController.enable()
        tests.expect(
            {
                guard case .failed(let reason) = bootstrapFailureState else { return false }
                return reason.contains("bootstrap failed with exit status 5")
                    && reason.contains("permission denied")
            }(),
            "test16_loginFallback_bootstrapFailureReturnsFailure"
        )
        let bootstrapFailurePlist = bootstrapFailureHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.suchintan.ticker.login.plist")
        tests.expect(
            !FileManager.default.fileExists(atPath: bootstrapFailurePlist.path),
            "test16_loginFallback_bootstrapFailureRemovesUnusablePlist"
        )
        tests.expect(
            bootstrapFailureCalls.contains(["bootout", agentTarget]),
            "test16_loginFallback_bootstrapFailureUnloadsUnusableService"
        )

        let verificationCleanupHome = root.appendingPathComponent(
            "verification-cleanup-failure-home",
            isDirectory: true
        )
        var verificationCleanupAgentIsLoaded = false
        var verificationCleanupBootoutCalls = 0
        var verificationCleanupCalls: [[String]] = []
        let verificationCleanupController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: verificationCleanupHome,
            launchctl: { arguments in
                verificationCleanupCalls.append(arguments)
                switch arguments.first {
                case "bootstrap":
                    verificationCleanupAgentIsLoaded = true
                    return LoginItemCommandResult(status: 0)
                case "bootout":
                    verificationCleanupBootoutCalls += 1
                    return LoginItemCommandResult(status: 5, stderr: "injected compensation denial")
                case "print":
                    return verificationCleanupAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: "/usr/local/bin/not-ticker")
                        )
                        : absentAgentResult()
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let verificationCleanupState = verificationCleanupController.enable()
        tests.expect(
            {
                guard case .failed(let reason) = verificationCleanupState else { return false }
                return reason.contains("did not report exact executable")
                    && reason.contains("also could not remove the unusable fallback")
                    && reason.contains("bootout failed with exit status 5")
                    && reason.contains("remains loaded")
            }(),
            "test16_loginFallback_verificationAndCompensationFailuresAreCombined"
        )
        tests.expect(
            verificationCleanupAgentIsLoaded
                && verificationCleanupBootoutCalls == 3
                && verificationCleanupCalls.contains { $0.first == "bootstrap" }
                && !FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: verificationCleanupHome).path
                ),
            "test16_loginFallback_failedVerificationCannotClaimProvenRemoval"
        )

        let verifiedHome = root.appendingPathComponent("verified-home", isDirectory: true)
        var verifiedCalls: [[String]] = []
        var verifiedAgentIsLoaded = false
        let verifiedController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: verifiedHome,
            launchctl: { arguments in
                verifiedCalls.append(arguments)
                switch arguments.first {
                case "bootstrap":
                    verifiedAgentIsLoaded = true
                    return LoginItemCommandResult(status: 0)
                case "bootout":
                    verifiedAgentIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                case "print":
                    return verifiedAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            verifiedController.enable(),
            .enabled(mechanism: .launchAgent),
            "test16_loginFallback_verifiedBootstrapReturnsEnabled"
        )
        tests.expectEqual(
            verifiedController.state(),
            .enabled(mechanism: .launchAgent),
            "test16_loginFallback_stateReadsVerifiedLiveService"
        )
        tests.expect(
            verifiedCalls.contains(["print", agentTarget]),
            "test16_loginFallback_verifiesExactLaunchctlTarget"
        )
        let exactTargetHome = root.appendingPathComponent(
            "exact-target-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: exactTargetHome, arguments: [installedExecutable])
        var exactTargetCalls: [[String]] = []
        let exactTargetController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: exactTargetHome,
            launchctl: { arguments in
                exactTargetCalls.append(arguments)
                if arguments.first == "print" {
                    return LoginItemCommandResult(
                        status: 0,
                        stdout: liveServiceOutput(executable: installedExecutable)
                    )
                }
                return LoginItemCommandResult(status: 0)
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            exactTargetController.state(),
            .enabled(mechanism: .launchAgent),
            "test16_loginFallback_exactPlistAndLoadedTargetAreEnabled"
        )
        tests.expect(
            !exactTargetCalls.contains { $0.first == "bootstrap" || $0.first == "bootout" },
            "test16_loginFallback_exactTargetNeedsNoReplacement"
        )

        let conflictServiceStates: [(LoginItemServiceState, String)] = [
            (.enabled, "enabled"),
            (.requiresApproval, "registered and requiring approval"),
            (.indeterminate, "indeterminate"),
        ]
        for (index, conflictServiceState) in conflictServiceStates.enumerated() {
            let conflictHome = root.appendingPathComponent(
                "live-agent-conflict-\(index)",
                isDirectory: true
            )
            try writeFallbackPlist(
                home: conflictHome,
                arguments: [installedExecutable]
            )
            var conflictServiceQueries = 0
            let conflictController = LoginItemController(
                bundlePath: LoginItemController.installedBundlePath,
                homeDirectory: conflictHome,
                launchctl: { arguments in
                    arguments.first == "print"
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : LoginItemCommandResult(status: -1, stderr: "unexpected command")
                },
                serviceState: {
                    conflictServiceQueries += 1
                    return conflictServiceState.0
                },
                registerService: {},
                unregisterService: {}
            )
            let conflictState = conflictController.state()
            tests.expect(
                {
                    guard case .failed(let reason) = conflictState else { return false }
                    return reason.contains("Login item conflict")
                        && reason.contains(conflictServiceState.1)
                }(),
                "test16_loginState_liveLaunchAgentConflict\(index)ReturnsFailure"
            )
            tests.expectEqual(
                conflictServiceQueries,
                1,
                "test16_loginState_liveLaunchAgentConflict\(index)UsesFreshServiceRead"
            )
        }

        let absentToLiveHome = root.appendingPathComponent(
            "state-absent-to-live-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: absentToLiveHome, arguments: [installedExecutable])
        let exactLiveResult = LoginItemCommandResult(
            status: 0,
            stdout: liveServiceOutput(executable: installedExecutable)
        )
        var absentToLivePrintResults = [
            absentAgentResult(),
            exactLiveResult,
            exactLiveResult,
            exactLiveResult,
        ]
        var absentToLiveServiceReads = 0
        let absentToLiveController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: absentToLiveHome,
            launchctl: { arguments in
                guard arguments == ["print", agentTarget],
                      !absentToLivePrintResults.isEmpty
                else {
                    return LoginItemCommandResult(
                        status: -1,
                        stderr: "unexpected command or extra probe"
                    )
                }
                return absentToLivePrintResults.removeFirst()
            },
            serviceState: {
                absentToLiveServiceReads += 1
                return .disabled
            },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            absentToLiveController.state(),
            .enabled(mechanism: .launchAgent),
            "test16_loginState_absentToLiveRetriesUntilLaunchAgentObservationIsStable"
        )
        tests.expect(
            absentToLivePrintResults.isEmpty && absentToLiveServiceReads == 2,
            "test16_loginState_absentToLiveUsesTwoBoundedPairedObservations"
        )

        let liveToStoppedHome = root.appendingPathComponent(
            "state-live-to-stopped-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: liveToStoppedHome, arguments: [installedExecutable])
        var liveToStoppedPrintResults = [
            exactLiveResult,
            absentAgentResult(),
            absentAgentResult(),
            absentAgentResult(),
        ]
        var liveToStoppedServiceStates = [
            LoginItemServiceState.disabled,
            LoginItemServiceState.enabled,
        ]
        let liveToStoppedController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: liveToStoppedHome,
            launchctl: { arguments in
                guard arguments == ["print", agentTarget],
                      !liveToStoppedPrintResults.isEmpty
                else {
                    return LoginItemCommandResult(
                        status: -1,
                        stderr: "unexpected command or extra probe"
                    )
                }
                return liveToStoppedPrintResults.removeFirst()
            },
            serviceState: {
                guard !liveToStoppedServiceStates.isEmpty else {
                    return .indeterminate
                }
                return liveToStoppedServiceStates.removeFirst()
            },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            liveToStoppedController.state(),
            .enabled(mechanism: .serviceManagement),
            "test16_loginState_liveToStoppedRetriesAndMapsStableAbsenceToFreshServiceState"
        )
        tests.expect(
            liveToStoppedPrintResults.isEmpty && liveToStoppedServiceStates.isEmpty,
            "test16_loginState_liveToStoppedDoesNotReturnStaleLaunchAgentSuccess"
        )

        let changingTargetHome = root.appendingPathComponent(
            "state-changing-target-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: changingTargetHome, arguments: [installedExecutable])
        var changingTargetPrintResults = [
            absentAgentResult(),
            exactLiveResult,
            exactLiveResult,
            absentAgentResult(),
            absentAgentResult(),
            exactLiveResult,
        ]
        var changingTargetServiceReads = 0
        let changingTargetController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: changingTargetHome,
            launchctl: { arguments in
                guard arguments == ["print", agentTarget],
                      !changingTargetPrintResults.isEmpty
                else {
                    return LoginItemCommandResult(
                        status: -1,
                        stderr: "unexpected command or extra probe"
                    )
                }
                return changingTargetPrintResults.removeFirst()
            },
            serviceState: {
                changingTargetServiceReads += 1
                return .disabled
            },
            registerService: {},
            unregisterService: {}
        )
        let changingTargetState = changingTargetController.state()
        tests.expect(
            {
                guard case .failed(let reason) = changingTargetState else { return false }
                return reason.contains("did not converge after 3 paired observation attempts")
                    && reason.contains(
                        "exact LaunchAgent target changed between reads"
                    )
            }(),
            "test16_loginState_changingTargetReturnsBoundedExhaustionDiagnostic"
        )
        tests.expect(
            changingTargetPrintResults.isEmpty && changingTargetServiceReads == 3,
            "test16_loginState_changingTargetStopsAtThreePairedObservations"
        )

        func assertFinalLaunchAgentProofReconcilesServiceTransition(
            _ transition: LoginItemServiceState,
            startsLoaded: Bool,
            expected: LoginItemState,
            testName: String
        ) throws {
            let home = root.appendingPathComponent(testName, isDirectory: true)
            if startsLoaded {
                try writeFallbackPlist(home: home, arguments: [installedExecutable])
            }
            var agentIsLoaded = startsLoaded
            var service = LoginItemServiceState.disabled
            var printCalls = 0
            var didTransition = false
            var events: [String] = []
            let transitionPrintCall = startsLoaded ? 2 : 5
            let controller = LoginItemController(
                bundlePath: LoginItemController.installedBundlePath,
                homeDirectory: home,
                launchctl: { arguments in
                    events.append(arguments.joined(separator: " "))
                    switch arguments.first {
                    case "bootstrap":
                        agentIsLoaded = true
                        return LoginItemCommandResult(status: 0)
                    case "bootout":
                        agentIsLoaded = false
                        return LoginItemCommandResult(status: 0)
                    case "print":
                        printCalls += 1
                        if agentIsLoaded
                            && printCalls == transitionPrintCall
                            && !didTransition {
                            didTransition = true
                            service = transition
                            events.append("service-transition")
                        }
                        return agentIsLoaded
                            ? LoginItemCommandResult(
                                status: 0,
                                stdout: liveServiceOutput(executable: installedExecutable)
                            )
                            : absentAgentResult()
                    default:
                        return LoginItemCommandResult(
                            status: -1,
                            stderr: "unexpected command"
                        )
                    }
                },
                serviceState: {
                    events.append("service-read-\(service)")
                    return service
                },
                registerService: {},
                unregisterService: {
                    events.append("unregister-service")
                    service = .disabled
                }
            )

            tests.expectEqual(
                controller.enable(),
                expected,
                "\(testName)_returnsReconciledMechanism"
            )
            tests.expect(
                didTransition,
                "\(testName)_changesServiceDuringExactFinalLaunchAgentProbe"
            )
            let transitionIndex = events.firstIndex(of: "service-transition")
            let followingServiceReadIndex = events.indices.first {
                guard let transitionIndex else { return false }
                return $0 > transitionIndex && events[$0].hasPrefix("service-read-")
            }
            tests.expect(
                transitionIndex != nil && followingServiceReadIndex != nil,
                "\(testName)_feedsPostLaunchAgentServiceReadBackIntoReconciliation"
            )
            switch expected {
            case .enabled(mechanism: .serviceManagement):
                tests.expect(
                    !agentIsLoaded
                        && !FileManager.default.fileExists(
                            atPath: fallbackPlistURL(for: home).path
                        ),
                    "\(testName)_removesLaunchAgentWhenServiceWins"
                )
            case .enabled(mechanism: .launchAgent):
                tests.expect(
                    agentIsLoaded
                        && service == .disabled
                        && FileManager.default.fileExists(
                            atPath: fallbackPlistURL(for: home).path
                        ),
                    "\(testName)_restoresOnlyLaunchAgentAfterServiceCleanup"
                )
            default:
                tests.expect(false, "\(testName)_hasSupportedExpectedState")
            }
        }

        for startsLoaded in [true, false] {
            let pathName = startsLoaded ? "existing" : "activated"
            try assertFinalLaunchAgentProofReconcilesServiceTransition(
                .enabled,
                startsLoaded: startsLoaded,
                expected: .enabled(mechanism: .serviceManagement),
                testName: "test16_fixedPoint_\(pathName)LAEnabledTransition"
            )
            try assertFinalLaunchAgentProofReconcilesServiceTransition(
                .requiresApproval,
                startsLoaded: startsLoaded,
                expected: .enabled(mechanism: .launchAgent),
                testName: "test16_fixedPoint_\(pathName)LAPendingTransition"
            )
            try assertFinalLaunchAgentProofReconcilesServiceTransition(
                .indeterminate,
                startsLoaded: startsLoaded,
                expected: .enabled(mechanism: .launchAgent),
                testName: "test16_fixedPoint_\(pathName)LAIndeterminateTransition"
            )
        }

        let unloadedExactPlistHome = root.appendingPathComponent(
            "unloaded-exact-plist-home",
            isDirectory: true
        )
        try writeFallbackPlist(
            home: unloadedExactPlistHome,
            arguments: [installedExecutable]
        )
        let unloadedExactPlistController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: unloadedExactPlistHome,
            launchctl: { arguments in
                arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected command")
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            unloadedExactPlistController.state(),
            .disabled,
            "test16_loginFallback_plistPresenceCannotOverrideLiveServiceAbsence"
        )

        let enabledServiceDormantPlistHome = root.appendingPathComponent(
            "enabled-service-dormant-plist-home",
            isDirectory: true
        )
        try writeFallbackPlist(
            home: enabledServiceDormantPlistHome,
            arguments: [installedExecutable]
        )
        var enabledServiceDormantPlistCalls: [[String]] = []
        var enabledServiceDormantPlistRegisterWasCalled = false
        let enabledServiceDormantPlistController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: enabledServiceDormantPlistHome,
            launchctl: { arguments in
                enabledServiceDormantPlistCalls.append(arguments)
                return arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected mutation")
            },
            serviceState: { .enabled },
            registerService: { enabledServiceDormantPlistRegisterWasCalled = true },
            unregisterService: {}
        )
        tests.expectEqual(
            enabledServiceDormantPlistController.enable(),
            .enabled(mechanism: .serviceManagement),
            "test16_loginEnable_enabledServiceWinsOverDormantLaunchAgentPlist"
        )
        tests.expect(
            enabledServiceDormantPlistCalls.filter { $0.first == "print" }.count == 5
                && enabledServiceDormantPlistCalls.filter { $0.first == "bootout" }.count == 1
                && !enabledServiceDormantPlistRegisterWasCalled
                && !FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: enabledServiceDormantPlistHome).path
                ),
            "test16_loginEnable_enabledServiceRemovesDormantLaunchAgentSource"
        )

        let enabledToPendingHome = root.appendingPathComponent(
            "loaded-agent-enabled-service-becomes-pending-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: enabledToPendingHome, arguments: [installedExecutable])
        var enabledToPendingAgentIsLoaded = true
        var enabledToPendingServiceState = LoginItemServiceState.enabled
        var enabledToPendingEvents: [String] = []
        var enabledToPendingUnregisterCalls = 0
        var enabledToPendingRegisterCalls = 0
        let enabledToPendingController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: enabledToPendingHome,
            launchctl: { arguments in
                enabledToPendingEvents.append(arguments.joined(separator: " "))
                switch arguments.first {
                case "bootstrap":
                    enabledToPendingAgentIsLoaded = true
                    return LoginItemCommandResult(status: 0)
                case "bootout":
                    enabledToPendingAgentIsLoaded = false
                    if enabledToPendingServiceState == .enabled {
                        enabledToPendingServiceState = .requiresApproval
                    }
                    return LoginItemCommandResult(status: 0)
                case "print":
                    return enabledToPendingAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { enabledToPendingServiceState },
            registerService: { enabledToPendingRegisterCalls += 1 },
            unregisterService: {
                enabledToPendingEvents.append("unregister-service")
                enabledToPendingUnregisterCalls += 1
                enabledToPendingServiceState = .disabled
            }
        )
        tests.expectEqual(
            enabledToPendingController.enable(),
            .enabled(mechanism: .launchAgent),
            "test16_loginEnable_postRemovalPendingServiceEstablishesFallback"
        )
        let enabledToPendingUnregisterIndex = enabledToPendingEvents.firstIndex(
            of: "unregister-service"
        )
        let enabledToPendingBootstrapIndex = enabledToPendingEvents.firstIndex {
            $0.hasPrefix("bootstrap ")
        }
        tests.expect(
            enabledToPendingUnregisterCalls == 1
                && enabledToPendingRegisterCalls == 0
                && enabledToPendingUnregisterIndex != nil
                && enabledToPendingBootstrapIndex != nil
                && enabledToPendingUnregisterIndex! < enabledToPendingBootstrapIndex!
                && enabledToPendingServiceState == .disabled
                && enabledToPendingAgentIsLoaded
                && FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: enabledToPendingHome).path
                ),
            "test16_loginEnable_loadedAgentEnabledToPendingTransitionKeepsOneProvenMechanism"
        )

        let disappearingExistingAgentHome = root.appendingPathComponent(
            "existing-agent-disappears-during-service-read-home",
            isDirectory: true
        )
        try writeFallbackPlist(
            home: disappearingExistingAgentHome,
            arguments: [installedExecutable]
        )
        var disappearingExistingAgentIsLoaded = true
        var disappearingExistingAgentPrintCalls = 0
        var disappearingExistingAgentBootstrapCalls = 0
        let disappearingExistingAgentController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: disappearingExistingAgentHome,
            launchctl: { arguments in
                switch arguments.first {
                case "print":
                    disappearingExistingAgentPrintCalls += 1
                    if disappearingExistingAgentPrintCalls == 2 {
                        disappearingExistingAgentIsLoaded = false
                        return absentAgentResult()
                    }
                    return disappearingExistingAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                case "bootout":
                    disappearingExistingAgentIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                case "bootstrap":
                    disappearingExistingAgentBootstrapCalls += 1
                    disappearingExistingAgentIsLoaded = true
                    return LoginItemCommandResult(status: 0)
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            disappearingExistingAgentController.enable(),
            .enabled(mechanism: .launchAgent),
            "test16_fixedPoint_existingLaunchAgentDisappearanceReestablishesFallback"
        )
        tests.expect(
            disappearingExistingAgentPrintCalls == 8
                && disappearingExistingAgentBootstrapCalls == 1
                && disappearingExistingAgentIsLoaded
                && FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: disappearingExistingAgentHome).path
                ),
            "test16_fixedPoint_existingLaunchAgentSuccessUsesFreshExactProbe"
        )

        let terminalObservationDisappearanceHome = root.appendingPathComponent(
            "launch-agent-disappears-during-terminal-service-read-home",
            isDirectory: true
        )
        try writeFallbackPlist(
            home: terminalObservationDisappearanceHome,
            arguments: [installedExecutable]
        )
        var terminalObservationAgentIsLoaded = true
        var terminalObservationPrintCalls = 0
        var terminalObservationServiceReads = 0
        let terminalObservationDisappearanceController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: terminalObservationDisappearanceHome,
            launchctl: { arguments in
                guard arguments == ["print", agentTarget] else {
                    return LoginItemCommandResult(
                        status: -1,
                        stderr: "unexpected mutation"
                    )
                }
                terminalObservationPrintCalls += 1
                return terminalObservationAgentIsLoaded
                    ? LoginItemCommandResult(
                        status: 0,
                        stdout: liveServiceOutput(executable: installedExecutable)
                    )
                    : absentAgentResult()
            },
            serviceState: {
                terminalObservationServiceReads += 1
                if terminalObservationServiceReads == 3 {
                    terminalObservationAgentIsLoaded = false
                }
                return .disabled
            },
            registerService: {},
            unregisterService: {}
        )
        let terminalObservationDisappearanceState =
            terminalObservationDisappearanceController.enable()
        tests.expect(
            {
                guard case .failed(let reason) = terminalObservationDisappearanceState else {
                    return false
                }
                return reason.contains("bounded paired LaunchAgent/System Settings observer")
                    && reason.contains("reached disabled")
            }(),
            "test16_terminalObserver_LADisappearanceDuringSMReadCannotReturnEnabled"
        )
        tests.expect(
            terminalObservationPrintCalls == 6
                && terminalObservationServiceReads == 4
                && !terminalObservationAgentIsLoaded,
            "test16_terminalObserver_LADisappearanceRetriesToFreshStableAbsence"
        )

        let pendingDormantHome = root.appendingPathComponent(
            "pending-service-dormant-plist-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: pendingDormantHome, arguments: [installedExecutable])
        var pendingDormantServiceState = LoginItemServiceState.requiresApproval
        var pendingDormantAgentIsLoaded = false
        var pendingDormantEvents: [String] = []
        var pendingDormantRegisterCalls = 0
        var pendingDormantUnregisterCalls = 0
        let pendingDormantController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: pendingDormantHome,
            launchctl: { arguments in
                pendingDormantEvents.append(arguments.joined(separator: " "))
                switch arguments.first {
                case "print":
                    return pendingDormantAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                case "bootstrap":
                    pendingDormantAgentIsLoaded = true
                    return LoginItemCommandResult(status: 0)
                case "bootout":
                    pendingDormantAgentIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { pendingDormantServiceState },
            registerService: { pendingDormantRegisterCalls += 1 },
            unregisterService: {
                pendingDormantEvents.append("unregister-service")
                pendingDormantUnregisterCalls += 1
                pendingDormantServiceState = .disabled
            }
        )
        tests.expectEqual(
            pendingDormantController.enable(),
            .enabled(mechanism: .launchAgent),
            "test16_loginEnable_pendingServiceDormantFallbackReconcilesToLaunchAgent"
        )
        let pendingDormantUnregisterIndex = pendingDormantEvents.firstIndex(
            of: "unregister-service"
        )
        let pendingDormantBootstrapIndex = pendingDormantEvents.firstIndex {
            $0.hasPrefix("bootstrap ")
        }
        tests.expect(
            pendingDormantUnregisterCalls == 1
                && pendingDormantRegisterCalls == 0
                && pendingDormantUnregisterIndex != nil
                && pendingDormantBootstrapIndex != nil
                && pendingDormantUnregisterIndex! < pendingDormantBootstrapIndex!
                && pendingDormantServiceState == .disabled
                && pendingDormantAgentIsLoaded,
            "test16_loginEnable_pendingServiceIsProvenDisabledBeforeDormantFallbackLoads"
        )

        let unregisterFailureHome = root.appendingPathComponent(
            "pending-service-unregister-failure-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: unregisterFailureHome, arguments: [installedExecutable])
        var unregisterFailureLaunchctlCalls: [[String]] = []
        var unregisterFailureCalls = 0
        let unregisterFailureController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: unregisterFailureHome,
            launchctl: { arguments in
                unregisterFailureLaunchctlCalls.append(arguments)
                return arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected mutation")
            },
            serviceState: { .requiresApproval },
            registerService: {},
            unregisterService: {
                unregisterFailureCalls += 1
                throw NSError(
                    domain: "TickerTests.LoginItem",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "injected unregister denial"]
                )
            }
        )
        let unregisterFailureState = unregisterFailureController.enable()
        tests.expect(
            {
                guard case .failed(let reason) = unregisterFailureState else { return false }
                return reason.contains("could not be unregistered")
                    && reason.contains("injected unregister denial")
                    && reason.contains("fallback was removed")
            }(),
            "test16_loginEnable_unregisterFailureIsObservable"
        )
        tests.expect(
            unregisterFailureCalls == 1
                && unregisterFailureLaunchctlCalls.filter { $0.first == "print" }.count == 3
                && unregisterFailureLaunchctlCalls.filter { $0.first == "bootout" }.count == 1
                && !FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: unregisterFailureHome).path
                ),
            "test16_loginEnable_unregisterFailureRemovesDormantFallbackWithoutActivation"
        )

        let postActivationChangeHome = root.appendingPathComponent(
            "post-activation-service-change-home",
            isDirectory: true
        )
        var postActivationAgentIsLoaded = false
        var postActivationServiceProbeCount = 0
        var postActivationLaunchctlCalls: [[String]] = []
        var postActivationRegisterCalls = 0
        let postActivationChangeController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: postActivationChangeHome,
            launchctl: { arguments in
                postActivationLaunchctlCalls.append(arguments)
                switch arguments.first {
                case "print":
                    return postActivationAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                case "bootstrap":
                    postActivationAgentIsLoaded = true
                    return LoginItemCommandResult(status: 0)
                case "bootout":
                    postActivationAgentIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: {
                defer { postActivationServiceProbeCount += 1 }
                return postActivationServiceProbeCount < 2 ? .disabled : .enabled
            },
            registerService: { postActivationRegisterCalls += 1 },
            unregisterService: {}
        )
        tests.expectEqual(
            postActivationChangeController.enable(),
            .enabled(mechanism: .serviceManagement),
            "test16_loginEnable_postActivationEnabledServiceWins"
        )
        tests.expectEqual(
            postActivationChangeController.state(),
            .enabled(mechanism: .serviceManagement),
            "test16_loginEnable_postActivationEnabledServiceHasExactFinalState"
        )
        tests.expect(
            !postActivationAgentIsLoaded
                && postActivationRegisterCalls == 1
                && postActivationLaunchctlCalls.contains { $0.first == "bootstrap" }
                && postActivationLaunchctlCalls.filter { $0.first == "bootout" }.count == 3
                && !FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: postActivationChangeHome).path
                ),
            "test16_loginEnable_postActivationEnabledServiceProvesLaunchAgentAbsence"
        )

        let postActivationPendingHome = root.appendingPathComponent(
            "post-activation-pending-service-home",
            isDirectory: true
        )
        var postActivationPendingAgentIsLoaded = false
        var postActivationPendingServiceState = LoginItemServiceState.disabled
        var postActivationPendingServiceProbeCount = 0
        var postActivationPendingUnregisterCalls = 0
        var postActivationPendingBootstrapCalls = 0
        let postActivationPendingController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: postActivationPendingHome,
            launchctl: { arguments in
                switch arguments.first {
                case "print":
                    return postActivationPendingAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                case "bootout":
                    postActivationPendingAgentIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                case "bootstrap":
                    postActivationPendingBootstrapCalls += 1
                    postActivationPendingAgentIsLoaded = true
                    return LoginItemCommandResult(status: 0)
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: {
                defer { postActivationPendingServiceProbeCount += 1 }
                if postActivationPendingServiceProbeCount == 2 {
                    postActivationPendingServiceState = .requiresApproval
                }
                return postActivationPendingServiceState
            },
            registerService: {},
            unregisterService: {
                postActivationPendingUnregisterCalls += 1
                postActivationPendingServiceState = .disabled
            }
        )
        tests.expectEqual(
            postActivationPendingController.enable(),
            .enabled(mechanism: .launchAgent),
            "test16_fixedPoint_postActivationPendingServiceReconcilesToFallback"
        )
        tests.expect(
            postActivationPendingUnregisterCalls == 1
                && postActivationPendingBootstrapCalls == 2
                && postActivationPendingServiceState == .disabled
                && postActivationPendingAgentIsLoaded
                && FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: postActivationPendingHome).path
                ),
            "test16_fixedPoint_pendingServiceIsDisabledBeforeLaunchAgentRemains"
        )

        let indeterminateProbeHome = root.appendingPathComponent(
            "indeterminate-probe-home",
            isDirectory: true
        )
        var indeterminateProbeCalls: [[String]] = []
        let indeterminateProbeController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: indeterminateProbeHome,
            launchctl: { arguments in
                indeterminateProbeCalls.append(arguments)
                return LoginItemCommandResult(status: 5, stderr: "permission denied")
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let indeterminateState = indeterminateProbeController.state()
        tests.expect(
            {
                guard case .failed(let reason) = indeterminateState else { return false }
                return reason.contains("exact target query failed with exit status 5")
                    && reason.contains("permission denied")
            }(),
            "test16_loginState_positivePermissionErrorIsIndeterminate"
        )
        tests.expect(
            indeterminateProbeCalls
                == [["print", agentTarget], ["print", agentTarget]],
            "test16_loginState_indeterminateProbeDoesNotMutateLoginItems"
        )
        let wrongStatusController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: root.appendingPathComponent("wrong-absence-status-home"),
            launchctl: { _ in
                LoginItemCommandResult(status: 5, stderr: "Could not find service")
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let wrongStatusEnableState = wrongStatusController.enable()
        tests.expect(
            {
                guard case .failed = wrongStatusEnableState else { return false }
                return true
            }(),
            "test16_loginEnable_serviceNotFoundMessageWithWrongStatusIsIndeterminate"
        )

        let indeterminateServiceHome = root.appendingPathComponent(
            "indeterminate-service-home",
            isDirectory: true
        )
        var indeterminateServiceLaunchctlCalls: [[String]] = []
        var indeterminateServiceRegisterWasCalled = false
        var indeterminateServiceUnregisterCalls = 0
        let indeterminateServiceController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: indeterminateServiceHome,
            launchctl: { arguments in
                indeterminateServiceLaunchctlCalls.append(arguments)
                return LoginItemCommandResult(status: 113, stderr: "Could not find service")
            },
            serviceState: { .indeterminate },
            registerService: { indeterminateServiceRegisterWasCalled = true },
            unregisterService: { indeterminateServiceUnregisterCalls += 1 }
        )
        let indeterminateServiceReadState = indeterminateServiceController.state()
        tests.expect(
            {
                guard case .failed(let reason) = indeterminateServiceReadState else { return false }
                return reason.contains("status is indeterminate")
            }(),
            "test16_loginState_indeterminateServiceStatusReturnsFailure"
        )
        let indeterminateServiceEnableState = indeterminateServiceController.enable()
        tests.expect(
            {
                guard case .failed(let reason) = indeterminateServiceEnableState else { return false }
                return reason.contains("is indeterminate")
                    && reason.contains("disabled state was not proven")
            }(),
            "test16_loginEnable_indeterminateServiceStatusReturnsFailure"
        )
        tests.expect(
            !indeterminateServiceRegisterWasCalled
                && indeterminateServiceUnregisterCalls == 1
                && !indeterminateServiceLaunchctlCalls.contains { $0.first == "bootstrap" }
                && indeterminateServiceLaunchctlCalls.filter { $0.first == "bootout" }.count == 1,
            "test16_loginEnable_indeterminateServiceCompensatesWithoutFallbackActivation"
        )

        let postRegistrationIndeterminateHome = root.appendingPathComponent(
            "post-registration-indeterminate-service-home",
            isDirectory: true
        )
        var postRegistrationServiceProbeCount = 0
        var postRegistrationRegisterWasCalled = false
        var postRegistrationLaunchctlCalls: [[String]] = []
        var postRegistrationUnregisterCalls = 0
        let postRegistrationIndeterminateController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: postRegistrationIndeterminateHome,
            launchctl: { arguments in
                postRegistrationLaunchctlCalls.append(arguments)
                return LoginItemCommandResult(status: 113, stderr: "Could not find service")
            },
            serviceState: {
                defer { postRegistrationServiceProbeCount += 1 }
                return postRegistrationServiceProbeCount == 0 ? .disabled : .indeterminate
            },
            registerService: { postRegistrationRegisterWasCalled = true },
            unregisterService: { postRegistrationUnregisterCalls += 1 }
        )
        let postRegistrationIndeterminateState = postRegistrationIndeterminateController.enable()
        tests.expect(
            {
                guard case .failed(let reason) = postRegistrationIndeterminateState else {
                    return false
                }
                return reason.contains("is indeterminate")
                    && reason.contains("disabled state was not proven")
            }(),
            "test16_loginEnable_postRegistrationIndeterminateStatusReturnsFailure"
        )
        tests.expect(
            postRegistrationRegisterWasCalled
                && postRegistrationUnregisterCalls == 1
                && !postRegistrationLaunchctlCalls.contains { $0.first == "bootstrap" }
                && postRegistrationLaunchctlCalls.filter { $0.first == "bootout" }.count == 1,
            "test16_loginEnable_postRegistrationIndeterminateCompensatesWithoutFallbackActivation"
        )

        try assertStalePlistRepair(
            homeName: "old-build-home",
            staleExecutable: "/private/tmp/Ticker-build/Ticker",
            testName: "test16_loginFallback_oldBuildTarget"
        )
        try assertStalePlistRepair(
            homeName: "foreign-executable-home",
            staleExecutable: "/Applications/Foreign.app/Contents/MacOS/Foreign",
            testName: "test16_loginFallback_foreignExecutable"
        )

        let malformedHome = root.appendingPathComponent(
            "malformed-plist-home",
            isDirectory: true
        )
        let malformedPlist = fallbackPlistURL(for: malformedHome)
        try FileManager.default.createDirectory(
            at: malformedPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("<?xml version=\"1.0\"?><plist><dict>".utf8).write(to: malformedPlist)
        var malformedPrintCount = 0
        let malformedController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: malformedHome,
            launchctl: { arguments in
                if arguments.first == "print" {
                    malformedPrintCount += 1
                }
                return LoginItemCommandResult(status: 0)
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let malformedState = malformedController.state()
        tests.expect(
            {
                guard case .failed(let reason) = malformedState else { return false }
                return reason.contains("plist is malformed")
            }(),
            "test16_loginFallback_malformedPlistIsRejected"
        )
        tests.expectEqual(
            malformedPrintCount,
            2,
            "test16_loginFallback_malformedPlistStillProbesExactTarget"
        )

        let symlinkHome = root.appendingPathComponent(
            "symlink-plist-home",
            isDirectory: true
        )
        let symlinkPlist = fallbackPlistURL(for: symlinkHome)
        let symlinkTarget = root.appendingPathComponent("valid-fallback-target.plist")
        try writeFallbackPlist(home: root, arguments: [installedExecutable])
        try FileManager.default.moveItem(
            at: fallbackPlistURL(for: root),
            to: symlinkTarget
        )
        try FileManager.default.createDirectory(
            at: symlinkPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkPlist,
            withDestinationURL: symlinkTarget
        )
        var symlinkPrintCount = 0
        let symlinkController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: symlinkHome,
            launchctl: { arguments in
                if arguments.first == "print" {
                    symlinkPrintCount += 1
                }
                return LoginItemCommandResult(status: 0)
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let symlinkState = symlinkController.state()
        tests.expect(
            {
                guard case .failed(let reason) = symlinkState else { return false }
                return reason.contains("must not be a symbolic link")
            }(),
            "test16_loginFallback_symlinkPlistIsRejected"
        )
        tests.expectEqual(
            symlinkPrintCount,
            2,
            "test16_loginFallback_symlinkPlistStillProbesExactTarget"
        )

        let nonregularHome = root.appendingPathComponent(
            "nonregular-plist-home",
            isDirectory: true
        )
        let nonregularPlist = fallbackPlistURL(for: nonregularHome)
        try FileManager.default.createDirectory(
            at: nonregularPlist,
            withIntermediateDirectories: true
        )
        var nonregularPrintCount = 0
        let nonregularController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: nonregularHome,
            launchctl: { arguments in
                if arguments.first == "print" {
                    nonregularPrintCount += 1
                }
                return LoginItemCommandResult(status: 0)
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let nonregularState = nonregularController.state()
        tests.expect(
            {
                guard case .failed(let reason) = nonregularState else { return false }
                return reason.contains("must be a regular file")
            }(),
            "test16_loginFallback_nonregularPlistIsRejected"
        )
        tests.expectEqual(
            nonregularPrintCount,
            2,
            "test16_loginFallback_nonregularPlistStillProbesExactTarget"
        )
        let nonregularSentinel = nonregularPlist.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: nonregularSentinel)
        let nonregularEnableState = nonregularController.enable()
        tests.expect(
            {
                guard case .failed(let reason) = nonregularEnableState else { return false }
                return reason.contains("refusing nonrecursive removal")
            }(),
            "test16_loginInstall_directoryFallbackIsRejectedWithoutRecursiveDeletion"
        )
        tests.expect(
            FileManager.default.fileExists(atPath: nonregularSentinel.path),
            "test16_loginInstall_directoryFallbackContentsArePreserved"
        )

        let extraArgumentsHome = root.appendingPathComponent(
            "extra-arguments-home",
            isDirectory: true
        )
        try writeFallbackPlist(
            home: extraArgumentsHome,
            arguments: [installedExecutable, "--unexpected"]
        )
        var extraArgumentsPrintCount = 0
        let extraArgumentsController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: extraArgumentsHome,
            launchctl: { arguments in
                if arguments.first == "print" {
                    extraArgumentsPrintCount += 1
                }
                return LoginItemCommandResult(status: 0)
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let extraArgumentsState = extraArgumentsController.state()
        tests.expect(
            {
                guard case .failed(let reason) = extraArgumentsState else { return false }
                return reason.contains("only exact executable")
            }(),
            "test16_loginFallback_extraProgramArgumentsAreRejected"
        )
        tests.expectEqual(
            extraArgumentsPrintCount,
            2,
            "test16_loginFallback_extraArgumentsStillProbeExactTarget"
        )

        let extraProgramHome = root.appendingPathComponent(
            "extra-program-home",
            isDirectory: true
        )
        try writeFallbackPlist(
            home: extraProgramHome,
            arguments: [installedExecutable],
            program: "/usr/local/bin/not-ticker"
        )
        var extraProgramPrintCount = 0
        let extraProgramController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: extraProgramHome,
            launchctl: { arguments in
                if arguments.first == "print" {
                    extraProgramPrintCount += 1
                }
                return LoginItemCommandResult(status: 0)
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let extraProgramState = extraProgramController.state()
        tests.expect(
            {
                guard case .failed(let reason) = extraProgramState else { return false }
                return reason.contains("unsupported Program value")
            }(),
            "test16_loginFallback_extraProgramIsRejected"
        )
        tests.expectEqual(
            extraProgramPrintCount,
            2,
            "test16_loginFallback_extraProgramStillProbesExactTarget"
        )

        let loadedMismatchHome = root.appendingPathComponent(
            "loaded-mismatch-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: loadedMismatchHome, arguments: [installedExecutable])
        let foreignLoadedExecutable = "/usr/local/bin/not-ticker"
        var loadedExecutable: String? = foreignLoadedExecutable
        var loadedMismatchCalls: [[String]] = []
        let loadedMismatchController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: loadedMismatchHome,
            launchctl: { arguments in
                loadedMismatchCalls.append(arguments)
                switch arguments.first {
                case "bootstrap":
                    loadedExecutable = installedExecutable
                    return LoginItemCommandResult(status: 0)
                case "bootout":
                    loadedExecutable = nil
                    return LoginItemCommandResult(status: 0)
                case "print":
                    guard let loadedExecutable else {
                        return absentAgentResult()
                    }
                    return LoginItemCommandResult(
                        status: 0,
                        stdout: liveServiceOutput(executable: loadedExecutable)
                    )
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let loadedMismatchState = loadedMismatchController.state()
        tests.expect(
            {
                guard case .failed(let reason) = loadedMismatchState else { return false }
                return reason.contains("did not report exact executable")
            }(),
            "test16_loginFallback_matchingLabelWithDifferentLoadedProgramIsRejected"
        )
        tests.expectEqual(
            loadedMismatchController.enable(),
            .enabled(mechanism: .launchAgent),
            "test16_loginFallback_loadedProgramMismatchIsReplaced"
        )
        tests.expect(
            loadedMismatchCalls.contains(["bootout", agentTarget])
                && loadedMismatchCalls.contains([
                    "bootstrap",
                    "gui/\(getuid())",
                    fallbackPlistURL(for: loadedMismatchHome).path,
                ]),
            "test16_loginFallback_loadedProgramMismatchUsesBootoutAndBootstrap"
        )

        let headerOnlyHome = root.appendingPathComponent(
            "header-only-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: headerOnlyHome, arguments: [installedExecutable])
        let headerOnlyController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: headerOnlyHome,
            launchctl: { arguments in
                guard arguments.first == "print" else {
                    return LoginItemCommandResult(status: 0)
                }
                return LoginItemCommandResult(
                    status: 0,
                    stdout: "\(agentTarget) = {\n}\n"
                )
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let headerOnlyState = headerOnlyController.state()
        tests.expect(
            {
                guard case .failed(let reason) = headerOnlyState else { return false }
                return reason.contains("did not report exact live state")
            }(),
            "test16_loginFallback_headerOnlyLaunchctlOutputIsRejected"
        )

        let nestedProgramHome = root.appendingPathComponent(
            "nested-program-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: nestedProgramHome, arguments: [installedExecutable])
        let nestedProgramController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: nestedProgramHome,
            launchctl: { arguments in
                guard arguments.first == "print" else {
                    return LoginItemCommandResult(status: 0)
                }
                return LoginItemCommandResult(
                    status: 0,
                    stdout: """
                    \(agentTarget) = {
                        state = running
                        metadata = {
                            program = \(installedExecutable)
                        }
                    }
                    """
                )
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let nestedProgramState = nestedProgramController.state()
        tests.expect(
            {
                guard case .failed(let reason) = nestedProgramState else { return false }
                return reason.contains("did not report exact executable")
            }(),
            "test16_loginFallback_nestedProgramCannotSpoofLoadedTarget"
        )

        let incompletePrintHome = root.appendingPathComponent(
            "incomplete-print-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: incompletePrintHome, arguments: [installedExecutable])
        let incompletePrintController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: incompletePrintHome,
            launchctl: { arguments in
                guard arguments.first == "print" else {
                    return LoginItemCommandResult(status: 0)
                }
                return LoginItemCommandResult(
                    status: 0,
                    stdout: """
                    \(agentTarget) = {
                        state = running
                        program = \(installedExecutable)
                    """
                )
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let incompletePrintState = incompletePrintController.state()
        tests.expect(
            {
                guard case .failed(let reason) = incompletePrintState else { return false }
                return reason.contains("complete exact service block")
            }(),
            "test16_loginFallback_incompleteLaunchctlOutputIsRejected"
        )

        let wrongServiceHome = root.appendingPathComponent(
            "wrong-service-home",
            isDirectory: true
        )
        var wrongServiceIsLoaded = true
        let wrongServiceController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: wrongServiceHome,
            launchctl: { arguments in
                switch arguments.first {
                case "bootstrap":
                    wrongServiceIsLoaded = true
                    return LoginItemCommandResult(status: 0)
                case "bootout":
                    wrongServiceIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                case "print":
                    return wrongServiceIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: "gui/\(getuid())/com.example.other = {\n}\n"
                        )
                        : absentAgentResult()
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let wrongServiceState = wrongServiceController.enable()
        tests.expect(
            {
                guard case .failed(let reason) = wrongServiceState else { return false }
                return reason.contains("did not identify exact service")
            }(),
            "test16_loginFallback_rejectsWrongPrintedService"
        )
        let wrongServicePlist = wrongServiceHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.suchintan.ticker.login.plist")
        tests.expect(
            !FileManager.default.fileExists(atPath: wrongServicePlist.path),
            "test16_loginFallback_wrongPrintedServiceRemovesPlist"
        )

        func absentAgentResult() -> LoginItemCommandResult {
            LoginItemCommandResult(status: 113, stderr: "Could not find service")
        }

        let missingPlistHome = root.appendingPathComponent(
            "disable-loaded-missing-plist-home",
            isDirectory: true
        )
        var missingPlistAgentIsLoaded = true
        var missingPlistDisableCalls: [[String]] = []
        let missingPlistController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: missingPlistHome,
            launchctl: { arguments in
                missingPlistDisableCalls.append(arguments)
                switch arguments.first {
                case "print":
                    return missingPlistAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                case "bootout":
                    missingPlistAgentIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            missingPlistController.state(),
            .enabled(mechanism: .launchAgent),
            "test16_loginState_liveExactAgentWithMissingPlistIsEnabled"
        )
        tests.expectEqual(
            missingPlistController.disable(),
            .disabled,
            "test16_loginDisable_loadedExactAgentWithMissingPlist_isDisabled"
        )
        tests.expect(
            missingPlistDisableCalls.contains(["bootout", agentTarget])
                && missingPlistDisableCalls.filter { $0 == ["print", agentTarget] }.count == 6,
            "test16_loginDisable_loadedExactAgentWithMissingPlist_isBootedOutAndVerified"
        )

        let lateLoadHome = root.appendingPathComponent(
            "disable-absent-to-present-late-load-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: lateLoadHome, arguments: [installedExecutable])
        var lateLoadAgentIsLoaded = false
        var lateLoadPrintCalls = 0
        var lateLoadBootoutCalls = 0
        let lateLoadController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: lateLoadHome,
            launchctl: { arguments in
                switch arguments.first {
                case "bootout":
                    lateLoadBootoutCalls += 1
                    lateLoadAgentIsLoaded = false
                    return LoginItemCommandResult(status: 0)
                case "print":
                    lateLoadPrintCalls += 1
                    if lateLoadPrintCalls == 1 {
                        lateLoadAgentIsLoaded = true
                        return absentAgentResult()
                    }
                    return lateLoadAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            lateLoadController.disable(),
            .disabled,
            "test16_loginDisable_absentToPresentLateLoadIsDisabled"
        )
        tests.expect(
            lateLoadPrintCalls == 4
                && lateLoadBootoutCalls == 2
                && !lateLoadAgentIsLoaded
                && !FileManager.default.fileExists(atPath: fallbackPlistURL(for: lateLoadHome).path),
            "test16_loginDisable_lateLoadUsesSecondBootoutAndFinalAbsenceProof"
        )

        let orderingBarrierHome = root.appendingPathComponent(
            "disable-post-unlink-ordering-barrier-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: orderingBarrierHome, arguments: [installedExecutable])
        var orderingBarrierAgentIsLoaded = false
        var orderingBarrierLoadIsQueued = false
        var orderingBarrierPrintCalls = 0
        var orderingBarrierBootoutCalls = 0
        var orderingBarrierSawUnlinkedSource = false
        let orderingBarrierController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: orderingBarrierHome,
            launchctl: { arguments in
                switch arguments.first {
                case "print":
                    orderingBarrierPrintCalls += 1
                    if orderingBarrierPrintCalls == 1 {
                        orderingBarrierLoadIsQueued = true
                        return absentAgentResult()
                    }
                    return orderingBarrierAgentIsLoaded
                        ? LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                        : absentAgentResult()
                case "bootout":
                    orderingBarrierBootoutCalls += 1
                    if orderingBarrierLoadIsQueued {
                        orderingBarrierAgentIsLoaded = true
                        orderingBarrierLoadIsQueued = false
                    }
                    orderingBarrierSawUnlinkedSource =
                        orderingBarrierSawUnlinkedSource
                        || !FileManager.default.fileExists(
                            atPath: fallbackPlistURL(for: orderingBarrierHome).path
                        )
                    if orderingBarrierAgentIsLoaded {
                        orderingBarrierAgentIsLoaded = false
                        return LoginItemCommandResult(status: 0)
                    }
                    return LoginItemCommandResult(
                        status: 3,
                        stderr: "Boot-out failed: 3: No such process"
                    )
                default:
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            orderingBarrierController.disable(),
            .disabled,
            "test16_fixedPoint_postUnlinkBootoutClosesQueuedLoadRace"
        )
        tests.expect(
            orderingBarrierBootoutCalls == 2
                && orderingBarrierSawUnlinkedSource
                && !orderingBarrierAgentIsLoaded
                && !FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: orderingBarrierHome).path
                ),
            "test16_fixedPoint_bootoutNotFoundStillEndsInExactAbsence"
        )

        let liveAfterBootoutFailureHome = root.appendingPathComponent(
            "disable-bootout-failure-live-home",
            isDirectory: true
        )
        let liveAfterBootoutFailureController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: liveAfterBootoutFailureHome,
            launchctl: { arguments in
                if arguments.first == "bootout" {
                    return LoginItemCommandResult(status: 5, stderr: "permission denied")
                }
                return LoginItemCommandResult(
                    status: 0,
                    stdout: liveServiceOutput(executable: installedExecutable)
                )
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let liveAfterBootoutFailureState = liveAfterBootoutFailureController.disable()
        tests.expect(
            {
                guard case .failed(let reason) = liveAfterBootoutFailureState else { return false }
                return reason.contains("bootout failed with exit status 5")
                    && reason.contains("remains loaded")
            }(),
            "test16_loginDisable_bootoutFailureWithLiveService_returnsFailure"
        )

        let absentAfterBootoutFailureHome = root.appendingPathComponent(
            "disable-bootout-failure-absent-home",
            isDirectory: true
        )
        var absentAfterBootoutFailurePrintCount = 0
        let absentAfterBootoutFailureController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: absentAfterBootoutFailureHome,
            launchctl: { arguments in
                if arguments.first == "print" {
                    absentAfterBootoutFailurePrintCount += 1
                    if absentAfterBootoutFailurePrintCount == 1 {
                        return LoginItemCommandResult(
                            status: 0,
                            stdout: liveServiceOutput(executable: installedExecutable)
                        )
                    }
                    return absentAgentResult()
                }
                if arguments.first == "bootout" {
                    return LoginItemCommandResult(status: 5, stderr: "service exited concurrently")
                }
                return LoginItemCommandResult(status: -1, stderr: "unexpected command")
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            absentAfterBootoutFailureController.disable(),
            .disabled,
            "test16_loginDisable_nonzeroBootoutWithSubsequentExactAbsence_isDisabled"
        )

        let finalIPCFailureHome = root.appendingPathComponent(
            "disable-final-ipc-failure-home",
            isDirectory: true
        )
        var finalIPCFailurePrintCount = 0
        let finalIPCFailureController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: finalIPCFailureHome,
            launchctl: { arguments in
                guard arguments.first == "print" else {
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
                finalIPCFailurePrintCount += 1
                return finalIPCFailurePrintCount == 1
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: 113, stderr: "IPC unavailable")
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let finalIPCFailureState = finalIPCFailureController.disable()
        tests.expect(
            {
                guard case .failed(let reason) = finalIPCFailureState else { return false }
                return reason.contains("absence could not be verified with exit status 113")
                    && reason.contains("IPC unavailable")
            }(),
            "test16_loginDisable_positiveFinalIPCErrorIsIndeterminate"
        )

        let directoryFallbackHome = root.appendingPathComponent(
            "disable-directory-fallback-home",
            isDirectory: true
        )
        let directoryFallback = fallbackPlistURL(for: directoryFallbackHome)
        try FileManager.default.createDirectory(
            at: directoryFallback,
            withIntermediateDirectories: true
        )
        let directorySentinel = directoryFallback.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: directorySentinel)
        let directoryFallbackController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: directoryFallbackHome,
            launchctl: { arguments in
                arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected command")
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let directoryFallbackState = directoryFallbackController.disable()
        tests.expect(
            {
                guard case .failed(let reason) = directoryFallbackState else { return false }
                return reason.contains("directory")
                    && reason.contains("refusing nonrecursive removal")
            }(),
            "test16_loginDisable_directoryFallbackIsRejected"
        )
        tests.expect(
            FileManager.default.fileExists(atPath: directorySentinel.path),
            "test16_loginDisable_directoryFallbackIsNotRecursivelyDeleted"
        )

        let fifoFallbackHome = root.appendingPathComponent(
            "disable-fifo-fallback-home",
            isDirectory: true
        )
        let fifoFallback = fallbackPlistURL(for: fifoFallbackHome)
        try FileManager.default.createDirectory(
            at: fifoFallback.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard Darwin.mkfifo(fifoFallback.path, 0o600) == 0 else {
            throw FixtureError.missing("test16 FIFO fallback fixture")
        }
        let fifoFallbackController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: fifoFallbackHome,
            launchctl: { arguments in
                arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected command")
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let fifoFallbackState = fifoFallbackController.disable()
        tests.expect(
            {
                guard case .failed(let reason) = fifoFallbackState else { return false }
                return reason.contains("FIFO")
                    && reason.contains("refusing nonrecursive removal")
            }(),
            "test16_loginDisable_nonregularFallbackIsRejected"
        )
        var fifoInformation = stat()
        tests.expect(
            Darwin.lstat(fifoFallback.path, &fifoInformation) == 0,
            "test16_loginDisable_nonregularFallbackIsPreserved"
        )

        let symlinkRemovalHome = root.appendingPathComponent(
            "disable-symlink-removal-home",
            isDirectory: true
        )
        let symlinkRemovalPath = fallbackPlistURL(for: symlinkRemovalHome)
        let symlinkRemovalTarget = root.appendingPathComponent("symlink-removal-target")
        try Data("target remains".utf8).write(to: symlinkRemovalTarget)
        try FileManager.default.createDirectory(
            at: symlinkRemovalPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkRemovalPath,
            withDestinationURL: symlinkRemovalTarget
        )
        let symlinkRemovalController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: symlinkRemovalHome,
            launchctl: { arguments in
                arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected command")
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        tests.expectEqual(
            symlinkRemovalController.disable(),
            .disabled,
            "test16_loginDisable_symlinkFallbackUnlinksOnlySymlink"
        )
        tests.expect(
            !FileManager.default.fileExists(atPath: symlinkRemovalPath.path)
                && FileManager.default.fileExists(atPath: symlinkRemovalTarget.path),
            "test16_loginDisable_symlinkTargetIsPreserved"
        )

        let recreatedFallbackHome = root.appendingPathComponent(
            "disable-recreated-fallback-home",
            isDirectory: true
        )
        try writeFallbackPlist(home: recreatedFallbackHome, arguments: [installedExecutable])
        var recreatedFallbackPrintCount = 0
        var recreatedFallbackError: Error?
        let recreatedFallbackController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: recreatedFallbackHome,
            launchctl: { arguments in
                guard arguments.first == "print" else {
                    return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                }
                recreatedFallbackPrintCount += 1
                if recreatedFallbackPrintCount == 2 {
                    do {
                        try writeFallbackPlist(
                            home: recreatedFallbackHome,
                            arguments: [installedExecutable]
                        )
                    } catch {
                        recreatedFallbackError = error
                    }
                }
                return absentAgentResult()
            },
            serviceState: { .disabled },
            registerService: {},
            unregisterService: {}
        )
        let recreatedFallbackState = recreatedFallbackController.disable()
        tests.expect(
            {
                guard case .failed(let reason) = recreatedFallbackState else { return false }
                return reason.contains("may have been recreated")
            }(),
            "test16_loginDisable_postRemovalRecreationReturnsFailure"
        )
        tests.expect(
            recreatedFallbackError == nil
                && !FileManager.default.fileExists(
                    atPath: fallbackPlistURL(for: recreatedFallbackHome).path
                ),
            "test16_loginDisable_postRemovalRecreationIsRemovedByFinalAbsenceCheck"
        )

        func assertLateDisableServiceTransition(
            _ transitionState: LoginItemServiceState,
            homeName: String,
            testName: String
        ) {
            let home = root.appendingPathComponent(homeName, isDirectory: true)
            var lateServiceState = LoginItemServiceState.disabled
            var lateServiceReadCount = 0
            var unregisterCalls = 0
            let controller = LoginItemController(
                bundlePath: LoginItemController.installedBundlePath,
                homeDirectory: home,
                launchctl: { arguments in
                    switch arguments.first {
                    case "print", "bootout":
                        return absentAgentResult()
                    default:
                        return LoginItemCommandResult(status: -1, stderr: "unexpected command")
                    }
                },
                serviceState: {
                    lateServiceReadCount += 1
                    if lateServiceReadCount == 2 {
                        lateServiceState = transitionState
                    }
                    return lateServiceState
                },
                registerService: {},
                unregisterService: {
                    unregisterCalls += 1
                    lateServiceState = .disabled
                }
            )

            tests.expectEqual(
                controller.disable(),
                .disabled,
                "\(testName)_returnsDisabled"
            )
            tests.expectEqual(
                controller.state(),
                .disabled,
                "\(testName)_hasExactFinalState"
            )
            tests.expect(
                unregisterCalls == 1 && lateServiceState == .disabled,
                "\(testName)_compensatesFinalObservedServiceTransition"
            )
        }

        assertLateDisableServiceTransition(
            .enabled,
            homeName: "disable-late-enabled-service-home",
            testName: "test16_fixedPoint_disableLateEnabledService"
        )
        assertLateDisableServiceTransition(
            .requiresApproval,
            homeName: "disable-late-pending-service-home",
            testName: "test16_fixedPoint_disableLatePendingService"
        )

        let enabledServiceHome = root.appendingPathComponent(
            "disable-service-still-enabled-home",
            isDirectory: true
        )
        var enabledServiceUnregisterWasCalled = false
        let enabledServiceController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: enabledServiceHome,
            launchctl: { arguments in
                arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected command")
            },
            serviceState: { .enabled },
            registerService: {},
            unregisterService: { enabledServiceUnregisterWasCalled = true }
        )
        let enabledServiceState = enabledServiceController.disable()
        tests.expect(
            {
                guard case .failed(let reason) = enabledServiceState else { return false }
                return reason.contains("login item remains enabled")
            }(),
            "test16_loginDisable_serviceStillEnabled_returnsFailure"
        )
        tests.expect(
            enabledServiceUnregisterWasCalled,
            "test16_loginDisable_serviceStillEnabled_attemptsUnregister"
        )

        let initiallyIndeterminateServiceHome = root.appendingPathComponent(
            "disable-initially-indeterminate-service-home",
            isDirectory: true
        )
        var initiallyIndeterminateServiceUnregisterWasCalled = false
        let initiallyIndeterminateServiceController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: initiallyIndeterminateServiceHome,
            launchctl: { arguments in
                arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected command")
            },
            serviceState: { .indeterminate },
            registerService: {},
            unregisterService: {
                initiallyIndeterminateServiceUnregisterWasCalled = true
            }
        )
        let initiallyIndeterminateServiceState = initiallyIndeterminateServiceController.disable()
        tests.expect(
            {
                guard case .failed(let reason) = initiallyIndeterminateServiceState else {
                    return false
                }
                return reason.contains("did not converge after 3 reconciliation attempts")
                    && reason.contains("remains indeterminate")
            }(),
            "test16_loginDisable_initialIndeterminateServiceReturnsBoundedFailure"
        )
        tests.expect(
            initiallyIndeterminateServiceUnregisterWasCalled,
            "test16_loginDisable_initialIndeterminateServiceAttemptsUnregister"
        )

        let finallyIndeterminateServiceHome = root.appendingPathComponent(
            "disable-finally-indeterminate-service-home",
            isDirectory: true
        )
        var finallyIndeterminateServiceProbeCount = 0
        var finallyIndeterminateServiceUnregisterWasCalled = false
        let finallyIndeterminateServiceController = LoginItemController(
            bundlePath: LoginItemController.installedBundlePath,
            homeDirectory: finallyIndeterminateServiceHome,
            launchctl: { arguments in
                arguments.first == "print"
                    ? absentAgentResult()
                    : LoginItemCommandResult(status: -1, stderr: "unexpected command")
            },
            serviceState: {
                defer { finallyIndeterminateServiceProbeCount += 1 }
                return finallyIndeterminateServiceProbeCount == 0 ? .enabled : .indeterminate
            },
            registerService: {},
            unregisterService: { finallyIndeterminateServiceUnregisterWasCalled = true }
        )
        let finallyIndeterminateServiceState = finallyIndeterminateServiceController.disable()
        tests.expect(
            {
                guard case .failed(let reason) = finallyIndeterminateServiceState else { return false }
                return reason.contains("did not converge after 3 reconciliation attempts")
                    && reason.contains("remains indeterminate")
            }(),
            "test16_loginDisable_finalIndeterminateServiceReturnsBoundedFailure"
        )
        tests.expect(
            finallyIndeterminateServiceUnregisterWasCalled,
            "test16_loginDisable_finalIndeterminateServiceAttemptsUnregister"
        )

        tests.expect(
            !FileManager.default.fileExists(atPath: agentPlist.path),
            "test16_loginFallback_doesNotWriteOutsideInjectedHome"
        )
    }

    try withTemporaryDirectory("round16-installer-transaction") { root in
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let requiresApprovalLoginState =
            "requires approval — approve Ticker in System Settings › General › Login Items"

        func writeExecutable(_ contents: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }

        func writeBundle(_ bundle: URL, version: String) throws {
            if FileManager.default.fileExists(atPath: bundle.path) {
                try FileManager.default.removeItem(at: bundle)
            }
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: contents,
                withIntermediateDirectories: true
            )
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleExecutable</key>
                <string>Ticker</string>
                <key>CFBundleIdentifier</key>
                <string>com.suchintan.ticker</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>CFBundleVersion</key>
                <string>1</string>
            </dict>
            </plist>
            """.write(
                to: contents.appendingPathComponent("Info.plist"),
                atomically: true,
                encoding: .utf8
            )
            try writeExecutable(
                "#!/bin/sh\nexit 0\n",
                to: contents.appendingPathComponent("MacOS/Ticker")
            )
            try writeExecutable(
                """
                #!/bin/sh
                set -eu
                action="${2:-${1:-}}"
                if [ "\(version)" = "legacy" ] && [ "${1:-}" = "login-item" ]; then
                  printf '%s\n' "$action" >> "${TICKER_TEST_LOGIN_CALLS}"
                  printf 'login %s\n' "$action" >> "${TICKER_TEST_PROCESS_CALLS}"
                  printf '%s\n' "ticker: Unknown command 'login-item'. Run 'ticker --help' for usage." >&2
                  exit 2
                fi
                case "$action" in
                  enable)
                    printf '%s\n' "$action" >> "${TICKER_TEST_LOGIN_CALLS}"
                    printf 'login %s\n' "$action" >> "${TICKER_TEST_PROCESS_CALLS}"
                    if [ "${TICKER_TEST_LOGIN_ENABLE_FAIL:-0}" = "1" ]; then
                      printf '%s\n' 'injected enable failure' >&2
                      exit 70
                    fi
                    if [ ! -s "${TICKER_TEST_LOGIN_STATE}" ]; then
                      printf '%s\n' 'enabled via LaunchAgent' > "${TICKER_TEST_LOGIN_STATE}"
                    fi
                    if [ "$(cat "${TICKER_TEST_LOGIN_STATE}")" = "enabled via LaunchAgent" ]; then
                      printf 'running\n' > "${TICKER_TEST_PROCESS_STATE}"
                    fi
                    signal="${TICKER_TEST_LOGIN_SIGNAL_AFTER_ENABLE:-0}"
                    case "$signal" in
                      0|'') ;;
                      1) kill -TERM "${TICKER_INSTALL_TRANSACTION_PID}" ;;
                      HUP|INT|QUIT|TERM) kill "-$signal" "${TICKER_INSTALL_TRANSACTION_PID}" ;;
                      *) exit 64 ;;
                    esac
                    cat "${TICKER_TEST_LOGIN_STATE}"
                    ;;
                  disable)
                    printf '%s\n' "$action" >> "${TICKER_TEST_LOGIN_CALLS}"
                    printf 'login %s\n' "$action" >> "${TICKER_TEST_PROCESS_CALLS}"
                    rm -f "${TICKER_TEST_LOGIN_STATE}"
                    signal="${TICKER_TEST_LOGIN_SIGNAL_DURING_DISABLE:-0}"
                    case "$signal" in
                      0|'') ;;
                      1) kill -TERM "${TICKER_INSTALL_TRANSACTION_PID}" ;;
                      HUP|INT|QUIT|TERM) kill "-$signal" "${TICKER_INSTALL_TRANSACTION_PID}" ;;
                      *) exit 64 ;;
                    esac
                    printf '%s\n' 'disabled'
                    ;;
                  status)
                    printf '%s\n' "$action" >> "${TICKER_TEST_LOGIN_CALLS}"
                    printf 'login %s\n' "$action" >> "${TICKER_TEST_PROCESS_CALLS}"
                    status_count=0
                    if [ -f "${TICKER_TEST_LOGIN_STATUS_CALLS}" ]; then
                      status_count="$(cat "${TICKER_TEST_LOGIN_STATUS_CALLS}")"
                    fi
                    status_count=$((status_count + 1))
                    printf '%s\n' "$status_count" > "${TICKER_TEST_LOGIN_STATUS_CALLS}"
                    if [ "${TICKER_TEST_START_PROCESS_ON_LOGIN_STATUS_AT:-0}" = "$status_count" ]; then
                      printf 'running\n' > "${TICKER_TEST_PROCESS_STATE}"
                    fi
                    if [ "${TICKER_TEST_LOGIN_STATUS_FAIL_AT:-0}" = "$status_count" ]; then
                      printf '%s\n' "${TICKER_TEST_LOGIN_STATUS_FAILURE_MESSAGE:-injected status failure}" >&2
                      exit "${TICKER_TEST_LOGIN_STATUS_FAILURE_CODE:-75}"
                    fi
                    if [ -s "${TICKER_TEST_LOGIN_STATE}" ]; then
                      state="$(cat "${TICKER_TEST_LOGIN_STATE}")"
                    else
                      state="disabled"
                    fi
                    if [ "$state" = "enabled via LaunchAgent" ] \
                        && [ ! -f "${TICKER_TEST_PROCESS_STATE}" ]; then
                      printf '%s\n' 'failed: exact LaunchAgent target is loaded but not running' >&2
                      exit 1
                    fi
                    printf '%s\n' "$state"
                    ;;
                  probe)
                    printf '%s\n' '\(version)'
                    ;;
                  *)
                    exit 64
                    ;;
                esac
                """,
                to: contents.appendingPathComponent("Helpers/ticker")
            )
            try version.write(
                to: bundle.appendingPathComponent("version.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        func writeCommand(_ contents: String, named name: String, in directory: URL) throws -> URL {
            let command = directory.appendingPathComponent(name)
            try writeExecutable(contents, to: command)
            return command
        }

        func makeFixture(
            _ name: String,
            priorVersion: String? = "old"
        ) throws -> (
            directory: URL,
            sourceBundle: URL,
            installedBundle: URL,
            cliLink: URL,
            loginState: URL,
            loginCalls: URL,
            processState: URL,
            processCalls: URL,
            environment: [String: String]
        ) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let sourceBundle = directory.appendingPathComponent(
                "source/Ticker.app",
                isDirectory: true
            )
            let installedBundle = directory.appendingPathComponent(
                "installed/Ticker.app",
                isDirectory: true
            )
            let cliLink = directory.appendingPathComponent("bin/ticker")
            let loginState = directory.appendingPathComponent("login-state.txt")
            let loginCalls = directory.appendingPathComponent("login-calls.txt")
            let loginStatusCalls = directory.appendingPathComponent("login-status-calls.txt")
            let pgrepCalls = directory.appendingPathComponent("pgrep-calls.txt")
            let processState = directory.appendingPathComponent("process-state.txt")
            let processCalls = directory.appendingPathComponent("process-calls.txt")

            try writeBundle(sourceBundle, version: "new")
            if let priorVersion {
                try writeBundle(installedBundle, version: priorVersion)
            }
            try FileManager.default.createDirectory(
                at: cliLink.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let pgrepCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                version="missing"
                if [ -f "${TICKER_INSTALL_BUNDLE}/version.txt" ]; then
                  version="$(cat "${TICKER_INSTALL_BUNDLE}/version.txt")"
                fi
                call_count=0
                if [ -f "${TICKER_TEST_PGREP_CALLS}" ]; then
                  call_count="$(cat "${TICKER_TEST_PGREP_CALLS}")"
                fi
                call_count=$((call_count + 1))
                printf '%s\n' "$call_count" > "${TICKER_TEST_PGREP_CALLS}"
                printf 'pgrep %s %s\n' "$version" "$*" >> "${TICKER_TEST_PROCESS_CALLS}"
                if [ "${TICKER_TEST_PGREP_ERROR:-0}" = "1" ]; then
                  exit 70
                fi
                process_was_running=0
                if [ -f "${TICKER_TEST_PROCESS_STATE}" ]; then
                  process_was_running=1
                fi
                if [ "${TICKER_TEST_START_PROCESS_AFTER_PGREP_AT:-0}" = "$call_count" ]; then
                  printf 'process-start %s\n' "$version" >> "${TICKER_TEST_PROCESS_CALLS}"
                  printf 'running\n' > "${TICKER_TEST_PROCESS_STATE}"
                fi
                [ "$process_was_running" = "1" ]
                """,
                named: "fake-pgrep.sh",
                in: directory
            )
            let pkillCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                version="missing"
                if [ -f "${TICKER_INSTALL_BUNDLE}/version.txt" ]; then
                  version="$(cat "${TICKER_INSTALL_BUNDLE}/version.txt")"
                fi
                printf 'pkill %s %s\n' "$version" "$*" >> "${TICKER_TEST_PROCESS_CALLS}"
                if [ "${TICKER_TEST_PKILL_FAIL:-0}" = "1" ]; then
                  exit 71
                fi
                if [ "${TICKER_TEST_STUBBORN_PROCESS:-0}" != "1" ]; then
                  rm -f "${TICKER_TEST_PROCESS_STATE}"
                fi
                """,
                named: "fake-pkill.sh",
                in: directory
            )
            let openCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                version="$(cat "$1/version.txt")"
                printf 'open %s\n' "$version" >> "${TICKER_TEST_PROCESS_CALLS}"
                if [ "${TICKER_TEST_OPEN_FAIL_VERSION:-}" = "$version" ]; then
                  exit 72
                fi
                if [ "${TICKER_TEST_OPEN_NO_START_VERSION:-}" != "$version" ]; then
                  printf 'running\n' > "${TICKER_TEST_PROCESS_STATE}"
                fi
                if [ "${TICKER_TEST_LOGIN_TRANSITION_AFTER_OPEN_VERSION:-}" = "$version" ]; then
                  printf '%s\n' "${TICKER_TEST_LOGIN_STATE_AFTER_OPEN}" > "${TICKER_TEST_LOGIN_STATE}"
                fi
                """,
                named: "fake-open.sh",
                in: directory
            )
            let launchctlCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                printf 'launchctl %s\n' "$*" >> "${TICKER_TEST_PROCESS_CALLS}"
                case "${1:-}" in
                  kickstart)
                    if [ "$#" -ne 3 ] || [ "${2:-}" != "-k" ] \
                        || [ "${3:-}" != "${TICKER_TEST_AGENT_TARGET}" ]; then
                      printf 'unexpected kickstart target\n' >&2
                      exit 64
                    fi
                    if [ ! -s "${TICKER_TEST_LOGIN_STATE}" ] \
                        || [ "$(cat "${TICKER_TEST_LOGIN_STATE}")" != "enabled via LaunchAgent" ]; then
                      printf 'Could not find service\n' >&2
                      exit 113
                    fi
                    version="$(cat "${TICKER_INSTALL_BUNDLE}/version.txt")"
                    if [ "${TICKER_TEST_KICKSTART_FAIL_VERSION:-}" = "$version" ]; then
                      printf 'injected kickstart failure for %s\n' "$version" >&2
                      exit 73
                    fi
                    if [ "${TICKER_TEST_KICKSTART_NO_START_VERSION:-}" != "$version" ]; then
                      printf 'running\n' > "${TICKER_TEST_PROCESS_STATE}"
                    fi
                    ;;
                  print)
                    if [ "$#" -ne 2 ] || [ "${2:-}" != "${TICKER_TEST_AGENT_TARGET}" ]; then
                      printf 'unexpected print target\n' >&2
                      exit 64
                    fi
                    result="${TICKER_TEST_LEGACY_LAUNCHCTL_RESULT:-auto}"
                    if [ "$result" = "auto" ]; then
                      if [ -s "${TICKER_TEST_LOGIN_STATE}" ] \
                          && [ "$(cat "${TICKER_TEST_LOGIN_STATE}")" = "enabled via LaunchAgent" ]; then
                        result="present"
                      else
                        result="absent"
                      fi
                    fi
                    case "$result" in
                      present)
                        if [ -f "${TICKER_TEST_PROCESS_STATE}" ]; then
                          printf 'gui/test = { state = running; }\n'
                        else
                          printf 'gui/test = { state = exited; }\n'
                        fi
                        ;;
                      absent)
                        printf 'Could not find service\n' >&2
                        exit 113
                        ;;
                      indeterminate)
                        printf 'permission denied\n' >&2
                        exit 5
                        ;;
                      *)
                        exit 64
                        ;;
                    esac
                    ;;
                  *)
                    printf 'unexpected launchctl command\n' >&2
                    exit 64
                    ;;
                esac
                """,
                named: "fake-launchctl.sh",
                in: directory
            )
            let linkCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                printf 'link %s\n' "$*" >> "${TICKER_TEST_PROCESS_CALLS}"
                exec /bin/ln "$@"
                """,
                named: "fake-ln.sh",
                in: directory
            )

            return (
                directory: directory,
                sourceBundle: sourceBundle,
                installedBundle: installedBundle,
                cliLink: cliLink,
                loginState: loginState,
                loginCalls: loginCalls,
                processState: processState,
                processCalls: processCalls,
                environment: [
                    "HOME": directory.appendingPathComponent("home", isDirectory: true).path,
                    "TICKER_INSTALL_SOURCE_BUNDLE": sourceBundle.path,
                    "TICKER_INSTALL_BUNDLE": installedBundle.path,
                    "TICKER_INSTALL_CLI_LINK": cliLink.path,
                    "TICKER_INSTALL_CODESIGN": "/usr/bin/true",
                    "TICKER_INSTALL_CODESIGN_CHECK_ENABLED": "1",
                    "TICKER_INSTALL_PLUTIL": "/usr/bin/plutil",
                    "TICKER_INSTALL_LAUNCHCTL": launchctlCommand.path,
                    "TICKER_INSTALL_COPY": "/bin/cp",
                    "TICKER_INSTALL_REMOVE": "/bin/rm",
                    "TICKER_INSTALL_LINK": linkCommand.path,
                    "TICKER_INSTALL_PGREP": pgrepCommand.path,
                    "TICKER_INSTALL_PKILL": pkillCommand.path,
                    "TICKER_INSTALL_OPEN": openCommand.path,
                    "TICKER_INSTALL_SLEEP": "/usr/bin/true",
                    "TICKER_INSTALL_STOP_CHECK_ATTEMPTS": "3",
                    "TICKER_INSTALL_START_CHECK_ATTEMPTS": "3",
                    "TICKER_TEST_PROCESS_STATE": processState.path,
                    "TICKER_TEST_PROCESS_CALLS": processCalls.path,
                    "TICKER_TEST_PGREP_CALLS": pgrepCalls.path,
                    "TICKER_TEST_PGREP_ERROR": "0",
                    "TICKER_TEST_PKILL_FAIL": "0",
                    "TICKER_TEST_START_PROCESS_AFTER_PGREP_AT": "0",
                    "TICKER_TEST_STUBBORN_PROCESS": "0",
                    "TICKER_TEST_OPEN_FAIL_VERSION": "",
                    "TICKER_TEST_OPEN_NO_START_VERSION": "",
                    "TICKER_TEST_LOGIN_TRANSITION_AFTER_OPEN_VERSION": "",
                    "TICKER_TEST_LOGIN_STATE_AFTER_OPEN": "",
                    "TICKER_TEST_LOGIN_STATE": loginState.path,
                    "TICKER_TEST_LOGIN_CALLS": loginCalls.path,
                    "TICKER_TEST_LOGIN_STATUS_CALLS": loginStatusCalls.path,
                    "TICKER_TEST_LOGIN_ENABLE_FAIL": "0",
                    "TICKER_TEST_LOGIN_SIGNAL_AFTER_ENABLE": "0",
                    "TICKER_TEST_LOGIN_SIGNAL_DURING_DISABLE": "0",
                    "TICKER_TEST_LOGIN_STATUS_FAIL_AT": "0",
                    "TICKER_TEST_LOGIN_STATUS_FAILURE_MESSAGE": "injected status failure",
                    "TICKER_TEST_LOGIN_STATUS_FAILURE_CODE": "75",
                    "TICKER_TEST_START_PROCESS_ON_LOGIN_STATUS_AT": "0",
                    "TICKER_TEST_LEGACY_LAUNCHCTL_RESULT": "auto",
                    "TICKER_TEST_AGENT_TARGET": "gui/\(getuid())/com.suchintan.ticker.login",
                    "TICKER_TEST_KICKSTART_FAIL_VERSION": "",
                    "TICKER_TEST_KICKSTART_NO_START_VERSION": "",
                ]
            )
        }

        func runInstaller(environment: [String: String]) throws -> test3A_ProcessResult {
            try test3A_runProcess(
                "/bin/bash",
                ["Scripts/install.sh"],
                environment: environment,
                removingEnvironmentKeys: ["TICKER_INSTALL_LEGACY_LOGIN_STATE"],
                currentDirectory: repository
            )
        }

        func startInstaller(
            environment overrides: [String: String],
            stdout: URL,
            stderr: URL
        ) throws -> Process {
            try Data().write(to: stdout)
            try Data().write(to: stderr)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["Scripts/install.sh"]
            process.currentDirectoryURL = repository
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "TICKER_INSTALL_LEGACY_LOGIN_STATE")
            for (key, value) in overrides {
                environment[key] = value
            }
            process.environment = environment
            process.standardOutput = try FileHandle(forWritingTo: stdout)
            process.standardError = try FileHandle(forWritingTo: stderr)
            try process.run()
            return process
        }

        func installedVersion(_ bundle: URL) -> String? {
            try? String(
                contentsOf: bundle.appendingPathComponent("version.txt"),
                encoding: .utf8
            )
        }

        func pathInode(_ url: URL) throws -> ino_t {
            var value = stat()
            guard Darwin.lstat(url.path, &value) == 0 else {
                throw FixtureError.missing(
                    "installer lstat \(url.path): \(String(cString: strerror(errno)))"
                )
            }
            return value.st_ino
        }

        func lockIdentity(_ url: URL) throws -> String {
            var value = stat()
            guard Darwin.lstat(url.path, &value) == 0 else {
                throw FixtureError.missing(
                    "installer lstat \(url.path): \(String(cString: strerror(errno)))"
                )
            }
            return "\(UInt64(value.st_dev)):\(UInt64(value.st_ino)):\(UInt(value.st_uid))"
        }

        func loginActions(_ calls: URL) -> [String] {
            guard let contents = try? String(contentsOf: calls, encoding: .utf8) else {
                return []
            }
            return contents.split(separator: "\n").map(String.init)
        }

        func processActions(_ calls: URL) -> [String] {
            guard let contents = try? String(contentsOf: calls, encoding: .utf8) else {
                return []
            }
            return contents.split(separator: "\n").map(String.init)
        }

        func transactionArtifacts(for installedBundle: URL) -> [String] {
            let parent = installedBundle.deletingLastPathComponent()
            let prefix = installedBundle.lastPathComponent
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            // Proven released-custody records are bounded audit artifacts, not
            // active transaction state. They are asserted separately below.
            return names.filter {
                $0.hasPrefix("\(prefix).staging.")
                    || $0.hasPrefix("\(prefix).backup.")
                    || $0.hasPrefix("\(prefix).failed.")
                    || $0 == "\(prefix).install.lock"
                    || $0.hasPrefix("\(prefix).install.lock.custody.")
                    || $0.hasPrefix(".ticker-rename-swap-")
            }
        }

        func releasedCustodyRecords(for installedBundle: URL) -> [URL] {
            let parent = installedBundle.deletingLastPathComponent()
            let prefix = "\(installedBundle.lastPathComponent).install.lock.released."
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            return names.filter { $0.hasPrefix(prefix) }.sorted().map {
                parent.appendingPathComponent($0, isDirectory: true)
            }
        }

        func releasedLockDirectoryIsProven(_ lockDirectory: URL) -> Bool {
            let marker = lockDirectory.appendingPathComponent("released-custody")
            guard
                let expectedIdentity = try? lockIdentity(lockDirectory),
                let recordedIdentity = try? String(contentsOf: marker, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return false
            }
            return recordedIdentity == expectedIdentity
        }

        func releasedCustodyRecordIsProven(_ record: URL) -> Bool {
            releasedLockDirectoryIsProven(
                record.appendingPathComponent("lock", isDirectory: true)
            )
        }

        func startInstalledHelperProbe(
            bundle: URL,
            ready: URL,
            stop: URL,
            failure: URL,
            samples: URL
        ) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                """
                : > "$2"
                count=0
                while [ ! -e "$3" ]; do
                  if value="$("$1/Contents/Helpers/ticker" probe 2>/dev/null)"; then
                    case "$value" in
                      old|new) ;;
                      *) printf 'unexpected helper output: %s\n' "$value" > "$4"; exit 1 ;;
                    esac
                  else
                    printf 'installed helper was unavailable\n' > "$4"
                    exit 1
                  fi
                  count=$((count + 1))
                done
                printf '%s\n' "$count" > "$5"
                """,
                "installed-helper-probe",
                bundle.path,
                ready.path,
                stop.path,
                failure.path,
                samples.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
                usleep(1_000)
            }
            guard FileManager.default.fileExists(atPath: ready.path) else {
                process.terminate()
                process.waitUntilExit()
                throw FixtureError.missing("installer helper probe did not become ready")
            }
            return process
        }

        do {
            let fixture = try makeFixture("overlapping-installers")
            let copyReady = fixture.directory.appendingPathComponent("copy-ready")
            let copyRelease = fixture.directory.appendingPathComponent("copy-release")
            let firstStdout = fixture.directory.appendingPathComponent("first-stdout.txt")
            let firstStderr = fixture.directory.appendingPathComponent("first-stderr.txt")
            let statCalls = fixture.directory.appendingPathComponent("stat-calls.txt")
            let recordingStat = try writeCommand(
                """
                #!/bin/sh
                set -eu
                printf 'stat %s\n' "$*" >> "${TICKER_TEST_STAT_CALLS}"
                exec /usr/bin/stat "$@"
                """,
                named: "recording-stat.sh",
                in: fixture.directory
            )
            let blockingCopy = try writeCommand(
                """
                #!/bin/sh
                set -eu
                : > "${TICKER_TEST_COPY_READY}"
                while [ ! -e "${TICKER_TEST_COPY_RELEASE}" ]; do
                  /bin/sleep 0.01
                done
                exec /bin/cp "$@"
                """,
                named: "blocking-copy.sh",
                in: fixture.directory
            )
            var overlapEnvironment = fixture.environment
            overlapEnvironment["TICKER_INSTALL_STAT"] = recordingStat.path
            overlapEnvironment["TICKER_TEST_STAT_CALLS"] = statCalls.path
            var firstEnvironment = overlapEnvironment
            firstEnvironment["TICKER_INSTALL_COPY"] = blockingCopy.path
            firstEnvironment["TICKER_TEST_COPY_READY"] = copyReady.path
            firstEnvironment["TICKER_TEST_COPY_RELEASE"] = copyRelease.path
            let priorInode = try pathInode(fixture.installedBundle)
            let first = try startInstaller(
                environment: firstEnvironment,
                stdout: firstStdout,
                stderr: firstStderr
            )
            defer {
                try? Data().write(to: copyRelease)
                if first.isRunning {
                    first.terminate()
                    first.waitUntilExit()
                }
            }

            let readyDeadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: copyReady.path), Date() < readyDeadline {
                usleep(1_000)
            }
            guard FileManager.default.fileExists(atPath: copyReady.path) else {
                throw FixtureError.missing("first overlapping installer did not reach copy seam")
            }
            let processCallsBeforeSecond = processActions(fixture.processCalls)
            let loginCallsBeforeSecond = loginActions(fixture.loginCalls)
            let statCallsBeforeSecond = try String(contentsOf: statCalls, encoding: .utf8)

            let second = try runInstaller(environment: overlapEnvironment)
            tests.expect(second.status != 0, "test16_installer_overlapSecondFails")
            tests.expect(
                second.stderr.contains("another installer owns")
                    && second.stderr.contains("remove the lock directory manually"),
                "test16_installer_overlapReportsOwnerAndManualRecovery"
            )
            tests.expectEqual(
                processActions(fixture.processCalls),
                processCallsBeforeSecond,
                "test16_installer_overlapSecondFailsBeforeAppCapture"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                loginCallsBeforeSecond,
                "test16_installer_overlapSecondFailsBeforeLoginCapture"
            )
            tests.expectEqual(
                try String(contentsOf: statCalls, encoding: .utf8),
                statCallsBeforeSecond,
                "test16_installer_overlapSecondFailsBeforePathStateCapture"
            )
            tests.expectEqual(
                try pathInode(fixture.installedBundle),
                priorInode,
                "test16_installer_overlapLeavesFirstInstalledIdentityIntact"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_installer_overlapDoesNotMutateCLI"
            )

            try Data().write(to: copyRelease)
            let finishDeadline = Date().addingTimeInterval(5)
            while first.isRunning, Date() < finishDeadline {
                usleep(1_000)
            }
            if first.isRunning {
                first.terminate()
                first.waitUntilExit()
            }
            tests.expectEqual(
                first.terminationStatus,
                0,
                "test16_installer_overlapFirstCompletesAfterSecondFails"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_installer_overlapFirstCommitsItsReplacement"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_overlapFirstReleasesOwnedLockAfterCleanup"
            )
            let releaseRecords = releasedCustodyRecords(for: fixture.installedBundle)
            tests.expectEqual(
                releaseRecords.count,
                1,
                "test16_installer_overlapRetainsOneBoundedCustodyRecordForOwner"
            )
            tests.expect(
                releaseRecords.allSatisfy(releasedCustodyRecordIsProven),
                "test16_installer_overlapCustodyRecordProvesReleasedOwnership"
            )
        }

        let lockSignalCases: [(name: String, status: Int32)] = [
            ("HUP", 129),
            ("QUIT", 131),
        ]
        let lockSignalPhases = [
            ("after-mkdir", "after-mkdir"),
            ("after-inode", "after-inode-capture"),
            ("between-metadata", "between-metadata-writes"),
        ]
        for signalCase in lockSignalCases {
            for (fixtureSuffix, signalPhase) in lockSignalPhases {
                let fixture = try makeFixture(
                    "lock-signal-\(signalCase.name.lowercased())-\(fixtureSuffix)"
                )
                var environment = fixture.environment
                environment["TICKER_INSTALL_LOCK_SIGNAL_PHASE"] = signalPhase
                environment["TICKER_INSTALL_LOCK_SIGNAL"] = signalCase.name

                let result = try runInstaller(environment: environment)
                tests.expectEqual(
                    result.status,
                    signalCase.status,
                    "test16_installer_\(signalCase.name)_\(signalPhase)_returnsDeferredSignalStatus"
                )
                tests.expect(
                    result.stderr.contains("received \(signalCase.name)"),
                    "test16_installer_\(signalCase.name)_\(signalPhase)_restoresSignalMaskAndHandler"
                )
                tests.expectEqual(
                    installedVersion(fixture.installedBundle),
                    "old",
                    "test16_installer_\(signalCase.name)_\(signalPhase)_doesNotEnterInstallTransaction"
                )
                tests.expectEqual(
                    processActions(fixture.processCalls),
                    [],
                    "test16_installer_\(signalCase.name)_\(signalPhase)_precedesAppStateCapture"
                )
                tests.expectEqual(
                    loginActions(fixture.loginCalls),
                    [],
                    "test16_installer_\(signalCase.name)_\(signalPhase)_precedesLoginStateCapture"
                )
                tests.expectEqual(
                    transactionArtifacts(for: fixture.installedBundle),
                    [],
                    "test16_installer_\(signalCase.name)_\(signalPhase)_releasesPublicLock"
                )
                let interruptedRecords = releasedCustodyRecords(
                    for: fixture.installedBundle
                )
                tests.expectEqual(
                    interruptedRecords.count,
                    1,
                    "test16_installer_\(signalCase.name)_\(signalPhase)_retainsOneCustodyRecord"
                )
                tests.expect(
                    interruptedRecords.allSatisfy(releasedCustodyRecordIsProven),
                    "test16_installer_\(signalCase.name)_\(signalPhase)_marksReleasedCustody"
                )

                let retry = try runInstaller(environment: fixture.environment)
                tests.expectEqual(
                    retry.status,
                    0,
                    "test16_installer_\(signalCase.name)_\(signalPhase)_allowsSafeRetry"
                )
                tests.expectEqual(
                    installedVersion(fixture.installedBundle),
                    "new",
                    "test16_installer_\(signalCase.name)_\(signalPhase)_retryCommitsReplacement"
                )
                tests.expectEqual(
                    transactionArtifacts(for: fixture.installedBundle),
                    [],
                    "test16_installer_\(signalCase.name)_\(signalPhase)_retryLeavesNoActiveLock"
                )
                let retryRecords = releasedCustodyRecords(for: fixture.installedBundle)
                tests.expectEqual(
                    retryRecords.count,
                    2,
                    "test16_installer_\(signalCase.name)_\(signalPhase)_boundsRecordsOnePerRun"
                )
                tests.expect(
                    retryRecords.allSatisfy(releasedCustodyRecordIsProven),
                    "test16_installer_\(signalCase.name)_\(signalPhase)_retryRecordsStayProven"
                )
            }
        }

        for signalCase in lockSignalCases {
            let fixture = try makeFixture(
                "lock-release-signal-\(signalCase.name.lowercased())"
            )
            let releaseSignalHook = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$1" = "during-custody-release" ]; then
                  kill "-${TICKER_TEST_LOCK_RELEASE_SIGNAL}" "$PPID"
                fi
                """,
                named: "signal-during-custody-release.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LOCK_HOOK"] = releaseSignalHook.path
            environment["TICKER_TEST_LOCK_RELEASE_SIGNAL"] = signalCase.name

            let result = try runInstaller(environment: environment)
            tests.expectEqual(
                result.status,
                signalCase.status,
                "test16_installer_\(signalCase.name)_duringCustodyReleaseReturnsSignalStatus"
            )
            tests.expect(
                result.stderr.contains(
                    "received \(signalCase.name) during installer lock release"
                ),
                "test16_installer_\(signalCase.name)_duringCustodyReleaseReconcilesHelperStatus"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_installer_\(signalCase.name)_duringCustodyReleaseKeepsCommittedInstall"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_\(signalCase.name)_duringCustodyReleaseLeavesPublicLockAbsent"
            )
            let interruptedRecords = releasedCustodyRecords(for: fixture.installedBundle)
            tests.expectEqual(
                interruptedRecords.count,
                1,
                "test16_installer_\(signalCase.name)_duringCustodyReleaseRetainsOneRecord"
            )
            tests.expect(
                interruptedRecords.allSatisfy(releasedCustodyRecordIsProven),
                "test16_installer_\(signalCase.name)_duringCustodyReleaseRestoresNativeMask"
            )

            let retry = try runInstaller(environment: fixture.environment)
            tests.expectEqual(
                retry.status,
                0,
                "test16_installer_\(signalCase.name)_duringCustodyReleaseAllowsCleanRetry"
            )
            tests.expectEqual(
                releasedCustodyRecords(for: fixture.installedBundle).count,
                2,
                "test16_installer_\(signalCase.name)_duringCustodyReleaseBoundsOneRecordPerRun"
            )
        }

        do {
            let fixture = try makeFixture("lock-date-failure")
            let failingDate = try writeCommand(
                "#!/bin/sh\nexit 81\n",
                named: "fail-lock-date.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_DATE"] = failingDate.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_installer_lockDateFailureIsReported")
            tests.expect(
                result.stderr.contains("could not obtain the installer lock timestamp"),
                "test16_installer_lockDateFailureIsObservable"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_lockDateFailureReleasesPartialOwnedLock"
            )
            tests.expectEqual(
                processActions(fixture.processCalls),
                [],
                "test16_installer_lockDateFailurePrecedesStateCapture"
            )
            tests.expectEqual(
                releasedCustodyRecords(for: fixture.installedBundle).count,
                1,
                "test16_installer_lockDateFailureRetainsOnePartialReleaseRecord"
            )

            let retry = try runInstaller(environment: fixture.environment)
            tests.expectEqual(retry.status, 0, "test16_installer_lockDateFailureAllowsRetry")
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_lockDateFailureRetryCleansArtifacts"
            )
            tests.expectEqual(
                releasedCustodyRecords(for: fixture.installedBundle).count,
                2,
                "test16_installer_lockDateFailureBoundsOneRecordPerRun"
            )
        }

        do {
            let fixture = try makeFixture("lock-write-failure")
            let writeFailureHook = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$1" = "between-metadata-writes" ]; then
                  chmod 0555 "$2"
                fi
                """,
                named: "fail-lock-write.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LOCK_HOOK"] = writeFailureHook.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_installer_lockWriteFailureIsReported")
            tests.expect(
                result.stderr.contains("could not record the installer lock timestamp"),
                "test16_installer_lockWriteFailureIsObservable"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_lockWriteFailureReleasesPartialOwnedLock"
            )
            tests.expectEqual(
                processActions(fixture.processCalls),
                [],
                "test16_installer_lockWriteFailurePrecedesStateCapture"
            )
            let partialRecords = releasedCustodyRecords(for: fixture.installedBundle)
            tests.expectEqual(
                partialRecords.count,
                1,
                "test16_installer_lockWriteFailureRetainsOnePartialReleaseRecord"
            )
            tests.expect(
                partialRecords.allSatisfy(releasedCustodyRecordIsProven),
                "test16_installer_lockWriteFailureMarksOwnedPartialCustody"
            )

            let retry = try runInstaller(environment: fixture.environment)
            tests.expectEqual(retry.status, 0, "test16_installer_lockWriteFailureAllowsRetry")
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_lockWriteFailureRetryCleansArtifacts"
            )
            tests.expectEqual(
                releasedCustodyRecords(for: fixture.installedBundle).count,
                2,
                "test16_installer_lockWriteFailureBoundsOneRecordPerRun"
            )
        }

        do {
            let fixture = try makeFixture("lock-successor-acquires-during-release")
            let lock = URL(fileURLWithPath: fixture.installedBundle.path + ".install.lock")
            let successorInodeRecord = fixture.directory.appendingPathComponent(
                "successor-public-lock-inode.txt"
            )
            let successorPID = "515151"
            let successorTimestamp = "2099-01-02T03:04:05Z"
            let successorAcquisitionHook = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$1" = "last-pre-delete" ]; then
                  /bin/mkdir "$2"
                  printf '%s\n' "${TICKER_TEST_SUCCESSOR_LOCK_PID}" > "$2/pid"
                  printf '%s\n' "${TICKER_TEST_SUCCESSOR_LOCK_TIMESTAMP}" > "$2/timestamp"
                  /usr/bin/stat -f '%i' "$2" > "${TICKER_TEST_SUCCESSOR_LOCK_INODE}"
                fi
                """,
                named: "acquire-successor-lock-during-release.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LOCK_HOOK"] = successorAcquisitionHook.path
            environment["TICKER_TEST_SUCCESSOR_LOCK_INODE"] = successorInodeRecord.path
            environment["TICKER_TEST_SUCCESSOR_LOCK_PID"] = successorPID
            environment["TICKER_TEST_SUCCESSOR_LOCK_TIMESTAMP"] = successorTimestamp

            let result = try runInstaller(environment: environment)
            tests.expectEqual(
                result.status,
                0,
                "test16_installer_successorPublicLockDuringReleaseLetsPriorOwnerSucceed"
            )
            tests.expect(
                !result.stderr.contains("public installer lock path"),
                "test16_installer_successorPublicLockIsNotClassifiedAsPriorOwnerCleanup"
            )
            let recordedSuccessorInode = try String(
                contentsOf: successorInodeRecord,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            tests.expectEqual(
                String(try pathInode(lock)),
                recordedSuccessorInode,
                "test16_installer_successorPublicLockPreservesExactInode"
            )
            tests.expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: lock.path).sorted(),
                ["pid", "timestamp"],
                "test16_installer_successorPublicLockPreservesExactEntries"
            )
            tests.expectEqual(
                try String(
                    contentsOf: lock.appendingPathComponent("pid"),
                    encoding: .utf8
                ),
                "\(successorPID)\n",
                "test16_installer_successorPublicLockPreservesExactPID"
            )
            tests.expectEqual(
                try String(
                    contentsOf: lock.appendingPathComponent("timestamp"),
                    encoding: .utf8
                ),
                "\(successorTimestamp)\n",
                "test16_installer_successorPublicLockPreservesExactTimestamp"
            )
            let releaseRecords = releasedCustodyRecords(for: fixture.installedBundle)
            tests.expectEqual(
                releaseRecords.count,
                1,
                "test16_installer_successorPublicLockKeepsOnePriorOwnerCustodyRecord"
            )
            tests.expect(
                releaseRecords.allSatisfy(releasedCustodyRecordIsProven),
                "test16_installer_successorPublicLockKeepsProvenPriorOwnerCustody"
            )
            tests.expect(
                releaseRecords.allSatisfy {
                    let releasedLock = $0.appendingPathComponent("lock", isDirectory: true)
                    return (try? pathInode(releasedLock)) != UInt64(recordedSuccessorInode)
                },
                "test16_installer_successorPublicLockStaysDistinctFromPriorOwnerCustody"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_installer_successorPublicLockDoesNotRollbackCommittedInstall"
            )

            try FileManager.default.removeItem(at: lock)
            let retry = try runInstaller(environment: fixture.environment)
            tests.expectEqual(
                retry.status,
                0,
                "test16_installer_successorPublicLockAllowsRetryAfterSuccessorRelease"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_successorPublicLockRetryLeavesNoActiveLock"
            )
            tests.expectEqual(
                releasedCustodyRecords(for: fixture.installedBundle).count,
                2,
                "test16_installer_successorPublicLockBoundsOneRecordPerRun"
            )
        }

        do {
            let fixture = try makeFixture("lock-foreign-at-former-pre-rmdir")
            let lock = URL(fileURLWithPath: fixture.installedBundle.path + ".install.lock")
            let heldOwnedLock = URL(fileURLWithPath: lock.path + ".custody.held")
            let foreignInodeRecord = fixture.directory.appendingPathComponent(
                "foreign-custody-inode.txt"
            )
            let foreignPathRecord = fixture.directory.appendingPathComponent(
                "foreign-custody-path.txt"
            )
            let swapHook = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$1" = "former-pre-rmdir" ]; then
                  /bin/mv "$3" "${TICKER_TEST_LOCK_HELD_PATH}"
                  /bin/mkdir "$3"
                  printf '%s\n' "$3" > "${TICKER_TEST_FOREIGN_LOCK_PATH}"
                  /usr/bin/stat -f '%i' "$3" > "${TICKER_TEST_FOREIGN_LOCK_INODE}"
                fi
                """,
                named: "swap-lock-at-former-pre-rmdir.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LOCK_HOOK"] = swapHook.path
            environment["TICKER_TEST_LOCK_HELD_PATH"] = heldOwnedLock.path
            environment["TICKER_TEST_FOREIGN_LOCK_INODE"] = foreignInodeRecord.path
            environment["TICKER_TEST_FOREIGN_LOCK_PATH"] = foreignPathRecord.path

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_installer_foreignCustodyAtFormerRmdirRequiresManualCleanup"
            )
            tests.expect(
                result.stderr.contains(
                    "foreign inode at released-custody path was preserved for manual cleanup"
                ),
                "test16_installer_foreignCustodyAtFormerRmdirIsClassified"
            )
            let recordedForeignInode = try String(
                contentsOf: foreignInodeRecord,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let recordedForeignPath = try String(
                contentsOf: foreignPathRecord,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let foreignPath = URL(
                fileURLWithPath: recordedForeignPath
            )
            tests.expectEqual(
                String(try pathInode(foreignPath)),
                recordedForeignInode,
                "test16_installer_foreignCustodyAtFormerRmdirPreservesExactInode"
            )
            tests.expect(
                releasedLockDirectoryIsProven(heldOwnedLock),
                "test16_installer_foreignCustodyAtFormerRmdirRetainsMarkedOwnedInode"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: lock.path),
                "test16_installer_foreignCustodyAtFormerRmdirLeavesPublicLockReleased"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_installer_foreignCustodyAtFormerRmdirKeepsCommittedInstall"
            )

            let retry = try runInstaller(environment: fixture.environment)
            tests.expectEqual(
                retry.status,
                0,
                "test16_installer_foreignCustodyAtFormerRmdirAllowsCleanRetry"
            )
            tests.expectEqual(
                String(try pathInode(foreignPath)),
                recordedForeignInode,
                "test16_installer_foreignCustodySurvivesCleanRetry"
            )
            tests.expect(
                releasedLockDirectoryIsProven(heldOwnedLock),
                "test16_installer_ownedCustodySurvivesCleanRetry"
            )
            tests.expectEqual(
                releasedCustodyRecords(for: fixture.installedBundle).count,
                2,
                "test16_installer_foreignCustodyRetryBoundsOneNamespacePerRun"
            )
            tests.expect(
                transactionArtifacts(for: fixture.installedBundle).contains(
                    heldOwnedLock.lastPathComponent
                ),
                "test16_installer_foreignCustodyRemainsExplicitManualArtifact"
            )
        }

        do {
            let fixture = try makeFixture("stale-installer-lock")
            let lock = URL(fileURLWithPath: fixture.installedBundle.path + ".install.lock")
            try FileManager.default.createDirectory(
                at: lock,
                withIntermediateDirectories: false
            )
            try "424242\n".write(
                to: lock.appendingPathComponent("pid"),
                atomically: true,
                encoding: .utf8
            )
            try "2001-01-01T00:00:00Z\n".write(
                to: lock.appendingPathComponent("timestamp"),
                atomically: true,
                encoding: .utf8
            )
            let staleLockInode = try pathInode(lock)

            let result = try runInstaller(environment: fixture.environment)
            tests.expect(result.status != 0, "test16_installer_staleLockFailsClosed")
            tests.expect(
                result.stderr.contains("pid=424242")
                    && result.stderr.contains("acquired=2001-01-01T00:00:00Z"),
                "test16_installer_staleLockReportsRecordedOwner"
            )
            tests.expect(
                FileManager.default.fileExists(atPath: lock.path),
                "test16_installer_staleLockIsNeverStolen"
            )
            tests.expectEqual(
                try pathInode(lock),
                staleLockInode,
                "test16_installer_staleLockPreservesExactForeignInode"
            )
            tests.expectEqual(
                processActions(fixture.processCalls),
                [],
                "test16_installer_staleLockFailsBeforeAppCapture"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                [],
                "test16_installer_staleLockFailsBeforeLoginCapture"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_staleLockPreservesInstalledBundle"
            )
            tests.expectEqual(
                releasedCustodyRecords(for: fixture.installedBundle),
                [],
                "test16_installer_staleForeignLockCreatesNoOwnedCustodyRecord"
            )
            try FileManager.default.removeItem(at: lock)
        }

        do {
            let fixture = try makeFixture("fresh-app-path-appearance", priorVersion: nil)
            let foreignBundle = fixture.directory.appendingPathComponent(
                "foreign/Ticker.app",
                isDirectory: true
            )
            try writeBundle(foreignBundle, version: "foreign")
            let noReplaceCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$3" = "${TICKER_INSTALL_BUNDLE}" ]; then
                  mkdir -p "$3"
                  /bin/cp -R "${TICKER_TEST_FOREIGN_BUNDLE}/." "$3/"
                fi
                exec "${TICKER_INSTALL_NATIVE_RENAME_HELPER}" "$@"
                """,
                named: "app-appearance-before-no-replace.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_NO_REPLACE"] = noReplaceCommand.path
            environment["TICKER_TEST_FOREIGN_BUNDLE"] = foreignBundle.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_freshAppAppearanceIsRejected")
            tests.expect(
                result.stderr.contains("no-replace publication refused to overwrite it")
                    && result.stderr.contains("left untouched for manual recovery"),
                "test16_freshAppAppearanceIsObservable"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "foreign",
                "test16_freshAppAppearanceNeverOverwritesForeignBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_freshAppAppearanceDoesNotMutateLoginState"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_freshAppAppearanceDoesNotPublishCLI"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_freshAppAppearanceCleansOnlyOwnedArtifacts"
            )
        }

        do {
            let fixture = try makeFixture("fresh-cli-path-appearance")
            let foreignTarget = fixture.directory.appendingPathComponent("foreign-cli")
            try writeExecutable("#!/bin/sh\nexit 0\n", to: foreignTarget)
            let noReplaceCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$3" = "${TICKER_INSTALL_CLI_LINK}" ]; then
                  /bin/ln -s "${TICKER_TEST_FOREIGN_CLI_TARGET}" "$3"
                fi
                exec "${TICKER_INSTALL_NATIVE_RENAME_HELPER}" "$@"
                """,
                named: "cli-appearance-before-no-replace.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_NO_REPLACE"] = noReplaceCommand.path
            environment["TICKER_TEST_FOREIGN_CLI_TARGET"] = foreignTarget.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_freshCLIAppearanceIsRejected")
            tests.expect(
                result.stderr.contains("CLI path appeared; no-replace publication refused")
                    && result.stderr.contains("left the unexpected destination identity untouched"),
                "test16_freshCLIAppearanceIsObservable"
            )
            tests.expectEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: fixture.cliLink.path),
                foreignTarget.path,
                "test16_freshCLIAppearanceNeverOverwritesForeignPath"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_freshCLIAppearanceRollsBackBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_freshCLIAppearanceRollsBackWithZeroLoginMutation"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_freshCLIAppearanceCleansOnlyOwnedArtifacts"
            )
        }

        do {
            let fixture = try makeFixture("copy-failure")
            let copyCommand = try writeCommand(
                "#!/bin/sh\nexit 71\n",
                named: "fail-copy.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_COPY"] = copyCommand.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_installer_copyFailureIsReported")
            tests.expect(
                result.stderr.contains("copy to staged replacement failed"),
                "test16_installer_copyFailureIsObservable"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_copyFailurePreservesPriorBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                [],
                "test16_installer_copyFailureDoesNotTouchLoginTarget"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_copyFailureCleansStaging"
            )
        }

        do {
            let fixture = try makeFixture("copy-replaces-staging-inode")
            let priorCLITarget = fixture.directory.appendingPathComponent("prior-cli")
            try writeExecutable("#!/bin/sh\nexit 0\n", to: priorCLITarget)
            try FileManager.default.createSymbolicLink(
                at: fixture.cliLink,
                withDestinationURL: priorCLITarget
            )
            let priorBundleInode = try pathInode(fixture.installedBundle)
            let priorCLIInode = try pathInode(fixture.cliLink)
            let copyIdentities = fixture.directory.appendingPathComponent(
                "copy-staging-identities.txt"
            )
            let replacingCopy = try writeCommand(
                """
                #!/bin/sh
                set -eu
                destination="${3%/}"
                replacement="${destination}.copied.$$"
                before="$(/usr/bin/stat -f '%i' "$destination")"
                /bin/mkdir "$replacement"
                /bin/cp -R "$2" "$replacement/"
                /bin/rm -rf "$destination"
                /bin/mv "$replacement" "$destination"
                after="$(/usr/bin/stat -f '%i' "$destination")"
                printf '%s\n%s\n' "$before" "$after" > "${TICKER_TEST_COPY_IDENTITIES}"
                """,
                named: "replace-staging-copy.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_COPY"] = replacingCopy.path
            environment["TICKER_TEST_COPY_IDENTITIES"] = copyIdentities.path
            environment["TICKER_TEST_OPEN_FAIL_VERSION"] = "new"

            let result = try runInstaller(environment: environment)
            let copiedIdentities = (
                try? String(contentsOf: copyIdentities, encoding: .utf8)
            )?.split(separator: "\n").map(String.init) ?? []
            tests.expect(
                copiedIdentities.count == 2 && copiedIdentities[0] != copiedIdentities[1],
                "test16_installer_copyFixtureReplacesStagingRootInode"
            )
            tests.expect(result.status != 0, "test16_installer_postCopyFailureIsReported")
            tests.expect(
                result.stderr.contains("replacement launch command failed")
                    && processActions(fixture.processCalls).contains("open new"),
                "test16_installer_postCopyFailureOccursAfterBundleAndCLIMutation"
            )
            tests.expectEqual(
                try pathInode(fixture.installedBundle),
                priorBundleInode,
                "test16_installer_postCopyInodeReplacementRestoresPriorBundleIdentity"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_postCopyInodeReplacementRestoresPriorBundleContents"
            )
            tests.expectEqual(
                try pathInode(fixture.cliLink),
                priorCLIInode,
                "test16_installer_postCopyInodeReplacementRestoresPriorCLIIdentity"
            )
            tests.expectEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: fixture.cliLink.path),
                priorCLITarget.path,
                "test16_installer_postCopyInodeReplacementRestoresPriorCLITarget"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_installer_postCopyInodeReplacementKeepsLoginStateReadOnly"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_postCopyInodeReplacementCleansOwnedArtifacts"
            )
        }

        do {
            let fixture = try makeFixture("invalid-staged-bundle")
            try "not a property list".write(
                to: fixture.sourceBundle.appendingPathComponent("Contents/Info.plist"),
                atomically: true,
                encoding: .utf8
            )

            let result = try runInstaller(environment: fixture.environment)
            tests.expect(result.status != 0, "test16_installer_invalidStageIsRejected")
            tests.expect(
                result.stderr.contains("staged replacement: ERROR - Info.plist is invalid"),
                "test16_installer_invalidStageFailureIsObservable"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_invalidStagePreservesPriorBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                [],
                "test16_installer_invalidStageDoesNotTouchLoginTarget"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_invalidStageCleansStaging"
            )
        }

        let invalidBundleIdentityCases: [(field: String, wrong: String, expected: String)] = [
            ("CFBundleIdentifier", "com.example.not-ticker", "com.suchintan.ticker"),
            ("CFBundleExecutable", "NotTicker", "Ticker"),
            ("CFBundlePackageType", "BNDL", "APPL"),
        ]
        for invalidIdentity in invalidBundleIdentityCases {
            let fixtureName = "invalid-\(invalidIdentity.field.lowercased())"
            let fixture = try makeFixture(fixtureName)
            let priorBundleInode = try pathInode(fixture.installedBundle)
            let infoPlist = fixture.sourceBundle.appendingPathComponent("Contents/Info.plist")
            var propertyList = try test2A_readPropertyList(infoPlist)
            propertyList[invalidIdentity.field] = invalidIdentity.wrong
            try writePropertyList(propertyList, to: infoPlist)

            let result = try runInstaller(environment: fixture.environment)
            tests.expect(
                result.status != 0,
                "test16_installer_\(invalidIdentity.field)WrongValueIsRejected"
            )
            tests.expect(
                result.stderr.contains(
                    "Info.plist \(invalidIdentity.field) must be exactly "
                        + "'\(invalidIdentity.expected)' (found '\(invalidIdentity.wrong)')"
                ),
                "test16_installer_\(invalidIdentity.field)WrongValueIsObservable"
            )
            tests.expectEqual(
                try pathInode(fixture.installedBundle),
                priorBundleInode,
                "test16_installer_\(invalidIdentity.field)RejectsBeforeBundleMutation"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_\(invalidIdentity.field)PreservesPriorBundle"
            )
            tests.expect(
                loginActions(fixture.loginCalls).isEmpty,
                "test16_installer_\(invalidIdentity.field)RejectsBeforeLoginMutation"
            )
            tests.expect(
                processActions(fixture.processCalls).allSatisfy { $0.hasPrefix("pgrep ") },
                "test16_installer_\(invalidIdentity.field)RejectsBeforeProcessMutation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_installer_\(invalidIdentity.field)RejectsBeforeCLIMutation"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_\(invalidIdentity.field)CleansOwnedStaging"
            )
        }

        do {
            let fixture = try makeFixture("signature-failure")
            let codesignCommand = try writeCommand(
                "#!/bin/sh\nexit 72\n",
                named: "fail-codesign.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_CODESIGN"] = codesignCommand.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_installer_signatureFailureIsRejected")
            tests.expect(
                result.stderr.contains("staged replacement: ERROR - signature verification failed"),
                "test16_installer_signatureFailureIsObservable"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_signatureFailurePreservesPriorBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                [],
                "test16_installer_signatureFailureDoesNotTouchLoginTarget"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_signatureFailureCleansStaging"
            )
        }

        do {
            let fixture = try makeFixture("modern-login-live-launch-agent")
            try "enabled via LaunchAgent\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            try "running\n".write(
                to: fixture.processState,
                atomically: true,
                encoding: .utf8
            )

            let result = try runInstaller(environment: fixture.environment)
            tests.expectEqual(result.status, 0, "test16_modernLiveLaunchAgent_succeeds")
            tests.expect(
                result.stdout.contains(
                    "login item: captured prior state: enabled via LaunchAgent"
                )
                    && result.stdout.contains(
                        "login item: preserved prior state: enabled via LaunchAgent"
                    )
                    && result.stdout.contains(
                        "login item: final preserved state: enabled via LaunchAgent"
                    ),
                "test16_modernLiveLaunchAgent_isCapturedAndVerifiedExactly"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_modernLiveLaunchAgent_installsReplacement"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status"],
                "test16_modernLiveLaunchAgent_usesOnlyReadOnlyLoginProofs"
            )
            let modernLaunchAgentEvents = processActions(fixture.processCalls)
            let modernKickstarts = modernLaunchAgentEvents.indices.filter {
                modernLaunchAgentEvents[$0]
                    == "launchctl kickstart -k gui/\(getuid())/com.suchintan.ticker.login"
            }
            let modernLoginStatuses = modernLaunchAgentEvents.indices.filter {
                modernLaunchAgentEvents[$0] == "login status"
            }
            let modernStopIndex = modernLaunchAgentEvents.firstIndex {
                $0.hasPrefix("pkill ")
            }
            let modernLinkIndex = modernLaunchAgentEvents.firstIndex {
                $0.hasPrefix("link ")
            }
            tests.expect(
                modernKickstarts.count == 1
                    && !modernLaunchAgentEvents.contains("open new")
                    && !modernLaunchAgentEvents.contains {
                        $0.hasPrefix("launchctl bootstrap ")
                    },
                "test16_modernLiveLaunchAgent_usesOneExactKickstartAsSoleReplacementStart"
            )
            if modernKickstarts.count == 1,
               modernLoginStatuses.count == 3,
               let modernStopIndex,
               let modernLinkIndex {
                tests.expect(
                    modernStopIndex < modernKickstarts[0]
                        && modernKickstarts[0] > modernLaunchAgentEvents.startIndex
                        && modernLaunchAgentEvents[modernKickstarts[0] - 1]
                            .hasPrefix("pgrep new ")
                        && modernKickstarts[0] < modernLoginStatuses[1]
                        && modernLoginStatuses[1] < modernLinkIndex
                        && modernLinkIndex < modernLoginStatuses[2],
                    "test16_modernLiveLaunchAgent_startsOnlyAfterPostExchangeAbsenceProof"
                )
            } else {
                tests.expect(
                    false,
                    "test16_modernLiveLaunchAgent_recordsCompleteRestartAndProofOrdering"
                )
            }
        }

        do {
            let fixture = try makeFixture("legacy-login-live-launch-agent", priorVersion: "legacy")
            try "enabled via LaunchAgent\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            try "running\n".write(
                to: fixture.processState,
                atomically: true,
                encoding: .utf8
            )

            let result = try runInstaller(environment: fixture.environment)
            tests.expectEqual(result.status, 0, "test16_legacyLiveLaunchAgent_succeeds")
            tests.expect(
                result.stdout.contains(
                    "prior helper lacks login-item; using the legacy launchctl/plist read contract"
                )
                    && result.stdout.contains(
                        "login item: captured prior state: enabled via LaunchAgent"
                    )
                    && result.stdout.contains(
                        "login item: preserved prior state: enabled via LaunchAgent"
                    )
                    && result.stdout.contains(
                        "login item: final preserved state: enabled via LaunchAgent"
                    ),
                "test16_legacyLiveLaunchAgent_isCapturedAndVerifiedExactly"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_legacyLiveLaunchAgent_installsReplacement"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "enabled via LaunchAgent\n",
                "test16_legacyLiveLaunchAgent_preservesMechanism"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status", "status"],
                "test16_legacyLiveLaunchAgent_usesReadOnlyCaptureAndInstalledVerification"
            )
            let legacyLaunchAgentEvents = processActions(fixture.processCalls)
            let legacyKickstarts = legacyLaunchAgentEvents.indices.filter {
                legacyLaunchAgentEvents[$0]
                    == "launchctl kickstart -k gui/\(getuid())/com.suchintan.ticker.login"
            }
            let legacyLoginStatuses = legacyLaunchAgentEvents.indices.filter {
                legacyLaunchAgentEvents[$0] == "login status"
            }
            let legacyStopIndex = legacyLaunchAgentEvents.firstIndex {
                $0.hasPrefix("pkill ")
            }
            let legacyLinkIndex = legacyLaunchAgentEvents.firstIndex {
                $0.hasPrefix("link ")
            }
            let legacyReplacementOpen = legacyLaunchAgentEvents.contains("open new")
            tests.expect(
                legacyKickstarts.count == 1
                    && !legacyReplacementOpen
                    && !legacyLaunchAgentEvents.contains {
                        $0.hasPrefix("launchctl bootstrap ")
                    },
                "test16_legacyLiveLaunchAgent_usesOneExactKickstartAsSoleReplacementStart"
            )
            if legacyKickstarts.count == 1,
               legacyLoginStatuses.count == 4,
               let legacyStopIndex,
               let legacyLinkIndex {
                tests.expect(
                    legacyStopIndex < legacyKickstarts[0]
                        && legacyKickstarts[0] > legacyLaunchAgentEvents.startIndex
                        && legacyLaunchAgentEvents[legacyKickstarts[0] - 1]
                            .hasPrefix("pgrep new ")
                        && legacyKickstarts[0] < legacyLoginStatuses[2]
                        && legacyLoginStatuses[2] < legacyLinkIndex
                        && legacyLinkIndex < legacyLoginStatuses[3],
                    "test16_legacyLiveLaunchAgent_startsOnlyAfterPostExchangeAbsenceProof"
                )
            } else {
                tests.expect(
                    false,
                    "test16_legacyLiveLaunchAgent_recordsCompleteRestartAndProofOrdering"
                )
            }
        }

        do {
            let fixture = try makeFixture("launch-agent-kickstart-failure-rollback")
            try "enabled via LaunchAgent\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            try "running\n".write(
                to: fixture.processState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_TEST_KICKSTART_FAIL_VERSION"] = "new"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_launchAgentKickstartFailure_failsTransaction"
            )
            tests.expect(
                result.stderr.contains(
                    "replacement exact LaunchAgent kickstart failed "
                        + "(launchctl status 73): injected kickstart failure for new"
                )
                    && result.stdout.contains(
                        "app: restored app exact LaunchAgent restart verified"
                    )
                    && result.stderr.contains(
                        "login item: restored exact prior state: enabled via LaunchAgent"
                    ),
                "test16_launchAgentKickstartFailure_reportsFailureAndVerifiedRollback"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_launchAgentKickstartFailure_restoresPriorBundle"
            )
            tests.expect(
                FileManager.default.fileExists(atPath: fixture.processState.path),
                "test16_launchAgentKickstartFailure_restoresRunningProcess"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "enabled via LaunchAgent\n",
                "test16_launchAgentKickstartFailure_restoresExactPriorMechanism"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_launchAgentKickstartFailure_restoresPriorCLIAbsence"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_launchAgentKickstartFailure_reprovesRestoredExactLoginState"
            )
            let rollbackEvents = processActions(fixture.processCalls)
            let rollbackKickstarts = rollbackEvents.indices.filter {
                rollbackEvents[$0]
                    == "launchctl kickstart -k gui/\(getuid())/com.suchintan.ticker.login"
            }
            let rollbackStateProof = rollbackEvents.lastIndex(of: "login status")
            tests.expect(
                rollbackKickstarts.count == 2
                    && rollbackStateProof != nil
                    && rollbackKickstarts[1] < rollbackStateProof!
                    && !rollbackEvents.contains("open old")
                    && !rollbackEvents.contains {
                        $0.hasPrefix("launchctl bootstrap ")
                    },
                "test16_launchAgentKickstartFailure_rollsBackThroughExactTargetBeforeProof"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_launchAgentKickstartFailure_cleansAfterProvenRollback"
            )
        }

        do {
            let fixture = try makeFixture(
                "launch-agent-process-appears-during-login-capture-rollback"
            )
            try "enabled via LaunchAgent\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_TEST_START_PROCESS_ON_LOGIN_STATUS_AT"] = "1"
            environment["TICKER_TEST_LOGIN_STATUS_FAIL_AT"] = "3"
            environment["TICKER_TEST_LOGIN_STATUS_FAILURE_MESSAGE"] =
                "injected late final login proof failure"

            let result = try runInstaller(environment: environment)

            tests.expect(
                result.status != 0,
                "test16_reinstallCustody_lateProcessThenFailureRollsBack"
            )
            tests.expect(
                result.stdout.contains("app: captured prior state: not running")
                    && result.stdout.contains(
                        "login item: captured prior state: enabled via LaunchAgent"
                    )
                    && result.stderr.contains("injected late final login proof failure")
                    && result.stdout.contains(
                        "app: restored app exact LaunchAgent restart verified"
                    )
                    && result.stderr.contains(
                        "login item: restored exact prior state: enabled via LaunchAgent"
                    ),
                "test16_reinstallCustody_rollbackProvesCapturedLaunchAgentAndProcess"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_reinstallCustody_restoresPriorBundle"
            )
            tests.expect(
                FileManager.default.fileExists(atPath: fixture.processState.path),
                "test16_reinstallCustody_restartsProcessStoppedAfterEarliestSnapshot"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status", "status"],
                "test16_reinstallCustody_reprovesCapturedLaunchAgentAfterRollback"
            )
            let custodyEvents = processActions(fixture.processCalls)
            let custodyKickstarts = custodyEvents.indices.filter {
                custodyEvents[$0]
                    == "launchctl kickstart -k gui/\(getuid())/com.suchintan.ticker.login"
            }
            let custodyStops = custodyEvents.filter { $0.hasPrefix("pkill ") }
            let firstLoginStatus = custodyEvents.firstIndex(of: "login status")
            let firstStop = custodyEvents.firstIndex { $0.hasPrefix("pkill ") }
            let rollbackStatus = custodyEvents.lastIndex(of: "login status")
            tests.expect(
                custodyKickstarts.count == 2
                    && custodyStops.count == 2
                    && firstLoginStatus != nil
                    && firstStop != nil
                    && firstLoginStatus! < firstStop!
                    && rollbackStatus != nil
                    && custodyKickstarts[1] < rollbackStatus!
                    && !custodyEvents.contains("open old")
                    && !custodyEvents.contains("open new"),
                "test16_reinstallCustody_ordersLateStopAndExactRollbackKickstart"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_reinstallCustody_cleansAfterProvenRollback"
            )
        }

        let preStartRollbackScenarios: [(name: String, startsLateOldProcess: Bool)] = [
            ("late-old-process", true),
            ("no-process-control", false),
        ]
        for scenario in preStartRollbackScenarios {
            let fixture = try makeFixture(
                "pre-start-rollback-\(scenario.name)"
            )
            let codesignCalls = fixture.directory.appendingPathComponent(
                "codesign-calls.txt"
            )
            let failInstalledValidation = try writeCommand(
                """
                #!/bin/sh
                set -eu
                call_count=0
                if [ -f "${TICKER_TEST_CODESIGN_CALLS}" ]; then
                  call_count="$(cat "${TICKER_TEST_CODESIGN_CALLS}")"
                fi
                call_count=$((call_count + 1))
                printf '%s\n' "$call_count" > "${TICKER_TEST_CODESIGN_CALLS}"
                if [ "$call_count" -eq 2 ]; then
                  printf 'injected installed replacement validation failure\n' >&2
                  exit 74
                fi
                """,
                named: "fail-installed-validation-\(scenario.name).sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_CODESIGN"] = failInstalledValidation.path
            environment["TICKER_TEST_CODESIGN_CALLS"] = codesignCalls.path
            if scenario.startsLateOldProcess {
                environment["TICKER_TEST_START_PROCESS_AFTER_PGREP_AT"] = "2"
            }

            let result = try runInstaller(environment: environment)
            let events = processActions(fixture.processCalls)
            let exactKickstart =
                "launchctl kickstart -k gui/\(getuid())/com.suchintan.ticker.login"

            tests.expect(
                result.status != 0
                    && result.stdout.contains("app: captured prior state: not running")
                    && result.stdout.contains("application replacement exchanged atomically")
                    && result.stderr.contains(
                        "installed replacement: ERROR - signature verification failed"
                    )
                    && !events.contains("open new")
                    && !events.contains(exactKickstart),
                "test16_preStartRollback_\(scenario.name)_failsAfterExchangeBeforeReplacementStart"
            )
            tests.expectEqual(
                try String(contentsOf: codesignCalls, encoding: .utf8),
                "3\n",
                "test16_preStartRollback_\(scenario.name)_validatesStageFailureAndRestoredBundle"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_preStartRollback_\(scenario.name)_restoresPriorBundle"
            )

            if scenario.startsLateOldProcess {
                let lateStartIndex = events.firstIndex(of: "process-start old")
                let rollbackStopIndex = events.firstIndex { $0.hasPrefix("pkill ") }
                let restoredOpenIndex = events.firstIndex(of: "open old")
                if let lateStartIndex,
                   let rollbackStopIndex,
                   let restoredOpenIndex {
                    tests.expect(
                        lateStartIndex > events.startIndex
                            && events[lateStartIndex - 1].hasPrefix("pgrep old ")
                            && lateStartIndex < rollbackStopIndex
                            && events[rollbackStopIndex].hasPrefix("pkill new ")
                            && rollbackStopIndex < restoredOpenIndex,
                        "test16_preStartRollback_lateOldProcess_stopsThenReopensRestoredApp"
                    )
                } else {
                    tests.expect(
                        false,
                        "test16_preStartRollback_lateOldProcess_recordsStartStopAndRestoreOpen"
                    )
                }
                tests.expect(
                    FileManager.default.fileExists(atPath: fixture.processState.path)
                        && events.filter { $0.hasPrefix("pkill ") }.count == 1,
                    "test16_preStartRollback_lateOldProcess_restoresRunningState"
                )
            } else {
                tests.expect(
                    !FileManager.default.fileExists(atPath: fixture.processState.path)
                        && !events.contains { $0.hasPrefix("process-start ") }
                        && !events.contains { $0.hasPrefix("pkill ") }
                        && !events.contains("open old"),
                    "test16_preStartRollback_noProcessControl_preservesStoppedState"
                )
            }
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_preStartRollback_\(scenario.name)_cleansAfterProvenRollback"
            )
        }

        do {
            let fixture = try makeFixture(
                "late-old-process-after-pre-exchange-absence"
            )
            var environment = fixture.environment
            environment["TICKER_TEST_START_PROCESS_AFTER_PGREP_AT"] = "2"
            environment["TICKER_TEST_LOGIN_STATUS_FAIL_AT"] = "3"
            environment["TICKER_TEST_LOGIN_STATUS_FAILURE_MESSAGE"] =
                "injected failure after replacement launch"

            let result = try runInstaller(environment: environment)

            tests.expect(
                result.status != 0
                    && result.stdout.contains("app: captured prior state: not running")
                    && result.stderr.contains("injected failure after replacement launch")
                    && result.stdout.contains("app: restored app launch verified"),
                "test16_postExchangeBarrier_lateOldProcessFailureRestartsRestoredApp"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_postExchangeBarrier_lateOldProcessFailureRestoresPriorBundle"
            )
            tests.expect(
                FileManager.default.fileExists(atPath: fixture.processState.path),
                "test16_postExchangeBarrier_lateOldProcessFailureRestoresRunningState"
            )
            let lateProcessEvents = processActions(fixture.processCalls)
            let lateStartIndex = lateProcessEvents.firstIndex(of: "process-start old")
            let lateStopIndices = lateProcessEvents.indices.filter {
                lateProcessEvents[$0].hasPrefix("pkill ")
            }
            let replacementOpenIndex = lateProcessEvents.firstIndex(of: "open new")
            let restoredOpenIndex = lateProcessEvents.firstIndex(of: "open old")
            if let lateStartIndex,
               lateStopIndices.count == 2,
               let replacementOpenIndex,
               let restoredOpenIndex {
                tests.expect(
                    lateStartIndex > lateProcessEvents.startIndex
                        && lateProcessEvents[lateStartIndex - 1].hasPrefix("pgrep old ")
                        && lateStartIndex < lateStopIndices[0]
                        && lateProcessEvents[lateStopIndices[0]].hasPrefix("pkill new ")
                        && replacementOpenIndex > lateProcessEvents.startIndex
                        && lateProcessEvents[replacementOpenIndex - 1].hasPrefix("pgrep new ")
                        && lateStopIndices[0] < replacementOpenIndex
                        && replacementOpenIndex < lateStopIndices[1]
                        && lateStopIndices[1] < restoredOpenIndex,
                    "test16_postExchangeBarrier_stopsDisplacedOldImageBeforeReplacementStart"
                )
            } else {
                tests.expect(
                    false,
                    "test16_postExchangeBarrier_recordsLateStartStopAndRollbackOrdering"
                )
            }
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_postExchangeBarrier_lateOldProcessRollbackCleans"
            )
        }

        let stoppedPriorScenarios: [(name: String, loginState: String?)] = [
            ("disabled", nil),
            ("system-settings", "enabled via System Settings login item\n"),
        ]
        for scenario in stoppedPriorScenarios {
            let fixture = try makeFixture(
                "stopped-\(scenario.name)-post-launch-failure-rollback"
            )
            if let loginState = scenario.loginState {
                try loginState.write(
                    to: fixture.loginState,
                    atomically: true,
                    encoding: .utf8
                )
            }
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_STATUS_FAIL_AT"] = "3"
            environment["TICKER_TEST_LOGIN_STATUS_FAILURE_MESSAGE"] =
                "injected post-launch final status failure"

            let result = try runInstaller(environment: environment)

            tests.expect(
                result.status != 0
                    && result.stderr.contains("injected post-launch final status failure"),
                "test16_reinstallCustody_\(scenario.name)ReplacementFailureRollsBack"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_reinstallCustody_\(scenario.name)RestoresPriorBundle"
            )
            let stoppedRollbackEvents = processActions(fixture.processCalls)
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.processState.path)
                    && stoppedRollbackEvents.contains("open new")
                    && stoppedRollbackEvents.filter { $0.hasPrefix("pkill ") }.count == 1
                    && !stoppedRollbackEvents.contains("open old"),
                "test16_reinstallCustody_\(scenario.name)ReplacementStopTakesNoPriorCustody"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_reinstallCustody_\(scenario.name)ReplacementRollbackCleans"
            )
        }

        do {
            let fixture = try makeFixture("legacy-login-absence-ambiguous", priorVersion: "legacy")

            let result = try runInstaller(environment: fixture.environment)
            tests.expect(
                result.status != 0,
                "test16_legacyLaunchAgentAbsence_withoutExplicitStateFailsClosed"
            )
            tests.expect(
                result.stderr.contains(
                    "exact legacy LaunchAgent absence is ambiguous; "
                        + "set TICKER_INSTALL_LEGACY_LOGIN_STATE to disabled, "
                        + "system-settings, or requires-approval"
                ),
                "test16_legacyLaunchAgentAbsence_reportsExplicitStateContract"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "legacy",
                "test16_legacyLaunchAgentAbsence_failsBeforeBundleMutation"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_legacyLaunchAgentAbsence_isReadOnly"
            )
        }

        do {
            let fixture = try makeFixture("legacy-login-explicit-disabled", priorVersion: "legacy")
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "disabled"

            let result = try runInstaller(environment: environment)
            tests.expectEqual(result.status, 0, "test16_legacyExplicitDisabled_succeeds")
            tests.expect(
                result.stdout.contains("login item: captured prior state: disabled")
                    && result.stdout.contains("login item: preserved prior state: disabled"),
                "test16_legacyExplicitDisabled_isVerifiedAfterExchange"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_legacyExplicitDisabled_installsReplacement"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.loginState.path),
                "test16_legacyExplicitDisabled_preservesDisabledState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status"],
                "test16_legacyExplicitDisabled_performsNoLoginMutation"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-login-explicit-system-settings",
                priorVersion: "legacy"
            )
            try "enabled via System Settings login item\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "system-settings"

            let result = try runInstaller(environment: environment)
            tests.expectEqual(result.status, 0, "test16_legacyExplicitSystemSettings_succeeds")
            tests.expect(
                result.stdout.contains(
                    "login item: captured prior state: enabled via System Settings login item"
                )
                    && result.stdout.contains(
                        "login item: preserved prior state: enabled via System Settings login item"
                    ),
                "test16_legacyExplicitSystemSettings_isVerifiedAfterExchange"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "enabled via System Settings login item\n",
                "test16_legacyExplicitSystemSettings_preservesMechanism"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status"],
                "test16_legacyExplicitSystemSettings_performsNoLoginMutation"
            )
        }

        do {
            let fixture = try makeFixture(
                "fresh-login-requires-approval",
                priorVersion: nil
            )
            try "\(requiresApprovalLoginState)\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )

            let result = try runInstaller(environment: fixture.environment)
            tests.expect(
                result.status != 0,
                "test16_freshRequiresApproval_isRejected"
            )
            tests.expect(
                result.stderr.contains(
                    "a fresh install requires a disabled prior login item"
                ),
                "test16_freshRequiresApproval_reportsDisabledStateRequirement"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.installedBundle.path),
                "test16_freshRequiresApproval_precedesBundleMutation"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "\(requiresApprovalLoginState)\n",
                "test16_freshRequiresApproval_preservesObservedState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_freshRequiresApproval_performsReadOnlyInspection"
            )
        }

        do {
            let fixture = try makeFixture("modern-login-requires-approval")
            try "\(requiresApprovalLoginState)\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )

            let result = try runInstaller(environment: fixture.environment)
            tests.expectEqual(result.status, 0, "test16_modernRequiresApproval_succeeds")
            tests.expect(
                result.stdout.contains(
                    "login item: captured prior state: \(requiresApprovalLoginState)"
                )
                    && result.stdout.contains(
                        "login item: preserved prior state: \(requiresApprovalLoginState)"
                    )
                    && result.stdout.contains(
                        "login item: final preserved state: \(requiresApprovalLoginState)"
                    )
                    && result.stdout.contains(
                        "done. Approval remains required — approve Ticker in "
                            + "System Settings › General › Login Items."
                    ),
                "test16_modernRequiresApproval_reportsPreservedPendingStateTruthfully"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_modernRequiresApproval_installsReplacement"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "\(requiresApprovalLoginState)\n",
                "test16_modernRequiresApproval_preservesExactState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status"],
                "test16_modernRequiresApproval_performsReadOnlyCaptureAndVerification"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-login-explicit-requires-approval",
                priorVersion: "legacy"
            )
            try "\(requiresApprovalLoginState)\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "requires-approval"

            let result = try runInstaller(environment: environment)
            tests.expectEqual(result.status, 0, "test16_legacyRequiresApproval_succeeds")
            tests.expect(
                result.stdout.contains(
                    "login item: captured prior state: \(requiresApprovalLoginState)"
                )
                    && result.stdout.contains(
                        "login item: preserved prior state: \(requiresApprovalLoginState)"
                    )
                    && result.stdout.contains(
                        "login item: final preserved state: \(requiresApprovalLoginState)"
                    )
                    && result.stdout.contains("Approval remains required"),
                "test16_legacyRequiresApproval_isAttestedVerifiedAndReported"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_legacyRequiresApproval_installsReplacement"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "\(requiresApprovalLoginState)\n",
                "test16_legacyRequiresApproval_preservesExactState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status"],
                "test16_legacyRequiresApproval_performsNoLoginMutation"
            )
        }

        do {
            let fixture = try makeFixture("modern-requires-approval-late-transition")
            try "\(requiresApprovalLoginState)\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_TRANSITION_AFTER_OPEN_VERSION"] = "new"
            environment["TICKER_TEST_LOGIN_STATE_AFTER_OPEN"] =
                "enabled via System Settings login item"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_modernLateLoginTransitionFailsBeforeCommit"
            )
            tests.expect(
                result.stderr.contains(
                    "installed login state changed before commit: "
                        + "enabled via System Settings login item; "
                        + "expected \(requiresApprovalLoginState)"
                )
                    && result.stderr.contains(
                        "atomically exchanging the prior bundle back into place"
                    ),
                "test16_modernLateLoginTransitionIsDetectedAndRolledBack"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_modernLateLoginTransitionRestoresPriorBundle"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "enabled via System Settings login item\n",
                "test16_modernLateLoginTransitionDoesNotMutateObservedLoginState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status"],
                "test16_modernLateLoginTransitionUsesFinalReadWithoutLoginMutation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_modernLateLoginTransitionRestoresPriorCLIState"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_modernLateLoginTransitionCleansTransaction"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-requires-approval-late-transition",
                priorVersion: "legacy"
            )
            try "\(requiresApprovalLoginState)\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "requires-approval"
            environment["TICKER_TEST_LOGIN_TRANSITION_AFTER_OPEN_VERSION"] = "new"
            environment["TICKER_TEST_LOGIN_STATE_AFTER_OPEN"] =
                "enabled via System Settings login item"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_legacyLateLoginTransitionFailsBeforeCommit"
            )
            tests.expect(
                result.stderr.contains(
                    "installed login state changed before commit: "
                        + "enabled via System Settings login item; "
                        + "expected \(requiresApprovalLoginState)"
                )
                    && result.stderr.contains(
                        "atomically exchanging the prior bundle back into place"
                    ),
                "test16_legacyLateLoginTransitionIsDetectedAndRolledBack"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "legacy",
                "test16_legacyLateLoginTransitionRestoresAttestedBundle"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "enabled via System Settings login item\n",
                "test16_legacyLateLoginTransitionDoesNotMutateObservedLoginState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status"],
                "test16_legacyLateLoginTransitionUsesFinalReadWithoutLoginMutation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_legacyLateLoginTransitionRestoresPriorCLIState"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_legacyLateLoginTransitionCleansTransaction"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-login-requires-approval-mismatch",
                priorVersion: "legacy"
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "requires-approval"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_legacyRequiresApprovalMismatch_failsClosed"
            )
            tests.expect(
                result.stderr.contains(
                    "replacement changed the prior login state: disabled; "
                        + "expected \(requiresApprovalLoginState)"
                )
                    && result.stderr.contains(
                        "atomically exchanging the prior bundle back into place"
                    ),
                "test16_legacyRequiresApprovalMismatch_isDetectedAndRolledBack"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "legacy",
                "test16_legacyRequiresApprovalMismatch_restoresPriorBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_legacyRequiresApprovalMismatch_performsNoLoginMutation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_legacyRequiresApprovalMismatch_precedesCLIMutation"
            )
        }

        do {
            let fixture = try makeFixture("modern-requires-approval-later-failure")
            try "\(requiresApprovalLoginState)\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LINK"] = "/usr/bin/false"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_modernRequiresApprovalLaterFailure_reportsFailure"
            )
            tests.expect(
                result.stdout.contains(
                    "login item: preserved prior state: \(requiresApprovalLoginState)"
                )
                    && result.stderr.contains(
                        "atomically exchanging the prior bundle back into place"
                    ),
                "test16_modernRequiresApprovalLaterFailure_rollsBackAfterVerification"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_modernRequiresApprovalLaterFailure_restoresPriorBundle"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "\(requiresApprovalLoginState)\n",
                "test16_modernRequiresApprovalLaterFailure_preservesExactState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_modernRequiresApprovalLaterFailure_rollsBackWithoutLoginMutation"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-login-explicit-state-mismatch",
                priorVersion: "legacy"
            )
            let cliMutation = fixture.directory.appendingPathComponent("cli-mutation")
            let linkCommand = try writeCommand(
                """
                #!/bin/sh
                : > "${TICKER_TEST_CLI_MUTATION}"
                exit 99
                """,
                named: "record-cli-mutation.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "system-settings"
            environment["TICKER_INSTALL_LINK"] = linkCommand.path
            environment["TICKER_TEST_CLI_MUTATION"] = cliMutation.path

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_legacyExplicitStateMismatch_failsClosed"
            )
            tests.expect(
                result.stderr.contains(
                    "replacement changed the prior login state: disabled; "
                        + "expected enabled via System Settings login item"
                )
                    && result.stderr.contains(
                        "atomically exchanging the prior bundle back into place"
                    ),
                "test16_legacyExplicitStateMismatch_rollsBackBundleObservably"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "legacy",
                "test16_legacyExplicitStateMismatch_restoresPriorBundle"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: cliMutation.path)
                    && !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_legacyExplicitStateMismatch_precedesCLIMutation"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_legacyExplicitStateMismatch_performsNoLoginMutation"
            )
        }

        do {
            let fixture = try makeFixture("modern-login-explicit-state", priorVersion: "old")
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "disabled"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_modernHelper_rejectsExplicitLegacyState"
            )
            tests.expect(
                result.stderr.contains(
                    "TICKER_INSTALL_LEGACY_LOGIN_STATE is only valid for "
                        + "an unsupported legacy helper with no live exact LaunchAgent"
                ),
                "test16_modernHelper_reportsExplicitLegacyStateInapplicable"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_modernHelper_rejectsExplicitLegacyStateBeforeMutation"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_modernHelper_explicitLegacyStatePreservesBundle"
            )
        }

        do {
            let fixture = try makeFixture("legacy-login-invalid-explicit-state", priorVersion: "legacy")
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "enabled"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_legacyInvalidExplicitState_isRejected"
            )
            tests.expect(
                result.stderr.contains(
                    "TICKER_INSTALL_LEGACY_LOGIN_STATE must be disabled, "
                        + "system-settings, or requires-approval"
                ),
                "test16_legacyInvalidExplicitState_reportsAllowedValues"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                [],
                "test16_legacyInvalidExplicitState_failsBeforeLoginInspection"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-live-launch-agent-explicit-state",
                priorVersion: "legacy"
            )
            try "enabled via LaunchAgent\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            try "running\n".write(
                to: fixture.processState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "disabled"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_legacyLiveLaunchAgent_rejectsExplicitState"
            )
            tests.expect(
                result.stderr.contains(
                    "TICKER_INSTALL_LEGACY_LOGIN_STATE is not valid "
                        + "when the exact legacy LaunchAgent is live"
                ),
                "test16_legacyLiveLaunchAgent_reportsExplicitStateInapplicable"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_legacyLiveLaunchAgent_rejectsExplicitStateReadOnly"
            )
        }

        do {
            let fixture = try makeFixture("unrelated-login-helper-failure")
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_STATUS_FAIL_AT"] = "1"
            environment["TICKER_TEST_LOGIN_STATUS_FAILURE_MESSAGE"] =
                "ticker: Unknown command 'login-item'. Run 'ticker --help' for usage."
            environment["TICKER_TEST_LOGIN_STATUS_FAILURE_CODE"] = "1"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_loginCapture_unrelatedHelperFailureIsRejected"
            )
            tests.expect(
                result.stderr.contains(
                    "could not capture prior state (helper status 1): "
                        + "ticker: Unknown command 'login-item'. "
                        + "Run 'ticker --help' for usage."
                )
                    && !result.stdout.contains("prior helper lacks login-item"),
                "test16_loginCapture_requiresUnsupportedCommandExitStatus"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_loginCapture_unrelatedHelperFailurePreservesPriorBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_loginCapture_unrelatedHelperFailureDoesNotQueryFallback"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-login-indeterminate",
                priorVersion: "legacy"
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "disabled"
            environment["TICKER_TEST_LEGACY_LAUNCHCTL_RESULT"] = "indeterminate"

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_legacyLoginCapture_indeterminateFailsClosed")
            tests.expect(
                result.stderr.contains(
                    "legacy LaunchAgent query failed (launchctl status 5): permission denied"
                ),
                "test16_legacyLoginCapture_indeterminateRejectsExplicitState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_legacyLoginCapture_indeterminateIsReadOnly"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "legacy",
                "test16_legacyLoginCapture_indeterminatePreservesPriorBundle"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-login-malformed-plist",
                priorVersion: "legacy"
            )
            let plist = fixture.directory
                .appendingPathComponent("home/Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("com.suchintan.ticker.login.plist")
            try FileManager.default.createDirectory(
                at: plist.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("<?xml version=\"1.0\"?><plist><dict>".utf8).write(to: plist)
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "disabled"

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_legacyLoginCapture_malformedFailsClosed")
            tests.expect(
                result.stderr.contains("legacy LaunchAgent plist is malformed"),
                "test16_legacyLoginCapture_malformedRejectsExplicitState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_legacyLoginCapture_malformedIsReadOnly"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "legacy",
                "test16_legacyLoginCapture_malformedPreservesPriorBundle"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-login-live-target-mismatch",
                priorVersion: "legacy"
            )
            try "enabled via LaunchAgent\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "disabled"
            environment["TICKER_TEST_LOGIN_STATUS_FAIL_AT"] = "1"
            environment["TICKER_TEST_LOGIN_STATUS_FAILURE_MESSAGE"] =
                "failed: LaunchAgent verification did not report exact executable"

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_legacyLoginCapture_mismatchFailsClosed")
            tests.expect(
                result.stderr.contains(
                    "legacy live LaunchAgent validation failed: failed: "
                        + "LaunchAgent verification did not report exact executable"
                ),
                "test16_legacyLoginCapture_mismatchRejectsExplicitState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_legacyLoginCapture_mismatchIsReadOnly"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "legacy",
                "test16_legacyLoginCapture_mismatchPreservesPriorBundle"
            )
            tests.expect(
                !processActions(fixture.processCalls).contains { $0.hasPrefix("pkill ") },
                "test16_legacyLoginCapture_mismatchPrecedesAppMutation"
            )
        }

        do {
            let fixture = try makeFixture(
                "legacy-disabled-later-failure",
                priorVersion: "legacy"
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LEGACY_LOGIN_STATE"] = "disabled"
            environment["TICKER_INSTALL_LINK"] = "/usr/bin/false"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_legacyLaterFailure_reportsFailure"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "legacy",
                "test16_legacyLaterFailure_restoresPriorBundle"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.loginState.path),
                "test16_legacyLaterFailure_preservesDisabledState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_legacyLaterFailure_rollsBackWithZeroLoginMutation"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_legacyLaterFailure_cleansTransaction"
            )
        }

        do {
            let fixture = try makeFixture("atomic-exchange-unavailable")
            let exchangeCalls = fixture.directory.appendingPathComponent("exchange-calls.txt")
            let exchangeCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                printf 'attempted\n' >> "${TICKER_TEST_EXCHANGE_CALLS}"
                exit 76
                """,
                named: "unavailable-exchange.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_EXCHANGE"] = exchangeCommand.path
            environment["TICKER_TEST_EXCHANGE_CALLS"] = exchangeCalls.path

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_installer_unavailableAtomicExchangeIsReported"
            )
            tests.expect(
                result.stderr.contains("atomic exchange preflight failed"),
                "test16_installer_unavailableAtomicExchangeIsObservable"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_unavailableAtomicExchangePreservesPriorBundle"
            )
            tests.expect(
                !processActions(fixture.processCalls).contains { $0.hasPrefix("pkill ") },
                "test16_installer_unavailableAtomicExchangeFailsBeforeStoppingApp"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_installer_unavailableAtomicExchangeOnlyCapturesLoginState"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_unavailableAtomicExchangeCleansStaging"
            )
        }

        do {
            let fixture = try makeFixture("stubborn-running-app")
            try "running\n".write(
                to: fixture.processState,
                atomically: true,
                encoding: .utf8
            )
            let priorInode = try pathInode(fixture.installedBundle)
            var environment = fixture.environment
            environment["TICKER_TEST_STUBBORN_PROCESS"] = "1"

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_installer_stubbornProcessIsRejected")
            tests.expect(
                result.stderr.contains("was not proven stopped after 3 checks"),
                "test16_installer_stubbornProcessFailureIsClassified"
            )
            tests.expectEqual(
                try pathInode(fixture.installedBundle),
                priorInode,
                "test16_installer_stubbornProcessAbortsBeforeBundleMutation"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_stubbornProcessPreservesPriorBundle"
            )
            tests.expect(
                FileManager.default.fileExists(atPath: fixture.processState.path)
                    && processActions(fixture.processCalls).contains { $0.hasPrefix("pkill ") }
                    && !processActions(fixture.processCalls).contains { $0.hasPrefix("open ") },
                "test16_installer_stubbornProcessIsNeverTreatedAsStopped"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_installer_stubbornProcessDoesNotMutateLoginState"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_installer_stubbornProcessDoesNotMutateCLI"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_stubbornProcessCleansUnpublishedReplacement"
            )
        }

        do {
            let fixture = try makeFixture("unexpected-bundle-displaced-by-swap")
            let foreignBundle = fixture.directory.appendingPathComponent(
                "foreign/Ticker.app",
                isDirectory: true
            )
            let parkedPrior = fixture.directory.appendingPathComponent(
                "externally-parked-prior/Ticker.app",
                isDirectory: true
            )
            let injected = fixture.directory.appendingPathComponent("foreign-injected")
            try writeBundle(foreignBundle, version: "foreign")
            try FileManager.default.createDirectory(
                at: parkedPrior.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let exchangeCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$1" = "${TICKER_INSTALL_BUNDLE}" ] && [ ! -e "${TICKER_TEST_FOREIGN_INJECTED}" ]; then
                  : > "${TICKER_TEST_FOREIGN_INJECTED}"
                  /bin/mv "$1" "${TICKER_TEST_PARKED_PRIOR}"
                  mkdir -p "$1"
                  /bin/cp -R "${TICKER_TEST_FOREIGN_BUNDLE}/." "$1/"
                fi
                exec "${TICKER_INSTALL_NATIVE_EXCHANGE_HELPER}" "$@"
                """,
                named: "inject-foreign-before-swap.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_EXCHANGE"] = exchangeCommand.path
            environment["TICKER_TEST_FOREIGN_BUNDLE"] = foreignBundle.path
            environment["TICKER_TEST_FOREIGN_INJECTED"] = injected.path
            environment["TICKER_TEST_PARKED_PRIOR"] = parkedPrior.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_unexpectedSwapIdentityIsRejected")
            tests.expect(
                result.stderr.contains("atomically exchanging it back")
                    && result.stderr.contains("left untouched for manual recovery"),
                "test16_unexpectedSwapIdentityIsRestoredBeforeAbort"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "foreign",
                "test16_unexpectedSwapIdentityIsNeverStranded"
            )
            tests.expectEqual(
                installedVersion(parkedPrior),
                "old",
                "test16_unexpectedSwapPreservesExternallyMovedPriorBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_unexpectedSwapFailsBeforeLoginMutation"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_unexpectedSwapCleansOnlyOwnedReplacement"
            )
        }

        do {
            let fixture = try makeFixture("atomic-exchange-failure")
            let exchangeFailure = fixture.directory.appendingPathComponent("exchange-failed.txt")
            let exchangeCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$1" = "${TICKER_INSTALL_BUNDLE}" ] && [ ! -e "${TICKER_TEST_EXCHANGE_FAILURE}" ]; then
                  : > "${TICKER_TEST_EXCHANGE_FAILURE}"
                  exit 73
                fi
                exec "${TICKER_INSTALL_NATIVE_EXCHANGE_HELPER}" "$@"
                """,
                named: "fail-application-exchange.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_EXCHANGE"] = exchangeCommand.path
            environment["TICKER_TEST_EXCHANGE_FAILURE"] = exchangeFailure.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_installer_exchangeFailureIsReported")
            tests.expect(
                result.stderr.contains("atomic replacement exchange failed")
                    && result.stderr.contains("restored and verified prior bundle"),
                "test16_installer_exchangeFailureRestoresObservably"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_exchangeFailurePreservesPriorBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_installer_exchangeFailureDoesNotMutateLoginState"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_exchangeFailureCleansAfterVerifiedRestore"
            )
        }

        do {
            let fixture = try makeFixture("post-swap-verification-failure")
            let codesignCalls = fixture.directory.appendingPathComponent("codesign-calls.txt")
            let codesignCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                count=0
                if [ -f "${TICKER_TEST_CODESIGN_CALLS}" ]; then
                  count="$(cat "${TICKER_TEST_CODESIGN_CALLS}")"
                fi
                count=$((count + 1))
                printf '%s\n' "$count" > "${TICKER_TEST_CODESIGN_CALLS}"
                if [ "$count" -eq 2 ]; then
                  exit 74
                fi
                exit 0
                """,
                named: "fail-second-codesign.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_CODESIGN"] = codesignCommand.path
            environment["TICKER_TEST_CODESIGN_CALLS"] = codesignCalls.path

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_installer_postSwapVerificationFailureIsReported"
            )
            tests.expect(
                result.stderr.contains("installed replacement: ERROR - signature verification failed")
                    && result.stderr.contains("restored and verified prior bundle"),
                "test16_installer_postSwapVerificationFailureRestoresObservably"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_postSwapVerificationFailurePreservesPriorBundle"
            )
            tests.expectEqual(
                try String(contentsOf: codesignCalls, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                "3",
                "test16_installer_postSwapFailureVerifiesRestoredBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status"],
                "test16_installer_postSwapFailureOnlyCapturesLoginState"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_postSwapFailureCleansAfterVerifiedRestore"
            )
        }

        do {
            let fixture = try makeFixture("login-enable-failure", priorVersion: nil)
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_ENABLE_FAIL"] = "1"

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_freshInstall_loginEnableFailureIsReported")
            tests.expect(
                result.stderr.contains("login item: ERROR - enable failed")
                    && result.stderr.contains("login item: restored prior state: disabled"),
                "test16_freshInstall_loginEnableFailureRestoresObservably"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.installedBundle.path),
                "test16_freshInstall_loginEnableFailureRemovesFailedBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "enable", "disable", "status"],
                "test16_freshInstall_loginEnableFailureCompensatesAndVerifies"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_freshInstall_loginEnableFailureCleansTransaction"
            )
        }

        do {
            let fixture = try makeFixture("replacement-launch-failure-restores-running-old-app")
            try "running\n".write(
                to: fixture.processState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_TEST_OPEN_FAIL_VERSION"] = "new"

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_replacementLaunchFailureIsReported")
            tests.expect(
                result.stderr.contains("replacement launch command failed")
                    && result.stdout.contains("restored app launch verified"),
                "test16_replacementLaunchFailureIsClassifiedBeforeOldRelaunch"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_replacementLaunchFailureRestoresPriorBundle"
            )
            tests.expect(
                FileManager.default.fileExists(atPath: fixture.processState.path)
                    && processActions(fixture.processCalls).contains("open new")
                    && processActions(fixture.processCalls).contains("open old"),
                "test16_replacementLaunchFailureVerifiesOldAppRelaunch"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_replacementLaunchFailurePerformsNoLoginMutation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_replacementLaunchFailureRestoresCLIBeforeOldRelaunch"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_replacementLaunchFailureCleansAfterVerifiedOldRelaunch"
            )
        }

        do {
            let fixture = try makeFixture("restored-app-relaunch-verification-failure")
            try "running\n".write(
                to: fixture.processState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_TEST_OPEN_FAIL_VERSION"] = "new"
            environment["TICKER_TEST_OPEN_NO_START_VERSION"] = "old"

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_restoredAppRelaunchFailureIsReported")
            tests.expect(
                result.stderr.contains("restored app launch verification failed"),
                "test16_restoredAppRelaunchFailureIsClassified"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_restoredAppRelaunchFailureStillRestoresPriorBundle"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_restoredAppRelaunchFailurePerformsNoLoginMutation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.processState.path)
                    && processActions(fixture.processCalls).contains("open old"),
                "test16_restoredAppRelaunchFailureIsProvenNotRunning"
            )
            tests.expect(
                transactionArtifacts(for: fixture.installedBundle).contains {
                    $0.hasPrefix("Ticker.app.staging.")
                },
                "test16_restoredAppRelaunchFailureRetainsTransactionArtifact"
            )
        }

        do {
            let fixture = try makeFixture("fresh-login-status-failure", priorVersion: nil)
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_STATUS_FAIL_AT"] = "2"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_freshInstall_enableThenStatusFailureIsReported"
            )
            tests.expect(
                result.stderr.contains("login item: ERROR - live-state verification failed")
                    && result.stderr.contains("login item: restored prior state: disabled"),
                "test16_freshInstall_enableThenStatusFailureCompensatesObservably"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.installedBundle.path),
                "test16_freshInstall_enableThenStatusFailureRemovesFailedAppAfterDisable"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.loginState.path),
                "test16_freshInstall_enableThenStatusFailureEndsDisabled"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "enable", "status", "disable", "status"],
                "test16_freshInstall_enableThenStatusFailureVerifiesCompensation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_freshInstall_enableThenStatusFailureDoesNotCreateCLILink"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_freshInstall_enableThenStatusFailureCleansTransaction"
            )
        }

        let rollbackSignalCases: [
            (name: String, status: Int32, cleanupSignal: String)
        ] = [
            ("HUP", 129, "QUIT"),
            ("QUIT", 131, "HUP"),
            ("TERM", 143, "QUIT"),
        ]
        for signalCase in rollbackSignalCases {
            let fixture = try makeFixture(
                "signal-\(signalCase.name.lowercased())-during-transaction-rollback",
                priorVersion: nil
            )
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_SIGNAL_AFTER_ENABLE"] = signalCase.name
            environment["TICKER_TEST_LOGIN_SIGNAL_DURING_DISABLE"] =
                signalCase.cleanupSignal

            let result = try runInstaller(environment: environment)
            tests.expectEqual(
                result.status,
                signalCase.status,
                "test16_installer_\(signalCase.name)_duringTransactionReturnsSignalStatus"
            )
            tests.expect(
                result.stderr.contains("received \(signalCase.name)")
                    && result.stderr.contains("login item: restored prior state: disabled"),
                "test16_installer_\(signalCase.name)_usesFreshLoginCompensation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.installedBundle.path),
                "test16_installer_\(signalCase.name)_removesFailedFreshBundle"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.loginState.path),
                "test16_installer_\(signalCase.name)_restoresDisabledLoginState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "enable", "disable", "status"],
                "test16_installer_\(signalCase.name)_suppressesCleanupSignalAndVerifiesCompensation"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_\(signalCase.name)_cleansTransactionAndPublicLock"
            )
            let rollbackRecords = releasedCustodyRecords(for: fixture.installedBundle)
            tests.expectEqual(
                rollbackRecords.count,
                1,
                "test16_installer_\(signalCase.name)_rollbackRetainsOneCustodyRecord"
            )
            tests.expect(
                rollbackRecords.allSatisfy(releasedCustodyRecordIsProven),
                "test16_installer_\(signalCase.name)_rollbackCustodyIsProvenReleased"
            )

            let retry = try runInstaller(environment: fixture.environment)
            tests.expectEqual(
                retry.status,
                0,
                "test16_installer_\(signalCase.name)_rollbackAllowsCleanRetry"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_installer_\(signalCase.name)_rollbackRetryCommitsReplacement"
            )
            tests.expectEqual(
                releasedCustodyRecords(for: fixture.installedBundle).count,
                2,
                "test16_installer_\(signalCase.name)_rollbackBoundsOneRecordPerRun"
            )
        }

        do {
            let fixture = try makeFixture("disabled-reinstall-login-status-failure")
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_STATUS_FAIL_AT"] = "2"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_disabledReinstall_verificationFailureIsReported"
            )
            tests.expect(
                result.stderr.contains("login item: ERROR - reinstall state verification failed"),
                "test16_disabledReinstall_verificationFailureIsObservable"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_disabledReinstall_verificationFailureRestoresPriorBundle"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.loginState.path),
                "test16_disabledReinstall_verificationFailurePreservesState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_disabledReinstall_verificationFailurePerformsNoLoginMutation"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_disabledReinstall_verificationFailureCleansTransaction"
            )
        }

        do {
            let fixture = try makeFixture("enabled-reinstall-login-status-failure")
            try "enabled via System Settings login item\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_STATUS_FAIL_AT"] = "2"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_enabledReinstall_verificationFailureIsReported"
            )
            tests.expect(
                result.stderr.contains("login item: ERROR - reinstall state verification failed"),
                "test16_enabledReinstall_verificationFailureIsObservable"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_enabledReinstall_verificationFailureRestoresPriorBundle"
            )
            tests.expectEqual(
                try String(contentsOf: fixture.loginState, encoding: .utf8),
                "enabled via System Settings login item\n",
                "test16_enabledReinstall_verificationFailurePreservesMechanism"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_enabledReinstall_verificationFailurePerformsNoLoginMutation"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_enabledReinstall_verificationFailureCleansTransaction"
            )
        }

        do {
            let fixture = try makeFixture("cli-link-failure")
            let linkCommand = try writeCommand(
                "#!/bin/sh\nprintf 'injected link failure\\n' >&2\nexit 77\n",
                named: "fail-link.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_LINK"] = linkCommand.path

            let result = try runInstaller(environment: environment)
            tests.expect(result.status != 0, "test16_installer_cliLinkFailureIsReported")
            tests.expect(
                result.stderr.contains("cli: ERROR - could not create staged CLI link")
                    && result.stderr.contains("restored and verified prior bundle"),
                "test16_installer_cliLinkFailureRollsBackObservably"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_cliLinkFailureRestoresPriorBundle"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.loginState.path),
                "test16_installer_cliLinkFailureRestoresDisabledLoginState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_installer_cliLinkFailurePerformsNoLoginMutation"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.cliLink.path),
                "test16_installer_cliLinkFailureLeavesPriorAbsentCLIPath"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_cliLinkFailureCleansTransaction"
            )
        }

        do {
            let fixture = try makeFixture("prior-cli-link-restoration")
            let priorTarget = fixture.directory.appendingPathComponent("prior-cli-target")
            try writeExecutable("#!/bin/sh\nexit 0\n", to: priorTarget)
            try FileManager.default.createSymbolicLink(
                at: fixture.cliLink,
                withDestinationURL: priorTarget
            )
            let priorLinkInode = try pathInode(fixture.cliLink)
            let readlinkCalls = fixture.directory.appendingPathComponent("readlink-calls.txt")
            let readlinkCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                count=0
                if [ -f "${TICKER_TEST_READLINK_CALLS}" ]; then
                  count="$(cat "${TICKER_TEST_READLINK_CALLS}")"
                fi
                count=$((count + 1))
                printf '%s\n' "$count" > "${TICKER_TEST_READLINK_CALLS}"
                if [ "$count" -eq 2 ]; then
                  printf '%s\n' '/injected/wrong-target'
                  exit 0
                fi
                exec /usr/bin/readlink "$@"
                """,
                named: "fail-installed-link-verification.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_READLINK"] = readlinkCommand.path
            environment["TICKER_TEST_READLINK_CALLS"] = readlinkCalls.path

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_installer_postLinkVerificationFailureIsReported"
            )
            tests.expect(
                result.stderr.contains("cli: ERROR - installed CLI link targets")
                    && result.stderr.contains("cli: restored prior path state"),
                "test16_installer_postLinkVerificationFailureRestoresCLIObservably"
            )
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "old",
                "test16_installer_postLinkVerificationFailureRestoresPriorBundle"
            )
            tests.expectEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: fixture.cliLink.path),
                priorTarget.path,
                "test16_installer_postLinkVerificationFailureRestoresPriorLink"
            )
            tests.expectEqual(
                try pathInode(fixture.cliLink),
                priorLinkInode,
                "test16_installer_postLinkVerificationFailureRestoresPriorLinkIdentity"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status"],
                "test16_installer_postLinkVerificationFailurePerformsNoLoginMutation"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_installer_postLinkVerificationFailureCleansTransaction"
            )
        }

        do {
            let fixture = try makeFixture("fresh-install", priorVersion: nil)
            let result = try runInstaller(environment: fixture.environment)

            tests.expectEqual(result.status, 0, "test16_freshInstall_succeedsTransactionally")
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_freshInstall_installsVerifiedReplacement"
            )
            tests.expect(
                result.stdout.contains("staged replacement verified")
                    && result.stdout.contains("installed replacement verified")
                    && result.stdout.contains("login item: enabled via LaunchAgent")
                    && result.stdout.contains(
                        "login item: final installed state: enabled via LaunchAgent"
                    )
                    && result.stdout.contains("Ticker will open automatically at login"),
                "test16_freshInstall_reportsAllVerifiedStates"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "enable", "status", "status"],
                "test16_freshInstall_enablesAndReadsBackFinalLoginState"
            )
            tests.expectEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: fixture.cliLink.path),
                fixture.installedBundle.appendingPathComponent("Contents/Helpers/ticker").path,
                "test16_freshInstall_linksInstalledHelper"
            )
            tests.expect(
                FileManager.default.fileExists(atPath: fixture.processState.path)
                    && processActions(fixture.processCalls).contains("open new"),
                "test16_freshInstall_launchesAndVerifiesNewApp"
            )
            let freshEvents = processActions(fixture.processCalls)
            let freshLoginStatuses = freshEvents.indices.filter {
                freshEvents[$0] == "login status"
            }
            let freshLinkIndex = freshEvents.firstIndex { $0.hasPrefix("link ") }
            let freshOpenIndex = freshEvents.firstIndex(of: "open new")
            if freshLoginStatuses.count == 3,
               let freshLinkIndex,
               let freshOpenIndex {
                tests.expect(
                    freshLoginStatuses[1] < freshLinkIndex
                        && freshLinkIndex < freshOpenIndex
                        && freshOpenIndex > freshEvents.startIndex
                        && freshEvents[freshOpenIndex - 1].hasPrefix("pgrep new ")
                        && freshOpenIndex < freshLoginStatuses[2],
                    "test16_freshInstall_startsOnlyAfterPostExchangeAbsenceProof"
                )
            } else {
                tests.expect(
                    false,
                    "test16_freshInstall_recordsCompleteFinalReadOrdering"
                )
            }
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_freshInstall_leavesNoTransactionArtifacts"
            )
        }

        do {
            let fixture = try makeFixture(
                "fresh-post-launch-login-transition",
                priorVersion: nil
            )
            var environment = fixture.environment
            environment["TICKER_TEST_LOGIN_TRANSITION_AFTER_OPEN_VERSION"] = "new"
            environment["TICKER_TEST_LOGIN_STATE_AFTER_OPEN"] =
                "enabled via System Settings login item"

            let result = try runInstaller(environment: environment)
            tests.expect(
                result.status != 0,
                "test16_freshPostLaunchTransition_failsBeforeCommit"
            )
            tests.expect(
                result.stderr.contains(
                    "installed login state changed before commit: "
                        + "enabled via System Settings login item; "
                        + "expected enabled via LaunchAgent"
                )
                    && result.stderr.contains("installer: rolling back incomplete install")
                    && result.stderr.contains("login item: restored prior state: disabled"),
                "test16_freshPostLaunchTransition_isDetectedAndCompensated"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: fixture.installedBundle.path)
                    && !FileManager.default.fileExists(atPath: fixture.cliLink.path)
                    && !FileManager.default.fileExists(atPath: fixture.loginState.path)
                    && !FileManager.default.fileExists(atPath: fixture.processState.path),
                "test16_freshPostLaunchTransition_restoresFreshPreinstallState"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "enable", "status", "status", "disable", "status"],
                "test16_freshPostLaunchTransition_usesFinalReadThenVerifiedRollback"
            )
            let transitionEvents = processActions(fixture.processCalls)
            let transitionStatuses = transitionEvents.indices.filter {
                transitionEvents[$0] == "login status"
            }
            let transitionLinkIndex = transitionEvents.firstIndex {
                $0.hasPrefix("link ")
            }
            let transitionOpenIndex = transitionEvents.firstIndex(of: "open new")
            tests.expect(
                transitionStatuses.count == 4
                    && transitionLinkIndex != nil
                    && transitionOpenIndex != nil
                    && transitionLinkIndex! < transitionOpenIndex!
                    && transitionOpenIndex! < transitionStatuses[2],
                "test16_freshPostLaunchTransition_readsChangedStateAfterPublicationAndLaunch"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_freshPostLaunchTransition_cleansAfterVerifiedRollback"
            )
        }

        do {
            let fixture = try makeFixture("successful-reinstall")
            try "running\n".write(
                to: fixture.processState,
                atomically: true,
                encoding: .utf8
            )
            try "enabled via System Settings login item\n".write(
                to: fixture.loginState,
                atomically: true,
                encoding: .utf8
            )
            let probeReady = fixture.directory.appendingPathComponent("probe-ready")
            let probeStop = fixture.directory.appendingPathComponent("probe-stop")
            let probeFailure = fixture.directory.appendingPathComponent("probe-failure.txt")
            let probeSamples = fixture.directory.appendingPathComponent("probe-samples.txt")
            let exchangeCommand = try writeCommand(
                """
                #!/bin/sh
                set -eu
                if [ "$1" = "${TICKER_INSTALL_BUNDLE}" ]; then
                  while [ ! -e "${TICKER_TEST_PROBE_READY}" ]; do
                    /bin/sleep 0.001
                  done
                  /bin/sleep 0.05
                fi
                exec "${TICKER_INSTALL_NATIVE_EXCHANGE_HELPER}" "$@"
                """,
                named: "observable-exchange.sh",
                in: fixture.directory
            )
            var environment = fixture.environment
            environment["TICKER_INSTALL_EXCHANGE"] = exchangeCommand.path
            environment["TICKER_TEST_PROBE_READY"] = probeReady.path

            let probe = try startInstalledHelperProbe(
                bundle: fixture.installedBundle,
                ready: probeReady,
                stop: probeStop,
                failure: probeFailure,
                samples: probeSamples
            )
            defer {
                if probe.isRunning {
                    try? Data().write(to: probeStop)
                    probe.terminate()
                    probe.waitUntilExit()
                }
            }
            let result = try runInstaller(environment: environment)
            try Data().write(to: probeStop)
            probe.waitUntilExit()

            tests.expectEqual(result.status, 0, "test16_reinstall_succeedsTransactionally")
            tests.expectEqual(
                installedVersion(fixture.installedBundle),
                "new",
                "test16_reinstall_replacesPriorBundleAfterValidation"
            )
            tests.expect(
                result.stdout.contains(
                    "login item: preserved prior state: enabled via System Settings login item"
                ),
                "test16_reinstall_verifiesExistingMechanismWithoutMutation"
            )
            tests.expectEqual(
                loginActions(fixture.loginCalls),
                ["status", "status", "status"],
                "test16_reinstall_readsStateBeforeAndAfterExchange"
            )
            tests.expect(
                processActions(fixture.processCalls).contains { $0.hasPrefix("pkill ") }
                    && processActions(fixture.processCalls).contains("open new")
                    && FileManager.default.fileExists(atPath: fixture.processState.path),
                "test16_reinstall_stopsOldAppAndVerifiesReplacementRelaunch"
            )
            tests.expect(
                !FileManager.default.fileExists(atPath: probeFailure.path),
                "test16_reinstall_atomicExchangeNeverMakesInstalledHelperUnavailable"
            )
            let sampleCount = Int(
                ((try? String(contentsOf: probeSamples, encoding: .utf8)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 0
            tests.expect(
                sampleCount > 10,
                "test16_reinstall_atomicExchangeIsObservedByHighFrequencyProbe"
            )
            tests.expectEqual(
                transactionArtifacts(for: fixture.installedBundle),
                [],
                "test16_reinstall_removesBackupOnlyAfterSuccess"
            )
        }
    }
}

private func test17_AttentionNotificationPlanner(_ tests: TestHarness) {
    let jobA = "launchd:job-a#111111111111"
    let failureID = AttentionIncidentID(jobID: jobA, kind: .failedRun)
    let lateID = AttentionIncidentID(jobID: jobA, kind: .lateRun)
    let firstFailure = AttentionNotificationCandidate(
        incidentID: failureID,
        jobLabel: "job-a",
        reason: "The scheduled run exited with code 1."
    )
    let duplicateIncident = AttentionNotificationCandidate(
        incidentID: failureID,
        jobLabel: "duplicate-label",
        reason: "Duplicate discovery must not create a second notification."
    )

    func launchdObservationJob(
        managed: Bool,
        lastKnownExit: ExitStatus?
    ) -> Job {
        Job(
            id: "launchd:observation-\(managed)#333333333333",
            source: .launchd,
            provenance: .yours,
            label: "observation",
            schedule: .onDemand,
            command: ["/usr/bin/true"],
            cwd: nil,
            enabled: true,
            runtimeStatusAttribution: .resolved,
            configPath: nil,
            lastKnownExit: lastKnownExit,
            lastRunAt: nil,
            lastScheduledFor: nil,
            managed: managed
        )
    }
    tests.expect(
        AttentionIncidentObservationPolicy.failedRunIsAuthoritative(
            for: launchdObservationJob(
                managed: false,
                lastKnownExit: ExitStatus(raw: 0)
            ),
            hasScheduledHealthSnapshot: false
        ),
        "test17_unmanagedLaunchdNativeStatusRemainsAuthoritativeWithoutDatabase"
    )
    tests.expect(
        !AttentionIncidentObservationPolicy.failedRunIsAuthoritative(
            for: launchdObservationJob(
                managed: true,
                lastKnownExit: ExitStatus(raw: 0)
            ),
            hasScheduledHealthSnapshot: false
        ),
        "test17_managedLaunchdStatusNeedsDatabaseEvidence"
    )
    tests.expect(
        !AttentionIncidentObservationPolicy.failedRunIsAuthoritative(
            for: launchdObservationJob(managed: false, lastKnownExit: nil),
            hasScheduledHealthSnapshot: false
        ),
        "test17_missingNativeAndDatabaseStatusIsNotAuthoritative"
    )

    let initial = AttentionNotificationPlanner.plan(
        candidates: [firstFailure, duplicateIncident],
        notifiedIncidentIDs: [],
        pendingIncidentIDs: [],
        observedIncidentIDs: [failureID]
    )
    tests.expectEqual(
        initial.notifications,
        [firstFailure],
        "test17_newIncidentProducesOneNotification"
    )

    let unchanged = AttentionNotificationPlanner.plan(
        candidates: [firstFailure],
        notifiedIncidentIDs: [failureID],
        pendingIncidentIDs: [],
        observedIncidentIDs: [failureID]
    )
    tests.expectEqual(
        unchanged.notifications,
        [],
        "test17_sameActiveIncidentDoesNotRepeat"
    )
    tests.expectEqual(
        unchanged.retainedNotifiedIncidentIDs,
        [failureID],
        "test17_activeIncidentRetainsNotificationState"
    )

    let missingFromPartialDiscovery = AttentionNotificationPlanner.plan(
        candidates: [],
        notifiedIncidentIDs: [failureID],
        pendingIncidentIDs: [],
        observedIncidentIDs: []
    )
    tests.expectEqual(
        missingFromPartialDiscovery.retainedNotifiedIncidentIDs,
        [failureID],
        "test17_unobservedIncidentCannotBeDeclaredRecovered"
    )

    let wrapperID = AttentionIncidentID(
        jobID: "launchd:job-b#222222222222",
        kind: .wrapperRecovery
    )
    let wrapperError = AttentionNotificationCandidate(
        incidentID: wrapperID,
        jobLabel: "job-b",
        reason: "Ticker could not verify the wrapper."
    )
    let partialDiscovery = AttentionNotificationPlanner.plan(
        candidates: [wrapperError],
        notifiedIncidentIDs: [failureID],
        pendingIncidentIDs: [],
        observedIncidentIDs: [wrapperID]
    )
    tests.expectEqual(
        partialDiscovery.notifications,
        [wrapperError],
        "test17_partialDiscoveryDeliversObservedIncident"
    )
    tests.expectEqual(
        partialDiscovery.retainedNotifiedIncidentIDs,
        [failureID],
        "test17_partialDiscoveryPreservesUnobservedIncident"
    )

    let late = AttentionNotificationCandidate(
        incidentID: lateID,
        jobLabel: "job-a",
        reason: "The same job is now late."
    )
    let newKind = AttentionNotificationPlanner.plan(
        candidates: [firstFailure, late],
        notifiedIncidentIDs: [failureID],
        pendingIncidentIDs: [],
        observedIncidentIDs: [failureID, lateID]
    )
    tests.expectEqual(
        newKind.notifications,
        [late],
        "test17_newIncidentKindNotifiesWhileFailureRemainsActive"
    )

    let failureRecovered = AttentionNotificationPlanner.plan(
        candidates: [late],
        notifiedIncidentIDs: [failureID, lateID],
        pendingIncidentIDs: [],
        observedIncidentIDs: [failureID, lateID]
    )
    tests.expectEqual(
        failureRecovered.retainedNotifiedIncidentIDs,
        [lateID],
        "test17_observedIncidentRecoveryClearsOnlyThatKind"
    )

    let fullyRecovered = AttentionNotificationPlanner.plan(
        candidates: [],
        notifiedIncidentIDs: [lateID],
        pendingIncidentIDs: [],
        observedIncidentIDs: [lateID]
    )
    let afterRecovery = AttentionNotificationPlanner.plan(
        candidates: [firstFailure],
        notifiedIncidentIDs: fullyRecovered.retainedNotifiedIncidentIDs,
        pendingIncidentIDs: [],
        observedIncidentIDs: [failureID]
    )
    tests.expectEqual(
        afterRecovery.notifications,
        [firstFailure],
        "test17_incidentAfterRecoveryNotifiesAgain"
    )

    let skipID = AttentionIncidentID(jobID: jobA, kind: .skipStorm)
    let skip = AttentionNotificationCandidate(
        incidentID: skipID,
        jobLabel: "job-a",
        reason: "12 scheduler skips"
    )
    let skipPlan = AttentionNotificationPlanner.plan(
        candidates: [skip],
        notifiedIncidentIDs: [],
        pendingIncidentIDs: [],
        observedIncidentIDs: [skipID]
    )
    tests.expectEqual(
        skipPlan.notifications,
        [skip],
        "test17_skipStormProducesNotification"
    )

    let unreadableSkipSource = AttentionNotificationPlanner.plan(
        candidates: [],
        notifiedIncidentIDs: [skipID],
        pendingIncidentIDs: [],
        observedIncidentIDs: [failureID]
    )
    tests.expectEqual(
        unreadableSkipSource.retainedNotifiedIncidentIDs,
        [skipID],
        "test17_unobservedSkipIncidentCannotBeDeclaredRecovered"
    )

    let pending = AttentionNotificationPlanner.plan(
        candidates: [firstFailure],
        notifiedIncidentIDs: [],
        pendingIncidentIDs: [failureID],
        observedIncidentIDs: [failureID]
    )
    tests.expectEqual(
        pending.notifications,
        [],
        "test17_pendingNotificationDoesNotDuplicate"
    )
}

@main
private enum TickerTests {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--test9-crash-after-exchange" {
            test9_crashAfterFirstExchange(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        if ProcessInfo.processInfo.environment["TICKER_TEST13_UI_ONLY"] == "1" {
            let tests = TestHarness()
            tests.run("round 13 provenance-first UI architecture") {
                try test13_UIArchitectureContract(tests)
            }
            tests.finish()
        }
        if ProcessInfo.processInfo.environment["TICKER_TEST13_ONLY"] == "1" {
            let tests = TestHarness()
            tests.run("round 13 provenance classification and cache") {
                try test13_ProvenanceClassificationAndCaching(tests)
            }
            tests.run("round 13 CLI missing payload") {
                try test13_CLISurfacesMissingPayload(tests)
            }
            tests.run("round 13 provenance-first UI architecture") {
                try test13_UIArchitectureContract(tests)
            }
            tests.finish()
        }
        if ProcessInfo.processInfo.environment["TICKER_TEST14_ONLY"] == "1" {
            let tests = TestHarness()
            tests.run("round 14 provenance failure direction") {
                try test14_ProvenanceFailsTowardVisibility(tests)
            }
            tests.run("round 14 launchd forms and diagnostics") {
                try test14_LaunchdFormsAndDiagnostics(tests)
            }
            tests.run("round 14 UI safety contract") {
                try test14_UISafetyContract(tests)
            }
            tests.finish()
        }
        if ProcessInfo.processInfo.environment["TICKER_TEST15_ONLY"] == "1" {
            let tests = TestHarness()
            tests.run("round 15 configuration states and filename provenance") {
                try test15_ConfigurationStatesAndFilenameProvenance(tests)
            }
            tests.run("round 15 informational state presentation") {
                try test15_InformationalStatePresentationContract(tests)
            }
            tests.finish()
        }
        if ProcessInfo.processInfo.environment["TICKER_TEST17_ONLY"] == "1" {
            let tests = TestHarness()
            tests.run("round 17 failure notification transitions") {
                test17_AttentionNotificationPlanner(tests)
            }
            tests.run("round 17 skip observation completeness") {
                try testClaudeAdapter(tests)
            }
            tests.run("round 17 notification app integration") {
                try test4B_AppExecutionAndPresentation(tests)
            }
            tests.finish()
        }
        let tests = TestHarness()
        tests.run("round 13 provenance classification and cache") {
            try test13_ProvenanceClassificationAndCaching(tests)
        }
        tests.run("round 13 CLI missing payload") {
            try test13_CLISurfacesMissingPayload(tests)
        }
        tests.run("round 14 provenance failure direction") {
            try test14_ProvenanceFailsTowardVisibility(tests)
        }
        tests.run("round 14 launchd forms and diagnostics") {
            try test14_LaunchdFormsAndDiagnostics(tests)
        }
        tests.run("round 15 configuration states and filename provenance") {
            try test15_ConfigurationStatesAndFilenameProvenance(tests)
        }
        tests.run("ExitStatus tests") { testExitStatus(tests) }
        tests.run("cron and schedule tests") { try testCronAndSchedules(tests) }
        tests.run("launchd adapter tests") { try testLaunchdAdapter(tests) }
        tests.run("launchd wrapper decoder tests") { try testLaunchdWrapperDecode(tests) }
        tests.run("crontab adapter tests") { try testCrontabAdapter(tests) }
        tests.run("Claude routine adapter tests") { try testClaudeAdapter(tests) }
        tests.run("SQLite store tests") { try testStore(tests) }
        tests.run("JobWrapper tests") { try testJobWrapper(tests) }
        tests.run("round 2A Program key wrapping") { try test2A_ProgramKeyWrapping(tests) }
        tests.run("round 2A wrapper path migration") { try test2A_WrapperPathMigration(tests) }
        tests.run("round 2A durable backup ordering") { try test2A_DurableBackupPrecedesRewrite(tests) }
        tests.run("round 2A SQLite text round-trip") { try test2A_SQLiteTextRoundTrip(tests) }
        tests.run("round 3A CLI behavior") { try test3A_CLIHardening(tests) }
        tests.run("round 3A missing-backup repair") { try test3A_MissingBackupRepair(tests) }
        tests.run("round 3A manual-restore reconciliation") { try test3A_ManualRestoreStaleRow(tests) }
        tests.run("round 3A foreign-wrapper reconciliation") { try test3A_ForeignWrapperLabel(tests) }
        tests.run("round 3A duplicate-label recovery") {
            try test3A_DuplicateLabelRecoveryIsolation(tests)
        }
        tests.run("round 2B launchd trigger and environment") {
            try test2B_LaunchdAutomaticTriggersAndEnvironment(tests)
        }
        tests.run("round 2B crontab execution context") { try test2B_CrontabExecutionContext(tests) }
        tests.run("round 2B Claude Run Now disablement") { try test2B_ClaudeRunNowDisabled(tests) }
        tests.run("round 2B Claude snapshot ordering") { try test2B_ClaudeSnapshotOrdering(tests) }
        tests.run("round 2B Claude skip deduplication") { try test2B_ClaudeSkipDeduplication(tests) }
        tests.run("round 3B crontab scheduler environment") {
            try test3B_CrontabSchedulerEnvironment(tests)
        }
        tests.run("round 3B Claude account-scoped ids") {
            try test3B_ClaudeAccountScopedIDs(tests)
        }
        tests.run("round 4B launchd identity, argv0, and ambiguity") {
            try test4B_LaunchdIdentityExecutionAndAmbiguity(tests)
        }
        tests.run("round 4B Claude topology-independent ids") {
            try test4B_ClaudeTopologyIndependentIdentity(tests)
        }
        tests.run("round 4B app execution and presentation") {
            try test4B_AppExecutionAndPresentation(tests)
        }
        tests.run("round 4A backup authenticity") { try test4A_BackupAuthenticity(tests) }
        tests.run("round 4A blocked-parent capture") { try test4A_BlockedParentCapture(tests) }
        tests.run("round 4A signal/reap stress") { try test4A_SignalReapingStress(tests) }
        tests.run("round 5 health precedence and manual isolation") {
            try test5_HealthPrecedenceAndManualIsolation(tests)
        }
        tests.run("round 8 wrapped health ordering") {
            try test8_WrappedHealthOrdering(tests)
        }
        tests.run("round 8 launchd runtime ordering evidence") {
            try test8_LaunchdRuntimeOrderingEvidence(tests)
        }
        tests.run("round 5 unwrap health reset") {
            try test5_UnwrapResetsHealthWithoutDeletingHistory(tests)
        }
        tests.run("round 5 trigger schema migration") {
            try test5_RunTriggerSchemaMigration(tests)
        }
        tests.run("round 8 concurrent trigger migration") {
            try test8_ConcurrentTriggerMigration(tests)
        }
        tests.run("round 8 already-triggered legacy migration") {
            try test8_AlreadyTriggeredRowsAreExcludedFromHealth(tests)
        }
        tests.run("round 8 wrapper store path policy") {
            test8_StorePathPolicy(tests)
        }
        tests.run("round 5 crontab context and identity") {
            try test5_CrontabContextAndIdentity(tests)
        }
        tests.run("round 5 registry id invariant") {
            test5_RegistryEnforcesUniqueIDs(tests)
        }
        tests.run("round 5 launchd domain, identity, and status") {
            try test5_LaunchdDomainIdentityAndStatus(tests)
        }
        tests.run("round 6 launchd duplicate status is domain-scoped") {
            try test6_LaunchdDuplicateStatusIsDomainScoped(tests)
        }
        tests.run("round 6 launchd runtime status explanations") {
            try test6_LaunchdRuntimeStatusExplanations(tests)
        }
        tests.run("round 7 unwrap preserves schedule edits") {
            try test7_UnwrapPreservesStartInterval(tests)
        }
        tests.run("round 7 unwrap preserves environment edits") {
            try test7_UnwrapPreservesEnvironmentVariables(tests)
        }
        tests.run("round 7 unwrap command conflict") {
            try test7_UnwrapRejectsOwnedKeyConflict(tests)
        }
        tests.run("round 7 wrap TOCTOU") {
            try test7_WrapRejectsConcurrentSourceChange(tests)
        }
        tests.run("round 7 file metadata") {
            try test7_WrapAndUnwrapPreserveFileMetadata(tests)
        }
        tests.run("round 7 system-daemon wrap gate") {
            try test7_SystemDaemonWrapIsRejected(tests)
        }
        tests.run("round 7 manual crontab context") {
            try test7_ManualCrontabRunUsesDiscoveredContext(tests)
        }
        tests.run("round 9 run liveness and native ordering") { try test9_RunLivenessAndNativeOrdering(tests) }
        tests.run("round 9 persistent identity aliases") { try test9_PersistentIdentityAliases(tests) }
        tests.run("round 9 copied wrapper runtime ownership") { try test9_CopiedWrapperRuntimeOwnership(tests) }
        tests.run("round 9 metadata-only concurrent change") { try test9_MetadataOnlyConcurrentChange(tests) }
        tests.run("round 9 interrupted exchange recovery") { try test9_InterruptedExchangeRecovery(tests) }
        tests.run("round 10 legacy wrapper removal") { try test10_LegacyWrapperRemoval(tests) }
        tests.run("round 10 concurrent evidence migration") { try test10_ConcurrentEvidenceMigration(tests) }
        tests.run("round 10 explicit singular identity reconciliation") { try test10_ExplicitSingularIdentityReconciliation(tests) }
        tests.run("round 10 runtime ownership and diagnostics") { try test10_RuntimeOwnershipAndDiagnostics(tests) }
        tests.run("round 11 active recorder diagnostics") {
            try test11_RecorderDiagnosticsAreCurrentAndBounded(tests)
        }
        tests.run("round 11 ambiguous wrapper explanation") {
            try test11_AmbiguousWrapperExplanationMatchesCause(tests)
        }
        tests.run("round 12 built bundle packaging") {
            try test12_BuiltBundlePackaging(tests)
        }
        tests.run("round 13 provenance-first UI architecture") {
            try test13_UIArchitectureContract(tests)
        }
        tests.run("round 14 UI safety contract") {
            try test14_UISafetyContract(tests)
        }
        tests.run("round 15 informational state presentation") {
            try test15_InformationalStatePresentationContract(tests)
        }
        tests.run("round 16 login at boot and fallback verification") {
            try test16_LoginAtBootAndFallbackVerification(tests)
        }
        tests.run("round 17 failure notification transitions") {
            test17_AttentionNotificationPlanner(tests)
        }
        tests.finish()
    }
}
