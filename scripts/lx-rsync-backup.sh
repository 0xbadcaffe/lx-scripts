#!/usr/bin/env bash
# Linux file backup: rsync snapshots, per-run SMTP reports, and user cron.
# Run this script; do not source it. Python standard library only; no pip needed.
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf 'Execute this script; do not source it.\n' >&2
    return 2
fi
exec /usr/bin/python3 -I - "$0" "$@" <<'PY_ENGINE'
"""Local/mounted-volume rsync snapshots, SMTP reports, and a user crontab.
Python 3.9+, Linux, rsync 3.x. No third-party Python packages.
"""
from __future__ import annotations

import argparse
import collections
import contextlib
import datetime as dt
import email.policy
from email.message import EmailMessage
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import smtplib
import socket
import ssl
import stat
import subprocess
import sys
import time
import uuid

VERSION = "1.0.0"
CONFIG_LIMIT = 131072
LOG_LIMIT = 2 * 1024 * 1024
TAIL_LIMIT = 16000
RECORD_LIMIT = 1024 * 1024
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
RUN_RE = re.compile(r"\d{8}T\d{6}Z-[0-9a-f]{12}\Z")


class BackupError(Exception):
    pass


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"Interrupted by {signal.Signals(signum).name}")


def now():
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def run_id():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]


def text(value, label, maximum=4096):
    if not isinstance(value, str) or not value or len(value.encode()) > maximum:
        raise BackupError(f"{label}: expected nonempty text, at most {maximum} bytes")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise BackupError(f"{label}: control characters are not allowed")
    return value


def path_value(value, label):
    value = text(value, label)
    p = Path(value).expanduser()
    if not p.is_absolute():
        raise BackupError(f"{label}: use an absolute path (~/ is also accepted)")
    # No expansion of $variables, wildcards or shell syntax.
    return Path(os.path.abspath(p))


def within(child, parent):
    return child == parent or parent in child.parents


def private_dir(path):
    if path.is_symlink():
        raise BackupError(f"Refusing symlinked private directory: {path}")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    s = path.stat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.geteuid() or s.st_mode & 0o077:
        raise BackupError(f"Private directory must be yours and mode 700: {path}")


def read_private(path, limit):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as f:
            s = os.fstat(f.fileno())
            if (not stat.S_ISREG(s.st_mode) or s.st_uid != os.geteuid()
                    or s.st_mode & 0o077):
                raise BackupError(f"File must be regular, owned by this user and mode 600: {path}")
            value = f.read(limit + 1)
    except OSError as exc:
        raise BackupError(f"Cannot read {path}: {exc.strerror}") from exc
    if len(value) > limit:
        raise BackupError(f"File exceeds {limit} bytes: {path}")
    return value


