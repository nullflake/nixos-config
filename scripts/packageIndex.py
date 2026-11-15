"""Build and search local NixOS package indexes; unstable is the default."""

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

from wcwidth import wcswidth

CHANNELS = {"unstable": "nixos-unstable", "stable": "nixos-26.05"}
DEFAULT_PACKAGE_SETS = ("kdePackages",)
ALLOWED_HOSTS = frozenset({"channels.nixos.org", "releases.nixos.org"})
MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024
MAX_UNPACKED_BYTES = 1024 * 1024 * 1024


def validate_download_url(url):
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in ALLOWED_HOSTS
        or parsed.port not in {None, 443}
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ValueError("package metadata URL must use HTTPS on an allowed NixOS host")


class PackageRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Check every hop before connecting, not just the final response URL.
        try:
            validate_download_url(newurl)
        except ValueError:
            fp.close()
            raise
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_metadata(request, timeout):
    url = request.full_url if isinstance(request, urllib.request.Request) else request
    validate_download_url(url)
    opener = urllib.request.build_opener(PackageRedirectHandler())
    return opener.open(request, timeout=timeout)


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


def github_link(position, source, channel):
    if not position:
        return ""
    path, separator, line = position.rpartition(":")
    if not separator or not line.isdigit():
        path, line = position, ""
    # Release URLs identify the indexed revision, unlike a moving channel branch.
    revision = re.search(
        r"\.([0-9a-f]{7,40})/packages\.json\.br$", urllib.parse.urlsplit(source).path
    )
    reference = revision.group(1) if revision else CHANNELS[channel]
    link = f"https://github.com/NixOS/nixpkgs/blob/{reference}/{urllib.parse.quote(path, safe='/')}"
    return f"{link}#L{line}" if line else link


def print_package_title(attr, version, color, width):
    reset = "\033[0m" if color else ""
    green = "\033[1;32m" if color else ""
    bold = "\033[1m" if color else ""
    if display_width(attr) + display_width(version) + 2 <= width:
        print(f"{green}{attr}{reset}  {bold}{version}{reset}")
        return
    for line in wrap_cells(attr, width):
        print(f"{green}{line}{reset}")
    indent = " " * min(2, max(0, width - 1))
    for line in wrap_cells(version, max(1, width - len(indent))):
        print(f"{indent}{bold}{line}{reset}")


def print_details(row, source, channel, color, terminal_width):
    attr, version, description, homepages, position = row
    reset = "\033[0m" if color else ""
    muted = "\033[2m" if color else ""
    print_package_title(attr, version, color, terminal_width)

    def field(label, value, wrap=False):
        label = f"{label}:" if label else ""
        if terminal_width < 28:
            indent = " " * min(2, terminal_width - 1)
            width = max(1, terminal_width - len(indent))
            if label:
                for line in wrap_cells(label, width):
                    print(f"{indent}{muted}{line}{reset}")
            lines = wrap_cells(value, width) if wrap else [value]
            for line in lines:
                print(f"{indent}{line}")
            return
        indent = " " * 16
        lines = wrap_cells(value, max(1, terminal_width - 16)) if wrap else [value]
        print(f"  {muted}{label:<12}{reset}  {lines[0]}")
        for line in lines[1:]:
            print(f"{indent}{line}")

    field("Description", description or "Not provided", wrap=True)
    links = json.loads(homepages)
    for number, link in enumerate(links):
        field("Homepage" if number == 0 else "", link)
    if not links:
        field("Homepage", "Not provided", wrap=True)
    field("Defined at", position or "Not provided", wrap=True)
    link = github_link(position, source, channel)
    if link:
        field("GitHub", link)
    print()


def build_index(catalog, target, source):
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
        db.executemany(
            "INSERT INTO metadata VALUES (?, ?)",
            [
                ("refreshed_at", datetime.now(UTC).isoformat(timespec="seconds")),
                ("source", source),
            ],
        )
    return len(rows)


