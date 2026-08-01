# Web Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export Pulse Arena to Web and serve it through a loopback-only HTTP preview endpoint suitable for authenticated port forwarding.

**Architecture:** Godot writes a Web export to `build/web/`. A Python standard-library server validates its loopback bind address and serves that directory with Godot Web isolation headers. A Bash lifecycle wrapper owns the background process through a PID file, while Make targets provide the public interface.

**Tech Stack:** Godot 4.7 Web export, Python 3.10 standard library, Bash, GNU Make, `unittest`.

## Global Constraints

- The preview listener must bind only `127.0.0.1` by default; non-loopback bind values fail.
- The preview listener uses port `8080` by default.
- `8765` and `8766` remain loopback-only and are not referenced by the preview host.
- Do not change UFW or expose a public interface.
- Python implementation dependencies must remain in the standard library.
- Each browser session is local single-player simulation; no multiplayer protocol is added.

---

### Task 1: Implement and test the loopback Web server

**Files:**
- Create: `scripts/linux/web_preview_server.py`
- Create: `tests/unit/test_web_preview_server.py`

**Interfaces:**
- Produces `validate_loopback_host(host: str) -> str`.
- Produces `create_preview_server(directory: Path, host: str, port: int) -> ThreadingHTTPServer`.
- Produces CLI `python3 scripts/linux/web_preview_server.py --directory <path> --host 127.0.0.1 --port 8080`.

- [ ] **Step 1: Write the failing server tests**

```python
def test_rejects_non_loopback_host():
    with self.assertRaises(ValueError):
        module.validate_loopback_host("0.0.0.0")

def test_serves_files_with_godot_isolation_headers():
    with temporary_preview_server({"index.html": b"ok"}) as url:
        response = urlopen(url)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.headers["Cross-Origin-Opener-Policy"], "same-origin")
        self.assertEqual(response.headers["Cross-Origin-Embedder-Policy"], "require-corp")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 -m unittest tests.unit.test_web_preview_server -v`

Expected: FAIL because `web_preview_server.py` does not exist.

- [ ] **Step 3: Implement the minimal standard-library server**

```python
def validate_loopback_host(host: str) -> str:
    if host not in {"127.0.0.1", "::1"}:
        raise ValueError("Preview server must bind to a loopback address")
    return host
```

Use `http.server.SimpleHTTPRequestHandler` with an overridden `end_headers()`
that adds `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`. Reject a missing directory
before binding and print the loopback URL once listening.

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 -m unittest tests.unit.test_web_preview_server -v`

Expected: PASS for host rejection, file serving, and both response headers.

- [ ] **Step 5: Commit**

```bash
git add scripts/linux/web_preview_server.py tests/unit/test_web_preview_server.py
git commit -m "feat: add loopback web preview server"
```

### Task 2: Add Web export and controlled server lifecycle commands

**Files:**
- Modify: `export_presets.cfg`
- Create: `scripts/linux/export_web.sh`
- Create: `scripts/linux/web_preview.sh`
- Modify: `Makefile`

**Interfaces:**
- Produces `make web-export`, which writes `build/web/index.html`.
- Produces `make web-start`, `make web-status`, and `make web-stop`.
- `scripts/linux/web_preview.sh` accepts exactly one action: `start`, `status`, or `stop`.

- [ ] **Step 1: Write failing lifecycle tests**

```python
def test_status_rejects_a_pid_not_owned_by_preview_server():
    pid_file.write_text(str(os.getpid()), encoding="utf-8")
    completed = subprocess.run(["bash", script, "status"], capture_output=True, text=True)
    self.assertNotEqual(completed.returncode, 0)

def test_start_and_stop_manage_a_loopback_preview_process():
    self.run_script("start")
    self.assertEqual(self.run_script("status").returncode, 0)
    self.assertEqual(self.run_script("stop").returncode, 0)
```

- [ ] **Step 2: Run lifecycle tests to verify they fail**

Run: `python3 -m unittest tests.unit.test_web_preview_lifecycle -v`

Expected: FAIL because export and lifecycle scripts do not exist.

- [ ] **Step 3: Implement export and lifecycle scripts**

Add a Godot `Web` export preset with `export_path="build/web/index.html"`.
`export_web.sh` resolves `GODOT_BIN`, imports the project headlessly, exports
the `Web` preset, and asserts the output HTML exists. `web_preview.sh` starts
only the Python server command under `nohup`, records its PID, polls the local
HTTP endpoint, and validates `/proc/<pid>/cmdline` contains
`web_preview_server.py` before reporting status or terminating it.

- [ ] **Step 4: Run lifecycle tests to verify they pass**

Run: `python3 -m unittest tests.unit.test_web_preview_lifecycle -v`

Expected: PASS for forged-PID rejection and start/status/stop lifecycle.

- [ ] **Step 5: Add Make targets and verify dry-run**

```make
web-export:
	GODOT_BIN="$(GODOT_BIN)" bash scripts/linux/export_web.sh
