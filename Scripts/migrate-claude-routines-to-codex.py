#!/usr/bin/python3 -I
"""Atomically move six Claude schedules to Ticker-observed Codex launchd jobs."""

from __future__ import annotations

import contextlib
import dataclasses
import datetime as dt
import enum
import fcntl
import grp
import hashlib
import json
import os
import platform
import plistlib
import pwd
import re
import secrets
import shlex
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple
from zoneinfo import ZoneInfo


class CutoverError(RuntimeError):
    pass


class RollbackError(CutoverError):
    pass


class CutoverSignal(BaseException):
    def __init__(self, signum: int) -> None:
        super().__init__(f"cutover interrupted by signal {signum}")
        self.signum = signum


RUNTIME_BINDING_PREFIX = b"# TICKER-RUNTIME-V1 "
RUNTIME_BINDING_VERSION = 3
RUNTIME_MODEL = "gpt-5.6-sol"
_CONTROL_CHARACTER_RE = re.compile(r"[\x00-\x1f\x7f]")
_NATIVE_MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}
_ELF_MAGIC = b"\x7fELF"
_RUNTIME_TASK_IDS = (
    "daily-summary",
    "daily-vitals-morning",
    "linkedin-post-ideas",
    "linkedin-post-ideas-sweeper",
    "overdue-customer-issues-slack",
    "team-progress-digest",
)


def _validate_path_text(value: str, description: str, *, allow_colon: bool = False) -> None:
    if not value or _CONTROL_CHARACTER_RE.search(value):
        raise CutoverError(f"{description} contains control characters")
    if not allow_colon and ":" in value:
        raise CutoverError(f"{description} contains a colon")


def _validate_absolute_path_text(value: str, description: str) -> Path:
    _validate_path_text(value, description)
    path = Path(value)
    if not path.is_absolute():
        raise CutoverError(f"{description} must be absolute")
    return path


def _validate_directory_metadata(
    metadata: os.stat_result,
    uid: int,
    description: str,
    *,
    require_owner: bool = False,
) -> None:
    if not stat.S_ISDIR(metadata.st_mode):
        raise CutoverError(f"{description} is not a directory")
    if require_owner and metadata.st_uid != uid:
        raise CutoverError(f"{description} is not owned by the current user")
    mode = stat.S_IMODE(metadata.st_mode)
    if mode & 0o022 and (
        metadata.st_uid != 0 or not mode & stat.S_ISVTX
    ):
        raise CutoverError(f"{description} is group or other writable")
    if metadata.st_uid not in (uid, 0):
        raise CutoverError(f"{description} has an unexpected owner")