def reuse_index(index, source):
    """Reuse a complete index only when its immutable release URL matches."""
    if not index.is_file() or not re.search(
        r"\.[0-9a-f]{7,40}/packages\.json\.br$", urllib.parse.urlsplit(source).path
    ):
        return False
    try:
        with closing(sqlite3.connect(index.as_uri() + "?mode=rw", uri=True)) as db, db:
            metadata = dict(db.execute("SELECT key, value FROM metadata"))
            columns = {row[1] for row in db.execute("PRAGMA table_info(packages)")}
            required = {"attr", "version", "description", "searchable", "homepages", "position"}
            if (
                metadata.get("source") != source
                or not required.issubset(columns)
                or not db.execute("SELECT 1 FROM packages LIMIT 1").fetchone()
            ):
                return False
            # A successful check confirms freshness even if the channel has not moved.
            db.execute(
                "INSERT OR REPLACE INTO metadata VALUES ('refreshed_at', ?)",
                (datetime.now(UTC).isoformat(timespec="seconds"),),
            )
        release = PurePosixPath(urllib.parse.urlsplit(source).path).parent.name
        print(f"Already up to date: {release}. No download needed.")
        return True
    except sqlite3.Error:
        # Missing/obsolete schemas and damaged indexes need a full rebuild.
        return False


def check_refresh(channel="unstable"):
    """Return 0 when current, 10 when a background refresh is needed."""
    directory = cache_dir(channel)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "refresh.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Package index refresh is already running.", file=sys.stderr)
            return 75
        url = f"https://channels.nixos.org/{CHANNELS[channel]}/packages.json.br"
        try:
            response = open_metadata(
                urllib.request.Request(url, method="HEAD"), timeout=15
            )
        except urllib.error.HTTPError as error:
            if error.code not in {405, 501}:
                raise
            # Some servers do not implement HEAD; never read the fallback body.
            error.close()
            response = open_metadata(url, timeout=15)
        with response:
            if reuse_index(directory / "index.sqlite", response.geturl()):
                return 0
    return 10


def refresh(channel="unstable"):
    directory = cache_dir(channel)
    channel_name = CHANNELS[channel]
    source_url = f"https://channels.nixos.org/{channel_name}/packages.json.br"
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "refresh.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Package index refresh is already running.", file=sys.stderr)
            return 75

        # Build on the same filesystem so replacement is atomic for active readers.
        with tempfile.TemporaryDirectory(prefix="refresh-", dir=directory) as work:
            work = Path(work)
            compressed = work / "packages.json.br"
            with (
                open_metadata(source_url, timeout=120) as response,
                compressed.open("wb") as output,
            ):
                source = response.geturl()
                if reuse_index(directory / "index.sqlite", source):
                    return 0
                download_metadata(response, output)
            unpacked = work / "packages.json"
            with unpacked.open("wb") as output:
                subprocess.run(
                    ["brotli", "--decompress", "--stdout", str(compressed)],
                    stdout=output,
                    check=True,
                    timeout=120,
                    preexec_fn=limit_unpacked_file,
                )
            with unpacked.open() as input_file:
                catalog = json.load(input_file)
            target = work / "index.sqlite"
            count = build_index(catalog, target, source)
            os.replace(target, directory / "index.sqlite")
        print(f"Indexed {count} packages from {channel_name}.")
    return 0


