#!/usr/bin/env python3
"""仅供合成集成测试的 loopback SSE 服务；stdout 只输出动态端口。"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from datetime import datetime
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
                      "slow_open": 0, "slow_closed": 0,
                      "proposal_started": 0, "agent_requests": 0,
                      "agent_tool_messages": 0, "ordinary_tools_advertised": 0,
                      "authorization_seen": 0, "post_requests": 0,
                      "limit_agent_requests": 0, "held_text_started": 0,
                      "context_label_leaks": 0, "context_body_requests": 0,
                      "model_list_requests": 0, "model_redirect_hits": 0}
        self.proposal_release = threading.Event()
        self.text_release = threading.Event()

    def increment(self, key, amount=1):
        with self.stats_lock:
            self.stats[key] += amount
            return self.stats[key]

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
        path = urlsplit(self.path).path
        if path == "/stats":
            self.send_json(200, self.server.snapshot())
        elif path == "/release-text":
            self.server.text_release.set()
            self.send_json(200, {"released": True})
        elif path == "/release-proposal":
            self.server.proposal_release.set()
            self.send_json(200, {"released": True})
        elif path in ("/models", "/empty/models"):
            self.server.increment("model_list_requests")
            self.send_json(200, {"object": "list", "data": [] if path.startswith("/empty/") else [{"id": "synthetic-listed-model"}]})
        elif path == "/redirect/models":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_address[1]}/model-redirect-target")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif path == "/model-redirect-target":
            self.server.increment("model_redirect_hits")
            self.send_json(200, {"object": "list", "data": []})
        elif path == "/model-tail/models":
            payload = b'{"object":"list","data":[]}' + b'\n' * 64 + b'synthetic-invalid-tail'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
        else:
            self.send_json(404, {"error": "synthetic fixture route"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > 2_097_152:
                self.send_json(413, {"error": MARKER})
                return
            self.connection.settimeout(5)
            body = self.rfile.read(length)
            self.server.increment("post_requests")
            if b"synthetic-provenance-secret-name" in body:
                self.server.increment("context_label_leaks")
            if b"synthetic-explicit-context-body" in body:
                self.server.increment("context_body_requests")
            if self.headers.get("Authorization"):
                self.server.increment("authorization_seen")
            path = urlsplit(self.path).path
            if path == "/stream":
                self.stream()
            elif path in ("/request-settings", "/responses-settings"):
                request = json.loads(body)
                selected = {key: request.get(key) for key in ("model", "reasoning_effort", "reasoning", "max_completion_tokens", "max_output_tokens", "store")}
                text = json.dumps(selected, ensure_ascii=False, sort_keys=True)
                if path == "/request-settings": self.complete_text(text, "synthetic-settings-response")
                else:
                    self.start_sse()
                    item = {"type":"message","id":"msg_settings","role":"assistant","status":"completed","phase":"final_answer",
                            "content":[{"type":"output_text","text":text,"annotations":[]}]}
                    values = [("response.created", {"response":{"id":"resp_settings"}}),
                              ("response.output_item.added", {"output_index":0,"item":item}),
                              ("response.output_item.done", {"output_index":0,"item":item}),
                              ("response.completed", {"response":{"id":"resp_settings","status":"completed","output":[item],"usage":{"input_tokens":7,"output_tokens":4}}})]
                    for sequence, (kind, fields) in enumerate(values):
                        self.wfile.write(event(dict(fields, type=kind, sequence_number=sequence)))
                    self.wfile.flush()
            elif path == "/usage":
                # 用量／费率归因用真实URLSession SSE但无人工逐字节延时；/stream继续专门覆盖跨字节解码。
                self.complete_text("Synthetic usage result", "synthetic-usage-response")
            elif path == "/attempt-echo":
                # 仅loopback合成回归：回显本次明确输入，证明没有复用旧attempt正文。
                request = json.loads(body)
                inputs = [m.get("content", "") for m in request.get("messages", []) if m.get("role") == "user"]
                text = inputs[-1] if inputs and isinstance(inputs[-1], str) else "missing synthetic input"
                self.complete_text(text, "synthetic-attempt-response")
            elif path == "/system-prompt-echo":
                # 只用于合成联调，核对调用前冻结的语言指令已进入实际请求。
                request = json.loads(body)
                systems = [m.get("content", "") for m in request.get("messages", []) if m.get("role") == "system"]
                self.complete_text("\n".join(systems), "synthetic-language-response")
            elif path == "/empty":
                self.complete_text("", "synthetic-empty-response")
            elif path == "/no-usage":
                self.start_sse()
                self.wfile.write(event(chunk(text="Synthetic no-usage result")) +
                                 event(chunk(finish="stop")) + b"data: [DONE]\r\n\r\n")
                self.wfile.flush()
            elif path == "/truncated":
                self.start_sse()
                self.wfile.write(event(chunk(text="Synthetic partial")) + event(chunk(finish="stop")))
                self.wfile.flush()
            elif path == "/slow":
                self.slow_stream()
            elif path in ("/large-text", "/large-proposal", "/large-agent", "/large-agent-reported", "/held-text"):
                request = json.loads(body)
                if path == "/held-text":
                    self.server.increment("held_text_started")
                    if not self.server.text_release.wait(timeout=5):
                        self.send_json(504, {"error": MARKER})
                        return
                    self.complete_text("Synthetic held result", "synthetic-held-text")
                else:
                    self.large_response(path, request)
            elif path == "/agent-command":
                self.agent_command(json.loads(body))
            elif path in ("/proposal", "/proposal-held", "/agent", "/agent-no-final-usage", "/agent-second-turn-failure", "/unexpected-tool"):
                request = json.loads(body)
                if not isinstance(request, dict):
                    raise ValueError("synthetic request shape")
                if path in ("/proposal", "/proposal-held"):
                    self.proposal(request, held=path == "/proposal-held")
                elif path in ("/agent", "/agent-no-final-usage", "/agent-second-turn-failure"):
                    self.agent(request, report_final_usage=path != "/agent-no-final-usage",
                               fail_final_turn=path == "/agent-second-turn-failure")
                else:
                    self.server.increment("ordinary_tools_advertised", len(request.get("tools", [])))
                    self.tool_response("synthetic-unexpected-tool")
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

    def large_response(self, path, request):
        if path in ("/large-agent", "/large-agent-reported"):
            self.server.increment("limit_agent_requests")
            messages = request.get("messages", [])
            has_result = any(m.get("role") == "tool" for m in messages)
            if not has_result:
                self.start_sse()
                self.write_large_text("synthetic-agent-large-1", 1_048_448)
                # 第一轮接近总预算，第二轮必须继续计算同一 Store 预算。
                first = {"id": "synthetic-agent-large-1", "choices": [{"index": 0, "delta": {
                    "tool_calls": [{"index": 0, "id": "large_time_1", "type": "function",
                                    "function": {"name": "current_time", "arguments": "{}"}}]},
                    "finish_reason": "tool_calls"}]}
                self.wfile.write(event(first) + event({"id": "synthetic-agent-large-1", "choices": [],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 4}}) + b"data: [DONE]\r\n\r\n")
                self.wfile.flush()
                return
            response_id, size = "synthetic-agent-large-2", 4096
        else:
            response_id, size = "synthetic-large-output", 1_052_672
        self.start_sse()
        if path == "/large-agent-reported":
            # usage与触发产品总预算的文本同一payload，decoder须在消费者停止前保存已验证事实。
            value = chunk(text="x" * size, finish="stop")
            value["id"] = response_id
            value["usage"] = {"prompt_tokens": 20, "completion_tokens": 6}
            self.wfile.write(event(value) + b"data: [DONE]\r\n\r\n")
            self.wfile.flush()
            return
        if path == "/large-proposal":
            # 直到最后才闭合 JSON；达到 Store 上限后不能解析或触发审阅。
            initial = chunk(text='{"name":"Synthetic oversize","executable":"/usr/bin/touch",'
                                 '"arguments":[],"cwd":"","explanation":"')
            initial["id"] = response_id
            self.wfile.write(event(initial))
        self.write_large_text(response_id, size)
        if path == "/large-agent":
            # 明确在wire上缺少第二轮usage与完成标记，避免把消费者未读到的完整响应假设为未报告。
            return
        if path == "/large-proposal":
            ending = chunk(text='"}')
            ending["id"] = response_id
            self.wfile.write(event(ending))
        finish = chunk(finish="stop")
        finish["id"] = response_id
        self.wfile.write(event(finish) + event({"id": response_id, "choices": [],
            "usage": {"prompt_tokens": 20, "completion_tokens": 6}}) + b"data: [DONE]\r\n\r\n")
        self.wfile.flush()

    def write_large_text(self, response_id, count):
        # 每个 SSE 行小于 parser 行上限，专门覆盖累计文本预算而非单行上限。
        while count > 0:
            size = min(32_768, count)
            value = chunk(text="x" * size)
            value["id"] = response_id
            self.wfile.write(event(value))
            self.wfile.flush()
            count -= size

    def complete_text(self, text, response_id, input_tokens=12, output_tokens=5):
        self.start_sse()
        content = chunk(text=text)
        content["id"] = response_id
        finish = chunk(finish="stop")
        finish["id"] = response_id
        self.wfile.write(event(content) + event(finish) +
                         event({"id": response_id, "choices": [], "usage": {
                             "prompt_tokens": input_tokens, "completion_tokens": output_tokens}}) +
                         b"data: [DONE]\r\n\r\n")
        self.wfile.flush()

    def proposal(self, request, held):
        sequence = self.server.increment("proposal_started")
        if request.get("tools", []):
            self.send_json(422, {"error": MARKER})
            return
        messages = request.get("messages", [])
        users = [m for m in messages if m.get("role") == "user"]
        if not users or not isinstance(users[-1].get("content"), str):
            self.send_json(422, {"error": MARKER})
            return
        # 仅合成输入成为 argv 数据；服务和测试均不会执行这个建议。
        proposal = {"name": f"Synthetic proposal {sequence}", "executable": "/usr/bin/touch",
                    "arguments": [users[-1]["content"]], "cwd": "",
                    "explanation": "Synthetic proposal only"}
        if held and not self.server.proposal_release.wait(timeout=5):
            self.send_json(504, {"error": MARKER})
            return
        self.complete_text(json.dumps(proposal), f"synthetic-proposal-{sequence}")

    def tool_response(self, response_id):
        self.start_sse()
        # 把函数名与参数拆到不同事件，验证真实适配器的组装路径。
        first = {"id": response_id, "choices": [{"index": 0, "delta": {"tool_calls": [
            {"index": 0, "id": "fixture_time_1", "type": "function",
             "function": {"name": "current_", "arguments": "{"}}]}}]}
        second = {"id": response_id, "choices": [{"index": 0, "delta": {"tool_calls": [
            {"index": 0, "function": {"name": "time", "arguments": "}"}}]},
            "finish_reason": "tool_calls"}]}
        self.wfile.write(event(first) + event(second) +
                         event({"id": response_id, "choices": [], "usage": {
                             "prompt_tokens": 10, "completion_tokens": 4}}) +
                         b"data: [DONE]\r\n\r\n")
        self.wfile.flush()

    def agent_command(self, request):
        self.server.increment("agent_requests")
        names = [tool.get("function", {}).get("name", "") for tool in request.get("tools", [])]
        commands = [name for name in names if name.startswith("command_")]
        if len(names) != 2 or names.count("current_time") != 1 or len(commands) != 1:
            self.send_json(422, {"error": MARKER})
            return
        name = commands[0]
        messages = request.get("messages", [])
        results = [message for message in messages if message.get("role") == "tool"]
        if not results:
            self.start_sse()
            response = {"id": "synthetic-command-agent-1", "choices": [{"index": 0, "delta": {"tool_calls": [
                {"index": 0, "id": "fixture_command_1", "type": "function", "function": {"name": name, "arguments": "{}"}}]}, "finish_reason": "tool_calls"}]}
            self.wfile.write(event(response) + b"data: [DONE]\r\n\r\n")
            self.wfile.flush()
            return
        calls = [call for message in messages if message.get("role") == "assistant" for call in message.get("tool_calls", [])]
        valid_call = any(call.get("id") == "fixture_command_1" and call.get("function", {}).get("name") == name
                         and call.get("function", {}).get("arguments") == "{}" for call in calls)
        if len(results) != 1 or results[0].get("content") != "original" or results[0].get("tool_call_id") != "fixture_command_1" or not valid_call:
            self.send_json(422, {"error": MARKER})
            return
        self.server.increment("agent_tool_messages")
        self.complete_text("Synthetic saved command round-trip complete", "synthetic-command-agent-2")

    def agent(self, request, report_final_usage=True, fail_final_turn=False):
        self.server.increment("agent_requests")
        tools = request.get("tools", [])
        names = [t.get("function", {}).get("name") for t in tools]
        if names != ["current_time"]:
            self.send_json(422, {"error": MARKER})
            return
        messages = request.get("messages", [])
        results = [m for m in messages if m.get("role") == "tool"]
        if not results:
            self.tool_response("synthetic-agent-1")
            return
        result = results[-1]
        calls = [c for m in messages if m.get("role") == "assistant"
                 for c in m.get("tool_calls", [])]
        # 第二轮必须包含真实 host tool 产物及对应调用身份，不能只按请求次数返回成功。
        valid_call = any(c.get("id") == "fixture_time_1" and
                         c.get("function", {}).get("name") == "current_time" and
                         c.get("function", {}).get("arguments") == "{}" for c in calls)
        try:
            timestamp = datetime.fromisoformat(result.get("content", "").replace("Z", "+00:00"))
            valid_time = timestamp.tzinfo is not None
        except (TypeError, ValueError):
            valid_time = False
        if not (len(results) == 1 and result.get("tool_call_id") == "fixture_time_1"
                and valid_call and valid_time):
            self.send_json(422, {"error": MARKER})
            return
        self.server.increment("agent_tool_messages")
        if fail_final_turn:
            # 用量展示只检验失败轮未知用量，不依赖1MiB输出压力；仍校验真实host工具回传。
            self.send_json(503, {"error": MARKER})
            return
        if report_final_usage:
            self.complete_text("Synthetic read-only tool round-trip complete", "synthetic-agent-2", 20, 6)
        else:
            # 最终轮完整成功，但提供商不附 usage；不能误报整次 Agent 用量完整。
            self.start_sse()
            content = chunk(text="Synthetic read-only tool round-trip complete")
            content["id"] = "synthetic-agent-2"
            finish = chunk(finish="stop")
            finish["id"] = "synthetic-agent-2"
            self.wfile.write(event(content) + event(finish) + b"data: [DONE]\r\n\r\n")
            self.wfile.flush()

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
