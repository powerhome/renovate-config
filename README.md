# renovate-config
Renovate configuration presets for Power organization

## default
Base configuration that inherits multiple different configurations, including `release-age(3)`.

Supported third-party version and digest updates wait three days when a release timestamp is available. Updates without a timestamp proceed without that delay, so OS packages, Git sources and container registries without dates are not frozen. Renovate retains its default strict filtering for dated releases that are still too young. GitHub tag/digest dates can reflect publisher-controlled commit or tag dates, so backdating or retagging can defeat that observation window; this is not a server-verified publication-age guarantee.

Usage: `"extends": ["github>powerhome/renovate-config"]`

## release-age(days)
Shared cooldown policy and Powerhome exemptions. `default` uses three days; `pac` applies the same policy with seven days. The exemption list is maintained here once, after the cooldown rules, so changing it affects both consumers. To choose another delay while preserving the exemptions, extend `release-age(14)` after the default. A top-level `minimumReleaseAge` value alone does not override this preset's package rule; explicit repository-specific overrides must use later `packageRules`.

`digest` and `pinDigest` updates keep the delay when their datasource supplies a usable timestamp. `lockFileMaintenance`, `pin`, `replacement`, `bump`, `lockfileUpdate` and `rollback` are explicitly exempt because Renovate cannot enforce release age for them. Security updates retain Renovate's upstream behavior. This policy does not guarantee an age for transitive changes made by a package manager.

Usage: `"extends": ["github>powerhome/renovate-config:release-age(3)"]`

## powerhome-release-age-source
Exempts actual Powerhome repository identities on the `github-tags`, `github-releases` and `github-digest` datasources. These GitHub-native datasources construct the source URL from the repository and lookup endpoint, so the rule verifies that result belongs to github.com. This does not trust repository URLs supplied in npm, RubyGems or image metadata.

Usage within `packageRules`: `"extends": ["github>powerhome/renovate-config:powerhome-release-age-source"]`

## powerhome-release-age-git
Exempts Git dependencies whose configured remote is a Powerhome GitHub repository.

Usage within `packageRules`: `"extends": ["github>powerhome/renovate-config:powerhome-release-age-git"]`

## powerhome-release-age-npm
Exempts the Powerhome npm scope and known package identities only when Renovate exposes one approved lookup registry: npmjs.org or Power's npm registry. It does not rewrite registry URLs or `.npmrc` scope mappings. An unknown, implicit or mixed registry configuration keeps the normal cooldown.

Usage within `packageRules`: `"extends": ["github>powerhome/renovate-config:powerhome-release-age-npm"]`

## powerhome-release-age-rubygems
Exempts known Powerhome gem identities only when the existing lookup registry is RubyGems.org. Gemfile sources are preserved; custom or ambiguous sources keep the normal cooldown.

Usage within `packageRules`: `"extends": ["github>powerhome/renovate-config:powerhome-release-age-rubygems"]`

## powerhome-release-age-docker-hub
Exempts the Powerhome Docker Hub namespace when the existing lookup registry is explicitly Docker Hub. It does not redirect a configured mirror.

Usage within `packageRules`: `"extends": ["github>powerhome/renovate-config:powerhome-release-age-docker-hub"]`

## powerhome-release-age-docker-hub-default
Exempts unqualified `powerhome/<image>` and `docker.io/powerhome/<image>` image references when `registryUrls`, `defaultRegistryUrls` and `additionalRegistryUrls` are all empty or absent. Renovate then uses Docker Hub directly. Any configured alternate route keeps the normal cooldown; this rule never redirects lookups.

Usage within `packageRules`: `"extends": ["github>powerhome/renovate-config:powerhome-release-age-docker-hub-default"]`

## powerhome-release-age-packages
Exempts fully qualified Powerhome container identities on GHCR and the listed internal image namespaces. Image labels and third-party mirrors do not establish identity.

Usage within `packageRules`: `"extends": ["github>powerhome/renovate-config:powerhome-release-age-packages"]`

New unscoped package identities require a reviewed allowlist change. These exemptions rely on registry and repository access controls, not signatures, and do not detect compromise of an already-authorized publisher.

## temporary-fixes
A collection of temporary fixes, like restrictions on package versions, where these are known to be broken and affect multiple apps.

Usage: `"extends": ["github>powerhome/renovate-config:temporary-fixes"]`

## ci-kubed-versioning
Allows Renovate the ability to bump ci-kubed versions in Jenkinsfiles.

