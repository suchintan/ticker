from __future__ import annotations

import dataclasses
import datetime as dt
import importlib.util
import io
import json
import os
import plistlib
import signal
import stat
import sys
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "Scripts" / "migrate-claude-routines-to-codex.py"
STAGED_SCRIPT = Path("/tmp/ticker-codex-cutover-SKY-14155.py")
RUNNER = REPO / "Scripts" / "run-codex-scheduled-task"
INSTALLED_RUNNER = Path("/Users/suchintan/.local/bin/run-codex-scheduled-task")

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
        self.raise_signal_on_wrap = False
        self.interrupt_wrap_after_mark = False
        self.interrupt_unwrap_after_write = False
        self.events: list[str] = []
        self.on_bootout: object | None = None

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
                self.wrapped.add(routine.task_id)
                self.authenticated_backups.add(routine.task_id)
                if self.interrupt_wrap_after_mark:
                    self.interrupt_wrap_after_mark = False
                    return cutover.CommandResult(5, "", "interrupted after markManaged")
                if self.raise_signal_on_wrap:
                    self.raise_signal_on_wrap = False
                    raise cutover.CutoverSignal(signal.SIGTERM)
                write_plist(routine, wrapped=True)
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
        self.registry = root / "scheduled-tasks.json"
        self.marker = root / "scheduled-tasks.json.ticker-codex-SKY-14155.success"
        self.lock = root / "scheduled-tasks.json.ticker-codex-SKY-14155.lock"
        self.runner_source = root / "source" / "run-codex-scheduled-task"
        self.runner_installed = root / "installed" / "run-codex-scheduled-task"
        self.ticker = root / "bin" / "ticker"
        self.codex = root / "bin" / "codex"
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
        self.ticker.parent.mkdir(parents=True)
        for executable in (self.ticker, self.codex):
            executable.write_bytes(b"#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)

        self.commands = FakeCommandRunner(self.routines_tuple)
        self.stack = ExitStack()

    def __enter__(self) -> "CutoverFixture":
        replacements = {
            "REGISTRY": self.registry,
            "TRANSACTION_LOCK": self.lock,
            "SUCCESS_MARKER": self.marker,
            "RUNNER_SOURCE": self.runner_source,
            "RUNNER_INSTALLED": self.runner_installed,
            "TICKER_EXECUTABLE": self.ticker,
            "CODEX_EXECUTABLE": self.codex,
        }
        for name, value in replacements.items():
            self.stack.enter_context(mock.patch.object(cutover, name, value))
        self.stack.enter_context(mock.patch.object(cutover.os, "getuid", return_value=os.getuid()))
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
        testcase.assertEqual(set(self.selected_enabled().values()), {False})
        testcase.assertEqual(self.commands.loaded, {routine.label for routine in self.routines})
        testcase.assertEqual(self.commands.wrapped, {routine.task_id for routine in self.routines})
        testcase.assertEqual(self.marker.read_bytes(), cutover.MARKER_PAYLOAD)
        testcase.assertFalse(self.commands.claude_running)
        for routine in self.routines:
            cutover.validate_plist(routine, wrapped=True)

    def prepare_partial(self, *, generated: int, wrapped: int, loaded: int) -> None:
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

    def test_generated_plists_preserve_exact_contract_without_run_at_load(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            routines = tuple(
                dataclasses.replace(routine, plist=root / routine.plist.name)
                for routine in cutover.ROUTINES
            )
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

    def test_executable_validator_accepts_relative_codex_link_and_rejects_unsafe_targets(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            codex_leaf = (
                root / "lib" / "node_modules" / "@openai" / "codex" / "bin" / "codex.js"
            )
            codex_leaf.parent.mkdir(parents=True)
            codex_leaf.write_bytes(b"#!/usr/bin/env node\n")
            codex_leaf.chmod(0o755)
            codex_link = bin_directory / "codex"
            codex_link.symlink_to("../lib/node_modules/@openai/codex/bin/codex.js")

            cutover.validate_executable(codex_link, "Codex executable")

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

    def test_main_lock_contention_precedes_all_engine_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with CutoverFixture(Path(directory)) as fixture:
                registry_before = fixture.registry.read_bytes()
                claude_pids_before = set(fixture.commands.claude_pids)
                transaction_factory = mock.Mock(name="CutoverTransaction")
                mutation_names = (
                    "atomic_write",
                    "publish_registry_enabled",
                    "install_runner_atomically",
                    "write_replacement_plists",
                    "remove_replacement_plist",
                    "stop_claude",
                    "relaunch_claude",
                    "ensure_success_marker",
                    "remove_success_marker",
                )

                with cutover.migration_transaction_lock():
                    lock_metadata = fixture.lock.lstat()
                    self.assertTrue(stat.S_ISREG(lock_metadata.st_mode))
                    self.assertEqual(lock_metadata.st_uid, os.getuid())
                    self.assertEqual(stat.S_IMODE(lock_metadata.st_mode), 0o600)

                    with ExitStack() as stack:
                        mutation_spies = {
                            name: stack.enter_context(
                                mock.patch.object(cutover, name, autospec=True)
                            )
                            for name in mutation_names
                        }
                        command_spy = stack.enter_context(
                            mock.patch.object(
                                cutover.CommandRunner,
                                "run",
                                autospec=True,
                            )
                        )
                        stack.enter_context(
                            mock.patch.object(
                                cutover,
                                "CutoverTransaction",
                                transaction_factory,
                            )
                        )
                        error_output = io.StringIO()
                        stack.enter_context(
                            mock.patch.object(cutover.sys, "stderr", error_output)
                        )

                        result = cutover.main([])

                self.assertEqual(result, 1)
                self.assertIn(
                    f"cutover failed: {cutover.TICKET} migration transaction "
                    f"is already running: {fixture.lock}",
                    error_output.getvalue(),
                )
                transaction_factory.assert_not_called()
                command_spy.assert_not_called()
                for mutation_spy in mutation_spies.values():
                    mutation_spy.assert_not_called()
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

    def test_source_and_installed_runner_copies_are_identical(self) -> None:
        self.assertEqual(RUNNER.read_bytes(), INSTALLED_RUNNER.read_bytes())

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

    def test_canonical_and_staged_cutover_copies_are_identical(self) -> None:
        self.assertEqual(SCRIPT.read_bytes(), STAGED_SCRIPT.read_bytes())


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
                self.assertEqual(publications, [(labels, task_ids)])
                self.assertEqual(fixture.marker.read_bytes(), cutover.MARKER_PAYLOAD)
                self.assertEqual(set(fixture.selected_enabled().values()), {False})
                self.assertEqual(fixture.runner_source.read_bytes(), fixture.runner_installed.read_bytes())
                backups = list(
                    fixture.root.glob("scheduled-tasks.json.ticker-codex-SKY-14155.audit.*.json")
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

    def test_fresh_invocation_recovers_every_known_partial_boundary(self) -> None:
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
                    state = fixture.transaction().execute()
                    self.assertTrue(state.recovered)
                    self.assertFalse(state.committed)
                    fixture.assert_claude_state(self)

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
                            root.glob(
                                "scheduled-tasks.json.ticker-codex-SKY-14155.audit.*.json"
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
                    (101, "/Users/suchintan/.local/bin/claude --resume"),
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
