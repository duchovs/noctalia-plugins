#!/usr/bin/env python3
"""Sidecar for the Noctalia "Claude Code" plugin.

Owns exactly one long-lived Claude Code session:

    claude -p --input-format stream-json --output-format stream-json --verbose

and exposes it over loopback HTTP + SSE, because Noctalia's Luau API can read a
process (runStream) but cannot write to one — there is no stdin. A one-shot
`claude -p` per message would work without this file, but it pays the Node/MCP
bootstrap and re-primes the prompt cache on every turn; holding the session open
pays both once. Everything else here follows from that one decision.

The wire format the CLI speaks is stream-json in both directions, including its
control protocol (initialize / interrupt / set_model / set_permission_mode, and
inbound can_use_tool permission requests). This file translates that into a
compact, render-ready transcript so the Luau panel does no parsing of its own.

Standard library only, by design: a Noctalia plugin should not require a pip
install or a node_modules to work after `git clone`.
"""

from __future__ import annotations

import errno
import json
import os
import queue
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Only used to label the request; the endpoint keys off the OAuth token.
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USAGE_BETA = "oauth-2025-04-20"

# Deltas arrive per token. Flushing each one would push thousands of SSE frames
# and re-renders per turn; 80ms is under the eye's fusion threshold and cuts the
# frame count by an order of magnitude.
FLUSH_INTERVAL = 0.08

# A transcript is a scrollback, not a database. Oldest items are dropped past
# this; the session itself keeps the real history and /compact still works.
MAX_ITEMS = 600

# Tool output shown inline is clamped — the panel offers the full text on demand.
TOOL_OUTPUT_CLAMP = 4000


def log(msg: str) -> None:
    sys.stderr.write("[claude-code-bridge] %s\n" % msg)
    sys.stderr.flush()


# ── Runtime directory / single-instance lock ────────────────────────────────


def runtime_dir() -> str:
    base = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    path = os.path.join(base, "noctalia-claude-code")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def lock_path() -> str:
    return os.path.join(runtime_dir(), "bridge.json")


def read_lock() -> dict | None:
    try:
        with open(lock_path(), "r") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError as exc:
        return exc.errno == errno.EPERM
    return True


def existing_healthy() -> dict | None:
    """Return the live instance's lock, or None. Idempotent start is the point:
    both the panel and the service may launch the bridge, and neither knows
    whether the other already did."""
    lock = read_lock()
    if not lock:
        return None
    pid = lock.get("pid")
    if not isinstance(pid, int) or not pid_alive(pid):
        return None
    try:
        req = urllib.request.Request(
            "http://127.0.0.1:%d/health" % lock["port"],
            headers={"X-Bridge-Token": lock.get("token", "")},
        )
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            return lock if resp.status == 200 else None
    except Exception:
        return None


def write_lock(port: int, token: str) -> None:
    payload = {
        "pid": os.getpid(),
        "port": port,
        "token": token,
        "started_at": int(time.time()),
    }
    tmp = lock_path() + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle)
    os.replace(tmp, lock_path())


# ── Transcript model ────────────────────────────────────────────────────────


class Transcript:
    """Append-and-patch list of render-ready items, guarded by one lock.

    Every mutation bumps `rev`, and every subscriber is fed the same event that
    produced it, so a late subscriber can take a snapshot and then follow deltas
    without a gap.
    """

    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.items: list[dict] = []
        self.rev = 0
        self.base = 0  # index of items[0], so ids stay stable after trimming
        self.subscribers: list[queue.Queue] = []
        self.status: dict = {"phase": "off"}
        self.caps: dict = {}

    # -- subscriptions

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=2048)
        with self.lock:
            self.subscribers.append(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self.lock:
            if q in self.subscribers:
                self.subscribers.remove(q)

    def publish(self, event: dict) -> None:
        with self.lock:
            dead = []
            for q in self.subscribers:
                try:
                    q.put_nowait(event)
                except queue.Full:
                    # A subscriber that cannot keep up is a stalled panel; drop
                    # it rather than let its backlog hold the session's memory.
                    dead.append(q)
            for q in dead:
                self.subscribers.remove(q)

    # -- mutations

    def append(self, item: dict) -> int:
        with self.lock:
            idx = self.base + len(self.items)
            item["i"] = idx
            self.items.append(item)
            if len(self.items) > MAX_ITEMS:
                drop = len(self.items) - MAX_ITEMS
                self.items = self.items[drop:]
                self.base += drop
            self.rev += 1
            self.publish({"e": "item", "item": item, "rev": self.rev})
            return idx

    def patch(self, idx: int, **fields) -> None:
        with self.lock:
            pos = idx - self.base
            if pos < 0 or pos >= len(self.items):
                return
            self.items[pos].update(fields)
            self.rev += 1
            fields["i"] = idx
            self.publish({"e": "patch", "item": fields, "rev": self.rev})

    def find_tool(self, tool_id: str) -> int | None:
        with self.lock:
            for item in reversed(self.items):
                if item.get("kind") == "tool" and item.get("tid") == tool_id:
                    return item["i"]
        return None

    def set_status(self, **fields) -> None:
        with self.lock:
            self.status.update(fields)
            snapshot = dict(self.status)
        self.publish({"e": "status", "status": snapshot})

    def set_caps(self, caps: dict) -> None:
        with self.lock:
            self.caps = caps
        self.publish({"e": "caps", "caps": caps})

    def reset(self) -> None:
        with self.lock:
            # Advance past the cleared range rather than restarting at zero: ids
            # must stay monotonic for the lifetime of the process, or an in-flight
            # patch for a dropped item could address a new one.
            self.base += len(self.items)
            self.items = []
            self.rev += 1
        self.publish({"e": "reset", "rev": self.rev})

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "rev": self.rev,
                "base": self.base,
                "items": list(self.items),
                "status": dict(self.status),
                "caps": dict(self.caps),
            }