Usage: `"extends": ["github>powerhome/renovate-config:ci-kubed-versioning"]`

## ci-kubed-read-token
Adds a repo-scoped hostRule so the github-releases lookup for powerhome/ci-kubed uses a narrowly-scoped read token instead of the repo's default Renovate job token.

This is only needed by **public** repos. Mend issues public repos' Renovate jobs a GitHub App token scoped to that one repo only (a security measure so a leaked token can't reach private org repos), so the github-releases datasource can't resolve the private ci-kubed repo without this override. Private repos get a broader-scoped token already and don't need it.

Usage: `"extends": ["github>powerhome/renovate-config:ci-kubed-read-token"]`

## deployer-image-versioning
Allows Renovate the ability to bump pac-deployer image versions in deployer bash scripts.
Legacy `main-<sha>-<build>` and `master-<sha>-<build>` tags are migrated to
the latest GitHub release, then future `vX.Y.Z` tags are updated from GitHub
releases.

Usage: `"extends": ["github>powerhome/renovate-config:deployer-image-versioning"]`

## use-internal-registry
Allows Renovate usage of Power's npm-registry.

Usage: `"extends": ["github>powerhome/renovate-config:use-internal-registry"]`

## krane-templates-image-versions
Allows Renovate to manage versions of Docker images references in .yaml.erb template files used by Krane.

The templates must be stored in `config/deploy/` or `deploy/` directories to be detected.

Usage: `"extends": ["github>powerhome/renovate-config:krane-templates-image-versions"]`

## dockerfile-dep-versions
Allows Renovate to update specifically labeled dependency specifications in Dockerfiles.

Usage: `"extends": ["github>powerhome/renovate-config:dockerfile-dep-versions"]`

Dockerfile syntax example:

```Dockerfile
FROM ruby:3.3.0-slim-bullseye AS base

# renovate: datasource=rubygems depName=bundler
ARG BUNDLER_VERSION=2.5.4
# renovate: datasource=github-releases depName=rubygems lookupName=rubygems/rubygems versioning=ruby extractVersion=^v(?<version>.*)$
ARG RUBYGEMS_VERSION=3.5.4
RUN gem install bundler -v $BUNDLER_VERSION && \
    gem update --system $RUBYGEMS_VERSION

# renovate: datasource=github-releases depName=nvm lookupName=nvm-sh/nvm extractVersion=^v(?<version>.*)$
ENV NVM_VERSION 0.39.1
# renovate: datasource=node-version depName=node versioning=node
ENV NODE_VERSION 20.9.0
# renovate: datasource=npm depName=npm
ENV NPM_VERSION 7.24.2
# renovate: datasource=npm depName=yarn
ENV YARN_VERSION 1.22.17
ENV NVM_DIR /home/app/.nvm
ENV PATH $NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH
RUN mkdir $NVM_DIR \
    && curl -o- https://raw.githubusercontent.com/creationix/nvm/v${NVM_VERSION}/install.sh | bash \
    && . $NVM_DIR/nvm.sh \
    && nvm install v${NODE_VERSION} \
    && nvm alias default v${NODE_VERSION} \
    && nvm use default \
    && npm install -g npm@${NPM_VERSION} \
    && npm install -g yarn@${YARN_VERSION} \
    && curl -sSL https://nodejs.org/download/release/v${NODE_VERSION}/node-v${NODE_VERSION}-headers.tar.gz -o /tmp/node-headers.tgz \
    && npm config set tarball /tmp/node-headers.tgz
```

## os-package-versions
Allows Renovate to update specifically labeled Ubuntu and Debian package versions in Dockerfiles.

Usage: `"extends": ["github>powerhome/renovate-config:os-package-versions"]`

Supported datasource aliases:

- `ubuntu-2404`
- `ubuntu-2604`
- `debian-12`
- `debian-13`
- `debian-14`

Dockerfile syntax example:

```Dockerfile
FROM ubuntu:24.04

# renovate: datasource=ubuntu-2404 depName=curl
ARG CURL_VERSION=8.5.0-2ubuntu10.6
RUN apt-get update && \
    apt-get install -y curl="${CURL_VERSION}" && \
    apt-get clean
```

## group-ruby-version
Groups Ruby version updates from a Dockerfile base image and a `.tool-versions` file into a single PR, so both stay in sync.

If a repo only has one of the two, that one is updated on its own — no extra effect on non-Ruby projects.

