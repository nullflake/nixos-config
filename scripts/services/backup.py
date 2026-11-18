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
BACKUP_INTERVAL = 24 * 60 * 60
KEEP_SNAPSHOTS = 8
RETRY = 15 * 60
STATE_VERSION = 3
MANIFEST = ".backup-manifest.json"
COMPLETE = ".backup-complete"
OWNER_MARKER = ".backup-owner"
SEQUENCE = ".backup-sequence"
SNAPSHOT_FORMAT = "usb-backup-v1"
OWNER_TOKEN = f"{SNAPSHOT_FORMAT}\n"
STAGING = ".backup-staging"
STAGING_OWNER = ".owned-v1"
METADATA = {MANIFEST, COMPLETE, OWNER_MARKER, SEQUENCE}
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
    boot: str
    mount: list[JsonValue] | None
    last_success_elapsed: float
    last_success: float
    last_snapshot: str
    last_outcome: str
    last_detail: str
    retry_after_elapsed: float


@dataclass
class Arguments(argparse.Namespace):
    config: Path = Path(".")
    force: bool = False
    status: bool = False
    verify: str | None = None


class BackupPostponed(RuntimeError):
    """A configured source is currently mounted."""


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


def probe_volume(label: str) -> tuple[bool, Volume | None]:
    """Return whether the label exists and, if mounted, its volume."""
    devices = command_json(
        "lsblk", "--json", "--list", "--output", "LABEL,MAJ:MIN,DISK-SEQ"
    )
    matches = [d for d in records(devices, "blockdevices") if d.get("label") == label]
    if not matches:
        return False, None
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
    mounts = command_json(
        "findmnt", "--json", "--list", "--output", "TARGET,MAJ:MIN,ID"
    )
    matches = [m for m in records(mounts, "filesystems") if m.get("maj:min") == device]
    if not matches:
        return True, None
    if len(matches) != 1:
        raise RuntimeError("Backup volume has multiple mountpoints")
    if type(sequence) is not int or sequence <= 0:
        raise RuntimeError("Cannot determine the backup volume's disk sequence")
    target, mount_id = matches[0].get("target"), matches[0].get("id")
    if not isinstance(target, str) or not Path(target).is_absolute():
        raise ValueError("Backup volume must have an absolute mountpoint")
    if type(mount_id) is not int or mount_id <= 0:
        raise ValueError("Cannot determine the backup volume's mount ID")
    return True, Volume(Path(target), device, sequence, mount_id)


def connection_identity(
    settings: Settings, volume: Volume, current_boot: str
) -> list[JsonValue]:
    return [
        current_boot,
        volume.device,
        volume.disk_sequence,
        volume.mount_id,
        settings.identity(),
    ]


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


def snapshot_name_time(name: str, timezone: dt.tzinfo = dt.UTC) -> dt.datetime | None:
    try:
        return dt.datetime.strptime(name, STAMP).replace(tzinfo=timezone)
    except ValueError:
        try:
            return dt.datetime.strptime(name, LEGACY_STAMP).replace(tzinfo=dt.UTC)
        except ValueError:
            return None


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


def remove_pending(pending: Path) -> None:
    if pending.is_symlink():
        raise RuntimeError(f"Backup staging path is a symlink: {pending}")
    if pending.exists():
        shutil.rmtree(pending)


def prepare_staging(destination: Path) -> Path:
    staging = destination / STAGING
    staging.mkdir(mode=0o700, exist_ok=True)
    if staging.is_symlink() or not staging.is_dir():
        raise ValueError(f"Expected an ordinary backup staging directory: {staging}")
    owner = staging / STAGING_OWNER
    if not owner.is_dir() or owner.is_symlink():
        if any(staging.iterdir()):
            raise ValueError(f"Backup staging directory has no owner: {staging}")
        # An interruption during setup can leave an empty staging root.
        owner.mkdir()
    pending = staging / "pending"
    remove_pending(pending)
    for path in destination.iterdir():
        if (
            path.name.startswith(".incomplete-")
            and not path.is_symlink()
            and path.is_dir()
            and marker_matches(path / OWNER_MARKER, OWNER_TOKEN)
        ):
            # Keep the ownership marker outside the tree being deleted.
            _ = path.rename(pending)
            remove_pending(pending)
    return pending


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


