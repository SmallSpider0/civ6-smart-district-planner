#!/usr/bin/env python3
"""civ6tuner - minimal FireTuner client for Civilization VI.

Lets agents and scripts run Lua inside the running game and capture Lua
print() output, as a substitute for Lua.log (which the macOS build does not
write). Requires `EnableTuner 1` in AppOptions.txt; the game then listens on
127.0.0.1:4318. The game accepts only ONE tuner client at a time, so the
intended setup is a long-running `serve` process that owns the connection,
appends every output frame to a log file, and accepts exec requests on a
local control port. `exec` and `states` talk to that daemon when it is
running and fall back to a direct connection otherwise.

Wire format (reverse engineered by the community, verified against 1.0.12.54):
  frame   = uint32 LE payload_length | uint32 LE tag | payload
  payload = UTF-8 text terminated by NUL (length includes the NUL)
  tag 4   = handshake: send "APP:" -> app id; send "LSQ:" -> "idx\\0name\\0..."
  tag 3   = command:   send "CMD:<state idx>:<lua>"; game replies with an ack
  tag 0xFFFFFFFF = output: "O\\0<state name>: <printed text>\\0"

Usage:
  civ6tuner.py serve [--log PATH]          own the connection, log output
  civ6tuner.py states                      list Lua states (index, name)
  civ6tuner.py exec [-s STATE] CODE|-f FILE run Lua, print its output
Exit codes: 0 ok, 1 Lua error, 2 connection/protocol problem, 3 timeout.
"""

import argparse
import datetime
import json
import os
import queue
import random
import socket
import socketserver
import struct
import sys
import threading
import time

GAME_HOST = "127.0.0.1"
# 4319 also accepts connections but does not answer requests (observed on
# macOS 1.0.12.54); probing it only leaves dead sockets, so use 4318 only.
GAME_PORTS = (4318,)
CONTROL_PORT = 43180       # local daemon control port (JSON lines)

TAG_COMMAND = 3
TAG_HANDSHAKE = 4
TAG_OUTPUT = 0xFFFFFFFF
HEADER = struct.Struct("<II")

END_MARK = "<<SDP_TUNER_END:{}>>"
ERR_MARK = "<<SDP_TUNER_ERR>>"

DEFAULT_LOG = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs", "tuner-lua.log"
)


class TunerError(Exception):
    """Connection or protocol failure."""


class LuaTimeout(TunerError):
    """The game did not report completion in time."""


def now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def parse_output(payload):
    """Split an output frame into (state name, text)."""
    parts = payload.split(b"\x00")
    text = parts[1] if len(parts) > 1 else parts[0]
    text = text.decode("utf-8", errors="replace")
    state, sep, rest = text.partition(": ")
    if sep and state and "\n" not in state:
        return state, rest
    return "", text


def wrap_lua(code, nonce):
    """Wrap user code so compile and runtime errors are reported and the end
    of its output is marked. Uses loadstring when the state provides it."""
    level = 0
    while ("]" + "=" * level + "]") in code:
        level += 1
    eq = "=" * level
    end_mark = END_MARK.format(nonce)
    return (
        "local __src = [" + eq + "[\n" + code + "\n]" + eq + "]\n"
        "local __ld = loadstring or load\n"
        "local __f, __e\n"
        "if __ld then __f, __e = __ld(__src, '=tuner') else __e = 'no loadstring in this state' end\n"
        "if __f then\n"
        "  local __ok, __err = pcall(__f)\n"
        "  if not __ok then print('" + ERR_MARK + "' .. tostring(__err)) end\n"
        "else print('" + ERR_MARK + "' .. tostring(__e)) end\n"
        "print('" + end_mark + "')\n"
    )


