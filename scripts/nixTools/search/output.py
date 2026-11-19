"""Render search results for terminals, pipes and JSON consumers."""

import json
import os
import re
import shutil
import sys
import urllib.parse
from datetime import datetime

from wcwidth import wcswidth

from .index import CHANNELS

RELEASE_REVISION = re.compile(r"\.([0-9a-f]{7,40})/(?:packages|options)\.json\.br$")


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


def github_link(position: str, source: str, channel: str) -> str:
    if not position:
        return ""
    path, separator, line = position.rpartition(":")
    if not separator or not line.isdigit():
        path, line = position, ""
    # Release URLs identify the indexed revision, unlike a moving channel branch.
    revision = RELEASE_REVISION.search(urllib.parse.urlsplit(source).path)
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
    for name, detail, description in visible_results:
        if not terminal_output:
            if description_limit is not None:
                description = " ".join(wrap_balanced(description, terminal_width, description_limit))
            print(f"{name}\t{detail}\t{description}")
            continue
        print_result_title(name, detail, result_color, terminal_width, name_width, stack_detail=stack_detail)
        if description:
            for line in wrap_balanced(description, description_width, description_limit):
                print(f"{indent}{muted}{line}{reset}")


def print_result_details(
    name, detail, fields, color, terminal_width, *, stack_detail=False, trailing_blank=True
):
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
    if trailing_blank:
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


def index_separator(width, max_width=60):
    return "─" * min(max_width, width)


def print_index_header(
    metadata, channel, offline, *, nixos_label="revision", home_manager_revision=None
):
    use_color = supports_color(sys.stderr)
    reset = "\033[0m" if use_color else ""
    cyan = "\033[1;36m" if use_color else ""
    muted = "\033[2m" if use_color else ""
    indexed = metadata.get("indexed_at")
    timestamp = (
        datetime.fromisoformat(indexed).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        if indexed
        else "unknown (legacy index)"
    )
    revision = RELEASE_REVISION.search(metadata.get("source", ""))
    revision = revision.group(1) if revision else "unknown"
    checked = metadata.get("checked_at")
    checked = (
        datetime.fromisoformat(checked).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        if checked
        else "unknown"
    )
    label_width = len("Home Manager revision") if home_manager_revision is not None else len(nixos_label)
    check_label = (
        f"offline; freshness not checked (last check: {checked})"
        if offline
        else f"{'verified':<{label_width}}  {checked}"
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
        + header_line(f"[ {CHANNELS[channel]} ]", cyan)
        + "\n"
        + (
            header_line(f"{nixos_label:<{label_width}}  {revision}", muted) + "\n"
            if nixos_label else ""
        )
        + (
            header_line(f"Home Manager revision  {home_manager_revision}", muted) + "\n"
            if home_manager_revision is not None
            else ""
        )
        + header_line(f"{'indexed':<{label_width}}  {timestamp}", muted)
        + "\n"
        + header_line(check_label, muted)
        + "\n"
        + f"{muted}{index_separator(header_width)}{reset}",
        file=sys.stderr,
    )


def print_result_limit(count, limit, label=None):
    if count > limit:
        prefix = f"[{label}] " if label else ""
        print(
            f"{prefix}Showing the first {limit} results. Increase --limit to see more.",
            file=sys.stderr,
        )


def print_package_results(results, metadata, channel, limit, details):
    visible_results = results[:limit]
    terminal_width = max(1, shutil.get_terminal_size().columns)
    result_color = supports_color(sys.stdout)
    if details:
        for row in visible_results:
            print_details(row, metadata["source"], channel, result_color, terminal_width)
    else:
        print_compact_results(visible_results, result_color, terminal_width)
        if len(results) > limit:
            sys.stdout.flush()
            print(file=sys.stderr)
    print_result_limit(len(results), limit)
    if not results:
        print("No matching packages.", file=sys.stderr)


def print_option_results(groups, metadata, channel, limit, *, offline, details, as_json, nixos_only):
    home_manager_revision = json.loads(metadata.get("home_manager_revisions", "{}")).get(
        "nix-community/home-manager"
    )
    if not as_json:
        revision = None
        if any(scope == "home-manager" for scope, _, _ in groups):
            revision = home_manager_revision[:12] if home_manager_revision else "unknown (legacy index)"
        print_index_header(
            metadata, channel, offline,
            nixos_label="NixOS revision" if "source" in metadata else "",
            home_manager_revision=revision,
        )
    if not as_json and not details:
        show_groups = len(groups) > 1
        color = supports_color(sys.stderr)
        cyan = "\033[1;36m" if color else ""
        muted = "\033[2m" if color else ""
        reset = "\033[0m" if color else ""
        for index, (_, label, rows) in enumerate(groups):
            if show_groups:
                if index:
                    width = max(1, shutil.get_terminal_size().columns)
                    print(f"{muted}{index_separator(width, max_width=40)}{reset}", file=sys.stderr)
                print(f"{cyan}[ {label} ]{reset}", file=sys.stderr)
                if not rows:
                    print("No matching options.", file=sys.stderr)
            for name, *_ in rows[:limit]:
                print(name)
            if show_groups or len(rows) > limit:
                sys.stdout.flush()
            if len(rows) > limit:
                print(file=sys.stderr)
            print_result_limit(len(rows), limit, label)
        return

    if as_json:
        print(json.dumps({
            "channel": CHANNELS[channel],
            **({"home_manager_revision": home_manager_revision} if not nixos_only else {}),
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
                for name, option_type, description, default, declarations in rows[:limit]
            ],
        }, indent=2))
        for _, label, rows in groups:
            print_result_limit(len(rows), limit, label)
        return

    width = max(1, shutil.get_terminal_size().columns)
    color = supports_color(sys.stdout)
    cyan = "\033[1;36m" if color else ""
    muted = "\033[2m" if color else ""
    reset = "\033[0m" if color else ""
    for index, (scope, label, rows) in enumerate(groups):
        if index:
            print(f"{muted}{index_separator(width, max_width=40)}{reset}")
        print(f"{cyan}[ {label} ]{reset}")
        if not rows:
            print("No matching options.")
            continue
        visible = rows[:limit]
        for row_index, (name, option_type, description, default, declarations) in enumerate(visible):
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
            print_result_details(
                name, option_type, fields, color, width,
                stack_detail=True,
                trailing_blank=index == len(groups) - 1 or row_index < len(visible) - 1,
            )
        sys.stdout.flush()
        if index < len(groups) - 1 and len(rows) > limit:
            print(file=sys.stderr)
        print_result_limit(len(rows), limit, label)
