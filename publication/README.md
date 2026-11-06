# Publication evidence for Renovate

These presets are opt-in. They complement `release-age(days)` and do not change its delay, schedules, security-update behavior, or first-party exemptions.

## Containers

Extend `github>powerhome/renovate-config:publication-age-containers` at a reviewed commit after the normal shared preset. Only the exact third-party package identities in `catalog.json` are mapped. Explicit alternate registries, fallback registries and mirrors keep their existing datasource. The preset does not map Powerhome images, Docker Hub images or arbitrary registries.

`publication/catalog.json` is the single maintained package inventory. After changing it, run `python3 bin/generate_publication_preset.py` and commit the updated `publication-age-containers.json` with the catalog. The script generates only the package allowlist of the rule that selects `custom.nip-publication`; it preserves the datasource, registry guards and special alias rules. Do not edit that allowlist manually. `python3 bin/generate_publication_preset.py --check` verifies synchronization, and the `Check publication catalog` workflow enforces it on pull requests. The generated preset stays committed so consumers can resolve it before a collector run.

The collector reads every page of GitHub Packages container versions and Quay active tags, the complete GCR manifest map and the ECR Public gallery. It pairs each active tag with the exact manifest digest and the registry's publication evidence:

| Registry | Publication field | Identity |
| --- | --- | --- |
| GHCR | Package version `created_at` | Package version `name`, the manifest digest |
| Quay | Active tag-history `start_ts` | `manifest_digest` |
| GCR | `timeUploadedMs` | Manifest-map digest key |
| ECR Public | `imagePushedAt` | `imageDetail.imageDigest` |

Image build timestamps and source-code release dates are not substitutes for these fields. These fields have different semantics: Quay measures the current tag assignment, while GHCR, GCR and ECR measure the publication of the referenced registry artifact. Assigning an already-published digest to a new tag does not create a new GHCR/GCR/ECR artifact publication time.

The workflow publishes complete snapshots to the `publication-data` branch every three hours. No credentials are included in snapshots. Its reader token needs package metadata access to every catalog entry. Publication uses a separate GitHub App token from a protected environment; the default workflow token has read-only contents access. A publisher's package permissions or organization policy may prevent the default workflow token from reading it; verify the first hosted run before activating consumers. If necessary, set `PUBLICATION_READ_TOKEN` as a secret in the protected `publication-data` environment to a narrowly scoped package reader credential. The collector uses it as `GH_TOKEN`, falling back to `github.token`; Git pushes use the separate publisher App token.

Packages are collected sequentially, with GitHub pages fetched in fixed batches of four HTTP threads. Collection has a 30-minute job limit, 45-second HTTP timeouts, three attempts for transient network failures, timeouts, HTTP 429/5xx responses and rate-limited HTTP 403 responses, a 32 MiB response limit and at most 1,000 pages per registry package. Redirects are refused, so authorization headers cannot cross hosts. Server `Retry-After` and rate-limit reset delays are honored up to 60 seconds; longer cooldowns fail the run. GHCR compares the package version count before and after pagination with every collected ID, including untagged versions. A changed count, duplicate ID or count mismatch fails the run. Equal-count additions and deletions can still escape detection; the API does not provide a transactional snapshot. Pagination errors, duplicate active tags, unknown digests, invalid dates and incomplete GCR maps fail the run. Nothing is published until every package succeeds; a failed package therefore prevents refresh of the entire feed. Repeated failures can let every package snapshot exceed the six-hour freshness limit. The workflow retains branch history and never force-pushes.

Renovate reads public raw JSON and checks the schema, exact package identity and a six-hour freshness limit at fetch time (subject to Renovate datasource caching) before accepting the release list. Missing files, stale data or invalid evidence fail closed. Each release carries its digest, so both version upgrades and same-tag digest changes retain digest pinning. Tags equivalent under Docker versioning (including a leading `v` or leading numeric zeroes) share the newest publication timestamp in that group. Missing evidence for any equivalent tag removes the group's timestamps, holding its updates. This conservative rule prevents one digest from borrowing an older timestamp through an equivalent tag. Floating tags that Docker versioning does not accept, such as `latest`, retain the native Docker datasource and its existing age behavior. The `nonroot` aliases of the two cataloged distroless images use a narrow versioning rule so Renovate actually resolves and ages their digest updates; the original alias stays in the file.

Only pins to the tag's top-level manifest or multi-architecture index are supported by this opt-in preset. A pin to an architecture-specific child manifest would be replaced with the top-level digest, because the feed does not enumerate child manifests. Check existing pins before enabling this preset; consumers requiring child-manifest pins must keep the native Docker datasource for those packages.

