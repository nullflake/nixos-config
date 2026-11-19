"""Build and search local NixOS package and option indexes; unstable is the default."""

import argparse
import fcntl
import json
import os
import re
import resource
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

from upstream import NIXOS_HOSTS, open_metadata, resolve_metadata_url, validate_url
from wcwidth import wcswidth

CHANNELS = {"unstable": "nixos-unstable", "stable": "nixos-26.05"}
DEFAULT_PACKAGE_SETS = ("kdePackages",)
DEFAULT_SEARCH_LIMIT = 20
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


def supports_color(stream):
    return (
        stream.isatty()
        and "NO_COLOR" not in os.environ
        and os.environ.get("TERM") != "dumb"
    )


def display_width(text):
    return max(0, wcswidth(text))


def wrap_cells(text, width):
    """Wrap words and long tokens by terminal cells, keeping combining marks."""
    lines = []
    line = ""
    for word in text.split():
        if line and display_width(f"{line} {word}") > width:
            lines.append(line)
            line = ""
        while display_width(word) > width:
            end = 0
            for position in range(1, len(word) + 1):
                if display_width(word[:position]) > width:
                    break
                end = position
            # A wide glyph cannot fit in a one-cell terminal column.
            if not end:
                lines.append("?")
                word = word[1:]
            else:
                lines.append(word[:end])
                word = word[end:]
        if word:
            line = f"{line} {word}" if line else word
    if line:
        lines.append(line)
    return lines or [""]


def wrap_balanced(text, width, limit=None):
    lines = wrap_cells(text, width)
    if limit is not None and len(lines) > limit:
        lines = lines[:limit]
        last = lines[-1]
        while display_width(last) >= width:
            last = last[:-1]
        lines[-1] = last.rstrip() + "…"
        text = " ".join(lines)
    if len(lines) == 1:
        return lines

    # Find the smallest width that fits the words in the same number of lines.
    minimum = max(map(display_width, text.split()))
    maximum = width
    line_count = len(lines)
    while minimum < maximum:
        middle = (minimum + maximum) // 2
        candidate = wrap_cells(text, middle)
        if len(candidate) > line_count:
            minimum = middle + 1
        else:
            maximum = middle
            lines = candidate
    return lines


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


def github_link(position: str, source: str, channel: str) -> str:
    if not position:
        return ""
    path, separator, line = position.rpartition(":")
    if not separator or not line.isdigit():
        path, line = position, ""
    # Release URLs identify the indexed revision, unlike a moving channel branch.
    revision = re.search(
        r"\.([0-9a-f]{7,40})/packages\.json\.br$", urllib.parse.urlsplit(source).path
    )
    reference = (revision.group(1) if revision else None) or CHANNELS.get(channel, channel)
    reference = urllib.parse.quote(reference, safe="")
    link = f"https://github.com/NixOS/nixpkgs/blob/{reference}/{urllib.parse.quote(path, safe='/')}"
    return f"{link}#L{line}" if line else link


def print_result_title(name, detail, color, width, name_width=0, *, stack_detail=False):
    reset = "\033[0m" if color else ""
    bold = "\033[1m" if color else ""
    name_style = "\033[1;32m" if color else ""
    name_lines = wrap_cells(name, width)
    for line in name_lines[:-1]:
        print(f"{name_style}{line}{reset}")

    last_name_line = name_lines[-1]
    name_cells = display_width(last_name_line)
    column = max(name_width, name_cells) + 2
    available = width - column
    title = f"{name_style}{last_name_line}{reset}"
    first_word = detail.split(maxsplit=1)
    if not first_word:
        print(title)
        return
    if not stack_detail and available >= max(1, display_width(first_word[0])):
        lines = wrap_cells(detail, available)
        padding = " " * (column - name_cells)
        print(f"{title}{padding}{bold}{lines[0]}{reset}")
        indent = " " * column
        lines = lines[1:]
    else:
        print(title)
        indent = " " * min(2, width - 1)
        lines = wrap_cells(detail, width - len(indent))
    for line in lines:
        print(f"{indent}{bold}{line}{reset}")


