from __future__ import annotations

import dataclasses
import datetime as dt
import errno
import hashlib
import importlib.util
import inspect
import io
import json
import os
import plistlib
import platform
import re
import shlex
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack, contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "Scripts" / "migrate-claude-routines-to-codex.py"
RUNNER = REPO / "Scripts" / "run-codex-scheduled-task"
_ORIGINAL_UMASK: int | None = None


def setUpModule() -> None:
    global _ORIGINAL_UMASK
    _ORIGINAL_UMASK = os.umask(0o077)


def tearDownModule() -> None:
    if _ORIGINAL_UMASK is not None:
        os.umask(_ORIGINAL_UMASK)

spec = importlib.util.spec_from_file_location("ticker_codex_cutover", SCRIPT)
assert spec is not None and spec.loader is not None
cutover = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = cutover
spec.loader.exec_module(cutover)


EXPECTED = {
    "daily-summary": ("55 23 * * *", {"Hour": 23, "Minute": 55}, "c8fe781eb340"),
    "daily-vitals-morning": (
        "30 8 * * 1-5",
        [
            {"Hour": 8, "Minute": 30, "Weekday": weekday}
            for weekday in range(1, 6)
        ],
        "41fcaa4cf24b",
    ),
    "linkedin-post-ideas": ("0 8 * * *", {"Hour": 8, "Minute": 0}, "6c4e3715f6d9"),
    "linkedin-post-ideas-sweeper": (
        "0 12 * * *",
        {"Hour": 12, "Minute": 0},
        "63d9c7b96397",
    ),
    "overdue-customer-issues-slack": (
        "40 9 * * 1-5",
        [
            {"Hour": 9, "Minute": 40, "Weekday": weekday}
            for weekday in range(1, 6)
        ],
        "48073be11319",
    ),
    "team-progress-digest": ("0 9 * * *", {"Hour": 9, "Minute": 0}, "b5d2b5a99273"),
}


def synthetic_discovery_routines(root: Path) -> tuple[object, ...]:
    routines = []
    for routine in cutover.ROUTINES:
        synthetic_root = root / "skill roots with spaces" / routine.root.name
        routines.append(
            dataclasses.replace(
                routine,
                claude_prompt=(
                    root
                    / "legacy prompts with spaces"
                    / routine.task_id
                    / "SKILL.md"
                ),
                plist=root / "LaunchAgents with spaces" / routine.plist.name,
                root=dataclasses.replace(
                    routine.root,
                    installed_root=synthetic_root / "installed",
                    canonical_root=synthetic_root / "canonical",
                ),
            )
        )
    return tuple(routines)


