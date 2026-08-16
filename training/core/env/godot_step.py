"""TCP JSONL client for the Godot ``TrainingServer``.

Used by the online PPO trainer to drive the Godot training environment
without going through the IPC layer of the editor.
"""
from __future__ import annotations

import json
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]


class StepIPCUnavailableError(RuntimeError):
    pass


@dataclass
class _StageCollectConfigFields:
    """Internal: marker class — real config lives in :mod:`.stage_collector`."""


class GodotStepEnv:
    """JSONL TCP client that wraps the headless ``TrainingServer`` in Godot."""

    def __init__(
        self,
        port: int = 8765,
        host: str = "127.0.0.1",
        godot: str | None = None,
        startup_timeout: float = 60.0,
    ) -> None:
        from training.core.env.stage_collector import resolve_godot

        self.host = host
        self.port = int(port)
        self.process: subprocess.Popen | None = None
        self.sock: socket.socket | None = None
        self.file = None
        self._start_process(resolve_godot(godot))
        self._connect(startup_timeout)
        hello = self._read()
        if hello.get("type") != "hello":
            raise StepIPCUnavailableError(f"Unexpected training server hello: {hello}")

    def _start_process(self, godot: str) -> None:
        log_dir = ROOT / "training" / "artifacts" / "server_logs" / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        log_path = log_dir / f"training_server_{self.port}.log"
        command = [
            godot,
            "--headless",
            "--disable-crash-handler",
            "--accessibility",
            "disabled",
            "--log-file",
            str(log_path),
            "--path",
            str(ROOT),
            "--",
            "--training-server",
            f"--port={self.port}",
        ]
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        self._stdout_handle = log_path.open("ab")
        self.process = subprocess.Popen(
            command,
            cwd=ROOT,
            stdout=self._stdout_handle,
            stderr=subprocess.STDOUT,
            creationflags=flags,
        )

    def _connect(self, timeout: float) -> None:
        deadline = time.time() + timeout
        last_error: OSError | None = None
        while time.time() < deadline:
            try:
                self.sock = socket.create_connection((self.host, self.port), timeout=1.0)
                self.file = self.sock.makefile("rwb")
                return
            except OSError as exc:
                last_error = exc
                if self.process is not None and self.process.poll() is not None:
                    output = self._read_log_tail()
                    raise StepIPCUnavailableError(
                        f"Godot training server exited early: {output}"
                    ) from exc
                time.sleep(0.2)
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
        raise StepIPCUnavailableError(
            f"Could not connect to Godot training server on {self.host}:{self.port}: "
            f"{last_error}. Log tail: {self._read_log_tail()}"
        )

    def reset(self, config: dict[str, Any]) -> dict[str, Any]:
        return self._request({"cmd": "reset", "config": config})

    def observe(self) -> dict[str, Any]:
        return self._request({"cmd": "observe"})

    def observe_tactical(self) -> dict[str, Any]:
        return self._request({"cmd": "observe_tactical"})

    def step(self, actions: dict[str, Any], ticks: int = 1) -> dict[str, Any]:
        return self._request({"cmd": "step", "actions": actions, "ticks": int(ticks)})

    def step_tactical(
        self, decisions: dict[str, Any], ticks: int = 1
    ) -> dict[str, Any]:
        return self._request(
            {
                "cmd": "step_tactical",
                "decisions": decisions,
                "ticks": int(ticks),
            }
        )

    def close(self) -> None:
        try:
            if self.file is not None:
                self._write({"cmd": "close"})
        finally:
            if self.file is not None:
                self.file.close()
            if self.sock is not None:
                self.sock.close()
            if self.process is not None and self.process.poll() is None:
                self.process.terminate()
            if hasattr(self, "_stdout_handle") and self._stdout_handle is not None:
                self._stdout_handle.close()

    def __enter__(self) -> "GodotStepEnv":
        return self

    def __exit__(self, _exc_type, _exc, _tb) -> None:
        self.close()

    def _request(self, payload: dict[str, Any]) -> dict[str, Any]:
        self._write(payload)
        return self._read()

    def _write(self, payload: dict[str, Any]) -> None:
        if self.file is None:
            raise StepIPCUnavailableError("GodotStepEnv is not connected")
        line = json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"
        self.file.write(line)
        self.file.flush()

    def _read(self) -> dict[str, Any]:
        if self.file is None:
            raise StepIPCUnavailableError("GodotStepEnv is not connected")
        line = self.file.readline()
        if not line:
            raise StepIPCUnavailableError(
                f"Godot training server closed the connection. "
                f"Log tail: {self._read_log_tail()}"
            )
        data = json.loads(line.decode("utf-8"))
        if data.get("type") == "error":
            raise StepIPCUnavailableError(str(data.get("message", data)))
        return data

    def _read_log_tail(self) -> str:
        log_path = (
            ROOT
            / "training"
            / "artifacts"
            / "server_logs"
            / "logs"
            / f"training_server_{self.port}.log"
        )
        if not log_path.exists():
            return ""
        data = log_path.read_bytes()[-4000:]
        return data.decode("utf-8", errors="replace")