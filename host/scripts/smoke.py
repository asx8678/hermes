#!/usr/bin/env python3
"""Phoenix Channels smoke test for the packaged hermes-host binary.

Usage:
  HERMES_PORT=4000 python3 host/scripts/smoke.py

Connects to the local WebSocket gateway, creates a session with the mock
provider, sends a prompt, and verifies a turn:complete event is received.
"""

import json
import os
import socket
import sys
import time

import websocket


def wait_for_port(host: str, port: int, timeout_s: float = 60.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            s = socket.create_connection((host, port), timeout=1)
            s.close()
            return
        except OSError:
            time.sleep(0.2)
    raise TimeoutError(f"port {host}:{port} did not become reachable")


def main() -> int:
    host = os.environ.get("HERMES_HOST", "127.0.0.1")
    port = int(os.environ.get("HERMES_PORT", "4000"))
    url = f"ws://{host}:{port}/ws/websocket"

    wait_for_port(host, port)

    ref = 0

    def next_ref() -> str:
        nonlocal ref
        ref += 1
        return str(ref)

    def send(ws, topic: str, event: str, payload: dict, join_ref: str) -> None:
        ws.send(
            json.dumps(
                {
                    "topic": topic,
                    "event": event,
                    "payload": payload,
                    "ref": next_ref(),
                    "join_ref": join_ref,
                }
            )
        )

    def recv_json(ws, deadline: float) -> dict:
        while time.time() < deadline:
            try:
                return json.loads(ws.recv())
            except websocket.WebSocketTimeoutException:
                continue
        raise TimeoutError("timed out waiting for websocket message")

    def expect_reply(ws, topic: str, deadline: float) -> dict:
        while time.time() < deadline:
            msg = recv_json(ws, deadline)
            if msg.get("topic") == topic and msg.get("event") == "phx_reply":
                status = msg.get("payload", {}).get("status")
                if status == "ok":
                    return msg
                raise RuntimeError(f"reply failed on {topic}: {msg}")
        raise TimeoutError(f"timed out waiting for reply on {topic}")

    def expect_event(ws, topic: str, event: str, deadline: float) -> dict:
        while time.time() < deadline:
            msg = recv_json(ws, deadline)
            if msg.get("topic") == topic and msg.get("event") == event:
                return msg
        raise TimeoutError(f"timed out waiting for {event} on {topic}")

    ws = websocket.create_connection(url, timeout=5)

    join_ref = next_ref()
    send(ws, "session:new", "phx_join", {}, join_ref)
    expect_reply(ws, "session:new", time.time() + 10)

    send(
        ws,
        "session:new",
        "session:create",
        {
            "model": "smoke-test-model",
            "provider": "mock",
            "api_mode": "mock",
        },
        join_ref,
    )
    expect_reply(ws, "session:new", time.time() + 10)

    send(ws, "session:new", "send_prompt", {"message": "hello"}, join_ref)
    expect_reply(ws, "session:new", time.time() + 10)

    msg = expect_event(ws, "session:new", "turn:complete", time.time() + 20)
    payload = msg.get("payload", {})
    if "final_response" not in payload:
        raise AssertionError(f"turn:complete missing final_response: {msg}")

    print(f"turn:complete received: {payload['final_response']}")
    ws.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
