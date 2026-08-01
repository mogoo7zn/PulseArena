# Web Preview and Debug Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a loopback-only Godot Web preview and a safe, in-game development debug overlay with performance, public match state, and bounded gameplay events.

**Architecture:** Godot exports a `Web` preset to `build/web/`; a standard-library Python server serves only that directory on `127.0.0.1:8080` with the isolation headers Godot Web needs. A Bash lifecycle wrapper owns the preview process and validates PID ownership. Inside the game, a focused event-log model and snapshot model feed a compact CanvasLayer overlay, leaving gameplay, training, inference, and browser networking unchanged.

**Tech Stack:** Godot 4.7/GDScript, Python 3.10 standard library, Bash, GNU Make, `unittest`, GitHub Actions.

## Global Constraints

- The preview listener accepts only `127.0.0.1` or `::1`; reject every other bind address before listening.
- The preview default is `127.0.0.1:8080`; do not create listeners for ports `8765` or `8766`.
- Keep Python code dependency-free beyond the standard library.
- Do not alter firewall, add a public reverse proxy, or create a system service.
- Each browser session remains an independent local simulation; do not add multiplayer networking.
- The debug panel has no network transport and starts hidden.
- The panel exposes only FPS, frame time, game state, map, remaining time, player count, projectile count, and a bounded public event feed.
- Never render controller internals, policy state, model endpoints, private energy/reserve values, or cooldowns in the Web panel.
- Skip the overlay in headless and training matches.
- This workspace currently has no usable Git metadata; run the stated verification after every task and do not claim a commit was created.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/linux/web_preview_server.py` | Validates loopback binds and serves the exported static build with Godot isolation headers. |
| `scripts/linux/export_web.sh` | Resolves Godot, imports the project, exports the `Web` preset, and verifies `index.html`. |
| `scripts/linux/web_preview.sh` | Safely starts, checks, and stops only the owned preview process. |
| `scripts/debug/debug_event_log.gd` | Formats allow-listed gameplay events and retains the newest 50 lines. |
| `scripts/debug/debug_runtime_snapshot.gd` | Creates a small public runtime snapshot from arena data. |
| `scripts/debug/debug_overlay.gd` | Renders and toggles the compact CanvasLayer panel. |
| `scripts/arena/arena_root.gd` | Creates the overlay only for interactive matches and supplies runtime data. |
| `tests/unit/test_web_preview_*.py` | Tests HTTP, lifecycle, and package contracts without Godot. |
| `tests/run_tests.gd` and `tests/smoke/debug_overlay_check.gd` | Tests bounded public event data and in-engine overlay visibility. |

### Task 1: Finish and harden the loopback Web server

**Files:**

- Modify: `scripts/linux/web_preview_server.py`
- Modify: `tests/unit/test_web_preview_server.py`

**Interfaces:**

- Produces `validate_loopback_host(host: str) -> str` accepting exactly `127.0.0.1` and `::1`.
- Produces `create_preview_server(directory: Path, host: str, port: int) -> ThreadingHTTPServer`.
- CLI: `python3 scripts/linux/web_preview_server.py --directory build/web --host 127.0.0.1 --port 8080`.

- [ ] **Step 1: Extend the failing server test contract**

```python
def test_rejects_missing_export_directory(self) -> None:
    module = load_module()
    with TemporaryDirectory() as temporary:
        with self.assertRaises(FileNotFoundError):
            module.create_preview_server(Path(temporary) / "missing", "127.0.0.1", 0)

def test_rejects_every_non_loopback_bind(self) -> None:
    module = load_module()
    for host in ("0.0.0.0", "192.168.1.5", "localhost"):
        with self.assertRaises(ValueError):
            module.validate_loopback_host(host)
```

- [ ] **Step 2: Run the server tests to verify the added contract fails**

Run: `python3 -m unittest tests.unit.test_web_preview_server -v`

Expected: the missing-directory test fails until `create_preview_server()` checks `Path.is_dir()` before binding.

- [ ] **Step 3: Implement the minimal validation and deterministic server setup**

```python
LOOPBACK_HOSTS = {"127.0.0.1", "::1"}

def validate_loopback_host(host: str) -> str:
    if host not in LOOPBACK_HOSTS:
        raise ValueError("Preview server must bind to a loopback address")
    return host

