# AGENTS.md

Guidance for AI coding agents working in this repository. Humans should start
with [README.md](README.md) and [docs/](docs/).

## What this is

Bash + Docker Compose infrastructure for **one Ubuntu 22.04/24.04 server**:

- **shared**: host-network Nginx (explicit IPv4/IPv6 binds, TLS via acme.sh,
  per-component IP allowlists, default deny with 403), firewall, backups.
- **gitea**: Gitea + PostgreSQL + Git-over-SSH, and a pool of Actions runners,
  each with a private rootless Docker daemon (no `--privileged`, no host socket).
- **openhands**: one isolated OpenHands instance per user (own container,
  network, volumes, API key, port).

Components are independent (own Compose projects, networks, volumes, secrets,
backups, deploy lifecycle). Either one can be disabled.

Deployment: an operator on macOS enables a temporary, restricted deploy key,
then GitHub Actions (`deploy.yml`, manual only) connects to the server, where a
forced-command **gateway** (`scripts/server/gateway.sh`) accepts only a fixed
set of commands. Settings and secrets live **on the server** (`/etc/1s`), never
in GitHub or the repo.

## Layout

| Path | Purpose |
|---|---|
| `config/schema.conf` | **Single source of truth** for every setting (name, component, kind, required, default, description) |
| `scripts/lib/` | Shared libraries: `common.sh` (logging, locks, atomic writes, `require_root`, dotenv parsing), `config.sh` (schema, validation), `nginx.sh` (rendering/apply), `firewall.sh`, `deploy.sh`, `openhands.sh` |
| `scripts/server/` | Run on the server: `bootstrap.sh`, `gateway.sh`, `1s` CLI, `config.sh`, `firewall.sh`, `deploy-access.sh` |
| `scripts/macos/` | Operator tools. Must work on **stock macOS** (Bash 3.2, only `git` and `ssh`); they drive the server over SSH |
| `scripts/deploy/` | Per-component deploy, runner pool, bundle builder, `ci-run.sh` (the Actions entry point) |
| `scripts/{access,certificates,backup,health}/` | Allowlists, acme.sh, backup/restore, health checks |
| `compose/` | Compose stacks per component plus isolation overlays |
| `config/nginx`, `config/systemd`, `config/apparmor` | Templates and units installed by the scripts |
| `tests/` | ShellCheck, unit, config validation, host checks, end-to-end |
| `.github/workflows/` | `ci.yml` (lint/tests, no secrets) and `deploy.yml` (manual, `production` environment) |

## Rules

- **Never write a real repository URL, server address, domain, IP, e-mail or
  secret into tracked files** (code, docs, tests, commit messages, agent
  notes). Use placeholders: `<owner>/<repo>`, `your-org/1s`, `example.com`, and
  documentation ranges `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`,
  `2001:db8::/32`. Real values belong only in the gitignored `.env` and on the
  server.
- Never commit `.env`, keys, backups or anything under `.local/`.
- Don't commit or push on your own. Ask the user first: some people commit
  manually, others are fine with automatic commits and pushes.
- Server scripts target **Bash >= 4.4** with `set -euo pipefail`. Scripts in
  `scripts/macos/` must stay **Bash 3.2-compatible** (stock macOS, no Homebrew).
- Treat dotenv files as data: parse them with `env_load`/`env_get` from
  `scripts/lib/common.sh`, never `source` them.
- Validate all external input (IPs, CIDRs, domains, ports, user names, SHAs)
  with the existing validators before use. The gateway must reject anything
  outside its fixed grammar.
- Privileged entry points call `require_root`. Don't weaken or bypass it,
  including for tests. Tests run as root in the toolbox container instead.
- Write files with `atomic_write`, serialise with `with_lock`, and keep
  Nginx changes transactional (render, `nginx -t`, swap, reload, roll back on
  failure).
- Container names and Compose projects use `ONES_PREFIX` (default `1s`). Tests
  use `1s-test-*`, `1s-validate-*` and `1s-e2e-*` only.

## Adding or changing a setting

1. Edit `config/schema.conf`.
2. Run `scripts/dev/generate-reference.sh` to regenerate `.env.example` and
   `docs/configuration.md`. The unit test "reference docs up to date" fails if
   you skip this.
3. Add validation and tests if the kind needs new rules.

## Testing

The tests need Linux and root, so run them in the toolbox container (see
[docs/testing.md](docs/testing.md)):

```bash
docker build -t 1s-test-toolbox:local tests/docker
docker run --rm -v "$PWD":/src:ro -w /src 1s-test-toolbox:local bash tests/shellcheck.sh
docker run --rm -v "$PWD":/src:ro -w /src 1s-test-toolbox:local bash tests/unit.sh
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD:$PWD" -w "$PWD" \
  1s-test-toolbox:local bash tests/validate-configs.sh
```

CI (`ci.yml`) runs these three steps the same way. Running `tests/unit.sh`
directly as a normal user fails: `ip-access`, `config import` and the
gateway tests need root. Add tests next to the matching section in
`tests/unit.sh`, using the helpers in `tests/lib.sh`. Docker calls are stubbed
by `tests/fixtures/bin/docker`.

## Docs

Update the relevant file in `docs/` when behaviour changes. `docs/security.md`
records the threat model and known limitations. Keep it accurate when you
touch access control, the gateway, firewall, secrets or container isolation.
