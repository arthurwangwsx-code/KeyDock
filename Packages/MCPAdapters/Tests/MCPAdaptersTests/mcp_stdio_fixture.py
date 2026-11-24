#!/usr/bin/env python3
"""合成stdio MCP；只处理合成JSON，不接触个人文件、凭据或外部API。"""
import json
import os
import signal
import sys
import threading
import time

signal.signal(signal.SIGTERM, signal.SIG_DFL)
mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
if mode == "delayed-start-slow":
    time.sleep(1.25)
lock = threading.Lock()
cancellations = 0
pending = {}
modern = True
schema = {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"], "additionalProperties": False}

def send(identifier, result):
    if modern: result = dict(result, resultType="complete")
    with lock:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "result": result}, ensure_ascii=False) + "\n")
        sys.stdout.flush()

def respond_later(identifier, text):
    event = threading.Event()
    pending[identifier] = event
    if not event.wait(60): send(identifier, {"content": [{"type": "text", "text": text}]})
    pending.pop(identifier, None)

for raw in sys.stdin:
    try: request = json.loads(raw)
    except Exception: sys.exit(2)
    method, params, identifier = request.get("method"), request.get("params", {}), request.get("id")
    if method == "notifications/cancelled":
        cancellations += 1
        if params.get("requestId") in pending: pending[params["requestId"]].set()
        continue
    if method == "notifications/initialized": continue
    if method == "initialize": modern = False
    if modern:
        if params.get("_meta", {}).get("io.modelcontextprotocol/protocolVersion") != "2026-07-28": sys.exit(3)
    if mode == "bad":
        print("synthetic unframed stdout", flush=True)
        continue
    if mode == "oversize":
        sys.stdout.write("x" * 300000)
        sys.stdout.flush()
        continue
    if method in ("initialize", "server/discover"):
        sys.stderr.write("synthetic stderr body must not be retained\n")
        sys.stderr.flush()
        caps = {"tools": {}, "resources": {}, "prompts": {}}
        if method == "initialize": send(identifier, {"protocolVersion": "2025-11-25", "capabilities": caps})
        else: send(identifier, {"supportedVersions": ["2026-07-28"], "capabilities": caps})
    elif method == "tools/list":
        send(identifier, {"tools": [{"name": "echo", "description": "Synthetic echo", "inputSchema": schema}]})
    elif method == "tools/call":
        text = params.get("arguments", {}).get("text", "")
        if mode in ("slow", "delayed-start-slow"): threading.Thread(target=respond_later, args=(identifier, text), daemon=True).start()
        else: send(identifier, {"content": [{"type": "text", "text": text}], "isError": False})
    elif method == "synthetic/stats":
        send(identifier, {"cancelled": cancellations, "pending": len(pending), "environmentKeys": list(os.environ.keys())})
    elif method == "resources/list": send(identifier, {"resources": [{"name": "Synthetic", "uri": "synthetic://test/one", "mimeType": "text/plain"}]})
    elif method == "resources/read": send(identifier, {"contents": [{"uri": params["uri"], "text": "Synthetic selected resource"}]})
    elif method == "prompts/list": send(identifier, {"prompts": [{"name": "synthetic", "arguments": [{"name": "text", "required": True}]}]})
    elif method == "prompts/get": send(identifier, {"messages": [{"role": "user", "content": {"type": "text", "text": params.get("arguments", {}).get("text", "")}}]})
    else:
        with lock:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "error": {"code": -32601, "message": "synthetic"}}) + "\n")
            sys.stdout.flush()
