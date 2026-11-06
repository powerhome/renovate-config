"""Bounded protocol fixtures; run with python3 -m unittest publication/check_collector.py."""

import importlib.util
from email.message import Message
from io import BytesIO
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.response import addinfourl

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
            if "/versions?" not in url:
                return {"version_count": 101}
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
        self.assertGreaterEqual(len(calls), 2)
        self.assertLessEqual(len(calls), collector.PAGE_WORKERS + 2)
        self.assertTrue(any("page=2&" in url for url in calls))
        self.assertIn("nested%2Fimage", calls[0])
        self.assertEqual(result[0]["releaseTimestamp"], DATE)
        self.assertEqual(result[0]["digest"], DIGEST)

    def test_github_rejects_page_deletion_that_skips_an_unseen_version(self):
        # Page one stays unchanged; a page-two deletion shifts ID 300 out of
        # page four while its page-three request still sees the older state.
        def get(url):
            if "/versions?" not in url:
                return {"version_count": 401}
            page = int(url.split("page=")[-1].split("&")[0])
            ids = range((page - 1) * 100, page * 100) if page < 4 else range(301, 401)
            if page > 4:
                ids = []
            return [{"id": i, "name": DIGEST, "created_at": DATE,
                     "metadata": {"container": {"tags": [f"v{i}"]}}} for i in ids]

        with self.assertRaisesRegex(ValueError, "changed during pagination"):
            collector.collect("ghcr.io/owner/image", "orgs", get)

    def test_github_rejects_changed_metadata_even_when_collected_count_matches(self):
        counts = iter([2, 1])

        def get(url):
            if "/versions?" not in url:
                return {"version_count": next(counts)}
            return [{"id": 1, "name": DIGEST, "created_at": DATE,
                     "metadata": {"container": {"tags": ["v1"]}}}]

        with self.assertRaisesRegex(ValueError, "changed during pagination"):
            collector.collect("ghcr.io/owner/image", "users", get)

    def test_github_count_includes_untagged_versions(self):
        def get(url):
            if "/versions?" not in url:
                return {"version_count": 2}
            return [{"id": i, "name": DIGEST, "created_at": DATE,
                     "metadata": {"container": {"tags": ["v1"] if i == 1 else []}}}
                    for i in [1, 2]]

        self.assertEqual(len(collector.collect("ghcr.io/owner/image", "users", get)), 1)

    def test_transient_network_failures_retry_and_remain_bounded(self):
        for error in [URLError("temporary DNS failure"), TimeoutError("timed out")]:
            with self.subTest(error=type(error).__name__):
                with patch.object(collector, "urlopen", side_effect=[error, BytesIO(b'{}')]) as request, \
                        patch.object(collector.time, "sleep") as sleep:
                    self.assertEqual(collector.fetch("https://quay.io/api/v1/test"), {})
                    self.assertEqual(request.call_count, 2)
                    sleep.assert_called_once_with(1)
                with patch.object(collector, "urlopen", side_effect=error) as request, \
                        patch.object(collector.time, "sleep") as sleep:
                    with self.assertRaises(type(error)):
                        collector.fetch("https://quay.io/api/v1/test")
                    self.assertEqual(request.call_count, 3)
                    self.assertEqual(sleep.call_count, 2)

    def test_rate_limit_retry_obeys_server_delay(self):
        cases = [
            (403, {"Retry-After": "7"}, 7),
            (429, {"Retry-After": "Thu, 01 Jan 1970 00:16:49 GMT"}, 9),
            (403, {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1011"}, 11),
            (403, {"Retry-After": "7", "X-RateLimit-Remaining": "0",
                   "X-RateLimit-Reset": "1011"}, 11),
            (503, {}, 1),
        ]
        for status, values, delay in cases:
            with self.subTest(status=status, headers=values):
                headers = Message()
                for key, value in values.items():
                    headers[key] = value
                error = HTTPError("https://quay.io/test", status, "failure", headers, None)
                with patch.object(collector, "urlopen", side_effect=[error, BytesIO(b'{}')]), \
                        patch.object(collector.time, "time", return_value=1000), \
                        patch.object(collector.time, "sleep") as sleep:
                    self.assertEqual(collector.fetch("https://quay.io/test"), {})
                    sleep.assert_called_once_with(delay)

    def test_permission_errors_and_excessive_delays_fail_without_retry(self):
        for status, values in [
            (403, {}), (401, {}), (429, {"Retry-After": "3600"}),
            (429, {"Retry-After": "invalid"}),
            (403, {"X-RateLimit-Remaining": "0"}),
        ]:
            with self.subTest(status=status, headers=values):
                headers = Message()
                for key, value in values.items():
                    headers[key] = value
                error = HTTPError("https://quay.io/test", status, "failure", headers, None)
                with patch.object(collector, "urlopen", side_effect=error) as request, \
                        patch.object(collector.time, "sleep") as sleep:
                    with self.assertRaises(HTTPError):
                        collector.fetch("https://quay.io/test")
                    self.assertEqual(request.call_count, 1)
                    sleep.assert_not_called()

    def test_rate_limit_retries_stop_after_three_attempts(self):
        headers = Message()
        headers["Retry-After"] = "3"
        error = HTTPError("https://quay.io/test", 403, "rate limited", headers, None)
        with patch.object(collector, "urlopen", side_effect=error) as request, \
                patch.object(collector.time, "sleep") as sleep:
            with self.assertRaises(HTTPError):
                collector.fetch("https://quay.io/test")
            self.assertEqual(request.call_count, 3)
            self.assertEqual([call.args[0] for call in sleep.call_args_list], [3, 3])

    def test_redirect_cannot_forward_github_authorization(self):
        requests = []

        def transport(handler, request):
            requests.append(request)
            if request.host == "api.github.com":
                headers = Message()
                headers["Location"] = "https://other.example/stolen"
                return handler.parent.error("https", request, BytesIO(), 302, "Found", headers)
            response = addinfourl(BytesIO(b'{}'), Message(), request.full_url, 200)
            response.msg = "OK"
            return response

        # Exercise urllib's real redirect dispatch, replacing only the wire.
        with patch.dict(collector.os.environ, {"GH_TOKEN": "test-token"}), \
                patch("urllib.request.HTTPSHandler.https_open", transport):
            with self.assertRaises(HTTPError):
                collector.fetch("https://api.github.com/orgs/owner/packages/container/image")
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].get_header("Authorization"), "Bearer test-token")

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

    def test_ecr_paginates_and_uses_digest_push_time(self):
        calls = []

        def get(url, body):
            calls.append((url, body))
            page = 2 if "nextToken" in body else 1
            return {"imageTagDetails": [{"imageTag": f"v{page}",
                    "createdAt": "2025-01-02T00:00:00Z",
                    "imageDetail": {"imageDigest": DIGEST, "imagePushedAt": DATE}}],
                    **({"nextToken": "next-page"} if page == 1 else {})}

        result = collector.collect("public.ecr.aws/aws-cli/aws-cli", None, get)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["releaseTimestamp"], DATE)
        self.assertEqual(calls[1][1]["nextToken"], "next-page")
        self.assertEqual(calls[0][1]["registryAliasName"], "aws-cli")

    def test_repeated_ecr_token_fails_closed(self):
        with self.assertRaises(ValueError):
            collector.collect("public.ecr.aws/aws-cli/aws-cli", None,
                              lambda url, body: {"imageTagDetails": [], "nextToken": "same"})

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
