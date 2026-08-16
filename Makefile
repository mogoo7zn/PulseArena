PYTHON ?= python3
GODOT_BIN ?=

.PHONY: help setup check test headless export-linux web-export web-start web-status web-stop train-baseline-audit train-preflight train-validate package-server

help:
	@printf '%s\n' 'Targets: setup check test headless export-linux web-export web-start web-status web-stop train-baseline-audit train-preflight train-validate package-server'

setup:
	bash scripts/ops/bootstrap.sh --with-training

check:
	$(PYTHON) tests/smoke/static_project_check.py

headless:
	GODOT_BIN="$(GODOT_BIN)" bash tests/smoke/run_headless_smoke.sh

test: headless

export-linux:
	GODOT_BIN="$(GODOT_BIN)" bash scripts/ops/export_linux.sh

web-export:
	GODOT_BIN="$(GODOT_BIN)" bash scripts/ops/export_web.sh

web-start:
	bash scripts/ops/web_preview.sh start

web-status:
	bash scripts/ops/web_preview.sh status

web-stop:
	bash scripts/ops/web_preview.sh stop

train-baseline-audit:
	$(PYTHON) training.evaluation.baseline_audit

train-preflight:
	GODOT_BIN="$(GODOT_BIN)" $(PYTHON) training.server.preflight

train-validate:
	$(PYTHON) training.pipelines.train_pipeline --profile local_constrained --phase validate

package-server:
	$(PYTHON) training.server.package_server_bundle
