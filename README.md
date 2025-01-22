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

## add-labels
Adds standard label(s) to Renovate PRs.

Adding the "dependencies" label will make the PRs created by Renovate exempt from the [stalebot](https://github.com/powerhome/software/blob/main/modules/github-repo/stale.yml.tpl) pruning process that is configured in all of the Power repositories.

Usage: `"extends": ["github>powerhome/renovate-config:add-labels"]`

## ignore-stalebot-action
Ignores Renovate PRs that are created by the updates to the [stalebot](https://github.com/powerhome/software/blob/main/modules/github-repo/stale.yml.tpl) action.

This ensures that Stalebot updates won't be created by Renovate, bringing repos out of compliance with the Software repo's state.

Usage: `"extends": ["github>powerhome/renovate-config:ignore-stalebot-action"]`
