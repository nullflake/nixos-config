"""Control the plugin's dedicated mpv queue through its private JSON IPC socket."""

import fcntl
import hashlib
import json
import math
import os
import re
import socket
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path


class Player:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(3)
        try:
            self.socket.connect(str(path))
        except OSError:
            self.socket.close()
            raise
        self.stream = self.socket.makefile("rb")
        self.serial = 0

    def close(self):
        self.stream.close()
        self.socket.close()

    def command(self, *command):
        self.serial += 1
        self.socket.sendall((json.dumps({"command": command, "request_id": self.serial}) + "\n").encode())
        while True:
            line = self.stream.readline()
            if not line:
                raise RuntimeError("Queue player disconnected")
            result = json.loads(line)
            if result.get("request_id") == self.serial:
                if result.get("error") != "success":
                    raise RuntimeError(result.get("error", "mpv command failed"))
                return result.get("data")

    def get(self, name):
        return self.command("get_property", name)


def socket_path(queue_path):
    digest = hashlib.sha256(str(queue_path.resolve()).encode()).hexdigest()[:16]
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
    directory = runtime / f"noctalia-youtube-{os.getuid()}-{digest}"
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError("Queue control directory must be private")
    return directory / "player.sock"


def read_items(path):
    saved = json.loads(path.read_text())
    if not isinstance(saved, dict):
        raise TypeError("Playback queue must be an object")
    if saved.get("version") != 1:
        raise ValueError("Invalid playback queue")
    items = saved.get("items")
    # Noctalia encodes an empty Luau table as an empty JSON object.
    if items == {}:
        items = []
    if not isinstance(items, list):
        raise TypeError("Queued items must be a list")
    urls = []
    for item in items:
        if not isinstance(item, dict):
            raise TypeError("Queued video must be an object")
        video_id = item.get("id")
        if not isinstance(video_id, str):
            raise TypeError("Queued video ID must be a string")
        if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            raise ValueError("Invalid queued video ID")
        url = "https://www.youtube.com/watch?v=" + video_id
        if url in urls:
            raise ValueError("Duplicate queued video")
        urls.append(url)
    return items


def read_queue(path):
    return [video_url(item["id"]) for item in read_items(path)]


def video_url(video_id):
    return "https://www.youtube.com/watch?v=" + video_id


def save_items(path, items):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part." + uuid.uuid4().hex)
    try:
        with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
            json.dump({"version": 1, "items": items}, stream)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def current_url(player):
    if player is None or player.get("idle-active") or player.get("eof-reached"):
        return None
    return next((entry["filename"] for entry in player.get("playlist")
                 if entry.get("current")), None)


def validate_item(item):
    if (not isinstance(item, dict) or not isinstance(item.get("id"), str)
            or not re.fullmatch(r"[A-Za-z0-9_-]{11}", item["id"])
            or not all(isinstance(item.get(key), str) for key in ("title", "subtitle"))):
        raise ValueError("Invalid queued video metadata")
    channel = item.get("channelId")
    if channel is not None and (not isinstance(channel, str)
                               or not re.fullmatch(r"UC[A-Za-z0-9_-]{22}", channel)):
        raise ValueError("Invalid queued channel")
    return {key: item[key] for key in ("id", "title", "subtitle", "channelId") if key in item}


