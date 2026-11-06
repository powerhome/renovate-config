# Enable the publication-data publisher

Use a dedicated, private GitHub App owned by `powerhome`, installed only on `powerhome/renovate-config`. Its installation token is short-lived and its identity can be the only ruleset bypass actor. The App's private key belongs in the `publication-data` environment, restricted to the `main` branch.

Consumers must use the explicit branch URL `https://raw.githubusercontent.com/powerhome/renovate-config/refs/heads/publication-data/data/<package>.json`. A short ref such as `publication-data/data/...` can resolve through an unprotected nested tag when the branch path is missing. The branch ruleset does not protect those tags.

This separates the reviewed publisher from feature-branch workflows. A bypass for the generic GitHub Actions App would also admit their `GITHUB_TOKEN`s. A personal access token introduces a user-owned publishing identity; a deploy key is a long-lived Git credential, and a deploy-key ruleset bypass admits all deploy keys on the repository. Both are possible alternatives, but neither improves this publisher's identity and token lifecycle. [GitHub credential types](https://docs.github.com/en/organizations/managing-programmatic-access-to-your-organization/github-credential-types)

The App controls who can publish snapshots. It does not repair datasource age semantics. The separately identified Actions equivalent-Release timestamp issue must be resolved before relying on `publication-age-actions`.

## Prerequisites

- A `powerhome` organization owner or authorized App manager must register the App. Organization policy may require an owner to approve its installation.
- A repository administrator must configure the environment and ruleset. Repository write access is insufficient.
- Keep `main` protected by review, including changes to the collector, catalog and workflow. Do not add the App to a bypass list for `main`.
- Run the commands below from a checkout containing the reviewed workflow and `publication/publication-data-ruleset.json`, authenticated as the administrator. They change GitHub settings; committing these files alone does not activate them.

## 1. Register and install the App

