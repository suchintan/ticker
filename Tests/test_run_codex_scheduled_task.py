from __future__ import annotations

import dataclasses
import hashlib
import importlib.machinery
import io
import json
import os
import platform
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
RUNNER = REPO / "Scripts" / "run-codex-scheduled-task"
NATIVE_FIXTURE = REPO / "Tests" / "Fixtures" / "native-codex.c"
_ORIGINAL_UMASK: int | None = None


def setUpModule() -> None:
    global _ORIGINAL_UMASK
    _ORIGINAL_UMASK = os.umask(0o077)


def tearDownModule() -> None:
    if _ORIGINAL_UMASK is not None:
        os.umask(_ORIGINAL_UMASK)


@dataclasses.dataclass(frozen=True)
class TaskSpec:
    skill_name: str
    project_relative: bool
    invocation: str


TASKS = {
    "daily-summary": TaskSpec(
        "daily-summary",
        False,
        "with no arguments",
    ),
    "daily-vitals-morning": TaskSpec(
        "vitals-run-all",
        False,
        "with the exact argument morning",
    ),
    "linkedin-post-ideas": TaskSpec(
        "linkedin-post-ideas",
        False,
        "with the exact integer argument 10 and exact run_context=scheduled-primary",
    ),
    "linkedin-post-ideas-sweeper": TaskSpec(
        "linkedin-post-ideas",
        False,
        "with the exact integer argument 10 and exact run_context=scheduled-sweeper",
    ),
    "overdue-customer-issues-slack": TaskSpec(
        "overdue-customer-issues-slack",
        True,
        "with no arguments",
    ),
    "team-progress-digest": TaskSpec(
        "team-progress-digest",
        False,
        "with no arguments",
    ),
}


def expected_task_contract(
    task_id: str,
    home: Path,
    working_directory: Path,
    skill_roots: dict[str, Path] | None = None,
    *,
    codex_home: Path | None = None,
) -> tuple[str, Path]:
    task = TASKS[task_id]
    if skill_roots is not None:
        skill_root = skill_roots[task_id]
    elif task.project_relative:
        skill_root = working_directory / ".agents" / "skills" / task.skill_name
    else:
        skill_root = (
            home / ".codex" if codex_home is None else codex_home
        ) / "skills" / task.skill_name
    prompt = (
        f"Use ${task.skill_name} at {skill_root} {task.invocation}. "
        "Execute the canonical workflow once."
    )
    return prompt, skill_root / "SKILL.md"


def render_test_runner(source: bytes, binding: dict[str, object]) -> bytes:
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
    marker = (
        b"# TICKER-RUNTIME-V1 "
        + json.dumps(binding, sort_keys=True, separators=(",", ":")).encode("utf-8")
        + b"\n"
    )
    return (
        f"#!{sys.executable} -I".encode("utf-8")
        + b"\n"
        + marker
        + b"".join(body_lines)
    )


@dataclasses.dataclass(frozen=True)
class RunnerHarness:
    root: Path
    runner: Path
    home: Path
    codex_home: Path
    working_directory: Path
    skill_roots: dict[str, Path]
    codex: Path
    controlled_path: str
    rogue_path: str
    loader: Path
    dotenv: Path
    events: Path
    rogue_events: Path
    stdin: Path
    argv: Path
    environment: Path
    binding: dict[str, object]