def create_preview_server(directory: Path, host: str, port: int) -> ThreadingHTTPServer:
    export_directory = directory.resolve()
    if not export_directory.is_dir():
        raise FileNotFoundError(f"Web export directory does not exist: {export_directory}")
    handler = partial(PreviewRequestHandler, directory=str(export_directory))
    return ThreadingHTTPServer((validate_loopback_host(host), port), handler)
```

Keep `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` in `end_headers()`; retain the existing cache and resource-policy headers.

- [ ] **Step 4: Run the complete server contract**

Run: `python3 -m unittest tests.unit.test_web_preview_server -v`

Expected: all loopback rejection, missing-directory, file-serving, and both required header assertions pass.

- [ ] **Step 5: Record the verification result**

Run: `python3 -m unittest tests.unit.test_web_preview_server -v`

Expected: exit code `0`. Git metadata is unavailable in this workspace, so do not attempt the planned commit.

### Task 2: Add Web export and safe preview lifecycle commands

**Files:**

- Modify: `export_presets.cfg`
- Create: `scripts/linux/export_web.sh`
- Create: `scripts/linux/web_preview.sh`
- Modify: `Makefile`
- Create: `tests/unit/test_web_preview_lifecycle.py`

**Interfaces:**

- `make web-export` writes `build/web/index.html` using the Godot preset named `Web`.
- `make web-start`, `make web-status`, and `make web-stop` delegate to `web_preview.sh`.
- `web_preview.sh` accepts exactly one positional action: `start`, `status`, or `stop`.
- Test-only environment overrides: `PREVIEW_DIRECTORY`, `PREVIEW_HOST`, `PREVIEW_PORT`, and `PREVIEW_STATE_DIR`.

- [ ] **Step 1: Write failing lifecycle tests**

```python
def test_status_rejects_a_pid_not_owned_by_preview_server(self) -> None:
    self.pid_file.write_text(str(os.getpid()), encoding="utf-8")
    completed = self.run_script("status")
    self.assertNotEqual(completed.returncode, 0)
    self.assertIn("does not belong to the preview server", completed.stderr)

def test_start_status_stop_manage_a_loopback_process(self) -> None:
    self.export_dir.mkdir()
    (self.export_dir / "index.html").write_text("ok", encoding="utf-8")
    self.assertEqual(self.run_script("start").returncode, 0)
    self.assertEqual(self.run_script("status").returncode, 0)
    self.assertEqual(self.run_script("stop").returncode, 0)
    self.assertFalse(self.pid_file.exists())
```

The test fixture assigns an unused loopback port, a temporary export directory, and a temporary state directory through the four test-only environment variables.

- [ ] **Step 2: Run lifecycle tests to prove they fail before scripts exist**

Run: `python3 -m unittest tests.unit.test_web_preview_lifecycle -v`

Expected: FAIL because `scripts/linux/web_preview.sh` and `scripts/linux/export_web.sh` do not yet exist.

- [ ] **Step 3: Add the Godot Web preset and export script**

Append a preset named `Web` to `export_presets.cfg` with `platform="Web"` and `export_path="build/web/index.html"`. Implement `export_web.sh` using the Linux export script's binary-resolution pattern:

```bash
OUTPUT_PATH="${OUTPUT_PATH:-${ROOT}/build/web/index.html}"
"${GODOT}" --headless --path "${ROOT}" --editor --quit
mkdir -p "$(dirname "${OUTPUT_PATH}")"
"${GODOT}" --headless --path "${ROOT}" --export-release "Web" "${OUTPUT_PATH}"
test -f "${OUTPUT_PATH}"
printf 'Web release written to %s\n' "${OUTPUT_PATH}"
```

Fail with the same clear exit codes used by `export_linux.sh` when Godot is missing or non-executable.

- [ ] **Step 4: Implement the lifecycle wrapper with PID ownership checks**

Use the following state defaults and ownership predicate in `web_preview.sh`:

```bash
PREVIEW_DIRECTORY="${PREVIEW_DIRECTORY:-${ROOT}/build/web}"
PREVIEW_HOST="${PREVIEW_HOST:-127.0.0.1}"
PREVIEW_PORT="${PREVIEW_PORT:-8080}"
PREVIEW_STATE_DIR="${PREVIEW_STATE_DIR:-${ROOT}/test-results/web-preview}"
PID_FILE="${PREVIEW_STATE_DIR}/server.pid"
LOG_FILE="${PREVIEW_STATE_DIR}/server.log"

