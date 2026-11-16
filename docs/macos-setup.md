# Installation from macOS

You need only what macOS already has: **Terminal, `git` and `ssh`**. There is
nothing to install with Homebrew. All scripts run with the built-in Bash.

Replace the example values: documentation addresses such as `203.0.113.10` and
domains such as `git.example.com`.

## 1. What you need

- An Ubuntu 22.04/24.04 server you can log in to with SSH as `root` or as a user
  with `sudo`. The scripts use this administrative login but never modify or
  revoke it.
- One public IPv4 address, or two if Gitea and OpenHands should use separate
  addresses, plus IPv6 addresses if you want them.
- A GitHub repository with this code (fork it or push a copy).
- DNS records you can edit.

Check that SSH works, and accept the host key when asked:

```bash
ssh root@203.0.113.5 'echo ok'
```

## 2. Configure

```bash
git clone https://github.com/your-org/1s.git && cd 1s
cp .env.example .env
open -e .env        # or: nano .env
```

Minimum settings (all explained in [configuration.md](configuration.md)):

```dotenv
SERVER_SSH=root@203.0.113.5         # your admin login (root, or a sudo user)
GITHUB_REPO=your-org/1s             # only used to print links

ACME_EMAIL=you@example.com

GITEA_DOMAIN=git.example.com
GITEA_BIND_IP=203.0.113.10
GITEA_ADMIN_EMAIL=you@example.com

OPENHANDS_DOMAIN=ai.example.com
OPENHANDS_BIND_IP=203.0.113.20      # may equal GITEA_BIND_IP
OPENHANDS_USERS=alice:443,bob:8444  # one isolated instance per user

ENABLE_GITEA=true                   # set false to install only OpenHands
ENABLE_OPENHANDS=true               # set false to install only Gitea
```

You don't set passwords or keys. The server generates them on the first
`push-config.sh` and keeps them as root-only files.

Notes:

- **One IP or several.** Gitea and OpenHands may share an IP; Nginx routes by
  name. Each OpenHands user needs their own port.
- **IPv6.** Set `ENABLE_IPV6=true` and the `*_BIND_IP6` values.
- **Git-over-SSH** listens on `GITEA_SSH_BIND_IP:GITEA_SSH_PORT`. The defaults
  are the Gitea IP and port 2222. It must not collide with the server's own sshd.
- **Behind 1:1 NAT** (the bind IP is private and the public IP is only in DNS),
  set `ACME_SKIP_DNS_CHECK=true`.