def snapshot_sequence(path: Path) -> int:
    try:
        value = read_json(path / SEQUENCE, limit=128)
    except FileNotFoundError:
        return 0
    if type(value) is not int or value <= 0:
        raise ValueError(f"Invalid snapshot sequence: {path}")
    return value


def prune(destination: Path, pending: Path, newest: Path) -> None:
    snapshots: list[tuple[int, dt.datetime, Path]] = []
    for path in destination.iterdir():
        if snapshot_name_time(path.name) is None:
            continue
        if path.is_symlink() or not path.is_dir():
            raise ValueError(f"Unexpected snapshot path: {path}")
        if not marker_matches(path / COMPLETE, "1\n"):
            raise ValueError(f"Snapshot is incomplete: {path}")
        manifest = read_manifest(path)
        stamp = dt.datetime.fromisoformat(manifest["created_utc"])
        snapshots.append((snapshot_sequence(path), stamp, path))
    # Keep the just-written snapshot even if the wall clock moved backwards.
    snapshots.sort(
        key=lambda item: (item[2] == newest, *item), reverse=True
    )
    if len(snapshots) <= KEEP_SNAPSHOTS:
        return
    for _, _, path in snapshots[:KEEP_SNAPSHOTS]:
        # take_snapshot already verified the new copy before publishing it.
        if path != newest:
            _ = verify_snapshot(path)
    for _, _, path in reversed(snapshots[KEEP_SNAPSHOTS:]):
        _ = path.rename(pending)
        remove_pending(pending)


def mounted_veracrypt_volumes(auxiliary_count: int) -> tuple[Path, ...]:
    unknown = "Cannot identify all mounted VeraCrypt volumes; dismount them first"
    try:
        result = subprocess.run(
            ["veracrypt", "-t", "--non-interactive", "--verbose", "--list"],
            capture_output=True,
            check=True,
            text=True,
            timeout=10,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError, UnicodeError) as error:
        raise BackupPostponed(unknown) from error

    volumes: dict[str, Path] = {}
    for record in result.stdout.strip("\n").split("\n\n"):
        lines = record.split("\n", 3)
        if len(lines) != 4 or not lines[2].startswith("Virtual Device:"):
            raise BackupPostponed(unknown)
        slot = lines[0].removeprefix("Slot: ")
        path = Path(lines[1].removeprefix("Volume: "))
        if (
            not lines[0].startswith("Slot: ")
            or not slot.isdecimal()
            or not lines[1].startswith("Volume: ")
            or not path.is_absolute()
            or volumes.setdefault(slot, path) != path
        ):
            raise BackupPostponed(unknown)

    # VeraCrypt skips auxiliary mounts whose control files it cannot read.
    if len(volumes) != auxiliary_count:
        raise BackupPostponed(unknown)
    return tuple(volumes.values())