web-start:
	bash scripts/linux/web_preview.sh start
```

Run: `make -n web-export web-start web-status web-stop`

Expected: printed commands reference only `build/web`, `127.0.0.1:8080`, and
the preview lifecycle script.

- [ ] **Step 6: Commit**

```bash
git add export_presets.cfg Makefile scripts/linux/export_web.sh scripts/linux/web_preview.sh tests/unit/test_web_preview_lifecycle.py
git commit -m "feat: add web export preview lifecycle"
```

### Task 3: Document, package, and validate the Web preview workflow

**Files:**
- Modify: `README.md`
- Modify: `docs/linux_port_zh.md`
- Modify: `training/package_server_bundle.py`
- Modify: `.github/workflows/linux.yml`

**Interfaces:**
- The README documents only forwarding local port `8080`.
- The training bundle includes all scripts required to export and serve the Web preview.
- CI validates the Web export and a loopback HTTP preview request.

- [ ] **Step 1: Write failing package-content test**

```python
def test_server_bundle_includes_web_preview_entrypoints():
    paths = archive_paths(create_bundle())
    self.assertIn("scripts/linux/export_web.sh", paths)
    self.assertIn("scripts/linux/web_preview.sh", paths)
    self.assertIn("scripts/linux/web_preview_server.py", paths)
```

- [ ] **Step 2: Run the package test to verify it fails**

Run: `python3 -m unittest tests.unit.test_web_preview_package -v`

Expected: FAIL because the new scripts are absent from the bundle.

- [ ] **Step 3: Implement documentation, package list, and CI checks**

Document the four Make targets, the loopback-only security model, and the
requirement to forward local port `8080` using the user's authenticated
platform feature. Update CI to install Godot Web export templates, export the
`Web` preset, start the lifecycle service, verify the local response headers,
and stop the service in an `always` cleanup step.

- [ ] **Step 4: Run package and documentation verification**

Run: `python3 -m unittest tests.unit.test_web_preview_package -v && python3 training/package_server_bundle.py --output-dir /tmp/pulsearena-web-package --bundle-id pulsearena-web --stamp verify`

Expected: PASS; output tarball contains the three Web preview scripts and no
PowerShell files.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/linux_port_zh.md training/package_server_bundle.py .github/workflows/linux.yml tests/unit/test_web_preview_package.py
git commit -m "docs: document secure web preview"
```

### Task 4: Install dependencies and verify the deployed preview

**Files:**
- Modify: `docs/linux_port_zh.md`

**Interfaces:**
- `make web-export && make web-start && make web-status` provides a ready
  loopback preview at `http://127.0.0.1:8080/`.

- [ ] **Step 1: Install or provide Godot 4.7 with Web export templates**

Use the platform-approved package or official Godot Linux archive. Set
`GODOT_BIN` to its executable path and verify `"$GODOT_BIN" --version`.

- [ ] **Step 2: Build and start the preview**

Run: `make web-export && make web-start && make web-status`

Expected: Web export succeeds; status prints `http://127.0.0.1:8080/`; the
health check returns HTTP 200 with both Godot isolation headers.

- [ ] **Step 3: Verify listener exposure and stop lifecycle**

Run: `ss -ltnp | grep ':8080' && make web-stop`

Expected: listener is `127.0.0.1:8080`, never `0.0.0.0:8080`; stop removes
the PID record and returns success.

- [ ] **Step 4: Commit**

```bash
git add docs/linux_port_zh.md
git commit -m "docs: verify web preview deployment"
```

## Plan Self-Review

- Scope coverage: Tasks 1-4 cover loopback security, Web export, process lifecycle, Make commands, server packaging, CI, installation, and live verification.
- No placeholders: every task lists concrete files, commands, expected results, and interfaces.
- Type consistency: Task 1 defines the server APIs used by Task 2; Tasks 2-4 consistently use `build/web/`, port `8080`, and `web_preview_server.py`.

## Execution Handoff

Use inline execution in this session. The workspace does not expose a usable
Git repository, so commit steps cannot run; each task will instead be
verified directly with its stated command before the next task starts.
