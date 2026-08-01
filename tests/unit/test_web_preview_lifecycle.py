from __future__ import annotations

import os
import socket
import subprocess
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "linux" / "web_preview.sh"


def free_loopback_port() -> int:
    """Reserve an ephemeral IPv4 loopback port long enough to discover it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class WebPreviewLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.export_directory = self.directory / "export"
        self.state_directory = self.directory / "state"
        self.port = free_loopback_port()
        self.environment = os.environ | {
            "PREVIEW_DIRECTORY": str(self.export_directory),
            "PREVIEW_HOST": "127.0.0.1",
            "PREVIEW_PORT": str(self.port),
            "PREVIEW_STATE_DIR": str(self.state_directory),
        }

    def tearDown(self) -> None:
        self.run_preview("stop")
        self.temporary.cleanup()

    def run_preview(self, action: str, *, timeout: float = 10) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), action],
            cwd=ROOT,
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def write_export(self) -> None:
        self.export_directory.mkdir()
        (self.export_directory / "index.html").write_text("<h1>preview</h1>", encoding="utf-8")

    def start_preview_process(self) -> subprocess.Popen[str]:
        return subprocess.Popen(
            ["bash", str(SCRIPT), "start"],
            cwd=ROOT,
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def wait_for(self, condition, timeout: float = 2) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        self.fail("timed out waiting for lifecycle test condition")

    def test_status_rejects_a_current_process_pid_that_is_not_the_preview_server(self) -> None:
        """Prevent a stale PID record from being trusted or signalled."""
        self.state_directory.mkdir()
        (self.state_directory / "server.pid").write_text(str(os.getpid()), encoding="utf-8")

        result = self.run_preview("status")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not belong to the preview server", result.stderr)

    def test_stop_rejects_a_current_process_pid_without_removing_its_record(self) -> None:
        """Prevent stop from signalling or clearing a foreign PID record."""
        self.state_directory.mkdir()
        pid_file = self.state_directory / "server.pid"
        pid_file.write_text(str(os.getpid()), encoding="utf-8")

        result = self.run_preview("stop")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not belong to the preview server", result.stderr)
        self.assertEqual(pid_file.read_text(encoding="utf-8"), str(os.getpid()))

    def test_start_status_stop_runs_a_loopback_preview_and_clears_its_pid_file(self) -> None:
        """Prevent lifecycle commands from leaving a healthy preview orphaned."""
        self.write_export()

        start = self.run_preview("start")
        status = self.run_preview("status")
        stop = self.run_preview("stop")

        self.assertEqual(start.returncode, 0, start.stderr)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(stop.returncode, 0, stop.stderr)
        self.assertFalse((self.state_directory / "server.pid").exists())

    def test_start_rejects_an_occupied_port_even_when_it_returns_http_success(self) -> None:
        """Prevent another HTTP service from making a failed preview start look healthy."""
        self.write_export()

        class SuccessHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - required stdlib callback name
                self.send_response(200)
                self.end_headers()

            def log_message(self, format: str, *args: object) -> None:
                pass

        server = ThreadingHTTPServer(("127.0.0.1", self.port), SuccessHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            result = self.run_preview("start")
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Web preview running", result.stdout)

    def test_failed_start_preserves_state_replaced_by_another_process(self) -> None:
        """Prevent failed-start cleanup from deleting a replacement PID/log state."""
        self.write_export()
        request_seen = threading.Event()
        release_response = threading.Event()

        class GatedFailureHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - required stdlib callback name
                request_seen.set()
                release_response.wait(timeout=2)
                self.send_response(503)
                self.end_headers()

            def log_message(self, format: str, *args: object) -> None:
                pass

        server = ThreadingHTTPServer(("127.0.0.1", self.port), GatedFailureHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        process = self.start_preview_process()
        pid_file = self.state_directory / "server.pid"
        log_file = self.state_directory / "server.log"
        try:
            self.wait_for(pid_file.exists)
            self.assertTrue(request_seen.wait(timeout=2))
            pid_file.write_text(str(os.getpid()), encoding="utf-8")
            log_file.write_text("replacement log", encoding="utf-8")
            release_response.set()
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)
            stdout, stderr = process.communicate(timeout=8)
        finally:
            release_response.set()
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=2)

        self.assertNotEqual(process.returncode, 0, stderr)
        self.assertEqual(pid_file.read_text(encoding="utf-8"), str(os.getpid()))
        self.assertEqual(log_file.read_text(encoding="utf-8"), "replacement log")

    def test_start_health_deadline_is_bounded_when_a_loopback_peer_stalls(self) -> None:
        """Prevent one slow health request from extending the five-second startup deadline."""
        self.write_export()

        class StallingHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - required stdlib callback name
                time.sleep(2)

            def log_message(self, format: str, *args: object) -> None:
                pass

        server = ThreadingHTTPServer(("127.0.0.1", self.port), StallingHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        started_at = time.monotonic()
        process = self.start_preview_process()
        try:
            try:
                stdout, stderr = process.communicate(timeout=7)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.communicate(timeout=2)
                self.fail("start exceeded the five-second health deadline")
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=2)

        self.assertNotEqual(process.returncode, 0, stderr)
        self.assertLessEqual(time.monotonic() - started_at, 5.2)


if __name__ == "__main__":
    unittest.main()
