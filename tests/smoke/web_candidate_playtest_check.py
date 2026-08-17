#!/usr/bin/env python3
"""Verify that a WebSocket preview reaches the requested tactical candidate."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import socket
import struct
from urllib.request import ProxyHandler, build_opener


WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def read_exact(connection: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise ConnectionError("connection closed before response completed")
        data.extend(chunk)
    return bytes(data)


def read_until(connection: socket.socket, marker: bytes) -> bytes:
    data = bytearray()
    while marker not in data:
        chunk = connection.recv(4096)
        if not chunk:
            raise ConnectionError("connection closed before HTTP upgrade completed")
        data.extend(chunk)
    return bytes(data)


def websocket_request(host: str, port: int, model_id: str) -> dict[str, object]:
    key = base64.b64encode(b"pulse-arena-playtest-key").decode("ascii")
    with socket.create_connection((host, port), timeout=5) as connection:
        connection.settimeout(5)
        connection.sendall(
            (
                "GET /agent HTTP/1.1\r\n"
                f"Host: {host}:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            ).encode("ascii")
        )
        response = read_until(connection, b"\r\n\r\n").decode("ascii")
        accept = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()).decode("ascii")
        if "101 Switching Protocols" not in response or f"Sec-WebSocket-Accept: {accept}" not in response:
            raise RuntimeError(f"WebSocket upgrade failed: {response}")
        request = json.dumps(
            {
                "cmd": "act_tactical",
                "protocol": 2,
                "request_id": 1,
                "model_id": model_id,
                "tactical_features": [0.0] * 142,
                "action_masks": {
                    # Mask dimensions must match the trained policy logits:
                    #   target_slot: 7, movement_mode: 12, fire_mode: 6, skill_mode: 6
                    "target_slot": [True] * 7,
                    "movement_mode": [True] * 12,
                    "fire_mode": [True] * 6,
                    "skill_mode": [True] * 6,
                },
            },
            separators=(",", ":"),
        ).encode("utf-8")
        mask = b"test"
        header = bytearray([0x81])
        if len(request) < 126:
            header.append(0x80 | len(request))
        elif len(request) <= 0xFFFF:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", len(request)))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", len(request)))
        connection.sendall(bytes(header) + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(request)))
        first, second = read_exact(connection, 2)
        if first != 0x81:
            raise RuntimeError(f"unexpected WebSocket opcode {first:#x}")
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", read_exact(connection, 2))[0]
        elif size == 127:
            size = struct.unpack("!Q", read_exact(connection, 8))[0]
        return json.loads(read_exact(connection, size).decode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--model-id", required=True)
    args = parser.parse_args()
    opener = build_opener(ProxyHandler({}))
    with opener.open(args.url, timeout=5) as response:
        if response.status != 200:
            raise RuntimeError(f"preview returned HTTP {response.status}")
    response = websocket_request(args.host, args.port, args.model_id)
    if response.get("type") != "tactical_decision":
        raise RuntimeError(f"expected tactical_decision, got {response}")
    if response.get("model_id") != args.model_id:
        raise RuntimeError(f"candidate mismatch: expected {args.model_id}, got {response.get('model_id')}")
    print(json.dumps({"web_candidate_playtest": "ok", "model_id": args.model_id, "decision": response.get("decision")}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
