# GitHub Actions

## Workflows

| Workflow | Trigger | Permissions | Secrets |
|---|---|---|---|
| `ci.yml` | push to `main`, pull requests (including forks) | `contents: read` | none |
| `deploy.yml` | **manual only** ("Run workflow"), on `main` | `contents: read` | `production` environment |

`deploy.yml` inputs:

- **target**: `all`, `shared`, `gitea` or `openhands`. `all` deploys shared first, then every component enabled on the server (`ENABLE_GITEA`, `ENABLE_OPENHANDS`).
- **action**: `deploy`, `health`, `backup`, `rollback` or `status`.
- **restore_data** (rollback only): also restore the pre-deployment backup taken before the current release. Changes made since then are lost.

## What GitHub stores

Only three **environment secrets** in `production`:

| Secret | Content |
|---|---|
| `DEPLOY_HOST` | server address |
| `DEPLOY_SSH_KEY` | private deployment key (`~/.ssh/1s_deploy_ed25519`) |
| `DEPLOY_KNOWN_HOSTS` | `1s-server <type> <key>`: the server host key, pinned |

Optional: a repository variable `DEPLOY_SSH_PORT` if your SSH port is not 22.
`scripts/macos/generate-deploy-key.sh` copies the three values to your
clipboard.

All server settings and application secrets stay on the server
(`scripts/macos/push-config.sh`). A deployment sends **only code**: a
`git archive` of the commit being deployed.

## Protection against untrusted code

- No workflow uses `pull_request_target` or `workflow_run`. Code from a pull
  request never runs with secrets.
- `deploy.yml` can only be started by people with write access and runs only
  for `main`. Its secrets are environment secrets, so only this job can read them.
- In *Settings → Environments → production*, set:
  - **Deployment branches**: `main` only.
  - Optionally, **Required reviewers**.
- Recommended:
  - Protect `main`: reviews, no force pushes.
  - Require approval for fork pull request workflows (*Settings → Actions → General*).
- `actions/checkout` is the only third-party action. Pin it to a commit SHA if your policy requires it.
- A leaked deploy key is useless while access is disabled. While access is
  enabled, the key can only run the gateway's fixed commands.

## Logs

The gateway prints progress to the workflow log and appends it to
`/var/log/1s/gateway.log` on the server. It never prints secrets.