class TunerConnection:
    """One connection to the game's tuner port. A reader thread splits the
    stream into frames; output frames go to listeners, handshake replies to a
    queue."""

    def __init__(self, port=None, connect_timeout=3.0):
        self.port = port
        self.connect_timeout = connect_timeout
        self.sock = None
        self.app_id = ""
        self.states = []  # [(index, name)] in the order the game reports
        self._send_lock = threading.Lock()
        self._handshake = queue.Queue()
        self._listeners = []
        self._listeners_lock = threading.Lock()
        self.closed = threading.Event()

    # -- framing ---------------------------------------------------------
    def _send(self, tag, text):
        data = text.encode("utf-8") + b"\x00"
        with self._send_lock:
            self.sock.sendall(HEADER.pack(len(data), tag) + data)

    def _read_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise TunerError("game closed the tuner connection")
            buf += chunk
        return buf

    def _reader(self):
        try:
            while True:
                length, tag = HEADER.unpack(self._read_exact(HEADER.size))
                payload = self._read_exact(length) if length else b""
                if tag == TAG_OUTPUT:
                    state, text = parse_output(payload)
                    with self._listeners_lock:
                        listeners = list(self._listeners)
                    for fn in listeners:
                        fn(state, text)
                elif tag == TAG_HANDSHAKE:
                    self._handshake.put(payload)
                # tag 3 frames are command acks; nothing to do with them
        except (OSError, TunerError):
            pass
        finally:
            self.closed.set()

    def add_listener(self, fn):
        with self._listeners_lock:
            self._listeners.append(fn)

    def remove_listener(self, fn):
        with self._listeners_lock:
            if fn in self._listeners:
                self._listeners.remove(fn)

    # -- session ---------------------------------------------------------
    def connect(self):
        ports = (self.port,) if self.port else GAME_PORTS
        last = None
        for port in ports:
            try:
                self._open(port)
                if self.states:
                    return self
                last = TunerError("port %d exposes no Lua states" % port)
            except OSError as e:
                last = TunerError("cannot connect to %s:%d (%s)" % (GAME_HOST, port, e))
            self.close()
        raise last or TunerError("no tuner port available")

    def _open(self, port):
        self.closed.clear()
        self._handshake = queue.Queue()
        self.sock = socket.create_connection((GAME_HOST, port), timeout=self.connect_timeout)
        self.sock.settimeout(None)
        self.port = port
        threading.Thread(target=self._reader, daemon=True).start()
        self._send(TAG_HANDSHAKE, "APP:")
        self.app_id = self._handshake_reply().rstrip(b"\x00").decode("utf-8", "replace")
        self.refresh_states()

    def _handshake_reply(self, timeout=5.0):
        try:
            return self._handshake.get(timeout=timeout)
        except queue.Empty:
            raise TunerError("no handshake reply from the game")

    def refresh_states(self):
        self._send(TAG_HANDSHAKE, "LSQ:")
        tokens = [t for t in self._handshake_reply().split(b"\x00") if t]
        states = []
        for i in range(0, len(tokens) - 1, 2):
            try:
                states.append((int(tokens[i]), tokens[i + 1].decode("utf-8", "replace")))
            except ValueError:
                continue
        self.states = states
        return states

    def resolve_state(self, state):
        """Map a state name or numeric index to the game's index. Names are
        refreshed from the game when not found (states change on load)."""
        if isinstance(state, int) or str(state).isdigit():
            return int(state)
        for attempt in (0, 1):
            for idx, name in self.states:
                if name == state:
                    return idx
            if attempt == 0:
                self.refresh_states()
        names = ", ".join(sorted({n for _, n in self.states}))
        raise TunerError("Lua state %r not found; available: %s" % (state, names))

    def execute(self, state, code, timeout=10.0, raw=False):
        """Run code in a Lua state. Returns (lines, error or None)."""
        idx = self.resolve_state(state)
        state_name = dict(self.states).get(idx, str(idx))
        nonce = "%d_%06d" % (int(time.time()), random.randint(0, 999999))
        end_mark = END_MARK.format(nonce)
        lines, error = [], None
        done = threading.Event()

        def on_output(st, text):
            nonlocal error
            if st != state_name or done.is_set():
                return
            if text == end_mark:
                done.set()
            elif text.startswith(ERR_MARK):
                error = text[len(ERR_MARK):]
            else:
                lines.append(text)

        self.add_listener(on_output)
        try:
            self._send(TAG_COMMAND, "CMD:%d:%s" % (idx, code if raw else wrap_lua(code, nonce)))
            if raw:
                time.sleep(min(timeout, 1.0))
                return lines, None
            deadline = time.time() + timeout
            while not done.wait(0.1):
                if self.closed.is_set():
                    raise TunerError("connection lost while waiting for output")
                if time.time() > deadline:
                    raise LuaTimeout("no completion marker within %.1fs (output so far: %d lines)"
                                     % (timeout, len(lines)))
            return lines, error
        finally:
            self.remove_listener(on_output)

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None


def handle_request(conn, lock, req):
    """Run one states/exec request on a connection; returns a JSON-able dict."""
    if conn is None or conn.closed.is_set():
        return {"ok": False, "kind": "connection", "error": "game tuner not connected"}
    try:
        with lock:
            if req.get("op") == "states":
                return {"ok": True, "states": conn.refresh_states()}
            lines, err = conn.execute(req.get("state", "InGame"), req["code"],
                                      float(req.get("timeout", 10)), bool(req.get("raw")))
            return {"ok": err is None, "kind": "lua" if err else None,
                    "output": lines, "error": err}
    except LuaTimeout as e:
        return {"ok": False, "kind": "timeout", "error": str(e)}
    except TunerError as e:
        return {"ok": False, "kind": "connection", "error": str(e)}


