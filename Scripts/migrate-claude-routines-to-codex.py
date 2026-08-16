#!/usr/bin/env python3
"""Atomically move six Claude schedules to Ticker-observed Codex launchd jobs."""

from __future__ import annotations

import contextlib
import dataclasses
import datetime as dt
import enum
import fcntl
import json
import os
import plistlib
import secrets
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple
from zoneinfo import ZoneInfo


TICKET = "SKY-14155"
MARKER_PAYLOAD = b"SKY-14155 ticker Codex cutover committed v1\n"
HOME_DIRECTORY = Path("/Users/suchintan")
WORKING_DIRECTORY = Path("/Users/suchintan/Development/Skyvern-cloud")
REGISTRY = Path(
    "/Users/suchintan/Library/Application Support/Claude/claude-code-sessions/"
    "c12cb80a-7d79-4bf5-830c-cb887bf75e9a/"
    "ce4a7336-0b74-4971-a208-a03702ccb1bf/scheduled-tasks.json"
)
TRANSACTION_LOCK = REGISTRY.with_name(
    f"{REGISTRY.name}.ticker-codex-{TICKET}.lock"
)
SUCCESS_MARKER = Path(str(REGISTRY) + ".ticker-codex-SKY-14155.success")
RUNNER_SOURCE = Path("/Users/suchintan/Development/ticker/Scripts/run-codex-scheduled-task")
RUNNER_INSTALLED = Path("/Users/suchintan/.local/bin/run-codex-scheduled-task")
CODEX_EXECUTABLE = Path("/Users/suchintan/.nvm/versions/node/v24.9.0/bin/codex")
TICKER_EXECUTABLE = Path("/Applications/Ticker.app/Contents/Helpers/ticker")
LAUNCHCTL = Path("/bin/launchctl")
PS = Path("/bin/ps")
OSASCRIPT = Path("/usr/bin/osascript")
OPEN = Path("/usr/bin/open")
CLAUDE_DESKTOP_EXECUTABLE = "/Applications/Claude.app/Contents/MacOS/Claude"
NEW_YORK = ZoneInfo("America/New_York")
BLACKOUT_SECONDS = 15 * 60
CLAUDE_POLL_ATTEMPTS = 50
CLAUDE_STABLE_POLLS = 3
REGISTRY_PUBLICATION_ATTEMPTS = 3
CLAUDE_POLL_INTERVAL_SECONDS = 0.2
LAUNCHD_ENVIRONMENT: Mapping[str, str] = {
    "HOME": "/Users/suchintan",
    "PATH": (
        "/Users/suchintan/.nvm/versions/node/v24.9.0/bin:"
        "/Users/suchintan/.superset/bin:/opt/homebrew/bin:/usr/local/bin:"
        "/usr/bin:/bin:/usr/sbin:/sbin:/Users/suchintan/.local/bin"
    ),
    "TZ": "America/New_York",
}
ABSENT_SERVICE_PHRASES = ("could not find service", "no such process", "service not found")
HANDLED_SIGNALS = tuple(
    getattr(signal, name)
    for name in ("SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM")
    if hasattr(signal, name)
)


class CutoverError(RuntimeError):
    pass


class RollbackError(CutoverError):
    pass


class CutoverSignal(BaseException):
    def __init__(self, signum: int) -> None:
        super().__init__(f"cutover interrupted by signal {signum}")
        self.signum = signum


class RootKind(enum.Enum):
    PERSONAL_LINK = "personal-link"
    DIRECT_PROJECT = "direct-project"


class PlistState(enum.Enum):
    ABSENT = "absent"
    ORIGINAL = "original"
    WRAPPED = "wrapped"


@dataclasses.dataclass(frozen=True)
class SkillRoot:
    name: str
    installed_root: Path
    canonical_root: Path
    kind: RootKind

    @property
    def installed_skill(self) -> Path:
        return self.installed_root / "SKILL.md"

    @property
    def canonical_skill(self) -> Path:
        return self.canonical_root / "SKILL.md"


@dataclasses.dataclass(frozen=True)
class Routine:
    task_id: str
    legacy_cron: str
    claude_prompt: Path
    plist: Path
    label: str
    ticker_id: str
    calendar: Any
    schedule_points: Tuple[Tuple[int, int, Optional[int]], ...]
    root: SkillRoot

    @property
    def original_arguments(self) -> List[str]:
        return [str(RUNNER_INSTALLED), self.task_id, str(WORKING_DIRECTORY)]

    @property
    def wrapper_arguments(self) -> List[str]:
        return [
            str(TICKER_EXECUTABLE),
            "run",
            "--ticker-wrapper-version",
            "1",
            "--label",
            self.ticker_id,
            "--",
            *self.original_arguments,
        ]


@dataclasses.dataclass(frozen=True)
class CommandResult:
    status: int
    stdout: str
    stderr: str


@dataclasses.dataclass(frozen=True)
class ReplacementSnapshot:
    plist_states: Mapping[str, PlistState]
    loaded: frozenset[str]

    @property
    def absent(self) -> bool:
        return all(state is PlistState.ABSENT for state in self.plist_states.values())

    @property
    def full_codex(self) -> bool:
        return all(state is PlistState.WRAPPED for state in self.plist_states.values()) and (
            self.loaded == frozenset(self.plist_states)
        )


@dataclasses.dataclass
class CutoverState:
    audit_backup: Optional[Path] = None
    registry_disabled: bool = False
    wrapped: Set[str] = dataclasses.field(default_factory=set)
    activated: Set[str] = dataclasses.field(default_factory=set)
    replacements_verified: bool = False
    claude_was_running: bool = False
    claude_prior_pids: frozenset[int] = frozenset()
    claude_relaunched: bool = False
    committed: bool = False
    rolled_back: bool = False
    recovered: bool = False


class CommandRunner:
    def run(self, executable: Path, arguments: Sequence[str]) -> CommandResult:
        environment = os.environ.copy()
        if executable == TICKER_EXECUTABLE:
            # Administrative wrap and recovery operations must use the same
            # canonical store as scheduled wrapper invocations.
            environment.pop("TICKER_STORE_PATH", None)
        try:
            completed = subprocess.run(
                [str(executable), *arguments],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                env=environment,
            )
        except OSError as error:
            raise CutoverError(f"cannot execute {executable}: {error}") from error
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)


