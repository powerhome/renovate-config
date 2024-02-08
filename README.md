# renovate-config
Renovate configuration presets for Power organization

## default
Base configuration that inherits multiple different configurations.

Usage: `"extends": ["github>powerhome/renovate-config"]`

## ci-kubed-versioning
Allows Renovate the ability to bump ci-kubed versions in Jenkinsfiles.

Usage: `"extends": ["github>powerhome/renovate-config:ci-kubed-versioning"]`

## use-internal-registry
Allows Renovate usage of Power's npm-registry.

Usage: `"extends": ["github>powerhome/renovate-config:use-internal-registry"]`

## krane-templates-image-versions
Allows Renovate to manage versions of Docker images references in .yaml.erb template files used by Krane.

Usage: `"extends": ["github>powerhome/renovate-config:krane-templates-image-versions"]`