def print_compact_results(
    visible_results, result_color, terminal_width, *, description_limit=None, stack_detail=False
):
    terminal_output = sys.stdout.isatty()
    name_width = max((display_width(row[0]) for row in visible_results), default=0)
    indent = " " * min(2, terminal_width - 1)
    description_width = terminal_width - len(indent)
    muted = "\033[2m" if result_color else ""
    reset = "\033[0m" if result_color else ""
    for index, (name, detail, description) in enumerate(visible_results):
        if not terminal_output:
            if description_limit is not None:
                description = " ".join(wrap_balanced(description, terminal_width, description_limit))
            print(f"{name}\t{detail}\t{description}")
            continue
        if index:
            print()
        print_result_title(name, detail, result_color, terminal_width, name_width, stack_detail=stack_detail)
        if description:
            for line in wrap_balanced(description, description_width, description_limit):
                print(f"{indent}{muted}{line}{reset}")


def print_result_details(name, detail, fields, color, terminal_width, *, stack_detail=False):
    reset = "\033[0m" if color else ""
    muted = "\033[2m" if color else ""
    print_result_title(name, detail, color, terminal_width, stack_detail=stack_detail)

    def field(label, value, wrap=False):
        label = f"{label}:" if label else ""
        if terminal_width < 28:
            indent = " " * min(2, terminal_width - 1)
            width = max(1, terminal_width - len(indent))
            if label:
                for line in wrap_cells(label, width):
                    print(f"{indent}{line}")
            lines = wrap_cells(value, width) if wrap else [value]
            for line in lines:
                print(f"{indent}{muted}{line}{reset}")
            return
        indent = " " * 16
        lines = wrap_cells(value, max(1, terminal_width - 16)) if wrap else [value]
        print(f"  {label:<12}  {muted}{lines[0]}{reset}")
        for line in lines[1:]:
            print(f"{indent}{muted}{line}{reset}")

    for label, value, wrap in fields:
        field(label, value, wrap=wrap)
    print()


def print_details(row, source, channel, color, terminal_width):
    attr, version, description, homepages, position = row
    fields = [("Description", description or "Not provided", True)]
    links = json.loads(homepages)
    for number, link in enumerate(links):
        fields.append(("Homepage" if number == 0 else "", link, False))
    if not links:
        fields.append(("Homepage", "Not provided", True))
    fields.append(("Defined at", position or "Not provided", True))
    link = github_link(position, source, channel)
    if link:
        fields.append(("GitHub", link, False))
    print_result_details(attr, version, fields, color, terminal_width)


def option_rows(options, revisions):
    if not isinstance(options, dict) or not options:
        raise ValueError("expected a non-empty NixOS option catalog")
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


def refresh_unit(channel, release):
    suffix = "-stable" if channel == "stable" else ""
    return f"package-search-refresh{suffix}@{release}.service"


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
            if (
                metadata.get("source") != source
                or not required.issubset(columns)
                or not db.execute("SELECT 1 FROM packages LIMIT 1").fetchone()
                or not db.execute("SELECT 1 FROM options LIMIT 1").fetchone()
            ):
                return False
            home_manager = home_manager_metadata() if include_home_manager else {}
            if home_manager and (
                any(metadata.get(key) != value for key, value in home_manager.items())
                or not db.execute("SELECT 1 FROM home_manager_options LIMIT 1").fetchone()
            ):
                return False
        return True
    except sqlite3.Error:
        # Missing/obsolete schemas and damaged indexes need a full rebuild.
        return False


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
        with closing(sqlite3.connect(index.as_uri() + "?mode=rw", uri=True)) as db, db:
            db.execute(
                "INSERT OR REPLACE INTO metadata VALUES ('checked_at', ?)",
                (datetime.now(UTC).isoformat(timespec="seconds"),),
            )
    return True