owns_preview_pid() {
  local pid="$1"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/${pid}/cmdline" ]] \
    && tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -Fq "web_preview_server.py"
}
```

For `start`, reject a non-loopback `PREVIEW_HOST`, require `index.html`, reject a live owned PID, start only `python3 "${ROOT}/scripts/linux/web_preview_server.py"` using `nohup`, write its PID, and poll `http://${PREVIEW_HOST}:${PREVIEW_PORT}/` with `curl --fail --silent --show-error --max-time 1` for up to five seconds. On an unsuccessful poll, stop only the owned child and remove its state files.

For `status`, require an owned live PID and a successful local HTTP request. For `stop`, terminate only an owned live PID, wait until it exits, then remove only the preview PID and log records. Reject malformed or foreign PID records without signalling them.

- [ ] **Step 5: Add Make targets**

```make
.PHONY: web-export web-start web-status web-stop

web-export:
	GODOT_BIN="$(GODOT_BIN)" bash scripts/linux/export_web.sh

web-start:
	bash scripts/linux/web_preview.sh start

web-status:
	bash scripts/linux/web_preview.sh status

web-stop:
	bash scripts/linux/web_preview.sh stop
```

Also extend `help` so it lists the four Web targets.

- [ ] **Step 6: Run lifecycle and Makefile verification**

Run: `python3 -m unittest tests.unit.test_web_preview_lifecycle -v && make -n web-export web-start web-status web-stop && bash -n scripts/linux/export_web.sh scripts/linux/web_preview.sh`

Expected: lifecycle tests pass; dry-run references the Web scripts; Bash syntax validation exits `0`.

- [ ] **Step 7: Record the verification result**

Run: `python3 -m unittest tests.unit.test_web_preview_server tests.unit.test_web_preview_lifecycle -v`

Expected: exit code `0`. Git metadata is unavailable in this workspace, so do not attempt the planned commit.

### Task 3: Build a bounded, public debug-data model

**Files:**

- Create: `scripts/debug/debug_event_log.gd`
- Create: `scripts/debug/debug_runtime_snapshot.gd`
- Modify: `scripts/core/app_log.gd`
- Modify: `tests/run_tests.gd`

**Interfaces:**

- `DebugEventLog.append_game_event(kind: String, payload: Dictionary) -> void`
- `DebugEventLog.append_public_log(level: String, message: String) -> void`
- `DebugEventLog.get_lines() -> PackedStringArray`
- `DebugEventLog.clear() -> void`
- `DebugRuntimeSnapshot.build(map_id: String, state: String, remaining_seconds: float, player_count: int, projectile_count: int, fps: float, frame_ms: float) -> Dictionary`
- `AppLog` emits `public_log_emitted(level: String, message: String)` only from its new explicit `public_info`, `public_warn`, and `public_error` methods; ordinary `info`/`warn`/`error` remain console-only.

- [ ] **Step 1: Add failing Godot assertions for public bounds and filtering**

Add preloads and a call from `tests/run_tests.gd`:

```gdscript
const DebugEventLog = preload("res://scripts/debug/debug_event_log.gd")
const DebugRuntimeSnapshot = preload("res://scripts/debug/debug_runtime_snapshot.gd")

func _test_debug_data() -> int:

	var log := DebugEventLog.new()
	for index in range(55):
		log.append_game_event("projectile_fired", {"owner_id": index % 4})
	log.append_game_event("player_damaged", {"victim_id": 1, "energy": 0.7, "reserve": 12.0})
	var lines := log.get_lines()
	var snapshot := DebugRuntimeSnapshot.build("dungeon", "PLAYING", 42.0, 4, 9, 60.0, 16.7)
	if lines.size() != 50 or "energy" in "\n".join(lines).to_lower() or "reserve" in "\n".join(lines).to_lower():
		return 1
	return 0 if snapshot == {"map_id": "dungeon", "state": "PLAYING", "remaining_seconds": 42.0, "player_count": 4, "projectile_count": 9, "fps": 60.0, "frame_ms": 16.7} else 1
```

