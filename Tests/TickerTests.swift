import Darwin
import Foundation

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
    if arguments == ["list"] {
        return AdapterCommandResult(
            status: 0,
            stdout: "PID\tStatus\tLabel\n-\t32512\tcom.example.dictionary\n88\t0\tcom.example.array\n99\t0\tCyolo\n",
            stderr: ""
        )
    }
    if arguments.count == 2, arguments[0] == "list" {
        let raw = arguments[1] == "com.example.dictionary" ? 32_512 : 0
        return AdapterCommandResult(
            status: 0,
            stdout: "{\n\t\"LastExitStatus\" = \(raw);\n}\n",
            stderr: ""
        )
    }
    return AdapterCommandResult(status: 1, stdout: "", stderr: "unexpected \(executable.path)")
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
                    "/usr/local/bin/ticker", "run", "--label",
                    "launchd:com.example.dictionary", "--", "/usr/bin/true", "--original-flag",
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
            "ticker", "run", "--label", "launchd:com.example", "--", "/bin/bash", "/tmp/job.sh",
        ]),
        "wrapped argv"
    )
    tests.expectEqual(decoded.label, "launchd:com.example", "LaunchdWrapper decodes the job label")
    tests.expectEqual(decoded.original, ["/bin/bash", "/tmp/job.sh"], "LaunchdWrapper decodes original argv")
    tests.expectEqual(
        LaunchdWrapper.decode(["/bin/bash", "/tmp/job.sh"])?.label,
        nil,
        "LaunchdWrapper rejects unwrapped argv"
    )
    tests.expectEqual(
        LaunchdWrapper.decode([
            "/usr/local/bin/ticker-helper", "run", "--label", "launchd:com.example", "--", "/bin/bash",
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
    tests.expectEqual(adapter.environment, ["SHELL": "/bin/zsh"], "crontab environment is parsed")
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
        tests.expectEqual(job.id, "claude:daily-summary", "Claude routine id is stable")
        tests.expectEqual(job.cwd, "/tmp/project-new", "Claude routine dedupe keeps the newest run")
        tests.expectNear(
            try require(job.lastRunAt, "Claude lastRunAt").timeIntervalSince1970,
            1_786_629_662.123,
            accuracy: 0.001,
            "Claude fractional-second ISO-8601 timestamp is parsed"
        )
        let skips = try adapter.skips()
        let records = try require(skips["claude:daily-summary"], "Claude skips")
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
        )
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
        )
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

        _ = try wrapper.wrap(job: job, tickerPath: "/Applications/Ticker.app/Contents/MacOS/ticker")
        let wrapped = try test2A_readPropertyList(plistURL)
        let wrappedArguments = try require(wrapped["ProgramArguments"] as? [String], "wrapped arguments")
        tests.expect(wrapped["Program"] == nil, "test2A Program-only wrap removes Program")
        tests.expectEqual(
            wrappedArguments.first,
            "/Applications/Ticker.app/Contents/MacOS/ticker",
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

    try withTemporaryDirectory("round2a-program-and-arguments") { directory in
        let plistURL = directory.appendingPathComponent("program-and-arguments.plist")
        let originalArguments = ["/usr/bin/env", "echo", "both"]
        try writePropertyList([
            "Label": "com.example.program-and-arguments",
            "Program": "/bin/echo",
            "ProgramArguments": originalArguments,
            "ThrottleInterval": 15,
        ], to: plistURL)
        let originalData = try Data(contentsOf: plistURL)
        let store = try SQLiteRunStore(path: directory.appendingPathComponent("ticker.db").path)
        let wrapper = JobWrapper(
            store: store,
            backupDirectory: directory.appendingPathComponent("backups", isDirectory: true)
        )
        let job = test2A_makeLaunchdJob(
            id: "launchd:com.example.program-and-arguments",
            label: "com.example.program-and-arguments",
            command: originalArguments,
            plistURL: plistURL
        )

        _ = try wrapper.wrap(job: job, tickerPath: "/usr/local/bin/ticker")
        let wrapped = try test2A_readPropertyList(plistURL)
        let wrappedArguments = try require(wrapped["ProgramArguments"] as? [String], "wrapped arguments")
        tests.expect(wrapped["Program"] == nil, "test2A combined wrap removes Program")
        tests.expectEqual(
            wrappedArguments.first,
            "/usr/local/bin/ticker",
            "test2A combined wrap makes ticker the effective executable"
        )
        tests.expectEqual(
            LaunchdWrapper.decode(wrappedArguments)?.original,
            originalArguments,
            "test2A combined wrap preserves ProgramArguments"
        )

        _ = try wrapper.unwrap(job: job)
        tests.expectEqual(
            try Data(contentsOf: plistURL),
            originalData,
            "test2A combined unwrap restores the original bytes"
        )
    }
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
        )
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
            beforeSourceRewrite: {
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
        )
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

private func test2A_CLIHardening(_ tests: TestHarness) throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/ticker/main.swift")
    let source = String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self)
    let forwarderIndex = try require(
        source.range(of: "let forwarder = SignalForwarder()")?.lowerBound,
        "signal forwarder construction"
    )
    let spawnIndex = try require(
        source.range(of: "try process.run()")?.lowerBound,
        "process spawn"
    )
    let attachIndex = try require(
        source.range(of: "forwarder.attach(processIdentifier: process.processIdentifier)")?.lowerBound,
        "signal forwarder attachment"
    )

    tests.expect(
        forwarderIndex < spawnIndex && spawnIndex < attachIndex,
        "test2A signal handling is installed before spawn and attached after spawn"
    )
    tests.expect(
        source.contains("pendingSignals.append(signal)")
            && source.contains("forwarder.stop()"),
        "test2A signals queue before attachment and spawn failure restores handling"
    )
    tests.expect(
        source.contains("private let maxTailBytes = 1_024 * 1_024")
            && source.contains("tailBytes = min(parsed, maxTailBytes)"),
        "test2A tail capture clamps requests to one MiB"
    )
    tests.expect(
        !source.contains("data.reserveCapacity(capacity)"),
        "test2A tail capture does not eagerly allocate the requested bound"
    )
    tests.expect(
        source.contains("--tail-bytes requires a positive integer"),
        "test2A non-positive tail limits remain usage errors"
    )
    tests.expect(
        source.contains("run requires a child command after '--'"),
        "test2A CLI rejects Run Now without a child command"
    )
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
        nightly.environment,
        ["PATH": "/opt/cron/bin:/usr/bin:/bin", "SHELL": "/bin/zsh"],
        "test2B crontab PATH and SHELL reach the job environment"
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

    let detailSourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/TickerApp/JobDetailView.swift")
    let detailSource = try String(contentsOf: detailSourceURL, encoding: .utf8)
    tests.expect(
        detailSource.contains(".disabled(busy || !job.canRunNow)"),
        "test2B detail view uses the tested Run Now predicate"
    )
    tests.expect(
        detailSource.contains("Ticker observes Claude routines but cannot faithfully re-run them.")
            && detailSource.contains("Trigger this routine from Claude."),
        "test2B detail view explains how to trigger Claude routines"
    )
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
        let forward = try require(
            try ClaudeRoutineAdapter(searchRoots: [rootA, rootZ]).discover().first,
            "test2B forward root order"
        )
        let reversed = try require(
            try ClaudeRoutineAdapter(searchRoots: [rootZ, rootA]).discover().first,
            "test2B reversed root order"
        )
        tests.expectEqual(
            forward.cwd,
            "/tmp/path-z",
            "test2B final snapshot path tie-break has a defined winner"
        )
        tests.expectEqual(
            reversed.cwd,
            forward.cwd,
            "test2B never-run snapshots resolve identically regardless of root order"
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
        let records = try require(
            try ClaudeRoutineAdapter(searchRoots: [root]).skips()["claude:daily-summary"],
            "test2B deduplicated skips"
        )
        tests.expectEqual(records.count, 3, "test2B copied snapshot skips are deduplicated")
        tests.expectEqual(
            Set(records.filter { $0.at.timeIntervalSince1970 == 2 }.map(\.reason)),
            Set(["limit", "disabled"]),
            "test2B same-time skips with distinct reasons both survive"
        )
    }
}

