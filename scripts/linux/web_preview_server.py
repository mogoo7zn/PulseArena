#!/usr/bin/env python3
"""Serve a Godot Web export only through a loopback HTTP listener."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import struct


LOOPBACK_HOSTS = {"127.0.0.1", "::1"}
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_WEBSOCKET_PAYLOAD = 1024 * 1024
UPSTREAM_TIMEOUT_SECONDS = 2.0


def validate_loopback_host(host: str) -> str:
    if host not in LOOPBACK_HOSTS:
        raise ValueError("Preview server must bind to a loopback address")
    return host


class PreviewRequestHandler(SimpleHTTPRequestHandler):
    agent_host = "127.0.0.1"
    agent_port = 8766

    def do_GET(self) -> None:  # noqa: N802 - stdlib HTTP callback name
        if self.path == "/agent" and self.headers.get("Upgrade", "").lower() == "websocket":
            self._serve_agent_websocket()
            return
        super().do_GET()

    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def _serve_agent_websocket(self) -> None:
        key = self.headers.get("Sec-WebSocket-Key", "")
        connection = self.headers.get("Connection", "").lower()
        if not key or "upgrade" not in connection:
            self.send_error(400, "Invalid WebSocket upgrade")
            return
        accept = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                opcode, payload = self._read_websocket_frame()
                if opcode == 0x8:
                    self._write_websocket_frame(0x8, payload)
                    return
                if opcode == 0x9:
                    self._write_websocket_frame(0xA, payload)
                    continue
                if opcode != 0x1:
                    raise ValueError("Only WebSocket text frames are supported")
                request = json.loads(payload.decode("utf-8"))
                if not isinstance(request, dict):
                    raise ValueError("WebSocket request must be a JSON object")
                response = self._forward_agent_request(request)
                self._write_websocket_frame(0x1, json.dumps(response, separators=(",", ":")).encode("utf-8"))
        except (ConnectionError, OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError) as exc:
            try:
                self._write_websocket_frame(0x1, json.dumps({"type": "error", "message": str(exc)}).encode("utf-8"))
            except (ConnectionError, OSError):
                pass

    def _forward_agent_request(self, request: dict[str, object]) -> dict[str, object]:
        payload = (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        with socket.create_connection((self.agent_host, self.agent_port), timeout=UPSTREAM_TIMEOUT_SECONDS) as upstream:
            upstream.settimeout(UPSTREAM_TIMEOUT_SECONDS)
            upstream.sendall(payload)
            response = self._read_jsonl_response(upstream)
        if not isinstance(response, dict):
            raise ValueError("Inference service returned a non-object JSON response")
        return response

    @staticmethod
    def _read_jsonl_response(upstream: socket.socket) -> object:
        with upstream.makefile("rb") as reader:
            while True:
                raw_response = reader.readline(MAX_WEBSOCKET_PAYLOAD + 1)
                if not raw_response:
                    raise ConnectionError("Inference service closed before responding")
                if len(raw_response) > MAX_WEBSOCKET_PAYLOAD:
                    raise ValueError("Inference response exceeds 1 MiB")
                response = json.loads(raw_response.decode("utf-8"))
                if isinstance(response, dict) and response.get("type") == "hello":
                    continue
                return response

    def _read_websocket_frame(self) -> tuple[int, bytes]:
        first, second = self._read_exact(2)
        final = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        payload_length = second & 0x7F
        if not final:
            raise ValueError("Fragmented WebSocket frames are not supported")
        if not masked:
            raise ValueError("Browser WebSocket frames must be masked")
        if payload_length == 126:
            payload_length = struct.unpack("!H", self._read_exact(2))[0]
        elif payload_length == 127:
            payload_length = struct.unpack("!Q", self._read_exact(8))[0]
        if payload_length > MAX_WEBSOCKET_PAYLOAD:
            raise ValueError("WebSocket frame exceeds 1 MiB")
        mask = self._read_exact(4)
        payload = self._read_exact(payload_length)
        return opcode, bytes(value ^ mask[index % 4] for index, value in enumerate(payload))

    def _write_websocket_frame(self, opcode: int, payload: bytes) -> None:
        if len(payload) > MAX_WEBSOCKET_PAYLOAD:
            raise ValueError("WebSocket response exceeds 1 MiB")
        header = bytearray([0x80 | opcode])
        if len(payload) < 126:
            header.append(len(payload))
        elif len(payload) <= 0xFFFF:
            header.append(126)
            header.extend(struct.pack("!H", len(payload)))
        else:
            header.append(127)
            header.extend(struct.pack("!Q", len(payload)))
        self.wfile.write(bytes(header) + payload)
        self.wfile.flush()

    def _read_exact(self, count: int) -> bytes:
        data = self.rfile.read(count)
        if len(data) != count:
            raise ConnectionError("WebSocket client closed before frame completed")
        return data


class IPv6ThreadingHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def create_preview_server(directory: Path, host: str, port: int, agent_host: str = "127.0.0.1", agent_port: int = 8766) -> ThreadingHTTPServer:
    export_directory = directory.resolve()
    if not export_directory.is_dir():
        raise FileNotFoundError(f"Web export directory does not exist: {export_directory}")
    validated_agent_host = validate_loopback_host(agent_host)
    handler_class = type(
        "PreviewAgentRequestHandler",
        (PreviewRequestHandler,),
        {"agent_host": validated_agent_host, "agent_port": int(agent_port)},
    )
    handler = partial(handler_class, directory=str(export_directory))
    bind_host = validate_loopback_host(host)
    server_class = IPv6ThreadingHTTPServer if bind_host == "::1" else ThreadingHTTPServer
    return server_class((bind_host, port), handler)


def preview_url(host: str, port: int) -> str:
    """Return the copyable loopback URL shown by the command-line server."""
    address = f"[{host}]" if ":" in host else host
    return f"http://{address}:{port}/"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--agent-host", default="127.0.0.1")
    parser.add_argument("--agent-port", type=int, default=8766)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        server = create_preview_server(args.directory, args.host, args.port, args.agent_host, args.agent_port)
    except (FileNotFoundError, OSError, ValueError) as exc:
        raise SystemExit(str(exc)) from exc
    host, port = server.server_address[:2]
    print(f"Pulse Arena Web preview listening at {preview_url(host, port)}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
