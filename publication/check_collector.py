"""Bounded protocol fixtures; run with python3 -m unittest publication/check_collector.py."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "collector", Path(__file__).parents[1] / "bin/collect_publication_dates.py"
)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
DIGEST = "sha256:" + "a" * 64
DATE = "2025-01-01T00:00:00Z"


class CollectorTest(unittest.TestCase):
    def test_github_paginates_and_uses_package_creation(self):
        calls = []

        def get(url):
            calls.append(url)
            if "page=1&" in url:
                return [
                    {"id": i, "name": DIGEST, "created_at": DATE,
                     "metadata": {"container": {"tags": [f"v{i}"]}}}
                    for i in range(100)
                ]
            return [{"id": 100, "name": DIGEST, "created_at": DATE,
                     "metadata": {"container": {"tags": ["v100"]}}}]

        result = collector.collect("ghcr.io/owner/nested/image", "orgs", get)
        self.assertEqual(len(result), 101)
        self.assertEqual(len(calls), 2)
        self.assertIn("nested%2Fimage", calls[0])
        self.assertEqual(result[0]["releaseTimestamp"], DATE)
        self.assertEqual(result[0]["digest"], DIGEST)

    def test_quay_paginates_and_uses_tag_start_not_image_creation(self):
        def get(url):
            page = int(url.rsplit("=", 1)[1])
            return {"page": page, "has_additional": page == 1, "tags": [
                {"name": f"v{page}", "manifest_digest": DIGEST, "start_ts": 1735689600}
            ]}

        result = collector.collect("quay.io/owner/image", None, get)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["releaseTimestamp"], DATE)

    def test_gcr_uses_upload_time_and_keeps_alias(self):
        response = {"name": "distroless/static", "tags": ["nonroot"], "manifest": {
            DIGEST: {"tag": ["nonroot"], "timeUploadedMs": "1735689600000",
                     "timeCreatedMs": "0"}
        }}
        result = collector.collect("gcr.io/distroless/static", None, lambda _: response)
        self.assertEqual(result, [{"version": "nonroot", "digest": DIGEST,
                                  "releaseTimestamp": DATE}])

    def test_duplicate_active_tags_fail_closed(self):
        releases = {}
        collector.add_release(releases, "v1", DIGEST, DATE)
        with self.assertRaises(ValueError):
            collector.add_release(releases, "v1", DIGEST, DATE)

    def test_incomplete_gcr_map_fails_closed(self):
        with self.assertRaises(ValueError):
            collector.collect("gcr.io/distroless/static", None, lambda _: {
                "name": "distroless/static", "tags": ["nonroot"], "manifest": {}})

    def test_pagination_limit_is_fatal(self):
        with self.assertRaises(ValueError):
            collector.collect("quay.io/owner/image", None, lambda url: {
                "page": int(url.rsplit("=", 1)[1]), "has_additional": True, "tags": []})

    def test_future_timestamp_and_non_digest_are_rejected(self):
        with self.assertRaises(ValueError):
            collector.timestamp("2999-01-01T00:00:00Z")
        with self.assertRaises(ValueError):
            collector.add_release({}, "v1", "not-a-digest", DATE)


if __name__ == "__main__":
    unittest.main()