# ── Tool rendering helpers ──────────────────────────────────────────────────

# One line that says what the call will actually do. Everything else is behind
# the expander; a transcript that shows full JSON for every call is unreadable.
def summarize_tool(name: str, payload: dict) -> str:
    if not isinstance(payload, dict):
        return ""
    getter = lambda *keys: next(
        (str(payload[k]) for k in keys if isinstance(payload.get(k), str)), ""
    )
    if name == "Bash":
        return getter("command")
    if name in ("Read", "Write", "NotebookEdit"):
        return getter("file_path", "notebook_path")
    if name == "Edit":
        return getter("file_path")
    if name == "Glob":
        return getter("pattern")
    if name == "Grep":
        pattern = getter("pattern")
        where = getter("path")
        return pattern + (" in " + where if where else "")
    if name in ("WebFetch", "WebSearch"):
        return getter("url", "query")
    if name in ("Task", "Agent"):
        return getter("description", "subagent_type")
    if name == "TodoWrite":
        todos = payload.get("todos")
        return "%d items" % len(todos) if isinstance(todos, list) else ""
    try:
        return json.dumps(payload)[:200]
    except (TypeError, ValueError):
        return ""


# Drives the accent color of the tool row. Deliberately coarse: the point is
# "should I be reading this one closely", not a taxonomy.
def classify_tool(name: str) -> str:
    if name == "Bash":
        return "exec"
    if name in ("Write", "Edit", "NotebookEdit"):
        return "write"
    if name in ("WebFetch", "WebSearch"):
        return "network"
    if name.startswith("mcp__"):
        return "mcp"
    return "read"


def block_text(block: dict) -> str:
    if isinstance(block, str):
        return block
    if not isinstance(block, dict):
        return ""
    if isinstance(block.get("text"), str):
        return block["text"]
    if isinstance(block.get("content"), list):
        return "".join(block_text(inner) for inner in block["content"])
    if isinstance(block.get("content"), str):
        return block["content"]
    return ""


# ── Stored sessions ─────────────────────────────────────────────────────────

# Claude Code keeps one JSONL per session under a per-directory folder whose name
# is the working directory with the separators rewritten. Rather than reproduce
# that encoding (and get it subtly wrong), each folder is identified by reading
# the `cwd` its own records carry.
SESSIONS_ROOT = "~/.claude/projects"
# A title lands within the first exchange, so a full scan of what can be a
# multi-megabyte transcript is never needed just to label a row.
TITLE_SCAN_LINES = 400


def _iter_json_lines(path: str, limit: int | None = None):
    try:
        with open(path, "r", errors="replace") as handle:
            for number, line in enumerate(handle):
                if limit is not None and number >= limit:
                    return
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


def session_dir_for(cwd: str) -> str | None:
    """The folder holding sessions for `cwd`, found by what the records say."""
    root = os.path.expanduser(SESSIONS_ROOT)
    if not os.path.isdir(root) or not cwd:
        return None
    target = os.path.realpath(cwd)
    for name in os.listdir(root):
        folder = os.path.join(root, name)
        if not os.path.isdir(folder):
            continue
        files = [f for f in os.listdir(folder) if f.endswith(".jsonl")]
        if not files:
            continue
        probe = os.path.join(folder, files[0])
        for record in _iter_json_lines(probe, 50):
            recorded = record.get("cwd")
            if isinstance(recorded, str) and recorded:
                if os.path.realpath(recorded) == target:
                    return folder
                break
    return None


def list_sessions(cwd: str) -> list[dict]:
    folder = session_dir_for(cwd)
    if folder is None:
        return []
    rows = []
    for name in os.listdir(folder):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(folder, name)
        try:
            stat = os.stat(path)
        except OSError:
            continue
        if stat.st_size == 0:
            continue
        title = ""
        fallback = ""
        for record in _iter_json_lines(path, TITLE_SCAN_LINES):
            kind = record.get("type")
            if kind == "custom-title" and isinstance(record.get("customTitle"), str):
                title = record["customTitle"]
                break
            if kind == "ai-title" and isinstance(record.get("aiTitle"), str):
                title = record["aiTitle"]
                break
            if not fallback and kind == "user" and not record.get("isMeta") and not record.get("isSidechain"):
                content = (record.get("message") or {}).get("content")
                text = content if isinstance(content, str) else ""
                # Slash-command echoes and injected caveats are wrapped in tags;
                # they name the machinery, not what the session was about.
                if isinstance(text, str) and text.lstrip()[:1] not in ("<", ""):
                    condensed = " ".join(text.split())
                    if len(condensed) >= 3:
                        fallback = condensed[:80]
        rows.append(
            {
                "id": name[:-6],
                "title": title or fallback or name[:-6][:8],
                "mtime": int(stat.st_mtime),
                "bytes": stat.st_size,
            }
        )
    rows.sort(key=lambda row: row["mtime"], reverse=True)
    return rows[:40]