def ensure_index(channel="unstable"):
    """Verify on every invocation and wait for the exact observed release."""
    source, release = channel_source(channel)
    if not confirm_index(channel, source):
        print(
            f"Updating {CHANNELS[channel]} package and option index to {release}...",
            file=sys.stderr,
        )
        unit = refresh_unit(channel, release)
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
    source = release_source(channel, release) if release else channel_source(channel)[0]
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "refresh.lock").open("a") as lock:
        # Other release workers for this channel must finish before replacing it.
        fcntl.flock(lock, fcntl.LOCK_EX)
        index = directory / "index.sqlite"
        if reuse_index(index, source):
            return 0

        # Build on the same filesystem so replacement is atomic for active readers.
        with tempfile.TemporaryDirectory(prefix="refresh-", dir=directory) as work:
            work = Path(work)
            target = work / "index.sqlite"
            if reuse_index(index, source, include_home_manager=False):
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


def print_index_header(metadata, channel, offline):
    use_color = supports_color(sys.stderr)
    reset = "\033[0m" if use_color else ""
    bold = "\033[1m" if use_color else ""
    muted = "\033[2m" if use_color else ""
    indexed = metadata.get("indexed_at")
    timestamp = (
        datetime.fromisoformat(indexed).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        if indexed
        else "unknown (legacy index)"
    )
    revision = re.search(
        r"\.([0-9a-f]{7,40})/packages\.json\.br$", metadata.get("source", "")
    )
    revision = revision.group(1) if revision else "unknown"
    checked = metadata.get("checked_at")
    checked = (
        datetime.fromisoformat(checked).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        if checked
        else "unknown"
    )
    check_label = (
        f"offline; freshness not checked (last check: {checked})"
        if offline
        else f"verified  {checked}"
    )
    header_width = max(1, shutil.get_terminal_size().columns)

    def header_line(text, style):
        lines = (
            wrap_cells(text, header_width)
            if display_width(text) > header_width
            else [text]
        )
        return "\n".join(f"{style}{line}{reset}" for line in lines)

    print(
        "\n"
        + header_line(f"[ {CHANNELS[channel]} ]", bold)
        + "\n"
        + header_line(f"revision  {revision}", muted)
        + "\n"
        + header_line(f"indexed   {timestamp}", muted)
        + "\n"
        + header_line(check_label, muted)
        + "\n"
        + f"{muted}{'─' * min(60, header_width)}{reset}",
        file=sys.stderr,
    )


