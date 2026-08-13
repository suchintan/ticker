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

Ticker scans these local sources every 30 seconds:

- `~/Library/LaunchAgents`
- `/Library/LaunchAgents`
- `/Library/LaunchDaemons`
- The current user's crontab
- Claude scheduled-task files under `~/Library/Application Support/Claude`

## How launchd wrapping works

Ticker does not replace launchd. It puts the `ticker run` recorder in front of the job's existing command.

When you run `ticker wrap launchd:com.foo.bar`, Ticker makes these on-disk changes:

1. It writes the original plist bytes to a same-volume temporary file under `~/.ticker/backups/`, syncs the file, renames it into place, and syncs the backup directory before it changes the original.
2. It records the job and backup path in the `managed_jobs` table in `~/.ticker/ticker.db`.
3. It removes the command-only `Program` key, if present, and writes the Ticker command through `ProgramArguments`. For example:

   ```text
   ["/bin/bash", "/path/to/job.sh", "--flag"]
   ```

   becomes:

   ```text
   ["/Applications/Ticker.app/Contents/MacOS/ticker", "run", "--label", "launchd:com.foo.bar", "--",
    "/bin/bash", "/path/to/job.sh", "--flag"]
   ```

   Non-command plist keys keep the same values. Property-list serialization can change formatting and key order. The backup preserves the original bytes exactly, and `ticker unwrap` restores those bytes.
4. It makes repeat wrapping safe. If the Ticker executable moves, wrapping again updates only the executable path and keeps the original backup.

Ticker does **not** reload the launchd job for you. It prints ready-to-paste commands like these:

```bash
launchctl unload ~/Library/LaunchAgents/com.foo.bar.plist
launchctl load   ~/Library/LaunchAgents/com.foo.bar.plist
```

Run both commands to apply the changed plist.

### Revert a wrapped job

Use one of these two paths:

- **Preferred:** Run `ticker unwrap launchd:com.foo.bar`. Then run the two `launchctl` commands that it prints.
- **Manual:** Copy the matching backup from `~/.ticker/backups/` over the original plist. Then unload and load the plist with `launchctl`.

Ticker never deletes backups. Unwrap jobs before deleting `Ticker.app`. A wrapped job whose `ticker` binary is missing will fail with exit 127, so removing the app first can leave that job unable to run until you restore its backup.

## CLI reference

Ticker uses hand-rolled argument parsing and has no CLI package dependency.

```text
ticker run --label <job-id> [--tail-bytes N] -- <argv>...
```

Runs the child command and records it. Ticker streams the child's stdout and stderr to its own parent unchanged while capturing the last `N` bytes of each stream. The default is 8,192 bytes, and values above 1,048,576 bytes are clamped to that maximum. `N` must be positive. Ticker records the child exit code and exits with that same code, so launchd still sees the true result. It forwards SIGINT and SIGTERM. If the child cannot start, Ticker records and returns exit 127. A history-store failure never prevents the child from running.

```text
ticker list [--json]
```

Lists every discovered job with its source, label, schedule, next fire, and latest known outcome.

```text
ticker history <job-id> [--limit N] [--json]
```

Shows recent runs with start time, duration, exit code, and captured output tails.

```text
ticker wrap <job-id>
ticker unwrap <job-id>
```

Wraps a launchd job or restores its original plist. Both commands print the `launchctl` commands needed to apply the change.

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

## Claude routine history limitations

Claude routines currently expose timestamps and recorded scheduler skips, but no completed-run outcome. Run Now is unavailable for Claude routines because Ticker cannot safely reproduce the scheduler's permission mode, worktree, session context, or working directory. Ticker does not modify or replay Claude routines.

## License

Ticker is available under the [MIT License](LICENSE).
