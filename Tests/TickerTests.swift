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
        tests.expectEqual(jobs.count, 5, "malformed launchd plist is skipped without hiding valid siblings")
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
        let skips = try adapter.skips()
        let records = try require(skips[job.id], "Claude skips")
        tests.expectEqual(records.count, 1, "Claude skip records are loaded")
        tests.expectNear(
            try require(records.first, "first Claude skip").at.timeIntervalSince1970,
            1_786_074_929.896,
            accuracy: 0.001,
            "Claude skip epoch milliseconds convert to seconds"
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

private func test3A_ProgramAndArgumentsExecution(_ tests: TestHarness) throws {
    try withTemporaryDirectory("round3a-program-and-arguments") { directory in
        let tickerPath = try test3A_builtCLIPath()
        let observedURL = directory.appendingPathComponent("observed.txt")
        let script = "printf 'binary=/bin/sh argv0=%s' \"$0\" > '\(observedURL.path)'"
        let plistURL = directory.appendingPathComponent("program-and-arguments.plist")
        try writePropertyList([
            "Label": "com.example.program-and-arguments",
            "Program": "/bin/sh",
            "ProgramArguments": ["nightly-shell", "-c", script],
            "ThrottleInterval": 15,
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)

        let adapter = LaunchdAdapter(searchDirectories: [directory]) { _, _ in
            AdapterCommandResult(status: 0, stdout: "", stderr: "")
        }
        let job = try require(try adapter.discover().first, "test3A combined launchd job")
        tests.expectEqual(
            job.command,
            ["/bin/sh", "-c", script],
            "test3A launchd discovery uses Program as the executable"
        )

        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
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
            Array(wrappedArguments.dropFirst())
        )
        let observed = String(
            decoding: try Data(contentsOf: observedURL),
            as: UTF8.self
        )
        print(
            "TRANSCRIPT test3A N-001 status=\(result.status) "
                + "command=\(job.command[0]) observed='\(observed)'"
        )
        tests.expectEqual(result.status, 0, "test3A wrapped Program executable runs successfully")
        tests.expectEqual(
            observed,
            "binary=/bin/sh argv0=nightly-shell",
            "test3A wrapped child observes the original launchd argv zero"
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
        let skips = try ClaudeRoutineAdapter(searchRoots: [root]).skips()
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

        let skips = try adapter.skips()
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
                    !model.hasUrgentIssuesInMyJobs,
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
                    model.hasUrgentIssuesInMyJobs,
                    "test13_ownerMissingPayload_setsUrgentMenuBarState"
                )

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
            repository.appendingPathComponent("Sources/TickerApp/JobListView.swift").path,
            repository.appendingPathComponent("Sources/TickerApp/JobDetailView.swift").path,
            harnessSourceURL.path,
        ]
        try test3B_runProcess(
            swiftc,
            [
                "-module-cache-path", moduleCachePath,
                "-target", "arm64-apple-macosx13.0",
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
        tests.expectEqual(delayedPIDResult.status, 0, "test10_noPIDYet_stillExecutesChild")
        tests.expect(FileManager.default.fileExists(atPath: marker.path),
                     "test10_noPIDYet_provesChildExecuted")
        tests.expectEqual(try store.runs(jobID: fixture.job.id, limit: 10).count, 0,
                          "test10_noPIDYet_doesNotAttributeUnprovenRun")
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
        tests.expectEqual(forged.status, 1, "test10_handRunScheduledInjection_executesSuppliedChild")
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
                0,
                "test11_exactCommandDifferentPID_stillExecutesChild"
            )
        }
        tests.expectEqual(
            try store.runs(jobID: fixture.job.id, limit: 10).count,
            0,
            "test11_exactCommandDifferentPID_cannotAttributeHistory"
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
        let ownedResult = try test3A_runProcess(
            fixture.arguments[0],
            Array(fixture.arguments.dropFirst()),
            environment: ownedEnvironment
        )
        tests.expectEqual(
            ownedResult.status,
            0,
            "test11_nextSuccessfulAuthorization_executesChild"
        )
        tests.expectEqual(
            try store.runs(jobID: fixture.job.id, limit: 10).count,
            1,
            "test11_nextSuccessfulAuthorization_recordsHistory"
        )
        tests.expectEqual(
            try store.recorderDiagnostics(),
            [],
            "test11_nextSuccessfulAuthorization_clearsDiagnostic"
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
        tests.expectEqual(copiedResult.status, 0, "test9_copiedWrapper_stillExecutesChild")
        tests.expectEqual(copiedResult.stdout, "owner\n",
                          "test10_copiedWrapper_provesChildActuallyLaunched")
        tests.expect(copiedResult.stderr.contains("scheduled wrapper ownership not proven"),
                     "test9_copiedWrapper_reportsOwnershipFailureClearly")
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
            0,
            "test11_differentLabelCopiedWrapper_stillExecutesChild"
        )
        tests.expect(
            pathBoundResult.stderr.contains("scheduled wrapper ownership not proven"),
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
        if case .unknown = classifier.classify(
            source: .launchd,
            command: ["/usr/bin/plain-tool"],
            configPath: root.appendingPathComponent("unknown.plist").path
        ).provenance {
            tests.expect(true, "test13_unattributedBinary_hasTypedUnknownReason")
        } else {
            tests.expect(false, "test13_unattributedBinary_hasTypedUnknownReason")
        }
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
        listSource.contains("NavigationSplitView")
            && listSource.contains("List(selection:")
            && listSource.contains(".listStyle(.sidebar)"),
        "test13_sidebar_usesNativeNavigationAndSelection"
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
        detailSource.contains("Table(")
            && detailSource.contains("DisclosureGroup(\"Configuration\")")
            && detailSource.contains("DisclosureGroup(\"Advanced\")"),
        "test13_detail_prioritizesHistoryAndCollapsesDiagnostics"
    )
    tests.expect(
        detailSource.contains("truncationMode(.middle)")
            && detailSource.contains("textSelection(.enabled)")
            && detailSource.contains("borderedProminent"),
        "test13_detail_usesReviewedPathAndActionPresentation"
    )
    tests.expect(
        appSource.contains("job.provenance == .yours")
            || appSource.contains("model.hasUrgentIssuesInMyJobs"),
        "test13_menuBarFailure_isScopedToMyJobs"
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
        let tests = TestHarness()
        tests.run("round 13 provenance classification and cache") {
            try test13_ProvenanceClassificationAndCaching(tests)
        }
        tests.run("round 13 CLI missing payload") {
            try test13_CLISurfacesMissingPayload(tests)
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
        tests.finish()
    }
}
