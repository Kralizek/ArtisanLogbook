"""Regression tests for provider-neutral release flavor matrix."""
import importlib.util
from pathlib import Path
import unittest
import yaml

MODULE = Path(__file__).with_name("resolve-flavor-matrix.py")
spec = importlib.util.spec_from_file_location("resolve_flavor_matrix", MODULE)
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


class FlavorMatrixTests(unittest.TestCase):
    def test_default_version_type_and_retail_asset(self):
        result = resolver.resolve_matrix({"flavors": [{"id": "retail", "version": "12.1.5"}]}, "0.4.0")
        self.assertEqual(result["include"], [{
            "id": "retail",
            "version": "12.1.5",
            "interface": 120105,
            "asset": "ArtisanLogbook-Bundle-0.4.0.zip",
            "curseforgeVersionType": "retail",
        }])

    def test_explicit_provider_override_and_named_artifact(self):
        result = resolver.resolve_matrix({"flavors": [
            {"id": "retail", "version": "12.1.5"},
            {"id": "forever", "version": "1.60.1",
             "metadata": {"curseforge": {"versionType": "classic"}}},
        ]}, "1.0.0")
        self.assertEqual(result["include"][1], {
            "id": "forever",
            "version": "1.60.1",
            "interface": 16001,
            "asset": "ArtisanLogbook-Bundle-forever-1.0.0.zip",
            "curseforgeVersionType": "classic",
        })

    def test_configured_retail_uses_actual_curseforge_version_type(self):
        config = yaml.safe_load(Path(".flavors.yml").read_text(encoding="utf-8"))
        result = resolver.resolve_matrix(config, "0.1.0-beta.5")
        self.assertEqual(len(result["include"]), 1)
        self.assertEqual(result["include"][0]["id"], "retail")
        self.assertEqual(result["include"][0]["version"], "12.1.5")
        self.assertEqual(result["include"][0]["curseforgeVersionType"], "517")

    def test_invalid_flavors_rejected(self):
        invalid = (
            [],
            [{"id": "retail", "version": "12.1"}],
            [{"id": "retail", "version": "12.1.5"}, {"id": "retail", "version": "12.1.6"}],
            [{"id": "retail", "version": "12.1.5", "metadata": {"curseforge": {"versionType": ""}}}],
            [{"id": "retail", "version": "12.1.5", "metadata": {"curseforge": {"versionType": " retail"}}}],
            [{"id": "retail", "version": "12.1.5", "metadata": {"curseforge": {"versionType": "retail "}}}],
            [{"id": "retail", "version": "12.1.5", "metadata": {"curseforge": {"versionType": "\tretail"}}}],
            [{"id": "retail", "version": "12.1.5", "metadata": {"curseforge": {"unknown": 1}}}],
        )
        for flavors in invalid:
            with self.subTest(flavors=flavors), self.assertRaises(ValueError):
                resolver.resolve_matrix({"flavors": flavors}, "1.0.0")


if __name__ == "__main__":
    unittest.main()
