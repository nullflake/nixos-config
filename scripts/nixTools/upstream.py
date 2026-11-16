"""Shared, read-only upstream queries for package search, livecheck and Helium."""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Set as AbstractSet
from datetime import UTC, datetime, timedelta
from email.utils import parsedate_to_datetime

NIXOS_HOSTS = frozenset({"channels.nixos.org", "releases.nixos.org"})
HELIUM_REPOSITORY = "imputnet/helium-linux"
MAX_JSON_BYTES = 4 * 1024 * 1024


class GitHubRateLimit(ValueError):
    """The shared GitHub quota prevents further requests during this run."""


def github_http_error(error):
    """Keep diagnostic headers, but never copy upstream messages into output."""
    code = error.code
    headers = {key.lower(): value for key, value in (error.headers or {}).items()}
    try:
        try:
            value = json.loads(error.read(16 * 1024))
            message = value.get("message", "") if isinstance(value, dict) else ""
        except (OSError, ValueError):
            message = ""
    finally:
        error.close()
    limited = code in {403, 429} and (
        code == 429
        or headers.get("x-ratelimit-remaining") == "0"
        or "retry-after" in headers
        or (isinstance(message, str) and "rate limit" in message.lower())
    )
    if limited:
        now = datetime.now(UTC)
        deadlines = []
        if headers.get("x-ratelimit-remaining") == "0":
            try:
                deadlines.append(
                    datetime.fromtimestamp(int(headers["x-ratelimit-reset"]), UTC)
                )
            except (KeyError, ValueError, OverflowError, OSError):
                pass
        if "retry-after" in headers:
            try:
                retry = headers["retry-after"]
                if retry.isdigit():
                    deadline = now + timedelta(seconds=int(retry))
                else:
                    deadline = parsedate_to_datetime(retry)
                    if deadline.tzinfo is None:
                        deadline = deadline.replace(tzinfo=UTC)
                deadlines.append(deadline)
            except (ValueError, OverflowError, TypeError):
                pass
        deadline = max(
            (deadline for deadline in deadlines if deadline > now),
            default=now + timedelta(seconds=60),
        )
        timestamp = deadline.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        return GitHubRateLimit(
            f"GitHub rate limit reached; retry after {timestamp}. "
            "Remaining GitHub requests skipped for this run."
        )
    if code in {401, 403}:
        return ValueError(
            f"GitHub access denied (HTTP {code}); check GITHUB_TOKEN and its permissions"
        )
    return ValueError(f"GitHub HTTP {code}")


def validate_url(url, hosts: AbstractSet[str]):
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in hosts
        or parsed.port not in {None, 443}
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ValueError("metadata URL must use HTTPS on an allowed host")


class MetadataRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, hosts: AbstractSet[str]):
        self.hosts = hosts

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        try:
            validate_url(newurl, self.hosts)
        except ValueError:
            fp.close()
            raise
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_metadata(request, timeout, hosts: AbstractSet[str] = NIXOS_HOSTS):
    url = request.full_url if isinstance(request, urllib.request.Request) else request
    validate_url(url, hosts)
    opener = urllib.request.build_opener(MetadataRedirectHandler(hosts))
    return opener.open(request, timeout=timeout)


def resolve_metadata_url(url, opener=open_metadata):
    """Resolve channel redirects without reading the archive/package list body."""
    try:
        response = opener(urllib.request.Request(url, method="HEAD"), timeout=15)
    except urllib.error.HTTPError as error:
        if error.code not in {405, 501}:
            raise
        error.close()
        response = opener(url, timeout=15)
    with response:
        return response.geturl()


def release_revision(url):
    match = re.search(r"\.([0-9a-f]{7,40})/[^/]+$", urllib.parse.urlsplit(url).path)
    if not match:
        raise ValueError("channel did not resolve to an immutable release revision")
    return match.group(1)


def same_revision(first, second):
    return bool(
        re.fullmatch(r"[0-9a-f]{7,40}", first)
        and re.fullmatch(r"[0-9a-f]{7,40}", second)
        and (first.startswith(second) or second.startswith(first))
    )