- [ ] **Step 2: Run Godot tests to verify the new data-model test fails**

Run: `godot --headless --path . --script tests/run_tests.gd`

Expected: FAIL because the two debug classes do not exist.

- [ ] **Step 3: Implement the small model classes and opt-in public AppLog signal**

```gdscript
# debug_event_log.gd
class_name DebugEventLog
const MAX_ENTRIES := 50
var _entries: PackedStringArray = PackedStringArray()

func append_game_event(kind: String, payload: Dictionary) -> void:
	var line := _format_game_event(kind, payload)
	if not line.is_empty():
		_append(line)

func _append(line: String) -> void:
	_entries.append(line)
	if _entries.size() > MAX_ENTRIES:
		_entries.remove_at(0)
```

`_format_game_event()` must use only event-specific public keys: player IDs, killer IDs, projectile IDs, amount, and remaining seconds. Never serialize whole payload dictionaries. `append_public_log()` stores the supplied level and message, but not arbitrary context.

```gdscript
# debug_runtime_snapshot.gd
class_name DebugRuntimeSnapshot

static func build(map_id: String, state: String, remaining_seconds: float, player_count: int, projectile_count: int, fps: float, frame_ms: float) -> Dictionary:
	return {"map_id": map_id, "state": state, "remaining_seconds": remaining_seconds, "player_count": player_count, "projectile_count": projectile_count, "fps": fps, "frame_ms": frame_ms}
```

Add `signal public_log_emitted(level: String, message: String)` to `AppLog`. The new public methods call the existing private `_log()` path for console output, then emit only the level name and message; never emit their context dictionary.

- [ ] **Step 4: Run the project test suite**

Run: `godot --headless --path . --script tests/run_tests.gd`

Expected: `PASS: Godot unit tests`, including the 50-entry bound, private-token exclusion, and exact runtime snapshot assertion.

- [ ] **Step 5: Record the verification result**

Run: `godot --headless --path . --script tests/run_tests.gd`

Expected: exit code `0`. Git metadata is unavailable in this workspace, so do not attempt the planned commit.

### Task 4: Render and wire the compact in-game debug overlay

**Files:**

- Modify: `scripts/debug/debug_overlay.gd`
- Modify: `scenes/debug/DebugOverlay.tscn`
- Modify: `scripts/core/input_registry.gd`
- Modify: `scripts/core/game_flow_manager.gd`
- Modify: `scripts/arena/arena_root.gd`
- Create: `tests/smoke/debug_overlay_check.gd`
- Modify: `tests/smoke/run_headless_smoke.sh`

**Interfaces:**

- `DebugOverlay.configure(arena: Node) -> void`
- `DebugOverlay.update_runtime(snapshot: Dictionary) -> void`
- `DebugOverlay.toggle_visibility() -> void`
- Input action `toggle_debug_overlay` is registered with `KEY_F3`.
- `ArenaRoot` owns `var debug_overlay: DebugOverlay` only when `config.headless == false`.

- [ ] **Step 1: Write the failing overlay smoke check**

```gdscript
extends SceneTree
const DEBUG_OVERLAY_SCENE := preload("res://scenes/debug/DebugOverlay.tscn")

func _init() -> void:
	var overlay := DEBUG_OVERLAY_SCENE.instantiate() as DebugOverlay
	root.add_child(overlay)
	call_deferred("_run", overlay)

func _run(overlay: DebugOverlay) -> void:
	overlay.update_runtime({"map_id": "dungeon", "state": "PLAYING", "remaining_seconds": 12.0, "player_count": 4, "projectile_count": 3, "fps": 60.0, "frame_ms": 16.7})
	if overlay.visible:
		quit(1)
		return
	overlay.toggle_visibility()
	if not overlay.visible or not overlay.get_display_text().contains("FPS") or not overlay.get_display_text().contains("Dungeon"):
		quit(1)
		return
	quit(0)
```

- [ ] **Step 2: Run the smoke check to verify it fails**

Run: `godot --headless --path . --script tests/smoke/debug_overlay_check.gd`

Expected: FAIL because the existing overlay has neither `update_runtime()` nor `get_display_text()` and starts visible by default.