The feed is a point-in-time registry observation. A publisher can move a tag after collection, and a manually updated pin can be newer than the snapshot until the next successful run. This is not a signature verification service or a guarantee that a mutable tag stays unchanged. GitHub Packages/GCR/ECR may report an old artifact's original publication time when a tag is reassigned to it. Quay reports the active tag assignment time.

### Rollout

1. Complete the data-branch access controls described below before enabling consumers. Merge the shared preset and collector PR, then run `Collect container publication dates` and verify package reads and the protected publisher credential both work.
2. Confirm each required `publication-data/data/<registry>/<repository>.json` file exists, has a fresh `collectedAt`, and includes the current tag and its exact digest.
3. Enable the preset in consumer repositories and inspect a hosted Renovate run. Confirm version updates, same-tag digest updates and pending age checks match the source registry.

### Data-branch access controls

A repository administrator must complete this setup before the first publication. The job-level `main` condition alone is insufficient: a repository writer can create a feature-branch workflow without that condition. Do not give the generic GitHub Actions App a bypass on the data branch.

1. Apply `publication/publication-data-ruleset.json` to this repository through GitHub's rulesets API. It initially denies creation, updates, deletion and force-pushes of `publication-data`, with no bypass actors.
2. Create a dedicated publisher GitHub App, installed only on this repository, with Contents: write and no workflow or administration permission. Add that App's numeric ID as the only `Integration` bypass actor (`bypass_mode: always`) in the ruleset. This identity is separate from `github-actions[bot]`; the commit author is not an authorization boundary.
3. Create the `publication-data` Actions environment. Set its deployment branch policy to selected branches and add only `main` (branch, not tag). Verify that branch restriction before adding secrets; keep `main` protected by review. GitHub can automatically create an unprotected environment when a workflow names a nonexistent one. Store the App client ID as environment variable `PUBLICATION_APP_CLIENT_ID` and its private key as environment secret `PUBLICATION_APP_PRIVATE_KEY`. Do not store the private key as a repository or organization secret accessible outside that environment.
4. Confirm a feature-branch workflow cannot access that environment or push to `publication-data`, while the reviewed `main` workflow can publish using the App. The workflow must fail if the App is unconfigured; it has no write-token fallback.

The ruleset and environment are GitHub settings, not activated by committing these files. Repository write access cannot install them. Until an administrator applies and verifies them, keep this rollout incomplete and consumers disabled.

Consumer PRs may be prepared before step 1, but enabling them before the feed exists intentionally stops these lookups. The collector does not cover private Harbor, `registry.k8s.io` or `docker.elastic.co`. Those need authenticated or registry-specific publication evidence before being added; this preset makes no enforcement claim for them.

ECR Public uses the anonymous `describeImageTags` endpoint consumed by AWS's own gallery. This backend contract is not a documented public API; schema changes fail collection rather than falling back to another clock.

## GitHub Actions

Extend `github>powerhome/renovate-config:publication-age-actions` at a reviewed commit after the normal shared preset. Third-party Actions already using a full semantic version use native `github-releases`, keeping Renovate's tag-to-commit resolver and the exact SHA pin. This obtains the GitHub Release publication date and requires a usable timestamp. Powerhome Actions, branch references and floating major/minor aliases retain their existing datasource and behavior.

An Action without a matching GitHub Release may stop updating under this preset, including when its current version has no Release even if later versions do. Review and manually migrate that pin if appropriate. Floating aliases remain outside this stronger evidence path. Moving the commit behind an old published Release can still result in a digest update aged against that Release's original date; this preset does not establish the first time a commit or moved tag was observed.

## Verification

The fixtures exercise the installed Renovate implementation instead of duplicating its update logic. No dependency installation is required; `RENOVATE_ROOT` must point to an already-installed, pinned Renovate package directory. CI runs the Python and native Renovate fixtures and validates both presets using the official Renovate 44.198.0 image pinned by digest. The initial validation used 44.198.0, with relevant 44.204.0 source behavior checked separately.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest publication/check_collector.py
RENOVATE_ROOT=/path/to/node_modules/renovate timeout 60 node publication/check_containers.mjs
RENOVATE_ROOT=/path/to/node_modules/renovate timeout 60 node publication/check_actions.mjs
renovate-config-validator publication-age-containers.json publication-age-actions.json
```

The collector fixtures cover pagination consistency, nested package names, exact publication fields, duplicate tags, invalid dates, truncated responses, bounded retries, rate-limit delays and redirect refusal. The Renovate fixtures cover real Dockerfile/Actions extraction, version and digest updates, a young release, missing timestamps, stale or mismatched snapshots, the distroless alias, first-party exclusions and configured mirrors. Live API checks require `GH_TOKEN` but do not replace the hosted workflow acceptance check.
