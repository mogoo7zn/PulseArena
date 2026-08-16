from __future__ import annotations

import json
import subprocess
import sys
import tarfile
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / "training" / "package_server_bundle.py"


class WebPreviewPackageTests(unittest.TestCase):
    def test_server_bundle_includes_discoverable_web_preview_entrypoints(self) -> None:
        """A deployed bundle must retain both Web scripts and their command contract."""
        with TemporaryDirectory() as temporary:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(PACKAGER),
                    "--output-dir",
                    temporary,
                    "--bundle-id",
                    "web-preview",
                    "--stamp",
                    "test",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            result = json.loads(completed.stdout)
            bundle = Path(result["bundle"])
            with tarfile.open(bundle, "r:gz") as archive:
                names = set(archive.getnames())
                manifest_file = archive.extractfile(
                    f"{result['package_root']}/BUNDLE_MANIFEST.json"
                )
                self.assertIsNotNone(manifest_file)
                manifest = json.loads(manifest_file.read().decode("utf-8"))

        for path in (
            "scripts/ops/export_web.sh",
            "scripts/ops/web_preview.sh",
            "scripts/ops/web_preview_server.py",
        ):
            self.assertIn(f"web-preview_test/{path}", names)
        self.assertEqual(
            manifest["entrypoints"]["web_preview"],
            {
                "export": "make web-export",
                "start": "make web-start",
                "status": "make web-status",
                "stop": "make web-stop",
            },
        )


if __name__ == "__main__":
    unittest.main()