# -- daemon ----------------------------------------------------------------
class Daemon:
    """Owns the game connection, reconnects when the game restarts, logs all
    output, and serves exec/states requests on CONTROL_PORT."""

    def __init__(self, log_path, port=None):
        self.log_path = log_path
        self.port = port
        self.conn = None
        self.lock = threading.Lock()  # one exec at a time
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        self.log_file = open(log_path, "a", encoding="utf-8", buffering=1)

    def log(self, state, text):
        if text.startswith(END_MARK.split("{")[0]):
            return
        for line in text.splitlines() or [""]:
            self.log_file.write("[%s] %s: %s\n" % (now(), state or "?", line))

    def note(self, text):
        self.log_file.write("[%s] -- %s\n" % (now(), text))
        print("[%s] %s" % (now(), text), flush=True)

    def maintain(self):
        while True:
            if self.conn is None or self.conn.closed.is_set():
                if self.conn is not None:
                    self.note("connection lost; reconnecting")
                    self.conn.close()
                    self.conn = None
                try:
                    conn = TunerConnection(self.port).connect()
                    conn.add_listener(self.log)
                    self.conn = conn
                    self.note("connected to port %d (%s), %d Lua states"
                              % (conn.port, conn.app_id or "unknown app", len(conn.states)))
                except TunerError:
                    pass
            time.sleep(2.0)

    def handle(self, req):
        return handle_request(self.conn, self.lock, req)

    def serve(self):
        daemon = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                line = self.rfile.readline()
                try:
                    resp = daemon.handle(json.loads(line))
                except (ValueError, KeyError) as e:
                    resp = {"ok": False, "kind": "connection", "error": "bad request: %s" % e}
                self.wfile.write((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))

        socketserver.ThreadingTCPServer.allow_reuse_address = True
        server = socketserver.ThreadingTCPServer(("127.0.0.1", CONTROL_PORT), Handler)
        threading.Thread(target=self.maintain, daemon=True).start()
        self.note("tuner daemon up; control 127.0.0.1:%d; log %s" % (CONTROL_PORT, self.log_path))
        server.serve_forever()


def daemon_request(req, timeout):
    """Send one request to a running daemon; None when no daemon listens."""
    try:
        s = socket.create_connection(("127.0.0.1", CONTROL_PORT), timeout=1.0)
    except OSError:
        return None
    with s:
        s.settimeout(timeout + 5)
        s.sendall((json.dumps(req) + "\n").encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)


def direct_request(req, port):
    conn = TunerConnection(port)
    try:
        conn.connect()
        return handle_request(conn, threading.Lock(), req)
    except TunerError as e:
        return {"ok": False, "kind": "connection", "error": str(e)}
    finally:
        conn.close()


def request(req, port=None):
    """Run one states/exec request through the daemon when it is up, else
    over a direct connection. Returns the JSON-able result dict."""
    resp = daemon_request(req, float(req.get("timeout", 10.0)))
    return resp if resp is not None else direct_request(req, port)


EXIT_CODES = {None: 0, "lua": 1, "connection": 2, "timeout": 3}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Civilization VI FireTuner client")
    ap.add_argument("--port", type=int, help="game tuner port (default 4318)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("serve", help="own the connection, log output, accept exec requests")
    sp.add_argument("--log", default=DEFAULT_LOG)
    sub.add_parser("states", help="list Lua states")
    ep = sub.add_parser("exec", help="run Lua and print its output")
    ep.add_argument("code", nargs="?", help="Lua code (or use -f)")
    ep.add_argument("-f", "--file", help="read Lua code from a file")
    ep.add_argument("-s", "--state", default="InGame", help="state name or index (default InGame)")
    ep.add_argument("-t", "--timeout", type=float, default=10.0)
    ep.add_argument("--raw", action="store_true", help="send code unwrapped (no error capture)")
    ep.add_argument("--json", action="store_true", help="print the full JSON result")
    args = ap.parse_args(argv)

    if args.cmd == "serve":
        Daemon(args.log, args.port).serve()
        return 0

    if args.cmd == "states":
        req = {"op": "states"}
    else:
        if args.file:
            with open(args.file, encoding="utf-8") as fh:
                code = fh.read()
        elif args.code is not None:
            code = args.code
        else:
            code = sys.stdin.read()
        req = {"op": "exec", "state": args.state, "code": code,
               "timeout": args.timeout, "raw": args.raw}

    resp = request(req, args.port)

    if getattr(args, "json", False):
        print(json.dumps(resp, ensure_ascii=False, indent=2))
    elif args.cmd == "states" and resp.get("ok"):
        for idx, name in resp["states"]:
            print("%4d  %s" % (idx, name))
    else:
        for line in resp.get("output") or []:
            print(line)
        sys.stdout.flush()
        if resp.get("error"):
            print("%s error: %s" % (resp.get("kind"), resp["error"]), file=sys.stderr)
    return EXIT_CODES.get(resp.get("kind"), 2) if not resp.get("ok") else 0


if __name__ == "__main__":
    sys.exit(main())