def search(
    queries,
    limit,
    package_set=None,
    top_level=False,
    all_packages=False,
    channel="unstable",
    details=False,
    offline=False,
):
    index = cache_dir(channel) / "index.sqlite"
    terms = " ".join(queries).casefold().split()
    if not terms:
        raise ValueError("provide a non-empty search query")
    expected_source = None if offline else ensure_index(channel)
    if not index.is_file():
        raise ValueError(
            f"no saved {CHANNELS[channel]} index; run a search without --offline first"
        )
    with closing(sqlite3.connect(index.as_uri() + "?mode=ro", uri=True)) as db:
        metadata = dict(db.execute("SELECT key, value FROM metadata"))
        if expected_source is not None and metadata.get("source") != expected_source:
            raise ValueError("package index changed during verification; retry the search")
        fields = "attr, version, description"
        if details:
            columns = {
                column[1] for column in db.execute("PRAGMA table_info(packages)")
            }
            if not {"homepages", "position"}.issubset(columns):
                raise ValueError(
                    "saved index has no package details; run a search without --offline to update it"
                )
            fields += ", homepages, position"
        print_index_header(metadata, channel, offline)
        where = " AND ".join("instr(searchable, ?) > 0" for _ in terms)
        parameters = list(terms)
        if package_set is not None:
            # A literal attribute prefix: '%' and '_' are not SQL wildcards.
            prefix = package_set + "."
            where += " AND substr(attr, 1, length(?)) = ?"
            parameters.extend([prefix, prefix])
        elif top_level:
            where += " AND instr(attr, '.') = 0"
        elif not all_packages:
            scopes = ["instr(attr, '.') = 0"]
            for name in DEFAULT_PACKAGE_SETS:
                prefix = name + "."
                scopes.append("substr(attr, 1, length(?)) = ?")
                parameters.extend([prefix, prefix])
            where += " AND (" + " OR ".join(scopes) + ")"
        query = " ".join(terms)
        ranked_query = f"{package_set}.{query}".casefold() if package_set else query
        results = db.execute(
            f"SELECT {fields} FROM packages WHERE {where} "
            "ORDER BY CASE WHEN lower(attr) = ? THEN 0 WHEN instr(lower(attr), ?) = 1 THEN 1 ELSE 2 END, "
            "length(attr), attr LIMIT ?",
            [*parameters, ranked_query, ranked_query, limit + 1],
        ).fetchall()
    visible_results = results[:limit]
    terminal_width = max(1, shutil.get_terminal_size().columns)
    result_color = supports_color(sys.stdout)
    if details:
        for row in visible_results:
            print_details(row, metadata["source"], channel, result_color, terminal_width)
    else:
        print_compact_results(visible_results, result_color, terminal_width)
    print_result_limit(len(results), limit)
    if not results:
        print("No matching packages.", file=sys.stderr)
    return 0


def print_result_limit(count, limit, label=None):
    if count > limit:
        prefix = f"[{label}] " if label else ""
        print(
            f"{prefix}Showing the first {limit} results. Increase --limit to see more.",
            file=sys.stderr,
        )


def search_limit(value):
    number = int(value)
    if not 1 <= number < sys.maxsize:
        raise argparse.ArgumentTypeError("must be a positive result count within SQLite's integer range")
    return number


def package_set_name(value):
    value = value.strip()
    if not value or value.endswith("."):
        raise argparse.ArgumentTypeError(
            "provide a package set path without a trailing dot"
        )
    return value


def option_summary(description):
    description = re.sub(r"```.*?```", " ", description)
    description = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", description)
    description = re.sub(r"(?:\{[\w:-]+\})?`([^`]+)`", r"\1", description)
    return clean(description)