Usage: `"extends": ["github>powerhome/renovate-config:group-ruby-version"]`

## add-labels
Adds standard label(s) to Renovate PRs.

Adding the "dependencies" label will make the PRs created by Renovate exempt from the [stalebot](https://github.com/powerhome/software/blob/main/modules/github-repo/stale.yml.tpl) pruning process that is configured in all of the Power repositories.

Usage: `"extends": ["github>powerhome/renovate-config:add-labels"]`

## ignore-stalebot-action
Stops Renovate touching the [stalebot workflow](https://github.com/powerhome/software/blob/main/modules/github-repo/stale.yml.tpl) that terraform renders into every repo as `.github/workflows/stale.yml`.

Merging a Renovate bump of that file brings the repo out of compliance with the Software repo's state, and the nightly drift check then opens a PR reverting it.

The rule is scoped to the rendered path rather than to the `actions/stale` package. Scoping it by package name also froze the template the file is rendered from, so the pin could only ever be moved by hand, and it froze unrelated workflows of a repo's own that happened to use the same action. Neither is terraform's to protect.

Usage: `"extends": ["github>powerhome/renovate-config:ignore-stalebot-action"]`

## ignore-reviewdog-action
Stops Renovate touching the [reviewdog workflow](https://github.com/powerhome/software/blob/main/modules/github-repo/reviewdog.tpl) that terraform renders into scanned repos as `.github/workflows/reviewdog.yml`.

As with the stalebot workflow, merging a Renovate bump of that file brings the repo out of compliance with the Software repo's state.

The rule is scoped to the rendered path for the same reason, and covers every dependency in that file rather than naming the reviewdog actions specifically.

Usage: `"extends": ["github>powerhome/renovate-config:ignore-reviewdog-action"]`

## throttle-claude-code-action
Batches `anthropics/claude-code-action` updates into a single PR that Renovate only opens on the first of the month.

Upstream ships patch releases most days, so without this every repo using the action gets a near-daily PR for a version bump nobody reviews. Updates are not ignored — they just arrive monthly instead of continuously. Major updates still get their own PR, and any repo that wants a bump sooner can rebase the open PR or run Renovate manually.

Usage: `"extends": ["github>powerhome/renovate-config:throttle-claude-code-action"]`

## group-github-actions
Groups all GitHub Actions updates in a repo into a single PR.

`anthropics/claude-code-action` is excluded, so it keeps the monthly group from `throttle-claude-code-action`. The built-in `group:githubArtifactActions` group from `config:best-practices` is absorbed into this one.

Usage: `"extends": ["github>powerhome/renovate-config:group-github-actions"]`

## group-go
Go settings that keep Go updates consistent and mergeable:

- Groups Go version updates from `go.mod`, the `actions/setup-go` workflow input and the `golang` Docker image into a single PR, so they stay in sync. It also bumps the `go` directive in `go.mod`, which Renovate otherwise leaves behind. This overrides the default `rangeStrategy` of `pin` for that one dependency.
- Runs `go mod tidy` after Renovate updates Go modules, so `go.sum` stays consistent and tidy checks in CI pass. `postUpdateOptions` is a list that a repo's own setting replaces rather than extends, so a repo that sets other post-update options must include `gomodTidy` itself.
- Puts all Go module security updates into a single PR. Fixes for related Go modules often depend on each other, so one PR per module tends to fail CI on its own. Security updates for every other datasource keep one PR per package, as before.

Renovate applies `vulnerabilityAlerts` as a forced override after all `packageRules`, so the security grouping can't be scoped with `matchDatasources`. Instead, `groupName` and `groupSlug` are templates that only differ for the `go` datasource. A template that renders empty for other datasources would put all of them on one broken branch, which is why the non-Go branch keeps a per-package value. Major security updates for other datasources get a `major-` branch prefix.

Usage: `"extends": ["github>powerhome/renovate-config:group-go"]`

## pac
Bundle for repositories that make up PAC (Power Application Cloud). It extends `default`, `group-github-actions` and `group-go`, and holds Renovate config decisions the Watchtower team made to apply across all PAC repos. See the `description` of each rule in `pac.json` for the reasoning.

Usage: `"extends": ["github>powerhome/renovate-config:pac"]`

## Percona presets

### percona-postgresql-versions
Restricts Percona PostgreSQL-related Docker and Helm chart updates to versions certified together in the blessed Percona PostgreSQL Operator release.

Usage: `"extends": ["github>powerhome/renovate-config:percona-postgresql-versions"]`

This preset:

- Groups Percona PostgreSQL dependency updates into one Renovate PR.
- Restricts `allowedVersions` to the certified image versions from Percona's release notes.
- Restricts the `pg-db` and `pg-operator` Helm charts to the blessed Percona PostgreSQL Operator version.
- Keeps PMM client updates on the current major version, so a project on PMM `2.x` is not offered PMM `3.x`.
- Keeps PostgreSQL image updates on the current PostgreSQL major version. For example, a project on PostgreSQL 14 only matches approved PostgreSQL 14 image tags.
- Keeps PostgreSQL image updates on the current image flavour, so a project on a plain `-postgres` image is not offered a PostGIS one, and vice versa. Three-segment PostGIS tags such as `2.7.0-ppg17.5.2-postgres-gis3.3.8` are the exception: they match no rule and are left alone, which is deliberate — see the comment on `POSTGRES_MINOR_SEGMENTS`.
- Migrates images off `percona/percona-postgresql-operator` tags whose component has moved to a repository of its own, in the same pull request as the matching operator and chart bump.

The `percona/percona-postgresql-operator` repository hosts several different
components, distinguished only by a tag suffix — `2.6.0` is the operator itself,
`2.6.0-ppg16.8-pgbackrest2.54.2` is pgBackRest, and so on. Rules generated from
the bare operator version are therefore scoped with `matchCurrentVersion` to
bare `x.y.z` tags. Without that scoping they also match every suffixed tag, and
Renovate offers the operator image as an upgrade for whatever the tag actually
is — silently replacing, say, pgBouncer with the operator binary.

Percona has also moved components out of that repository over time: pgBackRest
and pgBouncer in operator 2.7.0, and the plain PostgreSQL image in 2.8.0, which
now lives in `percona/percona-distribution-postgresql`. PostGIS images are still
published in the operator repository. Because Renovate keys rules on package
name, it cannot see such a move as an upgrade — the old tags simply stop being
published, and a deployment sits frozen on the last one. The preset declares
these moves and emits Renovate `replacementName` / `replacementVersion` rules for
them, so each affected project gets one migration PR pointing at the certified
image in its new home. The moves are declared explicitly in
`bin/update_percona_digests.rb` rather than inferred from a component's absence
from the certified image table, where an absence is far more likely to be a
documentation omission than a migration.

Those replacements are pulled onto the same branch as the operator and chart
bump, so they arrive as one pull request. They have to land together: a
replacement applied on its own leaves the cluster running component images from
a different operator release than the operator, and so does an operator bump
applied without them. Renovate normally gives every replacement its own branch
and ignores `groupName` when naming it, so the preset sets `branchTopic` to the
group's slug instead, which is the one branch-naming option a replacement does
honour.

PMM client rules are scoped to PostgreSQL template filenames because the PMM client image is certified with both PXC and PostgreSQL operators. A plain `percona/pmm-client` Docker image reference does not identify which operator owns it, so file scoping avoids applying PostgreSQL-certified PMM updates to PXC clusters when both Percona presets are enabled.

### percona-pxc-versions
Restricts Percona PXC-related Docker and Helm chart updates to versions certified together in the blessed Percona PXC Operator release.

Usage: `"extends": ["github>powerhome/renovate-config:percona-pxc-versions"]`

This preset:

- Groups Percona PXC dependency updates into one Renovate PR.
- Restricts `allowedVersions` to the certified image versions from Percona's release notes.
- Restricts the `pxc-db` and `pxc-operator` Helm charts to the blessed Percona PXC Operator version.
- Scopes PMM client updates to MySQL template filenames, so they can use the PXC-certified PMM version.
- Keeps PXC and XtraBackup updates on the current MySQL compatibility line. For example, a project on `8.0.x` is not offered `8.4.x`, and a project on `5.7.x` is not offered `8.0.x`.

### Updating Percona presets
The Percona presets are generated by `bin/update_percona_digests.rb`.

To update one operator preset:

```sh
./bin/update_percona_digests.rb --operator pxc --version "1.18.0"
./bin/update_percona_digests.rb --operator postgresql --version "2.8.2"
```

To update both blessed versions, update `.github/workflows/update-percona-digests.yml` and run the workflow. The workflow keeps the blessed PXC and PostgreSQL versions in one place and opens a single PR with generated Percona config changes. To change the blessed versions, update the `PXC_VERSION` and `POSTGRESQL_VERSION` environment variables in the workflow.