- [ ] **Step 3: Replace the monolithic diagnostic text with a focused overlay UI**

In `DebugOverlay`, create a right-top `PanelContainer` containing a title, one runtime `Label`, one events `Label`, and a `Button` labelled `DEBUG`. Build all controls in `_ready()` so the scene remains small. Set anchors to `ANCHOR_END`, offsets to keep a 16px upper-right margin, `mouse_filter = Control.MOUSE_FILTER_STOP`, and `visible = false`.

Implement the public surface:

```gdscript
func update_runtime(snapshot: Dictionary) -> void:
	_runtime_label.text = "FPS %.1f · %.1f ms\n%s · %s\nTime %05.1f · Players %d · Projectiles %d" % [
		float(snapshot.get("fps", 0.0)), float(snapshot.get("frame_ms", 0.0)),
		str(snapshot.get("state", "UNKNOWN")), str(snapshot.get("map_id", "unknown")).capitalize(),
		float(snapshot.get("remaining_seconds", 0.0)), int(snapshot.get("player_count", 0)), int(snapshot.get("projectile_count", 0)),
	]

func toggle_visibility() -> void:
	visible = not visible

func get_display_text() -> String:
	return _runtime_label.text + "\n" + _events_label.text
```

Instantiate `DebugEventLog`, connect only to the typed `GameEvents` signals and `AppLog.public_log_emitted`, and render its newest six lines. Do not call the legacy `update_agent_diagnostics()` or read controller diagnostics.

- [ ] **Step 4: Register the control and feed the overlay from ArenaRoot**

Add `"toggle_debug_overlay": []` to `InputRegistry.ACTIONS` and register `KEY_F3`. In `ArenaRoot`, preload `DebugOverlay.tscn` and `debug_runtime_snapshot.gd`; after the HUD is created for a non-headless match, create a second `CanvasLayer` with layer `30`, instantiate the overlay, call `configure(self)`, and retain it in `debug_overlay`.

At a 4 Hz update interval in `_physics_process`, pass:

```gdscript
DebugRuntimeSnapshot.build(
	config.map_id,
	GameFlowManagerService.GameState.keys()[GameFlowManager.current_state],
	match_manager.remaining_time,
	players.size(),
	projectiles.size(),
	Engine.get_frames_per_second(),
	Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
)
```

Handle `Input.is_action_just_pressed("toggle_debug_overlay")` in the overlay's `_unhandled_input`. Add `AppLog.public_info("Game state changed")` adjacent to the existing state log in `GameFlowManager.goto_state()` so the event feed captures state transitions without serializing context.

- [ ] **Step 5: Run focused and full smoke verification**

Run: `godot --headless --path . --script tests/smoke/debug_overlay_check.gd && bash tests/smoke/run_headless_smoke.sh`

Expected: the focused test exits `0`; headless tests still pass, proving the overlay is not required by training matches.

- [ ] **Step 6: Record the verification result**

Run: `python3 tests/smoke/static_project_check.py && godot --headless --path . --script tests/run_tests.gd`

Expected: both commands exit `0`. Git metadata is unavailable in this workspace, so do not attempt the planned commit.

### Task 5: Package, document, automate, and deploy the workflow locally

**Files:**

- Modify: `README.md`
- Modify: `docs/linux_port_zh.md`
- Modify: `training/package_server_bundle.py`
- Modify: `.github/workflows/linux.yml`
- Modify: `.gitignore`
- Create: `tests/unit/test_web_preview_package.py`

**Interfaces:**

- The README and Linux guide document `make web-export`, `make web-start`, `make web-status`, and `make web-stop`.
- The server bundle contains `export_web.sh`, `web_preview.sh`, and `web_preview_server.py` through the existing `scripts` directory inclusion.
- CI validates Python tests, Godot Web export, headers, lifecycle status, and cleanup.

- [ ] **Step 1: Write a failing package-content test**

```python
def test_server_bundle_includes_web_preview_entrypoints(self) -> None:
    completed = subprocess.run(
        [sys.executable, str(ROOT / "training/package_server_bundle.py"), "--output-dir", str(self.output_dir), "--bundle-id", "web-preview", "--stamp", "test"],
        check=True, capture_output=True, text=True,
    )
    bundle = Path(json.loads(completed.stdout)["bundle"])
    with tarfile.open(bundle, "r:gz") as archive:
        names = set(archive.getnames())
    for path in ("scripts/linux/export_web.sh", "scripts/linux/web_preview.sh", "scripts/linux/web_preview_server.py"):
        self.assertIn(f"web-preview_test/{path}", names)
```

