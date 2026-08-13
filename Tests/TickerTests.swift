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
        let storePath = directory.appendingPathComponent("ticker.db").path
        let environment = ["TICKER_STORE_PATH": storePath]

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

        let tailJobID = "test3A-tail-clamp"
        let oversized = try test3A_runProcess(
            tickerPath,
            [
                "run", "--label", tailJobID,
                "--tail-bytes", "2000000",
                "--", "/usr/bin/python3", "-c",
                "import sys; sys.stdout.write('A' * (1048576 + 257) + 'END')",
            ],
            environment: environment,
            timeout: 30
        )
        tests.expectEqual(oversized.status, 0, "test3A oversized tail run exits successfully")
        let store = try SQLiteRunStore(path: storePath)
        let storedTail = try require(
            try store.latestRun(jobID: tailJobID)?.stdoutTail,
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

        let pipeline = Process()
        pipeline.executableURL = URL(fileURLWithPath: tickerPath)
        pipeline.arguments = [
            "run", "--label", "test3A-signal-tree",
            "--", "/bin/sh", "-c",
            "echo $$ > '\(shellPIDURL.path)'; sleep 600 | cat",
        ]
        var pipelineEnvironment = ProcessInfo.processInfo.environment
        pipelineEnvironment["TICKER_STORE_PATH"] = storePath
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

private func test3A_builtCLIPath() throws -> String {
    if let test3A_cachedCLIPath {
        return test3A_cachedCLIPath
    }
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let result = try test3A_runProcess(
        "/bin/bash",
        ["Scripts/build-app.sh"],
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

        let storePath = directory.appendingPathComponent("ticker.db").path
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
            environment: ["TICKER_STORE_PATH": storePath]
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
            "ProgramArguments": ["/bin/echo", "manually-restored"],
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

private func test3B_AppBehavior(_ tests: TestHarness) throws {
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
        try test3B_runProcess(
            swiftc,
            [
                "-target", "arm64-apple-macosx13.0",
                "-parse-as-library",
                "-emit-module", "-module-name", "TickerCore",
                "-emit-module-path", modulePath,
                "-emit-library", "-static", "-o", libraryPath,
            ] + coreSources.map(\.path),
            currentDirectory: repository
        )

        let harnessSource = #"""
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

        @main
        private enum AppBehaviorHarness {
            @MainActor
            static func main() throws {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TickerAppHarness-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }

                let appOnlyBin = root.appendingPathComponent("gui-only-bin", isDirectory: true)
                try FileManager.default.createDirectory(at: appOnlyBin, withIntermediateDirectories: true)
                let ticker = appOnlyBin.appendingPathComponent("ticker")
                try """
                #!/bin/sh
                while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
                    shift
                done
                [ "$#" -gt 0 ] || exit 64
                shift
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
                    nextFireLabels == [
                        "kept alive",
                        "at load",
                        "when /tmp/watch changes",
                        "when /tmp/queue is not empty",
                        "on demand",
                    ],
                    "automatic trigger next-fire text was mislabeled"
                )
                try check(Set(nextFireLabels).count == 5, "automatic trigger labels were not distinct")

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
                environment: [String: String],
                command: [String]
            ) -> Job {
                Job(
                    id: id,
                    source: .crontab,
                    label: id,
                    schedule: .cron("* * * * *"),
                    command: command,
                    environment: environment,
                    cwd: nil,
                    enabled: true,
                    configPath: nil,
                    lastKnownExit: nil,
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
            "test3B app behavior harness covers refresh, Run Now, environment, and next-fire text"
        )
    }
}

// End round 3B regression tests

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
        tests.run("round 3B app behavior") { try test3B_AppBehavior(tests) }
        tests.finish()
    }
}
