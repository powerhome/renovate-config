# renovate-config
Renovate configuration presets for Power organization

## default
Base configuration that inherits multiple different configurations.

Usage: `"extends": ["github>powerhome/renovate-config"]``

## ci-kubed-versioning
Allows Renovate the ability to bump ci-kubed versions in Jenkinsfiles.

Usage: `"extends": ["github>powerhome/renovate-config:ci-kubed-versioning"]``

## use-internal-registry
Allows Renovate usage of Power's npm-registry.

Usage: `"extends": ["github>powerhome/renovate-config:use-internal-registry"]``
