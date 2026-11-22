#!/usr/bin/env python3
"""仅供合成集成测试的 loopback SSE 服务；stdout 只输出动态端口。"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import threading
import time
from urllib.parse import urlsplit

MARKER = "synthetic-private-response-body"


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def event(value):
    return b"data: " + encode(value) + b"\r\n\r\n"


def chunk(text=None, finish=None):
    delta = {} if text is None else {"content": text}
    choice = {"index": 0, "delta": delta}
    if finish is not None:
        choice["finish_reason"] = finish
    return {"id": "synthetic-network-response", "choices": [choice]}


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.stats_lock = threading.Lock()
        self.stats = {"redirect_hits": 0, "redirect_authorization_seen": 0,
                      "slow_open": 0, "slow_closed": 0}

    def increment(self, key, amount=1):
        with self.stats_lock:
            self.stats[key] += amount

    def snapshot(self):
        with self.stats_lock:
            return dict(self.stats)

    def handle_error(self, request, client_address):
        # 连接取消是测试事件；不输出 traceback、请求或凭据。
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if urlsplit(self.path).path == "/stats":
            self.send_json(200, self.server.snapshot())
        else:
            self.send_json(404, {"error": "synthetic fixture route"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > 2_097_152:
                self.send_json(413, {"error": MARKER})
                return
            self.connection.settimeout(5)
            self.rfile.read(length)
            path = urlsplit(self.path).path
            if path == "/stream":
                self.stream()
            elif path == "/truncated":
                self.start_sse()
                self.wfile.write(event(chunk(text="Synthetic partial")) + event(chunk(finish="stop")))
                self.wfile.flush()
            elif path == "/slow":
                self.slow_stream()
            elif path in ("/error/401", "/error/429"):
                self.send_json(int(path.rsplit("/", 1)[1]), {"error": {"message": MARKER}})
            elif path == "/redirect":
                self.send_response(307)
                # localhost 与 127.0.0.1 为不同 origin，不能转发 Authorization。
                self.send_header("Location", f"http://localhost:{self.server.server_address[1]}/redirect-target")
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
            elif path == "/redirect-target":
                self.server.increment("redirect_hits")
                if self.headers.get("Authorization"):
                    self.server.increment("redirect_authorization_seen")
                self.stream()
            else:
                self.send_json(404, {"error": "synthetic fixture route"})
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError, ValueError):
            self.close_connection = True

    def send_json(self, status, value):
        body = encode(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def start_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.close_connection = True

    def stream(self):
        self.start_sse()
        payload = encode(chunk(text="你好，网络 🌍"))
        split = payload.index(b",") + 1
        wire = (b"\xef\xbb\xbf: synthetic heartbeat\r\n\r\ndata: " + payload[:split] +
                b"\r\ndata: " + payload[split:] + b"\r\n\r\n" +
                event(chunk(finish="stop")) +
                event({"id": "synthetic-network-response", "choices": [],
                       "usage": {"prompt_tokens": 12, "completion_tokens": 5}}) +
                b"data: [DONE]\r\n\r\n")
        # 故意逐字节写入，覆盖 UTF-8 多字节字符和 SSE 跨行在真实网络路径中的处理。
        for byte in wire:
            self.wfile.write(bytes((byte,)))
            self.wfile.flush()
            time.sleep(0.001)

    def slow_stream(self):
        self.start_sse()
        self.server.increment("slow_open")
        try:
            self.wfile.write(event(chunk(text="Synthetic first token")))
            self.wfile.flush()
            for _ in range(400):
                time.sleep(0.05)
                self.wfile.write(event(chunk(text=" synthetic continuation")))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
            self.server.increment("slow_closed")
        finally:
            self.server.increment("slow_open", -1)


if __name__ == "__main__":
    server = FixtureServer()
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever(poll_interval=0.05)
    finally:
        server.server_close()