- **DNS-01 challenge** (only if port 80 can't be reached): set
  `ACME_DNS_PROVIDER=dns_cf` and
  `ACME_DNS_CREDENTIALS="CF_Token=... CF_Zone_ID=..."`, using your provider's
  names from the [acme.sh DNS API list](https://github.com/acmesh-official/acme.sh/wiki/dnsapi).
- `.env` is git-ignored. Never commit it.

## 3. DNS

| Name | Type | Value |
|---|---|---|
| `git.example.com` | A | `GITEA_BIND_IP` |
| `ai.example.com` | A | `OPENHANDS_BIND_IP` |
| optional | AAAA | the `*_BIND_IP6` values |

Each bind IP must be configured on the server's network interface
(`ip -br addr` on the server).

Check the records from your Mac:

```bash
host git.example.com
host ai.example.com
```

## 4. Prepare the server

```bash
scripts/macos/bootstrap-server.sh
```

It copies the repository to the server and installs:

- Docker (official repository) and base packages
- the **restricted `deploy` user**: it has no password, its home is root-owned,
  it is not in the `docker` group, and it may run exactly one program through
  sudo
- the deployment gateway
- the AppArmor profile that rootless runners need on Ubuntu 24.04
- the `1s` administration command

Deployment access is **disabled** at the end. Bootstrap is safe to re-run.

## 5. Upload the configuration

```bash
scripts/macos/push-config.sh
```

The server validates `.env`, generates the missing secrets and stores
everything under `/etc/1s`. If anything is invalid it changes nothing and tells
you what to fix. Run it again after every change to `.env`.

## 6. Deployment key and GitHub secrets

```bash
scripts/macos/generate-deploy-key.sh
```

1. It creates `~/.ssh/1s_deploy_ed25519`, a key used only for deployments.
2. It installs the **public** key on the server. Access stays disabled.
3. It copies three values to your clipboard one at a time. Paste each into
   GitHub: repository **Settings → Environments → New environment
   `production` → Add environment secret**:

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | server address |
| `DEPLOY_SSH_KEY` | the private deployment key |
| `DEPLOY_KNOWN_HOSTS` | the server's SSH host key, read over your trusted admin connection |

These three are the only things GitHub stores. The private key is never copied
to the server.

Recommended, in the same environment page:

- **Deployment branches**: "Selected branches" → `main`.
- **Required reviewers**: yourself, so every deployment needs your click.

If your SSH port isn't 22, also add a repository **variable** `DEPLOY_SSH_PORT`.

## 7. Allow your IP

The web UIs answer **403 to everyone** until you allow addresses:

```bash
scripts/macos/ip-access.sh add gitea me        # "me" = your address as seen by the server
scripts/macos/ip-access.sh add openhands me
scripts/macos/ip-access.sh add gitea-ssh me    # Git-over-SSH has its own list
scripts/macos/ip-access.sh add gitea 198.51.100.0/24 --comment office
scripts/macos/ip-access.sh list
```

## 8. Deploy

```bash
scripts/macos/deploy.sh
```

The script:

1. Enables deployment access with an automatic expiry (`DEPLOY_ACCESS_TTL`, default 2h).
2. Opens the workflow page. Click **Run workflow** and choose:
   - **target**: `all`, `shared`, `gitea` or `openhands`
   - **action**: `deploy`, `health`, `backup`, `rollback` or `status`
3. When the run has finished, press Enter in the terminal and access is
   **disabled again**. This also happens on Ctrl-C.

You can also do it by hand:

```bash
scripts/macos/deploy-access.sh enable --ttl 1h
# ... run the workflow on GitHub ...
scripts/macos/deploy-access.sh disable
scripts/macos/deploy-access.sh status
```

**If the script is interrupted** (laptop closed, network lost), access still
expires after the TTL. To revoke it immediately, run
`scripts/macos/deploy-access.sh disable`. Without SSH, use the provider's
console: `1s deploy-access disable`.

The first deployment takes a few minutes, mostly downloading images and
issuing certificates.

## 9. First login

- **Gitea**: `https://git.example.com`, user `gitea-admin`. Get the password with:

  ```bash
  scripts/macos/server.sh config secret GITEA_ADMIN_PASSWORD
  ```

  Add your SSH key in Gitea, then clone with
  `git clone ssh://git@git.example.com:2222/owner/repo.git`.
- **OpenHands**: each user opens `https://ai.example.com:<port>/` and pastes
  their API key:

  ```bash
  scripts/macos/server.sh openhands key alice
  ```

  Then follow [openhands.md](openhands.md) to choose an agent and add credentials.

## 10. Everyday operations

| Task | Command |
|---|---|
| Change settings | edit `.env` → `push-config.sh` → `deploy.sh` (target of that component) |
| Add/remove OpenHands users | edit `OPENHANDS_USERS` → `push-config.sh` → deploy `openhands` |
| Scale runners | edit `GITEA_RUNNER_COUNT` / `GITEA_RUNNER_CAPACITY` → `push-config.sh` → deploy `gitea` |
| Update versions | pull a newer release of this repository, or change a pinned image in `.env` → `push-config.sh` → deploy |
| Allowlists | `scripts/macos/ip-access.sh add\|remove\|list ...` |
| Status / health | `scripts/macos/server.sh status`, `scripts/macos/server.sh health` |
| Certificates | `scripts/macos/server.sh certs check` |
| Backups | automatic daily; `scripts/macos/server.sh backup create gitea`; see [operations.md](operations.md#restore) |
| Any server command | `scripts/macos/server.sh <command>` (same as `sudo 1s <command>` on the server) |

For problems, see [troubleshooting.md](troubleshooting.md).
