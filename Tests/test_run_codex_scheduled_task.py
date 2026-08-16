from __future__ import annotations

import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


RUNNER = Path(__file__).resolve().parents[1] / "Scripts" / "run-codex-scheduled-task"
INSTALLED_RUNNER = Path("/Users/suchintan/.local/bin/run-codex-scheduled-task")
LOAD_ENV = Path(
    "/Users/suchintan/Development/Skyvern-cloud/dev_scripts/skills/api/load-env.sh"
)
APPROVED_CWD = "/Users/suchintan/Development/Skyvern-cloud"
CODEX = "/Users/suchintan/.nvm/versions/node/v24.9.0/bin/codex"
CONTROLLED_PATH = (
    "/Users/suchintan/.nvm/versions/node/v24.9.0/bin:"
    "/Users/suchintan/.superset/bin:/opt/homebrew/bin:/usr/local/bin:"
    "/usr/bin:/bin:/usr/sbin:/sbin:/Users/suchintan/.local/bin"
)
TASKS = {
    "daily-summary": (
        "Use $daily-summary at /Users/suchintan/.codex/skills/daily-summary "
        "with no arguments. Execute the canonical workflow once.",
        "/Users/suchintan/.codex/skills/daily-summary/SKILL.md",
    ),
    "daily-vitals-morning": (
        "Use $vitals-run-all at /Users/suchintan/.codex/skills/vitals-run-all "
        "with the exact argument morning. Execute the canonical workflow once.",
        "/Users/suchintan/.codex/skills/vitals-run-all/SKILL.md",
    ),
    "linkedin-post-ideas": (
        "Use $linkedin-post-ideas at /Users/suchintan/.codex/skills/"
        "linkedin-post-ideas with the exact integer argument 10 and exact "
        "run_context=scheduled-primary. Execute the canonical workflow once.",
        "/Users/suchintan/.codex/skills/linkedin-post-ideas/SKILL.md",
    ),
    "linkedin-post-ideas-sweeper": (
        "Use $linkedin-post-ideas at /Users/suchintan/.codex/skills/"
        "linkedin-post-ideas with the exact integer argument 10 and exact "
        "run_context=scheduled-sweeper. Execute the canonical workflow once.",
        "/Users/suchintan/.codex/skills/linkedin-post-ideas/SKILL.md",
    ),
    "overdue-customer-issues-slack": (
        "Use $overdue-customer-issues-slack at /Users/suchintan/Development/"
        "Skyvern-cloud/.agents/skills/overdue-customer-issues-slack with no "
        "arguments. Execute the canonical workflow once.",
        "/Users/suchintan/Development/Skyvern-cloud/.agents/skills/"
        "overdue-customer-issues-slack/SKILL.md",
    ),
    "team-progress-digest": (
        "Use $team-progress-digest at /Users/suchintan/.codex/skills/"
        "team-progress-digest with no arguments. Execute the canonical workflow once.",
        "/Users/suchintan/.codex/skills/team-progress-digest/SKILL.md",
    ),
}