class Upstream:
    def __init__(self):
        # Only reuse queries during this invocation; no stale on-disk answers.
        self.answers = {}
        self.github_blocked = None
        self.revision_dates: dict[tuple[str, str], str] = {}

    def cached(self, key, query):
        if key not in self.answers:
            try:
                self.answers[key] = query()
            except (
                OSError,
                TypeError,
                ValueError,
                subprocess.SubprocessError,
            ) as error:
                self.answers[key] = error
        value = self.answers[key]
        if isinstance(value, Exception):
            raise value
        return value

    def github(self, repository, endpoint):
        if self.github_blocked is not None:
            raise self.github_blocked
        repository = repository.lower()
        parts = repository.split("/")
        if len(parts) != 2 or not all(re.fullmatch(r"[\w.-]+", part) for part in parts):
            raise ValueError("invalid GitHub repository")
        url = f"https://api.github.com/repos/{repository}/{endpoint}"

        def query():
            headers = {
                "Accept": "application/vnd.github+json",
                "User-Agent": "nixctl-livecheck",
            }
            token = os.environ.get("GITHUB_TOKEN")
            if token:
                # HTTP libraries may include malformed header values in exceptions.
                if not re.fullmatch(r"[A-Za-z0-9_]+", token):
                    raise ValueError(
                        "GITHUB_TOKEN has an invalid format; enter the token without whitespace or control characters"
                    )
                headers["Authorization"] = f"Bearer {token}"
            request = urllib.request.Request(url, headers=headers)
            try:
                with open_metadata(
                    request, timeout=15, hosts={"api.github.com"}
                ) as response:
                    body = response.read(MAX_JSON_BYTES + 1)
            except urllib.error.HTTPError as error:
                failure = github_http_error(error)
                if isinstance(failure, GitHubRateLimit):
                    self.github_blocked = failure
                raise failure from None
            if len(body) > MAX_JSON_BYTES:
                raise ValueError("GitHub response exceeds metadata size limit")
            value = json.loads(body)
            if not isinstance(value, dict):
                raise TypeError("invalid GitHub metadata")
            return value

        return self.cached(url, query)

    def github_revision(self, repository, ref=None):
        target = urllib.parse.quote(ref or "HEAD", safe="")
        metadata = self.github(repository, f"commits/{target}")
        value = metadata.get("sha", "")
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            raise ValueError("missing GitHub commit SHA")
        commit = metadata.get("commit")
        committer = commit.get("committer") if isinstance(commit, dict) else None
        timestamp = committer.get("date") if isinstance(committer, dict) else None
        if isinstance(timestamp, str):
            try:
                date = datetime.fromisoformat(timestamp)
                if date.tzinfo is not None:
                    self.revision_dates[(repository.lower(), value)] = (
                        date.astimezone(UTC).date().isoformat()
                    )
            except (ValueError, OverflowError):
                pass
        return value

    def github_revision_date(self, repository, revision):
        """Read an already fetched commit date; never make another API request."""
        return self.revision_dates.get((repository.lower(), revision))

    def compare(self, repository, current, latest):
        base = urllib.parse.quote(current, safe="")
        head = urllib.parse.quote(latest, safe="")
        value = self.github(repository, f"compare/{base}...{head}?per_page=1")
        status = value.get("status")
        ahead, behind = value.get("ahead_by"), value.get("behind_by")
        if status not in {"ahead", "behind", "identical", "diverged"} or not all(
            type(number) is int and number >= 0 for number in (ahead, behind)
        ):
            raise ValueError("invalid GitHub comparison")
        return status, ahead, behind

    def release(self, repository, tag=None):
        endpoint = "latest" if not tag else "tags/" + urllib.parse.quote(tag, safe="")
        value = self.github(repository, f"releases/{endpoint}")
        if not isinstance(value.get("tag_name"), str) or not value["tag_name"]:
            raise ValueError("missing upstream release tag")
        return value

    def channel(self, url):
        return self.cached(("channel", url), lambda: resolve_metadata_url(url))

    def git_revision(self, url, ref=None):
        """Other Git hosts: check refs without cloning a repository."""
        parsed = urllib.parse.urlsplit(url)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
        ):
            raise ValueError("only HTTPS Git remotes are supported")
        if ref and ref.startswith("refs/tags/"):
            refs = [f"{ref}^{{}}", ref]
        elif ref and ref.startswith("refs/"):
            refs = [ref]
        elif ref:
            refs = [f"refs/heads/{ref}", f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}"]
        else:
            refs = ["HEAD"]

        def query():
            result = subprocess.run(
                ["git", "-c", "credential.helper=", "ls-remote", "--", url, *refs],
                capture_output=True,
                check=False,
                text=True,
                timeout=20,
                env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
            )
            if result.returncode:
                raise ValueError("could not read Git remote refs")
            values = dict(line.split()[::-1] for line in result.stdout.splitlines())
            for name in refs:
                value = values.get(name, "")
                if re.fullmatch(r"[0-9a-f]{40}", value):
                    return value
            raise ValueError("Git remote ref was not found")

        return self.cached(("git", url, ref), query)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["helium-release"])
    parser.add_argument("tag", nargs="?")
    args = parser.parse_args()
    try:
        print(json.dumps(Upstream().release(HELIUM_REPOSITORY, args.tag)))
        return 0
    except (OSError, TypeError, ValueError) as error:
        print(f"Upstream error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
