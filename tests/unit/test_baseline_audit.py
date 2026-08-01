from __future__ import annotations

import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "training/baseline_audit.py"


def load_module():
    spec = importlib.util.spec_from_file_location("baseline_audit", PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BaselineAuditTests(unittest.TestCase):
    def test_makefile_exposes_baseline_audit_target(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("train-baseline-audit:", makefile)
        self.assertIn("$(PYTHON) training/baseline_audit.py", makefile)

    def test_live_project_contract_passes(self):
        report = load_module().build_report(ROOT)
        self.assertEqual(report["result"], "pass")
        self.assertEqual(report["checks"]["python_feature_dim"], 142)
        self.assertEqual(report["checks"]["godot_protocol"], 2)

    def test_manifest_dimension_mismatch_fails(self):
        module = load_module()
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in ("training/models", "training/configs/training_plans", "training/rl", "scripts/agents/hybrid"):
                (root / relative).mkdir(parents=True, exist_ok=True)
            (root / "training/models/model_catalog.json").write_text(json.dumps({"default_model_id": "hybrid_tactical_v1", "models": [{"model_id": "hybrid_tactical_v1", "manifest": "training/models/hybrid_tactical_v1_agent.json", "protocol": 2}]}), encoding="utf-8")
            (root / "training/models/hybrid_tactical_v1_agent.json").write_text(json.dumps({"model_id": "hybrid_tactical_v1", "kind": "hybrid_tactical_prior", "input_dim": 141, "protocol": 2}), encoding="utf-8")
            (root / "training/configs/training_plans/hybrid_tactical_local.json").write_text(json.dumps({"tactical_behavior_clone": {"enabled": True}}), encoding="utf-8")
            (root / "training/rl/encoding.py").write_text("HYBRID_PROTOCOL_VERSION = 2\\nTACTICAL_FEATURE_SCHEMA_VERSION = 2\\nTACTICAL_FEATURE_DIM = 142\\n", encoding="utf-8")
            (root / "scripts/agents/hybrid/tactical_decision.gd").write_text("const PROTOCOL_VERSION: int = 2\\n", encoding="utf-8")
            (root / "scripts/agents/hybrid/tactical_feature_builder.gd").write_text("const FEATURE_DIM: int = 142\\n", encoding="utf-8")
            report = module.build_report(root)
        self.assertEqual(report["result"], "fail")
        self.assertIn("manifest input_dim 141 does not equal Python feature dimension 142", report["failures"])

    def test_cli_output_creates_parent_directory(self):
        module = load_module()
        with TemporaryDirectory() as temporary:
            output = Path(temporary) / "evidence" / "audit.json"
            with patch.object(sys, "argv", ["baseline_audit.py", "--root", str(ROOT), "--output", str(output)]), patch("sys.stdout", new_callable=io.StringIO):
                status = module.main()
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["result"], "pass")