def _validate_trusted_directory_path(
    path: Path,
    uid: int,
    description: str,
    *,
    require_owner: bool = False,
) -> None:
    _validate_path_text(str(path), description)
    if not path.is_absolute():
        raise CutoverError(f"{description} must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise CutoverError(f"{description} is missing") from error
    if resolved != path:
        raise CutoverError(f"{description} must not contain symlinks")
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except OSError as error:
            raise CutoverError(f"{description} is missing") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise CutoverError(f"{description} must not contain symlinks")
        _validate_directory_metadata(
            metadata,
            uid,
            f"{description} component {current}",
            require_owner=require_owner and current == path,
        )


def _descriptor_number(handle: object) -> int:
    if isinstance(handle, int):
        return handle
    fileno = getattr(handle, "fileno", None)
    if not callable(fileno):
        raise CutoverError("trusted descriptor handle has no file descriptor")
    try:
        descriptor = int(fileno())
    except (OSError, TypeError, ValueError) as error:
        raise CutoverError("trusted descriptor handle is invalid") from error
    if descriptor < 0:
        raise CutoverError("trusted descriptor handle is closed")
    return descriptor


def _validate_open_directory(
    descriptor: int,
    uid: int,
    description: str,
    *,
    require_owner: bool = False,
) -> os.stat_result:
    try:
        metadata = os.fstat(descriptor)
    except OSError as error:
        raise CutoverError(f"cannot inspect {description}") from error
    _validate_directory_metadata(
        metadata,
        uid,
        description,
        require_owner=require_owner,
    )
    return metadata


def _validate_open_regular(
    descriptor: int,
    uid: int,
    mode: Optional[int],
    description: str,
) -> os.stat_result:
    try:
        metadata = os.fstat(descriptor)
    except OSError as error:
        raise CutoverError(f"cannot inspect {description}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise CutoverError(f"{description} is not a regular file")
    if metadata.st_uid != uid:
        raise CutoverError(f"{description} is not owned by the current user")
    actual_mode = stat.S_IMODE(metadata.st_mode)
    if actual_mode & 0o022:
        raise CutoverError(f"{description} is group or other writable")
    if mode is not None and actual_mode != mode:
        raise CutoverError(f"{description} mode is not {mode:04o}")
    return metadata


def open_trusted_directory_chain(path: Path, uid: int, description: str) -> int:
    """Open every directory component with O_NOFOLLOW and validate each descriptor."""
    _validate_trusted_directory_path(path, uid, description)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor: Optional[int] = None
    child: Optional[int] = None
    previous: Optional[int] = None
    try:
        descriptor = os.open(path.anchor or os.sep, flags)
        _validate_open_directory(descriptor, uid, description)
        current = Path(path.anchor)
        for component in path.parts[1:]:
            child = os.open(component, flags, dir_fd=descriptor)
            _validate_open_directory(
                child,
                uid,
                f"{description} component {current / component}",
            )
            previous = descriptor
            descriptor = child
            child = None
            os.close(previous)
            previous = None
            current /= component
        if descriptor is None:
            raise CutoverError(f"cannot open {description}")
        result = descriptor
        descriptor = None
        return result
    except OSError as error:
        raise CutoverError(f"cannot open {description}: {path}") from error
    finally:
        seen: set[int] = set()
        for open_descriptor in (child, previous, descriptor):
            if open_descriptor is None or open_descriptor in seen:
                continue
            seen.add(open_descriptor)
            try:
                os.close(open_descriptor)
            except OSError:
                pass


def open_trusted_regular_at(
    parent_descriptor: object,
    name: str,
    uid: int,
    mode: Optional[int],
    description: str,
) -> int:
    """Open one regular file relative to a validated directory descriptor."""
    _validate_path_text(name, description)
    if not name or "/" in name or name in {".", ".."}:
        raise CutoverError(f"{description} name is not a single path component")
    parent_fd = _descriptor_number(parent_descriptor)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        raise CutoverError(f"cannot open {description}") from error
    try:
        _validate_open_regular(descriptor, uid, mode, description)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_open_descriptor(handle: object, description: str) -> bytes:
    """Read bytes only from the already validated descriptor."""
    descriptor = _descriptor_number(handle)
    try:
        metadata = _validate_open_regular(descriptor, os.getuid(), None, description)
        chunks: List[bytes] = []
        offset = 0
        remaining = metadata.st_size
        while remaining:
            try:
                chunk = os.pread(descriptor, min(1024 * 1024, remaining), offset)
            except InterruptedError:
                continue
            except OSError as error:
                raise CutoverError(f"cannot read {description}") from error
            if not chunk:
                raise CutoverError(f"{description} changed while being read")
            if len(chunk) > remaining:
                raise CutoverError(f"{description} changed while being read")
            chunks.append(chunk)
            offset += len(chunk)
            remaining -= len(chunk)
        try:
            final_size = os.fstat(descriptor).st_size
        except OSError as error:
            raise CutoverError(f"cannot inspect {description}") from error
        if final_size != metadata.st_size:
            raise CutoverError(f"{description} changed while being read")
        return b"".join(chunks)
    except OSError as error:
        raise CutoverError(f"cannot read {description}") from error

@dataclasses.dataclass(frozen=True)
class RuntimeBinding:
    binding_version: int
    uid: int
    home: Path
    repository: Path
    python: Path
    codex: Path
    codex_home: Path
    path: str
    model: str
    skill_roots: Mapping[str, Path]
    codex_sha256: Optional[str]
    codex_macho_arch: Optional[str]
    codex_managed_package_root: Optional[Path]
    codex_managed_package_version: Optional[str]
    codex_code_mode_host: Optional[Path]
    codex_code_mode_host_sha256: Optional[str]
    codex_managed_by: str

    def as_dict(self) -> Dict[str, object]:
        return {
            "binding_version": self.binding_version,
            "uid": self.uid,
            "home": str(self.home),
            "repository": str(self.repository),
            "python": str(self.python),
            "codex": str(self.codex),
            "codex_home": str(self.codex_home),
            "path": self.path,
            "model": self.model,
            "skill_roots": {
                name: str(self.skill_roots[name]) for name in _RUNTIME_TASK_IDS
            },
            "codex_sha256": self.codex_sha256,
            "codex_macho_arch": self.codex_macho_arch,
            "codex_code_mode_host": (
                None if self.codex_code_mode_host is None else str(self.codex_code_mode_host)
            ),
            "codex_code_mode_host_sha256": self.codex_code_mode_host_sha256,
            "codex_managed_package_root": (
                None
                if self.codex_managed_package_root is None
                else str(self.codex_managed_package_root)
            ),
            "codex_managed_package_version": self.codex_managed_package_version,
            "codex_managed_by": self.codex_managed_by,
        }

    @classmethod
    def from_mapping(cls, value: Any) -> "RuntimeBinding":
        if not isinstance(value, dict):
            raise CutoverError("runtime binding keys are invalid")
        legacy_keys = {
            "uid",
            "home",
            "repository",
            "python",
            "codex",
            "path",
            "model",
            "codex_managed_package_root",
            "codex_managed_by",
        }
        v2_keys = {
            "binding_version",
            "uid",
            "home",
            "repository",
            "python",
            "codex",
            "codex_home",
            "path",
            "model",
            "skill_roots",
            "codex_sha256",
            "codex_macho_arch",
            "codex_managed_package_root",
            "codex_managed_package_version",
            "codex_managed_by",
        }
        v3_keys = v2_keys | {
            "codex_code_mode_host",
            "codex_code_mode_host_sha256",
        }
        legacy_v2_keys = v2_keys - {"codex_home"}
        if set(value) == legacy_keys:
            version = 1
        elif (
            set(value) in (legacy_v2_keys, v2_keys)
            and value.get("binding_version") == 2
        ):
            version = 2
        elif set(value) == v3_keys and value.get("binding_version") == RUNTIME_BINDING_VERSION:
            version = RUNTIME_BINDING_VERSION
        else:
            raise CutoverError("runtime binding keys are invalid")
        uid = value["uid"]
        if isinstance(uid, bool) or not isinstance(uid, int) or uid < 0:
            raise CutoverError("runtime binding uid is invalid")

        path_values: Dict[str, Path] = {}
        for key in ("home", "repository", "python", "codex"):
            raw = value[key]
            if not isinstance(raw, str):
                raise CutoverError(f"runtime binding {key} is invalid")
            path_values[key] = _validate_absolute_path_text(raw, f"runtime binding {key}")
        if version == 1 or "codex_home" not in value:
            codex_home = path_values["home"] / ".codex"
        else:
            raw_codex_home = value["codex_home"]
            if not isinstance(raw_codex_home, str):
                raise CutoverError("runtime binding codex_home is invalid")
            codex_home = _validate_absolute_path_text(
                raw_codex_home,
                "runtime binding codex_home",
            )

        path_value = value["path"]
        if not isinstance(path_value, str):
            raise CutoverError("runtime binding PATH is invalid")
        _validate_path_text(path_value, "runtime binding PATH", allow_colon=True)
        components = path_value.split(":")
        if not components or any(
            not component or not Path(component).is_absolute() for component in components
        ):
            raise CutoverError("runtime binding PATH must contain absolute components")
        if value["model"] != RUNTIME_MODEL:
            raise CutoverError("runtime binding model is invalid")

        manager = value["codex_managed_by"]
        if manager not in {"direct", "npm"}:
            raise CutoverError("runtime binding manager is invalid")

        package_root_value = value["codex_managed_package_root"]
        if package_root_value is None:
            package_root = None
        elif isinstance(package_root_value, str):
            package_root = _validate_absolute_path_text(
                package_root_value,
                "runtime binding codex package root",
            )
        else:
            raise CutoverError("runtime binding codex package root is invalid")

        package_version = value.get("codex_managed_package_version")
        if version == 1:
            package_version = None
            skill_roots: Mapping[str, Path] = {}
            digest = None
            arch = None
            code_mode_host = None
            code_mode_host_digest = None
        else:
            if manager == "npm":
                if (
                    not isinstance(package_version, str)
                    or not package_version
                    or _CONTROL_CHARACTER_RE.search(package_version)
                    or ":" in package_version
                ):
                    raise CutoverError("runtime binding package version is invalid")
            elif package_version is not None:
                raise CutoverError("direct runtime binding package version is invalid")
            raw_roots = value["skill_roots"]
            if not isinstance(raw_roots, dict) or set(raw_roots) != set(_RUNTIME_TASK_IDS):
                raise CutoverError("runtime binding skill roots are invalid")
            root_values: Dict[str, Path] = {}
            for task_id in _RUNTIME_TASK_IDS:
                raw_root = raw_roots[task_id]
                if not isinstance(raw_root, str):
                    raise CutoverError(f"runtime binding skill root is invalid: {task_id}")
                root_values[task_id] = _validate_absolute_path_text(
                    raw_root,
                    f"runtime binding skill root {task_id}",
                )
            skill_roots = root_values
            digest = value["codex_sha256"]
            if (
                not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            ):
                raise CutoverError("runtime binding Codex digest is invalid")
            arch = value["codex_macho_arch"]
            if arch not in {"arm64", "x86_64"}:
                raise CutoverError("runtime binding Codex architecture is invalid")
            if version >= 3:
                raw_code_mode_host = value["codex_code_mode_host"]
                if not isinstance(raw_code_mode_host, str):
                    raise CutoverError("runtime binding Codex code-mode host is invalid")
                code_mode_host = _validate_absolute_path_text(
                    raw_code_mode_host,
                    "runtime binding Codex code-mode host",
                )
                code_mode_host_digest = value["codex_code_mode_host_sha256"]
                if (
                    not isinstance(code_mode_host_digest, str)
                    or re.fullmatch(r"[0-9a-f]{64}", code_mode_host_digest) is None
                ):
                    raise CutoverError(
                        "runtime binding Codex code-mode host digest is invalid"
                    )
            else:
                code_mode_host = None
                code_mode_host_digest = None
            if manager == "direct" and (package_root is not None or package_version is not None):
                raise CutoverError("direct runtime binding cannot contain package metadata")
            if manager == "npm" and (package_root is None or package_version is None):
                raise CutoverError("npm runtime binding requires package metadata")

        return cls(
            binding_version=version,
            uid=uid,
            home=path_values["home"],
            repository=path_values["repository"],
            python=path_values["python"],
            codex=path_values["codex"],
            codex_home=codex_home,
            path=path_value,
            model=value["model"],
            skill_roots=skill_roots,
            codex_sha256=digest,
            codex_macho_arch=arch,
            codex_code_mode_host=code_mode_host,
            codex_code_mode_host_sha256=code_mode_host_digest,
            codex_managed_package_root=package_root,
            codex_managed_package_version=package_version,
            codex_managed_by=manager,
        )


def parse_runtime_binding(data: bytes) -> RuntimeBinding:
    try:
        lines = data.splitlines()
        if len(lines) < 2 or not lines[0].startswith(b"#!"):
            raise CutoverError("runtime binding header is missing")
        if not lines[1].startswith(RUNTIME_BINDING_PREFIX):
            raise CutoverError("runtime binding header is missing")
        payload = json.loads(lines[1][len(RUNTIME_BINDING_PREFIX) :].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CutoverError("runtime binding is malformed") from error
    return RuntimeBinding.from_mapping(payload)


def read_runtime_binding(path: Optional[Path] = None) -> RuntimeBinding:
    binding_path = RUNNER_INSTALLED if path is None else path
    parent = open_trusted_directory_chain(
        binding_path.parent,
        os.getuid(),
        "runtime binding parent",
    )
    try:
        descriptor = open_trusted_regular_at(
            parent,
            binding_path.name,
            os.getuid(),
            0o755,
            "runtime binding",
        )
        try:
            return parse_runtime_binding(read_open_descriptor(descriptor, "runtime binding"))
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def render_generated_runner(source: bytes, binding: RuntimeBinding) -> bytes:
    first_line, separator, body = source.partition(b"\n")
    if not separator or not first_line.startswith(b"#!"):
        raise CutoverError("runner source must contain a shebang")
    lines = body.splitlines(keepends=True)
    filtered = [
        line
        for line in lines
        if not line.startswith(RUNTIME_BINDING_PREFIX)
        and not line.startswith(b"RUNTIME_BINDING = ")
    ]
    insertion = next(
        (
            index
            for index, line in enumerate(filtered)
            if line.startswith(b'if __name__ == "__main__":')
        ),
        len(filtered),
    )
    literal = (
        b"RUNTIME_BINDING = "
        + repr(binding.as_dict()).encode("utf-8")
        + b"\n"
    )
    filtered.insert(insertion, literal)
    header = RUNTIME_BINDING_PREFIX + json.dumps(
        binding.as_dict(),
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return (
        b"#!"
        + str(binding.python).encode("utf-8")
        + b" -I\n"
        + header
        + b"\n"
        + b"".join(filtered)
    )

def home_from_environment(environment: Mapping[str, str]) -> Path:
    raw_home = environment.get("HOME")
    if not isinstance(raw_home, str):
        raise CutoverError("HOME must be set to one absolute path")
    try:
        home = _validate_absolute_path_text(raw_home, "HOME")
        uid_home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    except (KeyError, OSError, TypeError, ValueError) as error:
        raise CutoverError("cannot resolve the current user's HOME") from error
    if home != uid_home:
        raise CutoverError("HOME does not match the current user's directory")
    _validate_trusted_directory_path(home, os.getuid(), "HOME", require_owner=True)
    return home


def runner_source_from_script(script: Path) -> Path:
    try:
        source = script.resolve().with_name("run-codex-scheduled-task")
    except (OSError, RuntimeError, ValueError) as error:
        raise CutoverError(f"cannot resolve migration script path: {script}") from error
    if not source.is_absolute():
        raise CutoverError(f"migration runner source is not absolute: {source}")
    return source


@dataclasses.dataclass(frozen=True)
class NativeCodexIdentity:
    path: Path
    arch: str
    sha256: str


@dataclasses.dataclass(frozen=True)
class NativeCodexResolution:
    path: Path
    package_root: Optional[Path]
    managed_by: str
    package_version: Optional[str]
    arch: str
    sha256: str
    code_mode_host: Path
    code_mode_host_sha256: str

    @property
    def native_codex(self) -> Path:
        return self.path

    @property
    def native_path(self) -> Path:
        return self.path

    @property
    def codex_executable(self) -> Path:
        return self.path

    @property
    def codex_path(self) -> Path:
        return self.path

    @property
    def codex(self) -> Path:
        return self.path


def _host_native_arch() -> str:
    machine = platform.machine().lower()
    if machine in {"arm64", "aarch64"}:
        return "arm64"
    if machine in {"x86_64", "amd64"}:
        return "x86_64"
    raise CutoverError(f"unsupported host architecture: {machine}")


def _arch_from_cpu_type(cputype: int) -> Optional[str]:
    return {
        0x0100000C: "arm64",
        0x01000007: "x86_64",
    }.get(cputype & 0xFFFFFFFF)


def _parse_thin_macho(payload: bytes, expected_arch: str) -> str:
    magic = payload[:4]
    if magic in {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe"}:
        endian, header_size = (">", 28) if magic[0] == 0xFE else ("<", 28)
    elif magic in {b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe"}:
        endian, header_size = (">", 32) if magic[0] == 0xFE else ("<", 32)
    else:
        raise CutoverError("Codex file is not a Mach-O executable")
    if len(payload) < header_size:
        raise CutoverError("Codex Mach-O header is truncated")
    cputype = struct.unpack_from(endian + "I", payload, 4)[0]
    arch = _arch_from_cpu_type(cputype)
    if arch != expected_arch:
        raise CutoverError("Codex Mach-O architecture does not match the host")
    filetype = struct.unpack_from(endian + "I", payload, 12)[0]
    if filetype != 2:
        raise CutoverError("Codex Mach-O file type is not MH_EXECUTE")
    ncmds = struct.unpack_from(endian + "I", payload, 16)[0]
    sizeofcmds = struct.unpack_from(endian + "I", payload, 20)[0]
    command_end = header_size + sizeofcmds
    if command_end > len(payload) or sizeofcmds < ncmds * 8:
        raise CutoverError("Codex Mach-O load commands are truncated")
    cursor = header_size
    for _ in range(ncmds):
        if cursor + 8 > command_end:
            raise CutoverError("Codex Mach-O load command header is truncated")
        command_size = struct.unpack_from(endian + "I", payload, cursor + 4)[0]
        if command_size < 8 or cursor + command_size > command_end:
            raise CutoverError("Codex Mach-O load command bounds are invalid")
        cursor += command_size
    if cursor != command_end:
        raise CutoverError("Codex Mach-O load command size is invalid")
    return arch


def _parse_macho(payload: bytes, expected_arch: str) -> str:
    magic = payload[:4]
    if magic in {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}:
        endian = ">" if magic == b"\xca\xfe\xba\xbe" else "<"
        if len(payload) < 8:
            raise CutoverError("Codex fat Mach-O header is truncated")
        count = struct.unpack_from(endian + "I", payload, 4)[0]
        table_end = 8 + count * 20
        if count == 0 or table_end > len(payload):
            raise CutoverError("Codex fat Mach-O architecture table is invalid")
        for index in range(count):
            offset = 8 + index * 20
            cputype, _subtype, slice_offset, slice_size, _align = struct.unpack_from(
                endian + "IIIII",
                payload,
                offset,
            )
            slice_end = slice_offset + slice_size
            if slice_offset < table_end or slice_end > len(payload):
                raise CutoverError("Codex fat Mach-O slice bounds are invalid")
            if _arch_from_cpu_type(cputype) == expected_arch:
                return _parse_thin_macho(payload[slice_offset:slice_end], expected_arch)
        raise CutoverError("Codex fat Mach-O has no host architecture slice")
    return _parse_thin_macho(payload, expected_arch)


def _parse_elf(payload: bytes, expected_arch: str) -> str:
    if len(payload) < 16 or payload[:4] != _ELF_MAGIC:
        raise CutoverError("Codex file is not an ELF executable")
    elf_class = payload[4]
    endian_byte = payload[5]
    if elf_class not in {1, 2} or endian_byte not in {1, 2}:
        raise CutoverError("Codex ELF header is invalid")
    endian = "<" if endian_byte == 1 else ">"
    header_size = 52 if elf_class == 1 else 64
    if len(payload) < header_size:
        raise CutoverError("Codex ELF header is truncated")
    e_type, machine = struct.unpack_from(endian + "HH", payload, 16)
    machine_arch = {183: "arm64", 62: "x86_64"}.get(machine)
    if machine_arch != expected_arch:
        raise CutoverError("Codex ELF architecture does not match the host")
    if e_type not in {2, 3}:
        raise CutoverError("Codex ELF file type is not executable")
    if elf_class == 1:
        e_phoff, e_shoff = struct.unpack_from(endian + "II", payload, 28)
        e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum = struct.unpack_from(
            endian + "HHHHH",
            payload,
            40,
        )
    else:
        e_phoff, e_shoff = struct.unpack_from(endian + "QQ", payload, 32)
        e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum = struct.unpack_from(
            endian + "HHHHH",
            payload,
            52,
        )
    if e_ehsize < header_size or e_ehsize > len(payload):
        raise CutoverError("Codex ELF header size is invalid")
    if e_phnum and (e_phentsize == 0 or e_phoff + e_phentsize * e_phnum > len(payload)):
        raise CutoverError("Codex ELF program headers are truncated")
    if e_shnum and (e_shentsize == 0 or e_shoff + e_shentsize * e_shnum > len(payload)):
        raise CutoverError("Codex ELF section headers are truncated")
    return machine_arch


def _read_descriptor_bytes(descriptor: int, description: str) -> bytes:
    try:
        metadata = os.fstat(descriptor)
    except OSError as error:
        raise CutoverError(f"cannot inspect {description}") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) & 0o022
        or stat.S_IMODE(metadata.st_mode) & 0o111 == 0
    ):
        raise CutoverError(f"{description} ownership, mode, or type is invalid")
    chunks: List[bytes] = []
    offset = 0
    remaining = metadata.st_size
    while remaining:
        try:
            chunk = os.pread(descriptor, min(1024 * 1024, remaining), offset)
        except OSError as error:
            raise CutoverError(f"cannot read {description}") from error
        if not chunk:
            raise CutoverError(f"{description} changed while being read")
        chunks.append(chunk)
        offset += len(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def inspect_native_codex(path: Path, expected_arch: Optional[str] = None) -> NativeCodexIdentity:
    candidate = Path(path)
    if not candidate.is_absolute():
        raise CutoverError("Codex native path must be absolute")
    arch = _host_native_arch() if expected_arch is None else expected_arch
    if arch not in {"arm64", "x86_64"}:
        raise CutoverError("Codex native architecture is invalid")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_descriptor: Optional[int] = None
    descriptor: Optional[int] = None
    try:
        parent_descriptor = open_trusted_directory_chain(
            candidate.parent,
            os.getuid(),
            "Codex native parent",
        )
        descriptor = os.open(candidate.name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        raise CutoverError(f"cannot open Codex native executable: {candidate}") from error
    finally:
        if parent_descriptor is not None:
            os.close(parent_descriptor)
    try:
        payload = _read_descriptor_bytes(descriptor, "Codex native executable")
        if sys.platform.startswith("darwin"):
            if payload[:4] == _ELF_MAGIC:
                raise CutoverError("Darwin Codex executable is not Mach-O")
            parsed_arch = _parse_macho(payload, arch)
        elif sys.platform.startswith("linux"):
            if payload[:4] in _NATIVE_MACHO_MAGICS:
                raise CutoverError("Linux Codex executable is not ELF")
            parsed_arch = _parse_elf(payload, arch)
        elif payload[:4] in _NATIVE_MACHO_MAGICS:
            parsed_arch = _parse_macho(payload, arch)
        else:
            parsed_arch = _parse_elf(payload, arch)
        return NativeCodexIdentity(candidate, parsed_arch, hashlib.sha256(payload).hexdigest())
    finally:
        os.close(descriptor)


def _read_json_metadata(path: Path, description: str) -> Dict[str, Any]:
    metadata = _regular_file(path, description)
    if (
        metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) & 0o022
        or stat.S_IMODE(metadata.st_mode) & 0o111
    ):
        raise CutoverError(f"{description} ownership or mode is invalid")
    try:
        value = json.loads(read_regular(path, description).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CutoverError(f"{description} is malformed") from error
    if not isinstance(value, dict):
        raise CutoverError(f"{description} must contain an object")
    return value


def _platform_package_details() -> Tuple[str, str, str, str, str]:
    arch = _host_native_arch()
    if sys.platform == "darwin":
        if arch == "arm64":
            return (
                "codex-darwin-arm64",
                "aarch64-apple-darwin",
                "darwin",
                "arm64",
                "darwin-arm64",
            )
        if arch == "x86_64":
            return (
                "codex-darwin-x64",
                "x86_64-apple-darwin",
                "darwin",
                "x64",
                "darwin-x64",
            )
    elif sys.platform == "linux":
        if arch == "arm64":
            return (
                "codex-linux-arm64",
                "aarch64-unknown-linux-gnu",
                "linux",
                "arm64",
                "linux-arm64",
            )
        if arch == "x86_64":
            return (
                "codex-linux-x64",
                "x86_64-unknown-linux-gnu",
                "linux",
                "x64",
                "linux-x64",
            )
    raise CutoverError(f"unsupported host platform: {sys.platform} / {arch}")


def _validate_package_topology(
    package_root: Path,
) -> Tuple[Path, Path, str, NativeCodexIdentity, NativeCodexIdentity]:
    _validate_trusted_directory_path(
        package_root,
        os.getuid(),
        "Codex package root",
        require_owner=True,
    )
    package_json = package_root / "package.json"
    root_metadata = _read_json_metadata(package_json, "Codex package metadata")
    version = root_metadata.get("version")
    if (
        root_metadata.get("name") != "@openai/codex"
        or not isinstance(version, str)
        or not version
        or _CONTROL_CHARACTER_RE.search(version)
        or ":" in version
    ):
        raise CutoverError("Codex package metadata identity is invalid")
    bin_metadata = root_metadata.get("bin")
    if not isinstance(bin_metadata, dict) or bin_metadata.get("codex") != "bin/codex.js":
        raise CutoverError("Codex package bin metadata is invalid")
    platform_name, vendor_target, platform_os, platform_cpu, platform_suffix = (
        _platform_package_details()
    )
    platform_version = f"{version}-{platform_suffix}"
    platform_dependency_key = f"@openai/{platform_name}"
    platform_dependency = f"npm:@openai/codex@{platform_version}"
    optional = root_metadata.get("optionalDependencies")
    if (
        not isinstance(optional, dict)
        or optional.get(platform_dependency_key) != platform_dependency
    ):
        raise CutoverError("Codex package platform dependency is invalid")
    node_modules = package_root / "node_modules"
    scope = node_modules / "@openai"
    platform_package = scope / platform_name
    for directory, description in (
        (node_modules, "Codex package node_modules"),
        (scope, "Codex package scope"),
        (platform_package, "Codex platform package"),
        (package_root / "bin", "Codex package bin"),
    ):
        _validate_trusted_directory_path(directory, os.getuid(), description, require_owner=True)
    platform_metadata = _read_json_metadata(
        platform_package / "package.json",
        "Codex platform package metadata",
    )
    if (
        platform_metadata.get("name") != "@openai/codex"
        or platform_metadata.get("version") != platform_version
        or platform_metadata.get("os") != [platform_os]
        or platform_metadata.get("cpu") != [platform_cpu]
    ):
        raise CutoverError("Codex platform package metadata identity is invalid")
    entrypoint = package_root / "bin" / "codex.js"
    entrypoint_metadata = _regular_file(entrypoint, "Codex package entrypoint")
    if (
        entrypoint_metadata.st_uid != os.getuid()
        or stat.S_IMODE(entrypoint_metadata.st_mode) & 0o022
        or stat.S_IMODE(entrypoint_metadata.st_mode) & 0o111 == 0
    ):
        raise CutoverError("Codex package entrypoint ownership or mode is invalid")
    native = (
        platform_package
        / "vendor"
        / vendor_target
        / "bin"
        / "codex"
    )
    _validate_trusted_directory_path(native.parent, os.getuid(), "Codex native vendor path")
    identity = inspect_native_codex(native, _host_native_arch())
    code_mode_host = native.with_name("codex-code-mode-host")
    code_mode_identity = inspect_native_codex(code_mode_host, identity.arch)
    return native, code_mode_host, version, identity, code_mode_identity


def resolve_native_codex(environment: Mapping[str, str]) -> NativeCodexResolution:
    if not isinstance(environment, Mapping):
        raise CutoverError("Codex selection environment is invalid")
    supplied = [
        key
        for key in ("CODEX_NATIVE_PATH", "CODEX_PACKAGE_ROOT")
        if key in environment and environment[key] is not None
    ]
    if len(supplied) != 1:
        raise CutoverError(
            "provide exactly one of CODEX_NATIVE_PATH or CODEX_PACKAGE_ROOT"
        )
    selected = environment[supplied[0]]
    if not isinstance(selected, str):
        raise CutoverError("Codex selection value is invalid")
    target = _validate_absolute_path_text(selected, supplied[0])
    if supplied[0] == "CODEX_NATIVE_PATH":
        identity = inspect_native_codex(target, _host_native_arch())
        code_mode_identity = inspect_native_codex(
            identity.path.with_name("codex-code-mode-host"),
            identity.arch,
        )
        return NativeCodexResolution(
            path=identity.path,
            package_root=None,
            managed_by="direct",
            package_version=None,
            arch=identity.arch,
            sha256=identity.sha256,
            code_mode_host=code_mode_identity.path,
            code_mode_host_sha256=code_mode_identity.sha256,
        )
    native, code_mode_host, version, identity, code_mode_identity = (
        _validate_package_topology(target)
    )
    return NativeCodexResolution(
        path=native,
        package_root=target,
        managed_by="npm",
        package_version=version,
        arch=identity.arch,
        sha256=identity.sha256,
        code_mode_host=code_mode_host,
        code_mode_host_sha256=code_mode_identity.sha256,
    )


def discover_codex_executable(environment: Mapping[str, str]) -> Path:
    resolution = resolve_native_codex(environment)
    globals()["CODEX_MANAGED_PACKAGE_ROOT"] = resolution.package_root
    globals()["CODEX_MANAGED_PACKAGE_VERSION"] = resolution.package_version
    globals()["CODEX_MANAGED_BY"] = resolution.managed_by
    return resolution.path


def _validate_optional_codex_file(
    parent_descriptor: int,
    name: str,
    uid: int,
    description: str,
    *,
    auth: bool,
    required: bool = False,
) -> None:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except FileNotFoundError:
        if required:
            raise CutoverError(f"{description} is missing")
        return
    except OSError as error:
        raise CutoverError(f"{description} is not trustworthy") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != uid:
            raise CutoverError(f"{description} is not trustworthy")
        mode = stat.S_IMODE(metadata.st_mode)
        if mode & 0o022:
            raise CutoverError(f"{description} is not trustworthy")
        if auth and (mode & 0o077 or mode & 0o7000 or mode & 0o111):
            raise CutoverError(f"{description} is not trustworthy")
    except OSError as error:
        raise CutoverError(f"cannot inspect {description}") from error
    finally:
        os.close(descriptor)


def _validate_codex_regular_target(
    path: Path,
    uid: int,
    description: str,
    *,
    auth: bool,
) -> None:
    parent = open_trusted_directory_chain(
        path.parent,
        uid,
        f"{description} parent",
    )
    try:
        _validate_optional_codex_file(
            parent,
            path.name,
            uid,
            description,
            auth=auth,
            required=True,
        )
    finally:
        os.close(parent)


def _validate_codex_surface_entry(
    parent_descriptor: int,
    parent_path: Path,
    name: str,
    uid: int,
    description: str,
    *,
    directory: bool,
) -> Optional[Path]:
    if _CONTROL_CHARACTER_RE.search(name) or ":" in name:
        raise CutoverError(f"{description} has an unsafe name")
    try:
        metadata = os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        return None
    except OSError as error:
        raise CutoverError(f"{description} is not trustworthy") from error
    if stat.S_ISLNK(metadata.st_mode):
        if metadata.st_uid != uid:
            raise CutoverError(f"{description} symlink is not owned by the current user")
        try:
            target_text = os.readlink(name, dir_fd=parent_descriptor)
        except OSError as error:
            raise CutoverError(f"{description} symlink cannot be read") from error
        target = Path(target_text)
        if not target.is_absolute():
            target = parent_path / target
        try:
            canonical = target.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise CutoverError(f"{description} symlink target is missing") from error
        if canonical == parent_path / name:
            raise CutoverError(f"{description} symlink target is invalid")
    else:
        canonical = parent_path / name
        if metadata.st_uid != uid or stat.S_IMODE(metadata.st_mode) & 0o022:
            raise CutoverError(f"{description} is not trustworthy")
    if directory:
        if not canonical.is_dir():
            raise CutoverError(f"{description} is not a directory")
        _validate_trusted_directory_path(
            canonical,
            uid,
            description,
            require_owner=True,
        )
        target_descriptor = open_trusted_directory_chain(
            canonical,
            uid,
            description,
        )
        os.close(target_descriptor)
    else:
        if not canonical.is_file():
            raise CutoverError(f"{description} is not a regular file")
        _validate_codex_regular_target(
            canonical,
            uid,
            description,
            auth=False,
        )
    return canonical


def _validate_codex_surface_tree(
    path: Path,
    uid: int,
    description: str,
    visited: Optional[Set[Path]] = None,
) -> None:
    seen = set() if visited is None else visited
    canonical = path.resolve(strict=True)
    if canonical in seen:
        return
    seen.add(canonical)
    _validate_trusted_directory_path(
        canonical,
        uid,
        description,
        require_owner=True,
    )
    descriptor = open_trusted_directory_chain(canonical, uid, description)
    try:
        try:
            names = os.listdir(descriptor)
        except OSError as error:
            raise CutoverError(f"{description} entries cannot be listed") from error
        for name in names:
            if _CONTROL_CHARACTER_RE.search(name) or ":" in name:
                raise CutoverError(f"{description} has an unsafe entry name")
            entry_description = f"{description} entry {canonical / name}"
            try:
                metadata = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise CutoverError(f"{entry_description} is not trustworthy") from error
            if stat.S_ISLNK(metadata.st_mode):
                if metadata.st_uid != uid:
                    raise CutoverError(
                        f"{entry_description} symlink is not owned by the current user"
                    )
                try:
                    target_text = os.readlink(name, dir_fd=descriptor)
                except OSError as error:
                    raise CutoverError(
                        f"{entry_description} symlink cannot be read"
                    ) from error
                target = Path(target_text)
                if not target.is_absolute():
                    target = canonical / target
                try:
                    resolved = target.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise CutoverError(
                        f"{entry_description} symlink target is missing"
                    ) from error
                if resolved == canonical / name:
                    raise CutoverError(f"{entry_description} symlink target is invalid")
                if resolved.is_dir():
                    _validate_trusted_directory_path(
                        resolved,
                        uid,
                        entry_description,
                        require_owner=True,
                    )
                    target_descriptor = open_trusted_directory_chain(
                        resolved,
                        uid,
                        entry_description,
                    )
                    os.close(target_descriptor)
                    _validate_codex_surface_tree(
                        resolved,
                        uid,
                        entry_description,
                        seen,
                    )
                elif resolved.is_file():
                    _validate_codex_regular_target(
                        resolved,
                        uid,
                        entry_description,
                        auth=False,
                    )
                else:
                    raise CutoverError(f"{entry_description} has an invalid target")
            elif stat.S_ISDIR(metadata.st_mode):
                if metadata.st_uid != uid or stat.S_IMODE(metadata.st_mode) & 0o022:
                    raise CutoverError(f"{entry_description} is not trustworthy")
                child = canonical / name
                _validate_trusted_directory_path(
                    child,
                    uid,
                    entry_description,
                    require_owner=True,
                )
                child_descriptor = open_trusted_directory_chain(
                    child,
                    uid,
                    entry_description,
                )
                os.close(child_descriptor)
                _validate_codex_surface_tree(child, uid, entry_description, seen)
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_uid != uid or stat.S_IMODE(metadata.st_mode) & 0o022:
                    raise CutoverError(f"{entry_description} is not trustworthy")
                _validate_optional_codex_file(
                    descriptor,
                    name,
                    uid,
                    entry_description,
                    auth=False,
                    required=True,
                )
            else:
                raise CutoverError(f"{entry_description} has an invalid type")
    finally:
        os.close(descriptor)


def _validate_codex_home(codex_home: Path) -> None:
    uid = os.getuid()
    _validate_trusted_directory_path(
        codex_home,
        uid,
        "Codex home",
        require_owner=True,
    )
    descriptor = open_trusted_directory_chain(codex_home, uid, "Codex home")
    try:
        try:
            metadata = os.fstat(descriptor)
        except OSError as error:
            raise CutoverError("cannot inspect Codex home") from error
        if metadata.st_uid != uid:
            raise CutoverError("Codex home is not owned by the current user")
        _validate_optional_codex_file(
            descriptor,
            "config.toml",
            uid,
            "Codex home config.toml",
            auth=True,
        )
        _validate_optional_codex_file(
            descriptor,
            "auth.json",
            uid,
            "Codex home auth.json",
            auth=True,
        )
        for name in ("AGENTS.md", "RTK.md", "hooks.json"):
            _validate_codex_surface_entry(
                descriptor,
                codex_home,
                name,
                uid,
                f"Codex home {name}",
                directory=False,
            )
        for name in ("agents", "skills", "rules", "policy", "plugins"):
            surface = _validate_codex_surface_entry(
                descriptor,
                codex_home,
                name,
                uid,
                f"Codex home {name}",
                directory=True,
            )
            if surface is not None:
                _validate_codex_surface_tree(
                    surface,
                    uid,
                    f"Codex home {name}",
                )
    finally:
        os.close(descriptor)


def _validate_bound_path(path: str, uid: int) -> None:
    if not isinstance(path, str):
        raise CutoverError("runtime binding PATH is invalid")
    _validate_path_text(path, "runtime binding PATH", allow_colon=True)
    components = path.split(":")
    if not components or any(
        not component or not Path(component).is_absolute()
        for component in components
    ):
        raise CutoverError("runtime binding PATH must contain absolute directories")
    for component in components:
        descriptor = open_trusted_directory_chain(
            Path(component),
            uid,
            f"runtime binding PATH directory {component}",
        )
        os.close(descriptor)


def build_controlled_path(
    home: Path,
    codex: Path,
    optional_candidates: Optional[Sequence[Path]] = None,
) -> str:
    if not home.is_absolute() or not codex.is_absolute():
        raise CutoverError("HOME and Codex must use absolute paths")

    required_descriptor = open_trusted_directory_chain(
        codex.parent,
        os.getuid(),
        "required Codex parent",
    )
    os.close(required_descriptor)
    required = str(codex.parent)
    if optional_candidates is None:
        candidates: Sequence[Path] = (
            Path("/opt/homebrew/bin"),
            Path("/usr/local/bin"),
            Path("/usr/bin"),
            Path("/bin"),
            Path("/usr/sbin"),
            Path("/sbin"),
            home / ".local/bin",
        )
    else:
        candidates = optional_candidates

    components: List[str] = [required]
    seen: Set[str] = {required}
    for candidate in candidates:
        try:
            optional = candidate if isinstance(candidate, Path) else Path(candidate)
            descriptor = open_trusted_directory_chain(
                optional,
                os.getuid(),
                f"optional controlled PATH directory {optional}",
            )
            os.close(descriptor)
        except (CutoverError, OSError, RuntimeError, TypeError, ValueError):
            continue
        component = str(optional)
        if component not in seen:
            seen.add(component)
            components.append(component)
    return ":".join(components)


TICKET = "SKY-14155"
MARKER_PAYLOAD = b"SKY-14155 ticker Codex cutover committed v1\n"
HOME_DIRECTORY = Path("/home")
WORKING_DIRECTORY = HOME_DIRECTORY / "Development/Skyvern-cloud"
SESSIONS_ROOT = (
    HOME_DIRECTORY
    / "Library"
    / "Application Support"
    / "Claude"
    / "claude-code-sessions"
)
REGISTRY = Path("/registry/scheduled-tasks.json")
TRANSACTION_LOCK = SESSIONS_ROOT / f".ticker-codex-{TICKET}.lock"
SUCCESS_MARKER = Path(str(REGISTRY) + ".ticker-codex-SKY-14155.success")
RUNNER_SOURCE = runner_source_from_script(Path(__file__))
RUNNER_INSTALLED = HOME_DIRECTORY / ".local/bin/run-codex-scheduled-task"
CODEX_EXECUTABLE: Optional[Path] = None
CODEX_MANAGED_PACKAGE_ROOT: Optional[Path] = None
CODEX_MANAGED_PACKAGE_VERSION: Optional[str] = None
CODEX_MANAGED_BY: Optional[str] = None
TICKER_EXECUTABLE = Path("/Applications/Ticker.app/Contents/Helpers/ticker")
_LIVE_TICKER_EXECUTABLE = TICKER_EXECUTABLE
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
LAUNCHD_ENVIRONMENT: Optional[Mapping[str, str]] = None
ABSENT_SERVICE_PHRASES = ("could not find service", "no such process", "service not found")
HANDLED_SIGNALS = tuple(
    getattr(signal, name)
    for name in ("SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM")
    if hasattr(signal, name)
)


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
    recovery_policies_configured: bool = False
    committed: bool = False
    rolled_back: bool = False
    recovered: bool = False


_ADMINISTRATIVE_FALLBACK_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def _administrative_environment() -> Dict[str, str]:
    if LAUNCHD_ENVIRONMENT is None:
        home = str(HOME_DIRECTORY)
        path = _ADMINISTRATIVE_FALLBACK_PATH
        timezone = "America/New_York"
    else:
        bound = _validated_launchd_environment(LAUNCHD_ENVIRONMENT)
        home = bound["HOME"]
        path = bound["PATH"]
        timezone = bound["TZ"]
    return {
        "HOME": home,
        "PATH": path,
        "TZ": timezone,
        "LANG": "C",
        "LC_ALL": "C",
    }


def _materialize_validated_ticker(validated_fd: int) -> Path:
    """Copy a validated Ticker descriptor into a private executable file."""
    staging_parent = RUNNER_INSTALLED.parent
    uid = os.getuid()
    _validate_trusted_directory_path(
        staging_parent,
        uid,
        "Ticker staging parent",
        require_owner=True,
    )
    parent_descriptor = open_trusted_directory_chain(
        staging_parent,
        uid,
        "Ticker staging parent",
    )
    temporary_name: Optional[str] = None
    destination_descriptor: Optional[int] = None
    materialized_path: Optional[Path] = None
    completed = False
    try:
        _validate_open_directory(
            parent_descriptor,
            uid,
            "Ticker staging parent",
            require_owner=True,
        )
        source = _read_descriptor_bytes(validated_fd, "validated Ticker executable")
        for _attempt in range(20):
            candidate = f".ticker.{os.getpid()}.{secrets.token_hex(8)}"
            try:
                destination_descriptor = os.open(
                    candidate,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    0o700,
                    dir_fd=parent_descriptor,
                )
            except FileExistsError:
                continue
            except OSError as error:
                raise CutoverError("cannot create Ticker staging file") from error
            temporary_name = candidate
            break
        if temporary_name is None or destination_descriptor is None:
            raise CutoverError("cannot allocate a unique Ticker staging file")

        materialized_path = staging_parent / temporary_name
        try:
            try:
                os.fchmod(destination_descriptor, 0o700)
            except OSError as error:
                raise CutoverError("cannot set Ticker staging file mode") from error
            source_view = memoryview(source)
            offset = 0
            while offset < len(source_view):
                try:
                    written = os.write(destination_descriptor, source_view[offset:])
                except InterruptedError:
                    continue
                except OSError as error:
                    raise CutoverError("cannot copy validated Ticker executable") from error
                if written <= 0:
                    raise CutoverError("cannot copy validated Ticker executable")
                offset += written
            try:
                os.fsync(destination_descriptor)
            except OSError as error:
                raise CutoverError("cannot sync Ticker staging file") from error
        finally:
            try:
                os.close(destination_descriptor)
            except OSError:
                pass
            destination_descriptor = None

        readback_descriptor = open_trusted_regular_at(
            parent_descriptor,
            temporary_name,
            uid,
            0o700,
            "materialized Ticker executable",
        )
        try:
            readback = read_open_descriptor(
                readback_descriptor,
                "materialized Ticker executable",
            )
        finally:
            try:
                os.close(readback_descriptor)
            except OSError:
                pass
        if readback != source:
            raise CutoverError("materialized Ticker executable read-back differs")
        completed = True
        assert materialized_path is not None
        return materialized_path
    except BaseException as primary_error:
        if destination_descriptor is not None:
            try:
                os.close(destination_descriptor)
            except OSError:
                pass
            destination_descriptor = None
        cleanup_error: Optional[OSError] = None
        if not completed and temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
            except OSError as error:
                cleanup_error = error
        if cleanup_error is not None:
            raise CutoverError(
                "Ticker materialization failed: "
                f"{primary_error}; cleanup failed: {cleanup_error}"
            ) from primary_error
        raise
    finally:
        if destination_descriptor is not None:
            try:
                os.close(destination_descriptor)
            except OSError:
                pass
        try:
            os.close(parent_descriptor)
        except OSError:
            pass


class CommandRunner:
    def run(self, executable: Path, arguments: Sequence[str]) -> CommandResult:
        validated_fd: Optional[int] = None
        materialized_path: Optional[Path] = None

        def cleanup_materialized_copy() -> Optional[OSError]:
            if materialized_path is None:
                return None
            try:
                materialized_path.unlink(missing_ok=True)
            except OSError as error:
                return error
            return None

        try:
            environment = _administrative_environment()
            if executable == TICKER_EXECUTABLE or executable == _LIVE_TICKER_EXECUTABLE:
                validated_fd = validate_ticker_executable(executable)
            run_kwargs: Dict[str, Any] = {
                "stdin": subprocess.DEVNULL,
                "stdout": subprocess.PIPE,
                "stderr": subprocess.PIPE,
                "text": True,
                "check": False,
                "env": environment,
            }
            argv0 = str(executable)
            if executable == _LIVE_TICKER_EXECUTABLE and validated_fd is not None:
                materialized_path = _materialize_validated_ticker(validated_fd)
                run_kwargs["executable"] = str(materialized_path)
            completed = subprocess.run(
                [argv0, *arguments],
                **run_kwargs,
            )
        except OSError as primary_error:
            cleanup_error = cleanup_materialized_copy()
            if cleanup_error is not None:
                raise CutoverError(
                    f"cannot execute {executable}: {primary_error}; "
                    f"cleanup failed: {cleanup_error}"
                ) from primary_error
            raise CutoverError(
                f"cannot execute {executable}: {primary_error}"
            ) from primary_error
        except BaseException as primary_error:
            cleanup_error = cleanup_materialized_copy()
            if cleanup_error is not None:
                raise CutoverError(
                    f"{primary_error}; cleanup failed: {cleanup_error}"
                ) from primary_error
            raise
        else:
            cleanup_error = cleanup_materialized_copy()
            if cleanup_error is not None:
                raise CutoverError(f"cleanup failed: {cleanup_error}") from cleanup_error
            return CommandResult(completed.returncode, completed.stdout, completed.stderr)
        finally:
            if validated_fd is not None:
                try:
                    os.close(validated_fd)
                except OSError:
                    pass


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


def _personal_root(name: str, home: Optional[Path] = None) -> SkillRoot:
    home_directory = HOME_DIRECTORY if home is None else home
    return SkillRoot(
        name=name,
        installed_root=home_directory / ".codex/skills" / name,
        canonical_root=home_directory / "Development/obsidian/agents/skills" / name,
        kind=RootKind.PERSONAL_LINK,
    )


def _direct_root(name: str, working_directory: Optional[Path] = None) -> SkillRoot:
    directory = WORKING_DIRECTORY if working_directory is None else working_directory
    root = directory / ".agents/skills" / name
    return SkillRoot(name=name, installed_root=root, canonical_root=root, kind=RootKind.DIRECT_PROJECT)


def _routine(
    task_id: str,
    legacy_cron: str,
    ticker_suffix: str,
    calendar: Any,
    schedule_points: Tuple[Tuple[int, int, Optional[int]], ...],
    root: SkillRoot,
    home: Optional[Path] = None,
) -> Routine:
    home_directory = HOME_DIRECTORY if home is None else home
    label = "com.suchintan.codex-scheduled." + task_id
    return Routine(
        task_id=task_id,
        legacy_cron=legacy_cron,
        claude_prompt=home_directory / ".claude/scheduled-tasks" / task_id / "SKILL.md",
        plist=home_directory / "Library/LaunchAgents" / f"{label}.plist",
        label=label,
        ticker_id=f"launchd:{label}#{ticker_suffix}",
        calendar=calendar,
        schedule_points=schedule_points,
        root=root,
    )


def _build_routines(
    home: Path,
    working_directory: Path,
) -> Tuple[Tuple[SkillRoot, ...], Tuple[Routine, ...]]:
    roots = (
        _personal_root("daily-summary", home),
        _personal_root("vitals-run-all", home),
        _personal_root("linkedin-post-ideas", home),
        _direct_root("overdue-customer-issues-slack", working_directory),
        _personal_root("team-progress-digest", home),
    )
    daily_summary, vitals, linkedin, overdue, team_digest = roots
    routines = (
        _routine(
            "daily-summary",
            "55 23 * * *",
            "c8fe781eb340",
            {"Hour": 23, "Minute": 55},
            ((23, 55, None),),
            daily_summary,
            home,
        ),
        _routine(
            "daily-vitals-morning",
            "30 8 * * 1-5",
            "41fcaa4cf24b",
            _weekdays(8, 30),
            _weekday_points(8, 30),
            vitals,
            home,
        ),
        _routine(
            "linkedin-post-ideas",
            "0 8 * * *",
            "6c4e3715f6d9",
            {"Hour": 8, "Minute": 0},
            ((8, 0, None),),
            linkedin,
            home,
        ),
        _routine(
            "linkedin-post-ideas-sweeper",
            "0 12 * * *",
            "63d9c7b96397",
            {"Hour": 12, "Minute": 0},
            ((12, 0, None),),
            linkedin,
            home,
        ),
        _routine(
            "overdue-customer-issues-slack",
            "40 9 * * 1-5",
            "48073be11319",
            _weekdays(9, 40),
            _weekday_points(9, 40),
            overdue,
            home,
        ),
        _routine(
            "team-progress-digest",
            "0 9 * * *",
            "b5d2b5a99273",
            {"Hour": 9, "Minute": 0},
            ((9, 0, None),),
            team_digest,
            home,
        ),
    )
    return roots, routines


_ROOTS, ROUTINES = _build_routines(HOME_DIRECTORY, WORKING_DIRECTORY)
(
    DAILY_SUMMARY_ROOT,
    VITALS_ROOT,
    LINKEDIN_ROOT,
    OVERDUE_ROOT,
    TEAM_DIGEST_ROOT,
) = _ROOTS


def _regular_file(path: Path, description: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CutoverError(f"{description} is missing: {path}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise CutoverError(f"{description} is not a regular file: {path}")
    return metadata


def read_regular(path: Path, description: str) -> bytes:
    parent = open_trusted_directory_chain(path.parent, os.getuid(), f"{description} parent")
    try:
        descriptor = open_trusted_regular_at(
            parent,
            path.name,
            os.getuid(),
            None,
            description,
        )
        try:
            return read_open_descriptor(descriptor, description)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


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

def atomic_write_at(
    parent_descriptor: object,
    name: str,
    data: bytes,
    mode: int,
    *,
    description: str = "published file",
) -> bytes:
    """Publish bytes relative to one validated parent descriptor and read them back."""
    parent_fd = _descriptor_number(parent_descriptor)
    _validate_path_text(name, f"{description} name")
    if "/" in name or name in {".", ".."}:
        raise CutoverError(f"{description} name is not a single path component")
    temporary_name: Optional[str] = None
    descriptor: Optional[int] = None
    for _attempt in range(20):
        candidate = f".{name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
        try:
            descriptor = os.open(
                candidate,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                mode,
                dir_fd=parent_fd,
            )
            temporary_name = candidate
            break
        except FileExistsError:
            continue
        except OSError as error:
            raise CutoverError(f"cannot create temporary {description}") from error
    if descriptor is None or temporary_name is None:
        raise CutoverError(f"cannot allocate a temporary {description}")
    try:
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise CutoverError(f"cannot write temporary {description}")
            offset += written
        os.fsync(descriptor)
    except OSError as error:
        raise CutoverError(f"cannot persist temporary {description}") from error
    finally:
        os.close(descriptor)
        descriptor = None
    try:
        os.rename(
            temporary_name,
            name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        os.fsync(parent_fd)
        published = open_trusted_regular_at(
            parent_fd,
            name,
            os.getuid(),
            mode,
            description,
        )
        try:
            readback = read_open_descriptor(published, description)
        finally:
            os.close(published)
        if readback != data:
            raise CutoverError(f"{description} read-back differs")
        return readback
    except OSError as error:
        raise CutoverError(f"cannot publish {description}") from error
    finally:
        try:
            os.unlink(temporary_name, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
        except OSError as error:
            raise CutoverError(f"cannot remove temporary {description}") from error


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


def discover_claude_registry(
    home: Path,
    routines: Sequence[Routine],
) -> Path:
    sessions_root = (
        home
        / "Library"
        / "Application Support"
        / "Claude"
        / "claude-code-sessions"
    )
    selected_ids = {routine.task_id for routine in routines}
    matches: List[Path] = []
    for candidate in sessions_root.glob("*/*/scheduled-tasks.json"):
        data = read_regular(candidate, "Claude scheduled-task registry candidate")
        registry = _decode_registry(data)
        present_ids = {
            row.get("id")
            for row in registry["scheduledTasks"]
            if isinstance(row, dict) and isinstance(row.get("id"), str)
        }
        if selected_ids.isdisjoint(present_ids):
            continue
        selected_registry_rows(data, routines)
        matches.append(candidate)
    if not matches:
        raise CutoverError(
            f"no Claude registry contains the complete selected task set under {sessions_root}"
        )
    if len(matches) != 1:
        raise CutoverError("multiple Claude registries contain the complete selected task set")
    return matches[0]


def configure_static_runtime() -> None:
    home = home_from_environment(os.environ)
    working_directory = home / "Development/Skyvern-cloud"
    sessions_root = (
        home
        / "Library"
        / "Application Support"
        / "Claude"
        / "claude-code-sessions"
    )
    runner_source = runner_source_from_script(Path(__file__))
    runner_installed = home / ".local/bin/run-codex-scheduled-task"
    transaction_lock = sessions_root / f".ticker-codex-{TICKET}.lock"
    roots, routines = _build_routines(home, working_directory)
    daily_summary, vitals, linkedin, overdue, team_digest = roots
    globals().update(
        {
            "HOME_DIRECTORY": home,
            "WORKING_DIRECTORY": working_directory,
            "SESSIONS_ROOT": sessions_root,
            "TRANSACTION_LOCK": transaction_lock,
            "RUNNER_SOURCE": runner_source,
            "RUNNER_INSTALLED": runner_installed,
            "CODEX_EXECUTABLE": None,
            "CODEX_MANAGED_PACKAGE_ROOT": None,
            "CODEX_MANAGED_PACKAGE_VERSION": None,
            "CODEX_MANAGED_BY": None,
            "LAUNCHD_ENVIRONMENT": None,
            "_ROOTS": roots,
            "DAILY_SUMMARY_ROOT": daily_summary,
            "VITALS_ROOT": vitals,
            "LINKEDIN_ROOT": linkedin,
            "OVERDUE_ROOT": overdue,
            "TEAM_DIGEST_ROOT": team_digest,
            "ROUTINES": routines,
        }
    )


def bind_locked_registry_runtime() -> None:
    registry = discover_claude_registry(HOME_DIRECTORY, ROUTINES)
    launchd_environment = discover_stored_launchd_environment(ROUTINES)
    success_marker = Path(str(registry) + f".ticker-codex-{TICKET}.success")
    globals().update(
        {
            "REGISTRY": registry,
            "SUCCESS_MARKER": success_marker,
            "LAUNCHD_ENVIRONMENT": launchd_environment,
        }
    )


def prepare_forward_launchd_environment() -> None:
    resolution = resolve_native_codex(os.environ)
    _validate_codex_home(HOME_DIRECTORY / ".codex")
    launchd_environment = {
        "HOME": str(HOME_DIRECTORY),
        "PATH": build_controlled_path(HOME_DIRECTORY, resolution.path),
        "TZ": "America/New_York",
        "CODEX_HOME": str(HOME_DIRECTORY / ".codex"),
    }
    globals().update(
        {
            "CODEX_EXECUTABLE": resolution.path,
            "CODEX_MANAGED_PACKAGE_ROOT": resolution.package_root,
            "CODEX_MANAGED_PACKAGE_VERSION": resolution.package_version,
            "CODEX_MANAGED_BY": resolution.managed_by,
            "LAUNCHD_ENVIRONMENT": launchd_environment,
        }
    )


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


def _required_launchd_environment() -> Mapping[str, str]:
    if LAUNCHD_ENVIRONMENT is None:
        raise CutoverError("no launchd environment is bound to this migration state")
    return _validated_launchd_environment(LAUNCHD_ENVIRONMENT)


def _validated_launchd_environment(value: Any) -> Dict[str, str]:
    legacy_keys = {"HOME", "PATH", "TZ"}
    current_keys = {"HOME", "PATH", "TZ", "CODEX_HOME"}
    if not isinstance(value, dict) or set(value) not in (legacy_keys, current_keys):
        raise CutoverError("launchd environment keys changed")
    if any(not isinstance(value[key], str) for key in ("HOME", "PATH", "TZ")):
        raise CutoverError("launchd environment values must be strings")
    if value["HOME"] != str(HOME_DIRECTORY):
        raise CutoverError("launchd HOME changed")
    if value["TZ"] != "America/New_York":
        raise CutoverError("launchd timezone changed")
    path_components = value["PATH"].split(":")
    if not path_components or any(
        not component or "\0" in component or not Path(component).is_absolute()
        for component in path_components
    ):
        raise CutoverError("launchd PATH must contain only nonempty absolute paths")
    raw_codex_home = (
        str(HOME_DIRECTORY / ".codex")
        if set(value) == legacy_keys
        else value["CODEX_HOME"]
    )
    if not isinstance(raw_codex_home, str):
        raise CutoverError("launchd CODEX_HOME must be a string")
    codex_home = _validate_absolute_path_text(raw_codex_home, "launchd CODEX_HOME")
    return {
        "HOME": value["HOME"],
        "PATH": value["PATH"],
        "TZ": value["TZ"],
        "CODEX_HOME": str(codex_home),
    }


def _plist_state_and_environment(
    routine: Routine,
) -> Tuple[PlistState, Dict[str, str]]:
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
    if value["Label"] != routine.label:
        raise CutoverError(f"launchd command changed for {routine.task_id}")
    arguments = value["ProgramArguments"]
    if arguments == routine.wrapper_arguments:
        state = PlistState.WRAPPED
    elif arguments == routine.original_arguments:
        state = PlistState.ORIGINAL
    else:
        raise CutoverError(f"launchd wrapper state is unknown for {routine.task_id}")
    if value["WorkingDirectory"] != str(WORKING_DIRECTORY):
        raise CutoverError(f"launchd working directory changed for {routine.task_id}")
    environment = _validated_launchd_environment(value["EnvironmentVariables"])
    if value["StartCalendarInterval"] != routine.calendar:
        raise CutoverError(f"launchd schedule changed for {routine.task_id}")
    if not cron_matches_calendar(routine.legacy_cron, routine.calendar):
        raise CutoverError(f"legacy cron does not match launchd schedule for {routine.task_id}")
    return state, environment

def discover_stored_launchd_environment(
    routines: Sequence[Routine],
) -> Optional[Mapping[str, str]]:
    stored_environment: Optional[Dict[str, str]] = None
    for routine in routines:
        if not os.path.lexists(routine.plist):
            continue
        _state, environment = _plist_state_and_environment(routine)
        if stored_environment is None:
            stored_environment = environment
        elif environment != stored_environment:
            raise CutoverError("replacement plists contain inconsistent launchd environments")
    return stored_environment


def prepare_codex_compensation() -> None:
    binding = read_runtime_binding()
    if binding.uid != os.getuid():
        raise CutoverError("runtime binding uid does not match the current user")
    if binding.home != HOME_DIRECTORY:
        raise CutoverError("runtime binding HOME does not match the migration")
    if binding.repository != WORKING_DIRECTORY:
        raise CutoverError("runtime binding repository does not match the migration")
    _validate_codex_home(binding.codex_home)
    _validate_bound_path(binding.path, binding.uid)
    validate_skill_roots(tuple(routine.root for routine in ROUTINES))
    if binding.binding_version >= 2:
        expected_skill_roots = {
            routine.task_id: routine.root.canonical_root for routine in ROUTINES
        }
        if binding.skill_roots != expected_skill_roots:
            raise CutoverError("runtime binding skill roots changed")
    try:
        if binding.python.resolve(strict=True) != Path(sys.executable).resolve(strict=True):
            raise CutoverError("runtime binding Python interpreter changed")
    except (OSError, RuntimeError) as error:
        raise CutoverError("runtime binding Python interpreter is invalid") from error

    binding_environment = {
        "HOME": str(binding.home),
        "PATH": binding.path,
        "CODEX_HOME": str(binding.codex_home),
        "TZ": "America/New_York",
    }
    if LAUNCHD_ENVIRONMENT is None:
        stored_environment = discover_stored_launchd_environment(ROUTINES)
        if stored_environment is not None:
            stored = _validated_launchd_environment(stored_environment)
            if stored != binding_environment:
                raise CutoverError("stored launchd controls do not match runtime binding")
        environment = binding_environment
        globals()["LAUNCHD_ENVIRONMENT"] = environment
    else:
        environment = _validated_launchd_environment(LAUNCHD_ENVIRONMENT)
        if environment != binding_environment:
            raise CutoverError("stored launchd controls do not match runtime binding")
    identity = inspect_native_codex(binding.codex, binding.codex_macho_arch)
    if binding.binding_version >= 2:
        if identity.sha256 != binding.codex_sha256 or identity.arch != binding.codex_macho_arch:
            raise CutoverError("bound Codex native identity changed")
        code_mode_identity: Optional[NativeCodexIdentity] = None
        if binding.binding_version >= RUNTIME_BINDING_VERSION:
            if binding.codex_code_mode_host is None:
                raise CutoverError("bound Codex code-mode host is missing")
            code_mode_identity = inspect_native_codex(
                binding.codex_code_mode_host,
                binding.codex_macho_arch,
            )
            if code_mode_identity.sha256 != binding.codex_code_mode_host_sha256:
                raise CutoverError("bound Codex code-mode host identity changed")
        if binding.codex_managed_by == "npm":
            if binding.codex_managed_package_root is None:
                raise CutoverError("npm Codex binding has no package root")
            native, code_mode_host, version, package_identity, package_host_identity = (
                _validate_package_topology(binding.codex_managed_package_root)
            )
            if (
                native != binding.codex
                or version != binding.codex_managed_package_version
                or package_identity.sha256 != identity.sha256
            ):
                raise CutoverError("bound Codex package provenance changed")
            if binding.binding_version >= RUNTIME_BINDING_VERSION and (
                code_mode_identity is None
                or code_mode_host != binding.codex_code_mode_host
                or package_host_identity.sha256 != code_mode_identity.sha256
            ):
                raise CutoverError("bound Codex package provenance changed")
        elif binding.codex_managed_package_root is not None:
            raise CutoverError("direct Codex binding contains package provenance")
    elif binding.codex_managed_by == "npm":
        if binding.codex_managed_package_root is None:
            raise CutoverError("legacy npm binding has no package root")
        native, _host, _version, _package_identity, _host_identity = (
            _validate_package_topology(binding.codex_managed_package_root)
        )
        if native != binding.codex:
            raise CutoverError("legacy Codex package provenance changed")
    globals().update(
        {
            "CODEX_EXECUTABLE": binding.codex,
            "CODEX_MANAGED_PACKAGE_ROOT": (
                binding.codex_managed_package_root
                if binding.codex_managed_by == "npm"
                else None
            ),
            "CODEX_MANAGED_PACKAGE_VERSION": (
                binding.codex_managed_package_version
                if binding.codex_managed_by == "npm"
                else None
            ),
            "CODEX_MANAGED_BY": binding.codex_managed_by,
        }
    )


def replacement_plist_payload(routine: Routine) -> Dict[str, Any]:
    return {
        "Label": routine.label,
        "ProgramArguments": routine.original_arguments,
        "WorkingDirectory": str(WORKING_DIRECTORY),
        "EnvironmentVariables": dict(_required_launchd_environment()),
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
    state, environment = _plist_state_and_environment(routine)
    expected_state = PlistState.WRAPPED if wrapped else PlistState.ORIGINAL
    if state is not expected_state:
        raise CutoverError(f"launchd command changed for {routine.task_id}")
    if environment != dict(_required_launchd_environment()):
        raise CutoverError(f"launchd environment changed for {routine.task_id}")


def plist_wrapper_state(routine: Routine) -> bool:
    state, environment = _plist_state_and_environment(routine)
    if environment != dict(_required_launchd_environment()):
        raise CutoverError(f"launchd environment changed for {routine.task_id}")
    return state is PlistState.WRAPPED


def validate_ticker_ids(routines: Sequence[Routine]) -> None:
    ids = [routine.ticker_id for routine in routines]
    labels = [routine.label for routine in routines]
    if len(set(ids)) != len(ids) or len(set(labels)) != len(labels):
        raise CutoverError("routine Ticker ids or labels are not unique")
    for routine in routines:
        if not routine.ticker_id.startswith(f"launchd:{routine.label}#"):
            raise CutoverError(f"Ticker id does not bind label for {routine.task_id}")


def _recovery_policy_command(routine: Routine) -> List[str]:
    if routine.task_id == "daily-summary":
        return [
            "recovery-policy",
            routine.ticker_id,
            "retry-idempotent",
            "--task-id",
            "daily-summary",
            "--time-zone",
            "America/New_York",
        ]
    return ["recovery-policy", routine.ticker_id, "alert-only"]


def _alert_only_policy_command(routine: Routine) -> List[str]:
    return ["recovery-policy", routine.ticker_id, "alert-only"]


def fail_closed_recovery_policies(
    routines: Sequence[Routine],
    command_runner: CommandRunner,
) -> None:
    errors: List[str] = []
    for routine in routines:
        try:
            result = command_runner.run(
                TICKER_EXECUTABLE,
                _alert_only_policy_command(routine),
            )
        except BaseException as error:
            errors.append(f"{routine.task_id}: {error}")
            continue
        if result.status != 0:
            errors.append(f"{routine.task_id}: status {result.status}")
    if errors:
        raise RollbackError(
            "recovery policy fail-closed cleanup failed: " + "; ".join(errors)
        )


def configure_recovery_policies(
    routines: Sequence[Routine],
    command_runner: CommandRunner,
) -> None:
    selected = tuple(routines)
    ordered = tuple(
        routine for routine in selected if routine.task_id != "daily-summary"
    ) + tuple(
        routine for routine in selected if routine.task_id == "daily-summary"
    )
    try:
        for routine in ordered:
            result = command_runner.run(
                TICKER_EXECUTABLE,
                _recovery_policy_command(routine),
            )
            if result.status != 0:
                raise CutoverError(
                    f"Ticker recovery policy failed for {routine.task_id}"
                )
    except BaseException as error:
        try:
            fail_closed_recovery_policies(selected, command_runner)
        except BaseException as cleanup_error:
            raise RollbackError(
                f"recovery policy configuration failed ({error}); "
                f"fail-closed cleanup also failed ({cleanup_error})"
            ) from cleanup_error
        if isinstance(error, CutoverSignal):
            raise
        raise CutoverError(f"recovery policy configuration failed: {error}") from error

def _validate_skill_file(path: Path, description: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CutoverError(f"{description} is not readable") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise CutoverError(f"{description} must not be a symlink")
    try:
        canonical = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise CutoverError(f"{description} is not readable") from error
    if not canonical.is_absolute():
        raise CutoverError(f"{description} is not absolute")
    parent = open_trusted_directory_chain(
        canonical.parent,
        os.getuid(),
        f"{description} parent",
    )
    try:
        descriptor = open_trusted_regular_at(
            parent,
            canonical.name,
            os.getuid(),
            None,
            description,
        )
        os.close(descriptor)
    finally:
        os.close(parent)


def validate_skill_roots(roots: Sequence[SkillRoot]) -> None:
    seen: Set[str] = set()
    for root in roots:
        if root.name in seen:
            continue
        seen.add(root.name)
        try:
            canonical = root.canonical_root.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise CutoverError(f"canonical root is missing for {root.name}") from error
        if canonical != root.canonical_root or not canonical.is_dir():
            raise CutoverError(f"canonical root is not a direct directory for {root.name}")
        _validate_trusted_directory_path(
            canonical,
            os.getuid(),
            f"canonical root {root.name}",
            require_owner=True,
        )
        canonical_descriptor = open_trusted_directory_chain(
            canonical,
            os.getuid(),
            f"canonical root {root.name}",
        )
        os.close(canonical_descriptor)
        installed_parent_descriptor = open_trusted_directory_chain(
            root.installed_root.parent,
            os.getuid(),
            f"installed root parent {root.name}",
        )
        try:
            if root.kind is RootKind.PERSONAL_LINK:
                try:
                    installed_metadata = os.stat(
                        root.installed_root.name,
                        dir_fd=installed_parent_descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    raise CutoverError(f"personal root is missing for {root.name}") from error
                if (
                    not stat.S_ISLNK(installed_metadata.st_mode)
                    or installed_metadata.st_uid != os.getuid()
                ):
                    raise CutoverError(
                        f"personal root symlink ownership is invalid for {root.name}"
                    )
                try:
                    target_text = os.readlink(
                        root.installed_root.name,
                        dir_fd=installed_parent_descriptor,
                    )
                except OSError as error:
                    raise CutoverError(
                        f"personal root symlink cannot be read for {root.name}"
                    ) from error
                target = Path(target_text)
                if not target.is_absolute():
                    target = root.installed_root.parent / target
                try:
                    resolved_target = target.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise CutoverError(
                        f"personal root target is missing for {root.name}"
                    ) from error
                if resolved_target != canonical:
                    raise CutoverError(
                        f"personal root does not use the exact canonical target for {root.name}"
                    )
            elif root.kind is RootKind.DIRECT_PROJECT:
                if root.installed_root != root.canonical_root or root.installed_root.is_symlink():
                    raise CutoverError(f"direct project root is not direct for {root.name}")
            else:
                raise CutoverError(f"unknown root kind for {root.name}")
        finally:
            os.close(installed_parent_descriptor)
        _validate_skill_file(
            root.installed_skill,
            f"live root SKILL.md for {root.name}",
        )
        _validate_skill_file(
            root.canonical_skill,
            f"canonical root SKILL.md for {root.name}",
        )


def validate_executable(path: Path, description: str) -> None:
    if not path.is_absolute():
        raise CutoverError(f"{description} path is not absolute: {path}")
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
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise CutoverError(f"{description} target is group or other writable: {canonical}")
    if not os.access(canonical, os.R_OK | os.X_OK):
        raise CutoverError(
            f"{description} target is not readable and executable: {canonical}"
        )
    _validate_trusted_directory_path(canonical.parent, os.getuid(), f"{description} parent")


def validate_ticker_executable(path: Path) -> Optional[int]:
    if path != _LIVE_TICKER_EXECUTABLE:
        validate_executable(path, "Ticker executable")
        return None

    uid = os.getuid()
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    leaf_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptors: List[int] = []
    validated_leaf: Optional[int] = None

    def descriptor_metadata(descriptor: int, description: str) -> os.stat_result:
        try:
            return os.fstat(descriptor)
        except OSError as error:
            raise CutoverError(f"cannot inspect {description}") from error

    def require_directory(
        metadata: os.stat_result,
        description: str,
        *,
        owner: int,
        group: int,
        mode: int,
    ) -> None:
        if not stat.S_ISDIR(metadata.st_mode):
            raise CutoverError(f"{description} is not a directory")
        if metadata.st_uid != owner:
            raise CutoverError(f"{description} has an unexpected owner")
        if metadata.st_gid != group:
            raise CutoverError(f"{description} has an unexpected group")
        if stat.S_IMODE(metadata.st_mode) != mode:
            raise CutoverError(f"{description} mode is not {mode:04o}")

    def open_directory(parent: Optional[int], component: object, description: str) -> int:
        try:
            if parent is None:
                descriptor = os.open(component, directory_flags)
            else:
                descriptor = os.open(component, directory_flags, dir_fd=parent)
        except OSError as error:
            raise CutoverError(f"cannot open {description}") from error
        descriptors.append(descriptor)
        return descriptor

    try:
        root = open_directory(None, path.anchor or os.sep, "Ticker filesystem root")
        root_metadata = descriptor_metadata(root, "Ticker filesystem root")
        require_directory(
            root_metadata,
            "Ticker filesystem root",
            owner=0,
            group=0,
            mode=0o755,
        )

        applications_path = Path(path.anchor or os.sep) / "Applications"
        applications = open_directory(root, "Applications", "Ticker /Applications")
        applications_metadata = descriptor_metadata(applications, "Ticker /Applications")
        admin_gid = applications_metadata.st_gid
        require_directory(
            applications_metadata,
            "Ticker /Applications",
            owner=0,
            group=admin_gid,
            mode=0o775,
        )
        try:
            group_name = grp.getgrgid(admin_gid).gr_name
        except (KeyError, OSError) as error:
            raise CutoverError("Ticker /Applications group cannot be resolved") from error
        if group_name != "admin":
            raise CutoverError("Ticker /Applications is not in the admin group")

        app_path = applications_path / "Ticker.app"
        try:
            app_lstat = os.lstat(app_path)
        except OSError as error:
            raise CutoverError("Ticker app is missing") from error
        require_directory(
            app_lstat,
            "Ticker app",
            owner=uid,
            group=admin_gid,
            mode=0o700,
        )

        app = open_directory(applications, "Ticker.app", "Ticker app")
        app_metadata = descriptor_metadata(app, "Ticker app")
        require_directory(
            app_metadata,
            "Ticker app",
            owner=uid,
            group=admin_gid,
            mode=0o700,
        )
        if (app_lstat.st_dev, app_lstat.st_ino) != (
            app_metadata.st_dev,
            app_metadata.st_ino,
        ):
            raise CutoverError("Ticker app changed while being opened")
        try:
            app_final_lstat = os.lstat(app_path)
        except OSError as error:
            raise CutoverError("Ticker app is missing") from error
        require_directory(
            app_final_lstat,
            "Ticker app",
            owner=uid,
            group=admin_gid,
            mode=0o700,
        )
        if (app_metadata.st_dev, app_metadata.st_ino) != (
            app_final_lstat.st_dev,
            app_final_lstat.st_ino,
        ):
            raise CutoverError("Ticker app changed while being validated")

        contents = open_directory(app, "Contents", "Ticker Contents")
        require_directory(
            descriptor_metadata(contents, "Ticker Contents"),
            "Ticker Contents",
            owner=uid,
            group=admin_gid,
            mode=0o755,
        )
        helpers = open_directory(contents, "Helpers", "Ticker Helpers")
        require_directory(
            descriptor_metadata(helpers, "Ticker Helpers"),
            "Ticker Helpers",
            owner=uid,
            group=admin_gid,
            mode=0o755,
        )

        try:
            ticker = os.open("ticker", leaf_flags, dir_fd=helpers)
        except OSError as error:
            raise CutoverError("cannot open Ticker executable") from error
        descriptors.append(ticker)
        ticker_metadata = descriptor_metadata(ticker, "Ticker executable")
        if not stat.S_ISREG(ticker_metadata.st_mode):
            raise CutoverError("Ticker executable is not a regular file")
        if ticker_metadata.st_uid != uid:
            raise CutoverError("Ticker executable has an unexpected owner")
        if ticker_metadata.st_gid != admin_gid:
            raise CutoverError("Ticker executable has an unexpected group")
        if stat.S_IMODE(ticker_metadata.st_mode) != 0o755:
            raise CutoverError("Ticker executable mode is not 0755")
        try:
            readable = os.access(path, os.R_OK | os.X_OK)
        except OSError as error:
            raise CutoverError("cannot inspect Ticker executable") from error
        if not readable:
            raise CutoverError("Ticker executable is not readable and executable")
        validated_leaf = ticker
        return ticker
    finally:
        for descriptor in reversed(descriptors):
            if descriptor == validated_leaf:
                continue
            try:
                os.close(descriptor)
            except OSError:
                pass


def _runner_source_bytes() -> bytes:
    parent = open_trusted_directory_chain(
        RUNNER_SOURCE.parent,
        os.getuid(),
        "runner source parent",
    )
    try:
        descriptor = open_trusted_regular_at(
            parent,
            RUNNER_SOURCE.name,
            os.getuid(),
            None,
            "runner source",
        )
        try:
            metadata = os.fstat(descriptor)
            if stat.S_IMODE(metadata.st_mode) & 0o111 == 0:
                raise CutoverError("runner source ownership or executable mode is invalid")
            # Keep the path-level check for diagnostics, but read only the opened inode.
            _regular_file(RUNNER_SOURCE, "runner source")
            return read_open_descriptor(descriptor, "runner source")
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def _runtime_binding_for_runner() -> RuntimeBinding:
    if CODEX_EXECUTABLE is None:
        raise CutoverError("Codex runtime is not prepared")
    environment = _required_launchd_environment()
    _validated_launchd_environment(environment)
    _validate_codex_home(Path(environment["CODEX_HOME"]))
    _validate_bound_path(environment["PATH"], os.getuid())
    validate_skill_roots(tuple(routine.root for routine in ROUTINES))
    identity = inspect_native_codex(CODEX_EXECUTABLE, _host_native_arch())
    code_mode_identity = inspect_native_codex(
        CODEX_EXECUTABLE.with_name("codex-code-mode-host"),
        identity.arch,
    )
    managed_by = CODEX_MANAGED_BY or "direct"
    if managed_by not in {"direct", "npm"}:
        raise CutoverError("Codex manager identity is invalid")
    package_root = CODEX_MANAGED_PACKAGE_ROOT
    package_version = CODEX_MANAGED_PACKAGE_VERSION
    if managed_by == "npm":
        if package_root is None:
            raise CutoverError("npm Codex runtime has no package root")
        native, code_mode_host, version, package_identity, package_host_identity = (
            _validate_package_topology(package_root)
        )
        if (
            native != CODEX_EXECUTABLE
            or code_mode_host != code_mode_identity.path
            or version != package_version
            or package_identity.sha256 != identity.sha256
            or package_host_identity.sha256 != code_mode_identity.sha256
        ):
            raise CutoverError("npm Codex runtime provenance changed")
    elif package_root is not None or package_version is not None:
        raise CutoverError("direct Codex runtime contains package metadata")
    return RuntimeBinding(
        binding_version=RUNTIME_BINDING_VERSION,
        uid=os.getuid(),
        home=HOME_DIRECTORY,
        repository=WORKING_DIRECTORY,
        python=Path(sys.executable),
        codex=CODEX_EXECUTABLE,
        codex_home=Path(environment["CODEX_HOME"]),
        path=environment["PATH"],
        model=RUNTIME_MODEL,
        skill_roots={
            routine.task_id: routine.root.canonical_root for routine in ROUTINES
        },
        codex_sha256=identity.sha256,
        codex_macho_arch=identity.arch,
        codex_code_mode_host=code_mode_identity.path,
        codex_code_mode_host_sha256=code_mode_identity.sha256,
        codex_managed_package_root=package_root,
        codex_managed_package_version=package_version,
        codex_managed_by=managed_by,
    )


def install_runner_atomically() -> bytes:
    source = _runner_source_bytes()
    binding = _runtime_binding_for_runner()
    generated = render_generated_runner(source, binding)
    RUNNER_INSTALLED.parent.mkdir(parents=True, exist_ok=True)
    _validate_trusted_directory_path(
        RUNNER_INSTALLED.parent,
        os.getuid(),
        "installed runner parent",
    )
    parent = open_trusted_directory_chain(
        RUNNER_INSTALLED.parent,
        os.getuid(),
        "installed runner parent",
    )
    try:
        readback = atomic_write_at(
            parent,
            RUNNER_INSTALLED.name,
            generated,
            0o755,
            description="installed runner",
        )
        if readback != generated:
            raise CutoverError("generated runner read-back differs")
    finally:
        os.close(parent)
    return readback


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
    def _configure_recovery_policies(self) -> None:
        snapshot = self._inspect_replacements(repair_stale=False)
        if not snapshot.full_codex:
            raise CutoverError(
                "cannot configure recovery policies before all wrappers are consistent"
            )
        configure_recovery_policies(self.routines, self.command_runner)
        self.state.recovery_policies_configured = True

    def _fail_closed_recovery_policies(self) -> None:
        fail_closed_recovery_policies(self.routines, self.command_runner)


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
        _validate_trusted_directory_path(
            WORKING_DIRECTORY,
            os.getuid(),
            "approved working directory",
            require_owner=True,
        )
        validated_fd = validate_ticker_executable(TICKER_EXECUTABLE)
        if validated_fd is not None:
            os.close(validated_fd)
        validate_ticker_ids(self.routines)

    def _preflight_forward(self) -> None:
        if CODEX_EXECUTABLE is None:
            raise CutoverError("Codex runtime is not prepared")
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

    def _revalidate_registry_binding(self) -> None:
        discovered = discover_claude_registry(HOME_DIRECTORY, self.routines)
        if discovered != REGISTRY:
            raise CutoverError(
                "Claude registry selection changed during the migration transaction"
            )

    def _quiesce_and_revalidate_registry(self) -> None:
        stopped_pids = stop_claude(
            self.command_runner,
            observe_pids=self._record_claude_custody,
        )
        self._record_claude_custody(stopped_pids)
        self._revalidate_registry_binding()

    def _ensure_registry(self, enabled: bool) -> None:
        for _attempt in range(REGISTRY_PUBLICATION_ATTEMPTS):
            # Bind the authoritative registry after each consecutive absence
            # observation and immediately before its read/publication.
            self._quiesce_and_revalidate_registry()
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

            # Fence the publication against a new Claude process or a changed
            # structural registry selection before trusting the written state.
            self._quiesce_and_revalidate_registry()
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


    def _restore_enabled_claude_after_shutdown(self) -> None:
        with blocked_cutover_signals():
            self._revalidate_registry_binding()
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

    def _restore_claude_engine(self, *, deactivate_replacements: bool = True) -> None:
        with blocked_cutover_signals():
            self._quiesce_and_revalidate_registry()
            self._check_blackout()
            if deactivate_replacements:
                self._deactivate_replacements_to_absent()
            self._check_blackout()
            self._ensure_registry(True)
            self.state.claude_relaunched = relaunch_claude(
                self.command_runner,
                True,
                self.state.claude_prior_pids,
            )
            self._verify_claude_engine()
            self._revalidate_registry_binding()
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
            prepare_codex_compensation()
            self._check_blackout()
            self._quiesce_and_revalidate_registry()
            self._ensure_registry(False)
            self._deactivate_replacements_to_absent()
            self._check_blackout()
            self._create_codex_replacements()
            self._quiesce_and_revalidate_registry()
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

    def _fence_post_relaunch(self) -> None:
        try:
            self._revalidate_registry_binding()
            selected_registry_rows(
                read_regular(REGISTRY, "disabled Claude registry"),
                self.routines,
                False,
            )
        except BaseException:
            stopped_pids = stop_claude(
                self.command_runner,
                observe_pids=self._record_claude_custody,
            )
            self._record_claude_custody(stopped_pids)
            raise

    def _restart_claude_if_requested(self) -> None:
        self.state.claude_relaunched = relaunch_claude(
            self.command_runner,
            self.state.claude_was_running,
            self.state.claude_prior_pids,
        )
        self._fence_post_relaunch()

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
                    self._quiesce_and_revalidate_registry()
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
        if LAUNCHD_ENVIRONMENT is None or CODEX_EXECUTABLE is None:
            prepare_forward_launchd_environment()
        self._preflight_forward()
        install_runner_atomically()
        try:
            with SignalScope():
                self._quiesce_and_revalidate_registry()
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
                self._quiesce_and_revalidate_registry()
                ensure_success_marker()
                self._configure_recovery_policies()
                self._restart_claude_if_requested()
                self.state.committed = True
        except BaseException as error:
            if self.state.recovery_policies_configured:
                try:
                    self._fail_closed_recovery_policies()
                except BaseException as policy_error:
                    raise RollbackError(
                        f"cutover failed ({error}); recovery policy cleanup "
                        f"also failed ({policy_error})"
                    ) from policy_error
                self.state.recovery_policies_configured = False
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
        if replacements.full_codex:
            self._fail_closed_recovery_policies()
        if (
            marker == "exact"
            and not registry_enabled
            and replacements.absent
            and LAUNCHD_ENVIRONMENT is None
        ):
            self.state.registry_disabled = True
            with SignalScope():
                self._restore_claude_engine(deactivate_replacements=False)
            self.state.registry_disabled = True
            return self.state

        if marker == "absent":
            if not registry_enabled:
                self.state.registry_disabled = True
                try:
                    with SignalScope():
                        self._quiesce_and_revalidate_registry()
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
                    self._quiesce_and_revalidate_registry()
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
                self._quiesce_and_revalidate_registry()
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
                self._revalidate_registry_binding()
                remove_success_marker()
                self._verify_claude_engine()
                self.state.committed = False
                self.state.rolled_back = True
                return self.state
        except BaseException as error:
            try:
                with blocked_cutover_signals():
                    self._revalidate_registry_binding()
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


def _restore_installed_runner(data: bytes) -> None:
    parent = open_trusted_directory_chain(
        RUNNER_INSTALLED.parent,
        os.getuid(),
        "installed runner parent",
    )
    try:
        atomic_write_at(
            parent,
            RUNNER_INSTALLED.name,
            data,
            0o755,
            description="restored installed runner",
        )
    finally:
        os.close(parent)


def refresh_runtime_artifact(
    routines: Sequence[Routine] = ROUTINES,
    *,
    command_runner: Optional[CommandRunner] = None,
    clock: Callable[[], dt.datetime] = lambda: dt.datetime.now(tz=NEW_YORK),
) -> None:
    """Refresh the committed runner without changing registry, plist, or marker bytes."""
    selected = tuple(routines)
    runner = command_runner or CommandRunner()
    transaction = CutoverTransaction(selected, command_runner=runner, clock=clock)
    installed = False
    installed_runner: Optional[bytes] = None
    claude_quiesced = False
    relaunch_attempted = False
    policies_configured = False
    with blocked_cutover_signals():
        with SignalScope():
            try:
                transaction._preflight_common()
                transaction._quiesce_and_revalidate_registry()
                claude_quiesced = True
                transaction._check_blackout()
                if inspect_marker() != "exact":
                    raise CutoverError(
                        "committed runtime refresh requires the exact success marker"
                    )
                marker_before = read_regular(SUCCESS_MARKER, "success marker")
                registry_before = read_regular(REGISTRY, "disabled Claude registry")
                selected_registry_rows(registry_before, selected, False)
                plist_before = {
                    routine.task_id: read_regular(routine.plist, "wrapped launchd plist")
                    for routine in selected
                }
                for routine in selected:
                    validate_plist(routine, wrapped=True)
                runner_before = read_regular(RUNNER_INSTALLED, "installed runner")
                transaction._expect_ticker(True)
                for routine in selected:
                    if not transaction._service_loaded(routine):
                        raise CutoverError(
                            f"committed runtime refresh found an unloaded {routine.task_id}"
                        )
                prepare_codex_compensation()
                transaction._check_blackout()
                installed_runner = install_runner_atomically()
                installed = True
                if installed_runner is None:
                    installed_runner = read_regular(
                        RUNNER_INSTALLED,
                        "installed runner after refresh",
                    )
                converged = False
                for _attempt in range(REGISTRY_PUBLICATION_ATTEMPTS):
                    transaction._check_blackout()
                    states = transaction._ticker_recovery_states()
                    for routine in selected:
                        was_consistent = states[routine.task_id] == "wrapped-consistent"
                        if _attempt and was_consistent:
                            continue
                        result = runner.run(TICKER_EXECUTABLE, ["wrap", routine.ticker_id])
                        validate_plist(routine, wrapped=True)
                        if result.status != 0:
                            states = transaction._ticker_recovery_states()
                            if was_consistent:
                                raise CutoverError(
                                    f"Ticker refresh failed for {routine.task_id}"
                                )
                            if states[routine.task_id] != "wrapped-consistent":
                                break
                    states = transaction._ticker_recovery_states()
                    if all(
                        states[routine.task_id] == "wrapped-consistent"
                        for routine in selected
                    ):
                        converged = True
                        break
                if not converged:
                    raise RollbackError(
                        "committed runtime refresh did not converge all Ticker rows"
                    )
                transaction._expect_ticker(True)
                transaction._ticker_doctor()
                if read_regular(SUCCESS_MARKER, "refreshed success marker") != marker_before:
                    raise CutoverError("committed runtime refresh changed the success marker")
                if read_regular(REGISTRY, "refreshed Claude registry") != registry_before:
                    raise CutoverError("committed runtime refresh changed the Claude registry")
                for routine in selected:
                    if (
                        read_regular(routine.plist, "refreshed launchd plist")
                        != plist_before[routine.task_id]
                    ):
                        raise CutoverError(
                            f"committed runtime refresh changed {routine.task_id} plist"
                        )
                transaction._revalidate_registry_binding()
                transaction._configure_recovery_policies()
                policies_configured = True
                if transaction.state.claude_was_running:
                    relaunch_attempted = True
                    transaction._restart_claude_if_requested()
            except BaseException as refresh_error:
                if installed:
                    def plists_match_snapshots() -> bool:
                        try:
                            return all(
                                read_regular(routine.plist, "refresh plist")
                                == plist_before[routine.task_id]
                                for routine in selected
                            )
                        except BaseException:
                            return False

                    if plists_match_snapshots():
                        try:
                            compensation_allowed = True
                            for _attempt in range(REGISTRY_PUBLICATION_ATTEMPTS):
                                transaction._check_blackout()
                                if not plists_match_snapshots():
                                    compensation_allowed = False
                                    break
                                states = transaction._ticker_recovery_states()
                                for routine in selected:
                                    if states[routine.task_id] == "wrapped-consistent":
                                        continue
                                    if not plists_match_snapshots():
                                        compensation_allowed = False
                                        break
                                    runner.run(
                                        TICKER_EXECUTABLE,
                                        ["wrap", routine.ticker_id],
                                    )
                                if not compensation_allowed or not plists_match_snapshots():
                                    compensation_allowed = False
                                    break
                                states = transaction._ticker_recovery_states()
                                if all(
                                    states[routine.task_id] == "wrapped-consistent"
                                    for routine in selected
                                ):
                                    break
                            if compensation_allowed:
                                transaction._ticker_doctor()
                        except BaseException:
                            pass

                    if installed_runner is not None:
                        try:
                            current_runner = read_regular(
                                RUNNER_INSTALLED,
                                "refresh runner",
                            )
                        except BaseException:
                            current_runner = None
                        if current_runner == installed_runner:
                            try:
                                _restore_installed_runner(runner_before)
                            except BaseException:
                                pass

                if (
                    claude_quiesced
                    and transaction.state.claude_was_running
                    and not relaunch_attempted
                ):
                    try:
                        transaction._revalidate_registry_binding()
                        transaction._restart_claude_if_requested()
                    except BaseException:
                        pass
                if policies_configured:
                    try:
                        transaction._fail_closed_recovery_policies()
                    except BaseException as policy_error:
                        raise RollbackError(
                            f"committed runtime refresh failed ({refresh_error}); "
                            f"recovery policy cleanup also failed ({policy_error})"
                        ) from policy_error
                    policies_configured = False
                raise


def main(arguments: Optional[Sequence[str]] = None) -> int:
    values = list(sys.argv[1:] if arguments is None else arguments)
    if values not in ([], ["--rollback"], ["--refresh"]):
        print(
            f"usage: {Path(sys.argv[0]).name} [--rollback|--refresh]",
            file=sys.stderr,
        )
        return 64
    try:
        configure_static_runtime()
        with migration_transaction_lock():
            bind_locked_registry_runtime()
            transaction = CutoverTransaction(ROUTINES)
            if values == ["--rollback"]:
                transaction.rollback_committed()
                print(f"{TICKET} scheduled-routine rollback completed")
            elif values == ["--refresh"]:
                refresh_runtime_artifact(
                    ROUTINES,
                    command_runner=transaction.command_runner,
                    clock=transaction.clock,
                )
                print(f"{TICKET} scheduled-routine runtime refresh completed")
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
