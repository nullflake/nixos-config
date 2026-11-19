"""Build and search local NixOS package and option indexes; unstable is the default."""

import argparse
import os
import sqlite3
import subprocess
import sys

from upstream import NIXOS_CHANNELS as CHANNELS

from .index import refresh, search_index
from .output import print_index_header, print_option_results, print_package_results
from .queries import (
    OptionGroup,
    PackageRow,
    query_option_catalogs,
    query_packages,
)

DEFAULT_SEARCH_LIMIT = 20
DEFAULT_OPTION_NAME_LIMIT = 40
SEARCH_ERRORS = (OSError, KeyError, TypeError, ValueError, sqlite3.Error, subprocess.SubprocessError)


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
    terms = " ".join(queries).casefold().split()
    if not terms:
        raise ValueError("provide a non-empty search query")

    def query(db: sqlite3.Connection) -> list[PackageRow]:
        return query_packages(
            db, terms, details, limit,
            package_set=package_set, top_level=top_level, all_packages=all_packages,
        )

    metadata, results = search_index(channel, offline, query)
    print_index_header(metadata, channel, offline)
    print_package_results(results, metadata, channel, limit, details)
    return 0


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


def add_option_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("query", nargs="+", help="one or more search terms")
    parser.add_argument(
        "-l", "--limit", type=search_limit,
        help=f"maximum results per source (default: {DEFAULT_OPTION_NAME_LIMIT} for names, "
        f"{DEFAULT_SEARCH_LIMIT} with --details or --json)",
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


def search_options(args: argparse.Namespace) -> int:
    limit = args.limit
    if limit is None:
        limit = DEFAULT_SEARCH_LIMIT if args.details or args.json else DEFAULT_OPTION_NAME_LIMIT
    channel = "stable" if args.stable or args.channel == CHANNELS["stable"] else "unstable"
    query = " ".join(" ".join(args.query).casefold().split())
    if not query:
        raise ValueError("provide a non-empty search query")

    def read_options(db: sqlite3.Connection) -> tuple[list[OptionGroup], bool]:
        return query_option_catalogs(
            db, query, limit, nixos_only=args.nixos, home_manager_only=args.home_manager
        )

    metadata, (groups, missing_home_manager) = search_index(
        channel, args.offline, read_options, verify_home_manager=not args.nixos
    )
    if missing_home_manager:
        print(
            "Saved index has no Home Manager options; run a search without --offline to update it.",
            file=sys.stderr,
        )
    print_option_results(
        groups,
        metadata,
        channel,
        limit,
        offline=args.offline,
        details=args.details,
        as_json=args.json,
        nixos_only=args.nixos,
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build the parser shared by search commands and index refresh workers."""
    parser = argparse.ArgumentParser(prog="package-index", description=__doc__)
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
    add_option_arguments(commands.add_parser(
        "options",
        prog="nixctl search --options",
        help="search NixOS and Home Manager options",
        description="Search local NixOS and Home Manager options. Both catalogs are searched by default.",
    ))
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
            "  nixctl search --options services.openssh --nixos --details\n"
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
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "options":
            return search_options(args)
        channel = "stable" if args.stable else "unstable"
        if args.command == "refresh":
            return refresh(channel, args.release)
        return search(
            args.query,
            args.limit,
            args.package_set,
            args.top_level,
            args.all_packages,
            channel,
            args.details,
            args.offline,
        )
    except BrokenPipeError:
        raise
    except SEARCH_ERRORS as error:
        heading = "NixOS option search error" if args.command == "options" else "Package index error"
        print(f"{heading}: {error}", file=sys.stderr)
        return 1


def run():
    try:
        status = main()
        sys.stdout.flush()
        return status
    except BrokenPipeError:
        # Prevent Python from retrying the failed flush during shutdown.
        with open(os.devnull, "wb") as sink:
            os.dup2(sink.fileno(), sys.stdout.fileno())
        return 0


if __name__ == "__main__":
    sys.exit(run())