def parse_ts(value) -> int:
    """Claude Code's own records carry an ISO-8601 `timestamp` field. Replayed
    history previously hardcoded 0 here, which is harmless while the panel
    doesn't render `ts`, but wrong data is wrong data."""
    if not isinstance(value, str):
        return 0
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def load_history(cwd: str, session_id: str, limit: int = 120) -> list[dict]:
    """Replay a stored session into transcript items.

    Resuming into an empty panel would hide the very context being resumed, so
    the prior exchange is rebuilt from the same JSONL the CLI reads. Sidechain
    (subagent) and meta records are skipped: they are machinery, not the
    conversation.
    """
    folder = session_dir_for(cwd)
    if folder is None:
        return []
    path = os.path.join(folder, session_id + ".jsonl")
    if not os.path.isfile(path):
        return []

    items: list[dict] = []
    pending: dict[str, int] = {}
    for record in _iter_json_lines(path):
        if record.get("isSidechain") or record.get("isMeta"):
            continue
        kind = record.get("type")
        message = record.get("message") or {}
        content = message.get("content")
        stamp = parse_ts(record.get("timestamp"))

        if kind == "user":
            if isinstance(content, str):
                text = content.strip()
                if text and not text.startswith("<"):
                    items.append({"kind": "user", "text": text, "ts": stamp})
            elif isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "tool_result":
                        position = pending.get(block.get("tool_use_id") or "")
                        if position is None:
                            continue
                        body = block_text(block)
                        items[position]["state"] = "error" if block.get("is_error") else "ok"
                        items[position]["output"] = body[:TOOL_OUTPUT_CLAMP]
                        items[position]["truncated"] = len(body) > TOOL_OUTPUT_CLAMP
                    elif block.get("type") == "text":
                        # Real user turns land here whenever the CLI records them
                        # as a content list instead of a bare string (routine —
                        # every session in this user's own history has some).
                        # The old code only scanned list-form content for
                        # tool_result blocks, so every one of these was silently
                        # dropped from resumed history despite being a real,
                        # visible turn in the live session.
                        text = (block.get("text") or "").strip()
                        if text and not text.startswith("<"):
                            items.append({"kind": "user", "text": text, "ts": stamp})
        elif kind == "assistant" and isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text" and (block.get("text") or "").strip():
                    items.append({"kind": "assistant", "text": block["text"], "streaming": False, "ts": stamp})
                elif block.get("type") == "thinking" and (block.get("thinking") or "").strip():
                    items.append({"kind": "thinking", "text": block["thinking"], "streaming": False, "ts": stamp})
                elif block.get("type") == "tool_use":
                    name = block.get("name") or "tool"
                    payload = block.get("input") or {}
                    pending[block.get("id") or ""] = len(items)
                    items.append(
                        {
                            "kind": "tool",
                            "tid": block.get("id") or "",
                            "name": name,
                            "risk": classify_tool(name),
                            "summary": summarize_tool(name, payload),
                            "input": json.dumps(payload, indent=2)[:4000],
                            "state": "ok",
                            "output": "",
                            "ts": stamp,
                        }
                    )

    return items[-limit:]


# ── The session ─────────────────────────────────────────────────────────────


