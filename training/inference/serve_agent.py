from __future__ import annotations

import argparse
import errno
import json
import re
import socketserver
import time
from dataclasses import dataclass
from pathlib import Path
from threading import RLock
from typing import Any

from training.core.model_runtime import RuntimeAgentPolicy, resolve_path


DEFAULT_MANIFEST = Path("training/models/hybrid_tactical_v1_agent.json")
DEFAULT_CATALOG = Path("training/models/model_catalog.json")


def validate_inference_device(value: str) -> str:
    device = str(value).strip()
    if device in {"auto", "cpu", "cuda"} or re.fullmatch(r"cuda:[0-9]+", device):
        return device
    raise argparse.ArgumentTypeError("device must be one of: auto, cpu, cuda, cuda:N")


@dataclass(frozen=True)
class ModelCatalogEntry:
    model_id: str
    label: str
    manifest_path: Path


class AgentPolicyRegistry:
    def __init__(self, entries: list[ModelCatalogEntry], default_model_id: str, device: str = "auto") -> None:
        if not entries:
            raise ValueError("No model entries configured")
        self.entries = {entry.model_id: entry for entry in entries}
        self.default_model_id = default_model_id if default_model_id in self.entries else entries[0].model_id
        self.device = device
        self._policies: dict[str, RuntimeAgentPolicy] = {}
        self._lock = RLock()

    @classmethod
    def from_manifest(cls, manifest_path: Path, device: str = "auto") -> "AgentPolicyRegistry":
        resolved = resolve_path(manifest_path)
        data = json.loads(resolved.read_text(encoding="utf-8"))
        model_id = str(data.get("model_id", resolved.stem))
        label = str(data.get("label", model_id))
        entry = ModelCatalogEntry(model_id=model_id, label=label, manifest_path=resolved)
        return cls([entry], model_id, device=device)

    @classmethod
    def from_catalog(cls, catalog_path: Path, device: str = "auto") -> "AgentPolicyRegistry":
        resolved = resolve_path(catalog_path)
        data = json.loads(resolved.read_text(encoding="utf-8"))
        entries: list[ModelCatalogEntry] = []
        for raw in data.get("models", []):
            if not isinstance(raw, dict):
                continue
            manifest_value = raw.get("manifest")
            model_id = str(raw.get("model_id", "")).strip()
            if not manifest_value or not model_id:
                continue
            manifest_path = resolve_path(str(manifest_value), resolved.parent)
            label = str(raw.get("label", model_id))
            entries.append(ModelCatalogEntry(model_id=model_id, label=label, manifest_path=manifest_path))
        default_model_id = str(data.get("default_model_id", entries[0].model_id if entries else ""))
        return cls(entries, default_model_id, device=device)

    def get(self, model_id: str | None = None) -> RuntimeAgentPolicy:
        selected_model_id = model_id or self.default_model_id
        if selected_model_id not in self.entries:
            known = ", ".join(sorted(self.entries.keys()))
            raise ValueError(f"Unknown model_id '{selected_model_id}'. Known models: {known}")
        with self._lock:
            if selected_model_id not in self._policies:
                self._policies[selected_model_id] = RuntimeAgentPolicy(self.entries[selected_model_id].manifest_path, device=self.device)
            return self._policies[selected_model_id]

    def summaries(self) -> list[dict[str, Any]]:
        return [
            {
                "model_id": entry.model_id,
                "label": entry.label,
                "manifest": str(entry.manifest_path),
                "loaded": entry.model_id in self._policies,
                "default": entry.model_id == self.default_model_id,
            }
            for entry in self.entries.values()
        ]


