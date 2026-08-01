#!/usr/bin/env python3
"""Serve a Godot Web export only through a loopback HTTP listener."""
from __future__ import annotations

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket


LOOPBACK_HOSTS = {"127.0.0.1", "::1"}


def validate_loopback_host(host: str) -> str:
    if host not in LOOPBACK_HOSTS:
        raise ValueError("Preview server must bind to a loopback address")
    return host


class PreviewRequestHandler(SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


class IPv6ThreadingHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def create_preview_server(directory: Path, host: str, port: int) -> ThreadingHTTPServer:
    export_directory = directory.resolve()
    if not export_directory.is_dir():
        raise FileNotFoundError(f"Web export directory does not exist: {export_directory}")
    handler = partial(PreviewRequestHandler, directory=str(export_directory))
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
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        server = create_preview_server(args.directory, args.host, args.port)
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