class RunnerContractTests(unittest.TestCase):
    maxDiff = None

    def make_harness(
        self,
        root: Path,
        *,
        loader_body: str | None = None,
        codex_status: int = 0,
        omit_task_root: str | None = None,
    ) -> tuple[Path, dict[str, str], Path]:
        events = root / "events"
        stdin_path = root / "codex.stdin"
        argv_path = root / "codex.argv"
        environment_path = root / "codex.env"
        codex_path = root / "bin" / "codex"
        codex_path.parent.mkdir(parents=True)
        codex_path.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$@\" > " + shlex.quote(str(argv_path)) + "\n"
            "/bin/cat > " + shlex.quote(str(stdin_path)) + "\n"
            "{\n"
            "  printf 'SCHEDULED_RUN_DATE_ET=%s\\n' \"$SCHEDULED_RUN_DATE_ET\"\n"
            "  printf 'SCHEDULED_AGENT_ENGINE=%s\\n' \"$SCHEDULED_AGENT_ENGINE\"\n"
            "  printf 'SCHEDULED_SKILL_ROOT=%s\\n' \"$SCHEDULED_SKILL_ROOT\"\n"
            "  printf 'SCHEDULED_SKILL_LINK=%s\\n' \"$SCHEDULED_SKILL_LINK\"\n"
            "  printf 'HOME=%s\\n' \"$HOME\"\n"
            "  printf 'PATH=%s\\n' \"$PATH\"\n"
            "  printf 'TZ=%s\\n' \"$TZ\"\n"
            "  printf 'TASK_ID=%s\\n' \"${TASK_ID:-}\"\n"
            "  printf 'WORKING_DIRECTORY=%s\\n' \"${WORKING_DIRECTORY:-}\"\n"
            "  printf 'CODEX=%s\\n' \"${CODEX:-}\"\n"
            "  printf 'CONTROLLED_PATH=%s\\n' \"${CONTROLLED_PATH:-}\"\n"
            "  printf 'ENV_LOADER=%s\\n' \"${ENV_LOADER:-}\"\n"
            "  printf 'REPO_VALUE=%s\\n' \"${REPO_VALUE:-}\"\n"
            "} > " + shlex.quote(str(environment_path)) + "\n"
            f"exit {codex_status}\n",
            encoding="utf-8",
        )
        codex_path.chmod(0o755)

        date_path = root / "bin" / "date"
        date_path.write_text(
            "#!/bin/sh\n"
            "printf 'date\\n' >> " + shlex.quote(str(events)) + "\n"
            "printf '2026-08-15\\n'\n",
            encoding="utf-8",
        )
        date_path.chmod(0o755)

        loader_path = root / "dev_scripts" / "skills" / "api" / "load-env.sh"
        loader_path.parent.mkdir(parents=True)
        if loader_body is None:
            loader_body = (
                "printf 'loader\\n' >> " + shlex.quote(str(events)) + "\n"
                "SCHEDULED_RUN_DATE_ET=2099-01-01\n"
                "SCHEDULED_AGENT_ENGINE=claude\n"
                "SCHEDULED_SKILL_ROOT=/poisoned/root\n"
                "SCHEDULED_SKILL_LINK=/poisoned/link\n"
                "TASK_ID=not-approved\n"
                "WORKING_DIRECTORY=/poisoned/cwd\n"
                "CODEX=/poisoned/codex\n"
                "CONTROLLED_PATH=/poisoned/controlled-path\n"
                "ENV_LOADER=/poisoned/loader\n"
                "HOME=/poisoned/home\n"
                "PATH=/poisoned/path\n"
                "TZ=UTC\n"
                "REPO_VALUE=loaded\n"
                "export TASK_ID WORKING_DIRECTORY CODEX CONTROLLED_PATH ENV_LOADER\n"
                "export HOME PATH TZ REPO_VALUE\n"
            )
        loader_path.write_text(loader_body, encoding="utf-8")

        replacements = {APPROVED_CWD: str(root)}
        production_roots = sorted(
            {skill_path.removesuffix("/SKILL.md") for _, skill_path in TASKS.values()},
            key=len,
            reverse=True,
        )
        for index, production_root in enumerate(production_roots):
            fixture_root = root / "skills" / str(index)
            replacements[production_root] = str(fixture_root)
            affected_tasks = {
                task_id
                for task_id, (_, skill_path) in TASKS.items()
                if skill_path == production_root + "/SKILL.md"
            }
            if omit_task_root is None or omit_task_root not in affected_tasks:
                fixture_root.mkdir(parents=True)
                (fixture_root / "SKILL.md").write_text("live skill\n", encoding="utf-8")

        source = RUNNER.read_text(encoding="utf-8")
        source = source.replace(f"CODEX={CODEX}", f"CODEX={codex_path}")
        source = source.replace("DATE=/bin/date", f"DATE={date_path}")
        for production, fixture in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
            source = source.replace(production, fixture)
        isolated_runner = root / "run-codex-scheduled-task"
        isolated_runner.write_text(source, encoding="utf-8")
        isolated_runner.chmod(0o755)
        return isolated_runner, replacements, events

    def invoke(self, runner: Path, task_id: str, cwd: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(runner), task_id, str(cwd)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env={"HOME": "/inherited/home", "PATH": "/usr/bin:/bin", "TZ": "UTC"},
        )

    def source_real_loader(
        self,
        root: Path,
        env_body: str,
        variables: tuple[str, ...],
        *,
        reader_body: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
        (root / ".env").write_text(env_body, encoding="utf-8")
        probes = []
        for variable in variables:
            probes.append(
                'if [[ -n "${'
                + variable
                + '+x}" ]]; then\n'
                + "  printf "
                + shlex.quote(variable + "=%s\n")
                + ' "$'
                + variable
                + '"\n'
                + "else\n"
                + "  printf "
                + shlex.quote(variable + "=<UNSET>\n")
                + "\n"
                + "fi\n"
            )
        script = (
            "git() { printf '%s\\n' " + shlex.quote(str(root)) + "; }\n"
            + (reader_body or "")
            + ". "
            + shlex.quote(str(LOAD_ENV))
            + "\n"
            + "loader_status=$?\n"
            + "printf '__STATUS__=%s\\n' \"$loader_status\"\n"
            + "".join(probes)
        )
        result = subprocess.run(
            ["/bin/bash", "-c", script],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env={"HOME": "/inherited/home", "PATH": "/usr/bin:/bin", "TZ": "UTC"},
        )
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        return result, values

    def test_source_embeds_exact_six_prompt_and_root_mappings(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertEqual(source.partition("\n")[0], "#!/bin/bash")
        self.assertEqual(RUNNER.read_bytes(), INSTALLED_RUNNER.read_bytes())
        self.assertEqual(source.count("SCHEDULED_TASK_ID="), 0)
        self.assertEqual(source.count("SCHEDULED_RUN_CONTEXT="), 0)
        for task_id, (prompt, skill_path) in TASKS.items():
            with self.subTest(task_id=task_id):
                prompt_file = Path(
                    f"/Users/suchintan/.codex/scheduled-tasks/{task_id}/PROMPT.md"
                )
                self.assertEqual(prompt_file.read_bytes(), (prompt + "\n").encode("utf-8"))
                self.assertIn(f"PROMPT='{prompt}'", source)
                self.assertIn(f"SCHEDULED_SKILL_LINK='{skill_path}'", source)

    def test_all_six_tasks_send_exact_stdin_arguments_and_environment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner, replacements, events = self.make_harness(root)
            expected_events: list[str] = []
            for task_id, (prompt, skill_path) in TASKS.items():
                with self.subTest(task_id=task_id):
                    for artifact in (root / "codex.stdin", root / "codex.argv", root / "codex.env"):
                        artifact.unlink(missing_ok=True)
                    result = self.invoke(runner, task_id, root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    patched_prompt = prompt
                    patched_skill_path = skill_path
                    for production, fixture in sorted(
                        replacements.items(), key=lambda item: len(item[0]), reverse=True
                    ):
                        patched_prompt = patched_prompt.replace(production, fixture)
                        patched_skill_path = patched_skill_path.replace(production, fixture)
                    self.assertEqual(
                        (root / "codex.stdin").read_bytes(),
                        (patched_prompt + "\n").encode("utf-8"),
                    )
                    self.assertEqual(
                        (root / "codex.argv").read_text(encoding="utf-8").splitlines(),
                        ["exec", "--cd", str(root), "-"],
                    )
                    environment = (root / "codex.env").read_text(encoding="utf-8").splitlines()
                    self.assertEqual(
                        environment,
                        [
                            "SCHEDULED_RUN_DATE_ET=2026-08-15",
                            "SCHEDULED_AGENT_ENGINE=codex",
                            f"SCHEDULED_SKILL_ROOT={patched_skill_path.removesuffix('/SKILL.md')}",
                            f"SCHEDULED_SKILL_LINK={patched_skill_path}",
                            "HOME=/Users/suchintan",
                            f"PATH={CONTROLLED_PATH}",
                            "TZ=America/New_York",
                            f"TASK_ID={task_id}",
                            f"WORKING_DIRECTORY={root}",
                            f"CODEX={root / 'bin' / 'codex'}",
                            f"CONTROLLED_PATH={CONTROLLED_PATH}",
                            "ENV_LOADER="
                            f"{root / 'dev_scripts' / 'skills' / 'api' / 'load-env.sh'}",
                            "REPO_VALUE=loaded",
                        ],
                    )
                    expected_events.extend(["date", "loader"])
            self.assertEqual(events.read_text(encoding="utf-8").splitlines(), expected_events)

    def test_date_is_captured_before_loader_and_metadata_is_reasserted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner, _, events = self.make_harness(root)
            result = self.invoke(runner, "daily-summary", root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events.read_text(encoding="utf-8").splitlines(), ["date", "loader"])
            environment = (root / "codex.env").read_text(encoding="utf-8")
            self.assertIn("SCHEDULED_RUN_DATE_ET=2026-08-15\n", environment)
            self.assertIn("SCHEDULED_AGENT_ENGINE=codex\n", environment)
            self.assertNotIn("2099-01-01", environment)
            self.assertNotIn("claude", environment)
            self.assertNotIn("poisoned", environment)

    def test_repository_env_cannot_redirect_trusted_runner_controls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner, _, _ = self.make_harness(root)
            result = self.invoke(runner, "daily-summary", root)
            self.assertEqual(result.returncode, 0, result.stderr)
            environment = dict(
                line.split("=", 1)
                for line in (root / "codex.env").read_text(encoding="utf-8").splitlines()
            )
            self.assertEqual(
                {
                    key: environment[key]
                    for key in (
                        "TASK_ID",
                        "WORKING_DIRECTORY",
                        "CODEX",
                        "CONTROLLED_PATH",
                        "HOME",
                        "PATH",
                        "TZ",
                        "ENV_LOADER",
                    )
                },
                {
                    "TASK_ID": "daily-summary",
                    "WORKING_DIRECTORY": str(root),
                    "CODEX": str(root / "bin" / "codex"),
                    "CONTROLLED_PATH": CONTROLLED_PATH,
                    "HOME": "/Users/suchintan",
                    "PATH": CONTROLLED_PATH,
                    "TZ": "America/New_York",
                    "ENV_LOADER": str(
                        root / "dev_scripts" / "skills" / "api" / "load-env.sh"
                    ),
                },
            )
            self.assertEqual(
                (root / "codex.argv").read_text(encoding="utf-8").splitlines(),
                ["exec", "--cd", str(root), "-"],
            )

    def test_real_loader_parses_quotes_comments_spaces_escapes_and_skips_bad_lines(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result, values = self.source_real_loader(
                root,
                (
                    'DOUBLE_HASH = "abc#def"\n'
                    "SINGLE_HASH='ghi#jkl'\n"
                    'TRAILING = "value # kept" # outside comment\n'
                    "UNQUOTED_COMMENT=before#outside comment\n"
                    "  SPACED_KEY   =   value with spaces   \n"
                    'ESCAPED_MIXED="quote=\\"hash#inside\\" slash=\\\\ keep=\\q" # trailing comment\n'
                    'ESCAPED_BOUNDARY="quote=\\"#\\" keep=\\z slash-at-end=\\\\" # stripped\n'
                    "MALFORMED_VALUE this is not an assignment\n"
                    'UNMATCHED_DOUBLE="broken#value\n'
                    "UNMATCHED_SINGLE='broken#value\n"
                    "AFTER_BAD_LINES=loaded\n"
                ),
                (
                    "DOUBLE_HASH",
                    "SINGLE_HASH",
                    "TRAILING",
                    "UNQUOTED_COMMENT",
                    "SPACED_KEY",
                    "ESCAPED_MIXED",
                    "ESCAPED_BOUNDARY",
                    "MALFORMED_VALUE",
                    "UNMATCHED_DOUBLE",
                    "UNMATCHED_SINGLE",
                    "AFTER_BAD_LINES",
                ),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                values,
                {
                    "__STATUS__": "0",
                    "DOUBLE_HASH": "abc#def",
                    "SINGLE_HASH": "ghi#jkl",
                    "TRAILING": "value # kept",
                    "UNQUOTED_COMMENT": "before",
                    "SPACED_KEY": "value with spaces",
                    "ESCAPED_MIXED": 'quote="hash#inside" slash=\\ keep=\\q',
                    "ESCAPED_BOUNDARY": 'quote="#" keep=\\z slash-at-end=\\',
                    "MALFORMED_VALUE": "<UNSET>",
                    "UNMATCHED_DOUBLE": "<UNSET>",
                    "UNMATCHED_SINGLE": "<UNSET>",
                    "AFTER_BAD_LINES": "loaded",
                },
            )
            self.assertIn(
                "skipped malformed line 8 in .env",
                result.stderr,
            )
            self.assertIn(
                "skipped unmatched quote on line 9 in .env",
                result.stderr,
            )
            self.assertIn(
                "skipped unmatched quote on line 10 in .env",
                result.stderr,
            )

    def test_real_loader_read_failures_export_nothing(self) -> None:
        for reader_output in ("", "PARTIAL_VALUE=corrupted\n"):
            with self.subTest(reader_output=reader_output), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                reader_body = (
                    "cat() { printf '%s' "
                    + shlex.quote(reader_output)
                    + "; return 74; }\n"
                )
                result, values = self.source_real_loader(
                    root,
                    "FULL_VALUE=loaded\n",
                    ("FULL_VALUE", "PARTIAL_VALUE"),
                    reader_body=reader_body,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    values,
                    {
                        "__STATUS__": "1",
                        "FULL_VALUE": "<UNSET>",
                        "PARTIAL_VALUE": "<UNSET>",
                    },
                )
                self.assertIn("repository .env could not be read", result.stderr)

    def test_real_loader_reader_failure_maps_to_runner_exit_78(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".env").write_text("FULL_VALUE=loaded\n", encoding="utf-8")
            loader_body = (
                "git() { printf '%s\\n' "
                + shlex.quote(str(root))
                + "; }\n"
                + "cat() { printf 'PARTIAL_VALUE=corrupted\\n'; return 74; }\n"
                + LOAD_ENV.read_text(encoding="utf-8")
            )
            runner, _, _ = self.make_harness(root, loader_body=loader_body)
            result = self.invoke(runner, "daily-summary", root)
            self.assertEqual(result.returncode, 78)
            self.assertIn("repository .env could not be read", result.stderr)
            self.assertIn("repository environment load failed", result.stderr)
            self.assertFalse((root / "codex.stdin").exists())

    def test_loader_failure_stops_before_codex(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner, _, _ = self.make_harness(root, loader_body="return 23\n")
            result = self.invoke(runner, "daily-summary", root)
            self.assertEqual(result.returncode, 78)
            self.assertIn("repository environment load failed", result.stderr)
            self.assertFalse((root / "codex.stdin").exists())

    def test_real_loader_missing_or_unreadable_env_stops_before_codex(self) -> None:
        for case in ("missing", "unreadable"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                loader_body = (
                    "git() { printf '%s\\n' "
                    + shlex.quote(str(root))
                    + "; }\n"
                    + LOAD_ENV.read_text(encoding="utf-8")
                )
                runner, _, _ = self.make_harness(root, loader_body=loader_body)
                if case == "unreadable":
                    env_path = root / ".env"
                    env_path.write_text("REPO_VALUE=must-not-load\n", encoding="utf-8")
                    env_path.chmod(0o000)

                result = self.invoke(runner, "daily-summary", root)

                self.assertEqual(result.returncode, 78)
                self.assertIn("repository environment load failed", result.stderr)
                self.assertFalse((root / "codex.stdin").exists())

    def test_missing_root_stops_before_codex(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner, _, _ = self.make_harness(root, omit_task_root="daily-summary")
            result = self.invoke(runner, "daily-summary", root)
            self.assertEqual(result.returncode, 66)
            self.assertIn("scheduled root skill is not a readable regular file", result.stderr)
            self.assertFalse((root / "codex.stdin").exists())

    def test_codex_failure_status_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner, _, _ = self.make_harness(root, codex_status=42)
            result = self.invoke(runner, "team-progress-digest", root)
            self.assertEqual(result.returncode, 42)
            self.assertTrue((root / "codex.stdin").exists())

    def test_rejects_wrong_arity_unknown_task_and_wrong_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner, _, _ = self.make_harness(root)
            wrong_arity = subprocess.run(
                [str(runner), "daily-summary"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(wrong_arity.returncode, 64)
            unknown = self.invoke(runner, "not-approved", root)
            self.assertEqual(unknown.returncode, 64)
            self.assertIn("unknown scheduled task id", unknown.stderr)
            wrong_cwd = self.invoke(runner, "daily-summary", root / "other")
            self.assertEqual(wrong_cwd.returncode, 72)
            self.assertIn("working directory is not the approved repository", wrong_cwd.stderr)


if __name__ == "__main__":
    unittest.main()
