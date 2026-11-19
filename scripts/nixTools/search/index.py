"""Build, refresh and verify the local package and option indexes."""

import fcntl
import json
import os
import re
import resource
import sqlite3
import subprocess
import sys
import tempfile
import urllib.parse
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

from upstream import NIXOS_HOSTS, open_metadata, resolve_metadata_url, validate_url

CHANNELS = {"unstable": "nixos-unstable", "stable": "nixos-26.05"}
ALLOWED_HOSTS = NIXOS_HOSTS
MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024
MAX_UNPACKED_BYTES = 1024 * 1024 * 1024


def validate_download_url(url):
    validate_url(url, ALLOWED_HOSTS)


def download_metadata(response, output):
    length = response.headers.get("Content-Length")
    if length is not None and int(length) > MAX_DOWNLOAD_BYTES:
        raise ValueError("compressed package metadata exceeds the 256 MiB limit")
    total = 0
    while chunk := response.read(min(1024 * 1024, MAX_DOWNLOAD_BYTES - total + 1)):
        total += len(chunk)
        if total > MAX_DOWNLOAD_BYTES:
            raise ValueError("compressed package metadata exceeds the 256 MiB limit")
        output.write(chunk)


def limit_unpacked_file():
    # Applied only in the single-threaded decompressor child, before exec.
    _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    limit = MAX_UNPACKED_BYTES if hard == resource.RLIM_INFINITY else min(hard, MAX_UNPACKED_BYTES)
    resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))


def cache_dir(channel="unstable"):
    directory = (
        Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
        / "nix-package-search"
    )
    # Preserve the original unstable cache; version stable caches by release.
    return directory if channel == "unstable" else directory / CHANNELS[channel]


def clean(value):
    """Keep upstream metadata on one line and strip terminal control characters."""
    return " ".join("".join(c if c.isprintable() else " " for c in value).split())


def homepage_links(value):
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        return []
    return list(
        dict.fromkeys(
            clean(item) for item in value if isinstance(item, str) and clean(item)
        )
    )


def source_position(value):
    if not isinstance(value, str):
        return ""
    position = re.sub(r"^/nix/store/[^/]+/", "", clean(value))
    path, separator, line = position.rpartition(":")
    if not separator or not line.isdigit():
        path, line = position, ""
    if not path or path.startswith("/") or ".." in PurePosixPath(path).parts:
        return ""
    return f"{path}:{line}" if line else path


def option_rows(options, revisions):
    if not isinstance(options, dict) or not options:
        raise ValueError("expected a non-empty option catalog")
    for name, option in options.items():
        if not isinstance(option, dict):
            raise TypeError(f"invalid metadata for option {name}")
        name = clean(name)
        option_type = clean(option.get("type") or "unspecified")
        description = clean(option.get("description") or "")
        default = None
        if "default" in option:
            value = option["default"]
            if isinstance(value, dict) and isinstance(value.get("text"), str):
                value = value["text"]
            default = clean(value if isinstance(value, str) else json.dumps(value))
        declarations = []
        for declaration in option.get("declarations", []):
            if isinstance(declaration, dict):
                name_at_source = clean(declaration.get("name") or "").strip("<>")
                link = clean(declaration.get("url") or "")
                if name_at_source and link.startswith("https://github.com/"):
                    match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/blob/[^/]+/(.+)", link)
                    if match and (revision := revisions.get(match[1])):
                        link = f"https://github.com/{match[1]}/blob/{revision}/{match[2]}"
                    declarations.append({"name": name_at_source, "url": link})
            elif position := source_position(declaration):
                declarations.append(position)
        yield (
            name,
            option_type,
            description,
            default,
            json.dumps(declarations),
            f"{name} {description}".casefold(),
        )


def write_option_catalog(db, table, options, revisions):
    db.execute(f"DROP TABLE IF EXISTS {table}")
    db.execute(
        f"CREATE TABLE {table} (name TEXT PRIMARY KEY, type TEXT, description TEXT, "
        "default_value TEXT, declarations TEXT, searchable TEXT)"
    )
    db.executemany(f"INSERT INTO {table} VALUES (?, ?, ?, ?, ?, ?)", option_rows(options, revisions))


def home_manager_metadata():
    catalog = os.environ.get("NIXCTL_HOME_MANAGER_OPTIONS")
    if not catalog:
        return {}
    return {
        "home_manager_catalog": catalog,
        "home_manager_revisions": os.environ.get("NIXCTL_HOME_MANAGER_REVISIONS", "{}"),
    }


def write_home_manager_catalog(db):
    metadata = home_manager_metadata()
    if metadata:
        with Path(metadata["home_manager_catalog"]).open() as file:
            options = json.load(file)
        write_option_catalog(db, "home_manager_options", options, json.loads(metadata["home_manager_revisions"]))
        db.executemany("INSERT OR REPLACE INTO metadata VALUES (?, ?)", metadata.items())


