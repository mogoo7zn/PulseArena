from __future__ import annotations

import argparse
import errno
import json
import re
import socketserver
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import RLock
from typing import Any
from urllib.parse import urlparse

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
                "kind": _safe_read_kind(entry.manifest_path),
            }
            for entry in self.entries.values()
        ]


def _safe_read_kind(manifest_path: Path) -> str:
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    return str(data.get("kind", ""))


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
    parser.add_argument("--http-host", default="127.0.0.1", help="HTTP façade host (browser-friendly interface).")
    parser.add_argument("--http-port", type=int, default=0, help="If > 0, also serve a small HTTP API + HTML page on this port.")
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
        if args.http_port > 0:
            start_http_facade(args, registry)
        server.serve_forever()


def start_http_facade(args: argparse.Namespace, registry: "AgentPolicyRegistry") -> None:
    """Start the small HTTP façade in a daemon thread."""
    handler = _build_http_handler(registry, http_port=args.http_port, tcp_port=args.port)
    server = ThreadingHTTPServer((args.http_host, args.http_port), handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, name="http-facade", daemon=True)
    thread.start()
    print(json.dumps({"http_facade": "listening", "host": args.http_host, "port": server.server_address[1]}, ensure_ascii=False), flush=True)


def _build_http_handler(registry: "AgentPolicyRegistry", http_port: int, tcp_port: int):
    class HttpHandler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            return  # silence stderr access log

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path == "/":
                self._render_index()
            elif parsed.path == "/api/health":
                self._json_ok({"status": "ok", "tcp_port": tcp_port, "http_port": http_port, "models": len(registry.entries)})
            elif parsed.path == "/api/models":
                self._json_ok({"models": registry.summaries()})
            else:
                self._json_error(404, "not found")

        def do_POST(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path == "/api/act_tactical":
                self._handle_act_tactical()
            else:
                self._json_error(404, "not found")

        def _render_index(self) -> None:
            summaries = registry.summaries()
            rows = []
            for summary in summaries:
                # Read the manifest directly so the page renders even for
                # models whose checkpoint file is missing on disk.
                try:
                    manifest_data = json.loads(Path(summary["manifest"]).read_text(encoding="utf-8"))
                    strength = str(manifest_data.get("inference_profile", {}).get("strength", ""))
                except (OSError, json.JSONDecodeError):
                    strength = ""
                rows.append(
                    f"<tr><td><code>{_esc(summary['model_id'])}</code></td>"
                    f"<td>{_esc(summary['label'])}</td>"
                    f"<td>{_esc(summary.get('kind', ''))}</td>"
                    f"<td>{_esc(strength) or '—'}</td></tr>"
                )
            html = (
                "<!doctype html><html><head><meta charset='utf-8'>"
                "<title>Pulse Arena Hybrid Tactical — 5-tier HTTP demo</title>"
                "<style>body{font-family:system-ui,sans-serif;max-width:880px;margin:24px auto;padding:0 16px;color:#1f2937}"
                "h1{font-size:20px;margin:0 0 4px}h2{font-size:14px;color:#6b7280;margin:0 0 16px}"
                "table{border-collapse:collapse;width:100%}td,th{border:1px solid #e5e7eb;padding:6px 8px;font-size:13px;text-align:left}"
                "code{font-family:ui-monospace,monospace;font-size:12px}"
                "form{margin:24px 0;padding:16px;border:1px solid #e5e7eb;border-radius:8px}"
                "label{display:block;font-size:13px;margin:6px 0 2px}"
                "input,select{font-size:13px;padding:4px 6px}"
                "button{margin-top:8px;padding:6px 12px;background:#2563eb;color:#fff;border:0;border-radius:4px;cursor:pointer}"
                "pre{background:#f9fafb;padding:8px;border-radius:4px;font-size:12px;overflow:auto}"
                "</style></head><body>"
                "<h1>Pulse Arena · Hybrid Tactical HTTP façade</h1>"
                "<h2>9 models / 5 difficulty tiers / 1 checkpoint per tier</h2>"
                "<table><thead><tr><th>model_id</th><th>label</th><th>kind</th><th>inference_profile.strength</th></tr></thead>"
                f"<tbody>{''.join(rows)}</tbody></table>"
                "<form id='form'>"
                "<label>model_id (default tier matches strength): "
                "<select name='model_id'>"
                + "".join(
                    f"<option value='{_esc(s['model_id'])}'>{_esc(s['model_id'])}</option>"
                    for s in summaries
                )
                + "</select></label>"
                "<label>strength_profile (optional; falls back to manifest.inference_profile.strength): "
                "<select name='strength_profile'>"
                "<option value=''>(none)</option>"
                "<option value='easy'>easy (T=1.6 soften=0.30 safe=0.55)</option>"
                "<option value='casual'>casual (T=1.1 soften=0.20 safe=0.65)</option>"
                "<option value='normal'>normal (T=0.85 soften=0.10 safe=0.75)</option>"
                "<option value='strong'>strong (T=0.55 soften=0.05 safe=0.85)</option>"
                "<option value='elite'>elite (T=0.25 soften=0.0 safe=0.95)</option>"
                "</select></label>"
                "<label>tactical_features (142 floats, comma-separated; zeros are fine): "
                "<input name='features' size='80' value='"
                + ",".join(["0.0"] * 142)
                + "'></label>"
                "<label>action_masks preset: "
                "<select name='mask_preset'>"
                "<option value='all'>all-True</option>"
                "<option value='no_fire'>no fire_mode</option>"
                "<option value='no_target'>no target_slot 0..2</option>"
                "</select></label>"
                "<button type='submit'>Run act_tactical</button>"
                "</form>"
                "<h2>Response</h2><pre id='out'>Submit the form to see JSON…</pre>"
                "<script>"
                "const f=document.getElementById('form'),out=document.getElementById('out');"
                "f.addEventListener('submit',async e=>{e.preventDefault();out.textContent='…';"
                "const fd=new FormData(f);"
                "const masks=(()=>{"
                "  const p=fd.get('mask_preset');const all=()=>Array.from({length:1},()=>true);"
                "  let ts=[1,1,1,1,1,1,1],mv=[1,1,1,1,1,1,1,1,1,1,1,1],fm=[1,1,1,1,1,1],sk=[1,1,1,1,1,1];"
                "  if(p==='no_fire')fm=[0,0,0,0,0,0];"
                "  if(p==='no_target')ts=[0,0,0,1,1,1,1];"
                "  return {target_slot:ts,movement_mode:mv,fire_mode:fm,skill_mode:sk};"
                "})();"
                "const r=await fetch('/api/act_tactical',{method:'POST',headers:{'Content-Type':'application/json'},"
                "body:JSON.stringify({"
                "  model_id:fd.get('model_id'),"
                "  strength_profile:fd.get('strength_profile')||null,"
                "  tactical_features:fd.get('features').split(',').map(Number),"
                "  action_masks:masks"
                "})});"
                "out.textContent=JSON.stringify(await r.json(),null,2);"
                "});"
                "</script>"
                "</body></html>"
            )
            body = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _handle_act_tactical(self) -> None:
            length = int(self.headers.get("Content-Length", "0") or 0)
            raw = self.rfile.read(length) if length else b""
            try:
                request = json.loads(raw.decode("utf-8")) if raw else {}
            except json.JSONDecodeError as exc:
                self._json_error(400, f"invalid JSON body: {exc}")
                return
            model_id = request.get("model_id") or ""
            try:
                policy = registry.get(model_id or None)
            except ValueError as exc:
                self._json_error(404, str(exc))
                return
            strength = str(request.get("strength_profile", "") or "").strip()
            try:
                decision = policy.act_tactical(
                    tactical_features=request.get("tactical_features"),
                    action_masks=request.get("action_masks"),
                    strength_profile=strength or None,
                )
            except Exception as exc:  # noqa: BLE001
                self._json_error(500, f"act_tactical failed: {exc}")
                return
            self._json_ok({
                "model_id": policy.info.model_id,
                "strength_profile": strength or policy.info.manifest_strength or "",
                "decision": {
                    "target_slot": int(decision["target_slot"]),
                    "movement_mode": int(decision["movement_mode"]),
                    "fire_mode": int(decision["fire_mode"]),
                    "skill_mode": int(decision["skill_mode"]),
                    "confidence": float(decision.get("confidence", 0.0)),
                    "protocol_version": 2,
                },
            })

        def _json_ok(self, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _json_error(self, status: int, message: str) -> None:
            body = json.dumps({"error": message}, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return HttpHandler


def _esc(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


if __name__ == "__main__":
    main()