def require_unmounted(settings: Settings) -> None:
    containers = [settings.home / path for path in settings.container_paths]
    required = {(settings.home / path).resolve() for path in settings.unmounted_paths}
    veracrypt_mounts: set[Path] = set()
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
                raise BackupPostponed(f"Unmount {path} before backing up")
            if containers and (
                mount.get("fstype") == "fuse.veracrypt"
                or path.name.startswith(".veracrypt_aux_mnt")
            ):
                veracrypt_mounts.add(path)
    if not containers:
        return
    identities: set[tuple[int, int]] = set()
    for path in containers:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"Encrypted container is not a regular file: {path}")
        identities.add((info.st_dev, info.st_ino))
    resolved = {p.resolve() for p in containers}
    if veracrypt_mounts:
        # The loop device may be backed by the auxiliary FUSE file instead
        # of the original container, so use VeraCrypt's own volume list.
        for path in mounted_veracrypt_volumes(len(veracrypt_mounts)):
            try:
                real_path = path.resolve(strict=True)
                info = real_path.stat()
            except OSError as error:
                raise BackupPostponed(
                    "Cannot identify a mounted VeraCrypt volume; dismount it first"
                ) from error
            if real_path in resolved or (info.st_dev, info.st_ino) in identities:
                raise BackupPostponed(f"Encrypted container is mounted: {real_path}")

    loops = command_json("losetup", "--json", "--list", "--output", "BACK-FILE")
    for loop in records(loops, "loopdevices"):
        name = loop.get("back-file")
        if not isinstance(name, str) or not name:
            raise RuntimeError("Cannot determine a loop device's backing file")
        path = Path(name)
        if path.resolve() in resolved:
            raise BackupPostponed(f"Encrypted container is mounted: {path}")
        try:
            info = path.stat()
        except FileNotFoundError:
            continue  # An unrelated backing file may have been deleted.
        if (info.st_dev, info.st_ino) in identities:
            raise BackupPostponed(f"Encrypted container is mounted: {path}")


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


def verify_latest(settings: Settings) -> tuple[Path, int]:
    present, volume = probe_volume(settings.label)
    if volume is None:
        reason = "not mounted" if present else "not found"
        raise RuntimeError(f"Drive {settings.label!r}: {reason}")

    with mounted_directory(volume):
        destination = settings.destination
        if not os.path.lexists(destination) and settings.legacy_destination is not None:
            destination = settings.legacy_destination
        for path in (destination, *destination.parents):
            if path.is_symlink():
                raise ValueError(f"Backup directory is a symlink: {path}")
        if not destination.is_dir():
            raise ValueError(f"No backup directory at {volume.target / destination}")
        candidates: list[tuple[int, dt.datetime, Path]] = []
        for path in destination.iterdir():
            stamp = snapshot_name_time(path.name, settings.timezone)
            if stamp is not None:
                sequence = (
                    snapshot_sequence(path) if not path.is_symlink() and path.is_dir() else 0
                )
                candidates.append((sequence, stamp, path))
        if not candidates:
            raise ValueError(f"No snapshots found in {volume.target / destination}")
        _, _, snapshot = max(candidates)
        print(f"Verifying snapshot: {volume.target / snapshot}", flush=True)
        return volume.target / snapshot, verify_snapshot(snapshot)


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


def take_snapshot(settings: Settings) -> tuple[Path, Path]:
    require_unmounted(settings)
    before = inventory(settings.home, settings.paths)
    # Check before creating or migrating the destination inside a selected tree.
    destination = settings.destination
    for relative in settings.paths:
        source = settings.home / relative
        if source.is_dir() and destination.resolve().is_relative_to(source.resolve()):
            raise ValueError("Backup destination must not be inside a selected source")
    destination = prepare_destination(settings)
    temporary = prepare_staging(destination)
    sequence = max(
        (
            snapshot_sequence(path)
            for path in destination.iterdir()
            if snapshot_name_time(path.name) is not None
            and not path.is_symlink()
            and path.is_dir()
        ),
        default=0,
    ) + 1
    require_space(destination, before)
    temporary.mkdir(mode=0o700)
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
        write_json(temporary / SEQUENCE, sequence)
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
        try:
            remove_pending(temporary)
        except ERRORS as error:
            print(
                f"Staging cleanup failed; recovery will retry later: {error}",
                file=sys.stderr,
                flush=True,
            )
    return final, temporary


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