def build_index(catalog, options, target, source):
    if not isinstance(catalog, dict):
        raise TypeError("channel package metadata must be an object")
    if catalog.get("version") != "2":
        raise ValueError("unsupported channel package metadata format")
    packages = catalog.get("packages")
    if not isinstance(packages, dict):
        raise TypeError("channel package list must be an object")
    if not packages:
        raise ValueError("channel package list is empty")

    rows = []
    for attr, package in packages.items():
        if not isinstance(package, dict) or not isinstance(attr, str):
            raise TypeError("invalid package entry type")
        if not attr:
            raise ValueError("package attribute must not be empty")
        version = package.get("version", "")
        meta = package.get("meta", {})
        if not isinstance(version, str) or not isinstance(meta, dict):
            raise TypeError(f"invalid metadata for {attr}")
        description = meta.get("description", "")
        if not isinstance(description, str):
            raise TypeError(f"invalid description for {attr}")
        attr, version, description = map(clean, (attr, version, description))
        homepages = json.dumps(homepage_links(meta.get("homepage")))
        position = source_position(meta.get("position"))
        rows.append(
            (
                attr,
                version,
                description,
                f"{attr} {description}".casefold(),
                homepages,
                position,
            )
        )

    with closing(sqlite3.connect(target)) as db, db:
        db.execute(
            "CREATE TABLE packages (attr TEXT PRIMARY KEY, version TEXT, description TEXT, searchable TEXT, homepages TEXT, position TEXT)"
        )
        db.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")
        db.executemany("INSERT INTO packages VALUES (?, ?, ?, ?, ?, ?)", rows)
        write_option_catalog(db, "options", options, {})
        write_home_manager_catalog(db)
        db.executemany(
            "INSERT INTO metadata VALUES (?, ?)",
            [
                ("indexed_at", datetime.now(UTC).isoformat(timespec="seconds")),
                ("checked_at", datetime.now(UTC).isoformat(timespec="seconds")),
                ("source", source),
            ],
        )
    return len(rows)


def release_source(channel, release):
    """Accept only release names that are safe systemd instances and URL segments."""
    if not re.fullmatch(r"nixos-[0-9][0-9A-Za-z.-]*\.[0-9a-f]{7,40}", release):
        raise ValueError("invalid package metadata release")
    branch = (
        "unstable" if channel == "unstable" else CHANNELS[channel].removeprefix("nixos-")
    )
    if channel == "stable" and not release.startswith(f"nixos-{branch}."):
        raise ValueError("package release does not belong to the selected stable channel")
    return f"https://releases.nixos.org/nixos/{branch}/{release}/packages.json.br"


def channel_source(channel):
    url = f"https://channels.nixos.org/{CHANNELS[channel]}/packages.json.br"
    source = resolve_metadata_url(url, opener=open_metadata)
    parts = urllib.parse.urlsplit(source).path.split("/")
    release = parts[-2] if len(parts) >= 2 else ""
    if release_source(channel, release) != source:
        raise ValueError("channel did not resolve to the selected channel's immutable release")
    return source, release


def refresh_unit(channel, release, *, repair=False):
    suffix = "-stable" if channel == "stable" else ""
    instance = f"repair-{release}" if repair else release
    return f"package-search-refresh{suffix}@{instance}.service"


def reuse_index(index, source, *, include_home_manager=True):
    """Reuse a complete index only when its immutable release URL matches."""
    if not index.is_file() or not re.search(
        r"\.[0-9a-f]{7,40}/packages\.json\.br$", urllib.parse.urlsplit(source).path
    ):
        return False
    try:
        with closing(sqlite3.connect(index.as_uri() + "?mode=ro", uri=True)) as db:
            metadata = dict(db.execute("SELECT key, value FROM metadata"))
            columns = {row[1] for row in db.execute("PRAGMA table_info(packages)")}
            required = {"attr", "version", "description", "searchable", "homepages", "position"}
            option_columns = "name, type, description, default_value, declarations, searchable"
            if (
                metadata.get("source") != source
                or not required.issubset(columns)
                or not db.execute("SELECT 1 FROM packages LIMIT 1").fetchone()
                or not db.execute(f"SELECT {option_columns} FROM options LIMIT 1").fetchone()
            ):
                return False
            home_manager = home_manager_metadata() if include_home_manager else {}
            if home_manager and (
                any(metadata.get(key) != value for key, value in home_manager.items())
                or not db.execute(f"SELECT {option_columns} FROM home_manager_options LIMIT 1").fetchone()
            ):
                return False
        return True
    except sqlite3.Error:
        # Missing/obsolete schemas and damaged indexes need a full rebuild.
        return False


def is_corrupt(error):
    code = getattr(error, "sqlite_errorcode", 0) & 0xFF
    return code in (sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_NOTADB)