def write_registry(path: Path, routines: tuple[object, ...]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = [
        {
            "id": routine.task_id,
            "enabled": True,
            "cronExpression": routine.legacy_cron,
            "filePath": str(routine.claude_prompt),
        }
        for routine in routines
    ]
    path.write_text(json.dumps({"scheduledTasks": rows}), encoding="utf-8")


def write_plist(routine: object, wrapped: bool = False) -> None:
    arguments = routine.wrapper_arguments if wrapped else routine.original_arguments
    payload = {
        "Label": routine.label,
        "ProgramArguments": arguments,
        "WorkingDirectory": str(cutover.WORKING_DIRECTORY),
        "EnvironmentVariables": dict(cutover.LAUNCHD_ENVIRONMENT),
        "StartCalendarInterval": routine.calendar,
    }
    routine.plist.parent.mkdir(parents=True, exist_ok=True)
    with routine.plist.open("wb") as output:
        plistlib.dump(payload, output, sort_keys=False)
    routine.plist.chmod(0o644)


def host_native_arch() -> str:
    machine = platform.machine().lower()
    if machine in {"arm64", "aarch64"}:
        return "arm64"
    if machine in {"x86_64", "amd64"}:
        return "x86_64"
    raise unittest.SkipTest(f"unsupported host architecture: {machine}")


def synthetic_host_macho(
    *,
    arch: str | None = None,
    filetype: int = 2,
    ncmds: int = 0,
    sizeofcmds: int = 0,
) -> bytes:
    """Return a complete, non-executed thin Mach-O header for identity tests."""
    selected_arch = host_native_arch() if arch is None else arch
    cputype = {"arm64": 0x0100000C, "x86_64": 0x01000007}.get(selected_arch)
    if cputype is None:
        raise ValueError(f"unsupported synthetic architecture: {selected_arch}")
    if ncmds < 0 or sizeofcmds < 0:
        raise ValueError("Mach-O command counts must be non-negative")
    return struct.pack(
        "<IiiIIIII",
        0xFEEDFACF,
        cputype,
        0,
        filetype,
        ncmds,
        sizeofcmds,
        0,
        0,
    )


def synthetic_host_native() -> bytes:
    """Return a complete native executable header for the current host platform."""
    if sys.platform.startswith("darwin"):
        return synthetic_host_macho()
    if not sys.platform.startswith("linux"):
        raise unittest.SkipTest(f"unsupported host platform: {sys.platform}")
    machine = {"arm64": 183, "x86_64": 62}[host_native_arch()]
    ident = b"\x7fELF" + bytes((2, 1, 1)) + b"\x00" * 9
    return struct.pack(
        "<16sHHIQQQIHHHHHH",
        ident,
        2,
        machine,
        1,
        0,
        0,
        0,
        0,
        64,
        0,
        0,
        0,
        0,
        0,
    )


def native_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bind_generated_runner(source: bytes, binding: dict[str, object]) -> bytes:
    _shebang, separator, body = source.partition(b"\n")
    if not separator:
        raise AssertionError("runner source must have a shebang line")
    body_lines = body.splitlines(keepends=True)
    while body_lines and body_lines[0].startswith(b"# TICKER-RUNTIME-V1 "):
        body_lines.pop(0)
    constant = b"RUNTIME_BINDING = " + repr(binding).encode("utf-8") + b"\n"
    insertion = next(
        (
            index
            for index, line in enumerate(body_lines)
            if line.startswith(b"if __name__ == \"__main__\":")
        ),
        len(body_lines),
    )
    body_lines[insertion:insertion] = [constant]
    header = (
        b"# TICKER-RUNTIME-V1 "
        + json.dumps(binding, sort_keys=True, separators=(",", ":")).encode("utf-8")
        + b"\n"
    )
    return (
        f"#!{sys.executable} -I".encode("utf-8")
        + b"\n"
        + header
        + b"".join(body_lines)
    )


class FakeCommandRunner:
    def __init__(self, routines: tuple[object, ...]) -> None:
        self.routines = routines
        self.loaded: set[str] = set()
        self.wrapped: set[str] = set()
        self.authenticated_backups: set[str] = set()
        self.claude_pids: set[int] = {812}
        self.next_claude_pid = 900
        self.claude_relaunched = False
        self.open_status = 0
        self.open_process_states: list[bool | set[int]] | None = None
        self.ps_sequence: list[set[int]] = []
        self.extra_processes: list[tuple[int, str]] = []
        self.quit_process_sequences: list[list[set[int]]] = []
        self.shutdown_poll_count = 0
        self.signal_on_shutdown_poll: int | None = None
        self.signal_after_quit = False
        self.quit_requested = False
        self.failures: dict[str, int] = {}
        self.after_failure: dict[str, str] = {}
        self.doctor_overrides: dict[str, str] = {}
        self.wrap_failure_task_id: str | None = None
        self.raise_signal_on_wrap = False
        self.interrupt_wrap_after_mark = False
        self.interrupt_unwrap_after_write = False
        self.events: list[str] = []
        self.on_bootout: object | None = None
        self.on_open: object | None = None

    @property
    def claude_running(self) -> bool:
        return bool(self.claude_pids)

    @claude_running.setter
    def claude_running(self, running: bool) -> None:
        self.claude_pids = {812} if running else set()

    def fail_once(self, operation: str) -> None:
        self.failures[operation] = self.failures.get(operation, 0) + 1

    def consume_failure(self, operation: str) -> bool:
        remaining = self.failures.get(operation, 0)
        if remaining == 0:
            return False
        self.failures[operation] = remaining - 1
        followup = self.after_failure.get(operation)
        if followup is not None:
            self.fail_once(followup)
        return True

    def routine_for_label(self, label: str) -> object:
        return next(routine for routine in self.routines if routine.label == label)

    def routine_for_ticker_id(self, ticker_id: str) -> object:
        return next(routine for routine in self.routines if routine.ticker_id == ticker_id)

    def plist_is_wrapped(self, routine: object) -> bool:
        if not os.path.lexists(routine.plist):
            return False
        payload = plistlib.loads(routine.plist.read_bytes())
        return payload.get("ProgramArguments") == routine.wrapper_arguments

    def doctor_state(self, routine: object) -> str:
        override = self.doctor_overrides.get(routine.task_id)
        if override is not None:
            return override
        is_wrapped = self.plist_is_wrapped(routine)
        has_row = routine.task_id in self.wrapped
        has_backup = routine.task_id in self.authenticated_backups
        if is_wrapped:
            if has_row and has_backup:
                return "wrapped-consistent"
            return "wrapped-missing-backup"
        return "stale-row" if has_row else "unwrapped"

    def process_output(self) -> str:
        rows = [
            f"{pid} {cutover.CLAUDE_DESKTOP_EXECUTABLE}"
            for pid in sorted(self.claude_pids)
        ]
        rows.extend(f"{pid} {command}" for pid, command in self.extra_processes)
        return "".join(row + "\n" for row in rows)

    def set_open_process_sequence(self) -> None:
        self.next_claude_pid += 1
        new_pid = self.next_claude_pid
        if self.open_process_states is None:
            self.claude_pids = {new_pid}
            self.ps_sequence = []
            return
        converted = [
            ({new_pid} if state is True else set() if state is False else set(state))
            for state in self.open_process_states
        ]
        self.ps_sequence = converted
        self.claude_pids = converted[-1] if converted else set()

    def run(self, executable: Path, arguments: list[str] | tuple[str, ...]) -> object:
        arguments = list(arguments)
        name = executable.name
        self.events.append(name + " " + " ".join(arguments))
        if name == "ps":
            if self.quit_requested:
                self.shutdown_poll_count += 1
                if self.signal_on_shutdown_poll == self.shutdown_poll_count:
                    self.signal_on_shutdown_poll = None
                    raise cutover.CutoverSignal(signal.SIGTERM)
                if self.consume_failure("shutdown-ps"):
                    return cutover.CommandResult(5, "", "injected shutdown inventory failure")
            if self.consume_failure("ps"):
                return cutover.CommandResult(5, "", "injected process inventory failure")
            if self.ps_sequence:
                self.claude_pids = set(self.ps_sequence.pop(0))
            return cutover.CommandResult(0, self.process_output(), "")
        if name == "osascript":
            if self.consume_failure("osascript"):
                return cutover.CommandResult(5, "", "injected quit failure")
            self.quit_requested = True
            self.shutdown_poll_count = 0
            if self.quit_process_sequences:
                self.ps_sequence = [set(pids) for pids in self.quit_process_sequences.pop(0)]
                self.claude_pids = self.ps_sequence[-1] if self.ps_sequence else set()
            else:
                self.claude_pids = set()
                self.ps_sequence = []
            if self.signal_after_quit:
                self.signal_after_quit = False
                raise cutover.CutoverSignal(signal.SIGTERM)
            return cutover.CommandResult(0, "", "")
        if name == "open":
            if self.open_status != 0:
                return cutover.CommandResult(self.open_status, "", "injected open failure")
            self.quit_requested = False
            self.claude_relaunched = True
            if callable(self.on_open):
                self.on_open()
            self.set_open_process_sequence()
            return cutover.CommandResult(0, "", "")
        if name == "ticker":
            command = arguments[0]
            if command == "list":
                rows = [
                    {
                        "id": routine.ticker_id,
                        "label": routine.label,
                        "source": "launchd",
                        "configPath": str(routine.plist),
                        "managed": self.plist_is_wrapped(routine),
                    }
                    for routine in self.routines
                    if os.path.lexists(routine.plist)
                ]
                return cutover.CommandResult(0, json.dumps(rows), "")
            if command == "doctor":
                if self.consume_failure("doctor"):
                    return cutover.CommandResult(5, "", "injected doctor failure")
                if arguments[1:2] == ["--clear-stale"]:
                    routine = self.routine_for_ticker_id(arguments[2])
                    if self.doctor_state(routine) != "stale-row":
                        return cutover.CommandResult(5, "", "not stale")
                    self.wrapped.discard(routine.task_id)
                    return cutover.CommandResult(0, f"{routine.ticker_id}\tunwrapped\n", "")
                output = "".join(
                    f"{routine.ticker_id}\t{self.doctor_state(routine)}\n"
                    for routine in self.routines
                    if os.path.lexists(routine.plist)
                )
                return cutover.CommandResult(0, output, "")
            routine = self.routine_for_ticker_id(arguments[1])
            if command == "wrap":
                if (
                    (self.wrap_failure_task_id is None or routine.task_id == self.wrap_failure_task_id)
                    and self.consume_failure("wrap")
                ):
                    return cutover.CommandResult(5, "", "injected wrap failure")
                if self.interrupt_wrap_after_mark:
                    self.interrupt_wrap_after_mark = False
                    self.wrapped.add(routine.task_id)
                    self.authenticated_backups.add(routine.task_id)
                    return cutover.CommandResult(5, "", "interrupted after markManaged")
                if self.raise_signal_on_wrap:
                    self.raise_signal_on_wrap = False
                    raise cutover.CutoverSignal(signal.SIGTERM)
                if not self.plist_is_wrapped(routine):
                    write_plist(routine, wrapped=True)
                self.wrapped.add(routine.task_id)
                self.authenticated_backups.add(routine.task_id)
                return cutover.CommandResult(0, "", "")
            if command == "unwrap":
                if self.consume_failure("unwrap"):
                    return cutover.CommandResult(5, "", "injected unwrap failure")
                write_plist(routine, wrapped=False)
                if self.interrupt_unwrap_after_write:
                    self.interrupt_unwrap_after_write = False
                    return cutover.CommandResult(5, "", "interrupted before unmarkManaged")
                self.wrapped.discard(routine.task_id)
                return cutover.CommandResult(0, "", "")
        if name == "launchctl":
            command = arguments[0]
            if command == "print":
                label = arguments[1].rsplit("/", 1)[-1]
                if label not in self.loaded:
                    if self.consume_failure("absence"):
                        return cutover.CommandResult(0, "path = /wrong\nprogram = /wrong\n", "")
                    return cutover.CommandResult(3, "", "Could not find service")
                routine = self.routine_for_label(label)
                return cutover.CommandResult(
                    0,
                    f"path = {routine.plist}\nprogram = {cutover.TICKER_EXECUTABLE}\n",
                    "",
                )
            if command == "bootout":
                if callable(self.on_bootout):
                    self.on_bootout()
                if self.consume_failure("bootout"):
                    return cutover.CommandResult(5, "", "injected bootout failure")
                label = arguments[1].rsplit("/", 1)[-1]
                if label in self.loaded:
                    self.loaded.remove(label)
                    return cutover.CommandResult(0, "", "")
                return cutover.CommandResult(3, "", "Could not find service")
            if command == "bootstrap":
                if self.consume_failure("bootstrap"):
                    return cutover.CommandResult(5, "", "injected bootstrap failure")
                plist_path = Path(arguments[2])
                routine = next(routine for routine in self.routines if routine.plist == plist_path)
                self.loaded.add(routine.label)
                return cutover.CommandResult(0, "", "")
        raise AssertionError(f"unexpected command: {executable} {arguments}")


class CutoverFixture:
    def __init__(self, root: Path) -> None:
        root = root.resolve(strict=True)
        self.root = root
        self.home = root / "home"
        self.codex_home = self.home / ".codex"
        self.codex_home.mkdir(parents=True)
        self.codex_home.chmod(0o700)
        (self.codex_home / "config.toml").write_text("", encoding="utf-8")
        (self.codex_home / "config.toml").chmod(0o600)
        (self.codex_home / "auth.json").write_text("{}", encoding="utf-8")
        (self.codex_home / "auth.json").chmod(0o600)

        self.working_directory = self.home / "Development" / "Skyvern-cloud"
        self.working_directory.mkdir(parents=True)
        self.sessions_root = (
            self.home
            / "Library"
            / "Application Support"
            / "Claude"
            / "claude-code-sessions"
        )
        self.registry = (
            self.sessions_root
            / "account fixture"
            / "session fixture"
            / "scheduled-tasks.json"
        )
        self.registry.parent.mkdir(parents=True)
        self.marker = Path(str(self.registry) + ".ticker-codex-SKY-14155.success")
        self.lock = self.sessions_root / ".ticker-codex-SKY-14155.lock"
        self.runner_source = root / "source" / "run-codex-scheduled-task"
        self.runner_installed = self.home / ".local" / "bin" / "run-codex-scheduled-task"
        self.ticker = root / "bin" / "ticker"
        self.codex = root / "bin" / "codex"
        self.ticker.parent.mkdir(parents=True)
        self.ticker.write_bytes(b"#!/bin/sh\nexit 0\n")
        self.ticker.chmod(0o755)
        self.codex.write_bytes(synthetic_host_native())
        self.codex.chmod(0o755)
        self.launchd_environment = {
            "HOME": str(self.home),
            "PATH": cutover.build_controlled_path(self.home, self.codex),
            "TZ": "America/New_York",
        }
        self.roots: dict[str, object] = {}
        self.routines: list[object] = []

        for production in cutover.ROUTINES:
            root_name = production.root.name
            if root_name not in self.roots:
                canonical_root = root / "canonical-skills" / root_name
                canonical_root.mkdir(parents=True)
                (canonical_root / "SKILL.md").write_text("live skill\n", encoding="utf-8")
                if production.root.kind is cutover.RootKind.PERSONAL_LINK:
                    installed_root = root / "installed-skills" / root_name
                    installed_root.parent.mkdir(parents=True, exist_ok=True)
                    installed_root.symlink_to(canonical_root, target_is_directory=True)
                else:
                    installed_root = canonical_root
                self.roots[root_name] = dataclasses.replace(
                    production.root,
                    installed_root=installed_root,
                    canonical_root=canonical_root,
                )
            label = production.label
            claude_prompt = root / "claude" / production.task_id / "SKILL.md"
            claude_prompt.parent.mkdir(parents=True)
            claude_prompt.write_text("legacy prompt\n", encoding="utf-8")
            routine = dataclasses.replace(
                production,
                claude_prompt=claude_prompt,
                plist=root / "LaunchAgents" / f"{label}.plist",
                root=self.roots[root_name],
            )
            self.routines.append(routine)
        self.routines_tuple = tuple(self.routines)

        unrelated = {
            "id": "unrelated-task",
            "enabled": False,
            "cronExpression": "7 7 * * *",
            "filePath": "/tmp/unrelated.md",
            "unrelatedField": {"preserve": True},
        }
        selected = [
            {
                "id": routine.task_id,
                "enabled": True,
                "cronExpression": routine.legacy_cron,
                "filePath": str(routine.claude_prompt),
                "lastRun": f"keep-{routine.task_id}",
            }
            for routine in self.routines
        ]
        self.registry.write_text(
            json.dumps({"scheduledTasks": [unrelated, *selected], "topLevel": "preserve"}),
            encoding="utf-8",
        )
        self.registry.chmod(0o600)

        self.runner_source.parent.mkdir(parents=True)
        self.runner_source.write_bytes(b"#!/bin/sh\nexit 0\n")
        self.runner_source.chmod(0o755)
        self.runner_installed.parent.mkdir(parents=True)

        self.commands = FakeCommandRunner(self.routines_tuple)
        self.stack = ExitStack()

    def __enter__(self) -> "CutoverFixture":
        runtime_roots = tuple(self.roots.values())
        replacements = {
            "HOME_DIRECTORY": self.home,
            "WORKING_DIRECTORY": self.working_directory,
            "REGISTRY": self.registry,
            "TRANSACTION_LOCK": self.lock,
            "SUCCESS_MARKER": self.marker,
            "RUNNER_SOURCE": self.runner_source,
            "RUNNER_INSTALLED": self.runner_installed,
            "TICKER_EXECUTABLE": self.ticker,
            "CODEX_EXECUTABLE": self.codex,
            "LAUNCHD_ENVIRONMENT": self.launchd_environment,
            "_ROOTS": runtime_roots,
            "DAILY_SUMMARY_ROOT": runtime_roots[0],
            "VITALS_ROOT": runtime_roots[1],
            "LINKEDIN_ROOT": runtime_roots[2],
            "OVERDUE_ROOT": runtime_roots[3],
            "TEAM_DIGEST_ROOT": runtime_roots[4],
            "ROUTINES": self.routines_tuple,
        }
        if hasattr(cutover, "SESSIONS_ROOT"):
            replacements["SESSIONS_ROOT"] = self.sessions_root
        for name, value in replacements.items():
            self.stack.enter_context(mock.patch.object(cutover, name, value))
        self.stack.enter_context(mock.patch.object(cutover.os, "getuid", return_value=os.getuid()))
        self.stack.enter_context(
            mock.patch.object(
                cutover.pwd,
                "getpwuid",
                return_value=SimpleNamespace(pw_dir=str(self.home)),
            )
        )
        self.stack.enter_context(mock.patch.object(cutover.time, "sleep", return_value=None))
        return self

    def __exit__(self, *args: object) -> None:
        self.stack.close()

    def transaction(self) -> object:
        return cutover.CutoverTransaction(
            self.routines_tuple,
            command_runner=self.commands,
            clock=lambda: dt.datetime(2026, 8, 15, 10, 30, tzinfo=cutover.NEW_YORK),
        )

    def make_codex(self, directory_name: str) -> Path:
        executable = self.root / directory_name / "codex"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(synthetic_host_native())
        executable.chmod(0o755)
        return executable

    def binding_payload(self, *, codex: Path | None = None) -> dict[str, object]:
        selected_codex = self.codex if codex is None else codex
        return {
            "binding_version": 2,
            "uid": os.getuid(),
            "home": str(self.home),
            "repository": str(self.working_directory),
            "python": sys.executable,
            "codex": str(selected_codex),
            "codex_home": str(self.codex_home),
            "path": self.launchd_environment["PATH"],
            "model": "gpt-5.6-sol",
            "skill_roots": {
                routine.task_id: str(routine.root.canonical_root)
                for routine in self.routines
            },
            "codex_sha256": native_digest(selected_codex),
            "codex_macho_arch": host_native_arch(),
            "codex_managed_by": "direct",
            "codex_managed_package_root": None,
            "codex_managed_package_version": None,
        }

    def install_bound_runner(self) -> None:
        binding = self.binding_payload()
        self.runner_installed.write_bytes(
            bind_generated_runner(self.runner_source.read_bytes(), binding)
        )
        self.runner_installed.chmod(0o755)


    def run_main(
        self,
        arguments: list[str],
        path_value: str,
        transaction_factory: object | None = None,
    ) -> tuple[int, list[object], object]:
        transactions: list[object] = []
        transaction_class = cutover.CutoverTransaction

        if transaction_factory is None:
            def build_transaction(
                routines: object = None,
                **_kwargs: object,
            ) -> object:
                selected_routines = cutover.ROUTINES if routines is None else routines
                transaction = transaction_class(
                    selected_routines,
                    command_runner=self.commands,
                    clock=lambda: dt.datetime(
                        2026,
                        8,
                        15,
                        10,
                        30,
                        tzinfo=cutover.NEW_YORK,
                    ),
                )
                transactions.append(transaction)
                return transaction

            factory = build_transaction
        else:
            factory = transaction_factory

        runtime_roots = tuple(self.roots.values())
        with mock.patch.dict(
            cutover.os.environ,
            {"HOME": str(self.home), "PATH": path_value},
            clear=False,
        ), mock.patch.object(
            cutover,
            "_build_routines",
            return_value=(runtime_roots, self.routines_tuple),
        ), mock.patch.object(
            cutover,
            "CutoverTransaction",
            side_effect=factory,
        ) as patched_factory:
            result = cutover.main(arguments)
        return result, transactions, patched_factory

    def registry_document(self) -> dict[str, object]:
        return json.loads(self.registry.read_text(encoding="utf-8"))

    def selected_enabled(self) -> dict[str, bool]:
        rows = self.registry_document()["scheduledTasks"]
        task_ids = {routine.task_id for routine in self.routines}
        return {row["id"]: row["enabled"] for row in rows if row.get("id") in task_ids}

    def assert_claude_state(self, testcase: unittest.TestCase) -> None:
        testcase.assertEqual(set(self.selected_enabled().values()), {True})
        testcase.assertEqual(self.commands.loaded, set())
        testcase.assertEqual(self.commands.wrapped, set())
        testcase.assertFalse(self.marker.exists())
        testcase.assertTrue(self.commands.claude_running)
        for routine in self.routines:
            testcase.assertFalse(os.path.lexists(routine.plist))

    def assert_codex_state(self, testcase: unittest.TestCase) -> None:
        task_ids = {routine.task_id for routine in self.routines}
        testcase.assertEqual(set(self.selected_enabled().values()), {False})
        testcase.assertEqual(self.commands.loaded, {routine.label for routine in self.routines})
        testcase.assertEqual(self.commands.wrapped, task_ids)
        testcase.assertEqual(self.commands.authenticated_backups, task_ids)
        testcase.assertEqual(
            {self.commands.doctor_state(routine) for routine in self.routines},
            {"wrapped-consistent"},
        )
        testcase.assertEqual(self.marker.read_bytes(), cutover.MARKER_PAYLOAD)
        testcase.assertFalse(self.commands.claude_running)
        for routine in self.routines:
            cutover.validate_plist(routine, wrapped=True)

    def prepare_partial(self, *, generated: int, wrapped: int, loaded: int) -> None:
        self.install_bound_runner()
        cutover.publish_registry_enabled(False, self.routines_tuple, required_before=True)
        for routine in self.routines[:generated]:
            cutover.write_replacement_plist(routine)
        for routine in self.routines[:wrapped]:
            result = self.commands.run(cutover.TICKER_EXECUTABLE, ["wrap", routine.ticker_id])
            assert result.status == 0
        for routine in self.routines[:loaded]:
            result = self.commands.run(
                cutover.LAUNCHCTL,
                ["bootstrap", f"gui/{os.getuid()}", str(routine.plist)],
            )
            assert result.status == 0
        self.commands.claude_running = False

    def prepare_state(
        self,
        *,
        plist_states: list[str],
        loaded: int,
        registry_enabled: bool,
        marker_exact: bool,
    ) -> None:
        self.install_bound_runner()
        if not registry_enabled:
            cutover.publish_registry_enabled(False, self.routines_tuple, required_before=True)
        if len(self.routines) != len(plist_states):
            raise ValueError("fixture plist state count does not match routine count")
        for routine, state in zip(self.routines, plist_states):
            if state == "original":
                write_plist(routine, wrapped=False)
            elif state == "wrapped":
                write_plist(routine, wrapped=True)
                self.commands.wrapped.add(routine.task_id)
                self.commands.authenticated_backups.add(routine.task_id)
            elif state != "absent":
                raise AssertionError(f"unknown fixture plist state: {state}")
        self.commands.loaded = {routine.label for routine in self.routines[:loaded]}
        if marker_exact:
            self.marker.write_bytes(cutover.MARKER_PAYLOAD)
            self.marker.chmod(0o600)
        self.commands.claude_running = False

    def assert_no_engine_mutation(self, testcase: unittest.TestCase) -> None:
        testcase.assertFalse(any(event.startswith("osascript ") for event in self.commands.events))
        testcase.assertFalse(any(event.startswith("open ") for event in self.commands.events))
        testcase.assertFalse(any(event.startswith("launchctl bootout") for event in self.commands.events))
        testcase.assertFalse(any(event.startswith("launchctl bootstrap") for event in self.commands.events))


class StaticContractTests(unittest.TestCase):
    maxDiff = None

    def test_migration_script_uses_isolated_python_shebang(self) -> None:
        self.assertEqual(
            SCRIPT.read_text(encoding="utf-8").splitlines()[0],
            "#!/usr/bin/python3 -I",
        )

    def test_six_routine_table_preserves_cron_calendar_ticker_and_arguments(self) -> None:
        self.assertEqual({routine.task_id for routine in cutover.ROUTINES}, set(EXPECTED))
        for routine in cutover.ROUTINES:
            with self.subTest(task_id=routine.task_id):
                cron, calendar, ticker_suffix = EXPECTED[routine.task_id]
                self.assertEqual(routine.legacy_cron, cron)
                self.assertEqual(routine.calendar, calendar)
                self.assertEqual(
                    routine.ticker_id,
                    f"launchd:{routine.label}#{ticker_suffix}",
                )
                self.assertTrue(cutover.cron_matches_calendar(cron, calendar))
                self.assertEqual(
                    routine.original_arguments,
                    [
                        str(cutover.RUNNER_INSTALLED),
                        routine.task_id,
                        str(cutover.WORKING_DIRECTORY),
                    ],
                )

    def test_legacy_three_argument_inner_argv_and_outer_wrapper_are_unchanged(self) -> None:
        for routine in cutover.ROUTINES:
            with self.subTest(task_id=routine.task_id):
                self.assertEqual(
                    routine.original_arguments,
                    [
                        str(cutover.RUNNER_INSTALLED),
                        routine.task_id,
                        str(cutover.WORKING_DIRECTORY),
                    ],
                )
                self.assertEqual(routine.wrapper_arguments[-3:], routine.original_arguments)
                self.assertEqual(
                    routine.wrapper_arguments[:7],
                    [
                        str(cutover.TICKER_EXECUTABLE),
                        "run",
                        "--ticker-wrapper-version",
                        "1",
                        "--label",
                        routine.ticker_id,
                        "--",
                    ],
                )

    def test_generated_plists_preserve_exact_contract_without_run_at_load(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            routines = tuple(
                dataclasses.replace(routine, plist=root / routine.plist.name)
                for routine in cutover.ROUTINES
            )
            launchd_environment = {
                "HOME": str(cutover.HOME_DIRECTORY),
                "PATH": "/usr/bin:/bin",
                "TZ": "America/New_York",
            }
            with mock.patch.object(
                cutover,
                "LAUNCHD_ENVIRONMENT",
                launchd_environment,
            ):
                cutover.write_replacement_plists(routines)
                for routine in routines:
                    with self.subTest(task_id=routine.task_id):
                        cutover.validate_plist(routine, wrapped=False)
                        payload = cutover.parse_plist(routine.plist)
                        self.assertEqual(payload["ProgramArguments"], routine.original_arguments)
                        self.assertEqual(payload["StartCalendarInterval"], routine.calendar)
                        self.assertNotIn("RunAtLoad", payload)
                        metadata = routine.plist.stat()
                        self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o644)
                        self.assertEqual(metadata.st_uid, os.getuid())

    def test_controlled_path_filters_optional_candidates_and_keeps_required_codex_parent(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            home = root / "home"
            home.mkdir()
            codex_parent = root / "codex" / "bin"
            codex_parent.mkdir(parents=True)
            codex = codex_parent / "codex"
            codex.write_bytes(synthetic_host_native())
            codex.chmod(0o755)

            safe = root / "safe optional"
            safe.mkdir()
            safe.chmod(0o755)
            group_writable = root / "group writable optional"
            group_writable.mkdir()
            group_writable.chmod(0o775)
            other_writable = root / "other writable optional"
            other_writable.mkdir()
            other_writable.chmod(0o757)
            absent = root / "absent optional"

            builder = getattr(cutover, "build_controlled_path", None)
            self.assertIsNotNone(
                builder,
                "RED contract missing build_controlled_path(home, codex, optional_candidates=None)",
            )
            assert builder is not None
            controlled_path = builder(
                home,
                codex,
                optional_candidates=(
                    safe,
                    absent,
                    group_writable,
                    other_writable,
                    safe,
                    codex_parent,
                ),
            )

            self.assertEqual(
                controlled_path.split(":"),
                [str(codex_parent), str(safe)],
            )

    def test_personal_links_and_direct_roots_have_distinct_preflight_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            canonical = root / "canonical" / "personal"
            canonical.mkdir(parents=True)
            (canonical / "SKILL.md").write_text("personal\n", encoding="utf-8")
            installed = root / "installed" / "personal"
            installed.parent.mkdir()
            installed.symlink_to(canonical, target_is_directory=True)
            direct = root / "project" / "direct"
            direct.mkdir(parents=True)
            (direct / "SKILL.md").write_text("direct\n", encoding="utf-8")
            roots = (
                cutover.SkillRoot("personal", installed, canonical, cutover.RootKind.PERSONAL_LINK),
                cutover.SkillRoot("direct", direct, direct, cutover.RootKind.DIRECT_PROJECT),
            )
            cutover.validate_skill_roots(roots)
            installed.unlink()
            installed.symlink_to(direct, target_is_directory=True)
            with self.assertRaisesRegex(cutover.CutoverError, "canonical target"):
                cutover.validate_skill_roots(roots)

    def test_native_codex_validation_rejects_js_wrappers_and_unsafe_targets(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            codex_leaf = (
                root / "lib" / "node_modules" / "@openai" / "codex" / "bin" / "codex"
            )
            codex_leaf.parent.mkdir(parents=True)
            codex_leaf.write_bytes(synthetic_host_native())
            codex_leaf.chmod(0o755)
            codex_link = bin_directory / "codex"
            codex_link.symlink_to("../lib/node_modules/@openai/codex/bin/codex")

            cutover.validate_executable(codex_link, "Codex executable")

            js_leaf = codex_leaf.with_name("codex.js")
            js_leaf.write_bytes(b"#!/usr/bin/env node\n")
            js_leaf.chmod(0o755)
            js_directory = root / "js bin"
            js_directory.mkdir()
            (js_directory / "codex").symlink_to(
                "../lib/node_modules/@openai/codex/bin/codex.js"
            )
            resolver = getattr(
                cutover,
                "resolve_native_codex",
                cutover.discover_codex_executable,
            )
            with self.assertRaises(cutover.CutoverError):
                resolver(str(js_directory))

            direct = bin_directory / "direct"
            direct.write_bytes(b"#!/bin/sh\n")
            direct.chmod(0o755)
            cutover.validate_executable(direct, "direct executable")

            broken = bin_directory / "broken"
            broken.symlink_to("../lib/node_modules/@openai/codex/bin/missing.js")
            with self.assertRaisesRegex(cutover.CutoverError, "does not resolve"):
                cutover.validate_executable(broken, "broken executable")

            directory_target = codex_leaf.parent / "directory-target"
            directory_target.mkdir()
            directory_link = bin_directory / "directory-target"
            directory_link.symlink_to(
                "../lib/node_modules/@openai/codex/bin/directory-target"
            )
            with self.assertRaisesRegex(cutover.CutoverError, "not a regular file"):
                cutover.validate_executable(directory_link, "directory executable")

            non_executable = codex_leaf.parent / "non-executable.js"
            non_executable.write_bytes(b"#!/usr/bin/env node\n")
            non_executable.chmod(0o600)
            non_executable_link = bin_directory / "non-executable"
            non_executable_link.symlink_to(
                "../lib/node_modules/@openai/codex/bin/non-executable.js"
            )
            with self.assertRaisesRegex(
                cutover.CutoverError,
                "not readable and executable",
            ):
                cutover.validate_executable(
                    non_executable_link,
                    "non-executable target",
                )

            unsafe_target = codex_leaf.parent / "unsafe-target"
            os.mkfifo(unsafe_target)
            unsafe_link = bin_directory / "unsafe"
            unsafe_link.symlink_to("../lib/node_modules/@openai/codex/bin/unsafe-target")
            with self.assertRaisesRegex(cutover.CutoverError, "not a regular file"):
                cutover.validate_executable(unsafe_link, "unsafe executable")

    def test_sessions_root_lock_contention_precedes_registry_and_codex_discovery(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                registry_before = fixture.registry.read_bytes()
                claude_pids_before = set(fixture.commands.claude_pids)
                transaction = mock.Mock()
                transaction.execute.return_value = mock.Mock(recovered=False)
                transaction_factory = mock.Mock(return_value=transaction)
                real_registry_discovery = cutover.discover_claude_registry
                real_codex_discovery = cutover.discover_codex_executable

                with cutover.migration_transaction_lock():
                    lock_metadata = fixture.lock.lstat()
                    self.assertTrue(stat.S_ISREG(lock_metadata.st_mode))
                    self.assertEqual(lock_metadata.st_uid, os.getuid())
                    self.assertEqual(stat.S_IMODE(lock_metadata.st_mode), 0o600)

                    with mock.patch.object(
                        cutover,
                        "discover_claude_registry",
                        wraps=real_registry_discovery,
                    ) as registry_discovery, mock.patch.object(
                        cutover,
                        "discover_codex_executable",
                        wraps=real_codex_discovery,
                    ) as codex_discovery, mock.patch.object(
                        cutover.sys,
                        "stderr",
                        io.StringIO(),
                    ) as error_output:
                        result, _transactions, factory = fixture.run_main(
                            [],
                            str(fixture.codex.parent),
                            transaction_factory,
                        )

                self.assertEqual(result, 1)
                self.assertIn(
                    f"cutover failed: {cutover.TICKET} migration transaction "
                    f"is already running: {fixture.lock}",
                    error_output.getvalue(),
                )
                registry_discovery.assert_not_called()
                codex_discovery.assert_not_called()
                factory.assert_not_called()
                transaction_factory.assert_not_called()
                self.assertEqual(fixture.registry.read_bytes(), registry_before)
                self.assertEqual(fixture.commands.events, [])
                self.assertEqual(fixture.commands.claude_pids, claude_pids_before)
                self.assertFalse(fixture.marker.exists())
                self.assertFalse(fixture.runner_installed.exists())
                for routine in fixture.routines:
                    self.assertFalse(os.path.lexists(routine.plist))

    def test_registry_updates_only_selected_enabled_flags(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                original = fixture.registry_document()
                disabled = json.loads(
                    cutover.registry_with_selected_enabled(
                        fixture.registry.read_bytes(), False, fixture.routines_tuple
                    )
                )
                enabled = json.loads(
                    cutover.registry_with_selected_enabled(
                        (json.dumps(disabled) + "\n").encode("utf-8"),
                        True,
                        fixture.routines_tuple,
                    )
                )
                original_rows = {row["id"]: row for row in original["scheduledTasks"]}
                disabled_rows = {row["id"]: row for row in disabled["scheduledTasks"]}
                enabled_rows = {row["id"]: row for row in enabled["scheduledTasks"]}
                self.assertEqual(disabled["topLevel"], "preserve")
                self.assertEqual(disabled_rows["unrelated-task"], original_rows["unrelated-task"])
                for routine in fixture.routines:
                    before = dict(original_rows[routine.task_id])
                    before.pop("enabled")
                    after = dict(disabled_rows[routine.task_id])
                    self.assertFalse(after.pop("enabled"))
                    self.assertEqual(after, before)
                    self.assertTrue(enabled_rows[routine.task_id]["enabled"])

    def test_computed_blackout_rejects_near_fire_and_allows_safe_time(self) -> None:
        zone = cutover.NEW_YORK
        with self.assertRaisesRegex(cutover.CutoverError, "blackout"):
            cutover.check_blackout(dt.datetime(2026, 8, 15, 11, 50, tzinfo=zone))
        cutover.check_blackout(dt.datetime(2026, 8, 15, 10, 30, tzinfo=zone))

    def test_home_binding_rejects_uid_mismatch_symlink_colon_and_unsafe_parent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            canonical_home = root / "canonical home"
            canonical_home.mkdir()
            home_link = root / "home link"
            home_link.symlink_to(canonical_home, target_is_directory=True)
            alternate_home = root / "alternate home"
            alternate_home.mkdir()
            colon_home = root / "home:with-colon"
            colon_home.mkdir()
            writable_parent = root / "writable parent"
            writable_parent.mkdir()
            writable_parent.chmod(0o777)
            writable_home = writable_parent / "home"
            writable_home.mkdir()

            with mock.patch.object(
                cutover,
                "pwd",
                SimpleNamespace(
                    getpwuid=lambda _uid: SimpleNamespace(pw_dir=str(canonical_home))
                ),
                create=True,
            ):
                self.assertEqual(
                    cutover.home_from_environment({"HOME": str(canonical_home)}),
                    canonical_home,
                )
                for label, value in (
                    ("uid mismatch", alternate_home),
                    ("symlink", home_link),
                    ("colon", colon_home),
                    ("writable parent", writable_home),
                ):
                    with self.subTest(label=label):
                        with self.assertRaises(cutover.CutoverError):
                            cutover.home_from_environment({"HOME": str(value)})

        for environment in ({}, {"HOME": ""}, {"HOME": "relative home"}, {"HOME": "a\0b"}):
            with self.subTest(environment=environment):
                with self.assertRaises(cutover.CutoverError):
                    cutover.home_from_environment(environment)

    def test_runner_source_is_derived_from_migration_script_location(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            script = (
                Path(directory).resolve(strict=True)
                / "checkout with spaces"
                / "Scripts"
                / "migrate-claude-routines-to-codex.py"
            )
            script.parent.mkdir(parents=True)
            script.write_text("# synthetic migration script\n", encoding="utf-8")
            self.assertEqual(
                cutover.runner_source_from_script(script),
                script.with_name("run-codex-scheduled-task"),
            )

    def test_official_npm_resolution_requires_exact_platform_topology(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            package_root = root / "npm package"
            platform_name = (
                "codex-darwin-arm64"
                if host_native_arch() == "arm64"
                else "codex-darwin-x64"
            )
            vendor_target = (
                "aarch64-apple-darwin"
                if host_native_arch() == "arm64"
                else "x86_64-apple-darwin"
            )
            platform_package = (
                package_root / "node_modules" / "@openai" / platform_name
            )
            native = (
                platform_package
                / "vendor"
                / vendor_target
                / "bin"
                / "codex"
            )
            js_entrypoint = package_root / "bin" / "codex.js"
            native.parent.mkdir(parents=True)
            js_entrypoint.parent.mkdir(parents=True)
            package_version = "0.147.0"
            platform_suffix = platform_name.removeprefix("codex-")
            platform_version = f"{package_version}-{platform_suffix}"
            platform_os, platform_cpu = platform_suffix.split("-", 1)
            platform_dependency_key = f"@openai/{platform_name}"
            platform_dependency = f"npm:@openai/codex@{platform_version}"
            wrong_platform_suffix = (
                "darwin-x64" if platform_suffix == "darwin-arm64" else "darwin-arm64"
            )
            (package_root / "package.json").write_text(
                json.dumps(
                    {
                        "name": "@openai/codex",
                        "version": package_version,
                        "bin": {"codex": "bin/codex.js"},
                        "optionalDependencies": {
                            platform_dependency_key: platform_dependency
                        },
                    }
                ),
                encoding="utf-8",
            )
            (platform_package / "package.json").write_text(
                json.dumps(
                    {
                        "name": "@openai/codex",
                        "version": platform_version,
                        "os": [platform_os],
                        "cpu": [platform_cpu],
                    }
                ),
                encoding="utf-8",
            )
            js_entrypoint.write_text(
                "#!/usr/bin/env node\n"
                "// decoy: /tmp/not-the-native/codex\n"
                "if (false) { require('/tmp/not-the-native/codex'); }\n",
                encoding="utf-8",
            )
            js_entrypoint.chmod(0o755)
            native.write_bytes(synthetic_host_macho())
            native.chmod(0o755)

            resolver = getattr(cutover, "resolve_native_codex", None)
            self.assertIsNotNone(
                resolver,
                "RED contract missing resolve_native_codex(environment)",
            )
            assert resolver is not None

            def resolve(environment: dict[str, str]) -> object:
                with mock.patch.object(cutover.sys, "platform", "darwin"):
                    return resolver(environment)

            def resolved_path(value: object) -> Path:
                path = getattr(value, "path", getattr(value, "native_path", value))
                return Path(str(path))

            with self.assertRaises(cutover.CutoverError):
                resolve({"PATH": str(native.parent)})
            with self.assertRaises(cutover.CutoverError):
                resolve(
                    {
                        "CODEX_NATIVE_PATH": str(native),
                        "CODEX_PACKAGE_ROOT": str(package_root),
                    }
                )

            direct = resolve({"CODEX_NATIVE_PATH": str(native)})
            self.assertEqual(resolved_path(direct), native)
            self.assertEqual(getattr(direct, "managed_by", "direct"), "direct")

            npm = resolve({"CODEX_PACKAGE_ROOT": str(package_root)})
            self.assertEqual(resolved_path(npm), native)
            self.assertEqual(getattr(npm, "managed_by", None), "npm")
            self.assertEqual(getattr(npm, "package_root", package_root), package_root)
            self.assertEqual(getattr(npm, "package_version", None), package_version)

            def assert_topology_rejected() -> None:
                with self.assertRaises(cutover.CutoverError):
                    resolve({"CODEX_PACKAGE_ROOT": str(package_root)})

            for mutation in (
                lambda: (package_root / "package.json").write_text(
                    json.dumps(
                        {
                            "name": "@openai/not-codex",
                            "version": package_version,
                            "bin": {"codex": "bin/codex.js"},
                            "optionalDependencies": {
                                platform_dependency_key: platform_dependency
                            },
                        }
                    ),
                    encoding="utf-8",
                ),
                lambda: (package_root / "package.json").write_text(
                    json.dumps(
                        {
                            "name": "@openai/codex",
                            "version": "9.9.9",
                            "bin": {"codex": "bin/codex.js"},
                            "optionalDependencies": {
                                platform_dependency_key: platform_dependency
                            },
                        }
                    ),
                    encoding="utf-8",
                ),
                lambda: (package_root / "package.json").write_text(
                    json.dumps(
                        {
                            "name": "@openai/codex",
                            "version": package_version,
                            "bin": {"codex": "bin/other.js"},
                            "optionalDependencies": {
                                platform_dependency_key: platform_dependency
                            },
                        }
                    ),
                    encoding="utf-8",
                ),
                lambda: (package_root / "package.json").write_text(
                    json.dumps(
                        {
                            "name": "@openai/codex",
                            "version": package_version,
                            "bin": {"codex": "bin/codex.js"},
                            "optionalDependencies": {
                                platform_dependency_key: (
                                    f"npm:@openai/not-codex@{platform_version}"
                                )
                            },
                        }
                    ),
                    encoding="utf-8",
                ),
            ):
                mutation()
                assert_topology_rejected()

            (package_root / "package.json").write_text(
                json.dumps(
                    {
                        "name": "@openai/codex",
                        "version": package_version,
                        "bin": {"codex": "bin/codex.js"},
                        "optionalDependencies": {},
                    }
                ),
                encoding="utf-8",
            )
            assert_topology_rejected()

            (package_root / "package.json").write_text(
                json.dumps(
                    {
                        "name": "@openai/codex",
                        "version": package_version,
                        "bin": {"codex": "bin/codex.js"},
                        "optionalDependencies": {
                            platform_dependency_key: platform_dependency
                        },
                    }
                ),
                encoding="utf-8",
            )
            platform_metadata = platform_package / "package.json"
            platform_metadata.write_text(
                json.dumps(
                    {
                        "name": f"@openai/{platform_name}",
                        "version": package_version,
                        "os": [platform_os],
                        "cpu": [platform_cpu],
                    }
                ),
                encoding="utf-8",
            )
            assert_topology_rejected()
            platform_metadata.write_text(
                json.dumps(
                    {
                        "name": "@openai/codex",
                        "version": f"{package_version}-{wrong_platform_suffix}",
                        "os": [platform_os],
                        "cpu": [platform_cpu],
                    }
                ),
                encoding="utf-8",
            )
            assert_topology_rejected()
            platform_metadata.write_text(
                json.dumps(
                    {
                        "name": "@openai/codex",
                        "version": platform_version,
                        "os": [platform_os],
                        "cpu": [platform_cpu],
                    }
                ),
                encoding="utf-8",
            )

            native.unlink()
            hoisted = package_root / "node_modules" / platform_name / "bin" / "codex"
            hoisted.parent.mkdir(parents=True, exist_ok=True)
            hoisted.write_bytes(synthetic_host_macho())
            hoisted.chmod(0o755)
            assert_topology_rejected()
            hoisted.unlink()

            outside = root / "outside" / "codex"
            outside.parent.mkdir()
            outside.write_bytes(synthetic_host_macho())
            outside.chmod(0o755)
            native.parent.mkdir(parents=True, exist_ok=True)
            native.symlink_to(outside)
            assert_topology_rejected()
            native.unlink()
            native.write_bytes(synthetic_host_macho())
            native.chmod(0o755)

            decoy = root / "decoy-wrapper"
            decoy.write_text(
                "#!/bin/sh\n"
                "# exec /tmp/not-the-native/codex\n"
                "if false; then exec /tmp/not-the-native/codex; fi\n",
                encoding="utf-8",
            )
            decoy.chmod(0o755)
            with self.assertRaises(cutover.CutoverError):
                resolve({"CODEX_NATIVE_PATH": str(decoy)})

    def test_official_codex_selection_ignores_inherited_path_and_requires_explicit_native(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                rogue_directory = fixture.root / "rogue PATH first"
                rogue_directory.mkdir()
                rogue = rogue_directory / "codex"
                rogue.write_bytes(synthetic_host_native())
                rogue.chmod(0o755)
                resolver = getattr(cutover, "resolve_native_codex", None)
                self.assertIsNotNone(
                    resolver,
                    "RED contract missing explicit native resolver",
                )
                assert resolver is not None
                cutover.CODEX_EXECUTABLE = None
                cutover.CODEX_MANAGED_PACKAGE_ROOT = None
                cutover.CODEX_MANAGED_BY = None
                selection = {
                    "HOME": str(fixture.home),
                    "PATH": f"{rogue_directory}:{fixture.codex.parent}",
                }
                with self.assertRaises(cutover.CutoverError):
                    resolver(selection)
                self.assertIsNone(cutover.CODEX_EXECUTABLE)
                self.assertFalse(fixture.runner_installed.exists())
                self.assertFalse(fixture.marker.exists())
                self.assertEqual(fixture.commands.events, [])
                self.assertEqual(
                    [os.path.lexists(routine.plist) for routine in fixture.routines],
                    [False] * 6,
                )

                resolved = resolver(
                    {
                        "HOME": str(fixture.home),
                        "PATH": str(rogue_directory),
                        "CODEX_NATIVE_PATH": str(fixture.codex),
                    }
                )
                resolved_path = Path(
                    str(getattr(resolved, "path", getattr(resolved, "native_path", resolved)))
                )
                self.assertEqual(resolved_path, fixture.codex)
                self.assertEqual(getattr(resolved, "managed_by", "direct"), "direct")
                self.assertEqual(getattr(resolved, "package_root", None), None)
                self.assertNotIn("SUPERSET", repr(resolved))

    def test_full_macho_validation_rejects_truncated_wrong_arch_and_wrong_filetype(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            inspector = getattr(cutover, "inspect_native_codex", None)
            self.assertIsNotNone(
                inspector,
                "RED contract missing inspect_native_codex(path, expected_arch)",
            )
            assert inspector is not None

            def candidate(name: str, payload: bytes) -> Path:
                path = root / name
                path.write_bytes(payload)
                path.chmod(0o755)
                return path

            valid = candidate("valid", synthetic_host_macho())
            with mock.patch.object(cutover.sys, "platform", "darwin"):
                identity = inspector(valid, host_native_arch())
            self.assertEqual(Path(str(identity.path)), valid)
            self.assertEqual(identity.arch, host_native_arch())
            self.assertEqual(identity.sha256, native_digest(valid))
            malformed_fat = struct.pack(
                ">IIiiIII",
                0xCAFEBABE,
                1,
                0x0100000C,
                0,
                0xFFFFFF00,
                0x100,
                0,
            )
            wrong_arch = "x86_64" if host_native_arch() == "arm64" else "arm64"
            fixtures = {
                "magic-only": b"\xcf\xfa\xed\xfe",
                "truncated": synthetic_host_macho()[:16],
                "wrong-arch": synthetic_host_macho(arch=wrong_arch),
                "malformed-fat": malformed_fat,
                "wrong-filetype": synthetic_host_macho(filetype=1),
            }
            for name, payload in fixtures.items():
                with self.subTest(candidate=name):
                    path = candidate(name, payload)
                    with self.assertRaises(cutover.CutoverError):
                        with mock.patch.object(cutover.sys, "platform", "darwin"):
                            inspector(path, host_native_arch())
                    with self.assertRaises(cutover.CutoverError):
                        resolver = getattr(cutover, "resolve_native_codex", None)
                        self.assertIsNotNone(resolver)
                        assert resolver is not None
                        with mock.patch.object(cutover.sys, "platform", "darwin"):
                            resolver({"CODEX_NATIVE_PATH": str(path)})

    def test_registry_discovery_selects_the_only_structural_match(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve(strict=True) / "home with spaces"
            sessions = (
                home
                / "Library"
                / "Application Support"
                / "Claude"
                / "claude-code-sessions"
            )
            routines = synthetic_discovery_routines(home)
            unrelated = sessions / "account unrelated" / "session unrelated" / "scheduled-tasks.json"
            matching = sessions / "account matching" / "session matching" / "scheduled-tasks.json"
            write_registry(unrelated, ())
            write_registry(matching, routines)

            self.assertEqual(
                cutover.discover_claude_registry(home, routines),
                matching,
            )

    def test_registry_discovery_rejects_partial_and_ambiguous_matches(self) -> None:
        with self.subTest(case="partial"), tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve(strict=True) / "home with spaces"
            sessions = (
                home
                / "Library"
                / "Application Support"
                / "Claude"
                / "claude-code-sessions"
            )
            routines = synthetic_discovery_routines(home)
            partial = sessions / "account partial" / "session partial" / "scheduled-tasks.json"
            write_registry(partial, routines[:1])
            write_registry(
                sessions / "account complete" / "session complete" / "scheduled-tasks.json",
                routines,
            )

            with self.assertRaises(cutover.CutoverError):
                cutover.discover_claude_registry(home, routines)

        with self.subTest(case="ambiguous"), tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve(strict=True) / "home with spaces"
            sessions = (
                home
                / "Library"
                / "Application Support"
                / "Claude"
                / "claude-code-sessions"
            )
            routines = synthetic_discovery_routines(home)
            write_registry(
                sessions / "account first" / "session first" / "scheduled-tasks.json",
                routines,
            )
            write_registry(
                sessions / "account second" / "session second" / "scheduled-tasks.json",
                routines,
            )

            with self.assertRaisesRegex(cutover.CutoverError, "(?i:ambiguous|multiple)"):
                cutover.discover_claude_registry(home, routines)

    def test_repository_sources_contain_no_absolute_macos_user_paths_or_uuid_literals(
        self,
    ) -> None:
        sources = (
            SCRIPT,
            RUNNER,
            Path(__file__).resolve(),
            REPO / "Tests" / "test_run_codex_scheduled_task.py",
        )
        macos_user_prefix = "/" + "Users" + "/"
        uuid_pattern = re.compile(
            r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
            r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
        )
        violations: dict[str, list[str]] = {}
        for source in sources:
            matches = [
                f"{line_number}:{line}"
                for line_number, line in enumerate(
                    source.read_text(encoding="utf-8").splitlines(),
                    start=1,
                )
                if macos_user_prefix in line or uuid_pattern.search(line)
            ]
            if matches:
                violations[str(source.relative_to(REPO))] = matches

        self.assertEqual(violations, {})

    def test_trusted_read_returns_bytes_from_one_validated_descriptor(self) -> None:
        open_chain = getattr(cutover, "open_trusted_directory_chain", None)
        open_regular = getattr(cutover, "open_trusted_regular_at", None)
        read_descriptor = getattr(cutover, "read_open_descriptor", None)
        self.assertIsNotNone(open_chain, "RED contract missing trusted directory open")
        self.assertIsNotNone(open_regular, "RED contract missing trusted regular open")
        self.assertIsNotNone(read_descriptor, "RED contract missing descriptor reader")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            target = root / "state"
            original = b"validated original bytes\n"
            replacement = b"pathname replacement bytes\n"
            target.write_bytes(original)
            target.chmod(0o600)
            parent_handle = open_chain(root, os.getuid(), "state parent")
            parent_fd = (
                parent_handle.fileno()
                if hasattr(parent_handle, "fileno")
                else int(parent_handle)
            )
            file_handle = open_regular(
                parent_fd,
                target.name,
                os.getuid(),
                0o600,
                "state",
            )
            target.unlink()
            target.write_bytes(replacement)
            target.chmod(0o600)
            try:
                self.assertEqual(read_descriptor(file_handle, "state"), original)
            finally:
                for handle in (file_handle, parent_handle):
                    close = getattr(handle, "close", None)
                    if callable(close):
                        close()
                    elif isinstance(handle, int):
                        os.close(handle)

    def test_runner_install_rejects_path_swap_between_validation_and_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                malicious = b"malicious runner bytes\n"
                real_regular = cutover._regular_file

                def swap_after_validation(path: Path, description: str) -> object:
                    metadata = real_regular(path, description)
                    if path == fixture.runner_source:
                        path.write_bytes(malicious)
                        path.chmod(0o755)
                    return metadata

                with mock.patch.object(
                    cutover,
                    "_regular_file",
                    side_effect=swap_after_validation,
                ):
                    try:
                        cutover.install_runner_atomically()
                    except cutover.CutoverError:
                        pass

                if fixture.runner_installed.exists():
                    installed = fixture.runner_installed.read_bytes()
                    self.assertNotIn(malicious, installed)
                    self.assertIn(b"TICKER-RUNTIME-V1", installed)

    def test_generated_runner_binds_runtime_identity_without_private_source_literals(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                source = fixture.runner_source.read_bytes()
                self.assertNotIn(str(fixture.home).encode("utf-8"), source)
                self.assertNotIn(str(fixture.codex).encode("utf-8"), source)
                cutover.install_runner_atomically()
                installed = fixture.runner_installed.read_bytes()
                self.assertEqual(
                    installed.splitlines()[0],
                    f"#!{sys.executable} -I".encode("utf-8"),
                )
                self.assertIn(b"TICKER-RUNTIME-V1", installed)
                self.assertIn(str(fixture.home).encode("utf-8"), installed)
                self.assertIn(str(fixture.codex).encode("utf-8"), installed)
                self.assertIn(str(fixture.codex_home).encode("utf-8"), installed)
                self.assertNotIn(b"SUPERSET_AGENT_ID", installed)
                self.assertNotIn(b"--enable hooks", installed)

    def test_v2_binding_persists_digest_architecture_and_source_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.install_bound_runner()
                binding = cutover.read_runtime_binding(fixture.runner_installed)
                self.assertEqual(binding.binding_version, 2)
                self.assertEqual(Path(str(binding.codex_home)), fixture.codex_home)

                self.assertRegex(binding.codex_sha256, r"^[0-9a-f]{64}$")
                self.assertEqual(binding.codex_sha256, native_digest(fixture.codex))
                self.assertEqual(binding.codex_macho_arch, host_native_arch())
                self.assertEqual(binding.codex_managed_by, "direct")
                self.assertIsNone(binding.codex_managed_package_root)
                self.assertIsNone(binding.codex_managed_package_version)
                self.assertEqual(
                    set(binding.skill_roots),
                    {routine.task_id for routine in fixture.routines},
                )
                for routine in fixture.routines:
                    with self.subTest(task_id=routine.task_id):
                        self.assertEqual(
                            binding.skill_roots[routine.task_id],
                            routine.root.canonical_root,
                        )
                fixture.codex.write_bytes(fixture.codex.read_bytes() + b"tampered")
                fixture.codex.chmod(0o755)
                with mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    None,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ), mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                ) as discovery:
                    with self.assertRaises(cutover.CutoverError):
                        cutover.prepare_codex_compensation()
                discovery.assert_not_called()

    def test_runner_install_uses_one_parent_descriptor_for_publish_and_readback(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                atomic_write_at = getattr(cutover, "atomic_write_at", None)
                self.assertIsNotNone(
                    atomic_write_at,
                    "RED contract missing descriptor-relative atomic_write_at",
                )
                self.assertNotIn(
                    "atomic_write(RUNNER_INSTALLED",
                    SCRIPT.read_text(encoding="utf-8"),
                )
                parent_opens: list[Path] = []
                real_open_chain = cutover.open_trusted_directory_chain

                def observing_open_chain(
                    path: Path,
                    uid: int,
                    description: str,
                ) -> object:
                    if path == fixture.runner_installed.parent:
                        parent_opens.append(path)
                    return real_open_chain(path, uid, description)

                with mock.patch.object(
                    cutover,
                    "open_trusted_directory_chain",
                    side_effect=observing_open_chain,
                ):
                    cutover.install_runner_atomically()
                self.assertGreaterEqual(len(parent_opens), 1)
                self.assertNotIn(
                    b"malicious runner bytes",
                    fixture.runner_installed.read_bytes(),
                )
                self.assertNotIn(
                    "RUNNER_INSTALLED.read_bytes",
                    SCRIPT.read_text(encoding="utf-8"),
                )

    def test_codex_compensation_reads_installed_binding_without_path_discovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                binding = fixture.binding_payload()
                fixture.runner_installed.write_bytes(
                    bind_generated_runner(fixture.runner_source.read_bytes(), binding)
                )
                fixture.runner_installed.chmod(0o755)
                cutover.CODEX_EXECUTABLE = None
                cutover.LAUNCHD_ENVIRONMENT = fixture.launchd_environment
                with mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                    return_value=fixture.codex,
                ) as discovery:
                    cutover.prepare_codex_compensation()
                discovery.assert_not_called()
                self.assertEqual(Path(str(cutover.CODEX_EXECUTABLE)), fixture.codex)

    def test_committed_runtime_refresh_preserves_six_plists_and_rehydrates_managed_rows(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * len(fixture.routines),
                    loaded=len(fixture.routines),
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.commands.wrapped.clear()
                plist_before = {
                    routine.task_id: routine.plist.read_bytes() for routine in fixture.routines
                }
                registry_before = fixture.registry.read_bytes()
                marker_before = fixture.marker.read_bytes()
                refresh = getattr(cutover, "refresh_runtime_artifact", None)
                self.assertIsNotNone(
                    refresh,
                    "RED contract missing committed runtime refresh maintenance path",
                )
                with mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ):
                    refresh(fixture.routines_tuple, command_runner=fixture.commands)
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    plist_before,
                )
                self.assertEqual(fixture.registry.read_bytes(), registry_before)
                self.assertEqual(fixture.marker.read_bytes(), marker_before)
                self.assertEqual(
                    fixture.commands.wrapped,
                    {routine.task_id for routine in fixture.routines},
                )
                self.assertEqual(
                    {
                        fixture.commands.doctor_state(routine)
                        for routine in fixture.routines
                    },
                    {"wrapped-consistent"},
                )

    def test_refresh_aborts_on_unrelated_registry_drift_without_restoring_old_snapshot(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * len(fixture.routines),
                    loaded=len(fixture.routines),
                    registry_enabled=False,
                    marker_exact=True,
                )
                marker_before = fixture.marker.read_bytes()
                registry_before = fixture.registry.read_bytes()
                plist_before = {
                    routine.task_id: routine.plist.read_bytes()
                    for routine in fixture.routines
                }
                refresh = getattr(cutover, "refresh_runtime_artifact", None)
                self.assertIsNotNone(refresh)
                assert refresh is not None
                real_read_regular = cutover.read_regular
                edited_registry: bytes | None = None
                injected = False

                def inject_registry_drift(path: Path, description: str) -> bytes:
                    nonlocal edited_registry, injected
                    if (
                        not injected
                        and path == fixture.registry
                        and description == "refreshed Claude registry"
                    ):
                        document = fixture.registry_document()
                        scheduled_tasks = document["scheduledTasks"]
                        assert isinstance(scheduled_tasks, list)
                        assert isinstance(scheduled_tasks[0], dict)
                        scheduled_tasks[0]["unrelatedField"] = {
                            "preserve": "external edit",
                        }
                        fixture.registry.write_text(
                            json.dumps(document),
                            encoding="utf-8",
                        )
                        fixture.registry.chmod(0o600)
                        edited_registry = fixture.registry.read_bytes()
                        injected = True
                    return real_read_regular(path, description)

                with mock.patch.object(
                    cutover,
                    "read_regular",
                    side_effect=inject_registry_drift,
                ), mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ):
                    with self.assertRaises(cutover.CutoverError):
                        refresh(fixture.routines_tuple, command_runner=fixture.commands)

                self.assertTrue(injected)
                self.assertIsNotNone(edited_registry)
                assert edited_registry is not None
                self.assertNotEqual(edited_registry, registry_before)
                self.assertEqual(fixture.registry.read_bytes(), edited_registry)
                self.assertEqual(fixture.marker.read_bytes(), marker_before)
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    plist_before,
                )

    def test_refresh_rejects_registry_ambiguity_after_initial_revalidation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * len(fixture.routines),
                    loaded=len(fixture.routines),
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.commands.claude_running = True
                runner_before = fixture.runner_installed.read_bytes()
                registry_before = fixture.registry.read_bytes()
                marker_before = fixture.marker.read_bytes()
                plists_before = {
                    routine.task_id: routine.plist.read_bytes()
                    for routine in fixture.routines
                }
                second_registry = (
                    fixture.sessions_root
                    / "account refresh-race"
                    / "session refresh-race"
                    / "scheduled-tasks.json"
                )
                real_discover = cutover.discover_claude_registry
                discovery_calls = 0
                second_registry_before: bytes | None = None

                def discover_with_refresh_race(
                    home: Path,
                    routines: object,
                ) -> Path:
                    nonlocal discovery_calls, second_registry_before
                    discovery_calls += 1
                    discovered = real_discover(home, routines)
                    if discovery_calls == 2:
                        write_registry(second_registry, fixture.routines_tuple)
                        second_registry.chmod(0o600)
                        second_registry_before = second_registry.read_bytes()
                    return discovered

                with mock.patch.object(
                    cutover,
                    "discover_claude_registry",
                    side_effect=discover_with_refresh_race,
                ), mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ), mock.patch.object(
                    cutover.sys,
                    "stdout",
                    io.StringIO(),
                ) as output:
                    result, _transactions, _factory = fixture.run_main(
                        ["--refresh"],
                        str(fixture.codex.parent),
                    )

                self.assertEqual(result, 1)
                self.assertGreaterEqual(discovery_calls, 3)
                self.assertIsNotNone(second_registry_before)
                assert second_registry_before is not None
                self.assertEqual(
                    fixture.runner_installed.read_bytes(),
                    runner_before,
                )
                self.assertEqual(fixture.registry.read_bytes(), registry_before)
                self.assertEqual(fixture.marker.read_bytes(), marker_before)
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    plists_before,
                )
                self.assertEqual(second_registry.read_bytes(), second_registry_before)
                self.assertFalse(fixture.commands.claude_running)
                self.assertNotIn("runtime refresh completed", output.getvalue())

    def test_refresh_relaunches_prior_claude_after_final_registry_fences(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * len(fixture.routines),
                    loaded=len(fixture.routines),
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.commands.claude_running = True
                marker_before = fixture.marker.read_bytes()
                registry_before = fixture.registry.read_bytes()
                plists_before = {
                    routine.task_id: routine.plist.read_bytes()
                    for routine in fixture.routines
                }
                refresh = getattr(cutover, "refresh_runtime_artifact", None)
                self.assertIsNotNone(refresh)
                assert refresh is not None
                phases: list[str] = []
                real_revalidate = (
                    cutover.CutoverTransaction._revalidate_registry_binding
                )

                def observe_revalidation(transaction: object) -> None:
                    phases.append("registry-fence")
                    real_revalidate(transaction)

                fixture.commands.on_open = lambda: phases.append("relaunch")
                with mock.patch.object(
                    cutover.CutoverTransaction,
                    "_revalidate_registry_binding",
                    observe_revalidation,
                ), mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ):
                    refresh(fixture.routines_tuple, command_runner=fixture.commands)

                relaunch_index = phases.index("relaunch")
                self.assertGreater(relaunch_index, 0)
                self.assertEqual(phases[relaunch_index - 1], "registry-fence")
                self.assertIn("registry-fence", phases[relaunch_index + 1 :])
                self.assertTrue(fixture.commands.claude_relaunched)
                self.assertTrue(fixture.commands.claude_running)
                self.assertEqual(fixture.marker.read_bytes(), marker_before)
                self.assertEqual(fixture.registry.read_bytes(), registry_before)
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    plists_before,
                )

    def test_refresh_preflights_ticker_trust_before_any_mutation(self) -> None:
        for case in ("symlink-target", "group-writable-leaf", "writable-parent"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    fixture.prepare_state(
                        plist_states=["wrapped"] * len(fixture.routines),
                        loaded=len(fixture.routines),
                        registry_enabled=False,
                        marker_exact=True,
                    )
                    if case == "symlink-target":
                        target = fixture.root / "ticker target"
                        target.write_bytes(b"#!/bin/sh\nexit 0\n")
                        target.chmod(0o775)
                        fixture.ticker.unlink()
                        fixture.ticker.symlink_to(target)
                    elif case == "group-writable-leaf":
                        fixture.ticker.chmod(0o775)
                    else:
                        fixture.ticker.parent.chmod(0o777)

                    runner_before = fixture.runner_installed.read_bytes()
                    registry_before = fixture.registry.read_bytes()
                    marker_before = fixture.marker.read_bytes()
                    plist_before = {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    }
                    events_before = list(fixture.commands.events)
                    refresh = getattr(cutover, "refresh_runtime_artifact", None)
                    self.assertIsNotNone(refresh)
                    assert refresh is not None
                    with mock.patch.object(
                        cutover,
                        "CODEX_EXECUTABLE",
                        fixture.codex,
                    ), mock.patch.object(
                        cutover,
                        "LAUNCHD_ENVIRONMENT",
                        fixture.launchd_environment,
                    ):
                        with self.assertRaises(cutover.CutoverError):
                            refresh(
                                fixture.routines_tuple,
                                command_runner=fixture.commands,
                            )

                    self.assertEqual(fixture.commands.events, events_before)
                    self.assertEqual(
                        fixture.runner_installed.read_bytes(),
                        runner_before,
                    )
                    self.assertEqual(fixture.registry.read_bytes(), registry_before)
                    self.assertEqual(fixture.marker.read_bytes(), marker_before)
                    self.assertEqual(
                        {
                            routine.task_id: routine.plist.read_bytes()
                            for routine in fixture.routines
                        },
                        plist_before,
                    )

    def test_main_refresh_is_reachable_and_fenced(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.commands.wrapped.clear()
                marker_before = fixture.marker.read_bytes()
                registry_before = fixture.registry.read_bytes()
                plist_before = {
                    routine.task_id: routine.plist.read_bytes()
                    for routine in fixture.routines
                }
                with mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                ) as discovery, mock.patch.object(
                    cutover,
                    "migration_transaction_lock",
                    wraps=cutover.migration_transaction_lock,
                ) as lock, mock.patch.object(
                    cutover,
                    "SignalScope",
                    wraps=cutover.SignalScope,
                ) as signal_scope, mock.patch.object(
                    cutover,
                    "blocked_cutover_signals",
                    wraps=cutover.blocked_cutover_signals,
                ) as blocked, mock.patch.object(
                    cutover.sys,
                    "stdout",
                    io.StringIO(),
                ) as output:
                    result, _transactions, _factory = fixture.run_main(
                        ["--refresh"],
                        str(fixture.codex.parent),
                    )
                self.assertEqual(result, 0)
                discovery.assert_not_called()
                lock.assert_called()
                signal_scope.assert_called()
                blocked.assert_called()
                self.assertIn("refresh", output.getvalue().lower())
                self.assertEqual(fixture.marker.read_bytes(), marker_before)
                self.assertEqual(fixture.registry.read_bytes(), registry_before)
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    plist_before,
                )
                self.assertEqual(
                    {
                        fixture.commands.doctor_state(routine)
                        for routine in fixture.routines
                    },
                    {"wrapped-consistent"},
                )

    def test_refresh_retries_transient_wrap_failure_to_all_wrapped_consistent(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.commands.wrapped.clear()
                fixture.commands.fail_once("wrap")
                snapshots = {
                    "marker": fixture.marker.read_bytes(),
                    "registry": fixture.registry.read_bytes(),
                    "plists": {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                }
                with mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ):
                    refresh = getattr(cutover, "refresh_runtime_artifact", None)
                    self.assertIsNotNone(refresh)
                    assert refresh is not None
                    refresh(fixture.routines_tuple, command_runner=fixture.commands)
                binding = cutover.read_runtime_binding(fixture.runner_installed)
                self.assertEqual(binding.binding_version, 2)
                self.assertEqual(binding.uid, os.getuid())
                self.assertEqual(binding.home, fixture.home)
                self.assertEqual(binding.repository, fixture.working_directory)
                self.assertEqual(binding.python, Path(sys.executable))
                self.assertEqual(binding.codex, fixture.codex)
                self.assertEqual(binding.path, fixture.launchd_environment["PATH"])
                self.assertEqual(binding.model, "gpt-5.6-sol")
                self.assertEqual(binding.codex_sha256, native_digest(fixture.codex))
                self.assertEqual(binding.codex_macho_arch, host_native_arch())
                self.assertIsNone(binding.codex_managed_package_root)
                self.assertIsNone(binding.codex_managed_package_version)
                self.assertEqual(binding.codex_managed_by, "direct")
                self.assertEqual(
                    binding.skill_roots,
                    {
                        routine.task_id: routine.root.canonical_root
                        for routine in fixture.routines
                    },
                )
                self.assertEqual(fixture.marker.read_bytes(), snapshots["marker"])
                self.assertEqual(fixture.registry.read_bytes(), snapshots["registry"])
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    snapshots["plists"],
                )
                self.assertEqual(
                    {
                        fixture.commands.doctor_state(routine)
                        for routine in fixture.routines
                    },
                    {"wrapped-consistent"},
                )

    def test_refresh_compensates_after_mid_loop_failure_before_returning(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.commands.wrapped.clear()
                fixture.commands.wrap_failure_task_id = fixture.routines[1].task_id
                fixture.commands.fail_once("wrap")
                snapshots = {
                    "runner": fixture.runner_installed.read_bytes(),
                    "marker": fixture.marker.read_bytes(),
                    "registry": fixture.registry.read_bytes(),
                    "plists": {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                }
                refresh = getattr(cutover, "refresh_runtime_artifact", None)
                self.assertIsNotNone(refresh)
                assert refresh is not None
                with mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ):
                    try:
                        refresh(fixture.routines_tuple, command_runner=fixture.commands)
                    except (cutover.CutoverError, cutover.RollbackError):
                        pass
                first_wrap = f"ticker wrap {fixture.routines[0].ticker_id}"
                second_wrap = f"ticker wrap {fixture.routines[1].ticker_id}"
                self.assertLess(
                    fixture.commands.events.index(first_wrap),
                    fixture.commands.events.index(second_wrap),
                )
                self.assertEqual(fixture.marker.read_bytes(), snapshots["marker"])
                self.assertEqual(fixture.registry.read_bytes(), snapshots["registry"])
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    snapshots["plists"],
                )
                self.assertEqual(
                    {
                        fixture.commands.doctor_state(routine)
                        for routine in fixture.routines
                    },
                    {"wrapped-consistent"},
                )

    def test_persistent_refresh_failure_preserves_old_runner_and_external_bytes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                runner_before = fixture.runner_installed.read_bytes()
                marker_before = fixture.marker.read_bytes()
                registry_before = fixture.registry.read_bytes()
                plists_before = {
                    routine.task_id: routine.plist.read_bytes()
                    for routine in fixture.routines
                }
                fixture.runner_source.write_bytes(b"#!/bin/sh\nnew runner body\n")
                fixture.runner_source.chmod(0o755)
                fixture.commands.failures["wrap"] = 100
                refresh = getattr(cutover, "refresh_runtime_artifact", None)
                self.assertIsNotNone(refresh)
                assert refresh is not None
                with mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ):
                    with self.assertRaises(
                        (cutover.CutoverError, cutover.RollbackError)
                    ):
                        refresh(fixture.routines_tuple, command_runner=fixture.commands)
                self.assertEqual(fixture.runner_installed.read_bytes(), runner_before)
                self.assertEqual(fixture.marker.read_bytes(), marker_before)
                self.assertEqual(fixture.registry.read_bytes(), registry_before)
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    plists_before,
                )
                self.assertEqual(
                    {
                        fixture.commands.doctor_state(routine)
                        for routine in fixture.routines
                    },
                    {"wrapped-consistent"},
                )

    def test_legacy_v1_binding_rolls_back_and_refresh_upgrades_to_v2(self) -> None:
        def legacy_binding(fixture: CutoverFixture) -> dict[str, object]:
            return {
                "uid": os.getuid(),
                "home": str(fixture.home),
                "repository": str(fixture.working_directory),
                "python": sys.executable,
                "codex": str(fixture.codex),
                "path": fixture.launchd_environment["PATH"],
                "model": "gpt-5.6-sol",
                "codex_managed_package_root": str(fixture.codex.parent),
                "codex_managed_by": "direct",
            }

        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.runner_installed.write_bytes(
                    bind_generated_runner(
                        fixture.runner_source.read_bytes(),
                        legacy_binding(fixture),
                    )
                )
                fixture.runner_installed.chmod(0o755)
                missing_path = fixture.root / "missing caller PATH"
                missing_path.mkdir()
                with mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                ) as discovery:
                    result, transactions, _factory = fixture.run_main(
                        ["--rollback"],
                        str(missing_path),
                    )
                self.assertEqual(result, 0)
                discovery.assert_not_called()
                self.assertEqual(len(transactions), 1)
                fixture.assert_claude_state(self)

        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.runner_installed.write_bytes(
                    bind_generated_runner(
                        fixture.runner_source.read_bytes(),
                        legacy_binding(fixture),
                    )
                )
                fixture.runner_installed.chmod(0o755)
                fixture.commands.wrapped.clear()
                marker_before = fixture.marker.read_bytes()
                registry_before = fixture.registry.read_bytes()
                plists_before = {
                    routine.task_id: routine.plist.read_bytes()
                    for routine in fixture.routines
                }
                argv_before = {
                    routine.task_id: list(
                        plistlib.loads(routine.plist.read_bytes())["ProgramArguments"]
                    )
                    for routine in fixture.routines
                }
                refresh = getattr(cutover, "refresh_runtime_artifact", None)
                self.assertIsNotNone(refresh)
                assert refresh is not None
                with mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ):
                    refresh(fixture.routines_tuple, command_runner=fixture.commands)
                binding = cutover.read_runtime_binding(fixture.runner_installed)
                self.assertEqual(binding.binding_version, 2)
                self.assertRegex(binding.codex_sha256, r"^[0-9a-f]{64}$")
                self.assertEqual(binding.codex_macho_arch, host_native_arch())
                self.assertEqual(fixture.marker.read_bytes(), marker_before)
                self.assertEqual(fixture.registry.read_bytes(), registry_before)
                self.assertEqual(
                    {
                        routine.task_id: routine.plist.read_bytes()
                        for routine in fixture.routines
                    },
                    plists_before,
                )
                self.assertEqual(
                    {
                        routine.task_id: list(
                            plistlib.loads(routine.plist.read_bytes())["ProgramArguments"]
                        )
                        for routine in fixture.routines
                    },
                    argv_before,
                )

    def test_legacy_v2_binding_without_codex_home_rolls_back_and_refreshes_explicit_home(
        self,
    ) -> None:
        def legacy_v2_binding(fixture: CutoverFixture) -> dict[str, object]:
            payload = fixture.binding_payload()
            payload.pop("codex_home")
            return payload

        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.runner_installed.write_bytes(
                    bind_generated_runner(
                        fixture.runner_source.read_bytes(),
                        legacy_v2_binding(fixture),
                    )
                )
                fixture.runner_installed.chmod(0o755)
                parsed = cutover.read_runtime_binding(fixture.runner_installed)
                self.assertEqual(parsed.binding_version, 2)
                self.assertEqual(parsed.codex_home, fixture.home / ".codex")

                missing_path = fixture.root / "missing caller PATH"
                missing_path.mkdir()
                with mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                ) as discovery:
                    result, transactions, _factory = fixture.run_main(
                        ["--rollback"],
                        str(missing_path),
                    )
                self.assertEqual(result, 0)
                discovery.assert_not_called()
                self.assertEqual(len(transactions), 1)
                fixture.assert_claude_state(self)

        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.runner_installed.write_bytes(
                    bind_generated_runner(
                        fixture.runner_source.read_bytes(),
                        legacy_v2_binding(fixture),
                    )
                )
                fixture.runner_installed.chmod(0o755)
                refresh = getattr(cutover, "refresh_runtime_artifact", None)
                self.assertIsNotNone(refresh)
                assert refresh is not None
                with mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    fixture.codex,
                ), mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    fixture.launchd_environment,
                ):
                    refresh(fixture.routines_tuple, command_runner=fixture.commands)
                binding_line = next(
                    line
                    for line in fixture.runner_installed.read_bytes().splitlines()
                    if line.startswith(b"# TICKER-RUNTIME-V1 ")
                )
                payload = json.loads(
                    binding_line[len(b"# TICKER-RUNTIME-V1 ") :].decode("utf-8")
                )
                self.assertEqual(payload["codex_home"], str(fixture.codex_home))

    def test_gitignore_blocks_local_env_files_and_allows_examples(self) -> None:
        for candidate in (".env", "nested/.env.local"):
            with self.subTest(candidate=candidate):
                ignored = subprocess.run(
                    ["git", "check-ignore", "--quiet", "--no-index", candidate],
                    cwd=REPO,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(ignored.returncode, 0, ignored.stderr)

        for candidate in (".env.example", ".env.sample", ".env.template"):
            with self.subTest(candidate=candidate):
                trackable = subprocess.run(
                    ["git", "check-ignore", "--quiet", "--no-index", candidate],
                    cwd=REPO,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(trackable.returncode, 1, trackable.stderr)


    def test_administrative_commands_use_only_trusted_environment(self) -> None:
        trusted_home = "/trusted/ticker-home"
        fallback_environment = {
            "HOME": trusted_home,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TZ": "America/New_York",
            "LANG": "C",
            "LC_ALL": "C",
        }
        bound_environment = {
            "HOME": trusted_home,
            "PATH": "/trusted/ticker-bin:/usr/bin:/bin",
            "TZ": "America/New_York",
            "LANG": "C",
            "LC_ALL": "C",
        }
        poisoned_environment = {
            "TICKER_CRONTAB_PATH": "/tmp/ticker-crontab-payload",
            "TICKER_STORE_PATH": "/tmp/ticker-migration-foreign-store.db",
            "TICKER_CONFIG_PATH": "/tmp/ticker-config",
            "DYLD_INSERT_LIBRARIES": "/tmp/ticker-injected.dylib",
            "PYTHONPATH": "/tmp/ticker-pythonpath",
            "TICKER_MIGRATION_SENTINEL": "must-not-inherit",
        }
        administrative_commands = (
            (cutover.TICKER_EXECUTABLE, ["doctor"]),
            (Path("/usr/local/bin/codex"), ["--version"]),
            (cutover.LAUNCHCTL, ["print", "gui/0"]),
            (cutover.PS, ["-axo", "pid=,command="]),
            (cutover.OSASCRIPT, ["-e", "return"]),
            (cutover.OPEN, ["-a", "Claude"]),
        )
        completed = mock.Mock(returncode=0, stdout="", stderr="")

        def run_administrative_commands() -> None:
            for executable, arguments in administrative_commands:
                cutover.CommandRunner().run(executable, arguments)

        with mock.patch.dict(
            cutover.os.environ,
            {**fallback_environment, **poisoned_environment},
            clear=True,
        ), mock.patch.object(
            cutover,
            "HOME_DIRECTORY",
            Path(trusted_home),
        ), mock.patch.object(
            cutover,
            "LAUNCHD_ENVIRONMENT",
            None,
        ), mock.patch.object(
            cutover,
            "validate_ticker_executable",
            return_value=None,
        ), mock.patch.object(
            cutover.subprocess,
            "run",
            return_value=completed,
        ) as run:
            run_administrative_commands()
            with mock.patch.object(
                cutover,
                "LAUNCHD_ENVIRONMENT",
                {
                    key: value
                    for key, value in bound_environment.items()
                    if key not in {"LANG", "LC_ALL"}
                },
            ):
                run_administrative_commands()

        self.assertEqual(run.call_count, len(administrative_commands) * 2)
        expected_environments = (
            [fallback_environment] * len(administrative_commands)
            + [bound_environment] * len(administrative_commands)
        )
        for invocation, expected in zip(run.call_args_list, expected_environments):
            environment = invocation.kwargs["env"]
            self.assertEqual(environment, expected)
            self.assertTrue(
                set(poisoned_environment).isdisjoint(environment),
                f"poisoned environment leaked: {environment}",
            )

    def test_obsolete_integrity_closure_structures_are_absent(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        for obsolete in (
            "CANONICAL_SKILL_BINDINGS",
            "parse_skill_dependencies",
            "UF_IMMUTABLE",
            "disabled-ticker-codex",
            "PromptArgumentKind",
            "codex_prompt_sha256",
            "legacy_prompt_sha256",
            "ManualRecoveryRequired",
        ):
            self.assertNotIn(obsolete, source)


class TickerBoundaryTests(unittest.TestCase):
    LIVE_TICKER = Path("/Applications/Ticker.app/Contents/Helpers/ticker")

    @staticmethod
    def _metadata(
        *,
        mode: int,
        uid: int,
        gid: int,
        inode: int,
        regular: bool = False,
    ) -> SimpleNamespace:
        file_type = stat.S_IFREG if regular else stat.S_IFDIR
        return SimpleNamespace(
            st_mode=file_type | mode,
            st_uid=uid,
            st_gid=gid,
            st_dev=7,
            st_ino=inode,
            st_size=1,
            st_nlink=1,
        )

    def _valid_chain(
        self,
        uid: int,
        *,
        admin_gid: int = 80,
    ) -> dict[str, SimpleNamespace]:
        return {
            "/": self._metadata(mode=0o755, uid=0, gid=0, inode=1),
            "Applications": self._metadata(
                mode=0o775,
                uid=0,
                gid=admin_gid,
                inode=2,
            ),
            "Ticker.app": self._metadata(
                mode=0o700,
                uid=uid,
                gid=admin_gid,
                inode=3,
            ),
            "Contents": self._metadata(
                mode=0o755,
                uid=uid,
                gid=admin_gid,
                inode=4,
            ),
            "Helpers": self._metadata(
                mode=0o755,
                uid=uid,
                gid=admin_gid,
                inode=5,
            ),
            "ticker": self._metadata(
                mode=0o755,
                uid=uid,
                gid=admin_gid,
                inode=6,
                regular=True,
            ),
        }

    @staticmethod
    def _component(value: object) -> str:
        text = str(value)
        return "/" if text in {"", "/"} else Path(text).name

    @contextmanager
    def _fake_chain(
        self,
        descriptor_metadata: dict[str, SimpleNamespace],
        *,
        path_metadata: dict[str, SimpleNamespace] | None = None,
        group_name: str = "admin",
        fail_open: str | None = None,
    ):
        path_metadata = dict(
            descriptor_metadata if path_metadata is None else path_metadata
        )
        open_calls: list[tuple[str, int, object]] = []
        fstat_calls: list[int] = []
        closed: list[int] = []
        opened: list[int] = []
        descriptors: dict[int, str] = {}
        next_descriptor = 100

        def fake_open(
            path: object,
            flags: int,
            *_args: object,
            dir_fd: object = None,
            **_kwargs: object,
        ) -> int:
            nonlocal next_descriptor
            component = self._component(path)
            if component == fail_open:
                raise OSError("simulated O_NOFOLLOW symlink/open failure")
            if component not in descriptor_metadata:
                raise AssertionError(f"unexpected descriptor open: {path}")
            descriptor = next_descriptor
            next_descriptor += 1
            descriptors[descriptor] = component
            opened.append(descriptor)
            open_calls.append((component, flags, dir_fd))
            return descriptor

        def fake_fstat(descriptor: int) -> SimpleNamespace:
            fstat_calls.append(descriptor)
            try:
                return descriptor_metadata[descriptors[descriptor]]
            except KeyError as error:
                raise AssertionError(f"unexpected descriptor fstat: {descriptor}") from error

        def fake_path_metadata(path: object, *_args: object, **_kwargs: object) -> SimpleNamespace:
            component = self._component(path)
            try:
                return path_metadata[component]
            except KeyError as error:
                raise AssertionError(f"unexpected path metadata lookup: {path}") from error

        def fake_access(path: object, mode: int, *_args: object, **_kwargs: object) -> bool:
            component = self._component(path)
            metadata = descriptor_metadata.get(component)
            if metadata is None:
                return False
            permissions = stat.S_IMODE(metadata.st_mode)
            if mode & os.R_OK and not permissions & 0o444:
                return False
            if mode & os.X_OK and not permissions & 0o111:
                return False
            return True

        group_lookup = mock.Mock(
            return_value=SimpleNamespace(gr_name=group_name),
        )
        with ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(cutover.os, "getuid", return_value=501),
            )
            stack.enter_context(
                mock.patch.object(cutover.os, "open", side_effect=fake_open),
            )
            stack.enter_context(
                mock.patch.object(cutover.os, "fstat", side_effect=fake_fstat),
            )
            stack.enter_context(
                mock.patch.object(cutover.os, "close", side_effect=closed.append),
            )
            stack.enter_context(
                mock.patch.object(cutover.os, "lstat", side_effect=fake_path_metadata),
            )
            stack.enter_context(
                mock.patch.object(cutover.os, "stat", side_effect=fake_path_metadata),
            )
            stack.enter_context(
                mock.patch.object(cutover.os, "access", side_effect=fake_access),
            )
            stack.enter_context(
                mock.patch.object(Path, "resolve", side_effect=lambda path, *_args, **_kwargs: path),
            )
            stack.enter_context(
                mock.patch.object(Path, "lstat", side_effect=fake_path_metadata),
            )
            stack.enter_context(
                mock.patch.object(
                    cutover,
                    "grp",
                    SimpleNamespace(getgrgid=group_lookup),
                    create=True,
                ),
            )
            yield SimpleNamespace(
                open_calls=open_calls,
                fstat_calls=fstat_calls,
                closed=closed,
                opened=opened,
                group_lookup=group_lookup,
            )


    def _validator(self):
        validator = getattr(cutover, "validate_ticker_executable", None)
        self.assertIsNotNone(
            validator,
            "RED contract missing validate_ticker_executable(path)",
        )
        assert validator is not None
        return validator

    def test_ticker_validator_accepts_exact_live_chain_with_admin_gid_and_returns_open_leaf_fd(
        self,
    ) -> None:
        validator = self._validator()
        uid = 501
        with self._fake_chain(self._valid_chain(uid)) as probe:
            validated_fd = validator(self.LIVE_TICKER)
            self.assertIsInstance(validated_fd, int)
            assert isinstance(validated_fd, int)
            self.assertEqual(validated_fd, probe.opened[-1])
            self.assertNotIn(validated_fd, probe.closed)
            self.assertEqual(set(probe.closed), set(probe.opened[:-1]))
            os.close(validated_fd)
            self.assertEqual(set(probe.closed), set(probe.opened))

        self.assertEqual(cutover.TICKER_EXECUTABLE, self.LIVE_TICKER)
        self.assertEqual(
            [component for component, _flags, _dir_fd in probe.open_calls],
            ["/", "Applications", "Ticker.app", "Contents", "Helpers", "ticker"],
        )
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        self.assertNotEqual(nofollow, 0)
        self.assertTrue(
            all(flags & nofollow for _component, flags, _dir_fd in probe.open_calls),
        )
        self.assertGreaterEqual(len(probe.fstat_calls), len(probe.open_calls))
        probe.group_lookup.assert_called_once_with(80)

    def test_ticker_validator_rejects_unsafe_live_chain_metadata_and_replacements(
        self,
    ) -> None:
        validator = self._validator()
        uid = 501
        valid = self._valid_chain(uid)
        cases = (
            (
                "applications-owner",
                {"Applications": self._metadata(mode=0o775, uid=uid, gid=80, inode=2)},
                "admin",
                None,
                None,
            ),
            (
                "applications-group",
                {"Applications": self._metadata(mode=0o775, uid=0, gid=81, inode=2)},
                "staff",
                None,
                None,
            ),
            (
                "applications-mode",
                {"Applications": self._metadata(mode=0o755, uid=0, gid=80, inode=2)},
                "admin",
                None,
                None,
            ),
            (
                "app-group",
                {"Ticker.app": self._metadata(mode=0o700, uid=uid, gid=81, inode=3)},
                "admin",
                None,
                None,
            ),
            (
                "contents-group",
                {"Contents": self._metadata(mode=0o755, uid=uid, gid=81, inode=4)},
                "admin",
                None,
                None,
            ),
            (
                "symlink-open-failure",
                {},
                "admin",
                "Ticker.app",
                None,
            ),
            (
                "app-owner",
                {"Ticker.app": self._metadata(mode=0o700, uid=0, gid=80, inode=3)},
                "admin",
                None,
                None,
            ),
            (
                "app-mode",
                {"Ticker.app": self._metadata(mode=0o755, uid=uid, gid=80, inode=3)},
                "admin",
                None,
                None,
            ),
            (
                "swapped-app-descriptor",
                {"Ticker.app": self._metadata(mode=0o700, uid=uid, gid=80, inode=99)},
                "admin",
                None,
                {"Ticker.app": valid["Ticker.app"]},
            ),
            (
                "contents-owner",
                {"Contents": self._metadata(mode=0o755, uid=0, gid=80, inode=4)},
                "admin",
                None,
                None,
            ),
            (
                "helpers-group-writable",
                {"Helpers": self._metadata(mode=0o775, uid=uid, gid=80, inode=5)},
                "admin",
                None,
                None,
            ),
            (
                "helpers-group",
                {"Helpers": self._metadata(mode=0o755, uid=uid, gid=81, inode=5)},
                "admin",
                None,
                None,
            ),
            (
                "binary-not-readable",
                {
                    "ticker": self._metadata(
                        mode=0o711,
                        uid=uid,
                        gid=80,
                        inode=6,
                        regular=True,
                    )
                },
                "admin",
                None,
                None,
            ),
            (
                "binary-group",
                {
                    "ticker": self._metadata(
                        mode=0o755,
                        uid=uid,
                        gid=81,
                        inode=6,
                        regular=True,
                    )
                },
                "admin",
                None,
                None,
            ),
        )
        for case, descriptor_overrides, group_name, fail_open, path_overrides in cases:
            with self.subTest(case=case):
                descriptors = dict(valid)
                descriptors.update(descriptor_overrides)
                paths = dict(valid)
                paths.update(
                    descriptor_overrides if path_overrides is None else path_overrides
                )
                with self._fake_chain(
                    descriptors,
                    path_metadata=paths,
                    group_name=group_name,
                    fail_open=fail_open,
                ):
                    with self.assertRaises(cutover.CutoverError):
                        validator(self.LIVE_TICKER)

    def test_ticker_validator_does_not_exempt_unrelated_root_owned_group_writable_path(
        self,
    ) -> None:
        validator = self._validator()
        unrelated = Path(
            "/opt/root-owned-group-writable/Ticker.app/Contents/Helpers/ticker",
        )
        with mock.patch.object(
            cutover,
            "validate_executable",
            side_effect=cutover.CutoverError(
                "unrelated root-owned group-writable directory",
            ),
        ) as generic_validator:
            with self.assertRaises(cutover.CutoverError):
                validator(unrelated)
        generic_validator.assert_called_once()
        self.assertEqual(generic_validator.call_args.args[0], unrelated)

    def test_ticker_validator_returns_none_for_generic_fixture_path(self) -> None:
        validator = self._validator()
        fixture_path = Path("/tmp/ticker-fixture/Contents/Helpers/ticker")
        with mock.patch.object(
            cutover,
            "validate_executable",
            return_value=None,
        ) as generic_validator:
            result = validator(fixture_path)

        self.assertIsNone(result)
        generic_validator.assert_called_once()
        self.assertEqual(generic_validator.call_args.args[0], fixture_path)

    def test_preflight_common_uses_ticker_specific_validator_and_closes_fd(
        self,
    ) -> None:
        validated_fd = 141
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                with mock.patch.object(
                    cutover,
                    "validate_ticker_executable",
                    create=True,
                    return_value=validated_fd,
                ) as ticker_validator, mock.patch.object(
                    cutover,
                    "validate_executable",
                ) as generic_validator, mock.patch.object(
                    cutover.os,
                    "close",
                ) as close:
                    fixture.transaction()._preflight_common()

                ticker_validator.assert_called_once_with(fixture.ticker)
                generic_validator.assert_not_called()
                close.assert_called_once_with(validated_fd)
    def test_materialize_validated_ticker_copies_fd_into_private_trusted_file(
        self,
    ) -> None:
        materialize = getattr(cutover, "_materialize_validated_ticker", None)
        self.assertTrue(
            callable(materialize),
            "RED contract missing _materialize_validated_ticker(fd)",
        )
        assert callable(materialize)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            trusted_parent = root / "trusted runner parent"
            trusted_parent.mkdir()
            trusted_parent.chmod(0o700)
            installed_runner = trusted_parent / "run-codex-scheduled-task"
            source = root / "original ticker"
            original = b"\x00validated ticker bytes\n\xff"
            replacement = b"pathname replacement must not be read\n"
            source.write_bytes(original)
            source.chmod(0o755)
            source_fd = os.open(source, os.O_RDONLY)
            private_paths: list[Path] = []
            try:
                os.lseek(source_fd, len(original) // 2, os.SEEK_SET)
                source.unlink()
                source.write_bytes(replacement)
                source.chmod(0o755)
                current_position = os.lseek(source_fd, 0, os.SEEK_CUR)
                real_read_bytes = Path.read_bytes

                def reject_original_path_read(path: Path) -> bytes:
                    if path == source:
                        raise AssertionError("materializer read the original pathname")
                    return real_read_bytes(path)

                with mock.patch.object(
                    cutover,
                    "RUNNER_INSTALLED",
                    installed_runner,
                ), mock.patch.object(
                    Path,
                    "read_bytes",
                    side_effect=reject_original_path_read,
                ):
                    first = Path(materialize(source_fd))
                    private_paths.append(first)
                    second = Path(materialize(source_fd))
                    private_paths.append(second)

                self.assertEqual(first.read_bytes(), original)
                self.assertEqual(second.read_bytes(), original)
                self.assertEqual(first.parent, trusted_parent)
                self.assertEqual(second.parent, trusted_parent)
                self.assertNotEqual(first, second)
                self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(second.stat().st_mode), 0o700)
                self.assertEqual(
                    os.lseek(source_fd, 0, os.SEEK_CUR),
                    current_position,
                )
                self.assertEqual(source.read_bytes(), replacement)
            finally:
                os.close(source_fd)
                for private_path in private_paths:
                    private_path.unlink(missing_ok=True)

    def test_materialize_reports_copy_and_staging_cleanup_failure_and_closes_fds(
        self,
    ) -> None:
        materialize = getattr(cutover, "_materialize_validated_ticker", None)
        self.assertTrue(callable(materialize))
        assert callable(materialize)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            trusted_parent = root / "trusted runner parent"
            trusted_parent.mkdir()
            trusted_parent.chmod(0o700)
            installed_runner = trusted_parent / "run-codex-scheduled-task"
            source = root / "original ticker"
            source.write_bytes(b"validated ticker bytes\n")
            source.chmod(0o755)
            source_fd = os.open(source, os.O_RDONLY)
            closed: list[int] = []
            real_close = os.close

            def fail_write(_descriptor: int, _payload: object) -> int:
                raise OSError(errno.EIO, "simulated ticker copy failure")

            def fail_unlink(path: object, *, dir_fd: object = None) -> None:
                self.assertIsNotNone(dir_fd)
                self.assertTrue(str(path).startswith(".ticker."))
                raise OSError(errno.EPERM, "simulated staging cleanup denial")

            def track_close(descriptor: int) -> None:
                closed.append(descriptor)
                real_close(descriptor)

            try:
                with mock.patch.object(
                    cutover,
                    "RUNNER_INSTALLED",
                    installed_runner,
                ), mock.patch.object(
                    cutover.os,
                    "write",
                    side_effect=fail_write,
                ), mock.patch.object(
                    cutover.os,
                    "unlink",
                    side_effect=fail_unlink,
                ) as unlink, mock.patch.object(
                    cutover.os,
                    "close",
                    side_effect=track_close,
                ):
                    with self.assertRaises(cutover.CutoverError) as raised:
                        materialize(source_fd)
            finally:
                real_close(source_fd)

        message = str(raised.exception)
        self.assertIn("cannot copy validated Ticker executable", message)
        self.assertIn("cleanup failed", message.lower())
        self.assertIn("simulated staging cleanup denial", message)
        unlink.assert_called_once()
        self.assertGreaterEqual(len(closed), 2)
        self.assertNotIn(source_fd, closed)


    def test_command_runner_spawns_private_copy_after_path_swap_and_cleans_it(
        self,
    ) -> None:
        validated_fd = 211
        validation_calls: list[Path] = []
        path_state = {"inode": "validated"}
        closed: list[int] = []

        with tempfile.TemporaryDirectory() as directory:
            private_copy = Path(directory) / "private ticker"
            private_copy.write_bytes(b"validated ticker bytes\n")
            private_copy.chmod(0o700)

            def validate(path: Path) -> int:
                validation_calls.append(path)
                return validated_fd

            def materialize(fd: int) -> Path:
                self.assertEqual(fd, validated_fd)
                path_state["inode"] = "replacement"
                return private_copy

            def spawn(arguments: list[str], **kwargs: object) -> SimpleNamespace:
                self.assertEqual(arguments, [str(self.LIVE_TICKER), "doctor"])
                self.assertEqual(kwargs["executable"], str(private_copy))
                self.assertNotIn("pass_fds", kwargs)
                self.assertEqual(path_state["inode"], "replacement")
                self.assertTrue(private_copy.exists())
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with mock.patch.object(
                cutover,
                "validate_ticker_executable",
                side_effect=validate,
            ), mock.patch.object(
                cutover,
                "_materialize_validated_ticker",
                side_effect=materialize,
            ) as materializer, mock.patch.object(
                cutover.subprocess,
                "run",
                side_effect=spawn,
            ), mock.patch.object(
                cutover.os,
                "close",
                side_effect=closed.append,
            ), mock.patch.object(
                cutover,
                "_administrative_environment",
                return_value={
                    "HOME": "/trusted/home",
                    "PATH": "/usr/bin:/bin",
                    "TZ": "America/New_York",
                    "LANG": "C",
                    "LC_ALL": "C",
                },
            ):
                result = cutover.CommandRunner().run(self.LIVE_TICKER, ["doctor"])
                self.assertFalse(private_copy.exists())

        self.assertEqual(result.status, 0)
        self.assertEqual(validation_calls, [self.LIVE_TICKER])
        self.assertEqual(path_state["inode"], "replacement")
        materializer.assert_called_once_with(validated_fd)
        self.assertEqual(closed, [validated_fd])
        self.assertFalse(private_copy.exists())

    def test_command_runner_fails_after_success_when_private_copy_unlink_fails(
        self,
    ) -> None:
        validated_fd = 233
        closed: list[int] = []

        with tempfile.TemporaryDirectory() as directory:
            private_copy = Path(directory) / "private ticker"
            private_copy.write_bytes(b"validated ticker bytes\n")
            private_copy.chmod(0o700)

            def spawn(arguments: list[str], **kwargs: object) -> SimpleNamespace:
                self.assertEqual(arguments, [str(self.LIVE_TICKER), "doctor"])
                self.assertEqual(kwargs["executable"], str(private_copy))
                self.assertTrue(private_copy.exists())
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            def fail_unlink(path: Path, *, missing_ok: bool = False) -> None:
                self.assertEqual(path, private_copy)
                self.assertTrue(missing_ok)
                raise OSError(errno.EIO, "simulated successful-run cleanup denial")

            with mock.patch.object(
                cutover,
                "validate_ticker_executable",
                return_value=validated_fd,
            ), mock.patch.object(
                cutover,
                "_materialize_validated_ticker",
                return_value=private_copy,
            ) as materializer, mock.patch.object(
                cutover.subprocess,
                "run",
                side_effect=spawn,
            ) as subprocess_run, mock.patch.object(
                cutover.os,
                "close",
                side_effect=closed.append,
            ), mock.patch.object(
                Path,
                "unlink",
                autospec=True,
                side_effect=fail_unlink,
            ) as unlink, mock.patch.object(
                cutover,
                "_administrative_environment",
                return_value={
                    "HOME": "/trusted/home",
                    "PATH": "/usr/bin:/bin",
                    "TZ": "America/New_York",
                    "LANG": "C",
                    "LC_ALL": "C",
                },
            ):
                with self.assertRaises(cutover.CutoverError) as raised:
                    cutover.CommandRunner().run(self.LIVE_TICKER, ["doctor"])
                self.assertTrue(private_copy.exists())

        message = str(raised.exception)
        self.assertIn("cleanup failed", message.lower())
        self.assertIn("simulated successful-run cleanup denial", message)
        subprocess_run.assert_called_once()
        materializer.assert_called_once_with(validated_fd)
        unlink.assert_called_once_with(private_copy, missing_ok=True)
        self.assertEqual(closed, [validated_fd])



    def test_command_runner_unlinks_private_copy_and_closes_fd_when_spawn_fails(
        self,
    ) -> None:
        validated_fd = 223
        closed: list[int] = []

        with tempfile.TemporaryDirectory() as directory:
            private_copy = Path(directory) / "private ticker"
            private_copy.write_bytes(b"validated ticker bytes\n")
            private_copy.chmod(0o700)

            def spawn(arguments: list[str], **kwargs: object) -> SimpleNamespace:
                self.assertEqual(arguments, [str(self.LIVE_TICKER), "doctor"])
                self.assertEqual(kwargs["executable"], str(private_copy))
                self.assertNotIn("pass_fds", kwargs)
                self.assertTrue(private_copy.exists())
                raise OSError("simulated spawn failure")

            with mock.patch.object(
                cutover,
                "validate_ticker_executable",
                return_value=validated_fd,
            ), mock.patch.object(
                cutover,
                "_materialize_validated_ticker",
                return_value=private_copy,
            ) as materializer, mock.patch.object(
                cutover.subprocess,
                "run",
                side_effect=spawn,
            ) as subprocess_run, mock.patch.object(
                cutover.os,
                "close",
                side_effect=closed.append,
            ), mock.patch.object(
                cutover,
                "_administrative_environment",
                return_value={
                    "HOME": "/trusted/home",
                    "PATH": "/usr/bin:/bin",
                    "TZ": "America/New_York",
                    "LANG": "C",
                    "LC_ALL": "C",
                },
            ):
                with self.assertRaises(cutover.CutoverError):
                    cutover.CommandRunner().run(self.LIVE_TICKER, ["doctor"])
                self.assertFalse(private_copy.exists())

        subprocess_run.assert_called_once()
        materializer.assert_called_once_with(validated_fd)
        self.assertEqual(closed, [validated_fd])
        self.assertFalse(private_copy.exists())

    def test_command_runner_combines_spawn_and_private_copy_cleanup_failures(
        self,
    ) -> None:
        validated_fd = 239
        closed: list[int] = []

        with tempfile.TemporaryDirectory() as directory:
            private_copy = Path(directory) / "private ticker"
            private_copy.write_bytes(b"validated ticker bytes\n")
            private_copy.chmod(0o700)

            def spawn(arguments: list[str], **kwargs: object) -> SimpleNamespace:
                self.assertEqual(arguments, [str(self.LIVE_TICKER), "doctor"])
                self.assertEqual(kwargs["executable"], str(private_copy))
                self.assertTrue(private_copy.exists())
                raise OSError(errno.EPERM, "simulated spawn failure")

            def fail_unlink(path: Path, *, missing_ok: bool = False) -> None:
                self.assertEqual(path, private_copy)
                self.assertTrue(missing_ok)
                raise OSError(errno.EIO, "simulated spawn cleanup denial")

            with mock.patch.object(
                cutover,
                "validate_ticker_executable",
                return_value=validated_fd,
            ), mock.patch.object(
                cutover,
                "_materialize_validated_ticker",
                return_value=private_copy,
            ) as materializer, mock.patch.object(
                cutover.subprocess,
                "run",
                side_effect=spawn,
            ) as subprocess_run, mock.patch.object(
                cutover.os,
                "close",
                side_effect=closed.append,
            ), mock.patch.object(
                Path,
                "unlink",
                autospec=True,
                side_effect=fail_unlink,
            ) as unlink, mock.patch.object(
                cutover,
                "_administrative_environment",
                return_value={
                    "HOME": "/trusted/home",
                    "PATH": "/usr/bin:/bin",
                    "TZ": "America/New_York",
                    "LANG": "C",
                    "LC_ALL": "C",
                },
            ):
                with self.assertRaises(cutover.CutoverError) as raised:
                    cutover.CommandRunner().run(self.LIVE_TICKER, ["doctor"])
                self.assertTrue(private_copy.exists())

        message = str(raised.exception)
        self.assertIn("cannot execute", message)
        self.assertIn("simulated spawn failure", message)
        self.assertIn("cleanup failed", message.lower())
        self.assertIn("simulated spawn cleanup denial", message)
        subprocess_run.assert_called_once()
        materializer.assert_called_once_with(validated_fd)
        unlink.assert_called_once_with(private_copy, missing_ok=True)
        self.assertEqual(closed, [validated_fd])



    def test_command_runner_blocks_spawn_when_ticker_staging_parent_is_unsafe(
        self,
    ) -> None:
        validated_fd = 229
        closed: list[int] = []

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            unsafe_parent = root / "unsafe staging parent"
            unsafe_parent.mkdir()
            unsafe_parent.chmod(0o777)
            installed_runner = unsafe_parent / "run-codex-scheduled-task"
            source = root / "ticker"
            source.write_bytes(b"validated ticker bytes\n")
            source.chmod(0o755)
            source_fd = os.open(source, os.O_RDONLY)
            try:
                with mock.patch.object(
                    cutover,
                    "RUNNER_INSTALLED",
                    installed_runner,
                ), mock.patch.object(
                    cutover,
                    "validate_ticker_executable",
                    return_value=source_fd,
                ), mock.patch.object(
                    cutover.subprocess,
                    "run",
                ) as subprocess_run, mock.patch.object(
                    cutover.os,
                    "close",
                    side_effect=closed.append,
                ), mock.patch.object(
                    cutover,
                    "_administrative_environment",
                    return_value={
                        "HOME": "/trusted/home",
                        "PATH": "/usr/bin:/bin",
                        "TZ": "America/New_York",
                        "LANG": "C",
                        "LC_ALL": "C",
                    },
                ):
                    with self.assertRaises(cutover.CutoverError):
                        cutover.CommandRunner().run(self.LIVE_TICKER, ["doctor"])

                subprocess_run.assert_not_called()
                self.assertEqual(closed, [source_fd])
                self.assertEqual(tuple(unsafe_parent.iterdir()), ())
            finally:
                os.close(source_fd)


    def test_command_runner_revalidates_ticker_before_each_spawn_and_blocks_failure(
        self,
    ) -> None:
        validated_fd = 227
        validation_calls: list[Path] = []
        events: list[str] = []
        closed: list[int] = []

        with tempfile.TemporaryDirectory() as directory:
            private_paths: list[Path] = []

            def validate(path: Path) -> int:
                validation_calls.append(path)
                events.append("validate")
                if len(validation_calls) == 2:
                    raise cutover.CutoverError("Ticker trust changed before spawn")
                return validated_fd

            def materialize(fd: int) -> Path:
                self.assertEqual(fd, validated_fd)
                events.append("materialize")
                private_copy = Path(directory) / f"private-{len(private_paths)}"
                private_copy.write_bytes(b"validated ticker bytes\n")
                private_copy.chmod(0o700)
                private_paths.append(private_copy)
                return private_copy

            def spawn(arguments: list[str], **kwargs: object) -> SimpleNamespace:
                events.append("spawn")
                self.assertEqual(arguments, [str(self.LIVE_TICKER), "doctor"])
                self.assertEqual(kwargs["executable"], str(private_paths[-1]))
                self.assertNotIn("pass_fds", kwargs)
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with mock.patch.object(
                cutover,
                "validate_ticker_executable",
                side_effect=validate,
            ), mock.patch.object(
                cutover,
                "_materialize_validated_ticker",
                side_effect=materialize,
            ), mock.patch.object(
                cutover.subprocess,
                "run",
                side_effect=spawn,
            ) as subprocess_run, mock.patch.object(
                cutover.os,
                "close",
                side_effect=closed.append,
            ), mock.patch.object(
                cutover,
                "_administrative_environment",
                return_value={
                    "HOME": "/trusted/home",
                    "PATH": "/usr/bin:/bin",
                    "TZ": "America/New_York",
                    "LANG": "C",
                    "LC_ALL": "C",
                },
            ):
                first = cutover.CommandRunner().run(self.LIVE_TICKER, ["doctor"])
                self.assertEqual(first.status, 0)
                with self.assertRaises(cutover.CutoverError):
                    cutover.CommandRunner().run(self.LIVE_TICKER, ["wrap", "id"])
                self.assertTrue(
                    all(not private_path.exists() for private_path in private_paths)
                )

        self.assertEqual(validation_calls, [self.LIVE_TICKER, self.LIVE_TICKER])
        self.assertEqual(
            events,
            ["validate", "materialize", "spawn", "validate"],
        )
        self.assertEqual(subprocess_run.call_count, 1)
        self.assertEqual(closed, [validated_fd])
        self.assertTrue(all(not private_path.exists() for private_path in private_paths))


class TransactionTests(unittest.TestCase):
    def test_plists_are_created_only_after_atomic_registry_disable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                publications: list[tuple[Path, set[bool]]] = []
                real_atomic_write = cutover.atomic_write

                def observing_atomic_write(path: Path, data: bytes, mode: int) -> None:
                    if path in {routine.plist for routine in fixture.routines}:
                        publications.append((path, set(fixture.selected_enabled().values())))
                    real_atomic_write(path, data, mode)

                with mock.patch.object(cutover, "atomic_write", observing_atomic_write):
                    state = fixture.transaction().execute()

                self.assertTrue(state.committed)
                self.assertEqual(len(publications), 6)
                self.assertTrue(all(enabled == {False} for _, enabled in publications))

    def test_skill_root_trust_fails_preflight_before_engine_mutation(self) -> None:
        for case in ("parent-writable", "skill-writable", "skill-symlink"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    root = fixture.routines[0].root
                    if case == "parent-writable":
                        root.canonical_root.parent.chmod(0o777)
                    elif case == "skill-writable":
                        root.canonical_skill.chmod(0o666)
                    else:
                        replacement = fixture.root / "replacement SKILL.md"
                        replacement.write_text("replacement\n", encoding="utf-8")
                        replacement.chmod(0o600)
                        root.canonical_skill.unlink()
                        root.canonical_skill.symlink_to(replacement)

                    registry_before = fixture.registry.read_bytes()
                    runner_before = os.path.lexists(fixture.runner_installed)
                    plists_before = {
                        routine.plist: (
                            routine.plist.read_bytes()
                            if os.path.lexists(routine.plist)
                            else None
                        )
                        for routine in fixture.routines
                    }
                    with self.assertRaises(cutover.CutoverError):
                        fixture.transaction().execute()

                    self.assertEqual(fixture.registry.read_bytes(), registry_before)
                    self.assertEqual(
                        os.path.lexists(fixture.runner_installed),
                        runner_before,
                    )
                    self.assertEqual(
                        {
                            routine.plist: (
                                routine.plist.read_bytes()
                                if os.path.lexists(routine.plist)
                                else None
                            )
                            for routine in fixture.routines
                        },
                        plists_before,
                    )
                    self.assertFalse(
                        any(
                            event.startswith(prefix)
                            for event in fixture.commands.events
                            for prefix in (
                                "ticker wrap",
                                "ticker unwrap",
                                "ticker doctor --clear-stale",
                                "launchctl bootout",
                                "launchctl bootstrap",
                            )
                        )
                    )

    def test_codex_home_trust_fails_before_engine_mutation(self) -> None:
        for case in (
            "home-writable",
            "home-symlink",
            "config-mode",
            "config-symlink",
            "auth-mode",
            "auth-symlink",
        ):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    config = fixture.codex_home / "config.toml"
                    auth = fixture.codex_home / "auth.json"
                    if case == "home-writable":
                        fixture.codex_home.chmod(0o777)
                    elif case == "home-symlink":
                        target = fixture.root / "codex home target"
                        fixture.codex_home.rename(target)
                        fixture.codex_home.symlink_to(target, target_is_directory=True)
                    elif case == "config-mode":
                        config.chmod(0o644)
                    elif case == "config-symlink":
                        target = fixture.root / "config target"
                        target.write_text("", encoding="utf-8")
                        target.chmod(0o600)
                        config.unlink()
                        config.symlink_to(target)
                    elif case == "auth-mode":
                        auth.chmod(0o644)
                    else:
                        target = fixture.root / "auth target"
                        target.write_text("{}", encoding="utf-8")
                        target.chmod(0o600)
                        auth.unlink()
                        auth.symlink_to(target)

                    registry_before = fixture.registry.read_bytes()
                    runner_before = os.path.lexists(fixture.runner_installed)
                    plists_before = {
                        routine.plist: (
                            routine.plist.read_bytes()
                            if os.path.lexists(routine.plist)
                            else None
                        )
                        for routine in fixture.routines
                    }
                    with self.assertRaises(cutover.CutoverError):
                        fixture.transaction().execute()

                    self.assertEqual(fixture.registry.read_bytes(), registry_before)
                    self.assertEqual(
                        os.path.lexists(fixture.runner_installed),
                        runner_before,
                    )
                    self.assertEqual(
                        {
                            routine.plist: (
                                routine.plist.read_bytes()
                                if os.path.lexists(routine.plist)
                                else None
                            )
                            for routine in fixture.routines
                        },
                        plists_before,
                    )
                    self.assertFalse(
                        any(
                            event.startswith(prefix)
                            for event in fixture.commands.events
                            for prefix in (
                                "ticker wrap",
                                "ticker unwrap",
                                "ticker doctor --clear-stale",
                                "launchctl bootout",
                                "launchctl bootstrap",
                            )
                        )
                    )
                    fixture.assert_no_engine_mutation(self)

    def test_persisted_path_trust_fails_before_compensation_or_refresh_mutation(
        self,
    ) -> None:
        for source in ("binding", "plist"):
            for path_kind in ("missing", "writable"):
                with self.subTest(source=source, path_kind=path_kind):
                    with tempfile.TemporaryDirectory() as directory:
                        with CutoverFixture(Path(directory)) as fixture:
                            fixture.prepare_state(
                                plist_states=["wrapped"] * 6,
                                loaded=6,
                                registry_enabled=False,
                                marker_exact=True,
                            )
                            component = fixture.root / f"{source} {path_kind} PATH"
                            if path_kind == "writable":
                                component.mkdir()
                                component.chmod(0o777)
                            bad_path = (
                                f"{component}:{fixture.launchd_environment['PATH']}"
                            )
                            if source == "binding":
                                payload = fixture.binding_payload()
                                payload["path"] = bad_path
                                fixture.runner_installed.write_bytes(
                                    bind_generated_runner(
                                        fixture.runner_source.read_bytes(),
                                        payload,
                                    )
                                )
                                fixture.runner_installed.chmod(0o755)
                            else:
                                for routine in fixture.routines:
                                    plist = plistlib.loads(routine.plist.read_bytes())
                                    plist["EnvironmentVariables"]["PATH"] = bad_path
                                    routine.plist.write_bytes(
                                        plistlib.dumps(plist, sort_keys=False)
                                    )

                            registry_before = fixture.registry.read_bytes()
                            marker_before = fixture.marker.read_bytes()
                            runner_before = fixture.runner_installed.read_bytes()
                            plists_before = {
                                routine.plist: routine.plist.read_bytes()
                                for routine in fixture.routines
                            }
                            if source == "binding":
                                with self.assertRaises(cutover.CutoverError):
                                    cutover.prepare_codex_compensation()
                                environment = fixture.launchd_environment
                            else:
                                with mock.patch.object(
                                    cutover,
                                    "LAUNCHD_ENVIRONMENT",
                                    None,
                                ):
                                    cutover.bind_locked_registry_runtime()
                                environment = {
                                    **fixture.launchd_environment,
                                    "PATH": bad_path,
                                }

                            with mock.patch.object(
                                cutover,
                                "LAUNCHD_ENVIRONMENT",
                                environment,
                            ), self.assertRaises(cutover.CutoverError):
                                cutover.refresh_runtime_artifact(
                                    fixture.routines_tuple,
                                    command_runner=fixture.commands,
                                )

                            self.assertEqual(fixture.registry.read_bytes(), registry_before)
                            self.assertEqual(fixture.marker.read_bytes(), marker_before)
                            self.assertEqual(
                                fixture.runner_installed.read_bytes(),
                                runner_before,
                            )
                            self.assertEqual(
                                {
                                    routine.plist: routine.plist.read_bytes()
                                    for routine in fixture.routines
                                },
                                plists_before,
                            )
                            self.assertFalse(
                                any(
                                    event.startswith(prefix)
                                    for event in fixture.commands.events
                                    for prefix in (
                                        "ticker wrap",
                                        "ticker unwrap",
                                        "ticker doctor",
                                        "launchctl bootout",
                                        "launchctl bootstrap",
                                    )
                                )
                            )
                            if source == "plist":
                                result, _transactions, _factory = fixture.run_main(
                                    ["--rollback"],
                                    fixture.launchd_environment["PATH"],
                                )
                                self.assertEqual(result, 0)
                                fixture.assert_claude_state(self)

    def test_registry_publication_retries_after_selected_rows_are_rewritten(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                false_publications = 0
                plist_publication_attempts: list[int] = []
                real_publish = cutover.publish_registry_enabled
                real_atomic_write = cutover.atomic_write

                def publish_then_rewrite_once(
                    enabled: bool,
                    routines: object,
                    required_before: object,
                ) -> None:
                    nonlocal false_publications
                    real_publish(enabled, routines, required_before)
                    if not enabled:
                        false_publications += 1
                        if false_publications == 1:
                            real_publish(True, routines, required_before=False)

                def observe_plist_publication(path: Path, data: bytes, mode: int) -> None:
                    if path in {routine.plist for routine in fixture.routines}:
                        plist_publication_attempts.append(false_publications)
                    real_atomic_write(path, data, mode)

                with mock.patch.object(
                    cutover,
                    "publish_registry_enabled",
                    publish_then_rewrite_once,
                ):
                    with mock.patch.object(
                        cutover,
                        "atomic_write",
                        observe_plist_publication,
                    ):
                        state = fixture.transaction().execute()

                self.assertTrue(state.committed)
                self.assertEqual(false_publications, 2)
                self.assertEqual(plist_publication_attempts, [2] * 6)
                self.assertEqual(set(fixture.selected_enabled().values()), {False})

    def test_registry_publication_rewrite_exhaustion_fails_before_activation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                false_publications = 0
                real_publish = cutover.publish_registry_enabled

                def publish_then_rewrite(
                    enabled: bool,
                    routines: object,
                    required_before: object,
                ) -> None:
                    nonlocal false_publications
                    real_publish(enabled, routines, required_before)
                    if not enabled:
                        false_publications += 1
                        real_publish(True, routines, required_before=False)

                with mock.patch.object(
                    cutover,
                    "publish_registry_enabled",
                    publish_then_rewrite,
                ):
                    with self.assertRaisesRegex(
                        cutover.CutoverError,
                        "3 quiesced publication attempts",
                    ):
                        fixture.transaction().execute()

                self.assertEqual(
                    false_publications,
                    cutover.REGISTRY_PUBLICATION_ATTEMPTS,
                )
                self.assertFalse(
                    any(
                        event.startswith("launchctl bootstrap")
                        for event in fixture.commands.events
                    )
                )
                self.assertTrue(
                    all(not routine.plist.exists() for routine in fixture.routines)
                )
                fixture.assert_claude_state(self)

    def test_registry_selection_is_revalidated_after_quiescence(self) -> None:
        phases = (
            "fresh-forward",
            "partial-recovery",
            "committed-rollback",
            "marker-absent-rollback",
        )
        selection_changes = ("changed", "ambiguous")

        for phase in phases:
            for selection_change in selection_changes:
                with self.subTest(
                    phase=phase,
                    selection_change=selection_change,
                ), tempfile.TemporaryDirectory() as directory:
                    with CutoverFixture(Path(directory)) as fixture:
                        if phase == "partial-recovery":
                            fixture.prepare_partial(generated=3, wrapped=0, loaded=0)
                        elif phase == "committed-rollback":
                            fixture.prepare_state(
                                plist_states=["wrapped"] * 6,
                                loaded=6,
                                registry_enabled=False,
                                marker_exact=True,
                            )
                        elif phase == "marker-absent-rollback":
                            fixture.prepare_state(
                                plist_states=["absent"] * 6,
                                loaded=0,
                                registry_enabled=True,
                                marker_exact=False,
                            )

                        self.assertEqual(
                            cutover.discover_claude_registry(
                                fixture.home,
                                fixture.routines_tuple,
                            ),
                            fixture.registry,
                        )
                        fixture.commands.claude_running = True
                        fixture.commands.claude_relaunched = False
                        fixture.commands.events.clear()
                        before_plists = {
                            routine.plist: (
                                routine.plist.read_bytes()
                                if os.path.lexists(routine.plist)
                                else None
                            )
                            for routine in fixture.routines
                        }
                        before_marker = (
                            fixture.marker.read_bytes()
                            if fixture.marker.exists()

                            else None
                        )
                        second_registry = (
                            fixture.sessions_root
                            / "account replacement"
                            / "session replacement"
                            / "scheduled-tasks.json"
                        )
                        real_stop_claude = cutover.stop_claude
                        real_discover_registry = cutover.discover_claude_registry
                        real_atomic_write = cutover.atomic_write
                        injected = False
                        engine_writes: list[Path] = []
                        engine_paths = {
                            fixture.registry,
                            fixture.marker,
                            *(routine.plist for routine in fixture.routines),
                        }

                        def change_selection_after_stop(
                            command_runner: object,
                            known_pids: object = None,
                            observe_pids: object = None,
                        ) -> object:
                            nonlocal injected
                            stopped = real_stop_claude(
                                command_runner,
                                known_pids,
                                observe_pids,
                            )
                            if not injected:
                                write_registry(
                                    second_registry,
                                    fixture.routines_tuple,
                                )
                                second_registry.chmod(0o600)
                                if selection_change == "changed":
                                    write_registry(fixture.registry, ())
                                    fixture.registry.chmod(0o600)
                                injected = True
                            return stopped

                        def observe_engine_write(
                            path: Path,
                            data: bytes,
                            mode: int,
                        ) -> None:
                            if path in engine_paths:
                                engine_writes.append(path)
                            real_atomic_write(path, data, mode)

                        transaction = fixture.transaction()
                        operation = (
                            transaction.rollback_committed
                            if phase in {
                                "committed-rollback",
                                "marker-absent-rollback",
                            }
                            else transaction.execute
                        )
                        with mock.patch.object(
                            cutover,
                            "stop_claude",
                            change_selection_after_stop,
                        ), mock.patch.object(
                            cutover,
                            "discover_claude_registry",
                            wraps=real_discover_registry,
                        ) as registry_discovery, mock.patch.object(
                            cutover,
                            "atomic_write",
                            observe_engine_write,
                        ), mock.patch.object(
                            cutover,
                            "create_audit_backup",
                            wraps=cutover.create_audit_backup,
                        ) as audit_backup:
                            with self.assertRaises(
                                (cutover.CutoverError, cutover.RollbackError)
                            ):
                                operation()

                        self.assertTrue(injected)
                        registry_discovery.assert_called()
                        audit_backup.assert_not_called()
                        self.assertEqual(engine_writes, [])
                        self.assertEqual(
                            {
                                routine.plist: (
                                    routine.plist.read_bytes()
                                    if os.path.lexists(routine.plist)
                                    else None
                                )
                                for routine in fixture.routines
                            },
                            before_plists,
                        )
                        self.assertEqual(
                            (
                                fixture.marker.read_bytes()
                                if fixture.marker.exists()
                                else None
                            ),
                            before_marker,
                        )
                        self.assertFalse(fixture.commands.claude_relaunched)
                        self.assertFalse(fixture.commands.claude_running)
                        self.assertFalse(
                            any(
                                event.startswith(
                                    (
                                        "open ",
                                        "launchctl bootout",
                                        "launchctl bootstrap",
                                        "ticker wrap",
                                        "ticker unwrap",
                                        "ticker doctor --clear-stale",
                                    )
                                )
                                for event in fixture.commands.events
                            )
                        )

    def test_registry_ambiguity_after_publication_is_caught_before_commit(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                second_registry = (
                    fixture.sessions_root
                    / "account concurrent"
                    / "session concurrent"
                    / "scheduled-tasks.json"
                )
                real_publish = cutover.publish_registry_enabled
                real_discover = cutover.discover_claude_registry
                publication_complete = False
                ambiguity_injected = False
                discoveries_after_publication = 0

                def publish_then_create_ambiguity(
                    enabled: bool,
                    routines: object,
                    required_before: object,
                ) -> None:
                    nonlocal publication_complete, ambiguity_injected
                    real_publish(enabled, routines, required_before)
                    if not enabled and not ambiguity_injected:
                        write_registry(second_registry, fixture.routines_tuple)
                        second_registry.chmod(0o600)
                        publication_complete = True
                        ambiguity_injected = True

                def discover_with_publication_fence(
                    home: Path,
                    routines: object,
                ) -> Path:
                    nonlocal discoveries_after_publication
                    if publication_complete:
                        discoveries_after_publication += 1
                    return real_discover(home, routines)

                transaction = fixture.transaction()
                with mock.patch.object(
                    cutover,
                    "publish_registry_enabled",
                    publish_then_create_ambiguity,
                ), mock.patch.object(
                    cutover,
                    "discover_claude_registry",
                    side_effect=discover_with_publication_fence,
                ):
                    with self.assertRaises(
                        (cutover.CutoverError, cutover.RollbackError)
                    ):
                        transaction.execute()

                self.assertTrue(ambiguity_injected)
                self.assertGreater(discoveries_after_publication, 0)
                self.assertFalse(transaction.state.committed)
                self.assertFalse(fixture.marker.exists())
                self.assertEqual(fixture.commands.loaded, set())
                self.assertFalse(
                    any(
                        event.startswith("launchctl bootstrap")
                        for event in fixture.commands.events
                    )
                )

    def test_post_commit_relaunch_registry_selection_race_fails_closed_with_codex_intact(
        self,
    ) -> None:
        expected_errors = {
            "changed": "selection changed",
            "ambiguous": "multiple Claude registries",
        }

        for selection_change, expected_error in expected_errors.items():
            with self.subTest(
                selection_change=selection_change
            ), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    second_registry = (
                        fixture.sessions_root
                        / "account relaunched"
                        / "session relaunched"
                        / "scheduled-tasks.json"
                    )
                    transaction = fixture.transaction()
                    phase_events: list[str] = []
                    engine_at_open: dict[str, object] = {}
                    real_atomic_write = cutover.atomic_write
                    real_discover_registry = cutover.discover_claude_registry

                    def observe_marker_publication(
                        path: Path,
                        data: bytes,
                        mode: int,
                    ) -> None:
                        real_atomic_write(path, data, mode)
                        if path == fixture.marker:
                            phase_events.append("marker-published")

                    def inject_registry_race_from_open() -> None:
                        phase_events.append("fake-open")
                        self.assertTrue(transaction.state.committed)
                        self.assertEqual(
                            fixture.marker.read_bytes(),
                            cutover.MARKER_PAYLOAD,
                        )
                        self.assertFalse(second_registry.exists())
                        self.assertEqual(engine_at_open, {})
                        engine_at_open.update(
                            {
                                "plists": {
                                    routine.plist: routine.plist.read_bytes()
                                    for routine in fixture.routines
                                },
                                "loaded": set(fixture.commands.loaded),
                                "wrapped": set(fixture.commands.wrapped),
                                "backups": set(
                                    fixture.commands.authenticated_backups
                                ),
                            }
                        )
                        write_registry(second_registry, fixture.routines_tuple)
                        second_registry.chmod(0o600)
                        if selection_change == "changed":
                            write_registry(fixture.registry, ())
                            fixture.registry.chmod(0o600)
                        phase_events.append(f"injected-{selection_change}")

                    def discover_with_post_relaunch_fence(
                        home: Path,
                        routines: object,
                    ) -> Path:
                        if second_registry.exists():
                            phase_events.append("post-relaunch-fence")
                        return real_discover_registry(home, routines)

                    fixture.commands.on_open = inject_registry_race_from_open
                    with mock.patch.object(
                        cutover,
                        "atomic_write",
                        observe_marker_publication,
                    ), mock.patch.object(
                        cutover,
                        "discover_claude_registry",
                        side_effect=discover_with_post_relaunch_fence,
                    ):
                        with self.assertRaisesRegex(
                            cutover.CutoverError,
                            expected_error,
                        ):
                            transaction.execute()

                    self.assertEqual(
                        phase_events[:3],
                        [
                            "marker-published",
                            "fake-open",
                            f"injected-{selection_change}",
                        ],
                    )
                    self.assertTrue(phase_events[3:])
                    self.assertEqual(set(phase_events[3:]), {"post-relaunch-fence"})
                    self.assertTrue(transaction.state.committed)
                    self.assertFalse(transaction.state.rolled_back)
                    self.assertTrue(transaction.state.registry_disabled)
                    self.assertTrue(transaction.state.replacements_verified)
                    self.assertTrue(transaction.state.claude_was_running)
                    self.assertTrue(fixture.commands.claude_relaunched)
                    self.assertFalse(fixture.commands.claude_running)
                    self.assertEqual(
                        fixture.marker.read_bytes(),
                        cutover.MARKER_PAYLOAD,
                    )
                    self.assertEqual(
                        {
                            routine.plist: routine.plist.read_bytes()
                            for routine in fixture.routines
                        },
                        engine_at_open["plists"],
                    )
                    self.assertEqual(
                        fixture.commands.loaded,
                        engine_at_open["loaded"],
                    )
                    self.assertEqual(
                        fixture.commands.wrapped,
                        engine_at_open["wrapped"],
                    )
                    self.assertEqual(
                        fixture.commands.authenticated_backups,
                        engine_at_open["backups"],
                    )
                    for routine in fixture.routines:
                        cutover.validate_plist(routine, wrapped=True)

                    task_ids = {routine.task_id for routine in fixture.routines}
                    second_rows = json.loads(
                        second_registry.read_text(encoding="utf-8")
                    )["scheduledTasks"]
                    self.assertEqual(
                        {
                            row["id"]: row["enabled"]
                            for row in second_rows
                            if row.get("id") in task_ids
                        },
                        {task_id: True for task_id in task_ids},
                    )
                    if selection_change == "changed":
                        self.assertEqual(fixture.selected_enabled(), {})
                    else:
                        self.assertEqual(
                            fixture.selected_enabled(),
                            {task_id: False for task_id in task_ids},
                        )

                    quit_event = 'osascript -e tell application "Claude" to quit'
                    mutating_events = [
                        event
                        for event in fixture.commands.events
                        if event.startswith(
                            (
                                "osascript ",
                                "open ",
                                "launchctl bootout",
                                "launchctl bootstrap",
                                "ticker wrap",
                                "ticker unwrap",
                                "ticker doctor --clear-stale",
                            )
                        )
                    ]
                    self.assertEqual(
                        mutating_events,
                        [
                            quit_event,
                            *[
                                f"ticker wrap {routine.ticker_id}"
                                for routine in fixture.routines
                            ],
                            *[
                                "launchctl bootstrap "
                                f"gui/{os.getuid()} {routine.plist}"
                                for routine in fixture.routines
                            ],
                            "open -a Claude",
                            quit_event,
                        ],
                    )

    def test_full_activation_failure_removes_plists_and_restores_claude(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                original_unrelated = fixture.registry_document()["scheduledTasks"][0]
                fixture.commands.failures["bootstrap"] = 1
                with self.assertRaisesRegex(cutover.CutoverError, "bootstrap failed"):
                    fixture.transaction().execute()
                self.assertEqual(
                    fixture.registry_document()["scheduledTasks"][0], original_unrelated
                )
                fixture.assert_claude_state(self)

    def test_success_marker_is_published_only_after_all_six_verify(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.commands.claude_running = False
                publications: list[tuple[set[str], set[str]]] = []
                real_atomic_write = cutover.atomic_write

                def observing_atomic_write(path: Path, data: bytes, mode: int) -> None:
                    if path == fixture.marker:
                        publications.append(
                            (set(fixture.commands.loaded), set(fixture.commands.wrapped))
                        )
                    real_atomic_write(path, data, mode)

                with mock.patch.object(cutover, "atomic_write", observing_atomic_write):
                    state = fixture.transaction().execute()
                labels = {routine.label for routine in fixture.routines}
                task_ids = {routine.task_id for routine in fixture.routines}
                self.assertTrue(state.committed)
                fixture.assert_codex_state(self)
                self.assertEqual(publications, [(labels, task_ids)])
                self.assertEqual(fixture.marker.read_bytes(), cutover.MARKER_PAYLOAD)
                self.assertEqual(set(fixture.selected_enabled().values()), {False})
                binding = cutover.read_runtime_binding(fixture.runner_installed)
                self.assertEqual(binding.binding_version, 2)
                self.assertEqual(binding.uid, os.getuid())
                self.assertEqual(binding.home, fixture.home)
                self.assertEqual(binding.repository, fixture.working_directory)
                self.assertEqual(binding.python, Path(sys.executable))
                self.assertEqual(binding.codex, fixture.codex)
                self.assertEqual(binding.path, fixture.launchd_environment["PATH"])
                self.assertEqual(binding.model, "gpt-5.6-sol")
                self.assertEqual(binding.codex_sha256, native_digest(fixture.codex))
                self.assertEqual(binding.codex_macho_arch, host_native_arch())
                self.assertEqual(binding.codex_managed_package_root, None)
                self.assertEqual(binding.codex_managed_package_version, None)
                self.assertEqual(binding.codex_managed_by, "direct")
                self.assertEqual(
                    binding.skill_roots,
                    {
                        routine.task_id: routine.root.canonical_root
                        for routine in fixture.routines
                    },
                )
                self.assertEqual(
                    fixture.runner_installed.read_bytes().splitlines()[0],
                    f"#!{sys.executable} -I".encode("utf-8"),
                )
                backups = list(
                    fixture.registry.parent.glob(
                        f"{fixture.registry.name}.ticker-codex-SKY-14155.audit.*.json"
                    )
                )
                self.assertEqual(len(backups), 1)
                self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)

    def test_signal_after_registry_disable_uses_same_safe_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.commands.raise_signal_on_wrap = True
                with self.assertRaises(cutover.CutoverSignal) as raised:
                    fixture.transaction().execute()
                self.assertEqual(raised.exception.signum, signal.SIGTERM)
                fixture.assert_claude_state(self)

    def test_committed_rollback_uses_stored_environment_when_current_codex_is_missing(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=6,
                    registry_enabled=False,
                    marker_exact=True,
                )
                missing_codex_path = fixture.root / "empty caller path"
                missing_codex_path.mkdir()
                real_discover_codex = cutover.discover_codex_executable

                with mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                    wraps=real_discover_codex,
                ) as discover_codex:
                    result, transactions, _factory = fixture.run_main(
                        ["--rollback"],
                        str(missing_codex_path),
                    )

                self.assertEqual(result, 0)
                discover_codex.assert_not_called()
                self.assertEqual(len(transactions), 1)
                self.assertTrue(transactions[0].state.rolled_back)
                self.assertTrue(transactions[0].state.claude_relaunched)
                fixture.assert_claude_state(self)

    def test_main_rollback_restores_exact_disabled_absent_boundary_without_stored_environment(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture, mock.patch.object(
                cutover,
                "LAUNCHD_ENVIRONMENT",
                None,
            ), mock.patch.object(
                cutover,
                "CODEX_EXECUTABLE",
                None,
            ):
                fixture.prepare_state(
                    plist_states=["absent"] * 6,
                    loaded=0,
                    registry_enabled=False,
                    marker_exact=True,
                )
                fixture.commands.events.clear()
                missing_codex_path = fixture.root / "empty caller path"
                missing_codex_path.mkdir()
                transactions: list[object] = []
                binding_phases: list[str] = []
                transaction_class = cutover.CutoverTransaction
                real_configure_static_runtime = cutover.configure_static_runtime
                real_bind_locked_registry_runtime = (
                    cutover.bind_locked_registry_runtime
                )
                real_discover_stored_environment = (
                    cutover.discover_stored_launchd_environment
                )
                real_discover_codex = cutover.discover_codex_executable

                def configure_static_runtime() -> None:
                    binding_phases.append("configure-static")
                    real_configure_static_runtime()
                    self.assertEqual(cutover.HOME_DIRECTORY, fixture.home)
                    self.assertEqual(cutover.SESSIONS_ROOT, fixture.sessions_root)
                    self.assertIsNone(cutover.LAUNCHD_ENVIRONMENT)
                    self.assertIsNone(cutover.CODEX_EXECUTABLE)

                def bind_locked_registry_runtime() -> None:
                    self.assertEqual(binding_phases, ["configure-static"])
                    binding_phases.append("bind-locked")
                    real_bind_locked_registry_runtime()
                    self.assertEqual(cutover.REGISTRY, fixture.registry)
                    self.assertEqual(cutover.SUCCESS_MARKER, fixture.marker)
                    self.assertIsNone(cutover.LAUNCHD_ENVIRONMENT)
                    self.assertIsNone(cutover.CODEX_EXECUTABLE)

                def build_transaction(routines: object = None) -> object:
                    self.assertEqual(
                        binding_phases,
                        ["configure-static", "bind-locked"],
                    )
                    binding_phases.append("transaction")
                    self.assertIsNone(cutover.LAUNCHD_ENVIRONMENT)
                    self.assertIsNone(cutover.CODEX_EXECUTABLE)
                    selected_routines = (
                        cutover.ROUTINES if routines is None else routines
                    )
                    transaction = transaction_class(
                        selected_routines,
                        command_runner=fixture.commands,
                        clock=lambda: dt.datetime(
                            2026,
                            8,
                            15,
                            10,
                            30,
                            tzinfo=cutover.NEW_YORK,
                        ),
                    )
                    transactions.append(transaction)
                    return transaction

                with mock.patch.object(
                    cutover,
                    "configure_static_runtime",
                    side_effect=configure_static_runtime,
                ) as static_binding, mock.patch.object(
                    cutover,
                    "bind_locked_registry_runtime",
                    side_effect=bind_locked_registry_runtime,
                ) as locked_binding, mock.patch.object(
                    cutover,
                    "discover_stored_launchd_environment",
                    wraps=real_discover_stored_environment,
                ) as stored_environment, mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                    wraps=real_discover_codex,
                ) as discover_codex, mock.patch.object(
                    cutover.sys,
                    "stdout",
                    io.StringIO(),
                ) as standard_output, mock.patch.object(
                    cutover.sys,
                    "stderr",
                    io.StringIO(),
                ) as error_output:
                    result, fixture_transactions, factory = fixture.run_main(
                        ["--rollback"],
                        str(missing_codex_path),
                        build_transaction,
                    )

                self.assertEqual(result, 0)
                self.assertEqual(
                    standard_output.getvalue(),
                    f"{cutover.TICKET} scheduled-routine rollback completed\n",
                )
                self.assertEqual(error_output.getvalue(), "")
                self.assertEqual(
                    binding_phases,
                    ["configure-static", "bind-locked", "transaction"],
                )
                static_binding.assert_called_once_with()
                locked_binding.assert_called_once_with()
                stored_environment.assert_called_once_with(fixture.routines_tuple)
                discover_codex.assert_not_called()
                factory.assert_called_once_with(fixture.routines_tuple)
                self.assertEqual(fixture_transactions, [])
                self.assertEqual(len(transactions), 1)
                state = transactions[0].state
                self.assertTrue(state.registry_disabled)
                self.assertTrue(state.rolled_back)
                self.assertFalse(state.committed)
                self.assertTrue(state.claude_relaunched)
                self.assertFalse(state.claude_was_running)
                self.assertEqual(state.claude_prior_pids, frozenset())
                self.assertIsNone(cutover.LAUNCHD_ENVIRONMENT)
                self.assertIsNone(cutover.CODEX_EXECUTABLE)
                fixture.assert_claude_state(self)
                self.assertEqual(
                    [
                        event
                        for event in fixture.commands.events
                        if event.startswith(
                            (
                                "osascript ",
                                "open ",
                                "launchctl bootout",
                                "launchctl bootstrap",
                                "ticker wrap",
                                "ticker unwrap",
                                "ticker doctor --clear-stale",
                            )
                        )
                    ],
                    ["open -a Claude"],
                )

    def test_partial_recovery_ignores_changed_current_codex_path(self) -> None:
        cases = [("registry", 0, 0, 0)]
        cases.extend((f"generate-{count}", count, 0, 0) for count in range(1, 7))
        cases.extend((f"wrap-{count}", 6, count, 0) for count in range(1, 7))
        cases.extend((f"bootstrap-{count}", 6, 6, count) for count in range(1, 7))
        cases.append(("pre-marker", 6, 6, 6))

        for name, generated, wrapped, loaded in cases:
            with self.subTest(boundary=name), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    fixture.prepare_partial(
                        generated=generated,
                        wrapped=wrapped,
                        loaded=loaded,
                    )
                    current_codex = fixture.make_codex("changed caller path")
                    self.assertNotEqual(
                        cutover.build_controlled_path(fixture.home, current_codex),
                        fixture.launchd_environment["PATH"],
                    )
                    real_discover_codex = cutover.discover_codex_executable

                    with mock.patch.object(
                        cutover,
                        "discover_codex_executable",
                        wraps=real_discover_codex,
                    ) as discover_codex:
                        result, transactions, _factory = fixture.run_main(
                            [],
                            str(current_codex.parent),
                        )

                    self.assertEqual(result, 0)
                    discover_codex.assert_not_called()
                    self.assertEqual(len(transactions), 1)
                    self.assertTrue(transactions[0].state.recovered)
                    self.assertFalse(transactions[0].state.committed)
                    fixture.assert_claude_state(self)

    def test_zero_plist_partial_recovery_does_not_discover_codex(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_partial(generated=0, wrapped=0, loaded=0)
                missing_codex_path = fixture.root / "empty caller path"
                missing_codex_path.mkdir()
                real_discover_codex = cutover.discover_codex_executable

                with mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                    wraps=real_discover_codex,
                ) as discover_codex:
                    result, transactions, _factory = fixture.run_main(
                        [],
                        str(missing_codex_path),
                    )


                self.assertEqual(result, 0)
                discover_codex.assert_not_called()
                self.assertEqual(len(transactions), 1)
                self.assertTrue(transactions[0].state.recovered)
                fixture.assert_claude_state(self)

    def test_zero_plist_compensation_derives_environment_from_installed_binding(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_partial(generated=0, wrapped=0, loaded=0)
                fixture.commands.fail_once("ps")
                events_before = list(fixture.commands.events)
                with mock.patch.object(
                    cutover,
                    "LAUNCHD_ENVIRONMENT",
                    None,
                ), mock.patch.object(
                    cutover,
                    "CODEX_EXECUTABLE",
                    None,
                ), mock.patch.object(
                    cutover,
                    "discover_codex_executable",
                ) as discovery:
                    with self.assertRaises(cutover.RollbackError):
                        fixture.transaction().execute()
                discovery.assert_not_called()
                self.assertNotEqual(fixture.commands.events, events_before)
                fixture.assert_codex_state(self)


    def test_inconsistent_stored_plist_environments_fail_before_mutation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_partial(generated=2, wrapped=0, loaded=0)
                changed_codex = fixture.make_codex("different stored path")
                changed_environment = {
                    "HOME": str(fixture.home),
                    "PATH": cutover.build_controlled_path(
                        fixture.home,
                        changed_codex,
                    ),
                    "TZ": "America/New_York",
                }
                changed_plist = fixture.routines[1].plist
                payload = plistlib.loads(changed_plist.read_bytes())
                payload["EnvironmentVariables"] = changed_environment
                changed_plist.write_bytes(
                    plistlib.dumps(payload, sort_keys=False)
                )
                changed_plist.chmod(0o644)
                fixture.commands.events.clear()
                registry_before = fixture.registry.read_bytes()
                plists_before = {
                    routine.plist: (
                        routine.plist.read_bytes()
                        if os.path.lexists(routine.plist)
                        else None
                    )
                    for routine in fixture.routines
                }
                discover_stored_environment = getattr(
                    cutover,
                    "discover_stored_launchd_environment",
                    None,
                )

                result, transactions, factory = fixture.run_main(
                    [],
                    str(fixture.codex.parent),
                )

                self.assertEqual(result, 1)
                factory.assert_not_called()
                self.assertEqual(transactions, [])
                self.assertTrue(
                    callable(discover_stored_environment),
                    "discover_stored_launchd_environment() must bind persisted plist state",
                )
                self.assertEqual(fixture.registry.read_bytes(), registry_before)
                self.assertEqual(
                    {
                        routine.plist: (
                            routine.plist.read_bytes()
                            if os.path.lexists(routine.plist)
                            else None
                        )
                        for routine in fixture.routines
                    },
                    plists_before,
                )
                self.assertEqual(fixture.commands.events, [])
                self.assertTrue(fixture.runner_installed.exists())
                self.assertEqual(
                    list(
                        fixture.registry.parent.glob(
                            f"{fixture.registry.name}.ticker-codex-"
                            f"{cutover.TICKET}.audit.*.json"
                        )
                    ),
                    [],
                )

    def test_fresh_rollback_converges_every_exact_marker_boundary(self) -> None:
        enabled_cases: list[tuple[str, list[str], int]] = [
            ("registry-enabled", ["wrapped"] * 6, 6),
        ]
        enabled_cases.extend(
            (f"bootout-{count}", ["wrapped"] * 6, count)
            for count in range(5, -1, -1)
        )
        enabled_cases.extend(
            (
                f"unwrap-{count}",
                ["wrapped"] * count + ["original"] * (6 - count),
                0,
            )
            for count in range(5, -1, -1)
        )
        enabled_cases.extend(
            (
                f"remove-{count}",
                ["original"] * (6 - count) + ["absent"] * count,
                0,
            )
            for count in range(1, 7)
        )
        disabled_cases: list[tuple[str, list[str], int]] = [
            ("compensate-absent", ["absent"] * 6, 0),
        ]
        disabled_cases.extend(
            (
                f"compensate-generate-{count}",
                ["original"] * count + ["absent"] * (6 - count),
                0,
            )
            for count in range(1, 7)
        )
        disabled_cases.extend(
            (
                f"compensate-wrap-{count}",
                ["wrapped"] * count + ["original"] * (6 - count),
                0,
            )
            for count in range(1, 7)
        )
        disabled_cases.extend(
            (f"compensate-bootstrap-{count}", ["wrapped"] * 6, count)
            for count in range(7)
        )

        cases = [
            (name, states, loaded, True)
            for name, states, loaded in enabled_cases
        ] + [
            (name, states, loaded, False)
            for name, states, loaded in disabled_cases
        ]
        for name, states, loaded, registry_enabled in cases:
            with self.subTest(boundary=name), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    fixture.prepare_state(
                        plist_states=states,
                        loaded=loaded,
                        registry_enabled=registry_enabled,
                        marker_exact=True,
                    )
                    state = fixture.transaction().rollback_committed()
                    self.assertTrue(state.rolled_back)
                    fixture.assert_claude_state(self)

    def test_fresh_rollback_accepts_the_marker_removed_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["absent"] * 6,
                    loaded=0,
                    registry_enabled=True,
                    marker_exact=False,
                )
                state = fixture.transaction().rollback_committed()
                self.assertTrue(state.rolled_back)
                fixture.assert_claude_state(self)

    def test_store_aware_classification_rejects_unsafe_doctor_states_before_mutation(self) -> None:
        cases = (
            ("missing-backup", None),
            ("backup-content-mismatch", "wrapped-backup-content-mismatch"),
            ("foreign-label", "wrapped-foreign-label (launchd:foreign#123)"),
            ("doctor-error", "error"),
        )
        for name, override in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    fixture.prepare_state(
                        plist_states=["wrapped"] * 6,
                        loaded=0,
                        registry_enabled=False,
                        marker_exact=False,
                    )
                    target = fixture.routines[2]
                    if name == "missing-backup":
                        fixture.commands.authenticated_backups.remove(target.task_id)
                    elif name == "doctor-error":
                        fixture.commands.fail_once("doctor")
                    else:
                        assert override is not None
                        fixture.commands.doctor_overrides[target.task_id] = override
                    fixture.commands.events.clear()

                    with self.assertRaisesRegex(cutover.CutoverError, "Ticker"):
                        fixture.transaction().execute()

                    fixture.assert_no_engine_mutation(self)

    def test_mark_managed_before_plist_write_is_cleared_through_exact_doctor_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_partial(generated=6, wrapped=0, loaded=0)
                target = fixture.routines[0]
                fixture.commands.interrupt_wrap_after_mark = True
                result = fixture.commands.run(
                    cutover.TICKER_EXECUTABLE,
                    ["wrap", target.ticker_id],
                )
                self.assertNotEqual(result.status, 0)
                fixture.commands.events.clear()

                state = fixture.transaction().execute()

                self.assertTrue(state.recovered)
                self.assertIn(
                    f"ticker doctor --clear-stale {target.ticker_id}",
                    fixture.commands.events,
                )
                fixture.assert_claude_state(self)

    def test_unwrap_write_before_store_clear_is_repaired_on_fresh_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_state(
                    plist_states=["wrapped"] * 6,
                    loaded=0,
                    registry_enabled=True,
                    marker_exact=True,
                )
                target = fixture.routines[-1]
                fixture.commands.interrupt_unwrap_after_write = True
                result = fixture.commands.run(
                    cutover.TICKER_EXECUTABLE,
                    ["unwrap", target.ticker_id],
                )
                self.assertNotEqual(result.status, 0)
                fixture.commands.events.clear()

                state = fixture.transaction().rollback_committed()

                self.assertTrue(state.rolled_back)
                self.assertIn(
                    f"ticker doctor --clear-stale {target.ticker_id}",
                    fixture.commands.events,
                )
                fixture.assert_claude_state(self)

    def test_unknown_partial_identity_is_rejected_before_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.prepare_partial(generated=6, wrapped=0, loaded=0)
                corrupt = fixture.routines[2]
                payload = cutover.parse_plist(corrupt.plist)
                payload["ProgramArguments"] = ["/unknown"]
                corrupt.plist.write_bytes(plistlib.dumps(payload, sort_keys=False))
                before_registry = fixture.registry.read_bytes()
                before_plists = {
                    routine.plist: routine.plist.read_bytes() for routine in fixture.routines
                }

                with self.assertRaisesRegex(cutover.CutoverError, "unknown"):
                    fixture.transaction().execute()

                self.assertEqual(fixture.registry.read_bytes(), before_registry)
                self.assertEqual(
                    {routine.plist: routine.plist.read_bytes() for routine in fixture.routines},
                    before_plists,
                )
                self.assertFalse(any(event.startswith("osascript ") for event in fixture.commands.events))
                self.assertFalse(any(event.startswith("launchctl bootout") for event in fixture.commands.events))

    def test_explicit_rollback_enables_and_verifies_claude_before_bootout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                observed: list[tuple[set[bool], bool]] = []
                fixture.commands.on_bootout = lambda: observed.append(
                    (set(fixture.selected_enabled().values()), fixture.commands.claude_running)
                )

                state = fixture.transaction().rollback_committed()

                self.assertTrue(state.rolled_back)
                self.assertTrue(state.claude_was_running)
                self.assertTrue(state.claude_relaunched)
                self.assertTrue(observed)
                self.assertTrue(all(item == ({True}, True) for item in observed))
                fixture.assert_claude_state(self)

    def test_explicit_rollback_quiesces_claude_before_fresh_registry_publication(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with CutoverFixture(root) as fixture:
                fixture.transaction().execute()
                fixture.commands.claude_running = False
                publication_process_states: list[bool] = []
                update_injected = False
                real_stop_claude = cutover.stop_claude
                real_atomic_write = cutover.atomic_write

                def stop_and_inject_update(
                    command_runner: object,
                    known_pids: object = None,
                    observe_pids: object = None,
                ) -> object:
                    nonlocal update_injected
                    prior_pids = real_stop_claude(
                        command_runner,
                        known_pids,
                        observe_pids,
                    )
                    if not update_injected:
                        document = fixture.registry_document()
                        document["scheduledTasks"][0]["unrelatedField"] = {
                            "changedAfterStop": True
                        }
                        document["postStopUpdate"] = "keep"
                        fixture.registry.write_text(json.dumps(document), encoding="utf-8")
                        fixture.registry.chmod(0o600)
                        update_injected = True
                    return prior_pids

                def observe_registry_publication(path: Path, data: bytes, mode: int) -> None:
                    if path == fixture.registry:
                        _registry, rows = cutover.selected_registry_rows(
                            data,
                            fixture.routines_tuple,
                        )
                        if all(row["enabled"] for row in rows.values()):
                            publication_process_states.append(
                                fixture.commands.claude_running
                            )
                    real_atomic_write(path, data, mode)

                with mock.patch.object(
                    cutover,
                    "stop_claude",
                    stop_and_inject_update,
                ):
                    with mock.patch.object(
                        cutover,
                        "atomic_write",
                        observe_registry_publication,
                    ):
                        state = fixture.transaction().rollback_committed()

                final = fixture.registry_document()
                self.assertTrue(update_injected)
                self.assertEqual(publication_process_states, [False])
                self.assertFalse(state.claude_was_running)
                self.assertTrue(state.claude_relaunched)
                self.assertEqual(
                    final["scheduledTasks"][0]["unrelatedField"],
                    {"changedAfterStop": True},
                )
                self.assertEqual(final["postStopUpdate"], "keep")
                fixture.assert_claude_state(self)
                self.assertEqual(
                    len(
                        list(
                            fixture.registry.parent.glob(
                                f"{fixture.registry.name}.ticker-codex-"
                                "SKY-14155.audit.*.json"
                            )
                        )
                    ),
                    1,
                )

    def test_rollback_operational_failures_compensate_to_verified_codex(self) -> None:
        for operation in ("bootout", "absence", "unwrap", "ps"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    fixture.transaction().execute()
                    if operation == "ps":
                        fixture.commands.claude_running = False
                    fixture.commands.fail_once(operation)
                    with self.assertRaisesRegex(cutover.RollbackError, "Codex state was restored"):
                        fixture.transaction().rollback_committed()
                    fixture.assert_codex_state(self)

    def test_fresh_retry_converges_after_cleanup_and_first_compensation_both_fail(self) -> None:
        for operation in ("bootout", "unwrap"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    fixture.transaction().execute()
                    fixture.commands.fail_once(operation)
                    fixture.commands.after_failure[operation] = "ps"

                    with self.assertRaisesRegex(
                        cutover.RollbackError,
                        "compensation also failed",
                    ):
                        fixture.transaction().rollback_committed()

                    self.assertEqual(fixture.marker.read_bytes(), cutover.MARKER_PAYLOAD)
                    state = fixture.transaction().rollback_committed()
                    self.assertTrue(state.rolled_back)
                    fixture.assert_claude_state(self)

    def test_fresh_rollback_converges_after_plist_unlink_directory_sync_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                real_fsync_directory = cutover.fsync_directory
                failed = False

                def fail_after_unlink(directory: Path) -> None:
                    nonlocal failed
                    if directory == fixture.routines[-1].plist.parent and not failed:
                        failed = True
                        self.assertFalse(os.path.lexists(fixture.routines[-1].plist))
                        fixture.commands.fail_once("ps")
                        raise OSError("injected plist directory sync failure")
                    real_fsync_directory(directory)

                with mock.patch.object(
                    cutover,
                    "fsync_directory",
                    fail_after_unlink,
                ):
                    with self.assertRaisesRegex(
                        cutover.RollbackError,
                        "compensation also failed",
                    ):
                        fixture.transaction().rollback_committed()

                self.assertTrue(failed)
                self.assertEqual(
                    [os.path.lexists(routine.plist) for routine in fixture.routines],
                    [True] * 5 + [False],
                )
                self.assertEqual(fixture.marker.read_bytes(), cutover.MARKER_PAYLOAD)
                self.assertEqual(set(fixture.selected_enabled().values()), {True})

                state = fixture.transaction().rollback_committed()
                self.assertTrue(state.rolled_back)
                fixture.assert_claude_state(self)

    def test_rollback_registry_write_failure_compensates_to_verified_codex(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                real_atomic_write = cutover.atomic_write
                failed = False

                def fail_enable(path: Path, data: bytes, mode: int) -> None:
                    nonlocal failed
                    if path == fixture.registry and not failed:
                        _registry, rows = cutover.selected_registry_rows(data, fixture.routines_tuple)
                        if all(row["enabled"] for row in rows.values()):
                            failed = True
                            raise OSError("injected registry publication failure")
                    real_atomic_write(path, data, mode)

                with mock.patch.object(cutover, "atomic_write", fail_enable):
                    with self.assertRaisesRegex(cutover.RollbackError, "Codex state was restored"):
                        fixture.transaction().rollback_committed()
                fixture.assert_codex_state(self)

    def test_rollback_plist_removal_failure_compensates_to_verified_codex(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                real_remove = cutover.remove_replacement_plist
                failed = False

                def fail_remove(path: Path) -> None:
                    nonlocal failed
                    if not failed:
                        failed = True
                        raise OSError("injected plist removal failure")
                    real_remove(path)

                with mock.patch.object(cutover, "remove_replacement_plist", fail_remove):
                    with self.assertRaisesRegex(cutover.RollbackError, "Codex state was restored"):
                        fixture.transaction().rollback_committed()
                fixture.assert_codex_state(self)

    def test_rollback_marker_removal_after_unlink_recreates_retry_marker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                failed = False

                def remove_then_fail() -> None:
                    nonlocal failed
                    if not failed:
                        failed = True
                        fixture.marker.unlink()
                        raise OSError("injected marker directory sync failure")
                    cutover.remove_success_marker()

                with mock.patch.object(cutover, "remove_success_marker", remove_then_fail):
                    with self.assertRaisesRegex(cutover.RollbackError, "Codex state was restored"):
                        fixture.transaction().rollback_committed()
                fixture.assert_codex_state(self)

    def test_shutdown_signal_and_poll_failures_restore_enabled_claude(self) -> None:
        cases = ("after-quit", "poll-1", "poll-3", "inventory", "timeout")
        for name in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    if name == "after-quit":
                        fixture.commands.signal_after_quit = True
                    elif name.startswith("poll-"):
                        poll = int(name.rsplit("-", 1)[1])
                        fixture.commands.signal_on_shutdown_poll = poll
                        fixture.commands.quit_process_sequences = [
                            [{812}] * poll
                        ]
                    elif name == "inventory":
                        fixture.commands.fail_once("shutdown-ps")
                    else:
                        fixture.commands.quit_process_sequences = [
                            [{812}] * cutover.CLAUDE_POLL_ATTEMPTS
                        ]

                    expected = (
                        cutover.CutoverSignal
                        if name in {"after-quit", "poll-1", "poll-3"}
                        else cutover.CutoverError
                    )
                    with self.assertRaises(expected):
                        fixture.transaction().execute()

                    fixture.assert_claude_state(self)
                    self.assertTrue(fixture.commands.claude_relaunched)

    def test_partial_recovery_shutdown_failures_are_guarded_by_codex_compensation(self) -> None:
        cases = ("signal", "inventory", "timeout")
        for name in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    fixture.prepare_partial(generated=3, wrapped=0, loaded=0)
                    fixture.commands.claude_pids = {812}
                    if name == "signal":
                        fixture.commands.signal_after_quit = True
                    elif name == "inventory":
                        fixture.commands.fail_once("shutdown-ps")
                    else:
                        fixture.commands.quit_process_sequences = [
                            [{812}] * cutover.CLAUDE_POLL_ATTEMPTS
                        ]

                    expected = cutover.CutoverSignal if name == "signal" else cutover.RollbackError
                    with self.assertRaises(expected):
                        fixture.transaction().execute()

                    fixture.assert_codex_state(self)

    def test_absent_then_new_pid_is_stopped_and_added_to_rollback_custody(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                replacement_pid = 913
                fixture.commands.claude_pids = set()
                fixture.commands.ps_sequence = [set(), {replacement_pid}]

                state = fixture.transaction().execute()

                self.assertTrue(state.committed)
                self.assertTrue(state.claude_was_running)
                self.assertEqual(state.claude_prior_pids, frozenset({replacement_pid}))
                self.assertTrue(state.claude_relaunched)
                self.assertEqual(
                    sum(
                        event.startswith("osascript ")
                        for event in fixture.commands.events
                    ),
                    1,
                )
                self.assertEqual(set(fixture.selected_enabled().values()), {False})
                self.assertTrue(fixture.commands.claude_running)
                self.assertTrue(fixture.marker.exists())

    def test_old_pid_exit_then_new_pid_is_requit_and_both_enter_custody(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                replacement_pid = 913
                fixture.commands.quit_process_sequences = [[{replacement_pid}]]

                state = fixture.transaction().execute()

                self.assertTrue(state.committed)
                self.assertTrue(state.claude_was_running)
                self.assertEqual(
                    state.claude_prior_pids,
                    frozenset({812, replacement_pid}),
                )
                self.assertTrue(state.claude_relaunched)
                self.assertEqual(
                    sum(
                        event.startswith("osascript ")
                        for event in fixture.commands.events
                    ),
                    2,
                )
                self.assertEqual(set(fixture.selected_enabled().values()), {False})
                self.assertTrue(fixture.commands.claude_running)
                self.assertTrue(fixture.marker.exists())

    def test_desktop_pid_inventory_ignores_claude_cli_and_helpers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.commands.claude_pids = set()
                fixture.commands.extra_processes = [
                    (
                        101,
                        f"{fixture.root / 'home with spaces' / '.local' / 'bin' / 'claude'} "
                        "--resume",
                    ),
                    (
                        102,
                        "/Applications/Claude.app/Contents/Frameworks/"
                        "Claude Helper.app/Contents/MacOS/Claude Helper --type=renderer",
                    ),
                ]
                self.assertEqual(
                    cutover.claude_desktop_pids(fixture.commands),
                    frozenset(),
                )
                self.assertFalse(cutover.claude_is_running(fixture.commands))

    def test_restart_stops_preexisting_desktop_pid_and_requires_a_new_pid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                prior_pids = frozenset(fixture.commands.claude_pids)

                state = fixture.transaction().rollback_committed()

                self.assertTrue(state.rolled_back)
                self.assertTrue(prior_pids)
                self.assertTrue(prior_pids.isdisjoint(fixture.commands.claude_pids))
                fixture.assert_claude_state(self)

    def test_restart_rejects_open_that_only_reports_the_preexisting_pid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                prior_pid = next(iter(fixture.commands.claude_pids))
                fixture.commands.open_process_states = [{prior_pid}] * 3

                with self.assertRaisesRegex(cutover.RollbackError, "Codex state was restored"):
                    fixture.transaction().rollback_committed()

                fixture.assert_codex_state(self)

    def test_relaunch_rejects_open_nonzero_and_open_zero_without_process(self) -> None:
        cases = (("nonzero", 7, None), ("no-process", 0, []))
        for name, status, process_states in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                with CutoverFixture(Path(directory)) as fixture:
                    fixture.transaction().execute()
                    fixture.commands.claude_running = False
                    fixture.commands.open_status = status
                    fixture.commands.open_process_states = process_states
                    with self.assertRaisesRegex(cutover.RollbackError, "Codex state was restored"):
                        fixture.transaction().rollback_committed()
                    fixture.assert_codex_state(self)

    def test_relaunch_accepts_delayed_stable_start(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                fixture.commands.claude_running = False
                fixture.commands.open_process_states = [False, False, True, True, True]

                state = fixture.transaction().rollback_committed()

                self.assertTrue(state.rolled_back)
                fixture.assert_claude_state(self)

    def test_relaunch_rejects_start_then_immediate_exit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                fixture.transaction().execute()
                fixture.commands.claude_running = False
                fixture.commands.open_process_states = [True, False]

                with self.assertRaisesRegex(cutover.RollbackError, "Codex state was restored"):
                    fixture.transaction().rollback_committed()

                fixture.assert_codex_state(self)


if __name__ == "__main__":
    unittest.main()
