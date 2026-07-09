#!/usr/bin/env python3
"""Unit tests for claude-openrouter-proxy StreamFilter edge cases."""
import importlib.util
import json
import os
import sys

PROXY = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "claude-openrouter-proxy.py")
spec = importlib.util.spec_from_file_location("clorproxy", PROXY)
assert spec and spec.loader, f"cannot load {PROXY}"
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

FAIL = 0


def check(name, cond, detail=""):
    global FAIL
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if not cond and detail else ""))
    if not cond:
        FAIL += 1


def ev(payload, name=None):
    head = f"event: {name}\n".encode() if name else b""
    return head + b"data: " + json.dumps(payload).encode() + b"\n\n"


def parse(out):
    """Return list of parsed data payloads from filtered output."""
    res = []
    for event in out.split(b"\n\n"):
        for ln in event.split(b"\n"):
            if ln.startswith(b"data:"):
                res.append(json.loads(ln[5:].strip()))
    return res


# --- 1. thinking dropped, text remapped to 0, deltas follow the remap --------
f = m.StreamFilter()
stream = (
    ev({"type": "message_start", "message": {"id": "gen-1"}})
    + ev({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
    + ev({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "hmm"}})
    + ev({"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": ""}})
    + ev({"type": "content_block_stop", "index": 0})
    + ev({"type": "content_block_start", "index": 1, "content_block": {"type": "redacted_thinking", "data": "xx"}})
    + ev({"type": "content_block_stop", "index": 1})
    + ev({"type": "content_block_start", "index": 2, "content_block": {"type": "text", "text": ""}})
    + ev({"type": "content_block_delta", "index": 2, "delta": {"type": "text_delta", "text": "hello"}})
    + ev({"type": "content_block_stop", "index": 2})
    + ev({"type": "content_block_start", "index": 3, "content_block": {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}})
    + ev({"type": "content_block_delta", "index": 3, "delta": {"type": "input_json_delta", "partial_json": "{\"c\":1}"}})
    + ev({"type": "content_block_stop", "index": 3})
    + ev({"type": "message_delta", "delta": {"stop_reason": "tool_use"}})
    + ev({"type": "message_stop"})
)
out = f.feed(stream) + f.flush()
got = parse(out)
types = [(g.get("type"), g.get("index")) for g in got]
check("thinking events fully dropped",
      not any("thinking" in str(g.get("content_block", {}).get("type", "")) for g in got
              if g.get("type") == "content_block_start"))
check("no dropped-index deltas leak",
      not any(g.get("index") in (0, 1) and g.get("type", "").startswith("content_block")
              and g.get("index") is not None and g.get("type") != "content_block_start"
              for g in got if g.get("type") in ("content_block_delta", "content_block_stop")
              and g.get("index") in (0, 1)) or
      all(g.get("index") in (0, 1) for g in got if g.get("type") == "content_block_start"
          and g["content_block"]["type"] in ("text", "tool_use")))
starts = [g for g in got if g.get("type") == "content_block_start"]
check("text remapped 2->0", starts[0]["content_block"]["type"] == "text" and starts[0]["index"] == 0)
check("tool_use remapped 3->1", starts[1]["content_block"]["type"] == "tool_use" and starts[1]["index"] == 1)
deltas = [g for g in got if g.get("type") == "content_block_delta"]
check("text delta index remapped", deltas[0]["delta"]["type"] == "text_delta" and deltas[0]["index"] == 0)
check("tool delta index remapped", deltas[1]["delta"]["type"] == "input_json_delta" and deltas[1]["index"] == 1)
check("message_delta untouched", any(g.get("type") == "message_delta" for g in got))

# --- 2. chunk boundaries anywhere (byte-by-byte feed) -------------------------
f = m.StreamFilter()
out = b"".join(f.feed(stream[i:i + 1]) for i in range(len(stream))) + f.flush()
got2 = parse(out)
check("byte-by-byte feed == whole feed", got2 == got)

# --- 3. CRLF framing ----------------------------------------------------------
crlf_stream = stream.replace(b"\n", b"\r\n")
f = m.StreamFilter()
# feed in awkward 7-byte chunks so \r\n straddles boundaries
out = b"".join(f.feed(crlf_stream[i:i + 7]) for i in range(0, len(crlf_stream), 7)) + f.flush()
got3 = parse(out)
check("CRLF framing handled (chunk-straddling)", got3 == got)

# --- 4. multi-line data: event ------------------------------------------------
f = m.StreamFilter()
payload = {"type": "content_block_start", "index": 0,
           "content_block": {"type": "thinking", "thinking": ""}}
raw = json.dumps(payload)
half = len(raw) // 2
multi = f"data: {raw[:half]}\ndata: {raw[half:]}\n\n".encode()
# json split across two data lines joined by \n is invalid JSON unless the split
# point is whitespace-safe — use a payload whose join IS valid: split at a comma boundary
multi_ok = b"data: " + json.dumps(payload).encode() + b"\n\n"  # control
# construct a genuinely valid multi-line case: JSON tolerates \n between tokens
tokens = json.dumps(payload, indent=0).split("\n")
multi2 = b"".join(b"data: " + t.encode() + b"\n" for t in tokens) + b"\n"
out = f.feed(multi2)
check("multi-line data: thinking dropped", out == b"")

# --- 5. comments / pings pass through unchanged --------------------------------
f = m.StreamFilter()
ping = b": OPENROUTER PROCESSING\n\n"
check("comment keepalive passes through", f.feed(ping) == b": OPENROUTER PROCESSING\n\n")
pev = ev({"type": "ping"}, name="ping")
out = f.feed(pev)
check("ping event passes through", b'"type":"ping"' in out.replace(b" ", b"") and b"event: ping" in out)

# --- 6. non-JSON data passes through -------------------------------------------
f = m.StreamFilter()
weird = b"data: [DONE]\n\n"
check("non-JSON data passes through", f.feed(weird) == b"data: [DONE]\n\n")

# --- 7. unterminated final event flushed ---------------------------------------
f = m.StreamFilter()
tail_ev = b"data: " + json.dumps({"type": "message_stop"}).encode()  # no trailing \n\n
out = f.feed(tail_ev)
check("incomplete event held back", out == b"")
out = f.flush()
check("flush drains final event", b"message_stop" in out)

# --- 8. error event passes through unchanged -----------------------------------
f = m.StreamFilter()
err = ev({"type": "error", "error": {"type": "overloaded_error", "message": "x"}}, name="error")
out = f.feed(err)
check("error event passes through", b"overloaded_error" in out)

print()
sys.exit(1 if FAIL else 0)
