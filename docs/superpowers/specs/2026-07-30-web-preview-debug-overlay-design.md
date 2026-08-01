# Web Preview and Debug Overlay Design

## Goal

Export Pulse Arena as a browser-playable Godot Web build and provide a
development-only, in-game debugging overlay. The Web preview is served only
from the server loopback interface and accessed from a developer workstation
through its existing authenticated Cursor/SSH port forwarding.

## Scope

The preview workflow exports the existing local single-player/agent game to
`build/web/` and serves it at `127.0.0.1:8080`. It provides `make web-export`,
`make web-start`, `make web-status`, and `make web-stop`.

The game includes a development debugging overlay rendered inside the Godot
canvas. It is not a second browser application and opens no additional port.
The overlay uses the approved compact, top-right layout and is hidden by
default. A keyboard toggle (F3) and a visible development control make it
available on desktop and touch-only browser sessions.

## Security and Access Control

- The preview server accepts only `127.0.0.1` and `::1`; non-loopback bind
  addresses fail before listening.
- Port `8080` is the only preview port. Ports `8765` and `8766` remain
  loopback-only training and inference protocols and are neither served nor
  forwarded by project tooling.
- The developer forwards port `8080` through Cursor's existing Remote SSH
  connection. No firewall, public reverse proxy, or system service is added.
- The in-game panel has no network transport and cannot expose remote service
  state. It only renders local match diagnostics.
- The panel excludes controller internals, policy state, exact private energy,
  reserve values, cooldowns, model endpoints, and training/inference data.

## Architecture

### Web preview lifecycle

`export_web.sh` resolves `GODOT_BIN`, imports the project headlessly, exports
the `Web` preset, and verifies `build/web/index.html`. A standard-library
Python server receives an export directory and loopback host/port, serves only
that directory, and adds Godot Web isolation headers:

- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

`web_preview.sh` owns the background process through a PID file and log file
under `test-results/web-preview/`. It verifies that a recorded PID belongs to
the preview server before reporting status or stopping it, polls the local HTTP
endpoint after start, and removes stale or invalid state safely.

### In-game debug overlay

The existing `DebugOverlay` becomes a focused UI layer with three parts:

1. A runtime snapshot provider gathers public match metrics: FPS, frame time,
   game state, map ID, remaining time, player count, and projectile count.
2. A bounded event log subscribes to `GameEvents` and `AppLog`, formats public
   gameplay events, and retains the newest 50 records in memory.
3. The overlay presents the snapshot and latest event records in a compact
   top-right panel. It owns only formatting, visibility, and input handling.

The arena attaches the overlay for interactive matches only. It is skipped in
headless/training execution. The overlay starts hidden, toggles on F3, and has
a small in-canvas development button so browser sessions without a keyboard can
open it. Its status label clearly identifies development diagnostics.

## Data Flow

`ArenaRoot` supplies count and map context to the snapshot provider each frame.
`GameEvents` supplies typed gameplay events such as shots, damage, kills,
respawns, pause/resume, and match completion. `AppLog` emits structured public
records to the same bounded log after honoring its minimum level. The overlay
updates its label at a throttled interval rather than rebuilding UI each frame.

No debug data is sent from the Web build to the static server. Browser console
output remains useful for engine diagnostics but is not a dependency of the
panel.

## Failure Handling

Missing Godot binaries or Web templates cause `make web-export` to fail with a
clear error. Missing exports, invalid bind addresses, unavailable ports, and
forged PID records cause lifecycle commands to fail without touching unrelated
processes. Overlay instrumentation must tolerate absent arena state and unknown
event payloads without interrupting a match.

## Verification

Automated tests cover loopback validation, static-file serving, Godot response
headers, lifecycle PID ownership, lifecycle start/status/stop, bundle contents,
and public event-log bounds/formatting. Local deployment verification exports
the Web preset, starts the preview, checks HTTP `200` and the two isolation
headers at `127.0.0.1:8080`, confirms the listener address is loopback, then
stops the process. Interactive verification starts a match in the exported
build and confirms F3 plus the on-canvas control show and hide the panel.
