import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError


spec = importlib.util.spec_from_file_location(
    "release_versions", Path(__file__).resolve().parents[1] / "scripts/release-versions.py")
versions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versions)


class ReleaseVersionsTests(unittest.TestCase):
    def test_missing_includes_old_gaps_even_when_newest_is_published(self):
        selected, latest = versions.select_versions(
            "missing", {"0.1.1", "0.1.5-alpha.1", "0.1.5-alpha.2", "0.1.5-rc.1"},
            {"0.1.5-alpha.1", "0.1.5-rc.1", "buildcache-0.1.5-alpha.2-amd64", "latest"},
            "0.1.2-alpha.2")
        self.assertEqual(selected, ["0.1.5-alpha.2"])
        self.assertEqual(latest, "0.1.5-rc.1")

    def test_semver_order_and_stable_after_prereleases(self):
        self.assertEqual(versions.releases(
            ["0.1.5", "0.1.5-rc.1", "0.1.5-alpha.10", "0.1.5-alpha.2"], "0.1.0"),
            ["0.1.5-alpha.2", "0.1.5-alpha.10", "0.1.5-rc.1", "0.1.5"])

    def test_all_ignores_non_release_tags_and_floor(self):
        selected, _ = versions.select_versions("all", {"0.1.1", "0.1.5"},
            {"latest", "nightly", "buildcache-0.1.5-amd64", "sha256-abc", "0.1.1", "0.1.5", "0.1.5-amd64"}, "0.1.2")
        self.assertEqual(selected, ["0.1.5"])

    def test_explicit_batch_is_sorted_and_deduplicated(self):
        selected, _ = versions.select_versions("0.1.5 0.1.4 0.1.5", {"0.1.4", "0.1.5"}, set(), "0.1.2")
        self.assertEqual(selected, ["0.1.4", "0.1.5"])

    def test_invalid_or_unsupported_explicit_input_is_rejected(self):
        for value in ("master", "0.1.1", "$(id)", "0.2.0"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                versions.select_versions(value, {"0.1.1", "0.1.5"}, set(), "0.1.2")

    def test_no_missing_releases(self):
        self.assertEqual(versions.select_versions("missing", {"0.1.5"}, {"0.1.5"}, "0.1.2"),
                         ([], "0.1.5"))

    def test_registry_pagination(self):
        first = io.BytesIO(json.dumps({"tags": ["0.1.4"]}).encode())
        first.headers = {"Link": '</v2/repo/tags/list?n=1&last=0.1.4>; rel="next"'}
        second = io.BytesIO(json.dumps({"tags": ["0.1.5"]}).encode())
        second.headers = {}
        with patch.object(versions, "urlopen", side_effect=[first, second]) as request:
            result = list(versions.pages("https://ghcr.io/v2/repo/tags/list?n=1"))
        self.assertEqual(result, [{"tags": ["0.1.4"]}, {"tags": ["0.1.5"]}])
        self.assertEqual(request.call_args.args[0].full_url,
                         "https://ghcr.io/v2/repo/tags/list?n=1&last=0.1.4")

    def test_pagination_does_not_forward_auth_to_another_host(self):
        response = io.BytesIO(b'{}')
        response.headers = {"Link": '<https://example.com/>; rel="next"'}
        with patch.object(versions, "urlopen", return_value=response) as request:
            with self.assertRaises(ValueError):
                list(versions.pages("https://ghcr.io/v2/repo/tags/list"))
        self.assertEqual(request.call_count, 1)

    def test_registry_error_is_not_treated_as_missing_versions(self):
        error = HTTPError("https://ghcr.io", 503, "unavailable", {}, None)
        with patch.object(versions, "urlopen", side_effect=error):
            with self.assertRaises(HTTPError):
                list(versions.pages("https://ghcr.io", missing_ok=True))

    def test_queued_publish_defers_poll(self):
        with patch.dict(versions.os.environ, {"GH_TOKEN": "test"}), \
             patch.object(versions, "pages", side_effect=[
                 [{"workflow_runs": []}], [{"workflow_runs": [{"status": "queued"}]}],
             ]):
            self.assertTrue(versions.publish_active("owner/repo"))


if __name__ == "__main__":
    unittest.main()