def load_state(path: Path, current_boot: str) -> BackupState:
    try:
        state = read_json(path, limit=1024 * 1024)
        if (
            not isinstance(state, dict)
            or type(state.get("version")) is not int
            or state.get("version") not in (2, STATE_VERSION)
        ):
            raise ValueError("Unknown state format")
        validated: BackupState = {"version": STATE_VERSION}
        last_success = state.get("last_success")
        if (
            isinstance(last_success, (int, float))
            and not isinstance(last_success, bool)
            and 0 <= last_success < dt.datetime(9999, 12, 30, tzinfo=dt.UTC).timestamp()
        ):
            validated["last_success"] = float(last_success)
            if state.get("version") == 2:
                validated["last_outcome"] = "success"
        snapshot = state.get("last_snapshot")
        if isinstance(snapshot, str) and snapshot_name_time(snapshot) is not None:
            validated["last_snapshot"] = snapshot
        outcome = state.get("last_outcome")
        if outcome in ("success", "deferred", "error"):
            validated["last_outcome"] = outcome
        detail = state.get("last_detail")
        if isinstance(detail, str):
            validated["last_detail"] = detail
        mount = state.get("mount")
        saved_boot = state.get("boot")
        if state.get("version") == 2 and isinstance(mount, list) and mount:
            saved_boot = mount[0]
        if saved_boot == current_boot and (mount is None or isinstance(mount, list)):
            now = elapsed()
            validated["boot"] = current_boot
            validated["mount"] = mount
            successful = state.get("last_success_elapsed")
            retry = state.get("retry_after_elapsed")
            if (
                isinstance(successful, (int, float))
                and not isinstance(successful, bool)
                and 0 <= successful <= now
            ):
                validated["last_success_elapsed"] = float(successful)
            if (
                isinstance(retry, (int, float))
                and not isinstance(retry, bool)
                and 0 <= retry <= now + RETRY
            ):
                validated["retry_after_elapsed"] = float(retry)
        return validated
    except FileNotFoundError:
        return {}
    except (ValueError, UnicodeError):
        print(
            "Ignoring invalid or obsolete backup state", file=sys.stderr, flush=True
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


def scheduled_wait(
    state: BackupState, identity: list[JsonValue] | None, now: float
) -> tuple[str, float] | None:
    if state.get("mount") == identity:
        retry = state.get("retry_after_elapsed", 0)
        if now < retry:
            return "Retry scheduled", retry - now
        success = state.get("last_success_elapsed")
        if success is not None and now < success + BACKUP_INTERVAL:
            return "Normal interval", success + BACKUP_INTERVAL - now
    return None


def show_status(settings: Settings, state_path: Path) -> int:
    current_boot = boot_id()
    state = load_state(state_path, current_boot)
    success = state.get("last_success")
    if success is None:
        print("Last successful backup: no record")
    else:
        stamp = dt.datetime.fromtimestamp(success, settings.timezone)
        difference = time.time() - success
        duration = dt.timedelta(seconds=int(abs(difference)))
        age = f"{duration} ago" if difference >= 0 else f"{duration} in the future"
        local_time = stamp.isoformat(sep=" ", timespec="seconds")
        print(f"Last successful backup: {local_time} ({age})")
        if "last_snapshot" in state:
            print(f"Snapshot: {state['last_snapshot']}")
        print("Verification at backup time: completed")
    print("Snapshot verification in this query: not performed (use --verify latest)")

    outcomes = {"success": "successful", "deferred": "postponed", "error": "failed"}
    print(f"Last attempt: {outcomes.get(state.get('last_outcome', ''), 'no record')}")
    if detail := state.get("last_detail"):
        print(f"Details: {detail}")

    try:
        present, volume = probe_volume(settings.label)
    except ERRORS as error:
        print(f"Drive {settings.label!r}: detection failed ({error})")
        return 1
    if volume is None:
        drive_status = "present, not mounted" if present else "not found"
        print(f"Drive {settings.label!r}: {drive_status}")
        print("Schedule: waiting for a mounted drive")
        return 0

    print(f"Drive {settings.label!r}: mounted at {volume.target}")
    identity = connection_identity(settings, volume, current_boot)
    wait = scheduled_wait(state, identity, elapsed())
    if wait is None:
        print("Schedule: no active wait")
    else:
        reason, remaining = wait
        print(f"Schedule: {reason} ({dt.timedelta(seconds=int(remaining))} remaining)")
    return 0


def run(settings: Settings, state_path: Path, force: bool) -> int:
    now = elapsed()
    current_boot = boot_id()
    state: BackupState = load_state(state_path, current_boot)
    identity: list[JsonValue] | None = None
    snapshot = None
    try:
        _, volume = probe_volume(settings.label)
        if volume is None:
            if "mount" in state:
                del state["mount"]
                _ = state.pop("boot", None)
                _ = state.pop("last_success_elapsed", None)
                _ = state.pop("retry_after_elapsed", None)
                save_state(state_path, state)
            return 0
        identity = connection_identity(settings, volume, current_boot)
        if not force and scheduled_wait(state, identity, now) is not None:
            return 0
        warning = None
        with mounted_directory(volume):
            snapshot, pending = take_snapshot(settings)
            state = {
                "boot": current_boot,
                "mount": identity,
                "last_success_elapsed": elapsed(),
                "last_success": time.time(),
                "last_snapshot": snapshot.name,
                "last_outcome": "success",
            }
            save_state(state_path, state)
            try:
                prune(snapshot.parent, pending, snapshot)
                flush_volume()
            except ERRORS as error:
                warning = f"Backup saved, but old-backup cleanup failed: {error}"
                print(warning, file=sys.stderr, flush=True)
                state["last_detail"] = warning
                save_state(state_path, state)
        print(f"Backup complete: {volume.target / snapshot}", flush=True)
        notify(
            warning or "Selected files were backed up and verified successfully.",
            bool(warning),
        )
        return 0
    except ERRORS as error:
        if snapshot is not None:
            raise
        if (
            identity is None
            and not force
            and scheduled_wait(state, identity, now) is not None
        ):
            return 0
        postponed = isinstance(error, BackupPostponed)
        _ = state.pop("last_success_elapsed", None)
        state.update(
            boot=current_boot,
            mount=identity,
            retry_after_elapsed=elapsed() + RETRY,
            last_outcome="deferred" if postponed else "error",
            last_detail=str(error),
        )
        save_state(state_path, state)
        if postponed:
            print(f"Backup postponed: {error}", flush=True)
            notify(f"Backup postponed: {error}")
            return 0
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
    parser = argparse.ArgumentParser(prog="usb-backup", description=__doc__)
    _ = parser.add_argument("--config", required=True, type=Path, help=argparse.SUPPRESS)
    action = parser.add_mutually_exclusive_group()
    _ = action.add_argument(
        "--force",
        action="store_true",
        help="Back up now, ignoring the 24-hour interval and retry delay",
    )
    _ = action.add_argument(
        "--status",
        action="store_true",
        help="Report recorded backup results and current drive status (read-only)",
    )
    _ = action.add_argument(
        "--verify",
        metavar="SNAPSHOT",
        help="Verify a snapshot by path or use 'latest' for the newest on the backup drive",
    )
    args = parser.parse_args(namespace=Arguments())
    try:
        if args.verify is not None and args.verify != "latest":
            snapshot = Path(args.verify)
            count = verify_snapshot(snapshot)
            print(f"Snapshot verified: {count} files in {snapshot}")
            return 0
        settings = Settings.from_json(read_json(args.config))
        if args.verify == "latest":
            snapshot, count = verify_latest(settings)
            print(f"Snapshot verified: {count} files in {snapshot}")
            return 0
        state_home = Path(os.environ.get("XDG_STATE_HOME", ""))
        if not state_home.is_absolute():
            state_home = Path.home() / ".local/state"
        state_directory = Path(
            os.environ.get("STATE_DIRECTORY") or state_home / "usb-backup"
        ).absolute()
        state_path = state_directory / "state.json"
        if args.status:
            return show_status(settings, state_path)
        state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (state_directory / "lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            _ = signal.signal(signal.SIGTERM, interrupted)
            _ = signal.signal(signal.SIGINT, interrupted)
            return run(settings, state_path, args.force)
    except ERRORS as error:
        print(f"USB backup error: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