def fsync_dir(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_bytes(path, data):
    temp = path.parent / ("." + path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
        fsync_dir(path.parent)
    finally:
        temp.unlink(missing_ok=True)



def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode())

def strict_keys(d, allowed, label):
    if not isinstance(d, dict):
        raise BackupError(f"{label} must be an object")
    unknown = set(d) - set(allowed)
    if unknown:
        raise BackupError(f"Unknown {label} field(s): {', '.join(sorted(unknown))}")


def integer(d, key, default, minimum, maximum):
    value = d.get(key, default)
    if type(value) is not int or not minimum <= value <= maximum:
        raise BackupError(f"{key} must be an integer from {minimum} to {maximum}")
    d[key] = value


def address(value, label):
    value = text(value, label, 254)
    if not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+", value):
        raise BackupError(f"{label}: use one plain ASCII email address, without a display name")
    return value


def default_config():
    host = re.sub(r"[^A-Za-z0-9_.-]", "-", socket.gethostname()).strip(".-")[:40] or "linux"
    home = Path.home()
    job = host + "-home"
    return {
        "schema_version": 1,
        "job_name": job,
        "sources": [{"name": "home", "path": str(home)}],
        "destination": {
            "path": f"/mnt/backup/{host}",
            "mountpoint": "/mnt/backup",
            "token": str(uuid.uuid4()),
        },
        "state_dir": str(home / ".local/state/linux-rsync-backup" / job),
        "exclude_patterns": ["/.cache/***", "/.local/share/Trash/***"],
        "one_file_system": True,
        "preserve_ownership": False,
        "checksum": False,
        "minimum_free_gib": 2,
        "maximum_run_seconds": 28800,
        "io_timeout_seconds": 300,
        "bandwidth_kib": 0,
        "smtp": {
            "host": "smtp.example.com",
            "port": 587,
            "security": "starttls",
            "username": "you@example.com",
            "password_file": str(home / ".config/linux-rsync-backup/smtp-password"),
            "from": "you@example.com",
            "to": "you@example.com",
            "timeout_seconds": 30,
        },
    }


def load_config(filename):
    raw = json.loads(read_private(filename, CONFIG_LIMIT))
    strict_keys(raw, default_config().keys(), "config")
    if type(raw.get("schema_version")) is not int or raw["schema_version"] != 1:
        raise BackupError("schema_version must be 1")
    if not ID_RE.fullmatch(text(raw.get("job_name"), "job_name", 64)):
        raise BackupError("job_name: use letters, digits, dots, hyphens or underscores")
    sources = raw.get("sources")
    if not isinstance(sources, list) or not 1 <= len(sources) <= 32:
        raise BackupError("sources must contain 1 to 32 named directories")
    seen = set()
    for source in sources:
        strict_keys(source, ("name", "path"), "source")
        name = text(source.get("name"), "source.name", 64)
        if not ID_RE.fullmatch(name) or name in seen:
            raise BackupError("Source labels must be unique safe names")
        seen.add(name)
        source["path"] = str(path_value(source.get("path"), "source.path"))
    dest = raw.get("destination")
    strict_keys(dest, ("path", "mountpoint", "token"), "destination")
    dest["path"] = str(path_value(dest.get("path"), "destination.path"))
    if "mountpoint" not in dest:
        raise BackupError("destination.mountpoint is required; set it explicitly to null only for a non-mounted local destination")
    if dest.get("mountpoint") is not None:
        dest["mountpoint"] = str(path_value(dest.get("mountpoint"), "destination.mountpoint"))
    token = text(dest.get("token"), "destination.token", 128)
    if not re.fullmatch(r"[A-Za-z0-9-]{16,128}", token):
        raise BackupError("destination.token must be 16 to 128 alphanumeric/hyphen characters")
    raw["state_dir"] = str(path_value(raw.get("state_dir"), "state_dir"))
    excludes = raw.setdefault("exclude_patterns", [])
    if not isinstance(excludes, list) or len(excludes) > 256:
        raise BackupError("exclude_patterns must be a list with at most 256 entries")
    for item in excludes:
        text(item, "exclude pattern")
    for key in ("one_file_system", "preserve_ownership", "checksum"):
        raw.setdefault(key, key == "one_file_system")
        if type(raw[key]) is not bool:
            raise BackupError(f"{key} must be true or false")
    integer(raw, "minimum_free_gib", 2, 0, 1048576)
    integer(raw, "maximum_run_seconds", 28800, 1, 604800)
    integer(raw, "io_timeout_seconds", 300, 1, 86400)
    integer(raw, "bandwidth_kib", 0, 0, 100000000)
    smtp = raw.get("smtp")
    strict_keys(smtp, ("host", "port", "security", "username", "password_file", "from", "to", "timeout_seconds"), "smtp")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", text(smtp.get("host"), "smtp.host", 253)):
        raise BackupError("smtp.host must be a DNS host name or IPv4 address")
    integer(smtp, "port", 587, 1, 65535)
    integer(smtp, "timeout_seconds", 30, 2, 120)
    if smtp.get("security") not in ("starttls", "tls"):
        raise BackupError("smtp.security must be starttls or tls; plaintext SMTP is not supported")
    for key in ("from", "to"):
        address(smtp.get(key), "smtp." + key)
    if smtp.get("username"):
        text(smtp["username"], "smtp.username", 254)
        smtp["password_file"] = str(path_value(smtp.get("password_file"), "smtp.password_file"))
    elif smtp.get("username") != "":
        raise BackupError("smtp.username must be text, or an empty string for a trusted TLS relay")
    return raw


def setup_state(c):
    root = Path(c["state_dir"])
    private_dir(root)
    for name in ("logs", "reports", "outbox", "receipts"):
        private_dir(root / name)
    return root


@contextlib.contextmanager
def lock_file(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    acquired = False
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.geteuid() or s.st_mode & 0o077:
            raise BackupError(f"Unsafe lock file: {path}")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
        except BlockingIOError:
            pass
        yield acquired
    finally:
        os.close(fd)


def safe_paths(c, require_sources=True):
    root = Path(c["destination"]["path"])
    if root.is_symlink() or root == Path("/"):
        raise BackupError("Destination must be a dedicated directory, not / or a symlink")
    root_real = root.resolve()
    state_real = Path(c["state_dir"]).resolve()
    if within(state_real, root_real) or within(root_real, state_real):
        raise BackupError("Backup destination and local state directory must be separate")
    sources = []
    for entry in c["sources"]:
        src = Path(entry["path"]).resolve()
        if src == Path("/"):
            raise BackupError("Backing up / as a single source is not supported; select /home, /etc, /srv separately")
        if within(root_real, src) or within(src, root_real):
            raise BackupError(f"Source and destination overlap: {src} and {root_real}")
        if within(src, state_real):
            raise BackupError("The state directory cannot also be a source")
        if require_sources and not src.is_dir():
            raise BackupError(f"Source directory missing: {src}")
        if any(within(src, other) or within(other, src) for _, other in sources):
            raise BackupError(f"Overlapping source directories: {src}")
        sources.append((entry["name"], src))
    mount = c["destination"].get("mountpoint")
    if mount:
        m = Path(mount)
        if m.is_symlink() or not os.path.ismount(m):
            raise BackupError(f"Required backup filesystem is NOT mounted at {m}; refusing fallback to the root disk")
        if root_real == m.resolve() or not within(root_real, m.resolve()):
            raise BackupError("Destination must be a subdirectory of the configured mountpoint")
        # Do not accept a nested destination on a different filesystem.
        probe = root_real
        while not probe.exists():
            probe = probe.parent
        if probe.stat().st_dev != m.stat().st_dev:
            raise BackupError("Destination is on a different filesystem from the required mountpoint")
    return root, sources


def marker_path(root):
    return root / ".linux-rsync-backup-target.json"


def validate_destination(c):
    root, sources = safe_paths(c)
    if not root.is_dir():
        raise BackupError(f"Destination missing: {root}. Mount the disk, then use --init-destination")
    if root.stat().st_uid != os.geteuid() or root.stat().st_mode & 0o077:
        raise BackupError(f"Backup directory must be owned by this user and mode 700: {root}")
    marker = json.loads(read_private(marker_path(root), 4096))
    if marker != {"schema_version": 1, "token": c["destination"]["token"]}:
        raise BackupError("Backup target marker does not match this config; refusing to write")
    snapshots = root / "snapshots"
    if snapshots.is_symlink() or not snapshots.is_dir():
        raise BackupError("Missing/unsafe snapshots directory; use --init-destination")
    if snapshots.stat().st_uid != os.geteuid() or snapshots.stat().st_mode & 0o077:
        raise BackupError("snapshots directory must be owned by this user and mode 700")
    if c["preserve_ownership"] and os.geteuid() != 0:
        raise BackupError("preserve_ownership requires running as root; leave false for your own files")
    if shutil.which("rsync") is None:
        raise BackupError("rsync is missing. Debian: sudo apt-get install rsync")
    return root, sources


def init_destination(c):
    root, _ = safe_paths(c)
    if root.exists():
        if marker_path(root).exists():
            validate_destination(c)
            print(f"Destination already initialized: {root}")
            return
        if not root.is_dir() or any(root.iterdir()):
            raise BackupError("Refusing to initialize a nonempty, unmarked destination directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.stat().st_uid != os.geteuid():
        raise BackupError(f"Destination must be owned by this user: {root}")
    root.chmod(0o700)
    private_dir(root / "snapshots")
    atomic_json(marker_path(root), {"schema_version": 1, "token": c["destination"]["token"]})
    print(f"Initialized backup directory: {root}\nNo source files were copied.")


def latest_snapshot(c, root):
    link = root / "latest"
    if not link.exists() and not link.is_symlink():
        return None
    if not link.is_symlink():
        raise BackupError("latest is not a managed symlink; refusing to overwrite it")
    target = os.readlink(link)
    parts = Path(target).parts
    if len(parts) != 2 or parts[0] != "snapshots" or not RUN_RE.fullmatch(parts[1]):
        raise BackupError("latest points outside the managed snapshot layout")
    candidate = root / target
    if candidate.is_symlink() or not candidate.is_dir():
        raise BackupError("latest points to a missing or symlinked snapshot")
    result = json.loads(read_private(candidate / ".backup-run.json", RECORD_LIMIT))
    if result.get("status") != "SUCCESS" or result.get("destination_token") != c["destination"]["token"]:
        raise BackupError("latest does not identify a successfully completed backup")
    return candidate


def escape_pattern(s):
    return "".join("\\" + char if char in "\\*?[]" else char for char in s)


def excluded_internal(c, src):
    paths = [(Path(c["state_dir"]), True)]
    if c["smtp"].get("username"):
        paths.append((Path(c["smtp"]["password_file"]), False))
    result = []
    for path, directory in paths:
        path = path.resolve()
        if within(path, src):
            rel = path.relative_to(src)
            if str(rel) == ".":
                raise BackupError("Cannot back up the state directory or SMTP secret as a source")
            result.append("/" + escape_pattern(rel.as_posix()) + ("/***" if directory else ""))
    return result


def rsync_argv(c, src, dest, previous=None, dry=False):
    rsync = shutil.which("rsync")
    if not rsync:
        raise BackupError("rsync is missing")
    argv = [rsync, "-aHAX", "--numeric-ids", "--no-devices", "--no-specials",
            "--stats", "--human-readable", "--fsync", f"--timeout={c['io_timeout_seconds']}"]
    if not c["preserve_ownership"]:
        argv += ["--no-owner", "--no-group"]
    if c["one_file_system"]:
        argv.append("--one-file-system")
    if c["checksum"]:
        argv.append("--checksum")
    if c["bandwidth_kib"]:
        argv.append(f"--bwlimit={c['bandwidth_kib']}")
    if previous is not None:
        if previous.is_symlink():
            raise BackupError("Previous source snapshot must not be a symlink")
        if previous.is_dir():
            argv.append(f"--link-dest={previous}")
    for pattern in c["exclude_patterns"] + excluded_internal(c, src):
        argv.append(f"--exclude={pattern}")
    if dry:
        argv += ["--dry-run", "--itemize-changes"]
    # The source trailing slash copies contents into its explicitly named slot.
    argv += ["--", str(src) + "/", str(dest) + "/"]
    return argv


class BoundedLog:
    def __init__(self, path=None):
        self.path = path
        self.data = bytearray()
        self.dropped = 0
        self.last_flush = 0.0

    def write(self, data):
        if isinstance(data, str):
            data = data.encode("utf-8", "replace")
        self.data.extend(data)
        if len(self.data) > LOG_LIMIT:
            n = len(self.data) - LOG_LIMIT
            del self.data[:n]
            self.dropped += n
        if self.path and time.monotonic() - self.last_flush >= 10:
            self.flush()

    def flush(self):
        if self.path:
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as f:
                if self.dropped:
                    f.write(f"[Earlier {self.dropped} log bytes discarded; retained tail follows.]\n".encode())
                f.write(self.data)
            self.last_flush = time.monotonic()

    def tail(self):
        return bytes(self.data[-TAIL_LIMIT:]).decode("utf-8", "replace")


def terminate_group(proc):
    # This group is created by us. Never kill a PID recovered from an old report.
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)


def transfer(argv, log, deadline):
    prefix = ["/usr/bin/nice", "-n", "10"] if Path("/usr/bin/nice").exists() else []
    log.write("$ " + shlex.join(prefix + argv) + "\n")
    proc = subprocess.Popen(prefix + argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True, close_fds=True)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BackupError("Maximum backup duration exceeded")
            for key, _ in selector.select(min(1.0, remaining)):
                data = os.read(key.fd, 65536)
                if data:
                    log.write(data)
                else:
                    selector.unregister(key.fileobj)
            if log.path and time.monotonic() - log.last_flush > 10:
                log.flush()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise BackupError("Maximum backup duration exceeded")
        return proc.wait(timeout=remaining)
    except BaseException:
        terminate_group(proc)
        raise
    finally:
        selector.close()
        proc.stdout.close()


def free_bytes(root):
    return shutil.disk_usage(root).free


def check_space(c, root):
    available = free_bytes(root)
    if available < c["minimum_free_gib"] * 1024**3:
        raise BackupError(f"Insufficient backup free space: {available / 1024**3:.2f} GiB; minimum {c['minimum_free_gib']} GiB")
    return available


def copy_snapshot(c, rid, log, result, dry=False):
    root, sources = validate_destination(c)
    before = check_space(c, root)
    result["free_bytes_before"] = before
    previous = latest_snapshot(c, root)
    stage = root / "snapshots" / (".incomplete-" + rid)
    result["snapshot"] = str(stage)
    result["previous_snapshot"] = str(previous) if previous else None
    deadline = time.monotonic() + c["maximum_run_seconds"]
    if not dry:
        stage.mkdir(mode=0o700)
    results = []
    for name, src in sources:
        check_space(c, root)
        # A one-level nonexistent destination lets rsync preview without mkdir.
        dest = root / "snapshots" / (".preview-" + rid + "-" + name) if dry else stage / name
        if not dry:
            dest.mkdir(mode=0o700)
        code = transfer(rsync_argv(c, src, dest, previous / name if previous else None, dry), log, deadline)
        results.append({"name": name, "source": str(src), "rsync_exit_code": code})
        log.write(f"Source {name}: rsync exit {code}\n")
        if code not in (0, 24):
            break
    result["source_results"] = results
    result["free_bytes_after"] = free_bytes(root)
    failed = any(x["rsync_exit_code"] not in (0, 24) for x in results)
    vanished = any(x["rsync_exit_code"] == 24 for x in results)
    status = "FAILED" if failed else "WARNING" if vanished else "SUCCESS"
    result["status"] = status
    result["backup_exit_code"] = 1 if failed else 2 if vanished else 0
    result["finished"] = now()
    if dry:
        result["status"] = "DRY_RUN_" + status
        result["snapshot"] = None
        return
    result["destination_token"] = c["destination"]["token"]
    if status == "SUCCESS":
        final = root / "snapshots" / rid
        result["snapshot"] = str(final)
        atomic_json(stage / ".backup-run.json", result)
        # Same filesystem: completed snapshot is published with a directory rename.
        os.rename(stage, final)
        fsync_dir(final.parent)
        tmp_link = root / (".latest-" + rid)
        try:
            os.symlink("snapshots/" + rid, tmp_link)
            os.replace(tmp_link, root / "latest")
            fsync_dir(root)
        finally:
            tmp_link.unlink(missing_ok=True)
    else:
        atomic_json(stage / ".backup-run.json", result)
        log.write("Incomplete snapshot retained for diagnosis. latest was NOT changed.\n")



def save_password(c, password):
    if not c["smtp"]["username"]:
        raise BackupError("This config uses an unauthenticated TLS relay and has no password")
    if (not isinstance(password, str) or not password or len(password.encode()) > 4096
            or any(ch in password for ch in ("\n", "\r", "\x00"))):
        raise BackupError("Password must be a single nonempty line, at most 4096 bytes")
    path = Path(c["smtp"]["password_file"])
    private_dir(path.parent)
    if path.exists() or path.is_symlink():
        read_private(path, 4096)
    atomic_bytes(path, (password + "\n").encode())
    print(f"Stored SMTP password in {path} (mode 600). This is plaintext, protected by filesystem permissions.")

def smtp_password(c):
    s = c["smtp"]
    if s["host"] == "smtp.example.com" or s["from"].endswith("@example.com") or s["to"].endswith("@example.com"):
        raise BackupError("Edit the example SMTP host/from/to in your config before sending email")
    if not s["username"]:
        return None
    value = read_private(Path(s["password_file"]), 4096).decode("utf-8").rstrip("\r\n")
    if not value or "\n" in value or "\r" in value or "\x00" in value:
        raise BackupError("SMTP password file must contain one nonempty password/token line")
    return value


@contextlib.contextmanager
def smtp_deadline(seconds):
    def expired(_sig, _frame):
        raise TimeoutError("SMTP delivery deadline exceeded")
    old = signal.signal(signal.SIGALRM, expired)
    signal.alarm(int(math.ceil(seconds)))
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


def send_smtp(c, record):
    s = c["smtp"]
    password = smtp_password(c)
    msg = EmailMessage(policy=email.policy.SMTP)
    msg["From"] = address(record["from"], "queued sender")
    msg["To"] = address(record["to"], "queued recipient")
    msg["Subject"] = text(record["subject"], "queued subject", 512)
    msg["Date"] = text(record["date"], "queued date", 100)
    msg["Message-ID"] = text(record["message_id"], "queued message_id", 254)
    msg["Auto-Submitted"] = "auto-generated"
    msg.set_content(record["body"])
    tls = ssl.create_default_context()
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    client = None
    try:
        with smtp_deadline(s["timeout_seconds"] + 5):
            if s["security"] == "tls":
                client = smtplib.SMTP_SSL(s["host"], s["port"], timeout=s["timeout_seconds"], context=tls)
            else:
                client = smtplib.SMTP(s["host"], s["port"], timeout=s["timeout_seconds"])
                client.ehlo()
                client.starttls(context=tls)   # Mandatory; no plaintext fallback.
            client.ehlo()
            if s["username"]:
                client.login(s["username"], password)
            refused = client.send_message(msg, from_addr=record["from"], to_addrs=[record["to"]])
            if refused:
                raise BackupError("SMTP recipient rejected")
            # A QUIT failure must not turn a DATA-accepted email into an automatic retry.
    finally:
        if client is not None:
            client.close()


def mail_fingerprint(c):
    return hashlib.sha256(json.dumps(c["smtp"], sort_keys=True).encode()).hexdigest()


def notify(c, result, log, queue=True):
    state = Path(c["state_dir"])
    rid = result["run_id"]
    body = [f"Linux backup: {result['status']}", f"Job: {c['job_name']}",
            f"Host: {socket.gethostname()}", f"Run ID: {rid}",
            f"Started: {result['started']}", f"Finished: {result.get('finished', now())}",
            f"Elapsed: {result.get('elapsed_seconds', 0):.1f} seconds",
            f"Backup exit code: {result.get('backup_exit_code', 'n/a')}",
            f"Destination: {c['destination']['path']}", f"Snapshot: {result.get('snapshot') or 'none'}"]
    if result.get("error"):
        body.append("Details: " + result["error"])
    for key in ("free_bytes_before", "free_bytes_after"):
        if key in result:
            body.append(f"{key}: {result[key] / 1024**3:.2f} GiB")
    for row in result.get("source_results", []):
        body.append(f"Source {row['name']}: {row['source']} (rsync exit {row['rsync_exit_code']})")
    body += ["", "The backup is file-level, not an application-consistent or bare-metal image.",
             "No source files, old snapshots or old reports were deleted.",
             "", "Retained log tail (may contain paths/filenames):", log.tail()]
    from email.utils import format_datetime
    record = {
        "from": c["smtp"]["from"], "to": c["smtp"]["to"],
        "subject": f"[backup {result['status']}] {c['job_name']} {rid}",
        "date": format_datetime(dt.datetime.now().astimezone()),
        "message_id": f"<{rid}.{uuid.uuid4().hex}@linux-rsync-backup.local>",
        "body": "\n".join(body),
    }
    if queue:
        try:
            atomic_json(state / "outbox" / (rid + ".json"), record)
        except (OSError, BackupError) as exc:
            print(f"Outbox unavailable ({type(exc).__name__}); attempting direct SMTP", file=sys.stderr)
            queue = False
    if not queue:
        send_smtp(c, record)
        return True, "SMTP accepted directly; local outbox was unavailable"
    return retry_mail(c, preferred=rid)


def retry_mail(c, preferred=None):
    state = setup_state(c)
    with lock_file(state / "mail.lock") as acquired:
        if not acquired:
            return False, "A different run is sending mail; this report is queued"
        pending = sorted((state / "outbox").glob("*.json"))
        if preferred:
            pending.sort(key=lambda p: (p.stem != preferred, p.name))
        error = ""
        for path in pending[:20]:
            try:
                if not RUN_RE.fullmatch(path.stem):
                    raise BackupError("Unrecognized outbox filename")
                record = json.loads(read_private(path, RECORD_LIMIT))
                send_smtp(c, record)
                atomic_json(state / "receipts" / path.name,
                            {"smtp_accepted": now(), "message_id": record["message_id"]})
                path.unlink()
                fsync_dir(path.parent)
            except Exception as exc:
                # Never log SMTP passwords or protocol debug transcripts.
                error = f"Mail pending: {type(exc).__name__}"
                if isinstance(exc, BackupError):
                    error += ": " + str(exc)
                print(error, file=sys.stderr)
                break
        remaining = len(list((state / "outbox").glob("*.json")))
        return remaining == 0, error or (f"{remaining} older report(s) remain queued" if remaining else "SMTP accepted all pending reports")


def run_backup(c):
    state = Path(c["state_dir"])
    state_ready = False
    rid = run_id()
    log = BoundedLog()
    result = {"schema_version": 1, "run_id": rid, "job": c["job_name"],
              "started": now(), "status": "FAILED", "backup_exit_code": 1}
    start = time.monotonic()
    exit_code = 1
    def interrupted(signum, _frame):
        raise Interrupted(signum)
    old = {s: signal.signal(s, interrupted) for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    try:
        setup_state(c)
        state_ready = True
        log.path = state / "logs" / (rid + ".log")
        log.write(f"Started {result['started']}: {c['job_name']}\n")
        with lock_file(state / "run.lock") as acquired:
            if not acquired:
                result.update(status="SKIPPED", backup_exit_code=3, error="Another backup with this state directory is running")
            else:
                root, _ = validate_destination(c)
                with lock_file(root / ".backup.lock") as destination_acquired:
                    if not destination_acquired:
                        result.update(status="SKIPPED", backup_exit_code=3, error="Another backup is writing this destination")
                    else:
                        copy_snapshot(c, rid, log, result)
    except Interrupted as exc:
        result.update(status="INTERRUPTED", backup_exit_code=128 + exc.signum, error=str(exc))
    except Exception as exc:
        result.update(status="FAILED", backup_exit_code=1, error=f"{type(exc).__name__}: {exc}")
    finally:
        # Best-effort completion report after a catchable signal. SIGKILL/power loss cannot be caught.
        for signum in old:
            signal.signal(signum, signal.SIG_IGN)
        result.update(finished=now(), elapsed_seconds=round(time.monotonic() - start, 3))
        exit_code = result["backup_exit_code"]
        log.write(f"\nStatus: {result['status']}\n" + (result.get("error", "")) + "\n")
        # Local log/report errors must not prevent the SMTP attempt.
        try:
            log.flush()
            if state_ready:
                atomic_json(state / "reports" / (rid + ".json"), result)
        except Exception as exc:
            print(f"Cannot persist local report: {type(exc).__name__}: {exc}", file=sys.stderr)
            if exit_code == 0:
                exit_code = 4
        try:
            mail_ok, message = notify(c, result, log, queue=state_ready)
            result["email"] = "smtp-accepted" if mail_ok else "pending"
            result["email_note"] = message
            if not mail_ok and exit_code == 0:
                exit_code = 4
            if state_ready:
                atomic_json(state / "reports" / (rid + ".json"), result)
        except Exception as exc:
            print(f"Cannot save/send completion report: {type(exc).__name__}: {exc}", file=sys.stderr)
            if exit_code == 0:
                exit_code = 4
        finally:
            for signum, handler in old.items():
                signal.signal(signum, handler)
    print(f"{result['status']}: {rid}; email={result.get('email', 'failed')}; log={log.path}")
    return exit_code


def cron_schedule(value):
    if len(value) > 128:
        raise BackupError("Cron schedule is too long")
    fields = value.split()
    if len(fields) != 5:
        raise BackupError("Schedule must have five numeric cron fields, e.g. '30 2 * * *'")
    for field, low, high in zip(fields, (0, 0, 1, 1, 0), (59, 23, 31, 12, 7)):
        for token in field.split(","):
            match = re.fullmatch(r"(\*|\d+(?:-\d+)?)(?:/(\d+))?", token)
            if not match:
                raise BackupError(f"Unsupported cron field: {field}")
            span, step = match.groups()
            if step and not 1 <= int(step) <= high - low + 1:
                raise BackupError(f"Invalid cron step: {token}")
            if span != "*":
                numbers = list(map(int, span.split("-")))
                if any(not low <= number <= high for number in numbers) or numbers[0] > numbers[-1]:
                    raise BackupError(f"Cron field out of range: {field}")
    return " ".join(fields)


def cron_line(c, config_path, script_path, schedule):
    logfile = str(Path(c["state_dir"]) / "cron.log")
    for item in (str(script_path), str(config_path), logfile):
        if any(char in item for char in ("%", "\n", "\r")):
            raise BackupError("Cron paths must not contain %, newline or carriage return")
    command = shlex.join(["/bin/bash", str(script_path), "--config", str(config_path), "--run"])
    command += f" >> {shlex.quote(logfile)} 2>&1"
    if len(command.encode()) > 998:
        raise BackupError("Cron command exceeds Debian cron's 998-byte command limit")
    return f"{cron_schedule(schedule)} {command}"


def replace_cron(old, name, new_line):
    begin = f"# BEGIN linux-rsync-backup:{name}"
    end = f"# END linux-rsync-backup:{name}"
    lines = old.splitlines()
    if lines.count(begin) != lines.count(end) or lines.count(begin) > 1:
        raise BackupError("Malformed/duplicate managed cron block; review crontab manually")
    if begin in lines:
        first, last = lines.index(begin), lines.index(end)
        if first >= last:
            raise BackupError("Malformed managed cron block")
        lines[first:last + 1] = []
    if new_line is not None:
        lines += [begin, new_line, end]
    return "\n".join(lines) + ("\n" if lines else "")


def read_cron():
    proc = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=10)
    if proc.returncode == 0:
        return proc.stdout
    if proc.returncode == 1 and "no crontab for" in proc.stderr.lower():
        return ""
    raise BackupError("Cannot read user crontab: " + proc.stderr.strip())


def manage_cron(c, config_path, script_path, schedule, remove=False):
    if not shutil.which("crontab"):
        raise BackupError("crontab is missing. Debian: sudo apt-get install cron")
    state = setup_state(c)
    if not remove:
        validate_destination(c)
        smtp_password(c)
        receipt = json.loads(read_private(state / "mail-test.json", 4096)) if (state / "mail-test.json").exists() else {}
        if (receipt.get("fingerprint") != mail_fingerprint(c)
                or time.time() - receipt.get("epoch", 0) > 86400):
            raise BackupError("First run --test-mail successfully with these SMTP settings (within 24 hours)")
    newline = None if remove else cron_line(c, config_path, script_path, schedule)
    with lock_file(state / "cron-edit.lock") as acquired:
        if not acquired:
            raise BackupError("Another cron update is in progress")
        old = read_cron()
        revised = replace_cron(old, c["job_name"], newline)
        if revised == old:
            print("No crontab changes needed.")
            return
        backup = state / ("crontab-before-" + run_id() + ".json")
        atomic_json(backup, {"crontab": old, "saved": now()})
        if read_cron() != old:
            raise BackupError("Crontab changed during editing; retry instead of overwriting it")
        subprocess.run(["crontab", "-"], input=revised, text=True, check=True, timeout=10)
        print("Removed managed cron job." if remove else f"Installed user cron job:\n{newline}")
        print(f"Previous crontab saved in {backup}")


def parse_args(argv):
    p = argparse.ArgumentParser(prog="linux-rsync-backup.sh", description="Rsync snapshots + per-run SMTP reports + user cron. Default: show help, no action.")
    p.add_argument("--config", default="~/.config/linux-rsync-backup/config.json")
    actions = p.add_mutually_exclusive_group()
    for name, help_text in (
        ("init", "create an editable JSON config without overwriting an existing file"),
        ("init-destination", "mark a dedicated empty backup directory; requires the configured mount"),
        ("check", "check sources, destination marker, local tools and SMTP secret permissions; no network"),
        ("dry-run", "rsync preview only; no backups or emails written"),
        ("run", "perform a backup and send/queue its completion report"),
        ("test-mail", "send a test email; required before installing cron"),
        ("set-password", "prompt locally for an SMTP app password and store it mode 600"),
        ("retry-mail", "retry queued reports without running a backup"),
        ("show-cron", "print a cron line without installing it"),
        ("install-cron", "install/update only this job's managed user-crontab block"),
        ("remove-cron", "remove only this job's managed crontab block; retain backups"),
    ):
        actions.add_argument("--" + name, action="store_const", const=name, dest="action", help=help_text)
    p.add_argument("--schedule", default="30 2 * * *", help="five-field cron schedule (default: daily 02:30, machine timezone)")
    p.add_argument("--version", action="version", version=VERSION)
    args = p.parse_args(argv)
    if args.action is None:
        p.print_help()
    return args


def main(argv, script_path):
    os.umask(0o077)
    # Never pick up SDK/Poky wrappers or credentials injected into rsync options.
    os.environ["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
    os.environ["LC_ALL"] = "C.UTF-8"
    for key in tuple(os.environ):
        if key.startswith("RSYNC_"):
            os.environ.pop(key, None)
    args = parse_args(argv)
    if not args.action:
        return 0
    filename = path_value(args.config, "--config")
    if args.action == "init":
        if filename.exists() or filename.is_symlink():
            raise BackupError(f"Config already exists; not overwritten: {filename}")
        private_dir(filename.parent)
        fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(default_config(), f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        fsync_dir(filename.parent)
        print(f"Created {filename}\nEdit sources, destination and SMTP before running anything else.")
        return 0
    c = load_config(filename)
    if args.action == "init-destination":
        init_destination(c)
    elif args.action == "check":
        root, sources = validate_destination(c)
        latest_snapshot(c, root)
        smtp_password(c)
        available = check_space(c, root)
        print(f"Local preflight passed. Destination free: {available / 1024**3:.2f} GiB")
        for name, source in sources:
            print(f"  {name}: {source}")
        print("SMTP authentication, actual rsync access/ACLs and restore integrity are not proven by --check.")
    elif args.action == "dry-run":
        log = BoundedLog()
        result = {}
        copy_snapshot(c, run_id(), log, result, dry=True)
        print(log.tail())
        print(result["status"] + ": no snapshot, latest update, email or cron change")
        return result["backup_exit_code"]
    elif args.action == "run":
        return run_backup(c)
    elif args.action == "set-password":
        import getpass
        try:
            tty_fd = os.open("/dev/tty", os.O_RDWR)
            os.close(tty_fd)
        except OSError as exc:
            raise BackupError("--set-password requires a local controlling terminal") from exc
        first = getpass.getpass("SMTP app password: ")
        second = getpass.getpass("Repeat SMTP app password: ")
        if first != second:
            raise BackupError("Passwords did not match; nothing saved")
        save_password(c, first)
    elif args.action == "test-mail":
        state = setup_state(c)
        result = {"run_id": run_id(), "status": "TEST", "started": now(), "finished": now(),
                  "backup_exit_code": 0, "error": "SMTP test only. No backup was run."}
        ok, message = notify(c, result, BoundedLog())
        print(message)
        if ok:
            atomic_json(state / "mail-test.json", {"epoch": time.time(), "fingerprint": mail_fingerprint(c)})
        return 0 if ok else 4
    elif args.action == "retry-mail":
        ok, message = retry_mail(c)
        print(message)
        return 0 if ok else 4
    elif args.action == "show-cron":
        print(cron_line(c, filename, script_path, args.schedule))
    elif args.action in ("install-cron", "remove-cron"):
        manage_cron(c, filename, script_path, args.schedule, remove=args.action == "remove-cron")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[2:], Path(sys.argv[1]).resolve()))
    except (BackupError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print("No email can be guaranteed before valid config/state/SMTP are available. Review local output.", file=sys.stderr)
        raise SystemExit(5)

PY_ENGINE
