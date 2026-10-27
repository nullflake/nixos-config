"""Create verified, ordinary file copies on a uniquely labelled mounted volume."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import errno
import fcntl
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Generator, Sequence
from dataclasses import dataclass
from pathlib import Path
from types import FrameType
from typing import NamedTuple, NoReturn, TypedDict, cast
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

STAMP = "%d%m%Y_%H%M%S"
LEGACY_STAMP = "%Y-%m-%dT%H-%M-%S.%fZ"
BACKUP_INTERVAL = 2 * 60 * 60
RETENTION = dt.timedelta(days=7)
RETRY = 15 * 60
STATE_VERSION = 2
MANIFEST = ".backup-manifest.json"
COMPLETE = ".backup-complete"
OWNER_MARKER = ".backup-owner"
SNAPSHOT_FORMAT = "usb-backup-v1"
OWNER_TOKEN = f"{SNAPSHOT_FORMAT}\n"
METADATA = {MANIFEST, COMPLETE, OWNER_MARKER}
ERRORS = (
    OSError,
    RuntimeError,
    TypeError,
    ValueError,
    subprocess.SubprocessError,
)

type JsonValue = (
    None | bool | int | float | str | list[JsonValue] | dict[str, JsonValue]
)


class FileSignature(NamedTuple):
    mode: int
    device: int
    inode: int
    size: int
    modified_ns: int
    changed_ns: int


class FileDigest(TypedDict):
    size: int
    sha256: str


class SnapshotManifest(TypedDict):
    format: str
    created_utc: str
    sources: list[str]
    files: dict[str, FileDigest]
    directories: list[str]


class BackupState(TypedDict, total=False):
    version: int
    mount: list[JsonValue] | None
    last_success_elapsed: float
    last_success: float
    retry_after_elapsed: float


@dataclass
class Arguments(argparse.Namespace):
    config: Path = Path(".")
    force: bool = False
    verify: Path | None = None


@dataclass(frozen=True, slots=True)
class Settings:
    label: str
    home: Path
    paths: tuple[Path, ...]
    destination: Path
    legacy_destination: Path | None
    timezone: ZoneInfo
    unmounted_paths: tuple[Path, ...]
    container_paths: tuple[Path, ...]

    @classmethod
    def from_json(cls, value: JsonValue) -> Settings:
        """Validate configuration once, before touching the backup volume."""
        if not isinstance(value, dict):
            raise TypeError("Backup configuration must be a JSON object")
        label, home = value.get("label"), value.get("home")
        if not isinstance(label, str) or not isinstance(home, str):
            raise TypeError("Backup label and home must be strings")
        if not label or not Path(home).is_absolute():
            raise ValueError("Backup requires a nonempty label and an absolute home")

        def paths(name: str) -> tuple[Path, ...]:
            items = value.get(name, [])
            if not isinstance(items, list):
                raise TypeError(f"Backup {name} must be a list of relative paths")
            return tuple(relative_path(item) for item in items)

        selections = paths("paths")
        if not selections:
            raise ValueError("Select at least one backup path")
        if len(set(selections)) != len(selections) or any(
            parent in child.parents for parent in selections for child in selections
        ):
            raise ValueError(
                "Backup paths must not contain duplicates or nested selections"
            )
        containers = paths("containerPaths")
        if not set(containers).issubset(selections):
            raise ValueError("Container paths must also be selected for backup")

        destination = relative_path(value.get("destination"))
        legacy = value.get("legacyDestination")
        legacy = relative_path(legacy) if legacy is not None else None
        if legacy is not None and (
            destination.is_relative_to(legacy) or legacy.is_relative_to(destination)
        ):
            raise ValueError("Old and new backup locations must not overlap")
        zone = value.get("timezone", "UTC")
        if zone is None:
            zone = "UTC"
        if not isinstance(zone, str):
            raise TypeError("Backup timezone must be a string")
        try:
            timezone = ZoneInfo(zone)
        except ZoneInfoNotFoundError as error:
            raise ValueError(f"Unknown backup timezone: {zone!r}") from error
        return cls(
            label=label,
            home=Path(home),
            paths=selections,
            destination=destination,
            legacy_destination=legacy,
            timezone=timezone,
            unmounted_paths=paths("unmountedPaths"),
            container_paths=containers,
        )

    def identity(self) -> dict[str, JsonValue]:
        """Keep saved connection identities compatible with the JSON configuration."""
        return {
            "label": self.label,
            "home": str(self.home),
            "paths": [str(path) for path in self.paths],
            "destination": str(self.destination),
            "legacyDestination": str(self.legacy_destination)
            if self.legacy_destination is not None
            else None,
            "timezone": self.timezone.key,
            "unmountedPaths": [str(path) for path in self.unmounted_paths],
            "containerPaths": [str(path) for path in self.container_paths],
        }


@dataclass(frozen=True, slots=True)
class Volume:
    target: Path
    device: str
    disk_sequence: int
    mount_id: int


def elapsed() -> float:
    # Unlike the wall clock, this does not jump during time corrections and
    # includes time spent suspended. The saved identity also includes boot_id.
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def boot_id() -> str:
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def json_object(value: JsonValue, description: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict):
        raise TypeError(f"Expected a JSON object for {description}")
    return value


def command_json(*args: str) -> dict[str, JsonValue]:
    result = subprocess.run(
        args, check=True, capture_output=True, text=True, timeout=15
    )
    return json_object(cast(JsonValue, json.loads(result.stdout)), args[0])


def records(value: dict[str, JsonValue], key: str) -> list[dict[str, JsonValue]]:
    items = value.get(key)
    if not isinstance(items, list):
        raise TypeError(
            f"Invalid device information: expected a list of objects for {key}"
        )
    return [json_object(item, key) for item in items]


def find_volume(label: str) -> Volume | None:
    devices = command_json(
        "lsblk", "--json", "--list", "--output", "LABEL,MAJ:MIN,DISK-SEQ"
    )
    matches = [d for d in records(devices, "blockdevices") if d.get("label") == label]
    if not matches:
        return None
    if len(matches) != 1:
        raise RuntimeError(f"Multiple volumes have label {label!r}; refusing to choose")
    device = matches[0].get("maj:min")
    if (
        not isinstance(device, str)
        or not all(part.isdecimal() for part in device.split(":"))
        or device.count(":") != 1
    ):
        raise ValueError("Cannot determine the backup volume's device number")
    sequence = matches[0].get("disk-seq")
    if type(sequence) is not int or sequence <= 0:
        raise RuntimeError("Cannot determine the backup volume's disk sequence")
    mounts = command_json(
        "findmnt", "--json", "--list", "--output", "TARGET,MAJ:MIN,ID"
    )
    matches = [m for m in records(mounts, "filesystems") if m.get("maj:min") == device]
    if not matches:
        return None
    if len(matches) != 1:
        raise RuntimeError("Backup volume has multiple mountpoints")
    target, mount_id = matches[0].get("target"), matches[0].get("id")
    if not isinstance(target, str) or not Path(target).is_absolute():
        raise ValueError("Backup volume must have an absolute mountpoint")
    if type(mount_id) is not int or mount_id <= 0:
        raise ValueError("Cannot determine the backup volume's mount ID")
    return Volume(Path(target), device, sequence, mount_id)


def relative_path(value: object) -> Path:
    if not isinstance(value, str):
        raise TypeError("Backup paths must be strings")
    path = Path(value)
    if (
        "\0" in value
        or path.is_absolute()
        or not path.parts
        or any(part in ("", ".", "..") for part in value.split("/"))
    ):
        raise ValueError(f"Expected a relative path without traversal: {value!r}")
    if path.parts[0] in METADATA:
        raise ValueError(f"Path uses a reserved backup metadata name: {value!r}")
    return path


@contextlib.contextmanager
def mounted_directory(volume: Volume) -> Generator[None]:
    """Pin the filesystem so unplugging cannot redirect writes to the host disk."""
    previous = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
    descriptor = None
    try:
        descriptor = os.open(
            volume.target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        )
        device = os.fstat(descriptor).st_dev
        if f"{os.major(device)}:{os.minor(device)}" != volume.device:
            raise RuntimeError("Backup volume disappeared before it could be opened")
        os.fchdir(descriptor)
        yield
    finally:
        os.fchdir(previous)
        if descriptor is not None:
            os.close(descriptor)
        os.close(previous)


def make_directory(path: Path) -> None:
    current = Path(".")
    for part in path.parts:
        current /= part
        current.mkdir(exist_ok=True)
        if current.is_symlink() or not current.is_dir():
            raise RuntimeError(
                f"Backup directory is not an ordinary directory: {current}"
            )


def prepare_destination(settings: Settings) -> Path:
    destination = settings.destination
    legacy = settings.legacy_destination
    if legacy is not None:
        # Do not follow a substituted path on a replacement backup volume.
        for path in [legacy, *legacy.parents]:
            if path == Path("."):
                break
            if path.is_symlink():
                raise RuntimeError(f"Legacy backup path is a symlink: {path}")
        if legacy.exists():
            if not legacy.is_dir():
                raise RuntimeError(f"Legacy backup path is not a directory: {legacy}")
            if os.path.lexists(destination):
                raise RuntimeError(
                    "Both old and new backup locations exist; refusing to overwrite or merge"
                )
            make_directory(destination.parent)
            _ = legacy.rename(destination)
            flush_volume()
            # Only empty legacy parents are removed; other USB data stays put.
            for path in legacy.parents:
                if path == Path("."):
                    break
                try:
                    path.rmdir()
                except OSError as error:
                    if error.errno in (errno.ENOTEMPTY, errno.EEXIST, errno.ENOENT):
                        break
                    raise
    make_directory(destination)
    return destination


def snapshot_time(name: str, zone: dt.tzinfo | None = None) -> dt.datetime | None:
    try:
        stamp = dt.datetime.strptime(name, STAMP)
        if zone is not None:
            stamp = stamp.replace(tzinfo=zone)
    except ValueError:
        try:
            stamp = dt.datetime.strptime(name, LEGACY_STAMP).replace(tzinfo=dt.UTC)
        except ValueError:
            return None
    return stamp.astimezone(dt.UTC)


def read_json(path: Path, limit: int = 16 * 1024 * 1024) -> JsonValue:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError(f"Expected a regular JSON file: {path}")
        raw = source.read(limit + 1)
    if len(raw) > limit:
        raise ValueError(f"JSON file is too large: {path}")
    return cast(JsonValue, json.loads(raw))


def write_json(path: Path, value: object) -> None:
    with path.open("x", encoding="utf-8") as target:
        json.dump(value, target, sort_keys=True)
        _ = target.write("\n")


def marker_matches(path: Path, content: str) -> bool:
    try:
        info = path.lstat()
        return (
            stat.S_ISREG(info.st_mode)
            and info.st_size == len(content)
            and path.read_text() == content
        )
    except FileNotFoundError:
        return False


def remove_incomplete(destination: Path) -> None:
    for path in destination.iterdir():
        if (
            path.name.startswith(".incomplete-")
            and not path.is_symlink()
            and path.is_dir()
            and marker_matches(path / OWNER_MARKER, OWNER_TOKEN)
        ):
            shutil.rmtree(path)


def flush_volume() -> None:
    # syncfs via coreutils flushes this pinned filesystem, including directory
    # entries, and reports writeback errors before old backups may be removed.
    _ = subprocess.run(["sync", "--file-system", "."], check=True, timeout=60)


def manifest_time(manifest: JsonValue, path: Path) -> dt.datetime:
    if not isinstance(manifest, dict) or manifest.get("format") != SNAPSHOT_FORMAT:
        raise ValueError(f"Unknown snapshot manifest format: {path}")
    created = manifest.get("created_utc")
    if not isinstance(created, str):
        raise TypeError(f"Snapshot manifest has no creation timestamp: {path}")
    stamp = dt.datetime.fromisoformat(created)
    if stamp.tzinfo is None:
        raise ValueError(f"Snapshot manifest has no timezone: {path}")
    return stamp


def read_manifest(path: Path) -> SnapshotManifest:
    manifest = json_object(read_json(path / MANIFEST), "snapshot manifest")
    created = manifest_time(manifest, path)
    files = manifest.get("files")
    raw_directories = manifest.get("directories")
    raw_sources = manifest.get("sources")
    if (
        not isinstance(files, dict)
        or not isinstance(raw_directories, list)
        or not isinstance(raw_sources, list)
    ):
        raise TypeError(f"Invalid snapshot inventory: {path}")
    directories = [str(relative_path(name)) for name in raw_directories]
    sources = [str(relative_path(name)) for name in raw_sources]
    if len(set(directories)) != len(directories) or set(files).intersection(
        directories
    ):
        raise ValueError(f"Duplicate file or directory in snapshot inventory: {path}")
    digests: dict[str, FileDigest] = {}
    for name, details in files.items():
        name = str(relative_path(name))
        if not isinstance(details, dict) or set(details) != {"size", "sha256"}:
            raise ValueError(f"Invalid checksum metadata: {name}")
        size, digest = details["size"], details["sha256"]
        if type(size) is not int or size < 0 or not isinstance(digest, str):
            raise ValueError(f"Invalid checksum metadata: {name}")
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise ValueError(f"Invalid SHA-256 digest: {name}")
        digests[name] = {"size": size, "sha256": digest}
    return {
        "format": SNAPSHOT_FORMAT,
        "created_utc": created.isoformat(),
        "sources": sources,
        "files": digests,
        "directories": directories,
    }


def prune(destination: Path, zone: dt.tzinfo | None = None) -> None:
    cutoff = dt.datetime.now(dt.UTC) - RETENTION
    for path in destination.iterdir():
        if path.is_symlink() or not path.is_dir():
            continue
        stamp = snapshot_time(path.name, zone)
        if stamp is None or not marker_matches(path / COMPLETE, "1\n"):
            continue
        if (path / MANIFEST).exists():
            stamp = manifest_time(read_json(path / MANIFEST), path)
        if stamp < cutoff:
            shutil.rmtree(path)


def require_unmounted(settings: Settings) -> None:
    containers = [settings.home / path for path in settings.container_paths]
    required = {(settings.home / path).resolve() for path in settings.unmounted_paths}
    if required or containers:
        mounts = command_json(
            "findmnt", "--json", "--list", "--output", "TARGET,FSTYPE,SOURCE"
        )
        for mount in records(mounts, "filesystems"):
            target = mount.get("target")
            if not isinstance(target, str):
                raise TypeError("Mountpoint information must contain a path string")
            path = Path(target).resolve()
            if path in required:
                raise RuntimeError(
                    f"Backup postponed: unmount {path} before backing up"
                )
            # VeraCrypt's userspace crypto backend may attach the decrypted
            # auxiliary FUSE file to a loop device, hiding the original filename.
            if containers and (
                mount.get("fstype") == "fuse.veracrypt"
                or path.name.startswith(".veracrypt_aux_mnt")
            ):
                raise RuntimeError(
                    "Backup postponed: dismount VeraCrypt FUSE volumes first"
                )
    if not containers:
        return
    identities: set[tuple[int, int]] = set()
    for path in containers:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"Encrypted container is not a regular file: {path}")
        identities.add((info.st_dev, info.st_ino))
    resolved = {p.resolve() for p in containers}
    loops = command_json("losetup", "--json", "--list", "--output", "BACK-FILE")
    for loop in records(loops, "loopdevices"):
        name = loop.get("back-file")
        if not isinstance(name, str) or not name:
            raise RuntimeError("Cannot determine a loop device's backing file")
        path = Path(name)
        if path.resolve() in resolved:
            raise RuntimeError(
                f"Backup postponed: encrypted container is mounted: {path}"
            )
        try:
            info = path.stat()
        except FileNotFoundError:
            continue  # An unrelated backing file may have been deleted.
        if (info.st_dev, info.st_ino) in identities:
            raise RuntimeError(
                f"Backup postponed: encrypted container is mounted: {path}"
            )


def signature(info: os.stat_result) -> FileSignature:
    return FileSignature(
        mode=stat.S_IFMT(info.st_mode),
        device=info.st_dev,
        inode=info.st_ino,
        size=info.st_size,
        modified_ns=info.st_mtime_ns,
        changed_ns=info.st_ctime_ns,
    )


def inventory(
    root: Path, selections: Sequence[Path], ignore_metadata: bool = False
) -> dict[str, FileSignature]:
    entries: dict[str, FileSignature] = {}

    def visit(relative: Path) -> None:
        path = root / relative
        info = path.lstat()
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise RuntimeError(f"Unsupported source type or symlink: {path}")
        entries[str(relative)] = signature(info)
        if stat.S_ISDIR(info.st_mode):
            for child in sorted(path.iterdir()):
                visit(relative / child.name)

    for selection in selections:
        if ignore_metadata and selection.name in METADATA:
            continue
        visit(selection)
    return entries


def digest_file(path: Path) -> FileDigest:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    digest = hashlib.sha256()
    size = 0
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"Expected a regular file: {path}")
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
        if signature(before) != signature(os.fstat(source.fileno())):
            raise RuntimeError(f"File changed while reading: {path}")
    return {"size": size, "sha256": digest.hexdigest()}


def verify_snapshot(path: Path, require_complete: bool = True) -> int:
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"Snapshot is not an ordinary directory: {path}")
    if require_complete and not marker_matches(path / COMPLETE, "1\n"):
        raise ValueError(f"Snapshot is incomplete: {path}")
    manifest = read_manifest(path)
    files, directories = manifest["files"], manifest["directories"]
    expected = set(files) | set(directories)
    actual = inventory(
        path, [p.relative_to(path) for p in path.iterdir()], ignore_metadata=True
    )
    if set(actual) != expected:
        raise RuntimeError(f"Snapshot file/directory inventory mismatch: {path}")
    for name in directories:
        if actual[name].mode != stat.S_IFDIR:
            raise RuntimeError(f"Snapshot directory type mismatch: {name}")
    for name, details in files.items():
        if actual[name].mode != stat.S_IFREG or digest_file(path / name) != details:
            raise RuntimeError(f"Snapshot checksum mismatch: {name}")
    return len(files)


def require_space(destination: Path, entries: dict[str, FileSignature]) -> None:
    block = os.statvfs(destination).f_frsize
    required = (
        sum(((entry.size + block - 1) // block) * block for entry in entries.values())
        + block * 4
    )
    if required > shutil.disk_usage(destination).free:
        raise OSError(
            f"Insufficient backup space: approximately {required} bytes required"
        )


def build_manifest(
    settings: Settings, entries: dict[str, FileSignature]
) -> SnapshotManifest:
    files: dict[str, FileDigest] = {}
    directories: set[str] = set()
    for name, entry in entries.items():
        relative = Path(name)
        directories.update(
            str(parent) for parent in relative.parents if parent != Path(".")
        )
        if entry.mode == stat.S_IFDIR:
            directories.add(name)
        else:
            files[name] = digest_file(settings.home / relative)
    return {
        "format": SNAPSHOT_FORMAT,
        "created_utc": dt.datetime.now(dt.UTC).isoformat(),
        "sources": [str(path) for path in settings.paths],
        "files": files,
        "directories": sorted(directories),
    }


def available_snapshot_path(destination: Path, zone: ZoneInfo) -> Path:
    deadline = elapsed() + 2
    while True:
        path = destination / dt.datetime.now(zone).strftime(STAMP)
        if not os.path.lexists(path):
            return path
        if elapsed() >= deadline:
            raise RuntimeError(
                "Snapshot name is already in use; retry in a few seconds"
            )
        time.sleep(0.1)


def take_snapshot(settings: Settings) -> Path:
    require_unmounted(settings)
    before = inventory(settings.home, settings.paths)
    # Check before creating or migrating the destination inside a selected tree.
    destination = settings.destination
    for relative in settings.paths:
        source = settings.home / relative
        if source.is_dir() and destination.resolve().is_relative_to(source.resolve()):
            raise ValueError("Backup destination must not be inside a selected source")
    destination = prepare_destination(settings)
    remove_incomplete(destination)
    require_space(destination, before)
    temporary = Path(tempfile.mkdtemp(prefix=".incomplete-", dir=destination))
    try:
        _ = (temporary / OWNER_MARKER).write_text(OWNER_TOKEN)
        for relative in settings.paths:
            source, target = settings.home / relative, temporary / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                _ = shutil.copytree(source, target, symlinks=True)
            else:
                _ = shutil.copy2(source, target, follow_symlinks=False)
        write_json(temporary / MANIFEST, build_manifest(settings, before))
        _ = verify_snapshot(temporary, require_complete=False)
        require_unmounted(settings)
        if inventory(settings.home, settings.paths) != before:
            raise RuntimeError("Backup sources changed during the copy; retrying later")
        _ = (temporary / COMPLETE).write_text("1\n")
        flush_volume()
        final = available_snapshot_path(destination, settings.timezone)
        _ = temporary.rename(final)
        flush_volume()
    finally:
        if temporary.exists():
            try:
                shutil.rmtree(temporary)
            except OSError as error:
                print(
                    f"Staging cleanup failed; recovery will retry later: {error}",
                    file=sys.stderr,
                    flush=True,
                )
    return final


def notify(message: str, critical: bool = False) -> None:
    try:
        _ = subprocess.run(
            [
                "notify-send",
                "--app-name=USB Backup",
                f"--urgency={'critical' if critical else 'normal'}",
                "USB Backup",
                message,
            ],
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


def load_state(path: Path, now: float) -> BackupState:
    try:
        state = read_json(path, limit=1024 * 1024)
        if (
            not isinstance(state, dict)
            or type(state.get("version")) is not int
            or state.get("version") != STATE_VERSION
        ):
            raise ValueError("Unknown state format")
        mount = state.get("mount")
        if mount is not None and not isinstance(mount, list):
            raise ValueError("Invalid saved connection identity")
        timestamps: dict[str, float] = {}
        for name in ("last_success_elapsed", "retry_after_elapsed"):
            value = state.get(name, 0)
            if (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not 0 <= value <= now + RETRY
            ):
                raise ValueError("Invalid state timestamp")
            if name in state:
                timestamps[name] = float(value)
        last_success = state.get("last_success", 0)
        if (
            not isinstance(last_success, (int, float))
            or isinstance(last_success, bool)
            or not 0 <= last_success < float("inf")
        ):
            raise ValueError("Invalid state wall-clock timestamp")
        validated: BackupState = {"version": STATE_VERSION, "mount": mount}
        if "last_success_elapsed" in timestamps:
            validated["last_success_elapsed"] = timestamps["last_success_elapsed"]
        if "retry_after_elapsed" in timestamps:
            validated["retry_after_elapsed"] = timestamps["retry_after_elapsed"]
        if "last_success" in state:
            validated["last_success"] = float(last_success)
        if validated.get("last_success_elapsed", 0) > now:
            raise ValueError("State clock is outside this boot's range")
        return validated
    except FileNotFoundError:
        return {}
    except (ValueError, UnicodeError):
        print(
            "Discarding invalid or obsolete backup state", file=sys.stderr, flush=True
        )
        return {}


def save_state(path: Path, state: BackupState) -> None:
    state = {**state, "version": STATE_VERSION}
    descriptor, temporary = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as target:
            json.dump(state, target)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        Path(temporary).unlink(missing_ok=True)


def run(settings: Settings, state_path: Path, force: bool) -> int:
    now = elapsed()
    state = load_state(state_path, now)
    identity: list[JsonValue] | None = None
    try:
        volume = find_volume(settings.label)
        if volume is None:
            state_path.unlink(missing_ok=True)
            return 0
        identity = [
            boot_id(),
            volume.device,
            volume.disk_sequence,
            volume.mount_id,
            settings.identity(),
        ]
        if not force and state.get("mount") == identity:
            if now < state.get("retry_after_elapsed", 0):
                return 0
            if (
                "last_success_elapsed" in state
                and now - state["last_success_elapsed"] < BACKUP_INTERVAL
            ):
                return 0
        warning = None
        with mounted_directory(volume):
            snapshot = take_snapshot(settings)
            try:
                prune(settings.destination, settings.timezone)
                flush_volume()
            except ERRORS as error:
                warning = f"Backup saved, but old-backup cleanup failed: {error}"
        save_state(
            state_path,
            {
                "mount": identity,
                "last_success_elapsed": elapsed(),
                "last_success": time.time(),
            },
        )
        print(f"Backup complete: {volume.target / snapshot}", flush=True)
        if warning:
            print(warning, file=sys.stderr, flush=True)
        notify(
            warning or "Selected files were backed up and verified successfully.",
            bool(warning),
        )
        return 0
    except ERRORS as error:
        if (
            not force
            and state.get("mount") == identity
            and now < state.get("retry_after_elapsed", 0)
        ):
            return 0
        save_state(
            state_path, {"mount": identity, "retry_after_elapsed": elapsed() + RETRY}
        )
        print(f"Backup failed: {error}", file=sys.stderr, flush=True)
        notify(
            f"Backup failed: {error}. See journalctl --user -u usb-backup.service.",
            True,
        )
        return 1


def interrupted(signum: int, _frame: FrameType | None) -> NoReturn:
    # Let finally blocks clean staging; a later SIGKILL is recovered next run.
    _ = signal.signal(signal.SIGTERM, signal.SIG_IGN)
    _ = signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise InterruptedError(f"Backup interrupted by signal {signum}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument("--config", required=True, type=Path)
    _ = parser.add_argument(
        "--force",
        action="store_true",
        help="Back up now, ignoring the two-hour interval and retry delay",
    )
    _ = parser.add_argument(
        "--verify",
        type=Path,
        metavar="SNAPSHOT",
        help="Verify a completed snapshot without changing it",
    )
    args = parser.parse_args(namespace=Arguments())
    try:
        if args.verify:
            count = verify_snapshot(args.verify)
            print(f"Snapshot verified: {count} files in {args.verify}")
            return 0
        settings = Settings.from_json(read_json(args.config))
        state_directory = Path(
            os.environ.get(
                "STATE_DIRECTORY", str(Path.home() / ".local/state/usb-backup")
            )
        )
        state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (state_directory / "lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            _ = signal.signal(signal.SIGTERM, interrupted)
            _ = signal.signal(signal.SIGINT, interrupted)
            return run(settings, state_directory / "state.json", args.force)
    except ERRORS as error:
        print(f"USB backup error: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
