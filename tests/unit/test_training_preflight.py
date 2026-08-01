from __future__ import annotations

import argparse
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "training/server_agent/preflight.py"


def load_module():
    spec = importlib.util.spec_from_file_location("training_preflight", PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TrainingPreflightTests(unittest.TestCase):
    def test_require_cuda_lists_driver_and_torch_failures(self):
        module = load_module()
        answers = {("godot", "--version"): {"ok": True}, ("nvidia-smi", "-L"): {"ok": False}}
        with patch.object(module, "run_command", side_effect=lambda command: answers[tuple(command)]), patch.object(module, "module_present", side_effect=lambda name: name != "torch"), patch.object(module, "torch_info", return_value={"installed": False, "cuda_available": False, "devices": []}):
            report, failures = module.build_report(argparse.Namespace(godot="godot", require_cuda=True))
        self.assertFalse(report["cuda_requirements"]["nvidia_smi_ok"])
        self.assertFalse(report["cuda_requirements"]["torch_cuda_available"])
        self.assertIn("NVIDIA driver is unavailable; nvidia-smi must succeed before GPU training", failures)
        self.assertIn("PyTorch CUDA is not available; do not run the A100 training pilot", failures)
