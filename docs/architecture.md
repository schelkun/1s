# Architecture

## Components and lifecycles

| Component | Compose project(s) | Networks | Volumes | Secrets file |
|---|---|---|---|---|
| shared | `1s-nginx` | host network | none (config under `/etc/1s`) | `/etc/1s/secrets/shared.env` |
| gitea | `1s-gitea`, `1s-gitea-runner-N` | `1s-gitea-frontend` (10.202.0.0/24), `1s-gitea-backend` (internal), `1s-gitea-runner-N` (10.203.N.0/24) | `1s-gitea-{db,data,config}`, `1s-gitea-runner-N-{data,docker}` | `/etc/1s/secrets/gitea.env` |
| openhands | `1s-openhands-<user>` | `1s-openhands-<user>` (10.204.N.0/24) | `1s-openhands-<user>-{data,projects}` | `/etc/1s/secrets/openhands.env` |

Deploying a component writes only that component's files under `/etc/1s`.
It starts or updates only that component's containers and gracefully reloads
Nginx; it never restarts it. Gitea and OpenHands share no Docker network.
Each publishes its HTTP port on `127.0.0.1` only, and Nginx reaches it there.

Server layout:

```text
/opt/1s/releases/<git-sha>/   immutable code releases (last 8 kept)
/opt/1s/tools -> releases/... scripts used by timers, hooks and the 1s CLI
/opt/1s/acme.sh/              pinned acme.sh (checksum-verified)
/etc/1s/config/*.env          non-secret settings per component
/etc/1s/secrets/*.env         secrets per component (0600 root)
/etc/1s/runtime/              rendered compose env files (0600)
/etc/1s/access/*.allow        allowlists (source of truth)
/etc/1s/nginx/current ->      active Nginx generation (atomically swapped)
/etc/1s/tls/<domain>/         fullchain.pem, key.pem (0600)
/etc/1s/overrides/<dir>.yml   optional operator compose overlays
/var/lib/1s/state/            deployed markers, release history, pre-deploy backup ids
/var/lib/1s/acme/             acme.sh account and certificate state
/var/backups/1s/<component>/  local backups (0700)
/var/log/1s/gateway.log       deployment log
```

## Networking

**Nginx uses host networking.** This is deliberate:

- It binds **explicit addresses** (`listen 203.0.113.10:443`, `listen [2001:db8::10]:443`) and never wildcards. Two services can use different IPs, or share one.
- It sees the **real TCP peer address** without Docker NAT, `userland-proxy` or IPv6 NAT problems. This is what the allowlists match.
- It needs no Docker network shared with the applications, so the stacks stay isolated from each other.

For every IP:port Nginx listens on, a `default_server` rejects unknown names:
`ssl_reject_handshake` on TLS ports and `444` on port 80. A request for a name
that isn't configured never reaches an application.

**Client IP handling.** By default `TRUSTED_PROXIES` is empty and
`$remote_addr` is the TCP peer. Nginx overwrites `X-Forwarded-For`,
`X-Real-IP` and `Forwarded` towards the upstream and never appends to them. A
client therefore cannot spoof its address to the allowlist or to the
application. If you run a CDN or L4/L7 proxy in front, list its ranges in
`TRUSTED_PROXIES`. Nginx then uses `real_ip_header X-Forwarded-For` with
`real_ip_recursive on`, and only those proxies are believed. Gitea trusts
`X-Real-IP` only from the loopback and its frontend network gateway.

**WebSockets and long connections**: HTTP/1.1 upstream, `Upgrade` and `Connection`
mapping, 3600 s read and send timeouts, and no buffering (needed for Server-Sent Events and
streaming agent output).

## TLS (acme.sh)

- **HTTP-01 (default).** Port 80 on each bind IP serves only:
  - `/.well-known/acme-challenge/` from a webroot
  - `/.1s/healthz`
  - redirects to HTTPS

  ACME validation therefore works with any allowlist, and nothing protected is exposed on port 80.
- **DNS-01** (`ACME_DNS_PROVIDER=dns_xxx` and `ACME_DNS_CREDENTIALS`) uses any acme.sh DNS API hook.
- **Bootstrapping.** A deployed domain gets a 7-day self-signed placeholder, so Nginx can start and answer the challenge. The real certificate replaces it immediately. `1s certs check` and the health check flag any remaining placeholder.
- **Renewal.** `1s-certs.timer` runs daily: `acme.sh --cron`, then an expiry check. acme.sh installs renewed certificates, and its reload hook runs `nginx -t` and then a graceful reload.
- acme.sh is pinned to a release and its download is **verified with SHA-256**. The account and keys are stored as root with mode 0700.

## IP access control

| List | Enforced by | Default |
|---|---|---|
| `gitea` | Nginx `allow`/`deny all` → **403** | deny all |
| `openhands` | Nginx (every user instance) → **403** | deny all |
| `gitea-ssh` | iptables/ip6tables in `DOCKER-USER`, matched on the original destination (`--ctorigdst`) → drop | deny all |

