PYTHON ?= python3
GODOT_BIN ?=

.PHONY: help setup check test headless export-linux web-export web-start web-status web-stop train-baseline-audit train-preflight train-validate package-server

help:
	@printf '%s\n' 'Targets: setup check test headless export-linux web-export web-start web-status web-stop train-baseline-audit train-preflight train-validate package-server'

setup:
	bash scripts/linux/bootstrap.sh --with-training

check:
	$(PYTHON) tests/smoke/static_project_check.py

headless:
	GODOT_BIN="$(GODOT_BIN)" bash tests/smoke/run_headless_smoke.sh

test: headless

export-linux:
	GODOT_BIN="$(GODOT_BIN)" bash scripts/linux/export_linux.sh

web-export:
	GODOT_BIN="$(GODOT_BIN)" bash scripts/linux/export_web.sh

web-start:
	bash scripts/linux/web_preview.sh start

web-status:
	bash scripts/linux/web_preview.sh status

web-stop:
	bash scripts/linux/web_preview.sh stop

train-baseline-audit:
	$(PYTHON) training/baseline_audit.py

train-preflight:
	GODOT_BIN="$(GODOT_BIN)" $(PYTHON) training/server_agent/preflight.py

train-validate:
	$(PYTHON) training/train_pipeline.py --profile local_constrained --phase validate

package-server:
	$(PYTHON) training/package_server_bundle.py