def confirm_index(channel, source):
    """Record verification without racing an atomic replacement by a worker."""
    directory = cache_dir(channel)
    index = directory / "index.sqlite"
    if not index.is_file():
        return False
    with (directory / "refresh.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not reuse_index(index, source):
            return False
        try:
            with closing(sqlite3.connect(index.as_uri() + "?mode=rw", uri=True)) as db, db:
                db.execute(
                    "INSERT OR REPLACE INTO metadata VALUES ('checked_at', ?)",
                    (datetime.now(UTC).isoformat(timespec="seconds"),),
                )
        except sqlite3.DatabaseError as error:
            if not is_corrupt(error):
                raise
            return False
    return True


def ensure_index(channel="unstable", *, repair=False):
    """Verify on every invocation and wait for the exact observed release."""
    source, release = channel_source(channel)
    if repair or not confirm_index(channel, source):
        action = "Rebuilding" if repair else "Updating"
        print(
            f"{action} {CHANNELS[channel]} package and option index to {release}...",
            file=sys.stderr,
        )
        unit = refresh_unit(channel, release, repair=repair)
        result = subprocess.run(
            ["systemctl", "--user", "start", "--", unit],
            stdout=sys.stderr,
            timeout=960,
            check=False,
        )
        if result.returncode:
            raise ValueError(
                "index update failed; run 'nixctl search --logs"
                + (" --stable" if channel == "stable" else "")
                + "' for details. Use --offline explicitly to search the saved index"
            )
        if not confirm_index(channel, source):
            raise ValueError(
                "index does not match the checked release; retry the search"
            )
    return source


def read_index(channel, expected_source, query, *, verify_home_manager):
    index = cache_dir(channel) / "index.sqlite"
    if not index.is_file():
        raise ValueError(
            f"no saved {CHANNELS[channel]} index; run a search without --offline first"
        )
    with closing(sqlite3.connect(index.as_uri() + "?mode=ro", uri=True)) as db:
        metadata = dict(db.execute("SELECT key, value FROM metadata"))
        if expected_source is not None and metadata.get("source") != expected_source:
            raise ValueError("index changed during verification; retry the search")
        if expected_source is not None and verify_home_manager and any(
            metadata.get(key) != value for key, value in home_manager_metadata().items()
        ):
            raise ValueError("Home Manager index changed during verification; retry the search")
        return metadata, query(db)


def search_index(channel, offline, query, *, verify_home_manager=False):
    """Retry a read once after rebuilding an index that SQLite reports as corrupt."""
    source = None if offline else ensure_index(channel)
    try:
        return read_index(channel, source, query, verify_home_manager=verify_home_manager)
    except sqlite3.DatabaseError as error:
        if offline or not is_corrupt(error):
            raise

    source = ensure_index(channel, repair=True)
    return read_index(channel, source, query, verify_home_manager=verify_home_manager)


def load_catalog(source, work):
    compressed = work / PurePosixPath(urllib.parse.urlsplit(source).path).name
    with open_metadata(source, timeout=120) as response, compressed.open("wb") as output:
        if response.geturl() != source:
            raise ValueError("immutable metadata redirected to a different release")
        download_metadata(response, output)
    unpacked = compressed.with_suffix("")
    with unpacked.open("wb") as output:
        subprocess.run(
            ["brotli", "--decompress", "--stdout", str(compressed)],
            stdout=output,
            check=True,
            timeout=120,
            preexec_fn=limit_unpacked_file,
        )
    with unpacked.open() as input_file:
        return json.load(input_file)


def refresh(channel="unstable", release=None):
    directory = cache_dir(channel)
    channel_name = CHANNELS[channel]
    # Repair instances use the same service template but bypass index reuse.
    repair = False
    if release is not None and release.startswith("repair-"):
        release = release.removeprefix("repair-")
        repair = True
    source = release_source(channel, release) if release is not None else channel_source(channel)[0]
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "refresh.lock").open("a") as lock:
        # Other release workers for this channel must finish before replacing it.
        fcntl.flock(lock, fcntl.LOCK_EX)
        index = directory / "index.sqlite"
        if not repair and reuse_index(index, source):
            return 0

        # Build on the same filesystem so replacement is atomic for active readers.
        with tempfile.TemporaryDirectory(prefix="refresh-", dir=directory) as work:
            work = Path(work)
            target = work / "index.sqlite"
            if not repair and reuse_index(index, source, include_home_manager=False):
                with (
                    closing(sqlite3.connect(index.as_uri() + "?mode=ro", uri=True)) as old,
                    closing(sqlite3.connect(target)) as new,
                    new,
                ):
                    old.backup(new)
                    write_home_manager_catalog(new)
                message = f"Updated Home Manager options in the {channel_name} index."
            else:
                catalog = load_catalog(source, work)
                options = load_catalog(source.removesuffix("packages.json.br") + "options.json.br", work)
                count = build_index(catalog, options, target, source)
                message = f"Indexed {count} packages and {len(options)} options from {channel_name}."
            os.replace(target, index)
        print(message)
    return 0