`ip-access.sh` validates and normalises every address (IPv4, IPv6, CIDR, host
bits cleared) and skips duplicates. It writes the list atomically, renders a
**new Nginx generation**, runs `nginx -t`, swaps the `current` symlink and
reloads. If anything fails, the list file and the running configuration are
rolled back. `nginx -t` also binds the listen sockets, so it catches missing
addresses and port conflicts too.

Gitea runners reach Gitea at its public URL. Their address pool
(`GITEA_RUNNER_SUBNET_POOL`) is always allowed. OpenHands agents are allowed
only when `OPENHANDS_ALLOW_GITEA=true`.

## Deployment path

1. You enable access from macOS through the **admin** account. This writes one line into the deploy
   user's **root-owned** `authorized_keys`:
   `restrict,command="/usr/local/lib/1s/gateway" ssh-ed25519 …`. A transient
   systemd timer revokes it after the TTL.
2. The *Deploy* workflow (manual, `main` only, `production` environment) streams
   a `git archive` of the commit over SSH, with the host key pinned. Settings and
   secrets are already on the server (`push-config.sh` → `1s config import`).
3. The gateway accepts only `ping`, `status`, `deploy`, `health`, `backup` and `rollback`
   with strictly validated arguments. It re-executes itself as root through a single
   sudoers rule, installs the release immutably under `/opt/1s/releases/<sha>`
   and runs `scripts/deploy/deploy-<target>.sh`.
4. You disable access, or the TTL does it.

## Gitea Actions runners

- The official `gitea/runner` (v6) **`-dind-rootless`** image. Each runner has its
  own **rootless dockerd**, network and volumes, and limits on CPU, memory and PIDs. It runs
  **without `--privileged`** and without added capabilities:
  - `/dev/net/tun` (slirp4netns)
  - `seccomp=unconfined` and `systempaths=unconfined` (rootlesskit and nested `/proc`)
  - an AppArmor profile that only adds `userns` (needed on Ubuntu 24.04)

  Verified working in this repository's tests.
- Jobs never see the host Docker daemon. `GITEA_RUNNER_JOB_DOCKER=true` gives jobs
  the runner's *own* rootless daemon, for `docker build`.
- A runner registers with a one-time token generated by
  `gitea actions generate-runner-token`. The token file is emptied right after registration.
- **Scaling** (`GITEA_RUNNER_COUNT`) is reconciled one runner at a time. Removed
  runners finish their jobs (`GITEA_RUNNER_SHUTDOWN_TIMEOUT`), are deregistered
  through the API, and their volumes and network are deleted.
- The daily `1s-runner-prune.timer` prunes images and containers **inside each
  runner's private daemon**, never the host.
- Fallback `GITEA_RUNNER_ISOLATION=privileged` uses the rootful `-dind` image in a
  privileged container. It is less secure; use it only if your kernel cannot run rootless.

Alternatives considered: the host Docker socket (root-equivalent for every
workflow author, rejected), Sysbox (strong isolation but an extra
runtime and kernel dependency), and Kata Containers or one VM per job (strongest,
but much heavier and needs nested virtualization). See [security.md](security.md).

## OpenHands

Agent Canvas (`ghcr.io/openhands/agent-canvas`) bundles the UI, the Agent Server,
the Automation Server and an ingress. Upstream it is a **single-user**
product: one shared API key per backend, with no accounts or roles. Real multi-user
isolation therefore means **one instance per user**:

- its own container, network, data and projects volumes, and resource limits
- its own **API key**, derived from `OPENHANDS_API_MASTER_KEY` with HMAC-SHA256, and its own **encryption key** (`OH_SECRET_KEY`)
- its own origin (`https://domain:<port>`), so browser storage such as API keys cannot leak between users

Each agent runs as the unprivileged `openhands` user with `cap_drop: ALL` and
`no-new-privileges`. The image ships passwordless sudo, and these settings make it
unusable. There is no host Docker socket. Private, link-local and metadata egress is
blocked (`OPENHANDS_BLOCK_PRIVATE_EGRESS`), and so is access to host services,
other users' containers and Gitea (unless `OPENHANDS_ALLOW_GITEA`).

Sandbox options compared:

| Option | Isolation | Upstream support | Cost | Chosen |
|---|---|---|---|---|
| One shared Canvas container | none between users | yes | lowest | no |
| **One hardened container per user** | kernel namespaces, no caps, egress filtered | yes (official image) | moderate | **default** |
| Agent with `--privileged` Docker | weak | documented by upstream | — | no |
| Rootless Docker inside the agent | — | upstream says it does not work | — | no |
| Remote Agent Server per VM | VM boundary | yes (remote backends) | high | documented as the next step |
| gVisor / Kata runtime | strong | not tested upstream | medium/high | possible with an override file |

To get stronger isolation, `/etc/1s/overrides/openhands.yml` can set
`runtime: runsc` (gVisor) once it is installed. Upstream does not test this.
