"""Exercise real packaging without rerunning the Lua suites for each archive."""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
import zipfile

import yaml

ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / ".github/workflows/scripts/resolve-flavor-matrix.py"
spec = importlib.util.spec_from_file_location("flavor_matrix", MODULE)
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


class PackageTests(unittest.TestCase):
    def package(self, flavor, suffix=None):
        env = {**os.environ, "ADDON_FLAVOR": flavor, "SKIP_TESTS": "true"}
        env.pop("ARTIFACT_SUFFIX", None)
        if suffix is not None:
            env["ARTIFACT_SUFFIX"] = suffix
        return subprocess.run(["bash", "src/addon/scripts/package.sh"], cwd=ROOT,
                              env=env, capture_output=True, text=True)

    def test_configured_flavors_produce_correct_archives_and_tocs(self):
        config = yaml.safe_load((ROOT / ".flavors.yml").read_text())
        for row in resolver.resolve_matrix(config, "local")["include"]:
            with self.subTest(flavor=row["id"]):
                run = self.package(row["id"])
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                suffix = "" if row["id"] == "retail" else f"-{row['id']}"
                addons = ["ArtisanLogbook", "ArtisanLogbook_Core", "ArtisanLogbook_Tracer"]
                for prefix in [*addons, "ArtisanLogbook-Bundle"]:
                    with zipfile.ZipFile(ROOT / f"src/addon/dist/{prefix}{suffix}.zip") as archive:
                        self.assertIsNone(archive.testzip())
                        expected = addons if prefix == "ArtisanLogbook-Bundle" else [prefix]
                        self.assertEqual({name.split("/")[0] for name in archive.namelist()}, set(expected))
                        for addon in expected:
                            toc = archive.read(f"{addon}/{addon}.toc").decode()
                            self.assertIn(f"## Interface: {row['interface']}\n", toc)
                            self.assertEqual(toc.count("## Interface:"), 1)
                            self.assertIn(f"## X-ArtisanLogbook-Flavor: {row['id']}\n", toc)
                            if addon == "ArtisanLogbook_Tracer":
                                self.assertIn("## OptionalDeps: ArtisanLogbook_Core", toc)
                                self.assertNotIn("## RequiredDeps:", toc)
                                self.assertIn("## DefaultState: disabled", toc)
                            if addon == "ArtisanLogbook_Core":
                                self.assertIn("Diagnostics/Format.lua", toc)
                                self.assertIn("Diagnostics/Window.lua", toc)
                                self.assertIn("## SavedVariables: ArtisanLogbookDB, ArtisanLogbookDebugSettings", toc)
                                self.assertNotIn("## RequiredDeps:", toc)
                                self.assertIn(f"{addon}/Diagnostics/Format.lua", archive.namelist())
                                self.assertIn(f"{addon}/Diagnostics/Window.lua", archive.namelist())

    def test_wrong_suffix_and_unconfigured_flavor_are_rejected_without_overwriting(self):
        run = self.package("retail")
        self.assertEqual(run.returncode, 0, run.stderr)
        archive = ROOT / "src/addon/dist/ArtisanLogbook_Tracer.zip"
        before = hashlib.sha256(archive.read_bytes()).hexdigest()
        run = self.package("forever", "-retail")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("Artifact suffix must be", run.stderr)
        run = self.package("not-configured")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("not configured", run.stderr)
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), before)


if __name__ == "__main__":
    unittest.main()
