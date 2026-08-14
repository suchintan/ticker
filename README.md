# Ticker

Ticker is an open-source macOS menu-bar app for scheduled-job run history and failure alerts. It watches launchd jobs, crontab entries, and Claude Code scheduled routines from one local panel.

## Why Ticker exists

Two failures on the machine that inspired Ticker showed why configuration editors are not enough:

- Three launchd jobs, `com.skyvern.daily-summary`, `com.skyvern.follow-up-email`, and `com.skyvern.rebase-main`, reported `LastExitStatus = 32512`. That wait status decodes to exit 127, or “command not found.” They stayed broken and invisible for two days.
- The Claude routine `daily-summary` recorded **3,995 `per_task_limit` skips over 154 hours** from August 6 through August 13, 2026. When it finally started, it ran **9.9 hours late**: it was scheduled for `2026-08-12T03:55Z` but started at `2026-08-12T13:51Z`.

Neither scheduler surfaced these problems to the user. LaunchControl and Lingon X help edit launchd plists. Ticker answers a different question: **Did my automation run, and did it work?**

## What you get

- A menu-bar status icon that turns red when any discovered job has failed.
- One view for launchd agents and daemons, crontab entries, and Claude routines.
- Late-run warnings and Claude skip-storm summaries.
- Full run history for wrapped launchd jobs, including duration, exit code, and output tails.
- A local CLI for scripts and terminal use.

## Screenshot

> Screenshot placeholder: the Ticker popover with grouped jobs, a late-run warning, and captured run output will go here.

## Install

Ticker needs macOS 13 or later and the Swift toolchain included with Apple Command Line Tools. It has no external Swift packages.

```bash
git clone https://github.com/suchintan/ticker.git
cd ticker
bash Scripts/build-app.sh
open Ticker.app
```

The script invokes `swiftc` directly, creates an ad-hoc-signed `Ticker.app` in the repository root, and does not use SwiftPM. `swift build` cannot run with Command Line Tools alone because that installation has no platform SDK metadata. Move the app to `/Applications` before wrapping jobs if you want a stable executable path.

Run the dependency-free test executable through the direct compiler path:

```bash
bash Scripts/run-tests.sh
```

## Supported sources and native history

| Source | What the scheduler exposes without Ticker wrapping |
| --- | --- |
| launchd | `LastExitStatus` for the most recent run only. It has no timestamp, duration, output, or earlier history. |
| crontab | Nothing. crontab stores the schedule and command, but no run state or history. |
| Claude routines | `lastRunAt` and `lastScheduledFor` timestamps only. There is no exit code, duration, output, or outcome. |
| Wrapped by Ticker | Full local history: start, end, duration, exit code, and stdout/stderr tails. |

Ticker separates scheduled runs from manual **Run Now** attempts. Manual runs stay visible in history, but they never determine job health.

An unwrapped launchd job uses launchd's native exit status when it is available. A wrapped job uses fail-safe precedence:

- Ticker reports an unfinished stored run as `running` only while its wrapper PID is alive in the same macOS boot session and launchd reports that same PID for the service.
- An orphaned unfinished row cannot hide a native launchd failure. Ticker uses the native status when it cannot verify the wrapper process.
- Each wrapper records launchd's native exit status and run count before it starts the child. An unchanged native failure predates a later stored success and does not veto that success.
- If the current native exit status or launchd run count differs from the wrapper's start snapshot, launchd observed an event that the wrapper did not record. A current native failure then overrides the stored success.
- A stored failure remains a failure until a later scheduled wrapper run records success. Native success alone does not erase detailed stored failure evidence.

Ticker scans these local sources every 30 seconds:

- `~/Library/LaunchAgents`
- `/Library/LaunchAgents`
- `/Library/LaunchDaemons`
- The current user's crontab
- Claude scheduled-task files under `~/Library/Application Support/Claude`

Launchd labels are unique only within a launchd domain. The same label in the signed-in user's `gui` domain and the `system` domain represents two different jobs. Ticker lists them separately and resolves each job from its own domain-qualified runtime record.

## How launchd wrapping works

Ticker does not replace launchd. It puts the `ticker run` recorder in front of the job's existing command.

When you run `ticker wrap <launchd-job-id>`, Ticker makes these on-disk changes:

1. It writes the original plist bytes to a same-volume temporary file under `~/.ticker/backups/`, syncs the file, renames it into place, and syncs the backup directory before it changes the original. A versioned metadata file authenticates the backup with its byte count and SHA-256 digest. It also binds the backup to the job id and canonical source plist path. Ticker refuses legacy metadata without a digest and refuses any backup whose content no longer matches the metadata.
2. It records the job and backup path in the `managed_jobs` table in `~/.ticker/ticker.db`.
3. It removes `Program`, if present, and writes the Ticker command through `ProgramArguments`. The command includes a versioned provenance marker. For example:

   ```text
   ["/bin/bash", "/path/to/job.sh", "--flag"]
   ```

   becomes:

   ```text
   ["/Applications/Ticker.app/Contents/Helpers/ticker", "run", "--ticker-wrapper-version", "1",
    "--label", "launchd:com.foo.bar#0123456789ab", "--", "/bin/bash", "/path/to/job.sh", "--flag"]
   ```

   If a plist has both `Program` and `ProgramArguments`, Ticker keeps `Program` as the executable. It also passes `--argv0` so the child receives the original first argument. Ticker does not try to execute `ProgramArguments[0]` in this case.

   Non-command plist keys keep the same values. Property-list serialization can change formatting and key order. The authenticated backup preserves the original bytes for disaster recovery. On unwrap, Ticker restores only `Program` and `ProgramArguments` from that backup. It leaves current schedule, environment, and other non-command values unchanged.