def notify_queue_changed():
    try:
        subprocess.Popen(
            ["noctalia", "msg", "plugin", "nullflake/youtube-search:queue-events", "all",
             "queue-changed", uuid.uuid4().hex],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        pass  # The saved queue remains authoritative when the shell is not running.


def connect(path):
    try:
        return Player(path)
    except (FileNotFoundError, ConnectionRefusedError):
        return None


def apply_options(player, options):
    player.command("apply-profile", "youtube")
    player.command("set_property", "options/vid", "auto")
    script_options = []
    for option in options:
        if "=" not in option or option.startswith("--profile="):
            continue
        name, value = option.removeprefix("--").split("=", 1)
        if name == "script-opts-append":
            script_options.append(value)
            continue
        if name in ("ytdl-format", "vid", "force-window"):
            player.command("set_property", "options/" + name, value)
    # Script options are supplied when the dedicated player starts; resetting the
    # playback profile must retain them for later files and repeated Play queue.
    if script_options:
        player.command("set_property", "script-opts", "youtube-resume-enabled=yes," + ",".join(script_options))


def synchronize(player, urls):
    playlist = player.get("playlist")
    # Remove from the end so earlier indices remain stable.
    for index in range(len(playlist) - 1, -1, -1):
        if playlist[index]["filename"] not in urls:
            player.command("playlist-remove", index)
    playlist = player.get("playlist")
    existing = {entry["filename"] for entry in playlist}
    added = []
    at_end = not player.get("idle-active") and player.get("eof-reached")
    for url in urls:
        if url not in existing:
            player.command("loadfile", url, "append")
            added.append(url)
    playlist = player.get("playlist")
    # Move later entries backwards; mpv retains the current entry and its position
    # within the file when its playlist index changes.
    for index, url in enumerate(urls):
        if playlist[index]["filename"] != url:
            old_index = next(
                i for i in range(index + 1, len(playlist))
                if playlist[i]["filename"] == url
            )
            player.command("playlist-move", old_index, index)
            playlist.insert(index, playlist.pop(old_index))
    next_index = None
    if added and player.get("idle-active"):
        next_index = urls.index(added[0])
    elif added and at_end and player.get("eof-reached"):
        current = player.get("playlist-pos")
        if current + 1 < len(urls):
            next_index = current + 1
    if next_index is not None:
        player.command("set_property", "playlist-pos", next_index)
        player.command("set_property", "pause", False)


def main():
    action, filename, *options = sys.argv[1:]
    if action not in ("play", "sync", "toggle", "clear", "complete"):
        raise ValueError("Unknown queue action")
    queue_path = Path(filename)
    start_id = None
    start_time = None
    item = None
    completed_token = None
    completed_entry = None
    playback_options = []
    for option in options:
        if option.startswith("--queue-item="):
            item = validate_item(json.loads(option.split("=", 1)[1]))
        elif option.startswith("--queue-token="):
            completed_token = option.split("=", 1)[1]
        elif option.startswith("--queue-entry="):
            completed_entry = int(option.split("=", 1)[1])
        elif option.startswith("--queue-start="):
            start_id = option.split("=", 1)[1]
        elif option.startswith("--queue-start-time="):
            start_time = float(option.split("=", 1)[1])
            if not math.isfinite(start_time) or start_time < 0:
                raise ValueError("Invalid playback start time")
        else:
            playback_options.append(option)
    options = playback_options
    path = socket_path(queue_path)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        items = read_items(queue_path) if queue_path.exists() else []
        if action == "complete":
            if not start_id or not completed_token or completed_entry is None:
                raise ValueError("Missing completed video identity")
            remaining = [entry for entry in items if not (
                entry["id"] == start_id and entry.get("queueToken") == completed_token)]
            if remaining == items:
                return
            save_items(queue_path, remaining)
            player = connect(path)
            if player is not None:
                try:
                    for index, entry in enumerate(player.get("playlist")):
                        if entry.get("id") == completed_entry:
                            player.command("playlist-remove", index)
                            break
                finally:
                    player.close()
            notify_queue_changed()
            return
        player = connect(path)
        if action == "toggle":
            if item is None:
                raise ValueError("Missing queued video")
            if any(entry["id"] == item["id"] for entry in items):
                items = [entry for entry in items if entry["id"] != item["id"]]
            else:
                items.append(item)
        elif action == "clear":
            current = current_url(player)
            items = [entry for entry in items if video_url(entry["id"]) == current]
        elif action == "play" and item is not None:
            existing = next((entry for entry in items if entry["id"] == item["id"]), None)
            if existing is None:
                items.insert(0, item)
            else:
                existing.update(item)
            start_id = item["id"]
        for entry in items:
            if action == "play" or not entry.get("queueToken"):
                # Play rebuilds the whole playlist; an earlier EOF must not consume any of its new entries.
                entry["queueToken"] = uuid.uuid4().hex
        urls = [video_url(entry["id"]) for entry in items]
        if action == "play" and not urls:
            raise ValueError("Playback queue is empty")
        start_index = 0
        if start_id is not None:
            start_url = "https://www.youtube.com/watch?v=" + start_id
            if start_url not in urls:
                raise ValueError("Selected video is no longer in the playback queue")
            start_index = urls.index(start_url)
        process = None
        try:
            save_items(queue_path, items)
            if action == "play":
                options = [*options,
                    "--script=" + str(Path(__file__).with_name("queue-playback.lua")),
                    "--script-opts-append=queue-playback-queue_path=" + str(queue_path.resolve()),
                    "--script-opts-append=queue-playback-helper=" + str(Path(__file__).resolve()),
                    "--script-opts-append=queue-playback-python=" + sys.executable,
                    "--script-opts-append=youtube-resume-queue_path=" + str(queue_path.resolve())]
            if player is None and action == "play":
                path.unlink(missing_ok=True)
                process = subprocess.Popen(
                    ["mpv", *options, "--idle=yes", "--keep-open=no", "--force-window=yes",
                     "--input-ipc-server=" + str(path)],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                deadline = time.monotonic() + 6
                while player is None:
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Could not start the queue player")
                    time.sleep(0.05)
                    player = connect(path)
            if player is None:
                return  # Editing a saved queue must not start playback.
            if action == "play":
                apply_options(player, options)
                player.command("set_property", "keep-open", False)
                player.command("stop")
                player.command("playlist-clear")
                for index, url in enumerate(urls):
                    if index == start_index and start_time is not None:
                        player.command("loadfile", url, "append", -1,
                                       {"start": str(start_time), "resume-playback": "no"})
                    else:
                        player.command("loadfile", url, "append")
                player.command("set_property", "playlist-pos", start_index)
                player.command("set_property", "pause", False)
            else:
                synchronize(player, urls)
        except Exception:
            if process is not None and process.poll() is None:
                process.terminate()
            raise
        finally:
            if player is not None:
                player.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, TypeError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