class RunnerContractTests(unittest.TestCase):
    maxDiff = None

    def compile_native_codex(self, output: Path, status: int) -> None:
        compiler = shutil.which("clang")
        if compiler is None:
            self.skipTest("clang is required for the native Codex fixture")
        completed = subprocess.run(
            [
                compiler,
                "-std=c11",
                "-O2",
                f"-DCODEX_EXIT_STATUS={status}",
                str(NATIVE_FIXTURE),
                "-o",
                str(output),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def make_harness(
        self,
        root: Path,
        *,
        loader_body: str | None = None,
        dotenv_body: str | None = None,
        codex_status: int = 0,
        omit_task_root: str | None = None,
    ) -> RunnerHarness:
        root = root.resolve(strict=True)
        home = Path.home().resolve(strict=True)
        working_directory = root / "repository with spaces"
        codex_home = root / "codex home"
        codex_home.mkdir()
        codex_home.chmod(0o700)
        codex_config = codex_home / "config.toml"
        codex_config.write_text("", encoding="utf-8")
        codex_config.chmod(0o600)
        codex_auth = codex_home / "auth.json"
        codex_auth.write_text("{}", encoding="utf-8")
        codex_auth.chmod(0o600)

        working_directory.mkdir(parents=True)

        events = working_directory / "codex.events"
        rogue_events = root / "rogue-events"
        stdin_path = working_directory / "codex.stdin"
        argv_path = working_directory / "codex.argv"
        environment_path = working_directory / "codex.env"
        native_directory = root / "native codex"
        native_directory.mkdir()
        codex_path = native_directory / "codex"
        self.compile_native_codex(codex_path, codex_status)
        controlled_path = f"{native_directory}:/usr/bin"

        rogue_directory = root / "rogue path"
        rogue_directory.mkdir()
        for executable in ("codex", "git", "cat", "date"):
            rogue = rogue_directory / executable
            rogue.write_text(
                "#!/bin/sh\n"
                f"printf 'rogue-{executable}\\n' >> {shlex.quote(str(rogue_events))}\n"
                "exit 97\n",
                encoding="utf-8",
            )
            rogue.chmod(0o755)
        rogue_path = str(rogue_directory)

        loader_path = (
            working_directory
            / "dev_scripts"
            / "skills"
            / "api"
            / "load-env.sh"
        )
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
                "DATE=/poisoned/date\n"
                "REPO_VALUE=loaded-by-loader\n"
                "export TASK_ID WORKING_DIRECTORY CODEX CONTROLLED_PATH ENV_LOADER\n"
                "export HOME PATH TZ DATE REPO_VALUE\n"
            )
        loader_path.write_text(loader_body, encoding="utf-8")

        dotenv_path = working_directory / ".env"
        if dotenv_body is None:
            dotenv_body = (
                "# The scheduled runner must parse this file as data.\n"
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
                "DATE=/poisoned/date\n"
                "REPO_VALUE=loaded\n"
            )
        dotenv_path.write_text(dotenv_body, encoding="utf-8")

        skill_roots = {
            task_id: (
                working_directory / ".agents" / "skills" / TASKS[task_id].skill_name
                if TASKS[task_id].project_relative
                else root / "codex skills" / TASKS[task_id].skill_name
            )
            for task_id in TASKS
        }
        omitted_skill = None
        if omit_task_root is not None:
            _, omitted_skill = expected_task_contract(
                omit_task_root,
                home,
                working_directory,
                skill_roots,
                codex_home=codex_home,
            )
        for task_id in TASKS:
            _, skill_path = expected_task_contract(
                task_id,
                home,
                working_directory,
                skill_roots,
                codex_home=codex_home,
            )
            if skill_path == omitted_skill:
                continue
            skill_path.parent.mkdir(parents=True, exist_ok=True)
            skill_path.write_text("live skill\n", encoding="utf-8")

        machine = platform.machine().lower()
        if machine in {"arm64", "aarch64"}:
            codex_arch = "arm64"
        elif machine in {"x86_64", "amd64"}:
            codex_arch = "x86_64"
        else:
            self.skipTest(f"unsupported host architecture: {machine}")
        binding = {
            "binding_version": 2,
            "uid": os.getuid(),
            "home": str(home),
            "repository": str(working_directory),
            "python": sys.executable,
            "codex": str(codex_path),
            "codex_home": str(codex_home),
            "path": controlled_path,
            "model": "gpt-5.6-sol",
            "skill_roots": {task_id: str(path) for task_id, path in skill_roots.items()},
            "codex_sha256": hashlib.sha256(codex_path.read_bytes()).hexdigest(),
            "codex_macho_arch": codex_arch,
            "codex_managed_package_root": None,
            "codex_managed_package_version": None,
            "codex_managed_by": "direct",
        }
        generated = render_test_runner(RUNNER.read_bytes(), binding)
        isolated_runner = root / "isolated runner with spaces" / RUNNER.name
        isolated_runner.parent.mkdir(parents=True)
        isolated_runner.write_bytes(generated)
        isolated_runner.chmod(0o755)
        return RunnerHarness(
            root=root,
            runner=isolated_runner,
            home=home,
            codex_home=codex_home,
            working_directory=working_directory,
            skill_roots=skill_roots,
            codex=codex_path,
            controlled_path=controlled_path,
            rogue_path=rogue_path,
            loader=loader_path,
            dotenv=dotenv_path,
            events=events,
            rogue_events=rogue_events,
            stdin=stdin_path,
            argv=argv_path,
            environment=environment_path,
            binding=binding,
        )
    def invocation_environment(self, harness: RunnerHarness) -> dict[str, str]:
        return {
            "HOME": str(harness.home),
            "PATH": harness.controlled_path,
            "TZ": "UTC",
        }


    def invoke(
        self,
        harness: RunnerHarness,
        task_id: str,
        working_directory: Path | None = None,
        *,
        environment: dict[str, str] | None = None,
        interpreter: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            str(harness.runner),
            task_id,
            str(
                harness.working_directory
                if working_directory is None
                else working_directory
            ),
        ]
        if interpreter is not None:
            command.insert(0, str(interpreter))
        return subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=(
                self.invocation_environment(harness)
                if environment is None
                else environment
            ),
        )
    def load_runner_module(self, harness: RunnerHarness) -> types.ModuleType:
        loader = importlib.machinery.SourceFileLoader(
            f"ticker_runner_{id(harness)}",
            str(harness.runner),
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.assertIsNotNone(spec)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[loader.name] = module
        self.addCleanup(sys.modules.pop, loader.name, None)
        spec.loader.exec_module(module)
        return module

    def binding_object(self, harness: RunnerHarness) -> SimpleNamespace:
        return SimpleNamespace(
            binding_version=2,
            uid=os.getuid(),
            home=harness.home,
            codex_home=harness.codex_home,
            repository=harness.working_directory,
            python=Path(sys.executable),
            codex=harness.codex,
            path=harness.controlled_path,
            model="gpt-5.6-sol",
            skill_roots={
                task_id: path
                for task_id, path in harness.skill_roots.items()
            },
            codex_sha256=harness.binding["codex_sha256"],
            codex_macho_arch=harness.binding["codex_macho_arch"],
            codex_managed_package_root=None,
            codex_managed_package_version=None,
            codex_managed_by="direct",
        )

    def read_events(self, harness: RunnerHarness) -> list[str]:
        if not harness.events.exists():
            return []
        return harness.events.read_text(encoding="utf-8").splitlines()


    def test_runtime_binding_constant_is_used_without_self_path_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            source = RUNNER.read_text(encoding="utf-8")
            self.assertIn("RUNTIME_BINDING", source)
            self.assertNotIn("Path(__file__).read_bytes", source)
            module.RUNTIME_BINDING = harness.binding
            read_binding = getattr(module, "_read_runtime_binding", None)
            self.assertIsNotNone(read_binding)
            assert read_binding is not None
            original_read_bytes = module.Path.read_bytes

            def reject_runner_path(path: Path) -> bytes:
                if path == harness.runner:
                    raise AssertionError("runtime reopened its own pathname")
                return original_read_bytes(path)

            with mock.patch.object(
                module.Path,
                "read_bytes",
                side_effect=reject_runner_path,
            ):
                binding = read_binding()
            self.assertEqual(Path(str(binding.codex)), harness.codex)
            self.assertEqual(binding.codex_sha256, harness.binding["codex_sha256"])
            self.assertEqual(Path(str(binding.codex_home)), harness.codex_home)


            binding_object = self.binding_object(harness)
            task_root = harness.skill_roots["daily-summary"]
            skill_path = task_root / "SKILL.md"
            with mock.patch.object(
                module,
                "_read_runtime_binding",
                return_value=binding_object,
            ), mock.patch.object(
                module,
                "_task_contract",
                return_value=("prompt", task_root, skill_path),
            ), mock.patch.object(
                module,
                "_read_dotenv",
                return_value={},
            ), mock.patch.object(
                module,
                "_validate_readable_file",
            ), mock.patch.object(
                module,
                "_forwarded_child_status",
                return_value=0,
            ) as child:
                result = module.run(
                    ["daily-summary", str(harness.working_directory)]
                )
            self.assertEqual(result, 0)
            child.assert_called_once()

    def test_bound_home_requires_current_passwd_home(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            task_root = harness.skill_roots["daily-summary"]
            skill_path = task_root / "SKILL.md"
            read_dotenv = mock.Mock(side_effect=AssertionError("dotenv was read"))
            child = mock.Mock(side_effect=AssertionError("Codex was spawned"))
            pwd_module = SimpleNamespace(
                getpwuid=mock.Mock(
                    return_value=SimpleNamespace(
                        pw_dir=str(harness.root / "different passwd home")
                    )
                )
            )
            with mock.patch.object(
                module,
                "_read_runtime_binding",
                return_value=binding,
            ), mock.patch.object(module, "pwd", pwd_module, create=True), mock.patch.object(
                module,
                "_read_dotenv",
                read_dotenv,
            ), mock.patch.object(
                module,
                "_forwarded_child_status",
                child,
            ), mock.patch.object(
                module,
                "_task_contract",
                return_value=("prompt", task_root, skill_path),
            ), mock.patch.object(
                module,
                "_validate_readable_file",
            ), mock.patch.dict(
                module.os.environ,
                {
                    "HOME": str(harness.home),
                    "PATH": harness.controlled_path,
                    "TZ": "UTC",
                },
                clear=True,
            ):
                result = module.run(
                    ["daily-summary", str(harness.working_directory)]
                )
            self.assertEqual(result, 78)
            pwd_module.getpwuid.assert_called_once_with(os.getuid())
            read_dotenv.assert_not_called()
            child.assert_not_called()

            pwd_module.getpwuid.reset_mock()
            read_dotenv.reset_mock()
            child.reset_mock()
            with mock.patch.object(
                module,
                "_read_runtime_binding",
                return_value=binding,
            ), mock.patch.object(module, "pwd", pwd_module, create=True), mock.patch.object(
                module,
                "_read_dotenv",
                return_value={},
            ), mock.patch.object(
                module,
                "_forwarded_child_status",
                return_value=0,
            ) as matching_child, mock.patch.object(
                module,
                "_task_contract",
                return_value=("prompt", task_root, skill_path),
            ), mock.patch.object(
                module,
                "_validate_readable_file",
            ), mock.patch.dict(
                module.os.environ,
                {
                    "HOME": str(harness.home),
                    "PATH": harness.controlled_path,
                    "TZ": "UTC",
                },
                clear=True,
            ):
                pwd_module.getpwuid.return_value = SimpleNamespace(
                    pw_dir=str(harness.home)
                )
                result = module.run(
                    ["daily-summary", str(harness.working_directory)]
                )
            self.assertEqual(result, 0)
            pwd_module.getpwuid.assert_called_once_with(os.getuid())
            matching_child.assert_called_once()

    def test_child_environment_is_allowlisted_and_preserves_six_skill_credentials(
        self,
    ) -> None:
        required = {
            "FATHOM_API_KEY": "fathom-value",
            "SLACK_USER_TOKEN": "slack-user-value",
            "SLACK_BOT_TOKEN": "slack-bot-value",
            "SLACK_APP_TOKEN": "slack-app-value",
            "LINEAR_API_KEY": "linear-value",
            "HUBSPOT_ACCESS_TOKEN": "hubspot-value",
            "PYLON_API_KEY": "pylon-value",
            "NOTION_API_KEY": "notion-value",
            "DD_API_KEY": "dd-value",
            "DD_APP_KEY": "dd-app-value",
            "GOOGLE_CLIENT_ID": "google-client-id",
            "GOOGLE_CLIENT_SECRET": "google-client-secret",
            "GOOGLE_REFRESH_TOKEN": "google-refresh-token",
            "SKYVERN_API_KEY": "skyvern-value",
            "OPENAI_API_KEY": "openai-value",
            "CODEX_API_KEY": "codex-api-value",
            "PANGRAM_API_KEY": "pangram-value",
            "USER": "synthetic-user",
            "USER_EMAIL": "synthetic@example.invalid",
            "SLACK_FORCE_BOT": "1",
        }
        denied_names = {
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH",
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "PYTHONPATH",
            "PYTHONSTARTUP",
            "PYTHONUSERBASE",
            "NODE_OPTIONS",
            "BASH_ENV",
            "ENV",
            "RUBYOPT",
            "PERL5OPT",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "NO_PROXY",
            "SSL_CERT_FILE",
            "SSL_CERT_DIR",
            "REQUESTS_CA_BUNDLE",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "UNKNOWN_INHERITED",
            "UNKNOWN_DOTENV_KEY",
            "GIT_SSH",
            "GIT_SSH_COMMAND",
            "GIT_EXEC_PATH",
            "SUPERSET_AGENT_ID",
            "CODEX_MANAGED_BY_EVIL",
            "UNKNOWN_INHERITED",
            "CODEX_MANAGED_BY_NPM",
            "CODEX_MANAGED_BY_DIRECT",
            "SUPERSET_HOOK",
        }
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            inherited = {
                **required,
                **{
                    name: f"denied-{name.lower()}"
                    for name in denied_names | {"CODEX_HOME"}
                },
                "CINDER_SLACK_BOT_TOKEN": "cinder-bot-value",
                "CINDER_SLACK_APP_TOKEN": "cinder-app-value",
            }
            dotenv = {
                **{
                    name: f"dotenv-{name.lower()}"
                    for name in required
                },
                **{
                    name: f"dotenv-{name.lower()}"
                    for name in denied_names | {"CODEX_HOME"}
                },
                "CINDER_SLACK_BOT_TOKEN": "dotenv-cinder-bot",
                "CINDER_SLACK_APP_TOKEN": "dotenv-cinder-app",
            }
            builder = getattr(module, "_build_environment", None)
            self.assertIsNotNone(
                builder,
                "RED contract missing child environment builder",
            )
            assert builder is not None
            for task_id in TASKS:
                with self.subTest(task_id=task_id):
                    task_root = harness.skill_roots[task_id]
                    child_environment = builder(
                        binding,
                        task_id,
                        task_root,
                        task_root / "SKILL.md",
                        "2026-08-20",
                        dotenv,
                        inherited,
                    )
                    for name in required:
                        self.assertEqual(child_environment.get(name), dotenv[name])
                    self.assertEqual(
                        child_environment["SLACK_BOT_TOKEN"],
                        "dotenv-slack_bot_token",
                    )
                    self.assertEqual(
                        child_environment["SLACK_APP_TOKEN"],
                        "dotenv-slack_app_token",
                    )
                    self.assertEqual(
                        child_environment.get("CODEX_HOME"),
                        str(harness.codex_home),
                    )
                    self.assertEqual(
                        child_environment.get("HOME"),
                        str(harness.home),
                    )
                    self.assertEqual(
                        child_environment.get("PATH"),
                        harness.controlled_path,
                    )
                    self.assertEqual(
                        child_environment.get("TZ"),
                        "America/New_York",
                    )
                    self.assertEqual(
                        child_environment.get("LANG"),
                        "en_US.UTF-8",
                    )
                    self.assertEqual(
                        child_environment.get("LC_ALL"),
                        "en_US.UTF-8",
                    )
                    self.assertEqual(
                        child_environment.get("CODEX_MANAGED_BY_DIRECT"),
                        "1",
                    )
                    self.assertNotIn("CODEX_MANAGED_BY_NPM", child_environment)
                    for name in (
                        denied_names
                        - {"CODEX_MANAGED_BY_DIRECT", "CODEX_MANAGED_BY_NPM"}
                    ) | {
                        "CINDER_SLACK_BOT_TOKEN",
                        "CINDER_SLACK_APP_TOKEN",
                    }:
                        self.assertNotIn(name, child_environment)


    def test_npm_package_identity_allows_unrelated_bin_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            package_root = harness.root / "npm package"
            package_version = "0.147.0"
            platform_name, vendor_target = module._package_details()
            platform_suffix = platform_name.removeprefix("codex-")
            platform_os, platform_cpu = platform_suffix.split("-", 1)
            platform_version = f"{package_version}-{platform_suffix}"
            platform_dependency = f"npm:@openai/codex@{platform_version}"
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
            entrypoint = package_root / "bin" / "codex.js"
            helper = package_root / "bin" / "codex-helper.js"
            native.parent.mkdir(parents=True)
            entrypoint.parent.mkdir(parents=True)
            (package_root / "package.json").write_text(
                json.dumps(
                    {
                        "name": "@openai/codex",
                        "version": package_version,
                        "bin": {
                            "codex": "bin/codex.js",
                            "codex-helper": "bin/codex-helper.js",
                        },
                        "optionalDependencies": {
                            f"@openai/{platform_name}": platform_dependency,
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
            entrypoint.write_text("#!/usr/bin/env node\n", encoding="utf-8")
            helper.write_text("#!/usr/bin/env node\n", encoding="utf-8")
            native.write_bytes(harness.codex.read_bytes())
            for executable in (entrypoint, helper, native):
                executable.chmod(0o755)

            binding = self.binding_object(harness)
            binding.codex = native
            binding.codex_sha256 = hashlib.sha256(native.read_bytes()).hexdigest()
            binding.codex_managed_package_root = package_root
            binding.codex_managed_package_version = package_version
            binding.codex_managed_by = "npm"

            self.assertIsNone(
                module._validate_package_identity(
                    package_root,
                    binding.codex,
                    binding.codex_sha256,
                )
            )


    def test_npm_package_version_drift_rejects_before_spawn_with_bound_native_digest(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            package_root = harness.root / "npm package"
            package_version = "0.147.0"
            drifted_version = "0.147.1"
            platform_name, vendor_target = module._package_details()
            platform_suffix = platform_name.removeprefix("codex-")
            platform_os, platform_cpu = platform_suffix.split("-", 1)
            platform_version = f"{package_version}-{platform_suffix}"
            drifted_platform_version = f"{drifted_version}-{platform_suffix}"
            wrong_platform_suffix = (
                "darwin-x64" if platform_suffix == "darwin-arm64" else "darwin-arm64"
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
            entrypoint = package_root / "bin" / "codex.js"
            native.parent.mkdir(parents=True)
            entrypoint.parent.mkdir(parents=True)
            entrypoint.write_text("#!/usr/bin/env node\n", encoding="utf-8")
            native.write_bytes(harness.codex.read_bytes())
            for executable in (entrypoint, native):
                executable.chmod(0o755)

            binding = self.binding_object(harness)
            binding.codex = native
            binding.codex_sha256 = hashlib.sha256(native.read_bytes()).hexdigest()
            binding.codex_managed_package_root = package_root
            binding.codex_managed_package_version = package_version
            binding.codex_managed_by = "npm"
            self.assertEqual(
                binding.codex_sha256,
                hashlib.sha256(harness.codex.read_bytes()).hexdigest(),
            )

            def write_metadata(
                root_version: str,
                alias_target: str,
                platform_metadata_name: str,
                platform_metadata_version: str,
            ) -> None:
                (package_root / "package.json").write_text(
                    json.dumps(
                        {
                            "name": "@openai/codex",
                            "version": root_version,
                            "bin": {"codex": "bin/codex.js"},
                            "optionalDependencies": {
                                f"@openai/{platform_name}": alias_target,
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                (platform_package / "package.json").write_text(
                    json.dumps(
                        {
                            "name": platform_metadata_name,
                            "version": platform_metadata_version,
                            "os": [platform_os],
                            "cpu": [platform_cpu],
                        }
                    ),
                    encoding="utf-8",
                )

            cases = (
                (
                    "version-drift",
                    drifted_version,
                    f"npm:@openai/codex@{drifted_platform_version}",
                    "@openai/codex",
                    drifted_platform_version,
                ),
                (
                    "wrong-alias-target",
                    package_version,
                    f"npm:@openai/not-codex@{platform_version}",
                    "@openai/codex",
                    platform_version,
                ),
                (
                    "wrong-platform-suffix",
                    package_version,
                    f"npm:@openai/codex@{platform_version}",
                    "@openai/codex",
                    f"{package_version}-{wrong_platform_suffix}",
                ),
                (
                    "wrong-platform-canonical-name",
                    package_version,
                    f"npm:@openai/codex@{platform_version}",
                    f"@openai/{platform_name}",
                    platform_version,
                ),
            )
            task_root = harness.skill_roots["daily-summary"]
            skill_path = task_root / "SKILL.md"
            child = mock.Mock()
            child.stdin = io.BytesIO()
            child.wait.return_value = 0
            for (
                case,
                root_version,
                alias_target,
                platform_metadata_name,
                platform_metadata_version,
            ) in cases:
                with self.subTest(case=case):
                    write_metadata(
                        root_version,
                        alias_target,
                        platform_metadata_name,
                        platform_metadata_version,
                    )
                    with mock.patch.object(
                        module,
                        "_read_runtime_binding",
                        return_value=binding,
                    ), mock.patch.object(
                        module,
                        "_task_contract",
                        return_value=("prompt", task_root, skill_path),
                    ), mock.patch.object(
                        module,
                        "_validate_readable_file",
                    ), mock.patch.object(
                        module,
                        "_read_dotenv",
                        return_value={},
                    ), mock.patch.object(
                        module.subprocess,
                        "Popen",
                        return_value=child,
                    ) as popen:
                        result = module.run(
                            ["daily-summary", str(harness.working_directory)]
                        )

                    self.assertEqual(result, 69)
                    popen.assert_not_called()

    def test_codex_digest_macho_and_package_identity_are_checked_before_spawn(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            original = harness.codex.read_bytes()
            task_root = harness.skill_roots["daily-summary"]
            skill_path = task_root / "SKILL.md"
            binding = self.binding_object(harness)
            cases: list[tuple[str, SimpleNamespace]] = []

            truncated = SimpleNamespace(**vars(binding))
            truncated.codex = harness.root / "truncated-codex"
            truncated.codex.write_bytes(original[:16])
            truncated.codex.chmod(0o755)
            cases.append(("truncated", truncated))

            wrong_arch = SimpleNamespace(**vars(binding))
            wrong_arch.codex = harness.root / "wrong-arch-codex"
            wrong_payload = bytearray(original)
            if original[:4] in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}:
                wrong_payload[4:8] = (
                    0x0C000001
                    if binding.codex_macho_arch == "x86_64"
                    else 0x07000001
                ).to_bytes(4, "little")
            else:
                wrong_payload[18:20] = (0x0100 if binding.codex_macho_arch == "x86_64" else 0x000c).to_bytes(2, "little")
            wrong_arch.codex.write_bytes(bytes(wrong_payload))
            wrong_arch.codex.chmod(0o755)
            cases.append(("wrong-arch", wrong_arch))

            changed = SimpleNamespace(**vars(binding))
            changed.codex = harness.root / "changed-codex"
            changed.codex.write_bytes(original + b"changed")
            changed.codex.chmod(0o755)
            cases.append(("changed-digest", changed))

            direct = SimpleNamespace(**vars(binding))
            direct.codex = harness.root / "shell-codex"
            direct.codex.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            direct.codex.chmod(0o755)
            cases.append(("direct-provenance", direct))

            npm = SimpleNamespace(**vars(binding))
            npm.codex_managed_by = "npm"
            npm.codex_managed_package_root = harness.root / "bad npm package"
            npm.codex_managed_package_version = "0.147.0"
            npm.codex = harness.codex
            cases.append(("bad-package-metadata", npm))

            for name, case_binding in cases:
                with self.subTest(case=name):
                    with mock.patch.object(
                        module,
                        "_read_runtime_binding",
                        return_value=case_binding,
                    ), mock.patch.object(
                        module,
                        "_task_contract",
                        return_value=("prompt", task_root, skill_path),
                    ), mock.patch.object(
                        module,
                        "_validate_readable_file",
                    ), mock.patch.object(
                        module,
                        "_read_dotenv",
                        return_value={},
                    ), mock.patch.object(
                        module.subprocess,
                        "Popen",
                    ) as popen:
                        child = mock.Mock()
                        child.stdin = io.BytesIO()
                        child.wait.return_value = 0
                        popen.return_value = child
                        result = module.run(
                            ["daily-summary", str(harness.working_directory)]
                        )
                    self.assertEqual(result, 69)
                    popen.assert_not_called()

    def test_materialize_validated_codex_copies_exact_fd_bytes_after_path_swap(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            staging_home = harness.root / "staging home"
            staging_bin = staging_home / ".local" / "bin"
            staging_bin.mkdir(parents=True)
            for path in (staging_home, staging_home / ".local", staging_bin):
                path.chmod(0o700)
            binding.home = staging_home

            original = harness.codex.read_bytes()
            source = harness.root / "bound codex source"
            source.write_bytes(original)
            source.chmod(0o755)
            replacement = b"pathname replacement must not be copied\n"
            source_fd = os.open(source, os.O_RDONLY)
            private_paths: list[Path] = []
            try:
                materialize = getattr(
                    module,
                    "_materialize_validated_codex",
                    None,
                )
                self.assertTrue(
                    callable(materialize),
                    "RED contract missing _materialize_validated_codex(binding, fd)",
                )
                assert callable(materialize)
                os.lseek(source_fd, len(original) // 2, os.SEEK_SET)
                source.unlink()
                source.write_bytes(replacement)
                source.chmod(0o755)
                current_position = os.lseek(source_fd, 0, os.SEEK_CUR)

                first = Path(materialize(binding, source_fd))
                private_paths.append(first)
                second = Path(materialize(binding, source_fd))
                private_paths.append(second)

                for private_copy in private_paths:
                    self.assertEqual(private_copy.parent, staging_bin)
                    self.assertEqual(
                        stat.S_IMODE(private_copy.stat().st_mode),
                        0o700,
                    )
                    self.assertEqual(private_copy.read_bytes(), original)
                self.assertNotEqual(first, second)
                self.assertEqual(
                    os.lseek(source_fd, 0, os.SEEK_CUR),
                    current_position,
                )
                self.assertEqual(source.read_bytes(), replacement)
            finally:
                try:
                    os.close(source_fd)
                except OSError:
                    pass
                for private_copy in private_paths:
                    private_copy.unlink(missing_ok=True)

    def test_codex_executes_private_copy_after_path_swap_and_cleans_it(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            staging_home = harness.root / "staging home"
            staging_bin = staging_home / ".local" / "bin"
            staging_bin.mkdir(parents=True)
            for path in (staging_home, staging_home / ".local", staging_bin):
                path.chmod(0o700)
            binding.home = staging_home

            original = harness.codex.read_bytes()
            replacement = harness.root / "replacement-codex"
            replacement_bytes = b"#!/bin/sh\nexit 97\n"
            replacement.write_bytes(replacement_bytes)
            replacement.chmod(0o755)
            source_fd = os.open(harness.codex, os.O_RDONLY)
            private_paths: list[Path] = []
            events: list[str] = []

            class Child:
                stdin = io.BytesIO()

                def wait(self) -> int:
                    events.append("wait")
                    return 0

            expected_arguments = [
                str(binding.codex),
                "exec",
                "--model",
                "gpt-5.6-sol",
                "--cd",
                str(binding.repository),
                "-c",
                'model_reasoning_effort="xhigh"',
                "-",
            ]
            environment = {
                "HOME": str(binding.home),
                "PATH": harness.controlled_path,
                "TZ": "America/New_York",
            }

            def fake_popen(arguments: list[str], **kwargs: object) -> Child:
                events.append("popen")
                self.assertEqual(arguments, expected_arguments)
                self.assertEqual(kwargs["cwd"], binding.repository)
                self.assertEqual(kwargs["env"], environment)
                self.assertEqual(kwargs["stdin"], subprocess.PIPE)
                self.assertNotIn("pass_fds", kwargs)
                executable = kwargs.get("executable")
                self.assertIsInstance(executable, str)
                assert isinstance(executable, str)
                private_copy = Path(executable)
                private_paths.append(private_copy)
                self.assertEqual(private_copy.parent, staging_bin)
                self.assertEqual(
                    stat.S_IMODE(private_copy.stat().st_mode),
                    0o700,
                )
                self.assertEqual(private_copy.read_bytes(), original)
                os.replace(replacement, binding.codex)
                self.assertEqual(private_copy.read_bytes(), original)
                return Child()

            forward = getattr(module, "_forwarded_child_status", None)
            self.assertIsNotNone(
                forward,
                "RED contract missing private-copy runner seam",
            )
            assert forward is not None
            try:
                with mock.patch.object(
                    module,
                    "_open_bound_codex",
                    return_value=(
                        source_fd,
                        str(binding.codex_macho_arch),
                        str(binding.codex_sha256),
                    ),
                ), mock.patch.object(
                    module.subprocess,
                    "Popen",
                    side_effect=fake_popen,
                ):
                    status = forward(binding, "prompt", environment)
                self.assertEqual(status, 0)
                self.assertEqual(events, ["popen", "wait"])
                self.assertEqual(binding.codex.read_bytes(), replacement_bytes)
                self.assertTrue(private_paths)
                self.assertFalse(private_paths[0].exists())
                with self.assertRaises(OSError):
                    os.fstat(source_fd)
            finally:
                try:
                    os.close(source_fd)
                except OSError:
                    pass


    def test_codex_spawn_failure_cleans_private_copy_and_closes_validated_fd(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            private_copy = harness.root / "private codex"
            private_copy.write_bytes(b"validated private copy\n")
            private_copy.chmod(0o700)
            source_fd = os.open(harness.codex, os.O_RDONLY)
            environment = {
                "HOME": str(harness.home),
                "PATH": harness.controlled_path,
                "TZ": "America/New_York",
            }
            expected_arguments = [
                str(binding.codex),
                "exec",
                "--model",
                "gpt-5.6-sol",
                "--cd",
                str(binding.repository),
                "-c",
                'model_reasoning_effort="xhigh"',
                "-",
            ]

            def fake_popen(arguments: list[str], **kwargs: object) -> object:
                self.assertEqual(arguments, expected_arguments)
                self.assertEqual(kwargs["cwd"], binding.repository)
                self.assertEqual(kwargs["env"], environment)
                self.assertEqual(kwargs["stdin"], subprocess.PIPE)
                self.assertEqual(kwargs["executable"], str(private_copy))
                self.assertNotIn("pass_fds", kwargs)
                self.assertTrue(private_copy.exists())
                raise OSError("simulated Codex spawn failure")

            forward = getattr(module, "_forwarded_child_status", None)
            self.assertIsNotNone(forward)
            assert forward is not None
            try:
                with mock.patch.object(
                    module,
                    "_open_bound_codex",
                    return_value=(
                        source_fd,
                        binding.codex_macho_arch,
                        binding.codex_sha256,
                    ),
                ), mock.patch.object(
                    module,
                    "_materialize_validated_codex",
                    return_value=private_copy,
                    create=True,
                ), mock.patch.object(
                    module.subprocess,
                    "Popen",
                    side_effect=fake_popen,
                ), mock.patch.object(
                    module,
                    "_error",
                    return_value=69,
                ) as error:
                    status = forward(binding, "prompt", environment)
                self.assertEqual(status, 69)
                error.assert_called_once()
                self.assertIn("cannot execute", error.call_args.args[0])
                self.assertFalse(private_copy.exists())
                with self.assertRaises(OSError):
                    os.fstat(source_fd)
            finally:
                try:
                    os.close(source_fd)
                except OSError:
                    pass

    def test_codex_cleanup_failure_returns_nonzero_and_closes_validated_fd(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            private_copy = harness.root / "private codex"
            private_copy.write_bytes(b"validated private copy\n")
            private_copy.chmod(0o700)
            source_fd = os.open(harness.codex, os.O_RDONLY)
            environment = {
                "HOME": str(harness.home),
                "PATH": harness.controlled_path,
                "TZ": "America/New_York",
            }

            class Child:
                stdin = io.BytesIO()

                def wait(self) -> int:
                    return 0

            def fake_popen(_arguments: list[str], **kwargs: object) -> Child:
                self.assertEqual(kwargs["executable"], str(private_copy))
                self.assertNotIn("pass_fds", kwargs)
                self.assertTrue(private_copy.exists())
                return Child()

            def fail_unlink(path: Path, *, missing_ok: bool = False) -> None:
                self.assertEqual(path, private_copy)
                self.assertTrue(missing_ok)
                raise OSError("simulated private-copy cleanup failure")

            forward = getattr(module, "_forwarded_child_status", None)
            self.assertIsNotNone(forward)
            assert forward is not None
            try:
                with mock.patch.object(
                    module,
                    "_open_bound_codex",
                    return_value=(
                        source_fd,
                        binding.codex_macho_arch,
                        binding.codex_sha256,
                    ),
                ), mock.patch.object(
                    module,
                    "_materialize_validated_codex",
                    return_value=private_copy,
                    create=True,
                ), mock.patch.object(
                    module.subprocess,
                    "Popen",
                    side_effect=fake_popen,
                ) as popen, mock.patch.object(
                    Path,
                    "unlink",
                    autospec=True,
                    side_effect=fail_unlink,
                ) as unlink, mock.patch.object(
                    module,
                    "_error",
                    return_value=69,
                ) as error:
                    status = forward(binding, "prompt", environment)
                self.assertNotEqual(status, 0)
                error.assert_called_once()
                self.assertIn("cleanup failed", error.call_args.args[0].lower())
                popen.assert_called_once()
                unlink.assert_called_once_with(private_copy, missing_ok=True)
                self.assertTrue(private_copy.exists())
                with self.assertRaises(OSError):
                    os.fstat(source_fd)
            finally:
                try:
                    os.close(source_fd)
                except OSError:
                    pass

    def test_codex_materialization_and_internal_cleanup_failure_returns_combined_error(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            staging_home = harness.root / "staging home"
            staging_bin = staging_home / ".local" / "bin"
            staging_bin.mkdir(parents=True)
            for path in (staging_home, staging_home / ".local", staging_bin):
                path.chmod(0o700)
            binding.home = staging_home

            source_fd = os.open(harness.codex, os.O_RDONLY)
            environment = {
                "HOME": str(binding.home),
                "PATH": harness.controlled_path,
                "TZ": "America/New_York",
            }
            private_descriptors: list[int] = []
            closed_descriptors: list[int] = []
            real_close = os.close

            def fail_fchmod(descriptor: int, _mode: int) -> None:
                private_descriptors.append(descriptor)
                raise OSError("simulated materialization failure")

            def fail_unlink(path: str, *, dir_fd: int | None = None) -> None:
                self.assertTrue(path.startswith(".ticker-codex-"))
                self.assertIsNotNone(dir_fd)
                raise OSError("simulated internal unlink failure")

            def track_close(descriptor: int) -> None:
                closed_descriptors.append(descriptor)
                real_close(descriptor)

            forward = getattr(module, "_forwarded_child_status", None)
            self.assertIsNotNone(forward)
            assert forward is not None
            try:
                with mock.patch.object(
                    module,
                    "_open_bound_codex",
                    return_value=(
                        source_fd,
                        binding.codex_macho_arch,
                        binding.codex_sha256,
                    ),
                ), mock.patch.object(
                    module.os,
                    "fchmod",
                    side_effect=fail_fchmod,
                ), mock.patch.object(
                    module.os,
                    "unlink",
                    side_effect=fail_unlink,
                ) as unlink, mock.patch.object(
                    module.os,
                    "close",
                    side_effect=track_close,
                ), mock.patch.object(
                    module.subprocess,
                    "Popen",
                ) as popen, mock.patch.object(
                    module,
                    "_error",
                    return_value=69,
                ) as error:
                    status = forward(binding, "prompt", environment)

                self.assertEqual(status, 69)
                error.assert_called_once()
                diagnostic = error.call_args.args[0]
                self.assertIn("simulated materialization failure", diagnostic)
                self.assertIn("simulated internal unlink failure", diagnostic)
                self.assertIn("cleanup failed", diagnostic.lower())
                unlink.assert_called_once()
                popen.assert_not_called()
                self.assertEqual(len(private_descriptors), 1)
                self.assertIn(private_descriptors[0], closed_descriptors)
                self.assertIn(source_fd, closed_descriptors)
                with self.assertRaises(OSError):
                    os.fstat(source_fd)
            finally:
                try:
                    os.close(source_fd)
                except OSError:
                    pass


    def test_unsafe_staging_parent_blocks_spawn_and_closes_validated_fd(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            staging_home = harness.root / "staging home"
            staging_bin = staging_home / ".local" / "bin"
            staging_bin.mkdir(parents=True)
            for path in (staging_home, staging_home / ".local", staging_bin):
                path.chmod(0o700)
            staging_bin.chmod(0o777)
            binding.home = staging_home
            source_fd = os.open(harness.codex, os.O_RDONLY)
            environment = {
                "HOME": str(staging_home),
                "PATH": harness.controlled_path,
                "TZ": "America/New_York",
            }
            forward = getattr(module, "_forwarded_child_status", None)
            self.assertIsNotNone(forward)
            assert forward is not None
            try:
                with mock.patch.object(
                    module,
                    "_open_bound_codex",
                    return_value=(
                        source_fd,
                        binding.codex_macho_arch,
                        binding.codex_sha256,
                    ),
                ), mock.patch.object(
                    module.subprocess,
                    "Popen",
                ) as popen, mock.patch.object(
                    module,
                    "_error",
                    return_value=69,
                ) as error:
                    status = forward(binding, "prompt", environment)
                self.assertNotEqual(status, 0)
                error.assert_called_once()
                popen.assert_not_called()
                self.assertEqual(tuple(staging_bin.iterdir()), ())
                with self.assertRaises(OSError):
                    os.fstat(source_fd)
            finally:
                try:
                    os.close(source_fd)
                except OSError:
                    pass

    def test_all_six_tasks_pin_model_and_reasoning_effort_without_spawning_codex(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            expected_arguments = [
                str(binding.codex),
                "exec",
                "--model",
                "gpt-5.6-sol",
                "--cd",
                str(binding.repository),
                "-c",
                'model_reasoning_effort="xhigh"',
                "-",
            ]
            current_task = [""]
            seen_tasks: list[str] = []

            class Child:
                def __init__(self) -> None:
                    self.stdin = io.BytesIO()

                def wait(self) -> int:
                    return 0

            def fake_popen(arguments: list[str], **kwargs: object) -> Child:
                self.assertEqual(arguments, expected_arguments)
                self.assertEqual(kwargs["cwd"], binding.repository)
                seen_tasks.append(current_task[0])
                return Child()

            for task_id in TASKS:
                with self.subTest(task_id=task_id):
                    current_task[0] = task_id
                    task_root = harness.skill_roots[task_id]
                    skill_path = task_root / "SKILL.md"
                    with mock.patch.object(
                        module,
                        "_read_runtime_binding",
                        return_value=binding,
                    ), mock.patch.object(
                        module,
                        "_task_contract",
                        return_value=("prompt", task_root, skill_path),
                    ), mock.patch.object(
                        module,
                        "_validate_readable_file",
                    ), mock.patch.object(
                        module,
                        "_read_dotenv",
                        return_value={},
                    ), mock.patch.object(
                        module.subprocess,
                        "Popen",
                        side_effect=fake_popen,
                    ), mock.patch.dict(
                        module.os.environ,
                        {
                            "HOME": str(harness.home),
                            "PATH": harness.controlled_path,
                            "TZ": "UTC",
                        },
                        clear=True,
                    ):
                        result = module.run(
                            [task_id, str(harness.working_directory)]
                        )
                    self.assertEqual(result, 0)

            self.assertEqual(seen_tasks, list(TASKS))

    def test_forwarding_signal_mask_order_has_no_spawn_window(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            events: list[object] = []
            handlers: dict[int, object] = {}
            original_mask = frozenset({signal.SIGUSR1})

            class Child:
                stdin = io.BytesIO()

                def send_signal(self, signum: int) -> None:
                    events.append(("child-signal", signum))

                def wait(self) -> int:
                    events.append("wait")
                    return 0

            def fake_mask(how: int, signals: object) -> frozenset[int]:
                events.append(("mask", how, frozenset(signals)))
                return original_mask

            def fake_getsignal(signum: int) -> object:
                events.append(("getsignal", signum))
                return "previous"

            def fake_signal(signum: int, handler: object) -> object:
                if callable(handler):
                    handlers[signum] = handler
                events.append(("signal", signum, handler))
                return "previous"

            def fake_popen(_arguments: object, **kwargs: object) -> Child:
                events.append("popen")
                preexec = kwargs.get("preexec_fn")
                if callable(preexec):
                    preexec()
                    events.append("preexec")
                return Child()

            forward = getattr(module, "_forwarded_child_status", None)
            self.assertIsNotNone(
                forward,
                "RED contract missing signal runner seam",
            )
            assert forward is not None
            with mock.patch.object(
                module.signal,
                "pthread_sigmask",
                side_effect=fake_mask,
                create=True,
            ), mock.patch.object(
                module.signal,
                "getsignal",
                side_effect=fake_getsignal,
            ), mock.patch.object(
                module.signal,
                "signal",
                side_effect=fake_signal,
            ), mock.patch.object(
                module.subprocess,
                "Popen",
                side_effect=fake_popen,
            ):
                status = forward(
                    binding,
                    "prompt",
                    {
                        "HOME": str(harness.home),
                        "PATH": harness.controlled_path,
                        "TZ": "America/New_York",
                    },
                )
            self.assertEqual(status, 0)
            block_events = [
                index
                for index, event in enumerate(events)
                if isinstance(event, tuple)
                and event[0] == "mask"
                and event[1] == signal.SIG_BLOCK
            ]
            setmask_events = [
                index
                for index, event in enumerate(events)
                if isinstance(event, tuple)
                and event[0] == "mask"
                and event[1] == signal.SIG_SETMASK
            ]
            install_events = [
                index
                for index, event in enumerate(events)
                if isinstance(event, tuple)
                and event[0] == "signal"
                and callable(event[2])
            ]
            popen_index = events.index("popen")
            wait_index = events.index("wait")
            self.assertTrue(block_events)
            self.assertTrue(setmask_events)
            self.assertTrue(install_events)
            self.assertLess(block_events[0], install_events[0])
            self.assertLess(install_events[-1], popen_index)
            self.assertGreater(setmask_events[0], popen_index)
            self.assertGreater(wait_index, setmask_events[0])
            self.assertGreater(block_events[-1], wait_index)
            self.assertGreater(setmask_events[-1], block_events[-1])
            final_mask = events[setmask_events[-1]]
            assert isinstance(final_mask, tuple)
            self.assertEqual(final_mask[2], original_mask)
            for signum in module.HANDLED_SIGNALS:
                handler = handlers.get(signum)
                if callable(handler):
                    handler(signum, None)
                    self.assertIn(("child-signal", signum), events)

    def test_source_is_generated_python_runner_without_shell_dispatch_or_loader(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("TICKER-RUNTIME-V1", source)
        self.assertIn("json", source)
        self.assertNotIn("select_task() {", source)
        self.assertNotIn("load-env.sh", source)
        self.assertNotRegex(source, r"\bcommand\s+-v\s+codex\b")
        for task_id in TASKS:
            with self.subTest(task_id=task_id):
                self.assertIn(task_id, source)


    def test_runner_shebang_isolates_pythonpath_sitecustomize(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            pythonpath = harness.root / "attacker pythonpath"
            pythonpath.mkdir()
            sentinel = harness.root / "sitecustomize sentinel"
            (pythonpath / "sitecustomize.py").write_text(
                "from pathlib import Path\n"
                f"Path({str(sentinel)!r}).write_text('executed\\n', encoding='utf-8')\n",
                encoding="utf-8",
            )
            environment = self.invocation_environment(harness)
            environment["PYTHONPATH"] = str(pythonpath)

            result = self.invoke(
                harness,
                "daily-summary",
                environment=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.read_events(harness), ["native-codex"])
            self.assertFalse(sentinel.exists())

    def test_all_six_tasks_send_exact_stdin_arguments_and_bound_environment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            expected_events: list[str] = []
            for task_id in TASKS:
                with self.subTest(task_id=task_id):
                    for artifact in (
                        harness.stdin,
                        harness.argv,
                        harness.environment,
                    ):
                        artifact.unlink(missing_ok=True)
                    result = self.invoke(harness, task_id)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    prompt, skill_path = expected_task_contract(
                        task_id,
                        harness.home,
                        harness.working_directory,
                        harness.skill_roots,
                        codex_home=harness.codex_home,
                    )
                    self.assertEqual(
                        harness.stdin.read_bytes(),
                        (prompt + "\n").encode("utf-8"),
                    )
                    self.assertEqual(
                        harness.argv.read_text(encoding="utf-8").splitlines(),
                        [
                            "exec",
                            "--model",
                            "gpt-5.6-sol",
                            "--cd",
                            str(harness.working_directory),
                            "-c",
                            'model_reasoning_effort="xhigh"',
                            "-",
                        ],
                    )
                    environment = dict(
                        line.split("=", 1)
                        for line in harness.environment.read_text(
                            encoding="utf-8"
                        ).splitlines()
                    )
                    run_date = environment.pop("SCHEDULED_RUN_DATE_ET")
                    self.assertRegex(run_date, r"^\d{4}-\d{2}-\d{2}$")
                    self.assertEqual(
                        {
                            key: environment.get(key, "")
                            for key in (
                                "SCHEDULED_AGENT_ENGINE",
                                "SCHEDULED_SKILL_ROOT",
                                "SCHEDULED_SKILL_LINK",
                                "HOME",
                                "PATH",
                                "TZ",
                                "TASK_ID",
                                "WORKING_DIRECTORY",
                                "ENV_LOADER",
                                "REPO_VALUE",
                                "DOTENV_COMMAND",
                                "SLACK_BOT_TOKEN",
                                "SLACK_APP_TOKEN",
                            )
                        },
                        {
                            "SCHEDULED_AGENT_ENGINE": "codex",
                            "SCHEDULED_SKILL_ROOT": str(skill_path.parent),
                            "SCHEDULED_SKILL_LINK": str(skill_path),
                            "HOME": str(harness.home),
                            "PATH": harness.controlled_path,
                            "TZ": "America/New_York",
                            "TASK_ID": task_id,
                            "WORKING_DIRECTORY": str(harness.working_directory),
                            "ENV_LOADER": "",
                            "REPO_VALUE": "loaded",
                            "DOTENV_COMMAND": "",
                            "SLACK_BOT_TOKEN": "",
                            "SLACK_APP_TOKEN": "",
                        },
                    )
                    expected_events.append("native-codex")
            self.assertEqual(self.read_events(harness), expected_events)
            self.assertFalse(harness.rogue_events.exists())


    def test_v2_binding_uses_exact_bound_skill_root_and_missing_task_fails_before_spawn(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            bound_root = harness.root / "bound canonical skill"
            bound_root.mkdir()
            (bound_root / "SKILL.md").write_text("bound skill\n", encoding="utf-8")
            binding = dict(harness.binding)
            skill_roots = dict(binding["skill_roots"])
            skill_roots["daily-summary"] = str(bound_root)
            binding["skill_roots"] = skill_roots
            harness.runner.write_bytes(render_test_runner(RUNNER.read_bytes(), binding))
            harness.runner.chmod(0o755)

            result = self.invoke(harness, "daily-summary")
            self.assertEqual(result.returncode, 0, result.stderr)
            environment = dict(
                line.split("=", 1)
                for line in harness.environment.read_text(encoding="utf-8").splitlines()
            )
            self.assertEqual(environment["SCHEDULED_SKILL_ROOT"], str(bound_root))
            self.assertEqual(
                environment["SCHEDULED_SKILL_LINK"],
                str(bound_root / "SKILL.md"),
            )
            self.assertIn(str(bound_root), harness.stdin.read_text(encoding="utf-8"))

            for artifact in (
                harness.events,
                harness.stdin,
                harness.argv,
                harness.environment,
            ):
                artifact.unlink(missing_ok=True)
            unknown = self.invoke(harness, "missing-task-entry")
            self.assertEqual(unknown.returncode, 64)
            self.assertFalse(harness.events.exists())
            self.assertFalse(harness.stdin.exists())

            (bound_root / "SKILL.md").unlink()
            missing_root_file = self.invoke(harness, "daily-summary")
            self.assertEqual(missing_root_file.returncode, 66)
            self.assertFalse(harness.events.exists())
            self.assertFalse(harness.stdin.exists())

    def test_legacy_v2_symlink_skill_root_resolves_safely_before_spawn(self) -> None:
        for case in ("safe", "writable-parent", "wrong-target"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                harness = self.make_harness(Path(directory))
                agents = harness.codex_home / "AGENTS.md"
                agents.write_text("synthetic Codex instructions\n", encoding="utf-8")
                agents.chmod(0o600)
                canonical_root = harness.root / "legacy canonical skill"
                canonical_root.mkdir()
                (canonical_root / "SKILL.md").write_text(
                    "canonical skill\n",
                    encoding="utf-8",
                )
                (canonical_root / "SKILL.md").chmod(0o600)
                link_parent = harness.codex_home / "skills"
                link_parent.mkdir()
                link_parent.chmod(0o700)
                root_link = link_parent / "daily-summary"
                root_link.symlink_to(canonical_root, target_is_directory=True)
                if case == "writable-parent":
                    link_parent.chmod(0o777)
                elif case == "wrong-target":
                    wrong_target = harness.root / "wrong target"
                    wrong_target.mkdir()
                    wrong_target.chmod(0o777)
                    (wrong_target / "SKILL.md").write_text(
                        "wrong target\n",
                        encoding="utf-8",
                    )
                    (wrong_target / "SKILL.md").chmod(0o600)
                    root_link.unlink()
                    root_link.symlink_to(wrong_target, target_is_directory=True)

                binding = dict(harness.binding)
                skill_roots = dict(binding["skill_roots"])
                skill_roots["daily-summary"] = str(root_link)
                binding["skill_roots"] = skill_roots
                harness.runner.write_bytes(
                    render_test_runner(RUNNER.read_bytes(), binding)
                )
                harness.runner.chmod(0o755)

                result = self.invoke(harness, "daily-summary")
                if case == "safe":
                    self.assertEqual(result.returncode, 0, result.stderr)
                    environment = dict(
                        line.split("=", 1)
                        for line in harness.environment.read_text(
                            encoding="utf-8"
                        ).splitlines()
                    )
                    self.assertEqual(
                        environment["SCHEDULED_SKILL_ROOT"],
                        str(canonical_root),
                    )
                    self.assertEqual(
                        environment["SCHEDULED_SKILL_LINK"],
                        str(canonical_root / "SKILL.md"),
                    )
                    self.assertIn(
                        str(canonical_root),
                        harness.stdin.read_text(encoding="utf-8"),
                    )
                else:
                    self.assertIn(result.returncode, {66, 78})
                    self.assertFalse(harness.events.exists())
                    self.assertFalse(harness.stdin.exists())
                    self.assertFalse(harness.rogue_events.exists())

    def test_date_is_captured_before_data_parser_and_controls_are_reasserted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            result = self.invoke(harness, "daily-summary")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.read_events(harness), ["native-codex"])
            environment = harness.environment.read_text(encoding="utf-8")
            self.assertRegex(environment, r"(?m)^SCHEDULED_RUN_DATE_ET=\d{4}-\d{2}-\d{2}$")
            self.assertIn("SCHEDULED_AGENT_ENGINE=codex\n", environment)
            self.assertNotIn("2099-01-01", environment)
            self.assertNotIn("SCHEDULED_AGENT_ENGINE=claude", environment)
            self.assertNotIn("poisoned", environment)
            self.assertNotIn("load-env.sh", environment)

    def test_dotenv_values_cannot_redirect_trusted_runner_controls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            result = self.invoke(harness, "daily-summary")
            self.assertEqual(result.returncode, 0, result.stderr)
            environment = dict(
                line.split("=", 1)
                for line in harness.environment.read_text(encoding="utf-8").splitlines()
            )
            self.assertEqual(
                {
                    key: environment.get(key, "")
                    for key in (
                        "TASK_ID",
                        "WORKING_DIRECTORY",
                        "HOME",
                        "PATH",
                        "TZ",
                        "ENV_LOADER",
                        "REPO_VALUE",
                    )
                },
                {
                    "TASK_ID": "daily-summary",
                    "WORKING_DIRECTORY": str(harness.working_directory),
                    "HOME": str(harness.home),
                    "PATH": harness.controlled_path,
                    "TZ": "America/New_York",
                    "ENV_LOADER": "",
                    "REPO_VALUE": "loaded",
                },
            )
            self.assertEqual(
                harness.argv.read_text(encoding="utf-8").splitlines(),
                [
                    "exec",
                    "--model",
                    "gpt-5.6-sol",
                    "--cd",
                    str(harness.working_directory),
                    "-c",
                    'model_reasoning_effort="xhigh"',
                    "-",
                ],
            )


    def test_runner_rejects_untrusted_bound_path_component_and_codex_home(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            module = self.load_runner_module(harness)
            binding = self.binding_object(harness)
            task_root = harness.skill_roots["daily-summary"]
            skill_path = task_root / "SKILL.md"
            optional_path = harness.root / "optional path"
            optional_path.mkdir()
            optional_path.chmod(0o700)
            trusted_path = ":".join(
                [
                    str(harness.codex.parent),
                    str(optional_path),
                    "/usr/bin",
                ]
            )
            binding.path = trusted_path

            def run_case() -> tuple[int, mock.Mock]:
                child = mock.Mock()
                child.stdin = io.BytesIO()
                child.wait.return_value = 0
                with mock.patch.object(
                    module,
                    "_read_runtime_binding",
                    return_value=binding,
                ), mock.patch.object(
                    module,
                    "_task_contract",
                    return_value=("prompt", task_root, skill_path),
                ), mock.patch.object(
                    module,
                    "_read_dotenv",
                    return_value={},
                ), mock.patch.object(
                    module.subprocess,
                    "Popen",
                    return_value=child,
                ) as popen, mock.patch.dict(
                    module.os.environ,
                    {
                        "HOME": str(harness.home),
                        "PATH": trusted_path,
                        "TZ": "UTC",
                    },
                    clear=True,
                ):
                    status = module.run(
                        ["daily-summary", str(harness.working_directory)]
                    )
                return status, popen

            status, popen = run_case()
            self.assertEqual(status, 0)
            popen.assert_called_once()

            def assert_rejected(
                label: str,
                mutate: object,
                restore: object,
            ) -> None:
                with self.subTest(case=label):
                    assert callable(mutate)
                    assert callable(restore)
                    mutate()
                    try:
                        status, popen = run_case()
                    finally:
                        restore()
                    self.assertEqual(status, 78)
                    popen.assert_not_called()

            assert_rejected(
                "writable PATH component",
                lambda: optional_path.chmod(0o777),
                lambda: optional_path.chmod(0o700),
            )
            assert_rejected(
                "writable Codex home",
                lambda: harness.codex_home.chmod(0o777),
                lambda: harness.codex_home.chmod(0o700),
            )
            codex_home_link = harness.root / "codex home link"

            def symlink_codex_home() -> None:
                codex_home_link.symlink_to(
                    harness.codex_home,
                    target_is_directory=True,
                )
                binding.codex_home = codex_home_link

            def restore_codex_home() -> None:
                binding.codex_home = harness.codex_home
                codex_home_link.unlink()

            assert_rejected(
                "symlinked Codex home",
                symlink_codex_home,
                restore_codex_home,
            )


            config = harness.codex_home / "config.toml"
            assert_rejected(
                "writable Codex config",
                lambda: config.chmod(0o666),
                lambda: config.chmod(0o600),
            )
            assert_rejected(
                "group-readable Codex config",
                lambda: config.chmod(0o644),
                lambda: config.chmod(0o600),
            )

            config_target = harness.root / "config target.toml"
            config_target.write_text("", encoding="utf-8")
            config_target.chmod(0o600)

            def symlink_config() -> None:
                config.unlink()
                config.symlink_to(config_target)

            def restore_config() -> None:
                config.unlink()
                config.write_text("", encoding="utf-8")
                config.chmod(0o600)

            assert_rejected(
                "symlinked Codex config",
                symlink_config,
                restore_config,
            )

            auth = harness.codex_home / "auth.json"
            assert_rejected(
                "auth mode 0644",
                lambda: auth.chmod(0o644),
                lambda: auth.chmod(0o600),
            )

            for filename in ("AGENTS.md", "hooks.json"):
                surface = harness.codex_home / filename
                surface.write_text("synthetic trusted surface\n", encoding="utf-8")
                surface.chmod(0o600)
                assert_rejected(
                    f"writable Codex {filename}",
                    lambda surface=surface: surface.chmod(0o660),
                    lambda surface=surface: surface.chmod(0o600),
                )

            for directory_name in ("skills", "rules", "policy"):
                surface = harness.codex_home / directory_name
                surface.mkdir()
                surface.chmod(0o700)
                assert_rejected(
                    f"writable Codex {directory_name} surface",
                    lambda surface=surface: surface.chmod(0o770),
                    lambda surface=surface: surface.chmod(0o700),
                )

            status, popen = run_case()
            self.assertEqual(status, 0)
            popen.assert_called_once()

    def test_bound_home_rejects_inherited_mismatch_symlink_and_colon(self) -> None:
        for label in ("missing", "alternate", "symlink", "colon", "relative"):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve(strict=True)
                harness = self.make_harness(root)
                alternate = root / "alternate home"
                alternate.mkdir()
                home_values: dict[str, str] = {
                    "alternate": str(alternate),
                    "symlink": str(root / "home link"),
                    "colon": str(harness.home) + ":poison",
                    "relative": "relative home",
                }
                if label == "symlink":
                    (root / "home link").symlink_to(harness.home, target_is_directory=True)
                environment = {
                    "PATH": harness.controlled_path,
                    "TZ": "UTC",
                }
                if label != "missing":
                    environment["HOME"] = home_values[label]
                result = self.invoke(
                    harness,
                    "daily-summary",
                    environment=environment,
                )
                self.assertEqual(result.returncode, 78)
                self.assertIn("HOME", result.stderr)
                self.assertEqual(self.read_events(harness), [])
                self.assertFalse(harness.rogue_events.exists())
                self.assertFalse(harness.stdin.exists())

    def test_repository_loader_replacement_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = self.make_harness(root)
            loader_attempted = root / "loader-attempted"
            harness.loader.write_text(
                "#!/bin/sh\n"
                f"printf 'loader\\n' > {shlex.quote(str(loader_attempted))}\n"
                "exit 91\n",
                encoding="utf-8",
            )
            harness.loader.chmod(0o755)
            result = self.invoke(harness, "daily-summary")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.read_events(harness), ["native-codex"])
            self.assertFalse(loader_attempted.exists())
            self.assertFalse(harness.rogue_events.exists())

    def test_exact_bound_codex_runs_after_path_changes_and_rogue_setup_tools(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            result = self.invoke(
                harness,
                "daily-summary",
                environment={
                    "HOME": str(harness.home),
                    "PATH": harness.rogue_path,
                    "TZ": "UTC",
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.read_events(harness), ["native-codex"])
            self.assertFalse(harness.rogue_events.exists())
            self.assertEqual(
                harness.argv.read_text(encoding="utf-8").splitlines(),
                [
                    "exec",
                    "--model",
                    "gpt-5.6-sol",
                    "--cd",
                    str(harness.working_directory),
                    "-c",
                    'model_reasoning_effort="xhigh"',
                    "-",
                ],
            )

    def test_dotenv_is_data_not_shell_and_preserves_cinder_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "shell-executed"
            harness = self.make_harness(
                root,
                dotenv_body=(
                    "# comments outside quotes are ignored\n"
                    "DOTENV_DOUBLE=\"double # value\"\n"
                    "DOTENV_SINGLE='single value'\n"
                    + "DOTENV_ESCAPED=" + json.dumps('quote " and slash \\') + "\n"
                    + f"DOTENV_COMMAND=$(printf executed > {shlex.quote(str(marker))})\n"
                    + "BAD-KEY=must-be-ignored\n"
                    + "malformed line must-be-ignored\n"
                    + "CINDER_SLACK_BOT_TOKEN=synthetic-bot-token\n"
                    + "CINDER_SLACK_APP_TOKEN=synthetic-app-token\n"
                ),
            )
            result = self.invoke(harness, "daily-summary")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(harness.rogue_events.exists())
            environment = dict(
                line.split("=", 1)
                for line in harness.environment.read_text(encoding="utf-8").splitlines()
            )
            self.assertEqual(environment["DOTENV_DOUBLE"], "double # value")
            self.assertEqual(environment["DOTENV_SINGLE"], "single value")
            self.assertEqual(environment["DOTENV_ESCAPED"], 'quote " and slash \\')
            self.assertEqual(
                environment["DOTENV_COMMAND"],
                "$(printf executed > " + shlex.quote(str(marker)) + ")",
            )
            self.assertEqual(environment["SLACK_BOT_TOKEN"], "synthetic-bot-token")
            self.assertEqual(environment["SLACK_APP_TOKEN"], "synthetic-app-token")
            self.assertEqual(environment.get("DOTENV_BAD", ""), "")

    def test_dotenv_rejects_group_or_other_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))

            harness.dotenv.chmod(0o644)
            rejected = self.invoke(harness, "daily-summary")
            self.assertEqual(rejected.returncode, 78)
            self.assertRegex(rejected.stderr.lower(), r"owner.?only|permission")
            self.assertEqual(self.read_events(harness), [])
            self.assertFalse(harness.rogue_events.exists())
            self.assertFalse(harness.stdin.exists())

            harness.events.unlink(missing_ok=True)
            harness.dotenv.chmod(0o600)
            accepted = self.invoke(harness, "daily-summary")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertEqual(self.read_events(harness), ["native-codex"])
            self.assertFalse(harness.rogue_events.exists())


    def test_missing_or_malformed_runtime_binding_fails_closed(self) -> None:
        for label in ("missing", "malformed"):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                harness = self.make_harness(Path(directory))
                source = harness.runner.read_bytes()
                lines = source.splitlines(keepends=True)
                self.assertTrue(lines and lines[0].startswith(b"#!"))
                if label == "missing":
                    harness.runner.write_bytes(
                        b"".join(
                            line
                            for line in lines
                            if not line.startswith(b"# TICKER-RUNTIME-V1 ")
                            and not line.startswith(b"RUNTIME_BINDING = ")
                        )
                    )
                else:
                    malformed_lines = []
                    for line in lines:
                        if line.startswith(b"# TICKER-RUNTIME-V1 "):
                            malformed_lines.append(
                                b"# TICKER-RUNTIME-V1 {malformed-json}\n"
                            )
                        elif line.startswith(b"RUNTIME_BINDING = "):
                            malformed_lines.append(
                                b"RUNTIME_BINDING = {'malformed': True}\n"
                            )
                        else:
                            malformed_lines.append(line)
                    harness.runner.write_bytes(b"".join(malformed_lines))
                result = self.invoke(
                    harness,
                    "daily-summary",
                    environment={
                        "HOME": str(harness.home),
                        "PATH": harness.rogue_path,
                        "TZ": "UTC",
                    },
                    interpreter=Path(sys.executable),
                )
                self.assertEqual(result.returncode, 78)
                self.assertIn("binding", result.stderr.lower())
                self.assertEqual(self.read_events(harness), [])
                self.assertFalse(harness.rogue_events.exists())
                self.assertFalse(harness.stdin.exists())



    def test_missing_root_stops_before_codex(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(
                Path(directory),
                omit_task_root="daily-summary",
            )
            result = self.invoke(harness, "daily-summary")
            self.assertEqual(result.returncode, 66)
            self.assertIn(
                "scheduled root skill is not a readable regular file",
                result.stderr,
            )
            self.assertFalse(harness.stdin.exists())

    def test_codex_failure_status_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory), codex_status=42)
            result = self.invoke(harness, "team-progress-digest")
            self.assertEqual(result.returncode, 42)
            self.assertTrue(harness.stdin.exists())

    def test_rejects_wrong_arity_unknown_task_and_wrong_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            harness = self.make_harness(Path(directory))
            wrong_arity = subprocess.run(
                [str(harness.runner), "daily-summary"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
                env=self.invocation_environment(harness),
            )
            self.assertEqual(wrong_arity.returncode, 64)
            unknown = self.invoke(harness, "not-approved")
            self.assertEqual(unknown.returncode, 64)
            self.assertIn("unknown scheduled task id", unknown.stderr)
            wrong_cwd = self.invoke(
                harness,
                "daily-summary",
                harness.working_directory / "other",
            )
            self.assertEqual(wrong_cwd.returncode, 72)
            self.assertIn(
                "working directory is not the approved repository",
                wrong_cwd.stderr,
            )


if __name__ == "__main__":
    unittest.main()
