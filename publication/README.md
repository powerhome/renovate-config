# Publication evidence for Renovate

These presets are opt-in. They complement `release-age(days)` and do not change its delay, schedules, security-update behavior, or first-party exemptions.

## Containers

Extend `github>powerhome/renovate-config:publication-age-containers` at a reviewed commit after the normal shared preset. Only the exact third-party package identities in `catalog.json` are mapped. Explicit alternate registries, fallback registries and mirrors keep their existing datasource. The preset does not map Powerhome images, Docker Hub images or arbitrary registries.

The collector reads every page of GitHub Packages container versions and Quay active tags, and the complete GCR manifest map. It pairs each active tag with the exact manifest digest and the registry's publication evidence:

| Registry | Publication field | Identity |
| --- | --- | --- |
| GHCR | Package version `created_at` | Package version `name`, the manifest digest |
| Quay | Active tag-history `start_ts` | `manifest_digest` |
| GCR | `timeUploadedMs` | Manifest-map digest key |

Image build timestamps and source-code release dates are not substitutes for these fields. The three fields have different semantics: Quay measures the current tag assignment, while GHCR and GCR measure the publication of the referenced registry artifact. Assigning an already-published digest to a new tag does not create a new GHCR/GCR artifact publication time.

The workflow publishes complete snapshots to the `publication-data` branch every three hours. No credentials are included in snapshots. Its token needs package metadata read access to every catalog entry and permission to push the data branch. A publisher's package permissions or organization policy may prevent the default workflow token from reading it; verify the first hosted run before activating consumers. If necessary, provide a narrowly scoped reader credential through the workflow's `GH_TOKEN` environment, keeping Git pushes on the workflow token.

Collection is sequential, with a 30-minute job limit, 45-second HTTP timeouts, three attempts for transient HTTP failures, a 32 MiB response limit and at most 200 pages per registry package. Pagination errors, duplicate active tags, unknown digests, invalid dates and incomplete GCR maps fail the run. Nothing is published until every package succeeds; a failed package therefore prevents refresh of the entire feed. The workflow retains branch history and never force-pushes.

Renovate reads public raw JSON and checks the schema, exact package identity and a six-hour freshness limit before accepting the release list. Missing files, stale data or invalid evidence fail closed. Each release carries its digest, so both version upgrades and same-tag digest changes retain digest pinning and use the publication timestamp. The `nonroot` aliases of the two cataloged distroless images use a narrow versioning rule so Renovate actually resolves and ages their digest updates; the original alias stays in the file.

The feed is a point-in-time registry observation. A publisher can move a tag after collection, and a manually updated pin can be newer than the snapshot until the next successful run. This is not a signature verification service or a guarantee that a mutable tag stays unchanged. GitHub Packages/GCR may report an old artifact's original publication time when a tag is reassigned to it. Quay reports the active tag assignment time.

### Rollout

1. Merge the shared preset and collector PR, then run `Collect container publication dates` and verify it succeeds with the workflow's own token.
2. Confirm each required `publication-data/data/<registry>/<repository>.json` file exists, has a fresh `collectedAt`, and includes the current tag and its exact digest.
3. Enable the preset in consumer repositories and inspect a hosted Renovate run. Confirm version updates, same-tag digest updates and pending age checks match the source registry.

Consumer PRs may be prepared before step 1, but enabling them before the feed exists intentionally stops these lookups. The collector does not cover ECR Public, private Harbor, `registry.k8s.io` or `docker.elastic.co`. Those need authenticated or registry-specific publication evidence before being added; this preset makes no enforcement claim for them.

## GitHub Actions

Extend `github>powerhome/renovate-config:publication-age-actions` at a reviewed commit after the normal shared preset. Third-party Actions already using a full semantic version use native `github-releases`, keeping Renovate's tag-to-commit resolver and the exact SHA pin. This obtains the GitHub Release publication date and requires a usable timestamp. Powerhome Actions, branch references and floating major/minor aliases retain their existing datasource and behavior.

An Action without a matching GitHub Release may stop updating under this preset, including when its current version has no Release even if later versions do. Review and manually migrate that pin if appropriate. Floating aliases remain outside this stronger evidence path. Moving the commit behind an old published Release can still result in a digest update aged against that Release's original date; this preset does not establish the first time a commit or moved tag was observed.

## Verification

The fixtures exercise the installed Renovate implementation instead of duplicating its update logic. No dependency installation is required; `RENOVATE_ROOT` must point to an already-installed, pinned Renovate package directory. The initial validation used 44.198.0, with relevant 44.204.0 source behavior checked separately.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest publication/check_collector.py
RENOVATE_ROOT=/path/to/node_modules/renovate timeout 60 node publication/check_containers.mjs
RENOVATE_ROOT=/path/to/node_modules/renovate timeout 60 node publication/check_actions.mjs
renovate-config-validator publication-age-containers.json publication-age-actions.json
```

The collector fixtures cover pagination, nested package names, exact publication fields, duplicate tags, invalid dates and truncated responses. The Renovate fixtures cover real Dockerfile/Actions extraction, version and digest updates, a young release, missing timestamps, stale or mismatched snapshots, the distroless alias, first-party exclusions and configured mirrors. Live API checks require `GH_TOKEN` but do not replace the hosted workflow acceptance check.