- [ ] **Step 2: Run the package test to verify it fails**

Run: `python3 -m unittest tests.unit.test_web_preview_package -v`

Expected: FAIL until all three preview entrypoints exist under `scripts/linux/`.

- [ ] **Step 3: Document secure Cursor access and development controls**

Add a `Web Preview` section to `README.md` and `docs/linux_port_zh.md` with the four Make commands, the fixed local URL `http://127.0.0.1:8080/`, the instruction to forward port `8080` in Cursor's existing Ports panel, and the guarantee that no training/inference port is exposed. Document F3 and the on-canvas `DEBUG` button, the metrics shown, and that the overlay is development-only.

Add `.superpowers/` to `.gitignore` so temporary brainstorming screens and access keys are never packaged or committed.

- [ ] **Step 4: Extend CI with Web preview validation**

In the existing `godot` job, retain the already-installed export templates and add this post-Linux-export step using the same `GODOT_BIN` environment:

```yaml
- name: Export and verify Web preview
  env:
    GODOT_BIN: ${{ runner.temp }}/godot/Godot_v${{ env.GODOT_VERSION }}-stable_linux.x86_64
  run: |
    set -euo pipefail
    make web-export
    make web-start
    trap 'make web-stop || true' EXIT
    make web-status
    curl --fail --silent --show-error --head http://127.0.0.1:8080/ | grep -Fi 'Cross-Origin-Opener-Policy: same-origin'
    curl --fail --silent --show-error --head http://127.0.0.1:8080/ | grep -Fi 'Cross-Origin-Embedder-Policy: require-corp'
```

In the `static` job add `python -m unittest tests.unit.test_web_preview_server tests.unit.test_web_preview_lifecycle tests.unit.test_web_preview_package -v` and include the two new shell scripts in the `bash -n` command.

- [ ] **Step 5: Run package and static verification**

Run: `python3 -m unittest tests.unit.test_web_preview_server tests.unit.test_web_preview_lifecycle tests.unit.test_web_preview_package -v && python3 training/package_server_bundle.py --output-dir /tmp/pulsearena-web-package --bundle-id pulsearena-web --stamp verify && python3 tests/smoke/static_project_check.py`

Expected: every test passes, the tarball reports a path under `/tmp/pulsearena-web-package`, and the static project check prints `PASS`.

- [ ] **Step 6: Perform the local deployment verification**

Run: `make web-export && make web-start && make web-status && curl --fail --silent --show-error --head http://127.0.0.1:8080/ && ss -ltnp '( sport = :8080 )' && make web-stop`

Expected: export produces `build/web/index.html`; status succeeds; `curl` returns `200` plus both isolation headers; `ss` reports only `127.0.0.1:8080`; stop removes the preview state without signalling another process.

- [ ] **Step 7: Record the verification result**

Run: `make test && python3 -m unittest tests.unit.test_web_preview_server tests.unit.test_web_preview_lifecycle tests.unit.test_web_preview_package -v`

Expected: all available local tests exit `0`. If Godot Web templates are missing, report the exact `make web-export` error and request approval before downloading or installing software. Git metadata is unavailable in this workspace, so do not attempt the planned commit.

## Plan Self-Review

- Spec coverage: Tasks 1-2 implement loopback-only export and lifecycle; Tasks 3-4 implement the hidden, compact, public-only in-game overlay; Task 5 covers documentation, package content, CI, ignored temporary design files, and deployment verification.
- Completeness scan: every task names its files, public interfaces, test command, expected result, and implementation boundary; no deferred implementation markers remain.
- Type consistency: `DebugEventLog`, `DebugRuntimeSnapshot`, `DebugOverlay`, and the Make/lifecycle target names are introduced before consumers use them. The runtime snapshot keys match the overlay formatter and its smoke test.

## Execution Handoff

Plan complete. Execute the tasks in order, preserving the test-first checks and recording the actual verification output after each task.
