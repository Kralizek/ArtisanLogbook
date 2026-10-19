"""Rerun safety for CurseForge publication when no completion marker exists."""
import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("release-addon.sh")


class CurseForgeRerunTests(unittest.TestCase):
    def check(self, attempt):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            gh = root / "gh"
            gh.write_text("#!/bin/sh\n# Simulate a release with no publication markers.\nexit 0\n")
            gh.chmod(0o755)
            output = root / "output"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}",
                       GITHUB_REPOSITORY="test/addon", GH_TOKEN="test",
                       TAG="addon-v1.0.0", VERSION="1.0.0", FLAVOR="retail",
                       GAME_VERSION="12.1.5", VERSION_TYPE="retail",
                       ASSET="bundle.zip", BUNDLE_SHA256="abc", PROJECT_ID="123",
                       GITHUB_RUN_ATTEMPT=str(attempt), GITHUB_OUTPUT=str(output))
            result = subprocess.run(["bash", str(SCRIPT), "check-curseforge"],
                                    env=env, capture_output=True, text=True)
            return result, output.read_text() if output.exists() else ""

    def test_first_attempt_allows_upload(self):
        result, output = self.check(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skip=false", output)

    def test_rerun_without_marker_fails_closed(self):
        result, output = self.check(2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("marker missing on workflow rerun", result.stderr)
        self.assertNotIn("skip=false", output)


if __name__ == "__main__":
    unittest.main()