class AgentRequestHandler(socketserver.StreamRequestHandler):
    @staticmethod
    def _is_disconnect_error(exc: OSError) -> bool:
        disconnect_codes = {
            errno.EPIPE,
            errno.ECONNRESET,
            errno.ECONNABORTED,
            10053,  # WSAECONNABORTED: local software aborted the connection.
            10054,  # WSAECONNRESET: connection reset by peer.
        }
        return getattr(exc, "errno", None) in disconnect_codes or getattr(exc, "winerror", None) in disconnect_codes

    def _send_json(self, payload: dict[str, Any]) -> bool:
        try:
            self.wfile.write(json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n")
            self.wfile.flush()
            return True
        except OSError as exc:
            if self._is_disconnect_error(exc):
                return False
            raise

    def setup(self) -> None:
        super().setup()
        self.registry: AgentPolicyRegistry = self.server.registry  # type: ignore[attr-defined]
        default_info = self.registry.get().info
        self._send_json({
            "type": "hello",
            "protocol": 2,
            "supports_protocols": [1, 2],
            "model_id": default_info.model_id,
            "default_model_id": self.registry.default_model_id,
            "models": self.registry.summaries(),
        })

    def handle(self) -> None:
        try:
            for raw_line in self.rfile:
                line = raw_line.decode("utf-8").strip()
                if not line:
                    continue
                start = time.perf_counter()
                try:
                    request = json.loads(line)
                    response = self._handle_request(request, start)
                except Exception as exc:
                    response = {"type": "error", "message": str(exc)}
                if not self._send_json(response):
                    return
        except OSError as exc:
            if not self._is_disconnect_error(exc):
                raise

    def _handle_request(self, request: dict[str, Any], start: float) -> dict[str, Any]:
        request_id = request.get("request_id")
        cmd = str(request.get("cmd", "act"))
        requested_model_id = str(request.get("model_id", "")).strip() or None
        if cmd == "models":
            return {
                "type": "models",
                "request_id": request_id,
                "default_model_id": self.registry.default_model_id,
                "models": self.registry.summaries(),
            }
        if cmd == "health":
            info = self.registry.get(requested_model_id).info
            return {
                "type": "health",
                "request_id": request_id,
                "model_id": info.model_id,
                "kind": info.kind,
                "input_dim": info.input_dim,
                "device": info.device,
            }
        if cmd == "act_tactical":
            policy = self.registry.get(requested_model_id)
            strength = str(request.get("strength_profile", "")).strip()
            decision = policy.act_tactical(
                tactical_features=request.get("tactical_features"),
                action_masks=request.get("action_masks"),
                strength_profile=strength or None,
            )
            return {
                "type": "tactical_decision",
                "protocol": 2,
                "request_id": request_id,
                "model_id": policy.info.model_id,
                "strength_profile": strength or policy.info.manifest_strength or "",
                "latency_ms": round((time.perf_counter() - start) * 1000.0, 3),
                "decision": {
                    "target_slot": int(decision["target_slot"]),
                    "movement_mode": int(decision["movement_mode"]),
                    "fire_mode": int(decision["fire_mode"]),
                    "skill_mode": int(decision["skill_mode"]),
                    "confidence": float(decision.get("confidence", 0.0)),
                    "protocol_version": 2,
                },
            }
        if cmd != "act":
            return {"type": "error", "request_id": request_id, "message": f"Unknown command: {cmd}"}
        policy = self.registry.get(requested_model_id)
        action = policy.act(
            observation=request.get("observation"),
            flat_observation=request.get("flat_observation"),
        )
        return {
            "type": "action",
            "request_id": request_id,
            "model_id": policy.info.model_id,
            "latency_ms": round((time.perf_counter() - start) * 1000.0, 3),
            "action": action,
        }


class ThreadedAgentServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address: tuple[str, int], handler_class: type[AgentRequestHandler], registry: AgentPolicyRegistry) -> None:
        self.registry = registry
        super().__init__(server_address, handler_class)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve a trained Pulse Arena agent over JSONL TCP.")
    parser.add_argument("--manifest", type=Path, default=None, help="Run a single model manifest. Overrides the default catalog.")
    parser.add_argument("--catalog", type=Path, default=None, help="Run a catalog of selectable model manifests.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--device", default="auto", type=validate_inference_device)
    parser.add_argument("--print-info", action="store_true")
    return parser.parse_args()


def build_registry(args: argparse.Namespace) -> AgentPolicyRegistry:
    if args.catalog is not None:
        return AgentPolicyRegistry.from_catalog(args.catalog, device=args.device)
    if args.manifest is not None:
        return AgentPolicyRegistry.from_manifest(args.manifest, device=args.device)
    if DEFAULT_CATALOG.exists():
        return AgentPolicyRegistry.from_catalog(DEFAULT_CATALOG, device=args.device)
    return AgentPolicyRegistry.from_manifest(DEFAULT_MANIFEST, device=args.device)


def main() -> None:
    args = parse_args()
    registry = build_registry(args)
    info = registry.get().info
    print(json.dumps({
        "agent_server": "loaded",
        "model_id": info.model_id,
        "default_model_id": registry.default_model_id,
        "kind": info.kind,
        "checkpoint": str(info.checkpoint),
        "input_dim": info.input_dim,
        "device": info.device,
        "metrics": info.metrics,
        "models": registry.summaries(),
    }, ensure_ascii=False), flush=True)
    if args.print_info:
        return
    with ThreadedAgentServer((args.host, args.port), AgentRequestHandler, registry) as server:
        print(json.dumps({"agent_server": "listening", "host": args.host, "port": args.port, "protocol": "jsonl_v1_v2"}, ensure_ascii=False), flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