private func test2B_AppConcurrencyContracts(_ tests: TestHarness) throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/TickerApp/AppModel.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    tests.expect(
        source.contains("guard !refreshInProgress else")
            && source.contains("self.refreshInProgress = false"),
        "test2B refresh uses a single-flight gate"
    )
    tests.expect(
        source.contains("process.terminationHandler")
            && !source.contains("process.waitUntilExit()"),
        "test2B Run Now completion is asynchronous and never blocks discovery"
    )
    tests.expect(
        source.contains("ProcessInfo.processInfo.environment.merging(job.environment)"),
        "test2B Run Now merges scheduler variables over the inherited environment"
    )
}

// End round 2B regression tests

@main
private enum TickerTests {
    static func main() {
        let tests = TestHarness()
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
        tests.run("round 2A CLI hardening") { try test2A_CLIHardening(tests) }
        tests.run("round 2B launchd trigger and environment") {
            try test2B_LaunchdAutomaticTriggersAndEnvironment(tests)
        }
        tests.run("round 2B crontab execution context") { try test2B_CrontabExecutionContext(tests) }
        tests.run("round 2B Claude Run Now disablement") { try test2B_ClaudeRunNowDisabled(tests) }
        tests.run("round 2B Claude snapshot ordering") { try test2B_ClaudeSnapshotOrdering(tests) }
        tests.run("round 2B Claude skip deduplication") { try test2B_ClaudeSkipDeduplication(tests) }
        tests.run("round 2B app concurrency contracts") { try test2B_AppConcurrencyContracts(tests) }
        tests.finish()
    }
}
