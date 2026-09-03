# renovate-config
Renovate configuration presets for Power organization

## default
Base configuration that inherits multiple different configurations.

Usage: `"extends": ["github>powerhome/renovate-config"]`

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
