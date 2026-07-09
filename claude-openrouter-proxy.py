#!/usr/bin/env python3
"""
claude-openrouter-proxy — make always-on reasoning models (grok-4.5, etc.) usable
from Claude Code via OpenRouter's Anthropic-compatible endpoint.

OpenRouter returns `thinking` / `redacted_thinking` content blocks with empty
signatures. Claude Code can't validate those and silently discards the whole
assistant message, so the model's real text/tool_use never reaches you. This
proxy sits between Claude Code and OpenRouter, forwards requests unchanged (the
OpenRouter key flows through Claude Code's Authorization header), and rewrites
responses to drop those blocks, re-indexing the survivors so the SSE stream stays
well-formed.

Usage:
  claude-openrouter-proxy.py [portfile]
    Binds 127.0.0.1 on an ephemeral port. Writes the chosen port to `portfile`
    (if given) after binding, else prints it to stdout. When a portfile is given
    (wrapper mode), the proxy also self-terminates if its parent process dies,
    so a SIGKILLed wrapper can't leave an orphan.

Env:
  OPENROUTER_BASE_URL                upstream base (default https://openrouter.ai/api)
  OPENROUTER_PROXY_IDLE_TIMEOUT_MS   per-socket-op upstream timeout (default 1200000)
  CLOR_DEBUG                         dir to dump raw-in / filtered-out streams
"""
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request

UPSTREAM = os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api").rstrip("/")
# Applies per socket operation (connect, each read) — not to the whole response,
# so long generations are fine as long as bytes keep flowing / pings arrive.
IDLE_TIMEOUT = int(os.environ.get("OPENROUTER_PROXY_IDLE_TIMEOUT_MS", "1200000")) / 1000.0
DEBUG = os.environ.get("CLOR_DEBUG")  # dir to dump raw-in / filtered-out streams

STRIP = {"thinking", "redacted_thinking"}
# hop-by-hop + anything that would break re-framing / length after rewrite
HOP = {"host", "content-length", "connection", "accept-encoding", "keep-alive",
       "proxy-connection", "transfer-encoding", "te", "trailer", "upgrade", "expect"}


def _dbg(name, data):
    if not DEBUG:
        return
    try:
        with open(os.path.join(DEBUG, name), "ab") as f:
            f.write(data)
    except Exception:
        pass


def fwd_headers(headers):
    return {k: v for k, v in headers.items() if k.lower() not in HOP}


def anthropic_error(message, etype="api_error"):
    return json.dumps({"type": "error", "error": {"type": etype, "message": message}}).encode()


