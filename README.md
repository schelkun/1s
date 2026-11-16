# 1s — self-hosted Gitea, Gitea Actions runners and OpenHands

Production-ready, reusable infrastructure for one Ubuntu 22.04/24.04 server:

- **Shared infrastructure**: one Nginx reverse proxy that binds explicit IPv4 and IPv6 addresses. TLS certificates come from **acme.sh** (Let's Encrypt). Both web UIs **deny by default (HTTP 403)** except to allowlisted IPs.
- **Gitea**: Gitea 28 (rootless image), PostgreSQL 18 and Git-over-SSH on its own IP and port with its own allowlist.
  - A scalable pool of **Gitea Actions runners**. Each runner has a private *rootless* Docker daemon and runs without `--privileged` and without the host Docker socket.
- **OpenHands**: Agent Canvas, with **one isolated instance per user**: its own container, network, volumes, API key and port. It supports the OpenHands agent, Claude Code, Codex, Gemini CLI, OpenCode and other ACP agents.

Install Gitea only, OpenHands only, or both. Each component has its own Compose projects, networks, volumes, secrets, backups and deployment lifecycle.

Every deployment runs through **GitHub Actions** over a **temporary, restricted SSH key**. You enable and disable that key from macOS with your normal administrative SSH login. Settings and secrets stay on the server; GitHub holds only three deployment secrets.

```text
           ┌──────────────────────── Ubuntu server ─────────────────────────┐
 client ──►│ Nginx (host network, explicit IPs, TLS, allowlists, 403)       │
           │   GITEA_BIND_IP:443 ─► 127.0.0.1:13000 ─► Gitea ─► PostgreSQL  │
           │   OPENHANDS_BIND_IP:<port per user> ─► 127.0.0.1:2800N ─► user │
           │ GITEA_SSH_BIND_IP:2222 ─► Gitea SSH (firewall allowlist)       │
           │ runner-N: rootless dockerd (own net) ─► jobs                   │
           └────────────────────────────────────────────────────────────────┘
 GitHub Actions ──(deploy key, forced command, enabled on demand)──► gateway
 macOS ──(admin SSH, never touched)──► enable/disable access, allowlists
```

## Quick start (macOS: only git and ssh needed)

```bash
git clone https://github.com/<you>/1s.git && cd 1s
cp .env.example .env && open -e .env        # server login, domains, IPs
scripts/macos/bootstrap-server.sh           # prepare Ubuntu (Docker, deploy user, gateway)
scripts/macos/push-config.sh                # store settings on the server; secrets are generated there
scripts/macos/generate-deploy-key.sh        # deploy key + the 3 GitHub secrets (via clipboard)
scripts/macos/ip-access.sh add gitea me     # allow your own IP
scripts/macos/ip-access.sh add openhands me
scripts/macos/deploy.sh                     # enable access -> click "Run workflow" -> disable access
```

The full walkthrough is in **[docs/macos-setup.md](docs/macos-setup.md)**.

## Documentation

| Document | Contents |
|---|---|
| [docs/macos-setup.md](docs/macos-setup.md) | Step-by-step installation from macOS (prerequisites to first deployment) |
| [docs/architecture.md](docs/architecture.md) | Components, networking, isolation decisions and their reasons |
| [docs/configuration.md](docs/configuration.md) | Every setting (generated from `config/schema.conf`) |
| [docs/github-actions.md](docs/github-actions.md) | Workflows, Variables/Secrets, protection against forks and pull requests |
| [docs/operations.md](docs/operations.md) | Allowlists, certificates, updates, backups and restore, rollback, credential rotation |
| [docs/openhands.md](docs/openhands.md) | Users, agent backends (Claude Code, Codex, Gemini CLI, OpenCode), Gitea integration |
| [docs/security.md](docs/security.md) | Threat model, trust boundaries, hardening details, known limitations |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms and fixes, including lockout recovery and interrupted deployments |
| [docs/testing.md](docs/testing.md) | Tests and how to run them locally |

## Repository layout

```text
.github/workflows/   ci.yml (lint/tests, no secrets) and deploy.yml (manual, environment-protected)
compose/             nginx/, gitea/, gitea-runners/, openhands/ (+ isolation overlays)
config/              schema.conf (single source of truth), nginx templates, systemd units, AppArmor
scripts/
  macos/             operator tools for stock macOS (bootstrap, config upload, deploy key, access, allowlists)
  server/            bootstrap.sh, gateway.sh (deploy forced command), 1s CLI, firewall, deploy-access
  deploy/            per-component deploy scripts, runner pool, bundle builder, CI entry point
  access/            ip-access.sh (allowlists)
  certificates/      certs.sh (acme.sh)
  backup/            backup.sh (create/list/verify/restore/prune)
  health/            health.sh
  lib/               shared Bash libraries
tests/               shellcheck, unit, config validation, full end-to-end test
```

## Requirements

- Ubuntu 22.04 or 24.04 (x86_64 or arm64) with public IPv4 address(es). IPv6 is optional.
- Hardware is not fixed. Size these limits to your server: `GITEA_*_CPUS/MEMORY`, `GITEA_RUNNER_COUNT/CAPACITY/CPUS/MEMORY`, `OPENHANDS_CPUS/MEMORY`. As a rough guide, OpenHands needs about 1.5–4 GB of RAM per active user, and the image is 3.8 GB.
- A GitHub repository (a public fork or a private copy) with Actions enabled.
- DNS records for your domains pointing at the bind IPs. With `ACME_DNS_PROVIDER` you use the DNS-01 challenge instead of HTTP-01.

## License

[MIT](LICENSE)