Open [New GitHub App for powerhome](https://github.com/organizations/powerhome/settings/apps/new) and use these settings:

| Setting | Value |
| --- | --- |
| Name | `powerhome-renovate-publication`, or an available equivalent |
| Homepage URL | `https://github.com/powerhome/renovate-config` |
| User authorization / OAuth | Not needed; leave callback and setup URLs empty |
| Webhooks | Inactive; this App is used only for authentication |
| Repository permissions | **Contents: Read and write**; Metadata read is implicit |
| Other repository, organization and account permissions | No access, including Workflows and Administration |
| Where it can be installed | **Only on this account** |

Install the App on `powerhome` with **Only select repositories**, selecting only `renovate-config`. Record its **numeric App ID** and **Client ID**. Generate a private key and keep the downloaded PEM file local; do not commit or paste it into the PR. [Registration](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app), [installation](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app), [Git permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)

These identifiers are different:

| Value | Used by |
| --- | --- |
| Numeric App ID | Ruleset `Integration.actor_id` |
| Client ID, typically starting with `Iv` | Environment variable `PUBLICATION_APP_CLIENT_ID` |
| Private key PEM | Environment secret `PUBLICATION_APP_PRIVATE_KEY` |
| Installation ID | Discovered automatically; no workflow setting is needed |

## 2. Lock the data branch

First check for an existing publisher ruleset. If one exists, inspect and update it rather than creating a duplicate:

```sh
gh api repos/powerhome/renovate-config/rulesets \
  --jq '.[] | {id, name, enforcement}'
```

For the initial setup, apply the committed deny-by-default ruleset and record the returned ID:

```sh
gh api --method POST repos/powerhome/renovate-config/rulesets \
  --input publication/publication-data-ruleset.json \
  --jq '{id, name, enforcement}'
```

It applies only to `refs/heads/publication-data` and initially admits no publisher. It restricts creation, updates, deletion and force pushes. Do not modify the existing `main` rulesets. [Ruleset API](https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset)

## 3. Restrict the environment before adding credentials

In [repository environments](https://github.com/powerhome/renovate-config/settings/environments), create `publication-data`. Under **Deployment branches and tags**, select **Selected branches and tags** and add exactly:

- Ref type: **Branch**
- Name pattern: **main**

Do not allow tags, wildcard branches or all protected branches. Verify this policy before adding any secret. A workflow can automatically create a missing environment without protections; naming it in YAML is not sufficient. Required reviewers are optional, but enabling them makes each scheduled publication wait for approval. [Environment protection](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)

Read back the policy:

```sh
gh api repos/powerhome/renovate-config/environments/publication-data \
  --jq '.deployment_branch_policy'
gh api repos/powerhome/renovate-config/environments/publication-data/deployment-branch-policies \
  --jq '.branch_policies | map({name, type})'
```

Expected: `protected_branches: false`, `custom_branch_policies: true`, and exactly one policy with `name: main`, `type: branch`.

Then add the environment variable and secret, replacing the placeholders:

```sh
gh variable set PUBLICATION_APP_CLIENT_ID \
  --repo powerhome/renovate-config --env publication-data \
  --body '<App Client ID>'
gh secret set PUBLICATION_APP_PRIVATE_KEY \
  --repo powerhome/renovate-config --env publication-data \
  < /secure/path/to/publisher.private-key.pem
```

Do not create repository- or organization-level copies of the private key. The workflow already requests only `contents: write`, scopes its installation token to the current repository, uses it only in the publish step, and revokes it when the job finishes. [Pinned token action](https://github.com/actions/create-github-app-token/blob/64ab729a6294000f5aa4a4bc0b73d1f32bc45510/README.md)

The collector separately uses `GITHUB_TOKEN` with `packages: read`. If the first hosted run cannot read another organization's package metadata, use a separate classic PAT with only `read:packages`, preferably owned by a dedicated automation account, as environment secret `PUBLICATION_READ_TOKEN`. This scope is not restricted to the catalog; the token can read packages accessible to its owner. The workflow selects it automatically. Do not give the publisher App extra package permissions to work around a reader failure. [Package API authentication](https://docs.github.com/en/rest/packages/packages)

```sh
gh secret set PUBLICATION_READ_TOKEN \
  --repo powerhome/renovate-config --env publication-data
```

## 4. Allow only the dedicated App to publish

Set the two numeric IDs recorded above, then update only this ruleset:

```sh
PUBLISHER_APP_ID='<numeric App ID>'
PUBLICATION_RULESET_ID='<publisher ruleset ID>'

jq --argjson app_id "$PUBLISHER_APP_ID" \
  '.bypass_actors = [{actor_id: $app_id, actor_type: "Integration", bypass_mode: "always"}]' \
  publication/publication-data-ruleset.json |
  gh api --method PUT \
    "repos/powerhome/renovate-config/rulesets/$PUBLICATION_RULESET_ID" --input -

gh api "repos/powerhome/renovate-config/rulesets/$PUBLICATION_RULESET_ID" \
  --jq '{enforcement, conditions, bypass_actors, rules}'
```

Before enabling any consumer, confirm its preset uses the explicit `refs/heads/publication-data` raw URL rather than the short ref. Confirm enforcement is `active`, the only included ref is `refs/heads/publication-data`, and the only bypass actor is the dedicated App's numeric ID with `actor_type: Integration` and `bypass_mode: always`. Do not add the generic GitHub Actions App, repository roles, users, teams or deploy keys. `always` is needed for direct publication; `pull_request` does not authorize the workflow's direct push.

## 5. Validate before enabling consumers

After the reviewed workflow is on `main`, dispatch it explicitly from `main`:

```sh
gh workflow run collect-publication-dates.yml \
  --repo powerhome/renovate-config --ref main
gh run list --repo powerhome/renovate-config \
  --workflow collect-publication-dates.yml --limit 5
```

Record the run ID and inspect it with `gh run view <run-id> --repo powerhome/renovate-config --log-failed`. The catalog check, collection, App-token creation and push must all succeed. Confirm every catalog entry has a fresh snapshot with the correct package identity, exact tag/digest pairs and no missing package files. A passing fixture workflow is not proof that hosted credentials work.

Verify the environment's denial separately: use a temporary branch version of the existing dispatchable workflow containing only a read-only, no-op job that references `publication-data`, without the workflow's `main` guard. It must be rejected by the environment branch policy. Do not include publishing commands or print credentials in this probe. A stock feature-branch run skipped by the `main` guard does not prove environment enforcement.

Only then enable the container preset in a consumer and inspect its hosted Renovate results. Keep the Actions preset disabled until its equivalent-Release timestamp issue is resolved. Leave the PR's publication-permissions discussion open until an administrator has recorded the policy readback and successful hosted publication.