4. It makes repeat wrapping safe. If the Ticker executable moves, wrapping again updates only the executable path and keeps the authenticated original backup. Ticker does not adopt a third-party executable merely because its filename is `ticker`. Before each rewrite, Ticker also confirms that the source bytes still match the version it read.

Ticker does **not** reload the launchd job for you. It prints ready-to-paste commands like these:

```bash
launchctl unload ~/Library/LaunchAgents/com.foo.bar.plist
launchctl load   ~/Library/LaunchAgents/com.foo.bar.plist
```

Run both commands to apply the changed plist.

### Revert a wrapped job

Use one of these two paths:

- **Preferred:** Find the internal job id with `ticker list --json`. Run `ticker unwrap <launchd-job-id>`. Ticker restores the original command and preserves non-command edits made while wrapped. Then run the two `launchctl` commands that it prints.
- **Manual:** Copy the matching backup over the original plist. Run `ticker doctor --clear-stale <launchd-job-id>` to clear the managed database row. Then unload and load the plist with `launchctl`. Ticker refuses a manual restore whose authenticated metadata names another plist or whose bytes fail authentication.

If `Program` or `ProgramArguments` changed to neither the Ticker wrapper nor the backed-up command, Ticker refuses to guess. The error names both files. Compare those two keys with the authenticated backup, restore the intended command manually, and then run `ticker doctor`. You can copy the complete backup into place if you want disaster recovery instead of preserving current non-command edits.

Ticker never deletes backups. Unwrap jobs before deleting `Ticker.app`. A wrapped job whose `ticker` binary is missing will fail with exit 127, so removing the app first can leave that job unable to run until you restore its backup.

## CLI reference

Ticker uses hand-rolled argument parsing and has no CLI package dependency.

```text
ticker run --label <job-id> [--manual] [--ticker-wrapper-version VERSION] [--argv0 VALUE] [--tail-bytes N] -- <argv>...
```

Runs the child command and records it. `--manual` marks a Run Now attempt, which appears in history but does not change scheduled health. Ticker validates manual jobs against current discovery and refuses jobs whose launchd uid or gid differs from Ticker's process. The wrapper-generated provenance version distinguishes Ticker-managed launchd entries from unrelated executables with the same filename. `--argv0` sets the child process's first argument without changing the executable. Ticker streams stdout and stderr to its parent while capturing the last `N` bytes of each stream. The default is 8,192 bytes. Values above 1,048,576 bytes are clamped to that maximum, and `N` must be positive. Capture is independent of parent output backpressure. Forwarding uses a bounded pending buffer and can discard forwarded bytes when the parent stops reading, but the recorded tail still completes. Ticker records the child exit code and exits with that same code. It forwards SIGINT and SIGTERM to the child's process group.

```text
ticker list [--json]
```

Lists every discovered job with its source, label, schedule, next fire, and latest known outcome.

```text
ticker history <job-id> [--limit N] [--json]
```

Shows recent runs with their scheduled or manual trigger, start time, duration, exit code, and captured output tails.

```text
ticker wrap <job-id>
ticker unwrap <job-id>
```

Wraps a launchd job or restores only its original command keys. Unwrap preserves current non-command plist values. Both commands print the `launchctl` commands needed to apply the change.

```text
ticker doctor
ticker doctor --clear-stale <job-id>
```

Reports each launchd job's current wrapper, managed-row, and authenticated-backup state, followed by any active recorder-authorization diagnostics. It reports missing or unauthenticated backups, authenticated-content mismatches, wrapper and backup command disagreements, foreign wrapper labels, identity changes, and stale managed rows. The clear option removes a managed row only when the plist has already been restored outside Ticker.

```text
ticker --help
ticker --version
```

Usage errors exit with status 2. Commands using `--json` write valid JSON to stdout and write nothing else there.

## Data and privacy

Ticker keeps all state on your Mac:

| Path | Contents |
| --- | --- |
| `~/.ticker/ticker.db` | Run history in SQLite with WAL enabled |
| `~/.ticker/backups/` | Plist backups made before wrapping |

Ticker makes no network calls and sends no telemetry.

## Run Now fidelity

Ticker enables Run Now only when it can reproduce the scheduler's execution context. Crontab jobs run with their discovered scheduler environment and from their effective non-empty `HOME`, as cron does. Launchd jobs are disabled when their `UserName`, `GroupName`, or system-daemon domain would use a different effective uid or gid. Wrapping uses the same identity gate, so Ticker does not rewrite a system-domain daemon that it cannot run faithfully. The job detail view and command error state the reason.

## Claude routine history limitations

Claude routines currently expose timestamps and recorded scheduler skips, but no completed-run outcome. Run Now is unavailable for Claude routines because Ticker cannot safely reproduce the scheduler's permission mode, worktree, session context, or working directory. Ticker does not modify or replay Claude routines.

## License

Ticker is available under the [MIT License](LICENSE).