def search_options(arguments):
    parser = argparse.ArgumentParser(
        prog="nixctl search --options",
        description="Search local NixOS and Home Manager options.",
    )
    parser.add_argument("query", nargs="+", help="one or more search terms")
    parser.add_argument(
        "-l", "--limit", type=search_limit, default=DEFAULT_SEARCH_LIMIT,
        help=f"maximum results per source (default: {DEFAULT_SEARCH_LIMIT})",
    )
    scopes = parser.add_mutually_exclusive_group()
    scopes.add_argument("--nixos", action="store_true", help="show only NixOS options")
    scopes.add_argument("--home-manager", action="store_true", help="show only Home Manager options")
    channels = parser.add_mutually_exclusive_group()
    channels.add_argument("--stable", action="store_true", help="search the stable channel")
    channels.add_argument("-c", "--channel", choices=tuple(CHANNELS.values()))
    parser.add_argument("--offline", action="store_true", help="use the saved index")
    parser.add_argument("--details", action="store_true", help="show descriptions, defaults and source links")
    parser.add_argument("-j", "--json", action="store_true", help="output results as JSON")
    args = parser.parse_args(arguments)
    channel = "stable" if args.stable or args.channel == CHANNELS["stable"] else "unstable"
    query = " ".join(" ".join(args.query).casefold().split())
    if not query:
        raise ValueError("provide a non-empty search query")
    index = cache_dir(channel) / "index.sqlite"
    expected_source = None if args.offline else ensure_index(channel)
    if not index.is_file():
        raise ValueError(
            f"no saved {CHANNELS[channel]} index; run a search without --offline first"
        )
    with closing(sqlite3.connect(index.as_uri() + "?mode=ro", uri=True)) as db:
        metadata = dict(db.execute("SELECT key, value FROM metadata"))
        if expected_source is not None and metadata.get("source") != expected_source:
            raise ValueError("index changed during verification; retry the search")
        if expected_source is not None and not args.nixos and any(
            metadata.get(key) != value for key, value in home_manager_metadata().items()
        ):
            raise ValueError("Home Manager index changed during verification; retry the search")
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        terms = query.split()
        where = " AND ".join("instr(searchable, ?) > 0" for _ in terms)
        matches_name = " AND ".join("instr(lower(name), ?) > 0" for _ in terms)
        groups = []
        sources = [
            ("nixos", "NixOS", "options", not args.home_manager),
            ("home-manager", "Home Manager", "home_manager_options", not args.nixos),
        ]
        for scope, label, table, enabled in sources:
            if not enabled:
                continue
            if table not in tables:
                if scope == "home-manager" and not args.home_manager:
                    print("Saved index has no Home Manager options; run a search without --offline to update it.", file=sys.stderr)
                    continue
                raise ValueError(f"saved index has no {label} options; run a search without --offline to update it")
            rows = db.execute(
                f"SELECT name, type, description, default_value, declarations FROM {table} WHERE {where} "
                "ORDER BY CASE WHEN lower(name) = ? THEN 0 "
                "WHEN instr(lower(name), ?) = 1 THEN 1 "
                f"WHEN {matches_name} THEN 2 ELSE 3 END, "
                "name COLLATE NOCASE, name LIMIT ?",
                [*terms, query, query, *terms, args.limit + 1],
            ).fetchall()
            groups.append((scope, label, rows))

    home_manager_revision = json.loads(metadata.get("home_manager_revisions", "{}")).get(
        "nix-community/home-manager"
    )
    if args.json:
        print(json.dumps({
            "channel": CHANNELS[channel],
            **({"home_manager_revision": home_manager_revision} if not args.nixos else {}),
            "options": [
                {
                    "option_scope": scope,
                    "option_name": name,
                    "option_type": option_type,
                    "option_description": description,
                    "option_default": default,
                    "option_source": (json.loads(declarations) or [None])[0],
                }
                for scope, _, rows in groups
                for name, option_type, description, default, declarations in rows[:args.limit]
            ],
        }, indent=2))
        for _, label, rows in groups:
            print_result_limit(len(rows), args.limit, label)
        return 0

    print_index_header(metadata, channel, args.offline)
    width = max(1, shutil.get_terminal_size().columns)
    color = supports_color(sys.stdout)
    bold = "\033[1m" if color else ""
    muted = "\033[2m" if color else ""
    reset = "\033[0m" if color else ""
    for index, (scope, label, rows) in enumerate(groups):
        if index:
            print()
        print(f"{bold}[ {label} ]{reset}")
        if scope == "home-manager":
            revision = home_manager_revision[:12] if home_manager_revision else "unknown (legacy index)"
            print(f"{muted}revision  {revision}{reset}")
        if not rows:
            print("No matching options.")
            continue
        visible = rows[:args.limit]
        if not args.details:
            summaries = [(name, kind, option_summary(text)) for name, kind, text, *_ in visible]
            print_compact_results(summaries, color, width, description_limit=2, stack_detail=True)
        else:
            for name, option_type, description, default, declarations in visible:
                fields = [("Description", description or "Not provided", True)]
                if default is not None:
                    fields.append(("Default", default, True))
                for declaration in json.loads(declarations):
                    if isinstance(declaration, dict):
                        position, link = declaration["name"], declaration["url"]
                    else:
                        position = declaration
                        link = github_link(position, metadata["source"], channel) if scope == "nixos" else ""
                    fields.append(("Defined at", position, True))
                    if link:
                        fields.append(("GitHub", link, False))
                print_result_details(name, option_type, fields, color, width, stack_detail=True)
        print_result_limit(len(rows), args.limit, label)
    return 0


