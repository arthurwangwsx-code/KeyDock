#!/usr/bin/env python3
"""合成MCP wire夹具；只绑定loopback，stdout仅打印端口，不记录正文／凭据。"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import base64
import signal
import threading
import time

signal.signal(signal.SIGTERM, signal.SIG_DFL)
if hasattr(signal, "pthread_sigmask"):
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})
SCHEMA = {"type": "object", "properties": {"text": {"type": "string"}},
          "required": ["text"], "additionalProperties": False}

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.lock = threading.Lock()
        self.stats = {"posts": 0, "redirect_hits": 0, "slow_open": 0,
                      "slow_closed": 0, "authorization_seen": 0, "valid_metadata": 0}
    def count(self, key, delta=1):
        with self.lock:
            self.stats[key] += delta
    def handle_error(self, request, client_address):
        pass

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def send_json(self, code, payload, extra=None):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra or {}).items(): self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/stats":
            with self.server.lock: snapshot = dict(self.server.stats)
            return self.send_json(200, snapshot)
        self.server.count("redirect_hits")
        return self.send_json(200, {})
    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 < size <= 262144: return self.send_json(413, {})
        self.connection.settimeout(5)
        try: request = json.loads(self.rfile.read(size))
        except Exception: return self.send_json(400, {})
        self.server.count("posts")
        if self.headers.get("Authorization"): self.server.count("authorization_seen")
        method = request.get("method")
        params = request.get("params", {})
        legacy = self.path == "/legacy"
        if not legacy:
            meta = params.get("_meta", {})
            valid = (meta.get("io.modelcontextprotocol/protocolVersion") == "2026-07-28"
                     and self.headers.get("MCP-Protocol-Version") == "2026-07-28"
                     and self.headers.get("Mcp-Method") == method
                     and meta.get("io.modelcontextprotocol/clientCapabilities") == {})
            if method in ("tools/call", "resources/read", "prompts/get"):
                header = self.headers.get("Mcp-Name", "")
                if header.startswith("=?base64?") and header.endswith("?="):
                    try: header = base64.b64decode(header[9:-2]).decode("utf8")
                    except Exception: header = None
                valid = valid and header == (params.get("uri") if method == "resources/read" else params.get("name"))
            if not valid: return self.send_json(422, {})
            self.server.count("valid_metadata")
        elif method != "initialize":
            if self.headers.get("Mcp-Session-Id") != "synthetic-wire-session": return self.send_json(422, {})
            if self.headers.get("MCP-Protocol-Version") != "2025-11-25": return self.send_json(422, {})
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/redirect-target")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/slow":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.server.count("slow_open")
            try:
                while True:
                    self.wfile.write(b": synthetic keepalive\r\n\r\n")
                    self.wfile.flush()
                    time.sleep(.02)
            except (OSError, ConnectionError): pass
            finally:
                self.server.count("slow_open", -1)
                self.server.count("slow_closed")
            return
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}, "resources": {}, "prompts": {}}}
        elif method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif method == "server/discover":
            result = {"supportedVersions": ["2026-07-28"], "capabilities": {"tools": {}, "resources": {}, "prompts": {}}}
        elif method == "tools/list":
            result = {"tools": [{"name": "echo", "description": "Synthetic echo", "inputSchema": SCHEMA}]}
        elif method == "resources/list":
            result = {"resources": [{"name": "Synthetic context", "uri": "synthetic://source/合成"}]}
        elif method == "resources/read":
            result = {"contents": [{"uri": params["uri"], "text": "Synthetic selected HTTP context"}]}
        elif method == "prompts/list":
            result = {"prompts": [{"name": "合成提示", "arguments": [{"name": "text", "required": True}]}]}
        elif method == "prompts/get":
            result = {"messages": [{"role": "user", "content": {"type": "text", "text": params["arguments"]["text"]}}]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": params.get("arguments", {}).get("text", "") + " 合成"}], "isError": False}
        else:
            return self.send_json(400, {"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": -32601, "message": "synthetic"}})
        if not legacy: result["resultType"] = "complete"
        envelope = {"jsonrpc": "2.0", "id": 999999 if self.path == "/mismatch" else request.get("id"), "result": result}
        if self.path == "/sse" and method == "tools/call":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            wire = b": synthetic comment\r\n\r\n" + b"data: " + json.dumps(envelope, ensure_ascii=False).encode("utf8") + b"\r\n\r\n"
            for index in range(0, len(wire), 3):
                self.wfile.write(wire[index:index+3])
                self.wfile.flush()
            self.close_connection = True
            return
        return self.send_json(200, envelope, {"Mcp-Session-Id": "synthetic-wire-session"} if legacy else {})

server = Server()
print(server.server_port, flush=True)
server.serve_forever()
