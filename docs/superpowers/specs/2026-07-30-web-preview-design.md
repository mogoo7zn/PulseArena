# Web Preview Design

## Goal

Provide a browser-playable Pulse Arena build from the Linux server without
exposing training, inference, or other project TCP services to the network.

## Scope

The server will export the existing single-player/local-agent Godot game to
Web and serve the generated static files on `127.0.0.1:8080`. The user will
use the platform's authenticated port-forwarding feature to reach that local
port from their browser.

This is a preview host, not multiplayer networking. Every browser session
runs its own game simulation. Ports `8765` and `8766` remain loopback-only
training and model-inference protocols and are never forwarded or exposed.

## Architecture

`make web-export` invokes Godot's `Web` export preset and writes its output to
`build/web/`. `make web-start` starts a Python standard-library static server
that serves only that directory, binds to `127.0.0.1`, and writes a PID/status
record under `test-results/`. The server adds Cross-Origin-Opener-Policy and
Cross-Origin-Embedder-Policy response headers required by Godot Web builds
that use shared-memory features.

`make web-status` verifies that the process is alive and performs a local HTTP
health check. `make web-stop` terminates only the process recorded in the PID
file. The start command rejects a non-loopback bind address and refuses to
serve a missing export directory.

## Access Control

The preview process is unreachable from external network interfaces because
it binds to `127.0.0.1`. The server firewall remains unchanged. Access is
granted by the port-forwarding platform's user authentication and forwarding
policy. A forwarded URL must not be shared when private access is required.

## Commands

```bash
make web-export
make web-start
make web-status
make web-stop
```

The forwarded local port is `8080`. The service does not install a public
reverse proxy, modify UFW, or create a system-wide service.

## Failure Handling

Web export fails clearly when Godot or its Web export templates are absent.
The server exits with a non-zero code for an invalid bind address, unavailable
port, missing export directory, or invalid PID record. Startup performs an
HTTP request to `http://127.0.0.1:8080/` and reports failure instead of
claiming the preview is ready.

## Verification

Automated tests cover loopback-only binding validation, safe PID ownership
checks, health endpoint behavior, and Godot response headers. The deployment
verification runs `make web-export`, starts the server, confirms a successful
local HTTP response and headers, then stops it. The actual browser URL is
provided by the user's port-forwarding system after the local verification.
