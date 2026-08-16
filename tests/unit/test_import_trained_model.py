from __future__ import annotations

import argparse
import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import training.server.import_trained_model as importer


class ImportTrainedModelTests(unittest.TestCase):
    def test_manifest_and_catalog_preserve_tactical_actor_critic_kind(self) -> None:
        with TemporaryDirectory(dir=importer.ROOT) as temporary:
            root = Path(temporary)
            checkpoint = root / "checkpoint.pt"
            checkpoint.write_bytes(b"checkpoint")
            metrics = root / "metrics.json"
            metrics.write_text(json.dumps({"fallback_rate": 0.000087}), encoding="utf-8")
            manifest_path = root / "training/models/candidate_agent.json"
            args = argparse.Namespace(
                model_id="candidate",
                label="Candidate",
                kind="tactical_actor_critic",
                checkpoint=checkpoint,
                run_id="run",
                hidden=192,
                input_dim=142,
                metrics_json=metrics,
                description="Candidate model",
                reward_profile_id="legal_window_pressure",
            )

            manifest = importer.build_manifest(args, checkpoint)
            with patch.object(importer, "DEFAULT_CATALOG", root / "training/models/model_catalog.json"):
                importer.update_catalog(manifest_path, "candidate", "Candidate", "tactical_actor_critic", False)
                catalog = json.loads((root / "training/models/model_catalog.json").read_text(encoding="utf-8"))

        self.assertEqual(manifest["kind"], "tactical_actor_critic")
        self.assertEqual(manifest["reward_profile_id"], "legal_window_pressure")
        self.assertEqual(catalog["models"][0]["kind"], "tactical_actor_critic")
        self.assertEqual(catalog["default_model_id"], "candidate")


if __name__ == "__main__":
    unittest.main()