class StreamFilter:
    """Incrementally rewrites an Anthropic SSE stream: drops STRIP content blocks
    and re-indexes the survivors so indices stay contiguous from 0.

    Handles chunk boundaries anywhere (mid-line, mid-event), CRLF or LF framing,
    multi-`data:`-line events, and passes comments/pings/unparseable events
    through untouched.
    """

    def __init__(self):
        self.buf = b""
        self.dropped = set()   # original indices of stripped blocks
        self.remap = {}        # original index -> new contiguous index
        self.next_idx = 0

    def feed(self, chunk):
        self.buf += chunk
        # Normalize CRLF -> LF so event boundaries are always \n\n. A lone
        # trailing \r (CRLF split across chunks) stays buffered until its \n
        # arrives, so nothing is lost. buf only ever holds one partial event.
        if b"\r" in self.buf:
            self.buf = self.buf.replace(b"\r\n", b"\n")
        out = []
        while True:
            i = self.buf.find(b"\n\n")
            if i < 0:
                break
            event, self.buf = self.buf[:i], self.buf[i + 2:]
            ev = self._rewrite(event)
            if ev:
                out.append(ev)
        return b"".join(out)

    def flush(self):
        """Drain any final unterminated event (stream ended without \\n\\n)."""
        if not self.buf.strip():
            self.buf = b""
            return b""
        ev = self._rewrite(self.buf)
        self.buf = b""
        return ev or b""

    def _rewrite(self, event):
        lines = event.split(b"\n")
        data_idx = [i for i, ln in enumerate(lines) if ln.startswith(b"data:")]
        if not data_idx:
            return event + b"\n\n"          # comment / ping keepalive: pass through
        # SSE: multiple data: lines are one payload joined by \n; a single
        # leading space after the colon is not part of the value.
        payload = b"\n".join(
            lines[i][6:] if lines[i][5:6] == b" " else lines[i][5:] for i in data_idx
        )
        try:
            j = json.loads(payload)
        except Exception:
            return event + b"\n\n"          # not JSON we understand: pass through
        t = j.get("type")
        if t == "content_block_start":
            idx = j.get("index")
            btype = (j.get("content_block") or {}).get("type")
            if btype in STRIP:
                self.dropped.add(idx)
                return b""
            self.remap[idx] = self.next_idx
            self.next_idx += 1
            j["index"] = self.remap[idx]
        elif t in ("content_block_delta", "content_block_stop"):
            idx = j.get("index")
            if idx in self.dropped:
                return b""
            if idx in self.remap:
                j["index"] = self.remap[idx]
        # message_start / message_delta / message_stop / ping / error: unchanged
        head = [lines[i] for i in range(len(lines)) if i not in set(data_idx)]
        data_line = b"data: " + json.dumps(j, separators=(",", ":")).encode()
        return b"\n".join(head + [data_line]) + b"\n\n"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    # ---- entry points --------------------------------------------------------
    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_PUT(self):
        self._proxy("PUT")

    def do_PATCH(self):
        self._proxy("PATCH")

    def do_DELETE(self):
        self._proxy("DELETE")

    # ---- plumbing ------------------------------------------------------------
    def _read_body(self):
        n = int(self.headers.get("content-length", 0) or 0)
        return self.rfile.read(n) if n > 0 else None

    def _send_json_error(self, status, message):
        body = anthropic_error(message)
        try:
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.send_header("connection", "close")
            self.end_headers()
            self.close_connection = True
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _proxy(self, method):
        body = self._read_body() if method in ("POST", "PUT", "PATCH") else None
        req = urllib.request.Request(UPSTREAM + self.path, data=body,
                                     headers=fwd_headers(self.headers), method=method)
        try:
            up = urllib.request.urlopen(req, timeout=IDLE_TIMEOUT)
            status, hdrs = up.status, up.headers
        except urllib.error.HTTPError as e:          # forward 4xx/5xx bodies verbatim
            up, status, hdrs = e, e.code, e.headers
        except Exception as e:
            self._send_json_error(502, f"proxy: upstream unreachable: {e}")
            return

        ctype = hdrs.get("content-type", "") or ""
        path_only = self.path.split("?", 1)[0].rstrip("/")
        is_messages = path_only.endswith("/v1/messages")
        _dbg("requests.log",
             f"{method} {self.path} -> {status} ctype={ctype!r} msgs={is_messages}\n".encode())
        try:
            if "text/event-stream" in ctype:
                self._stream(up, status, ctype, filtered=is_messages)
            else:
                data = up.read()
                if is_messages and status == 200 and "application/json" in ctype:
                    _dbg("nonstream_in.json", data)
                    data = self._filter_json(data)
                    _dbg("nonstream_out.json", data)
                self.send_response(status)
                self.send_header("content-type", ctype or "application/json")
                self.send_header("content-length", str(len(data)))
                self.send_header("connection", "close")
                self.end_headers()
                self.close_connection = True
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass                                     # client went away: nothing to do

    def _filter_json(self, data):
        try:
            j = json.loads(data)
            if isinstance(j.get("content"), list):
                j["content"] = [b for b in j["content"] if b.get("type") not in STRIP]
            return json.dumps(j).encode()
        except Exception:
            return data

    def _stream(self, up, status, ctype, filtered):
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True

        # Upstream reads and client writes fail with the same exception types
        # (ConnectionResetError etc.), so they need SEPARATE error scopes: an
        # upstream failure must surface to the client as an SSE error event,
        # while a client disconnect just ends the handler.
        filt = StreamFilter() if filtered else None
        while True:
            try:
                chunk = up.read(8192)
            except Exception as e:                   # upstream died mid-stream
                self._emit_stream_error(f"proxy: upstream stream error: {e}")
                return
            if not chunk:
                break
            _dbg("raw_in.sse", chunk)
            out = filt.feed(chunk) if filt else chunk
            if out:
                _dbg("filtered_out.sse", out)
                try:
                    self.wfile.write(out)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    return                           # client went away mid-stream
        tail = filt.flush() if filt else b""
        if tail:
            try:
                self.wfile.write(tail)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    def _emit_stream_error(self, message):
        """Best-effort SSE error event so the client fails fast with a message
        instead of hanging on a silent close."""
        try:
            self.wfile.write(b"event: error\ndata: " + anthropic_error(message) + b"\n\n")
            self.wfile.flush()
        except Exception:
            pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def watch_parent():
    """Exit if the parent (the wrapper) dies — covers SIGKILL, where the
    wrapper's cleanup trap never runs. A dead parent shows up either as a
    changed getppid() or as ppid 1 (reparented to init/launchd) — the latter
    also catches the race where the parent died before we sampled it."""
    ppid = os.getppid()
    while True:
        cur = os.getppid()
        if cur != ppid or cur == 1:
            os._exit(0)
        time.sleep(5)


def main():
    portfile = sys.argv[1] if len(sys.argv) > 1 else None
    srv = Server(("127.0.0.1", 0), Handler)      # socket is listening once constructed
    port = srv.server_address[1]
    if portfile:
        tmp = portfile + ".tmp"
        with open(tmp, "w") as f:                # atomic: reader never sees a partial port
            f.write(str(port))
        os.replace(tmp, portfile)
        threading.Thread(target=watch_parent, daemon=True).start()
    else:
        print(port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