def search(
    queries,
    limit,
    package_set=None,
    top_level=False,
    all_packages=False,
    channel="unstable",
    details=False,
):
    index = cache_dir(channel) / "index.sqlite"
    refresh_command = "nixctl search --refresh" + (
        " --stable" if channel == "stable" else ""
    )
    if not index.is_file():
        raise ValueError(
            f"no {CHANNELS[channel]} package index yet; run '{refresh_command}' and wait for the service to finish"
        )
    terms = " ".join(queries).casefold().split()
    if not terms:
        raise ValueError("provide a non-empty search query")
    with closing(sqlite3.connect(index.as_uri() + "?mode=ro", uri=True)) as db:
        metadata = dict(db.execute("SELECT key, value FROM metadata"))
        fields = "attr, version, description"
        if details:
            columns = {
                column[1] for column in db.execute("PRAGMA table_info(packages)")
            }
            if not {"homepages", "position"}.issubset(columns):
                raise ValueError(
                    f"this index does not contain package details yet; run '{refresh_command}' and wait for completion"
                )
            fields += ", homepages, position"
        refreshed = datetime.fromisoformat(metadata["refreshed_at"])
        age = datetime.now(UTC) - refreshed
        stale = (
            f" (older than 48 hours; run '{refresh_command}')"
            if age.total_seconds() > 172800
            else ""
        )
        use_color = supports_color(sys.stderr)
        reset = "\033[0m" if use_color else ""
        accent = "\033[1;36m" if use_color else ""
        muted = "\033[2m" if use_color else ""
        warning = "\033[1;33m" if use_color else ""
        timestamp = refreshed.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
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
            + header_line(f"[ {CHANNELS[channel]} ]", accent)
            + "\n"
            + header_line(f"refreshed  {timestamp}", muted)
            + "\n"
            + (header_line(stale.strip(), warning) + "\n" if stale else "")
            + f"{muted}{'─' * min(60, header_width)}{reset}",
            file=sys.stderr,
        )
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
    terminal_output = sys.stdout.isatty()
    result_color = supports_color(sys.stdout)
    attr_width = max((display_width(row[0]) for row in visible_results), default=0)
    version_width = max((display_width(row[1]) for row in visible_results), default=0)
    terminal_width = max(1, shutil.get_terminal_size().columns)
    description_column = attr_width + version_width + 4
    stacked_description = description_column >= terminal_width - 10
    if stacked_description:
        description_column = min(2, terminal_width - 1)
    description_width = max(1, terminal_width - description_column)
    for row in visible_results:
        if details:
            print_details(
                row, metadata["source"], channel, result_color, terminal_width
            )
            continue
        attr, version, description = row
        if not terminal_output:
            print(f"{attr}\t{version}\t{description}")
            continue
        lines = wrap_cells(description, description_width)
        indent = " " * description_column
        if stacked_description:
            # Drop table padding before wrapping the title in a narrow terminal.
            print_package_title(attr, version, result_color, terminal_width)
            for line in lines:
                print(f"{indent}{line}")
            continue
        attr_padding = " " * (attr_width - display_width(attr) + 2)
        version_padding = " " * (version_width - display_width(version) + 2)
        if result_color:
            attr = f"\033[1;32m{attr}\033[0m"
            version = f"\033[1m{version}\033[0m"
        prefix = f"{attr}{attr_padding}{version}"
        print(f"{prefix}{version_padding}{lines[0]}")
        for line in lines[1:]:
            print(f"{indent}{line}")
    if len(results) > limit:
        print(
            f"Showing first {limit} matches; narrow the query or use --limit N.",
            file=sys.stderr,
        )
    elif not results:
        print("No matching packages.", file=sys.stderr)
    return 0


def positive_int(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return number


def package_set_name(value):
    value = value.strip()
    if not value or value.endswith("."):
        raise argparse.ArgumentTypeError(
            "provide a package set path without a trailing dot"
        )
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check_parser = commands.add_parser(
        "check-refresh", help="check whether an index refresh is needed without downloading"
    )
    check_parser.add_argument("--stable", action="store_true")
    refresh_parser = commands.add_parser(
        "refresh", help="download channel metadata and atomically rebuild the index"
    )
    refresh_parser.add_argument(
        "--stable",
        action="store_true",
        help=f"refresh {CHANNELS['stable']} instead of unstable",
    )
    search_parser = commands.add_parser(
        "search",
        prog="nixctl search",
        help="search package attributes and descriptions (all terms must match)",
        description="Search unstable top-level packages and kdePackages by default; all query terms must match.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Index management (without a search query; optional --stable):\n"
            "  nixctl search --refresh             unstable\n"
            f"  nixctl search --refresh --stable    stable ({CHANNELS['stable']})\n\n"
            "  nixctl search --status              refresh service status\n"
            "  nixctl search --status --stable     stable refresh service status\n"
            "  nixctl search --logs                last 20 refresh log entries\n"
            "  nixctl search --logs --stable       last 20 stable refresh log entries\n\n"
            "Automatic refresh: both channels daily and after startup.\n"
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
    search_parser.add_argument("query", nargs="+", help="one or more search terms")
    search_parser.add_argument(
        "--details",
        action="store_true",
        help="show description, homepage and Nixpkgs source links in package blocks",
    )
    search_parser.add_argument(
        "--limit",
        type=positive_int,
        default=50,
        help="maximum number of results (default: 50)",
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
        if args.command == "check-refresh":
            return check_refresh(channel)
        return (
            refresh(channel)
            if args.command == "refresh"
            else search(
                args.query,
                args.limit,
                args.package_set,
                args.top_level,
                args.all_packages,
                channel,
                args.details,
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