class SignalScope:
    def __enter__(self) -> "SignalScope":
        self.previous: Dict[int, Any] = {}

        def handler(signum: int, _frame: object) -> None:
            raise CutoverSignal(signum)

        for signum in HANDLED_SIGNALS:
            self.previous[signum] = signal.getsignal(signum)
            signal.signal(signum, handler)
        return self

    def __exit__(self, _kind: object, _value: object, _traceback: object) -> None:
        for signum, previous in self.previous.items():
            signal.signal(signum, previous)


@contextlib.contextmanager
def blocked_cutover_signals() -> Iterable[None]:
    if not hasattr(signal, "pthread_sigmask"):
        yield
        return
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, set(HANDLED_SIGNALS))
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


@contextlib.contextmanager
def migration_transaction_lock() -> Iterable[None]:
    flags = (
        os.O_RDWR
        | os.O_CREAT
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(TRANSACTION_LOCK, flags, 0o600)
    except OSError as error:
        raise CutoverError(f"cannot open migration lock: {TRANSACTION_LOCK}") from error
    try:
        try:
            metadata = os.fstat(descriptor)
        except OSError as error:
            raise CutoverError(
                f"cannot inspect migration lock descriptor: {TRANSACTION_LOCK}"
            ) from error
        if not stat.S_ISREG(metadata.st_mode):
            raise CutoverError(
                f"migration lock is not a regular file: {TRANSACTION_LOCK}"
            )
        if metadata.st_uid != os.getuid():
            raise CutoverError(
                f"migration lock is not owned by the current user: {TRANSACTION_LOCK}"
            )
        if stat.S_IMODE(metadata.st_mode) != 0o600:
            raise CutoverError(
                f"migration lock mode is not 0600: {TRANSACTION_LOCK}"
            )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise CutoverError(
                f"{TICKET} migration transaction is already running: "
                f"{TRANSACTION_LOCK}"
            ) from error
        except OSError as error:
            raise CutoverError(
                f"cannot acquire migration lock: {TRANSACTION_LOCK}"
            ) from error
        yield
    finally:
        os.close(descriptor)


def _weekdays(hour: int, minute: int) -> List[Dict[str, int]]:
    return [
        {"Hour": hour, "Minute": minute, "Weekday": weekday}
        for weekday in range(1, 6)
    ]


def _weekday_points(hour: int, minute: int) -> Tuple[Tuple[int, int, Optional[int]], ...]:
    return tuple((hour, minute, weekday) for weekday in range(1, 6))


def _personal_root(name: str) -> SkillRoot:
    return SkillRoot(
        name=name,
        installed_root=HOME_DIRECTORY / ".codex/skills" / name,
        canonical_root=HOME_DIRECTORY / "Development/obsidian/agents/skills" / name,
        kind=RootKind.PERSONAL_LINK,
    )


def _direct_root(name: str) -> SkillRoot:
    root = WORKING_DIRECTORY / ".agents/skills" / name
    return SkillRoot(name=name, installed_root=root, canonical_root=root, kind=RootKind.DIRECT_PROJECT)


DAILY_SUMMARY_ROOT = _personal_root("daily-summary")
VITALS_ROOT = _personal_root("vitals-run-all")
LINKEDIN_ROOT = _personal_root("linkedin-post-ideas")
OVERDUE_ROOT = _direct_root("overdue-customer-issues-slack")
TEAM_DIGEST_ROOT = _personal_root("team-progress-digest")


def _routine(
    task_id: str,
    legacy_cron: str,
    ticker_suffix: str,
    calendar: Any,
    schedule_points: Tuple[Tuple[int, int, Optional[int]], ...],
    root: SkillRoot,
) -> Routine:
    label = "com.suchintan.codex-scheduled." + task_id
    return Routine(
        task_id=task_id,
        legacy_cron=legacy_cron,
        claude_prompt=HOME_DIRECTORY / ".claude/scheduled-tasks" / task_id / "SKILL.md",
        plist=HOME_DIRECTORY / "Library/LaunchAgents" / f"{label}.plist",
        label=label,
        ticker_id=f"launchd:{label}#{ticker_suffix}",
        calendar=calendar,
        schedule_points=schedule_points,
        root=root,
    )


ROUTINES: Tuple[Routine, ...] = (
    _routine(
        "daily-summary",
        "55 23 * * *",
        "c8fe781eb340",
        {"Hour": 23, "Minute": 55},
        ((23, 55, None),),
        DAILY_SUMMARY_ROOT,
    ),
    _routine(
        "daily-vitals-morning",
        "30 8 * * 1-5",
        "41fcaa4cf24b",
        _weekdays(8, 30),
        _weekday_points(8, 30),
        VITALS_ROOT,
    ),
    _routine(
        "linkedin-post-ideas",
        "0 8 * * *",
        "6c4e3715f6d9",
        {"Hour": 8, "Minute": 0},
        ((8, 0, None),),
        LINKEDIN_ROOT,
    ),
    _routine(
        "linkedin-post-ideas-sweeper",
        "0 12 * * *",
        "63d9c7b96397",
        {"Hour": 12, "Minute": 0},
        ((12, 0, None),),
        LINKEDIN_ROOT,
    ),
    _routine(
        "overdue-customer-issues-slack",
        "40 9 * * 1-5",
        "48073be11319",
        _weekdays(9, 40),
        _weekday_points(9, 40),
        OVERDUE_ROOT,
    ),
    _routine(
        "team-progress-digest",
        "0 9 * * *",
        "b5d2b5a99273",
        {"Hour": 9, "Minute": 0},
        ((9, 0, None),),
        TEAM_DIGEST_ROOT,
    ),
)


def _regular_file(path: Path, description: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CutoverError(f"{description} is missing: {path}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise CutoverError(f"{description} is not a regular file: {path}")
    return metadata


def read_regular(path: Path, description: str) -> bytes:
    _regular_file(path, description)
    try:
        return path.read_bytes()
    except OSError as error:
        raise CutoverError(f"cannot read {description}: {path}") from error


def fsync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            descriptor = -1
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def create_audit_backup(registry_bytes: bytes, now: dt.datetime) -> Path:
    stamp = now.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    for _attempt in range(20):
        path = REGISTRY.with_name(
            f"{REGISTRY.name}.ticker-codex-{TICKET}.audit."
            f"{stamp}.{os.getpid()}.{secrets.token_hex(6)}.json"
        )
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        try:
            with os.fdopen(descriptor, "wb", closefd=True) as output:
                output.write(registry_bytes)
                output.flush()
                os.fsync(output.fileno())
        except BaseException:
            path.unlink(missing_ok=True)
            raise
        fsync_directory(path.parent)
        if read_regular(path, "registry audit backup") != registry_bytes:
            raise CutoverError("registry audit backup read-back failed")
        if stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise CutoverError("registry audit backup mode is not 0600")
        return path
    raise CutoverError("cannot allocate a unique registry audit backup")


def _decode_registry(data: bytes) -> Dict[str, Any]:
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CutoverError("Claude registry is not valid UTF-8 JSON") from error
    if not isinstance(value, dict) or not isinstance(value.get("scheduledTasks"), list):
        raise CutoverError("Claude registry does not contain scheduledTasks")
    return value


def selected_registry_rows(
    data: bytes,
    routines: Sequence[Routine] = ROUTINES,
    required_enabled: Optional[bool] = None,
) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    registry = _decode_registry(data)
    expected = {routine.task_id: routine for routine in routines}
    found: Dict[str, Dict[str, Any]] = {}
    for row in registry["scheduledTasks"]:
        if not isinstance(row, dict):
            continue
        task_id = row.get("id")
        if not isinstance(task_id, str) or task_id not in expected:
            continue
        if task_id in found:
            raise CutoverError(f"Claude registry duplicates selected row {task_id}")
        routine = expected[task_id]
        if row.get("cronExpression") != routine.legacy_cron:
            raise CutoverError(f"Claude cron changed for {task_id}")
        if row.get("filePath") != str(routine.claude_prompt):
            raise CutoverError(f"Claude prompt path changed for {task_id}")
        if type(row.get("enabled")) is not bool:
            raise CutoverError(f"Claude enabled flag is not Boolean for {task_id}")
        if required_enabled is not None and row["enabled"] is not required_enabled:
            state = "enabled" if required_enabled else "disabled"
            raise CutoverError(f"Claude row {task_id} is not {state}")
        found[task_id] = row
    missing = set(expected) - set(found)
    if missing:
        raise CutoverError(f"Claude registry is missing selected rows: {sorted(missing)}")
    return registry, found


def registry_with_selected_enabled(
    data: bytes,
    enabled: bool,
    routines: Sequence[Routine] = ROUTINES,
) -> bytes:
    registry, rows = selected_registry_rows(data, routines)
    for routine in routines:
        rows[routine.task_id]["enabled"] = enabled
    return (json.dumps(registry, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def publish_registry_enabled(
    enabled: bool,
    routines: Sequence[Routine],
    required_before: Optional[bool],
) -> None:
    metadata = _regular_file(REGISTRY, "Claude registry")
    if metadata.st_uid != os.getuid():
        raise CutoverError("Claude registry is not owned by the current user")
    current = read_regular(REGISTRY, "Claude registry")
    selected_registry_rows(current, routines, required_before)
    updated = registry_with_selected_enabled(current, enabled, routines)
    atomic_write(REGISTRY, updated, stat.S_IMODE(metadata.st_mode))
    selected_registry_rows(read_regular(REGISTRY, "published Claude registry"), routines, enabled)


def selected_registry_enabled(
    data: bytes,
    routines: Sequence[Routine] = ROUTINES,
) -> bool:
    _registry, rows = selected_registry_rows(data, routines)
    states = {row["enabled"] for row in rows.values()}
    if len(states) != 1:
        raise CutoverError("selected Claude registry rows have a mixed enabled state")
    return states.pop()


def cron_matches_calendar(cron: str, calendar: Any) -> bool:
    fields = cron.split()
    if len(fields) != 5 or fields[2:4] != ["*", "*"]:
        return False
    minute_text, hour_text, _day, _month, weekday_text = fields
    try:
        hour = int(hour_text)
        minute = int(minute_text)
    except ValueError:
        return False
    if weekday_text == "*":
        return calendar == {"Hour": hour, "Minute": minute}
    if weekday_text == "1-5":
        return calendar == _weekdays(hour, minute)
    return False


def parse_plist(path: Path) -> Dict[str, Any]:
    data = read_regular(path, "launchd plist")
    try:
        value = plistlib.loads(data)
    except plistlib.InvalidFileException as error:
        raise CutoverError(f"launchd plist is malformed: {path}") from error
    if not isinstance(value, dict):
        raise CutoverError(f"launchd plist root is not a dictionary: {path}")
    return value


def replacement_plist_payload(routine: Routine) -> Dict[str, Any]:
    return {
        "Label": routine.label,
        "ProgramArguments": routine.original_arguments,
        "WorkingDirectory": str(WORKING_DIRECTORY),
        "EnvironmentVariables": dict(LAUNCHD_ENVIRONMENT),
        "StartCalendarInterval": routine.calendar,
    }


def replacement_plist_bytes(routine: Routine) -> bytes:
    return plistlib.dumps(
        replacement_plist_payload(routine),
        fmt=plistlib.FMT_XML,
        sort_keys=False,
    )


def write_replacement_plist(routine: Routine) -> None:
    if os.path.lexists(routine.plist):
        raise CutoverError(f"replacement plist already exists for {routine.task_id}")
    atomic_write(routine.plist, replacement_plist_bytes(routine), 0o644)
    validate_plist(routine, wrapped=False)


def write_replacement_plists(routines: Sequence[Routine]) -> None:
    for routine in routines:
        write_replacement_plist(routine)


def remove_replacement_plist(path: Path) -> None:
    try:
        path.unlink()
    except OSError as error:
        raise CutoverError(f"cannot remove replacement plist: {path}") from error
    fsync_directory(path.parent)
    if os.path.lexists(path):
        raise CutoverError(f"replacement plist remained after removal: {path}")


def validate_plist(routine: Routine, wrapped: bool) -> None:
    metadata = _regular_file(routine.plist, "launchd plist")
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o644:
        raise CutoverError(f"launchd ownership or mode changed for {routine.task_id}")
    value = parse_plist(routine.plist)
    if set(value) != {
        "Label",
        "ProgramArguments",
        "WorkingDirectory",
        "EnvironmentVariables",
        "StartCalendarInterval",
    }:
        raise CutoverError(f"launchd keys changed for {routine.task_id}")
    expected_arguments = routine.wrapper_arguments if wrapped else routine.original_arguments
    if value["Label"] != routine.label or value["ProgramArguments"] != expected_arguments:
        raise CutoverError(f"launchd command changed for {routine.task_id}")
    if value["WorkingDirectory"] != str(WORKING_DIRECTORY):
        raise CutoverError(f"launchd working directory changed for {routine.task_id}")
    if value["EnvironmentVariables"] != dict(LAUNCHD_ENVIRONMENT):
        raise CutoverError(f"launchd environment changed for {routine.task_id}")
    if value["StartCalendarInterval"] != routine.calendar:
        raise CutoverError(f"launchd schedule changed for {routine.task_id}")
    if not cron_matches_calendar(routine.legacy_cron, routine.calendar):
        raise CutoverError(f"legacy cron does not match launchd schedule for {routine.task_id}")


def plist_wrapper_state(routine: Routine) -> bool:
    arguments = parse_plist(routine.plist).get("ProgramArguments")
    if arguments == routine.wrapper_arguments:
        validate_plist(routine, wrapped=True)
        return True
    if arguments == routine.original_arguments:
        validate_plist(routine, wrapped=False)
        return False
    raise CutoverError(f"launchd wrapper state is unknown for {routine.task_id}")


def validate_ticker_ids(routines: Sequence[Routine]) -> None:
    ids = [routine.ticker_id for routine in routines]
    labels = [routine.label for routine in routines]
    if len(set(ids)) != len(ids) or len(set(labels)) != len(labels):
        raise CutoverError("routine Ticker ids or labels are not unique")
    for routine in routines:
        if not routine.ticker_id.startswith(f"launchd:{routine.label}#"):
            raise CutoverError(f"Ticker id does not bind label for {routine.task_id}")


def validate_skill_roots(roots: Sequence[SkillRoot]) -> None:
    seen: Set[str] = set()
    for root in roots:
        if root.name in seen:
            continue
        seen.add(root.name)
        try:
            canonical = root.canonical_root.resolve(strict=True)
        except OSError as error:
            raise CutoverError(f"canonical root is missing for {root.name}") from error
        if canonical != root.canonical_root or not canonical.is_dir():
            raise CutoverError(f"canonical root is not a direct directory for {root.name}")
        if root.kind is RootKind.PERSONAL_LINK:
            if not root.installed_root.is_symlink():
                raise CutoverError(f"personal root is not a symlink for {root.name}")
            target = Path(os.readlink(root.installed_root))
            if not target.is_absolute():
                target = root.installed_root.parent / target
            try:
                resolved_target = target.resolve(strict=True)
            except OSError as error:
                raise CutoverError(f"personal root target is missing for {root.name}") from error
            if resolved_target != canonical:
                raise CutoverError(f"personal root does not use the exact canonical target for {root.name}")
        elif root.kind is RootKind.DIRECT_PROJECT:
            if root.installed_root != root.canonical_root or root.installed_root.is_symlink():
                raise CutoverError(f"direct project root is not direct for {root.name}")
        else:
            raise CutoverError(f"unknown root kind for {root.name}")
        if not root.installed_skill.is_file() or not os.access(root.installed_skill, os.R_OK):
            raise CutoverError(f"live root SKILL.md is not readable for {root.name}")
        if not root.canonical_skill.is_file() or not os.access(root.canonical_skill, os.R_OK):
            raise CutoverError(f"canonical root SKILL.md is not readable for {root.name}")


def validate_executable(path: Path, description: str) -> None:
    try:
        canonical = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise CutoverError(
            f"{description} does not resolve to a valid target: {path}"
        ) from error
    metadata = _regular_file(canonical, f"{description} target")
    if metadata.st_uid != os.getuid():
        raise CutoverError(
            f"{description} target is not owned by the current user: {canonical}"
        )
    if not os.access(canonical, os.R_OK | os.X_OK):
        raise CutoverError(
            f"{description} target is not readable and executable: {canonical}"
        )


def install_runner_atomically() -> None:
    source = read_regular(RUNNER_SOURCE, "runner source")
    source_metadata = RUNNER_SOURCE.stat()
    if source_metadata.st_uid != os.getuid() or source_metadata.st_mode & 0o111 == 0:
        raise CutoverError("runner source ownership or executable mode is invalid")
    atomic_write(RUNNER_INSTALLED, source, 0o755)
    installed_metadata = _regular_file(RUNNER_INSTALLED, "installed runner")
    if installed_metadata.st_uid != os.getuid() or stat.S_IMODE(installed_metadata.st_mode) != 0o755:
        raise CutoverError("installed runner ownership or mode is invalid")
    if read_regular(RUNNER_INSTALLED, "installed runner") != source:
        raise CutoverError("source-installed runner read-back differs")


def _scheduled_fire_times(
    local: dt.datetime,
    routines: Sequence[Routine],
) -> Iterable[Tuple[Routine, dt.datetime]]:
    for day_delta in range(-8, 9):
        day = local.date() + dt.timedelta(days=day_delta)
        launchd_weekday = (day.weekday() + 1) % 7
        for routine in routines:
            for hour, minute, weekday in routine.schedule_points:
                if weekday is not None and weekday != launchd_weekday:
                    continue
                yield routine, dt.datetime.combine(
                    day,
                    dt.time(hour, minute),
                    tzinfo=NEW_YORK,
                )


def check_blackout(
    now: dt.datetime,
    routines: Sequence[Routine] = ROUTINES,
    blackout_seconds: int = BLACKOUT_SECONDS,
) -> None:
    if now.tzinfo is None:
        raise CutoverError("cutover clock must be timezone-aware")
    local = now.astimezone(NEW_YORK)
    nearest = min(
        _scheduled_fire_times(local, routines),
        key=lambda item: abs((item[1] - local).total_seconds()),
    )
    distance = abs((nearest[1] - local).total_seconds())
    if distance < blackout_seconds:
        raise CutoverError(
            f"cutover is inside the no-fire blackout for {nearest[0].task_id} at "
            f"{nearest[1].isoformat()}"
        )


def inspect_marker() -> str:
    if not os.path.lexists(SUCCESS_MARKER):
        return "absent"
    metadata = _regular_file(SUCCESS_MARKER, "success marker")
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
        return "foreign"
    return "exact" if read_regular(SUCCESS_MARKER, "success marker") == MARKER_PAYLOAD else "foreign"


def ensure_success_marker() -> None:
    marker = inspect_marker()
    if marker == "foreign":
        raise CutoverError("non-owned success marker blocks state publication")
    if marker == "absent":
        atomic_write(SUCCESS_MARKER, MARKER_PAYLOAD, 0o600)
    if inspect_marker() != "exact":
        raise CutoverError("success marker read-back failed")


def remove_success_marker() -> None:
    if inspect_marker() != "exact":
        raise RollbackError("success marker changed before rollback removal")
    try:
        SUCCESS_MARKER.unlink()
    except OSError as error:
        raise RollbackError("cannot remove success marker") from error
    fsync_directory(SUCCESS_MARKER.parent)
    if inspect_marker() != "absent":
        raise RollbackError("success marker remained after rollback")


def _service_absent(result: CommandResult) -> bool:
    if result.status == 0:
        return False
    output = (result.stdout + "\n" + result.stderr).lower()
    return any(phrase in output for phrase in ABSENT_SERVICE_PHRASES)


def parse_launchctl_print(output: str) -> Mapping[str, str]:
    fields: Dict[str, str] = {}
    for line in output.splitlines():
        key, separator, value = line.partition("=")
        if not separator:
            continue
        fields[key.strip()] = value.strip()
    return fields


def claude_desktop_pids(command_runner: CommandRunner) -> frozenset[int]:
    result = command_runner.run(PS, ["-axo", "pid=,command="])
    if result.status != 0:
        raise CutoverError("cannot inspect Claude process state")
    pids: Set[int] = set()
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, separator, command = stripped.partition(" ")
        if not separator or not pid_text.isdigit():
            raise CutoverError("cannot parse process inventory")
        pid = int(pid_text)
        if pid == os.getpid():
            continue
        try:
            arguments = shlex.split(command)
        except ValueError as error:
            raise CutoverError("cannot parse process command") from error
        if arguments and arguments[0] == CLAUDE_DESKTOP_EXECUTABLE:
            pids.add(pid)
    return frozenset(pids)


def claude_is_running(command_runner: CommandRunner) -> bool:
    return bool(claude_desktop_pids(command_runner))


def stop_claude(
    command_runner: CommandRunner,
    known_pids: Optional[frozenset[int]] = None,
    observe_pids: Optional[Callable[[frozenset[int]], None]] = None,
) -> frozenset[int]:
    observed_pids = (
        claude_desktop_pids(command_runner) if known_pids is None else known_pids
    )
    prior_pids: Set[int] = set()
    last_quit_pids = frozenset()
    stable_absence_polls = 0

    for attempt in range(CLAUDE_POLL_ATTEMPTS):
        if observed_pids:
            prior_pids.update(observed_pids)
            if observe_pids is not None:
                observe_pids(observed_pids)
            stable_absence_polls = 0
            if observed_pids != last_quit_pids:
                result = command_runner.run(
                    OSASCRIPT,
                    ["-e", 'tell application "Claude" to quit'],
                )
                if result.status != 0:
                    raise CutoverError("cannot ask Claude to quit")
                last_quit_pids = observed_pids
        else:
            stable_absence_polls += 1
            last_quit_pids = frozenset()
            if stable_absence_polls >= CLAUDE_STABLE_POLLS:
                return frozenset(prior_pids)

        if attempt + 1 < CLAUDE_POLL_ATTEMPTS:
            time.sleep(CLAUDE_POLL_INTERVAL_SECONDS)
            observed_pids = claude_desktop_pids(command_runner)

    raise CutoverError(
        "Claude did not remain absent for "
        f"{CLAUDE_STABLE_POLLS} consecutive observations before cutover"
    )


def relaunch_claude(
    command_runner: CommandRunner,
    should_run: bool,
    prior_pids: frozenset[int] = frozenset(),
) -> bool:
    if not should_run:
        return False
    current_pids = claude_desktop_pids(command_runner)
    rejected_pids = prior_pids | current_pids
    if current_pids:
        rejected_pids |= stop_claude(command_runner, current_pids)
    result = command_runner.run(OPEN, ["-a", "Claude"])
    if result.status != 0:
        raise CutoverError("Claude launch request failed")
    stable_pids: frozenset[int] = frozenset()
    stable_polls = 0
    for attempt in range(CLAUDE_POLL_ATTEMPTS):
        observed_pids = claude_desktop_pids(command_runner)
        if observed_pids and observed_pids.isdisjoint(rejected_pids):
            if observed_pids == stable_pids:
                stable_polls += 1
            else:
                stable_pids = observed_pids
                stable_polls = 1
            if stable_polls >= CLAUDE_STABLE_POLLS:
                return True
        else:
            stable_pids = frozenset()
            stable_polls = 0
        if attempt + 1 < CLAUDE_POLL_ATTEMPTS:
            time.sleep(CLAUDE_POLL_INTERVAL_SECONDS)
    raise CutoverError("Claude did not reach a new stable desktop process state")


class CutoverTransaction:
    def __init__(
        self,
        routines: Sequence[Routine] = ROUTINES,
        command_runner: Optional[CommandRunner] = None,
        clock: Callable[[], dt.datetime] = lambda: dt.datetime.now(tz=NEW_YORK),
    ) -> None:
        self.routines = tuple(routines)
        self.command_runner = command_runner or CommandRunner()
        self.clock = clock
        self.state = CutoverState()

    def _check_blackout(self) -> None:
        check_blackout(self.clock(), self.routines)

    def _ticker_states(self) -> Dict[str, Optional[bool]]:
        result = self.command_runner.run(TICKER_EXECUTABLE, ["list", "--json"])
        if result.status != 0:
            raise CutoverError("Ticker list failed")
        try:
            records = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise CutoverError("Ticker list returned malformed JSON") from error
        if not isinstance(records, list) or any(not isinstance(row, dict) for row in records):
            raise CutoverError("Ticker list JSON shape is invalid")

        seen_ids: Set[str] = set()
        known: Dict[str, bool] = {}
        for row in records:
            row_id = row.get("id")
            if not isinstance(row_id, str) or row_id in seen_ids:
                raise CutoverError("Ticker list contains a missing or duplicate id")
            seen_ids.add(row_id)
            matches = [
                routine
                for routine in self.routines
                if (
                    row_id == routine.ticker_id
                    or row.get("label") == routine.label
                    or row.get("configPath") == str(routine.plist)
                )
            ]
            if not matches:
                continue
            if len(matches) != 1:
                raise CutoverError("Ticker replacement identities overlap")
            routine = matches[0]
            managed = row.get("managed")
            if (
                row_id != routine.ticker_id
                or row.get("label") != routine.label
                or row.get("source") != "launchd"
                or row.get("configPath") != str(routine.plist)
                or type(managed) is not bool
                or routine.task_id in known
            ):
                raise CutoverError(f"Ticker identity is unknown for {routine.task_id}")
            known[routine.task_id] = managed
        return {routine.task_id: known.get(routine.task_id) for routine in self.routines}

    def _expect_ticker(self, managed: Optional[bool]) -> None:
        states = self._ticker_states()
        for routine in self.routines:
            if states[routine.task_id] is not managed:
                expected = "absent" if managed is None else ("managed" if managed else "unmanaged")
                raise CutoverError(
                    f"Ticker replacement is not {expected} for {routine.task_id}"
                )

    def _ticker_recovery_states(self) -> Dict[str, Optional[str]]:
        result = self.command_runner.run(TICKER_EXECUTABLE, ["doctor"])
        if result.status != 0:
            raise CutoverError("Ticker doctor failed")
        expected = {routine.ticker_id: routine.task_id for routine in self.routines}
        states: Dict[str, str] = {}
        for line in result.stdout.splitlines():
            ticker_id, separator, recovery = line.partition("\t")
            task_id = expected.get(ticker_id)
            if task_id is None:
                continue
            if not separator or task_id in states:
                raise CutoverError(f"Ticker doctor identity is unknown for {task_id}")
            states[task_id] = recovery
        return {routine.task_id: states.get(routine.task_id) for routine in self.routines}

    def _ticker_doctor(self) -> None:
        states = self._ticker_recovery_states()
        for routine in self.routines:
            if states[routine.task_id] != "wrapped-consistent":
                raise CutoverError(f"Ticker wrapper validation failed for {routine.task_id}")

    def _plist_state(self, routine: Routine) -> PlistState:
        if not os.path.lexists(routine.plist):
            return PlistState.ABSENT
        return PlistState.WRAPPED if plist_wrapper_state(routine) else PlistState.ORIGINAL

    def _service_loaded(self, routine: Routine) -> bool:
        target = f"gui/{os.getuid()}/{routine.label}"
        result = self.command_runner.run(LAUNCHCTL, ["print", target])
        if result.status == 0:
            fields = parse_launchctl_print(result.stdout)
            if (
                fields.get("path") != str(routine.plist)
                or fields.get("program") != str(TICKER_EXECUTABLE)
            ):
                raise CutoverError(
                    f"launchctl loaded an unknown replacement for {routine.task_id}"
                )
            return True
        if _service_absent(result):
            return False
        raise CutoverError(f"cannot inspect replacement service for {routine.task_id}")

    def _known_replacement_shape(
        self,
        plist_states: Mapping[str, PlistState],
        loaded: Set[str],
    ) -> bool:
        ordered_states = [plist_states[routine.task_id] for routine in self.routines]
        count = len(ordered_states)
        plist_shape_is_known = any(
            ordered_states
            == [PlistState.ORIGINAL] * split + [PlistState.ABSENT] * (count - split)
            for split in range(count + 1)
        ) or any(
            ordered_states
            == [PlistState.WRAPPED] * split + [PlistState.ORIGINAL] * (count - split)
            for split in range(count + 1)
        )
        if not plist_shape_is_known:
            return False
        if not loaded:
            return True
        loaded_flags = [routine.task_id in loaded for routine in self.routines]
        loaded_shape_is_known = any(
            loaded_flags == [True] * split + [False] * (count - split)
            for split in range(count + 1)
        )
        return (
            loaded_shape_is_known
            and all(state is PlistState.WRAPPED for state in ordered_states)
        )

    def _inspect_replacements(self, repair_stale: bool = True) -> ReplacementSnapshot:
        plist_states = {
            routine.task_id: self._plist_state(routine) for routine in self.routines
        }
        ticker_states = self._ticker_states()
        recovery_states = self._ticker_recovery_states()
        loaded = {
            routine.task_id for routine in self.routines if self._service_loaded(routine)
        }
        stale: List[Routine] = []
        for routine in self.routines:
            task_id = routine.task_id
            plist_state = plist_states[task_id]
            ticker_state = ticker_states[task_id]
            recovery_state = recovery_states[task_id]
            is_loaded = task_id in loaded
            if plist_state is PlistState.ABSENT:
                if ticker_state is not None or recovery_state is not None or is_loaded:
                    raise CutoverError(f"absent replacement has live identity for {task_id}")
            elif plist_state is PlistState.ORIGINAL:
                if ticker_state is not False or is_loaded:
                    raise CutoverError(f"unwrapped replacement state is unknown for {task_id}")
                if recovery_state == "stale-row":
                    stale.append(routine)
                elif recovery_state != "unwrapped":
                    raise CutoverError(f"Ticker recovery state is unsafe for {task_id}")
            elif (
                ticker_state is not True
                or recovery_state != "wrapped-consistent"
            ):
                raise CutoverError(f"Ticker wrapped recovery state is unsafe for {task_id}")

        if not self._known_replacement_shape(plist_states, loaded):
            raise CutoverError("replacement phases form an unknown combination")
        if stale:
            if not repair_stale:
                raise CutoverError("Ticker stale-row cleanup did not converge")
            for routine in stale:
                result = self.command_runner.run(
                    TICKER_EXECUTABLE,
                    ["doctor", "--clear-stale", routine.ticker_id],
                )
                expected = f"{routine.ticker_id}\tunwrapped"
                if result.status != 0 or result.stdout.splitlines() != [expected]:
                    raise CutoverError(f"Ticker stale-row cleanup failed for {routine.task_id}")
            return self._inspect_replacements(repair_stale=False)
        return ReplacementSnapshot(plist_states, frozenset(loaded))

    def _preflight_common(self) -> None:
        if not WORKING_DIRECTORY.is_dir():
            raise CutoverError("approved working directory is missing")
        validate_executable(TICKER_EXECUTABLE, "Ticker executable")
        validate_ticker_ids(self.routines)

    def _preflight_forward(self) -> None:
        validate_executable(CODEX_EXECUTABLE, "Codex executable")
        validate_skill_roots(tuple(routine.root for routine in self.routines))

    def _wrap_all(self) -> None:
        for routine in self.routines:
            result = self.command_runner.run(TICKER_EXECUTABLE, ["wrap", routine.ticker_id])
            if result.status != 0:
                raise CutoverError(f"Ticker wrap failed for {routine.task_id}")
            validate_plist(routine, wrapped=True)
            self.state.wrapped.add(routine.task_id)
        self._expect_ticker(True)
        self._ticker_doctor()

    def _activate_all(self) -> None:
        for routine in self.routines:
            self._check_blackout()
            result = self.command_runner.run(
                LAUNCHCTL,
                ["bootstrap", f"gui/{os.getuid()}", str(routine.plist)],
            )
            if result.status != 0:
                raise CutoverError(f"launchctl bootstrap failed for {routine.task_id}")
            self.state.activated.add(routine.task_id)
            if not self._service_loaded(routine):
                raise CutoverError(f"replacement did not load for {routine.task_id}")

    def _validate_replacements(self) -> None:
        snapshot = self._inspect_replacements()
        if not snapshot.full_codex:
            raise CutoverError("not all six replacements reached activation")
        selected_registry_rows(
            read_regular(REGISTRY, "disabled Claude registry"),
            self.routines,
            False,
        )
        self._ticker_doctor()
        expected = {routine.task_id for routine in self.routines}
        self.state.wrapped = set(expected)
        self.state.activated = set(expected)
        self.state.replacements_verified = True

    def _record_claude_custody(self, pids: frozenset[int]) -> None:
        if not pids:
            return
        self.state.claude_prior_pids |= pids
        self.state.claude_was_running = True

    def _quiesce_claude(self) -> None:
        stopped_pids = stop_claude(
            self.command_runner,
            observe_pids=self._record_claude_custody,
        )
        self._record_claude_custody(stopped_pids)

    def _ensure_registry(self, enabled: bool) -> None:
        for _attempt in range(REGISTRY_PUBLICATION_ATTEMPTS):
            # These consecutive absence observations are the last operation
            # before the authoritative registry read/publication.
            self._quiesce_claude()
            current = selected_registry_enabled(
                read_regular(REGISTRY, "Claude registry"),
                self.routines,
            )
            if current is not enabled:
                publish_registry_enabled(
                    enabled,
                    self.routines,
                    required_before=current,
                )

            # Prove quiescence again before trusting the publication. If a
            # newly started exact Claude process rewrote the selected rows,
            # the next bounded attempt republishes from that fresh document.
            self._quiesce_claude()
            published = selected_registry_enabled(
                read_regular(REGISTRY, "published Claude registry"),
                self.routines,
            )
            if published is enabled:
                self.state.registry_disabled = not enabled
                return

        state = "enabled" if enabled else "disabled"
        raise CutoverError(
            f"Claude registry did not remain {state} after "
            f"{REGISTRY_PUBLICATION_ATTEMPTS} quiesced publication attempts"
        )

    def _deactivate_replacements_to_absent(self) -> None:
        self._inspect_replacements()
        for routine in reversed(self.routines):
            target = f"gui/{os.getuid()}/{routine.label}"
            result = self.command_runner.run(LAUNCHCTL, ["bootout", target])
            if result.status != 0 and not _service_absent(result):
                raise RollbackError(f"bootout failed for {routine.task_id}")
            observed = self.command_runner.run(LAUNCHCTL, ["print", target])
            if not _service_absent(observed):
                raise RollbackError(f"replacement remained loaded for {routine.task_id}")

        self._inspect_replacements()
        for routine in reversed(self.routines):
            state = self._plist_state(routine)
            if state is PlistState.WRAPPED:
                result = self.command_runner.run(
                    TICKER_EXECUTABLE,
                    ["unwrap", routine.ticker_id],
                )
                if result.status != 0:
                    raise RollbackError(f"Ticker unwrap failed for {routine.task_id}")
                validate_plist(routine, wrapped=False)
        snapshot = self._inspect_replacements()
        if any(
            state is PlistState.WRAPPED for state in snapshot.plist_states.values()
        ):
            raise RollbackError("a replacement remained wrapped")

        for routine in self.routines:
            if self._plist_state(routine) is PlistState.ORIGINAL:
                validate_plist(routine, wrapped=False)
        for routine in reversed(self.routines):
            if os.path.lexists(routine.plist):
                remove_replacement_plist(routine.plist)
        if not self._inspect_replacements().absent:
            raise RollbackError("replacement plists remained after removal")
        self.state.wrapped.clear()
        self.state.activated.clear()
        self.state.replacements_verified = False

    def _create_codex_replacements(self) -> None:
        write_replacement_plists(self.routines)
        generated = self._inspect_replacements()
        if any(
            state is not PlistState.ORIGINAL
            for state in generated.plist_states.values()
        ):
            raise CutoverError("generated replacement state is not fully original")
        self._wrap_all()
        self._activate_all()
        self._validate_replacements()

    def _verify_claude_available(self) -> None:
        selected_registry_rows(
            read_regular(REGISTRY, "enabled Claude registry"),
            self.routines,
            True,
        )
        if not claude_is_running(self.command_runner):
            raise RollbackError("Claude desktop is not running")

    def _verify_claude_engine(self) -> None:
        self._verify_claude_available()
        if not self._inspect_replacements().absent:
            raise RollbackError("Claude state still has replacement plists")

    def _record_and_stop_claude(self) -> None:
        self._quiesce_claude()

    def _restore_enabled_claude_after_shutdown(self) -> None:
        with blocked_cutover_signals():
            selected_registry_rows(
                read_regular(REGISTRY, "enabled Claude registry"),
                self.routines,
                True,
            )
            if not self._inspect_replacements().absent:
                raise RollbackError("enabled Claude recovery found replacement plists")
            self.state.claude_relaunched = relaunch_claude(
                self.command_runner,
                self.state.claude_was_running,
                self.state.claude_prior_pids,
            )
            if self.state.claude_was_running:
                self._verify_claude_engine()

    def _restore_claude_engine(self) -> None:
        with blocked_cutover_signals():
            self._check_blackout()
            self._deactivate_replacements_to_absent()
            self._check_blackout()
            self._ensure_registry(True)
            self.state.claude_relaunched = relaunch_claude(
                self.command_runner,
                True,
                self.state.claude_prior_pids,
            )
            self._verify_claude_engine()
            marker = inspect_marker()
            if marker == "exact":
                remove_success_marker()
            elif marker != "absent":
                raise RollbackError("non-owned success marker blocks Claude restoration")
            self._verify_claude_engine()
            self.state.committed = False
            self.state.rolled_back = True

    def _restore_codex_engine(self) -> None:
        with blocked_cutover_signals():
            self._check_blackout()
            self._record_and_stop_claude()
            self._ensure_registry(False)
            self._deactivate_replacements_to_absent()
            self._check_blackout()
            self._create_codex_replacements()
            ensure_success_marker()
            self._validate_replacements()
            self.state.committed = True
            self.state.rolled_back = False
            self.state.claude_relaunched = False

    def _raise_with_codex_compensation(
        self,
        context: str,
        error: BaseException,
    ) -> None:
        try:
            self._restore_codex_engine()
        except BaseException as compensation_error:
            raise RollbackError(
                f"{context} failed ({error}); Codex compensation also failed "
                f"({compensation_error})"
            ) from compensation_error
        if isinstance(error, CutoverSignal):
            raise error
        raise RollbackError(
            f"{context} failed ({error}); Codex state was restored"
        ) from error

    def _restart_claude_if_requested(self) -> None:
        self.state.claude_relaunched = relaunch_claude(
            self.command_runner,
            self.state.claude_was_running,
            self.state.claude_prior_pids,
        )

    def execute(self) -> CutoverState:
        self._check_blackout()
        marker = inspect_marker()
        if marker == "exact":
            raise CutoverError("success marker already exists; use --rollback")
        if marker != "absent":
            raise CutoverError("non-owned success marker blocks cutover")
        self._preflight_common()
        registry_enabled = selected_registry_enabled(
            read_regular(REGISTRY, "Claude registry"),
            self.routines,
        )
        replacements = self._inspect_replacements()

        if not registry_enabled:
            self.state.registry_disabled = True
            try:
                with SignalScope():
                    self._record_and_stop_claude()
                    self._restore_claude_engine()
            except BaseException as recovery_error:
                self._raise_with_codex_compensation(
                    "partial cutover recovery",
                    recovery_error,
                )
            self.state.recovered = True
            self.state.rolled_back = False
            return self.state

        if not replacements.absent:
            raise CutoverError(
                "enabled Claude registry has replacement state; identity is unknown"
            )
        self._preflight_forward()
        install_runner_atomically()
        try:
            with SignalScope():
                self._record_and_stop_claude()
                self._check_blackout()
                registry = read_regular(REGISTRY, "Claude registry")
                selected_registry_rows(registry, self.routines, True)
                self.state.audit_backup = create_audit_backup(registry, self.clock())
                with blocked_cutover_signals():
                    self._ensure_registry(False)
                self._check_blackout()
                write_replacement_plists(self.routines)
                generated = self._inspect_replacements()
                if any(
                    state is not PlistState.ORIGINAL
                    for state in generated.plist_states.values()
                ):
                    raise CutoverError("generated replacement state is not fully original")
                self._wrap_all()
                self._activate_all()
                self._validate_replacements()
                self._check_blackout()
                ensure_success_marker()
                self.state.committed = True
        except BaseException as error:
            if self.state.committed:
                self._restart_claude_if_requested()
                return self.state
            registry_is_enabled = selected_registry_enabled(
                read_regular(REGISTRY, "Claude registry"),
                self.routines,
            )
            if registry_is_enabled:
                try:
                    self._restore_enabled_claude_after_shutdown()
                except BaseException as recovery_error:
                    self._raise_with_codex_compensation(
                        f"enabled Claude recovery after {error}",
                        recovery_error,
                    )
                raise
            self.state.registry_disabled = True
            try:
                self._restore_claude_engine()
            except BaseException as rollback_error:
                self._raise_with_codex_compensation(
                    f"cutover rollback after {error}",
                    rollback_error,
                )
            raise
        self._restart_claude_if_requested()
        return self.state

    def rollback_committed(self) -> CutoverState:
        self._check_blackout()
        marker = inspect_marker()
        if marker == "foreign":
            raise CutoverError("later rollback requires an absent or exact success marker")
        self._preflight_common()
        registry_enabled = selected_registry_enabled(
            read_regular(REGISTRY, "Claude registry"),
            self.routines,
        )
        replacements = self._inspect_replacements()

        if marker == "absent":
            if not registry_enabled:
                self.state.registry_disabled = True
                try:
                    with SignalScope():
                        self._record_and_stop_claude()
                        self._restore_claude_engine()
                except BaseException as recovery_error:
                    self._raise_with_codex_compensation(
                        "marker-absent rollback recovery",
                        recovery_error,
                    )
                return self.state
            if not replacements.absent:
                raise CutoverError(
                    "marker-absent enabled Claude state has replacement plists"
                )
            try:
                with SignalScope():
                    self.state.claude_prior_pids = claude_desktop_pids(
                        self.command_runner
                    )
                    self.state.claude_was_running = bool(
                        self.state.claude_prior_pids
                    )
                    self.state.claude_relaunched = relaunch_claude(
                        self.command_runner,
                        True,
                        self.state.claude_prior_pids,
                    )
                    self._verify_claude_engine()
            except BaseException as error:
                raise RollbackError(
                    f"marker-absent rollback verification failed ({error})"
                ) from error
            self.state.committed = False
            self.state.rolled_back = True
            return self.state

        try:
            with SignalScope():
                self._record_and_stop_claude()
                if not registry_enabled:
                    self.state.registry_disabled = True
                    if replacements.full_codex:
                        self._validate_replacements()
                    else:
                        self._restore_codex_engine()
                    replacements = self._inspect_replacements()
                    if not replacements.full_codex:
                        raise RollbackError(
                            "Codex normalization did not reach a complete state"
                        )
                self._check_blackout()
                self._ensure_registry(True)
                self.state.claude_relaunched = relaunch_claude(
                    self.command_runner,
                    True,
                    self.state.claude_prior_pids,
                )
                self._verify_claude_available()
                self._check_blackout()
                self._deactivate_replacements_to_absent()
                self._verify_claude_engine()
                remove_success_marker()
                self._verify_claude_engine()
                self.state.committed = False
                self.state.rolled_back = True
                return self.state
        except BaseException as error:
            try:
                with blocked_cutover_signals():
                    if inspect_marker() == "absent":
                        ensure_success_marker()
                self._restore_codex_engine()
            except BaseException as compensation_error:
                raise RollbackError(
                    f"explicit rollback failed ({error}); Codex compensation also failed "
                    f"({compensation_error})"
                ) from compensation_error
            if isinstance(error, CutoverSignal):
                raise
            raise RollbackError(
                f"explicit rollback failed ({error}); Codex state was restored"
            ) from error


def main(arguments: Optional[Sequence[str]] = None) -> int:
    values = list(sys.argv[1:] if arguments is None else arguments)
    if values not in ([], ["--rollback"]):
        print(f"usage: {Path(sys.argv[0]).name} [--rollback]", file=sys.stderr)
        return 64
    try:
        with migration_transaction_lock():
            transaction = CutoverTransaction()
            if values == ["--rollback"]:
                transaction.rollback_committed()
                print(f"{TICKET} scheduled-routine rollback completed")
            else:
                state = transaction.execute()
                if state.recovered:
                    print(
                        f"{TICKET} recovered a partial cutover to Claude; "
                        "run again to start a new cutover"
                    )
                else:
                    print(f"{TICKET} scheduled-routine cutover committed")
        return 0
    except CutoverSignal as error:
        print(f"cutover interrupted by signal {error.signum}", file=sys.stderr)
        return 128 + error.signum
    except RollbackError as error:
        print(f"safe rollback failed: {error}", file=sys.stderr)
        return 75
    except (CutoverError, OSError) as error:
        print(f"cutover failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