class Session:
    """The Claude Code child process and the translation of its stream."""

    def __init__(self, transcript: Transcript, options: dict) -> None:
        self.tx = transcript
        self.options = options
        self.proc: subprocess.Popen | None = None
        self.write_lock = threading.Lock()
        self.pending: dict[str, threading.Event] = {}
        self.responses: dict[str, dict] = {}
        self.permissions: dict[str, dict] = {}
        self.counter = 0
        self.last_activity = time.time()
        # Set by /effort. Every turn re-emits a session-init frame, and reading
        # settings.json there would otherwise overwrite what the user just chose
        # with the on-disk default. Cleared on a model switch, where a per-model
        # override in settings becomes the better answer again.
        self.effort_override: str | None = None

        # Streaming assembly state, reset per assistant message.
        self.stream_lock = threading.Lock()
        self.open_blocks: dict[int, dict] = {}
        self.pending_flush: dict[int, str] = {}
        # Text blocks streamed for the message currently being assembled. The
        # full `assistant` frame repeats content that already arrived as deltas,
        # so it is only a source of text when nothing streamed — which is how
        # synthetic replies (slash commands, model "<synthetic>") arrive.
        self.streamed_text = 0
        self.flusher = threading.Thread(target=self._flush_loop, daemon=True)
        self.flusher.start()

    # -- process lifecycle

    def argv(self) -> list[str]:
        binary = self.options.get("binary") or "claude"
        args = [
            binary,
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        session_id = self.options.get("resume")
        if session_id:
            # --fork-session is load-bearing, not cosmetic: without it this
            # process shares the session ID with whatever else has it open
            # (e.g. a terminal or the desktop app), and Claude Code's Remote
            # Control ownership treats that as a single conversation with one
            # legitimate driver — the bridge's writes land in a session that
            # something else already owns, and nothing here renders. Forking
            # seeds this session from the same history but gives it its own
            # ID, so it never contends for ownership of the original.
            args += ["--resume", session_id, "--fork-session"]
        return args

    def start(self) -> None:
        cwd = self.options.get("working_dir") or os.path.expanduser("~")
        if not os.path.isdir(cwd):
            cwd = os.path.expanduser("~")
        self.tx.set_status(phase="starting", cwd=cwd, error="")
        try:
            self.proc = subprocess.Popen(
                self.argv(),
                cwd=cwd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                env=os.environ.copy(),
            )
        except OSError as exc:
            self.tx.set_status(phase="error", error="cannot start %r: %s" % (self.argv()[0], exc))
            return
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        threading.Thread(target=self._handshake, daemon=True).start()

    def stop(self) -> None:
        proc, self.proc = self.proc, None
        if not proc:
            return
        try:
            if proc.stdin:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        self.tx.set_status(phase="off")

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def restart(self, **option_updates) -> None:
        self.options.update(option_updates)
        self.stop()
        with self.stream_lock:
            self.open_blocks.clear()
            self.pending_flush.clear()
        self.start()

    # -- writing

    def write(self, payload: dict) -> bool:
        proc = self.proc
        if not proc or not proc.stdin or proc.poll() is not None:
            return False
        line = json.dumps(payload) + "\n"
        with self.write_lock:
            try:
                proc.stdin.write(line)
                proc.stdin.flush()
            except (OSError, ValueError):
                return False
        self.last_activity = time.time()
        return True

    def send_user(self, text: str) -> bool:
        # The CLI answers /effort with usage text, never with the current value,
        # so the only way to keep the header honest is to watch what goes past.
        match = re.match(r"^/effort\s+(\w+)\s*$", text.strip())
        if match and match.group(1).lower() in EFFORT_LEVELS:
            self.effort_override = match.group(1).lower()
            self.tx.set_status(effort=self.effort_override)

        self.tx.append({"kind": "user", "text": text, "ts": int(time.time())})
        ok = self.write(
            {
                "type": "user",
                "message": {"role": "user", "content": [{"type": "text", "text": text}]},
            }
        )
        if ok:
            self.tx.set_status(phase="busy")
        return ok

    def control(self, request: dict, timeout: float = 20.0) -> dict:
        """Send a control_request and block for its correlated response."""
        self.counter += 1
        request_id = "n%d-%d" % (os.getpid(), self.counter)
        event = threading.Event()
        self.pending[request_id] = event
        if not self.write({"type": "control_request", "request_id": request_id, "request": request}):
            self.pending.pop(request_id, None)
            return {"ok": False, "error": "session not running"}
        if not event.wait(timeout):
            self.pending.pop(request_id, None)
            return {"ok": False, "error": "timed out"}
        self.pending.pop(request_id, None)
        return self.responses.pop(request_id, {"ok": False, "error": "no response"})

    def _handshake(self) -> None:
        result = self.control({"subtype": "initialize"}, timeout=45.0)
        if not result.get("ok"):
            self.tx.set_status(phase="error", error="initialize failed: %s" % result.get("error"))
            return
        caps = result.get("data") or {}
        self.tx.set_caps(caps)
        fields = {
            # The model is not known until the first session-init frame, so this
            # is the top-level setting; it is refined per model once one lands.
            "effort": read_effort(""),
            "mode": caps.get("current_permission_mode", "default"),
            "account": (caps.get("account") or {}).get("email", ""),
            "plan": (caps.get("account") or {}).get("subscriptionType", ""),
        }
        # The handshake runs concurrently with the first turn, so it must not
        # declare the session idle if that turn has already moved it on — a
        # permission ask arriving first would otherwise be erased.
        with self.tx.lock:
            if self.tx.status.get("phase") in (None, "off", "starting"):
                fields["phase"] = "idle"
        self.tx.set_status(**fields)

        # Auto is this console's default: Claude Code decides when a call is
        # worth asking about, rather than prompting for everything or nothing.
        # Applied after the handshake so it survives whatever the CLI started in.
        if self.options.get("default_mode"):
            wanted = str(self.options["default_mode"])
            if wanted != fields.get("mode"):
                result = self.control({"subtype": "set_permission_mode", "mode": wanted})
                if result.get("ok"):
                    self.tx.set_status(mode=wanted)

    # -- answering an inbound permission request

    def answer_permission(self, request_id: str, allow: bool, message: str = "") -> bool:
        entry = self.permissions.pop(request_id, None)
        if entry is not None and entry.get("timer") is not None:
            entry["timer"].cancel()
        response = (
            {"behavior": "allow"}
            if allow
            else {"behavior": "deny", "message": message or "Denied from the Noctalia console."}
        )
        ok = self.write(
            {
                "type": "control_response",
                "response": {
                    "subtype": "success",
                    "request_id": request_id,
                    "response": response,
                },
            }
        )
        if entry is not None:
            self.tx.patch(
                entry["item"],
                state="allowed" if allow else "denied",
                detail=message,
            )
        self.tx.set_status(phase="busy" if self.alive() else "off")
        return ok

    # -- reading

    def _read_stderr(self) -> None:
        proc = self.proc
        if not proc or not proc.stderr:
            return
        for line in proc.stderr:
            line = line.strip()
            if line:
                log("child stderr: %s" % line[:500])

    def _read_stdout(self) -> None:
        proc = self.proc
        if not proc or not proc.stdout:
            return
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue
            try:
                self._dispatch(message)
            except Exception as exc:  # a malformed frame must not kill the reader
                log("dispatch error: %r" % exc)
        code = proc.poll()
        if self.proc is proc:  # not a deliberate stop
            self.tx.set_status(phase="error", error="session exited (code %s)" % code)

    def _dispatch(self, message: dict) -> None:
        kind = message.get("type")
        self.last_activity = time.time()

        if kind == "control_response":
            self._on_control_response(message)
        elif kind == "control_request":
            self._on_control_request(message)
        elif kind == "control_cancel_request":
            self._on_control_cancel(message)
        elif kind == "stream_event":
            self._on_stream_event(message.get("event") or {})
        elif kind == "assistant":
            self._on_assistant(message)
        elif kind == "user":
            self._on_user(message)
        elif kind == "system":
            self._on_system(message)
        elif kind == "rate_limit_event":
            info = message.get("rate_limit_info") or {}
            self.tx.set_status(rate_limit=info)
        elif kind == "result":
            self._on_result(message)

    def _on_control_response(self, message: dict) -> None:
        response = message.get("response") or {}
        request_id = response.get("request_id")
        if not request_id:
            return
        if response.get("subtype") == "success":
            self.responses[request_id] = {"ok": True, "data": response.get("response")}
        else:
            self.responses[request_id] = {
                "ok": False,
                "error": str(response.get("error") or "error"),
            }
        event = self.pending.get(request_id)
        if event:
            event.set()

    def _on_control_request(self, message: dict) -> None:
        request = message.get("request") or {}
        request_id = message.get("request_id") or ""
        if request.get("subtype") != "can_use_tool":
            # Nothing else is answerable here; say so rather than hang the turn.
            self.write(
                {
                    "type": "control_response",
                    "response": {
                        "subtype": "error",
                        "request_id": request_id,
                        "error": "unsupported control_request subtype",
                    },
                }
            )
            return

        name = request.get("tool_name") or "tool"
        payload = request.get("input") or {}
        policy = self.options.get("permission_prompts", "ask")

        if policy == "allow":
            self.answer_permission(request_id, True)
            return
        if policy == "deny":
            self.answer_permission(request_id, False, "Auto-denied by plugin policy.")
            return

        idx = self.tx.append(
            {
                "kind": "permission",
                "rid": request_id,
                "name": name,
                "risk": classify_tool(name),
                "summary": summarize_tool(name, payload),
                "input": json.dumps(payload, indent=2)[:4000],
                "state": "pending",
                "ts": int(time.time()),
            }
        )
        timeout = float(self.options.get("permission_timeout", 120))
        timer = threading.Timer(timeout, self._expire_permission, args=(request_id,))
        timer.daemon = True
        self.permissions[request_id] = {"item": idx, "at": time.time(), "timer": timer}
        self.tx.set_status(phase="awaiting")
        timer.start()

    def _expire_permission(self, request_id: str) -> None:
        if request_id in self.permissions:
            self.answer_permission(
                request_id, False, "No answer in the console before the timeout."
            )

    def _on_control_cancel(self, message: dict) -> None:
        request_id = message.get("request_id") or ""
        entry = self.permissions.pop(request_id, None)
        if entry is not None:
            if entry.get("timer") is not None:
                entry["timer"].cancel()
            self.tx.patch(entry["item"], state="cancelled")

    # -- streaming assembly

    def _on_stream_event(self, event: dict) -> None:
        kind = event.get("type")
        if kind == "message_start":
            with self.stream_lock:
                self.open_blocks.clear()
                self.streamed_text = 0
            self.tx.set_status(phase="busy")
            return

        if kind == "content_block_start":
            block = event.get("content_block") or {}
            block_type = block.get("type")
            if block_type not in ("text", "thinking"):
                return  # tool_use is reconciled from the full assistant message
            idx = self.tx.append(
                {
                    "kind": "assistant" if block_type == "text" else "thinking",
                    "text": "",
                    "streaming": True,
                    "ts": int(time.time()),
                }
            )
            with self.stream_lock:
                self.open_blocks[event.get("index", 0)] = {"item": idx}
                if block_type == "text":
                    self.streamed_text += 1
            return

        if kind == "content_block_delta":
            delta = event.get("delta") or {}
            piece = ""
            if delta.get("type") == "text_delta":
                piece = delta.get("text") or ""
            elif delta.get("type") == "thinking_delta":
                piece = delta.get("thinking") or ""
            else:
                return  # signature_delta and friends are not renderable
            if not piece:
                return
            with self.stream_lock:
                slot = self.open_blocks.get(event.get("index", 0))
                if not slot:
                    return
                idx = slot["item"]
                self.pending_flush[idx] = self.pending_flush.get(idx, "") + piece
            return

        if kind == "content_block_stop":
            with self.stream_lock:
                slot = self.open_blocks.pop(event.get("index", 0), None)
            if slot:
                self._flush_now()
                self.tx.patch(slot["item"], streaming=False)
            return

        if kind == "message_stop":
            self._flush_now()

    def _flush_loop(self) -> None:
        while True:
            time.sleep(FLUSH_INTERVAL)
            try:
                self._flush_now()
            except Exception as exc:
                log("flush error: %r" % exc)

    def _flush_now(self) -> None:
        with self.stream_lock:
            if not self.pending_flush:
                return
            batch = self.pending_flush
            self.pending_flush = {}
        for idx, piece in batch.items():
            # Read-modify-write under a single hold. _flush_now runs on both the
            # timer thread and the stdout reader, and patch() overwrites rather
            # than appends, so splitting these two would drop whichever piece
            # lost the race. Transcript.lock is an RLock, so patch() re-entering
            # it here is fine.
            with self.tx.lock:
                pos = idx - self.tx.base
                if pos < 0 or pos >= len(self.tx.items):
                    continue
                current = self.tx.items[pos].get("text", "") + piece
                self.tx.patch(idx, text=current)

    # -- whole messages

    def _on_assistant(self, message: dict) -> None:
        content = (message.get("message") or {}).get("content")
        if not isinstance(content, list):
            return
        # Materialize any buffered deltas first, so the streamed items are
        # complete before this frame is reconciled against them.
        self._flush_now()
        with self.stream_lock:
            streamed = self.streamed_text
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                name = block.get("name") or "tool"
                payload = block.get("input") or {}
                self.tx.append(
                    {
                        "kind": "tool",
                        "tid": block.get("id") or "",
                        "name": name,
                        "risk": classify_tool(name),
                        "summary": summarize_tool(name, payload),
                        "input": json.dumps(payload, indent=2)[:4000],
                        "state": "running",
                        "output": "",
                        "ts": int(time.time()),
                    }
                )
            elif block.get("type") == "text" and streamed == 0:
                # Nothing streamed for this message, so this frame is the only
                # carrier of the text: a synthetic reply to a slash command.
                text = block.get("text") or ""
                if text:
                    self.tx.append(
                        {"kind": "assistant", "text": text, "streaming": False, "ts": int(time.time())}
                    )

    def _on_user(self, message: dict) -> None:
        content = (message.get("message") or {}).get("content")
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            idx = self.tx.find_tool(block.get("tool_use_id") or "")
            if idx is None:
                continue
            text = block_text(block)
            truncated = len(text) > TOOL_OUTPUT_CLAMP
            self.tx.patch(
                idx,
                state="error" if block.get("is_error") else "ok",
                output=text[:TOOL_OUTPUT_CLAMP],
                truncated=truncated,
            )

    def _on_system(self, message: dict) -> None:
        subtype = message.get("subtype")
        if subtype == "init":
            servers = message.get("mcp_servers") or []
            failed = [s.get("name") for s in servers if s.get("status") == "failed"]
            model = message.get("model", "") or self.tx.status.get("model", "")
            self.tx.set_status(
                session_id=message.get("session_id", ""),
                cwd=message.get("cwd", ""),
                model=model,
                effort=self.effort_override or read_effort(model),
                tools=len(message.get("tools") or []),
                mcp_failed=failed,
            )
        elif subtype == "status":
            state = message.get("status")
            if state:
                self.tx.set_status(activity=state)

    def _on_result(self, message: dict) -> None:
        self._flush_now()
        usage = message.get("usage") or {}
        self.tx.append(
            {
                "kind": "result",
                "error": bool(message.get("is_error")),
                "subtype": message.get("subtype") or "",
                "cost": message.get("total_cost_usd") or 0,
                "ms": message.get("duration_ms") or message.get("duration_api_ms") or 0,
                "input": usage.get("input_tokens") or 0,
                "output": usage.get("output_tokens") or 0,
                "cache_read": usage.get("cache_read_input_tokens") or 0,
                "cache_write": usage.get("cache_creation_input_tokens") or 0,
                "ts": int(time.time()),
            }
        )
        self.tx.set_status(
            phase="idle",
            session_id=message.get("session_id", "") or self.tx.status.get("session_id", ""),
            activity="",
        )


# ── Usage ───────────────────────────────────────────────────────────────────


EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max", "auto")


def read_effort(model: str = "") -> str:
    """Current effort level for `model`.

    Neither the initialize handshake nor the session-init frame reports effort,
    so it is read from Claude Code's own settings, where a per-model override in
    `modelSettings` beats the top-level `effortLevel`. `/effort` typed in the
    console updates this optimistically — the CLI has no readback for it.
    """
    try:
        with open(os.path.expanduser("~/.claude/settings.json"), "r") as handle:
            settings = json.load(handle)
    except (OSError, ValueError):
        return ""
    if not isinstance(settings, dict):
        return ""
    per_model = settings.get("modelSettings")
    if isinstance(per_model, dict) and model:
        entry = per_model.get(model)
        if isinstance(entry, dict) and isinstance(entry.get("effortLevel"), str):
            return entry["effortLevel"]
    top = settings.get("effortLevel")
    return top if isinstance(top, str) else ""


def read_oauth_token() -> str | None:
    path = os.path.expanduser("~/.claude/.credentials.json")
    try:
        with open(path, "r") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    oauth = data.get("claudeAiOauth") or {}
    token = oauth.get("accessToken")
    return token if isinstance(token, str) and token else None


def fetch_usage(cli_version: str = "2.1.241") -> dict:
    """The same endpoint Claude Code itself reads for /usage. Reported as-is;
    an expired token is a re-auth prompt, never a silent refresh — rotating the
    token out from under the CLI would break its own session."""
    token = read_oauth_token()
    if not token:
        return {"ok": False, "error": "no_credentials"}
    request = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "claude-code/" + cli_version,
            "anthropic-beta": USAGE_BETA,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as resp:
            return {"ok": True, "data": json.load(resp)}
    except urllib.error.HTTPError as exc:
        return {"ok": False, "error": "http_%d" % exc.code}
    except Exception as exc:
        return {"ok": False, "error": type(exc).__name__}


# ── HTTP surface ────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "noctalia-claude-code/1.0"

    # The stock handler logs every request to stderr; the journal does not need
    # a line per SSE frame.
    def log_message(self, fmt, *args) -> None:  # noqa: A003
        pass

    # -- helpers

    @property
    def app(self):
        return self.server.app  # type: ignore[attr-defined]

    def authorized(self) -> bool:
        return secrets.compare_digest(
            self.headers.get("X-Bridge-Token", ""), self.app.token
        )

    def reply(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, OSError):
            return {}

    # -- routes

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            if not self.authorized():
                return self.reply(403, {"error": "forbidden"})
            return self.reply(200, {"ok": True, "pid": os.getpid()})
        if not self.authorized():
            return self.reply(403, {"error": "forbidden"})
        if path == "/snapshot":
            return self.reply(200, self.app.tx.snapshot())
        if path == "/usage":
            return self.reply(200, self.app.usage())
        if path == "/sessions":
            return self.reply(200, {"sessions": list_sessions(self.app.current_cwd())})
        if path == "/events":
            return self.stream_events()
        self.reply(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self.authorized():
            return self.reply(403, {"error": "forbidden"})
        path = self.path.split("?", 1)[0]
        payload = self.body()
        app = self.app

        if path == "/send":
            text = str(payload.get("text") or "")
            if not text.strip():
                return self.reply(400, {"error": "empty"})
            app.ensure_session()
            return self.reply(200, {"ok": app.session.send_user(text)})

        if path == "/control":
            subtype = str(payload.get("subtype") or "")
            if subtype not in ("interrupt", "set_model", "set_permission_mode", "initialize"):
                return self.reply(400, {"error": "unsupported subtype"})
            request = {"subtype": subtype}
            if subtype == "set_model" and payload.get("model") is not None:
                request["model"] = payload["model"]
            if subtype == "set_permission_mode":
                request["mode"] = payload.get("mode") or "default"
            app.ensure_session()
            result = app.session.control(request)
            if result.get("ok") and subtype == "set_permission_mode":
                app.tx.set_status(mode=request["mode"])
            if result.get("ok") and subtype == "set_model":
                chosen = request.get("model") or ""
                app.session.effort_override = None
                app.tx.set_status(model=chosen, effort=read_effort(chosen))
            if result.get("ok") and subtype == "initialize":
                app.tx.set_caps(result.get("data") or {})
            return self.reply(200, result)

        if path == "/permission":
            request_id = str(payload.get("rid") or "")
            allow = bool(payload.get("allow"))
            return self.reply(
                200,
                {"ok": app.session.answer_permission(request_id, allow, str(payload.get("message") or ""))},
            )

        if path == "/session":
            action = str(payload.get("action") or "new")
            if action == "new":
                app.tx.reset()
                app.session.restart(resume=None, working_dir=payload.get("cwd") or app.session.options.get("working_dir"))
            elif action == "cwd":
                app.tx.reset()
                app.session.restart(resume=None, working_dir=payload.get("cwd") or "")
            elif action == "options":
                app.session.options.update(payload.get("options") or {})
            elif action == "resume":
                session_id = str(payload.get("id") or "")
                if not session_id:
                    return self.reply(400, {"error": "missing id"})
                # Replay first, then hand the id to the CLI: the panel should
                # show the conversation it is rejoining, not an empty box.
                history = load_history(app.current_cwd(), session_id)
                app.tx.reset()
                for item in history:
                    app.tx.append(item)
                app.session.restart(resume=session_id)
            elif action == "start":
                # Warm the CLI when the console opens rather than on the first
                # message, so its Node/MCP boot overlaps with the user typing
                # instead of being added to the first reply's latency.
                app.ensure_session()
            elif action == "stop":
                app.session.stop()
            return self.reply(200, {"ok": True})

        if path == "/clear":
            app.tx.reset()
            return self.reply(200, {"ok": True})

        if path == "/shutdown":
            threading.Timer(0.2, app.shutdown).start()
            return self.reply(200, {"ok": True})

        self.reply(404, {"error": "not found"})

    # -- SSE

    def stream_events(self) -> None:
        q = self.app.tx.subscribe()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            # A subscriber that connects mid-turn needs the current picture
            # before the deltas make sense.
            self.write_event({"e": "hello", "snapshot": self.app.tx.snapshot()})
            while True:
                try:
                    event = q.get(timeout=15)
                except queue.Empty:
                    # Comment frame: keeps the socket (and any NAT in between)
                    # from timing the stream out during a long think.
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                self.write_event(event)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.app.tx.unsubscribe(q)

    def write_event(self, event: dict) -> None:
        payload = json.dumps(event, separators=(",", ":"))
        self.wfile.write(b"data: " + payload.encode() + b"\n\n")
        self.wfile.flush()


class App:
    def __init__(self, options: dict) -> None:
        self.token = secrets.token_urlsafe(24)
        self.tx = Transcript()
        self.options = options
        self.session = Session(self.tx, options)
        self.httpd: ThreadingHTTPServer | None = None
        self._usage_cache: dict = {"ok": False, "error": "not_fetched"}
        self._usage_at = 0.0
        self._stopping = False

    def current_cwd(self) -> str:
        recorded = self.tx.status.get("cwd")
        if isinstance(recorded, str) and recorded:
            return recorded
        configured = self.options.get("working_dir") or ""
        return configured or os.path.expanduser("~")

    def ensure_session(self) -> None:
        if not self.session.alive():
            self.session.start()

    def usage(self) -> dict:
        # A short floor: the bar widget, the panel header and a manual refresh
        # can all ask within the same second.
        if time.time() - self._usage_at < 30 and self._usage_cache.get("ok"):
            return self._usage_cache
        self._usage_cache = fetch_usage()
        self._usage_at = time.time()
        return self._usage_cache

    def idle_watch(self) -> None:
        while not self._stopping:
            time.sleep(30)
            minutes = int(self.options.get("idle_shutdown_minutes") or 0)
            if minutes <= 0 or not self.session.alive():
                continue
            if self.tx.status.get("phase") in ("busy", "awaiting"):
                continue
            if time.time() - self.session.last_activity > minutes * 60:
                log("idle for %d minutes — stopping session" % minutes)
                self.session.stop()

    def shutdown(self) -> None:
        self._stopping = True
        self.session.stop()
        try:
            os.unlink(lock_path())
        except OSError:
            pass
        if self.httpd:
            self.httpd.shutdown()

    def run(self) -> None:
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.httpd.app = self  # type: ignore[attr-defined]
        port = self.httpd.socket.getsockname()[1]
        write_lock(port, self.token)
        log("listening on 127.0.0.1:%d" % port)

        # shutdown() calls httpd.shutdown(), which blocks until the serve_forever
        # loop exits. A signal handler runs on the main thread — the same thread
        # that loop is on — so calling it directly deadlocks and the process
        # ignores SIGTERM. Hand it to a helper thread instead.
        def on_signal(*_):
            threading.Thread(target=self.shutdown, daemon=True).start()

        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, on_signal)

        threading.Thread(target=self.idle_watch, daemon=True).start()
        if self.options.get("eager"):
            self.ensure_session()
        try:
            self.httpd.serve_forever()
        finally:
            self.session.stop()


def main() -> int:
    # Options arrive as argv, not env: Noctalia's runAsync executes an argv table
    # directly with no shell, so there is nowhere to set a variable — and keeping
    # the shell out is what makes a user-supplied working directory safe to pass.
    def flag(name: str, fallback: str) -> str:
        token = "--" + name
        if token in sys.argv:
            position = sys.argv.index(token) + 1
            if position < len(sys.argv):
                return sys.argv[position]
        return os.environ.get("CC_" + name.replace("-", "_").upper(), fallback)

    def int_flag(name: str, fallback: int) -> int:
        try:
            return int(flag(name, str(fallback)))
        except ValueError:
            return fallback

    options = {
        "binary": flag("binary", "claude"),
        "working_dir": flag("working-dir", ""),
        "permission_prompts": flag("permission-prompts", "ask"),
        "permission_timeout": int_flag("permission-timeout", 120),
        "idle_shutdown_minutes": int_flag("idle-minutes", 0),
        "default_mode": flag("default-mode", "auto"),
        "eager": "--eager" in sys.argv or os.environ.get("CC_EAGER", "") == "1",
    }

    if "--print-endpoint" in sys.argv:
        # How the Luau side discovers a bridge it did not start: run this, read
        # one line of JSON. Starting is the same command without the flag.
        live = existing_healthy()
        print(json.dumps(live or {"error": "not running"}))
        return 0 if live else 1

    live = existing_healthy()
    if live:
        # Someone beat us to it. Print its endpoint so the caller can use it and
        # exit successfully — starting twice must never be an error.
        print(json.dumps(live))
        return 0

    App(options).run()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
