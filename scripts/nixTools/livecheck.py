"""Check direct flake inputs and independent pins without changing them."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
import urllib.parse
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from upstream import HELIUM_REPOSITORY, Upstream, release_revision, same_revision


@dataclass
class Result:
    name: str
    status: str
    detail: str
    compact: str | None = None


def discover_inputs(lock):
    """Discover root inputs only, checking shared follows targets once."""
    nodes = lock["nodes"]
    root = lock["root"]

    def resolve(reference, following=()):
        if isinstance(reference, str):
            return reference
        path = tuple(reference)
        if path in following:
            raise ValueError("cyclic input follows path")
        key = root
        for part in path:
            key = resolve(nodes[key]["inputs"][part], (*following, path))
        return key

    inputs = nodes[root].get("inputs", {})
    # Prefer concrete input names over follows aliases of the same node.
    entries = sorted(inputs.items(), key=lambda item: not isinstance(item[1], str))
    seen = {root}
    for name, reference in entries:
        key = resolve(reference)
        if key in seen:
            continue
        seen.add(key)
        yield name, nodes[key]


def github_repository(source):
    if source.get("type") == "github":
        if source.get("host", "github.com") != "github.com":
            return None
        return f"{source['owner']}/{source['repo']}"
    if source.get("type") == "git":
        url = urllib.parse.urlsplit(source.get("url", ""))
        if (
            url.scheme == "https"
            and url.hostname == "github.com"
            and not url.username
            and not url.password
        ):
            return url.path.strip("/").removesuffix(".git")
    return None


def compare_revision(client, name, repository, current, latest, target):
    transition = f"{current[:12]} -> {latest[:12]} ({target})"
    if same_revision(current, latest):
        return Result(name, "current", f"{current[:12]} ({target})")
    if repository:
        try:
            relation, ahead, behind = client.compare(repository, current, latest)
        except (OSError, TypeError, ValueError) as error:
            return Result(
                name, "changed", f"{transition}; commit count unavailable: {error}"
            )
        if relation == "ahead":
            unit = "commit" if ahead == 1 else "commits"
            return Result(name, "update", f"{ahead} {unit} behind; {transition}")
        if relation == "behind":
            unit = "commit" if behind == 1 else "commits"
            return Result(
                name, "ahead", f"{behind} {unit} ahead of {target}; {current[:12]}"
            )
        if relation == "diverged":
            return Result(
                name,
                "diverged",
                f"{ahead} upstream / {behind} local commits; {transition}",
            )
        return Result(name, "current", f"{current[:12]} ({target})")
    return Result(
        name, "changed", f"{transition}; commit count unavailable for this source"
    )


def check_input(client, name, node):
    source = node.get("original", {})
    locked = node.get("locked", {})
    kind = source.get("type")
    current = locked.get("rev", "")
    if kind == "path":
        return Result(name, "local", "local path; no upstream to check")
    if source.get("rev"):
        return Result(
            name,
            "pinned",
            f"explicit revision {source['rev'][:12]}; change the input to advance it",
        )
    repository = github_repository(source)
    if repository:
        if not current:
            raise ValueError("missing locked revision")
        ref = source.get("ref")
        latest = client.github_revision(repository, ref)
        result = compare_revision(
            client, name, repository, current, latest, ref or "default branch"
        )
        if repository.lower() == "nixos/nixpkgs" and result.status == "update":
            result.compact = "new revision"
            latest_date = client.github_revision_date(repository, latest)
            timestamp = locked.get("lastModified")
            if type(timestamp) is int and isinstance(latest_date, str):
                try:
                    current_date = (
                        datetime.fromtimestamp(timestamp, UTC).date().isoformat()
                    )
                except (ValueError, OverflowError, OSError):
                    pass
                else:
                    result.compact = (
                        f"{current_date} → {latest_date}"
                        if current_date != latest_date
                        else f"new revision · {latest_date}"
                    )
        return result
    if kind == "git":
        if not current:
            raise ValueError("missing locked revision")
        ref = source.get("ref")
        latest = client.git_revision(source["url"], ref)
        return compare_revision(
            client, name, None, current, latest, ref or "default branch"
        )
    if kind == "tarball":
        url = source.get("url", "")
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme == "https" and parsed.hostname == "channels.nixos.org":
            latest = release_revision(client.channel(url))
            current = current or release_revision(locked.get("url", ""))
            channel = parsed.path.strip("/").split("/")[0]
            return compare_revision(
                client, name, "NixOS/nixpkgs", current, latest, channel
            )
    raise ValueError(
        f"unsupported source type: {kind or 'unknown'}; upstream needs an explicit check"
    )


def check_helium(client, directory):
    with (directory / "pkgs/helium.json").open() as file:
        current = json.load(file)["version"]
    latest = client.release(HELIUM_REPOSITORY)["tag_name"]
    if not isinstance(current, str) or not current:
        raise ValueError("missing Helium version")
    if current == latest:
        return Result("helium", "current", current)
    if all(re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", value) for value in (current, latest)):
        first, second = [
            tuple(map(int, value.split("."))) for value in (current, latest)
        ]
        width = max(len(first), len(second))
        if first + (0,) * (width - len(first)) > second + (0,) * (width - len(second)):
            return Result("helium", "ahead", f"{current}; latest release is {latest}")
    return Result("helium", "update", f"{current} -> {latest}")


CHECK_ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)


def collect_results(directory, client):
    with (directory / "flake.lock").open() as file:
        inputs = list(discover_inputs(json.load(file)))
    inputs.append(("helium", None))
    inputs.sort(key=lambda item: (item[0] != "nixpkgs", item[0].casefold()))
    for name, node in inputs:
        try:
            result = (
                check_helium(client, directory)
                if node is None
                else check_input(client, name, node)
            )
        except CHECK_ERRORS as error:
            result = Result(name, "unknown", str(error))
        yield result


def clean(text):
    return " ".join("".join(c if c.isprintable() else " " for c in str(text)).split())


def notify_results(results, icon):
    updates = [
        result
        for result in results
        if result.status in {"update", "changed", "diverged"}
    ]
    failed = any(result.status == "unknown" for result in results)
    selected = [result for result in results if result.status != "current"]
    if updates:
        title = "System updates available"
    elif failed:
        title = "System update check incomplete"
    elif selected:
        title = "System update check complete"
    else:
        title = "System is up to date"
    try:
        subprocess.run(
            [
                "notify-send",
                "--app-name=nixctl",
                "--urgency=normal",
                "--icon",
                str(icon),
                "--",
                title,
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Notification unavailable: {clean(error)}", file=sys.stderr)


def result_detail(result):
    """Keep revisions out of the compact report without hiding failures."""
    if result.compact is not None:
        return result.compact
    detail = clean(result.detail).replace(" -> ", " → ")
    if result.status in {"current", "local"}:
        return ""
    if result.status == "pinned":
        return "explicit revision; change the input to advance it"
    if result.status == "changed":
        _, _, reason = detail.partition("; ")
        return "revision differs" + (f"; {reason}" if reason else "")
    if result.status in {"update", "diverged"}:
        return detail.split("; ", 1)[0]
    if result.status == "ahead" and result.name != "helium":
        return detail.split("; ", 1)[0]
    return detail


def report(directory, client, notification_icon=None, details=False):
    results = []
    width = max(1, shutil.get_terminal_size().columns)
    use_color = (
        sys.stdout.isatty()
        and "NO_COLOR" not in os.environ
        and os.environ.get("TERM") != "dumb"
    )
    styles = {
        "muted": "90",
        "current": "32",
        "update": "1;33",
        "changed": "33",
        "unknown": "1;31",
        "diverged": "1;33",
        "ahead": "36",
        "pinned": "90",
        "local": "90",
        "command": "36",
    }

    def paint(value, style=None):
        return f"\033[{styles[style]}m{value}\033[0m" if use_color and style else value

    def line(value, style=None, indent=0):
        padding = " " * min(indent, width - 1)
        for part in textwrap.wrap(clean(value), width=max(1, width - len(padding))):
            print(padding + paint(part, style), flush=True)

    def divider():
        print(paint("─" * min(60, width), "muted"), flush=True)

    print(flush=True)
    labels = {
        "current": "current",
        "update": "update",
        "changed": "changed",
        "unknown": "failed",
        "diverged": "diverged",
        "ahead": "ahead",
        "pinned": "pinned",
        "local": "local",
    }
    for result in collect_results(directory, client):
        results.append(result)
        name = clean(result.name)
        detail = result_detail(result)
        label = labels[result.status]
        name_width = max(16, len(name))
        heading_width = name_width + 2 + 8
        if heading_width <= width:
            heading = f"{name:<{name_width}}  {paint(f'{label:<8}', result.status)}"
            lines = textwrap.wrap(detail, width=max(1, width - heading_width - 2))
            if detail and heading_width + 3 <= width:
                print(f"{heading}  {lines[0]}", flush=True)
                for continuation in lines[1:]:
                    print(" " * (heading_width + 2) + continuation, flush=True)
            else:
                print(
                    f"{name:<{name_width}}  {paint(label, result.status)}", flush=True
                )
                line(detail, indent=2)
        else:
            line(name)
            line(label, result.status, indent=2)
            line(detail, indent=2)
        if details:
            expanded = clean(result.detail).replace(" -> ", " → ")
            if expanded != detail:
                if result.status in {
                    "update",
                    "diverged",
                    "ahead",
                } and expanded.startswith(detail + "; "):
                    expanded = expanded[len(detail) + 2 :]
                line(expanded, "muted", indent=2)

    updates = {"update", "changed", "diverged"}
    count = sum(result.status in updates for result in results)
    summary = [
        (
            f"{count} {'update' if count == 1 else 'updates'}",
            "update" if count else None,
        )
    ]
    for status, label in [
        ("current", "current"),
        ("ahead", "ahead"),
        ("pinned", "pinned"),
        ("local", "local"),
        ("unknown", "failed"),
    ]:
        total = sum(result.status == status for result in results)
        if total:
            summary.append((f"{total} {label}", status))
    divider()
    if len(" · ".join(text for text, _ in summary)) <= width:
        print(" · ".join(paint(text, style) for text, style in summary), flush=True)
    else:
        for text, style in summary:
            line(text, style)
    if count:
        if width >= len("Run: nixctl update"):
            print(
                f"{paint('Run:', 'muted')} {paint('nixctl update', 'command')}",
                flush=True,
            )
        else:
            line("Run:", "muted")
            line("nixctl update", "command", indent=2)
    print()
    if notification_icon is not None:
        notify_results(results, notification_icon)
    if any(result.status == "unknown" for result in results):
        print(
            "Some sources could not be checked; they are not reported as current.",
            file=sys.stderr,
        )
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser(
        prog="nixctl livecheck",
        description=__doc__,
        epilog="Discovers direct locked inputs automatically. No files are updated. GITHUB_TOKEN is optional.",
    )
    parser.add_argument(
        "--details",
        action="store_true",
        help="also show revisions, source references and nixpkgs commit counts",
    )
    parser.add_argument(
        "--notify-icon",
        type=Path,
        help="show a desktop notification after every check using this icon",
    )
    parser.add_argument(
        "--flake",
        type=Path,
        default=os.environ.get("FLAKE"),
        help="checkout directory (default: $FLAKE)",
    )
    args = parser.parse_args()
    if not args.flake:
        parser.error("$FLAKE is unset; provide --flake <directory>")
    try:
        return report(args.flake, Upstream(), args.notify_icon, args.details)
    except CHECK_ERRORS as error:
        print(f"Livecheck error: {clean(error)}", file=sys.stderr)
        if args.notify_icon is not None:
            notify_results(
                [Result("livecheck", "unknown", str(error))], args.notify_icon
            )
        return 1


if __name__ == "__main__":
    sys.exit(main())
