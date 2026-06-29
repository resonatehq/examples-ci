#!/usr/bin/env python3
# Mock LLM HTTP server for examples-ci.
#
# Listens on :8080 and serves canned JSON responses for:
#   POST /v1/chat/completions  (OpenAI)
#   POST /v1/messages          (Anthropic)
#
# Examples that use the official OpenAI/Anthropic SDKs with default
# constructors will redirect here via OPENAI_BASE_URL / ANTHROPIC_BASE_URL,
# which the runner exports when this service starts. Each request gets a
# canned reply whose `content` is a JSON string satisfying the strictest
# downstream schema we've enrolled (HN research-agent's relevance verdict).
# Examples that just want any text treat the JSON as opaque content.
#
# Tool-using examples (schedule-reminder, deep-research-agent) are supported:
# when a chat request carries a non-empty `tools` list and the conversation
# has not yet produced a tool result, the mock replies with ONE tool_call
# whose arguments are synthesized from the tool's JSON-schema parameters.
# Once a tool result is present (or no tools are offered), it returns the
# canned final content. This drives a single tool round then terminates, so
# agent loops always converge in CI.

import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("MOCK_LLM_HOST", "127.0.0.1")
PORT = int(os.environ.get("MOCK_LLM_PORT", "8080"))

CANNED_CONTENT = json.dumps({
    "relevanceScore": 7,
    "summary": "Mock LLM response for examples-ci.",
    "keyPoints": ["mock point 1", "mock point 2"],
    "isInteresting": True,
    "answer": "Mock answer text.",
})


def _synthesize_args(parameters: dict) -> dict:
    """Build a minimal arguments object that satisfies a tool's JSON schema.

    Fills every declared property (required first) with a type-appropriate
    placeholder so the example's tool dispatch can json.loads + call its
    handler without KeyError or type surprises.
    """
    props = (parameters or {}).get("properties", {}) or {}
    out: dict = {}
    for name, spec in props.items():
        t = (spec or {}).get("type", "string")
        if t in ("integer", "number"):
            out[name] = 1
        elif t == "boolean":
            out[name] = True
        elif t == "array":
            out[name] = []
        elif t == "object":
            out[name] = {}
        else:  # string and anything unrecognized
            out[name] = "mock"
    return out


def _wants_tool_call(req: dict) -> bool:
    """True when we should answer with a tool_call instead of final content.

    Emit a tool_call only on the first turn of a tool-using conversation:
    `tools` offered, tool_choice not disabled, and no tool result returned yet.
    After one tool round (a role=="tool" message appears) we fall through to
    final content so the agent loop terminates.
    """
    tools = req.get("tools") or []
    if not tools:
        return False
    if req.get("tool_choice") == "none":
        return False
    messages = req.get("messages") or []
    if any(isinstance(m, dict) and m.get("role") == "tool" for m in messages):
        return False
    return True


def openai_chat_response(model: str, req: dict) -> dict:
    if _wants_tool_call(req):
        fn = (req["tools"][0] or {}).get("function", {}) or {}
        name = fn.get("name", "mock_tool")
        args = _synthesize_args(fn.get("parameters", {}))
        message = {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_mock_{uuid.uuid4().hex[:8]}",
                    "type": "function",
                    "function": {"name": name, "arguments": json.dumps(args)},
                }
            ],
        }
        finish_reason = "tool_calls"
    else:
        message = {"role": "assistant", "content": CANNED_CONTENT}
        finish_reason = "stop"
    return {
        "id": f"chatcmpl-mock-{uuid.uuid4().hex[:8]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
    }


def anthropic_messages_response(model: str) -> dict:
    return {
        "id": f"msg_mock_{uuid.uuid4().hex[:8]}",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [{"type": "text", "text": CANNED_CONTENT}],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 1, "output_tokens": 1},
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Keep the line tight; goes to stderr (visible in /tmp/mock-llm.log).
        sys.stderr.write("mock-llm: " + (fmt % args) + "\n")

    def _send_json(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        # Health probe — any GET returns 200.
        self._send_json(200, {"status": "ok", "service": "mock-llm"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            req = {}
        model = req.get("model", "mock-model")

        if self.path.endswith("/v1/chat/completions"):
            self._send_json(200, openai_chat_response(model, req))
        elif self.path.endswith("/v1/messages"):
            self._send_json(200, anthropic_messages_response(model))
        else:
            self._send_json(404, {"error": f"no mock for {self.path}"})


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write(f"mock-llm: listening on {HOST}:{PORT}\n")
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
