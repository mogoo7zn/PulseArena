from __future__ import annotations

import importlib.util
import errno
import socket
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.request import ProxyHandler, build_opener


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "linux" / "web_preview_server.py"


def load_module():
    spec = importlib.util.spec_from_file_location("web_preview_server", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WebPreviewServerTests(unittest.TestCase):
    def test_formats_ipv6_cli_url_with_brackets(self) -> None:
        """Protect copyable IPv6 output from being parsed as an invalid URL."""
        module = load_module()

        self.assertEqual(module.preview_url("::1", 8080), "http://[::1]:8080/")
        self.assertEqual(module.preview_url("127.0.0.1", 8080), "http://127.0.0.1:8080/")

    def test_rejects_every_non_loopback_bind(self) -> None:
        """Protect against accidentally exposing the preview on every interface."""
        module = load_module()

        for host in ("0.0.0.0", "192.168.1.5", "localhost"):
            with self.assertRaises(ValueError):
                module.validate_loopback_host(host)

    def test_rejects_missing_export_directory(self) -> None:
        """Protect against binding a server that cannot serve an export."""
        module = load_module()

        with TemporaryDirectory() as temporary:
            with self.assertRaises(FileNotFoundError):
                module.create_preview_server(Path(temporary) / "missing", "127.0.0.1", 0)

    def test_serves_export_with_godot_isolation_headers(self) -> None:
        """Protect against browsers disabling Godot Web shared-memory features."""
        module = load_module()
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "index.html").write_text("preview", encoding="utf-8")
            server = module.create_preview_server(directory, "127.0.0.1", 0)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                port = server.server_address[1]
                opener = build_opener(ProxyHandler({}))
                with opener.open(f"http://127.0.0.1:{port}/", timeout=2.0) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), b"preview")
                    self.assertEqual(response.headers["Cross-Origin-Opener-Policy"], "same-origin")
                    self.assertEqual(response.headers["Cross-Origin-Embedder-Policy"], "require-corp")
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=2.0)

    def test_serves_export_over_ipv6_loopback_when_available(self) -> None:
        """Protect the allowed ::1 bind from silently using an IPv4-only server."""
        if not socket.has_ipv6:
            self.skipTest("IPv6 is unavailable")

        module = load_module()
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "index.html").write_text("ipv6 preview", encoding="utf-8")
            try:
                server = module.create_preview_server(directory, "::1", 0)
            except OSError as exc:
                if exc.errno in (errno.EADDRNOTAVAIL, errno.EAFNOSUPPORT):
                    self.skipTest("IPv6 loopback is unavailable")
                raise
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                port = server.server_address[1]
                opener = build_opener(ProxyHandler({}))
                with opener.open(f"http://[::1]:{port}/", timeout=2.0) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), b"ipv6 preview")
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=2.0)


if __name__ == "__main__":
    unittest.main()
