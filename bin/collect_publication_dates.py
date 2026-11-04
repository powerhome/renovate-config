#!/usr/bin/env python3
"""Collect exact registry digest publication times using only the standard library."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


MAX_PAGES = 1000
MAX_BODY = 32 * 1024 * 1024
DIGEST = re.compile(r"sha256:[a-f0-9]{64}\Z")


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.year < 2000:
        raise ValueError("invalid publication timestamp")
    if parsed.timestamp() > time.time() + 300:
        raise ValueError("publication timestamp is in the future")
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def epoch(value, divisor=1):
    return timestamp(datetime.fromtimestamp(int(value) / divisor, timezone.utc).isoformat())


def fetch(url, body=None):
    headers = {"Accept": "application/json", "User-Agent": "powerhome-publication-dates"}
    if url.startswith("https://api.github.com/"):
        token = os.environ.get("GH_TOKEN")
        if not token:
            raise ValueError("GH_TOKEN with read:packages access is required")
        headers.update({"Authorization": f"Bearer {token}", "X-GitHub-Api-Version": "2022-11-28"})
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    for attempt in range(3):
        try:
            with urlopen(Request(url, data=data, headers=headers), timeout=45) as response:
                body = response.read(MAX_BODY + 1)
                if len(body) > MAX_BODY:
                    raise ValueError("registry response exceeds size limit")
                return json.loads(body)
        except HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                raise
        time.sleep(2 ** attempt)
    raise RuntimeError("registry request failed")


def add_release(releases, version, digest, date):
    if not isinstance(version, str) or not version or not DIGEST.fullmatch(digest):
        raise ValueError("invalid registry tag or digest")
    value = {"version": version, "digest": digest, "releaseTimestamp": timestamp(date)}
    if version in releases:
        raise ValueError(f"duplicate active tag {version}; registry changed during pagination")
    releases[version] = value


def collect(package, owner_type, get=fetch):
    releases = {}
    host, repository = package.split("/", 1)
    if host == "ghcr.io":
        owner, name = repository.split("/", 1)
        if owner_type not in ("orgs", "users"):
            raise ValueError("GitHub owner type must be declared")
        endpoint = f"https://api.github.com/{owner_type}/{owner}/packages/container/{quote(name, safe='')}/versions"
        seen = set()
        for page in range(1, MAX_PAGES + 1):
            if page % 50 == 0:
                print(f"{package}: collecting page {page}", flush=True)
            versions = get(f"{endpoint}?per_page=100&page={page}&state=active")
            if not isinstance(versions, list):
                raise ValueError("invalid GitHub package versions response")
            for version in versions:
                if version["id"] in seen:
                    raise ValueError("GitHub versions changed during pagination")
                seen.add(version["id"])
                for tag in version["metadata"]["container"]["tags"]:
                    add_release(releases, tag, version["name"], version["created_at"])
            if len(versions) < 100:
                break
        else:
            raise ValueError("GitHub pagination limit exceeded; snapshot is incomplete")
    elif host == "quay.io":
        for page in range(1, MAX_PAGES + 1):
            result = get(f"https://quay.io/api/v1/repository/{repository}/tag/?onlyActiveTags=true&limit=100&page={page}")
            if result.get("page") != page or not isinstance(result.get("has_additional"), bool):
                raise ValueError("invalid Quay pagination response")
            for tag in result["tags"]:
                add_release(releases, tag["name"], tag["manifest_digest"], epoch(tag["start_ts"]))
            if not result["has_additional"]:
                break
        else:
            raise ValueError("Quay pagination limit exceeded; snapshot is incomplete")
    elif host == "gcr.io":
        result = get(f"https://gcr.io/v2/{repository}/tags/list")
        if result["name"] != repository:
            raise ValueError("GCR repository identity mismatch")
        for digest, manifest in result["manifest"].items():
            for tag in manifest.get("tag", []):
                add_release(releases, tag, digest, epoch(manifest["timeUploadedMs"], 1000))
        if set(releases) != set(result["tags"]):
            raise ValueError("GCR tag listing and manifest map disagree")
    elif host == "public.ecr.aws":
        alias, name = repository.split("/", 1)
        body = {"registryAliasName": alias, "repositoryName": name, "maxResults": 1000}
        seen_tokens = set()
        for _ in range(MAX_PAGES):
            result = get("https://api.us-east-1.gallery.ecr.aws/describeImageTags", body)
            for tag in result["imageTagDetails"]:
                detail = tag["imageDetail"]
                add_release(releases, tag["imageTag"], detail["imageDigest"], detail["imagePushedAt"])
            token = result.get("nextToken")
            if not token:
                break
            if not isinstance(token, str) or token in seen_tokens:
                raise ValueError("invalid or repeated ECR pagination token")
            seen_tokens.add(token)
            body = {**body, "nextToken": token}
        else:
            raise ValueError("ECR pagination limit exceeded; snapshot is incomplete")
    else:
        raise ValueError(f"unsupported registry {host}")
    if not releases:
        raise ValueError(f"no active releases found for {package}")
    return [releases[tag] for tag in sorted(releases)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=Path("publication/catalog.json"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text())
    snapshots = {}
    for package, owner_type in catalog.items():
        print(f"Collecting {package}", flush=True)
        releases = collect(package, owner_type)
        snapshots[package] = {
            "schemaVersion": 1,
            "packageName": package,
            "collectedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "releases": releases,
        }
    # Do not write a partial snapshot if any registry failed or exceeded a bound.
    for package, snapshot in snapshots.items():
        destination = args.output / "data" / f"{package}.json"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(snapshot, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
