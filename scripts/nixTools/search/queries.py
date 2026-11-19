"""Run read-only queries against the local search indexes."""

import sqlite3
from collections.abc import Sequence
from typing import NamedTuple

DEFAULT_PACKAGE_SETS = ("kdePackages",)

type OptionRow = tuple[str, str, str, str | None, str]
type OptionGroup = tuple[str, str, list[OptionRow]]


class PackageRow(NamedTuple):
    """A package result with empty source details when they were not requested."""

    attr: str
    version: str
    description: str
    homepages_json: str = "[]"
    position: str = ""


def package_search_fields(db: sqlite3.Connection, details: bool) -> str:
    """Select display columns, checking legacy schemas only for detailed output."""
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
    return fields


def query_packages(
    db: sqlite3.Connection,
    terms: Sequence[str],
    details: bool,
    limit: int,
    *,
    package_set: str | None,
    top_level: bool,
    all_packages: bool,
) -> list[PackageRow]:
    """Return ranked matches and at most one extra row to signal truncation."""
    fields = package_search_fields(db, details)
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
    rows = db.execute(
        f"SELECT {fields} FROM packages WHERE {where} "
        "ORDER BY CASE WHEN lower(attr) = ? THEN 0 WHEN instr(lower(attr), ?) = 1 THEN 1 ELSE 2 END, "
        "length(attr), attr LIMIT ?",
        [*parameters, ranked_query, ranked_query, limit + 1],
    )
    return [PackageRow(*row) for row in rows]


def query_options(db: sqlite3.Connection, table: str, query: str, limit: int) -> list[OptionRow]:
    """Rank option names ahead of description matches and fetch one extra row."""
    terms = query.split()
    where = " AND ".join("instr(searchable, ?) > 0" for _ in terms)
    matches_name = " AND ".join("instr(lower(name), ?) > 0" for _ in terms)
    return db.execute(
        f"SELECT name, type, description, default_value, declarations FROM {table} WHERE {where} "
        "ORDER BY CASE WHEN lower(name) = ? THEN 0 "
        "WHEN instr(lower(name), ?) = 1 THEN 1 "
        f"WHEN {matches_name} THEN 2 ELSE 3 END, "
        "name COLLATE NOCASE, name LIMIT ?",
        [*terms, query, query, *terms, limit + 1],
    ).fetchall()


def query_option_catalogs(
    db: sqlite3.Connection,
    query: str,
    limit: int,
    *,
    nixos_only: bool,
    home_manager_only: bool,
) -> tuple[list[OptionGroup], bool]:
    """Return the selected catalog groups and flag absent optional Home Manager data."""
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    sources = (
        ("nixos", "NixOS", "options", not home_manager_only),
        ("home-manager", "Home Manager", "home_manager_options", not nixos_only),
    )
    groups = []
    missing_home_manager = False
    for scope, label, table, enabled in sources:
        if not enabled:
            continue
        if table not in tables:
            if scope == "home-manager" and not home_manager_only:
                missing_home_manager = True
                continue
            raise ValueError(f"saved index has no {label} options; run a search without --offline to update it")
        groups.append((scope, label, query_options(db, table, query, limit)))
    return groups, missing_home_manager