def main():
    if sys.argv[1:2] == ["options"]:
        try:
            return search_options(sys.argv[2:])
        except (OSError, KeyError, TypeError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
            print(f"NixOS option search error: {error}", file=sys.stderr)
            return 1

    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    refresh_parser = commands.add_parser(
        "refresh", help="download channel metadata and atomically rebuild the index"
    )
    refresh_parser.add_argument(
        "--stable",
        action="store_true",
        help=f"refresh {CHANNELS['stable']} instead of unstable",
    )
    refresh_parser.add_argument(
        "--release", help="internal: exact published release to index"
    )
    search_parser = commands.add_parser(
        "search",
        prog="nixctl search",
        help="search package attributes and descriptions (all terms must match)",
        description="Search unstable top-level packages and kdePackages by default; all query terms must match.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Index management (without a search query; optional --stable):\n"
            "  nixctl search --status              refresh service status\n"
            "  nixctl search --status --stable     stable refresh service status\n"
            "  nixctl search --logs                last 20 refresh log entries\n"
            "  nixctl search --logs --stable       last 20 stable refresh log entries\n\n"
            "NixOS and Home Manager options (local index):\n"
            "  nixctl search --options services.openssh --details\n"
            "  nixctl search --options zoxide --home-manager\n"
            "  nixctl search --options --help      show option search flags\n\n"
            "Each search verifies the published channel release and waits for updates.\n"
            "Use --offline explicitly to search saved metadata without verification.\n"
            "--all, --set and --top-level are mutually exclusive.\n\n"
            "Examples:\n"
            "  nixctl search firefox\n"
            "  nixctl search firefox --stable\n"
            "  nixctl search codex --details\n"
            "  nixctl search requests --all --limit 10\n"
            "  nixctl search requests --set python313Packages\n"
            "  nixctl search firefox --top-level"
        ),
    )
    search_parser.add_argument(
        "--offline",
        action="store_true",
        help="search saved metadata without checking freshness",
    )
    search_parser.add_argument("query", nargs="+", help="one or more search terms")
    search_parser.add_argument(
        "--details",
        action="store_true",
        help="show description, homepage and Nixpkgs source links in package blocks",
    )
    search_parser.add_argument(
        "--limit",
        type=search_limit,
        default=DEFAULT_SEARCH_LIMIT,
        help=f"maximum results (default: {DEFAULT_SEARCH_LIMIT})",
    )
    search_parser.add_argument(
        "--stable",
        action="store_true",
        help=f"search {CHANNELS['stable']} instead of unstable",
    )
    filters = search_parser.add_mutually_exclusive_group()
    filters.add_argument(
        "--set",
        dest="package_set",
        type=package_set_name,
        help="restrict to a package set attribute path, e.g. python313Packages",
    )
    filters.add_argument(
        "--top-level",
        action="store_true",
        help="exclude packages nested in package sets",
    )
    filters.add_argument(
        "--all",
        dest="all_packages",
        action="store_true",
        help="search all indexed packages, including every package set",
    )
    args = parser.parse_args()
    channel = "stable" if args.stable else "unstable"
    try:
        return (
            refresh(channel, args.release)
            if args.command == "refresh"
            else search(
                args.query,
                args.limit,
                args.package_set,
                args.top_level,
                args.all_packages,
                channel,
                args.details,
                args.offline,
            )
        )
    except (
        OSError,
        TypeError,
        ValueError,
        sqlite3.Error,
        subprocess.SubprocessError,
        urllib.error.URLError,
        TimeoutError,
    ) as error:
        print(f"Package index error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
