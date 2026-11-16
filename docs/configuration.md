# Configuration reference

Generated from [`config/schema.conf`](../config/schema.conf) by
`scripts/dev/generate-reference.sh`. Do not edit by hand.

How it works:

* You edit `.env` on your Mac and run `scripts/macos/push-config.sh`.
* The server validates it, generates missing secrets and stores
  `/etc/1s/config/<component>.env` (0644) and `/etc/1s/secrets/<component>.env`
  (0600 root). Nothing changes if the file is invalid.
* `local` settings are only read by the macOS scripts.
* GitHub holds only the three deployment secrets `DEPLOY_HOST`,
  `DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS` (plus an optional variable
  `DEPLOY_SSH_PORT`).

Empty values fall back to the defaults below. `${NAME}` means "same as NAME".

## Your Mac (used by scripts/macos only)

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `SERVER_SSH` | string | yes |  | Your administrative SSH login, e.g. root@203.0.113.5 or ubuntu@203.0.113.5 (needs sudo). |
| `SERVER_SSH_PORT` | port | no | `22` | SSH port of the server. |
| `GITHUB_REPO` | string | no |  | GitHub repository as owner/name (only used to print links). |
| `DEPLOY_ACCESS_TTL` | duration | no | `2h` | Deployment access auto-expires after this long (safety net if disable is never run). |

## Shared infrastructure (Nginx, TLS, firewall, backups)

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `ENABLE_GITEA` | bool | no | `true` | Install/deploy Gitea (with deploy target "all"). |
| `ENABLE_OPENHANDS` | bool | no | `true` | Install/deploy OpenHands (with deploy target "all"). |
| `ACME_EMAIL` | email | yes |  | Contact e-mail for the ACME (Let's Encrypt) account. |
| `ACME_SERVER` | string | no | `letsencrypt` | acme.sh CA name or directory URL. Use letsencrypt_test for staging. |
| `ACME_KEY_TYPE` | enum:ec-256/ec-384/2048/3072/4096 | no | `ec-256` | Certificate key type passed to acme.sh --keylength. |
| `ACME_DNS_PROVIDER` | string | no |  | Optional acme.sh DNS API hook (e.g. dns_cf). Empty = HTTP-01 webroot validation. |
| `ACME_DNS_CREDENTIALS` | **secret** | no |  | Whitespace-separated KEY=VALUE pairs for the DNS hook (e.g. "CF_Token=... CF_Zone_ID=..."). |
| `ACME_SKIP_DNS_CHECK` | bool | no | `false` | Skip the DNS-points-to-bind-IP check before HTTP-01 issuance (needed behind 1:1 NAT where the bind IP is private). |
| `ACME_RENEW_DAYS` | int | no | `30` | Warn in health checks when a certificate expires in fewer days than this. |
| `ENABLE_IPV6` | bool | no | `false` | Listen on the *_BIND_IP6 addresses as well. |
| `TRUSTED_PROXIES` | cidrs | no |  | Comma-separated CIDRs of trusted L7 proxies/CDNs in front of Nginx. Empty = trust nobody; the TCP peer address is the client IP. |
| `HSTS_MAX_AGE` | int | no | `31536000` | Strict-Transport-Security max-age in seconds (0 disables the header). |
| `NGINX_IMAGE` | image | no | `nginx:1.30.6-alpine` | Pinned Nginx image. |
| `HELPER_IMAGE` | image | no | `alpine:3.22` | Pinned small image used for volume backup/restore helpers. |
| `BACKUP_DIR` | string | no | `/var/backups/1s` | Local backup directory on the server. |

## Gitea, PostgreSQL and runners

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `GITEA_DOMAIN` | domain | if-gitea |  | Public HTTPS domain for Gitea. |
| `GITEA_BIND_IP` | ipv4 | if-gitea |  | Public IPv4 address Nginx binds for Gitea. |
| `GITEA_BIND_IP6` | ipv6 | no |  | Public IPv6 address for Gitea (used when ENABLE_IPV6=true). |
| `GITEA_SSH_DOMAIN` | domain | no | `${GITEA_DOMAIN}` | Host name shown in SSH clone URLs. |
| `GITEA_SSH_BIND_IP` | ipv4 | no | `${GITEA_BIND_IP}` | IPv4 address for Git-over-SSH. |
| `GITEA_SSH_BIND_IP6` | ipv6 | no |  | IPv6 address for Git-over-SSH (used when ENABLE_IPV6=true). |
| `GITEA_SSH_PORT` | port | no | `2222` | Public Git-over-SSH port. Must not collide with the host sshd. |
| `GITEA_IMAGE` | image | no | `gitea/gitea:28.3.0-rootless` | Pinned Gitea image (rootless variant). |
| `GITEA_POSTGRES_IMAGE` | image | no | `postgres:18.7-alpine` | Pinned PostgreSQL image. |
| `GITEA_LOCAL_PORT` | port | no | `13000` | Loopback port Gitea HTTP is published on (127.0.0.1 only). |
| `GITEA_APP_NAME` | string | no | `Gitea` | Site title. |
| `GITEA_ADMIN_USER` | string | no | `gitea-admin` | Initial administrator login ("admin" is reserved by Gitea). |
| `GITEA_ADMIN_EMAIL` | email | if-gitea |  | Initial administrator e-mail. |
| `GITEA_DISABLE_REGISTRATION` | bool | no | `true` | Disable self-registration. |
| `GITEA_REQUIRE_SIGNIN_VIEW` | bool | no | `true` | Require sign-in to view anything. |
| `GITEA_MAX_BODY_SIZE` | size | no | `512m` | Nginx client_max_body_size for Gitea (pushes, LFS, uploads). |
| `GITEA_CPUS` | cpus | no | `2` | CPU limit for the Gitea container. |
| `GITEA_MEMORY` | size | no | `2g` | Memory limit for the Gitea container. |
| `GITEA_DB_MEMORY` | size | no | `1g` | Memory limit for PostgreSQL. |
| `GITEA_NETWORK_SUBNET` | cidr | no | `10.202.0.0/24` | Private subnet of the Gitea compose network. |
| `GITEA_RUNNER_COUNT` | int | no | `1` | Number of runner containers (0 disables runners). |
| `GITEA_RUNNER_CAPACITY` | int | no | `1` | Concurrent jobs per runner. |
| `GITEA_RUNNER_CPUS` | cpus | no | `2` | CPU limit per runner (shared by its jobs). |
| `GITEA_RUNNER_MEMORY` | size | no | `4g` | Memory limit per runner (shared by its jobs). |
| `GITEA_RUNNER_PIDS_LIMIT` | int | no | `4096` | PID limit per runner. |
| `GITEA_RUNNER_LABELS` | string | no | `ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest,ubuntu-24.04:docker://docker.gitea.com/runner-images:ubuntu-24.04` | Comma-separated runner labels (label:docker://image). |
| `GITEA_RUNNER_IMAGE` | image | no | `gitea/runner:6.0.0-dind-rootless` | Pinned runner image (must match GITEA_RUNNER_ISOLATION). |
| `GITEA_RUNNER_ISOLATION` | enum:rootless/privileged | no | `rootless` | rootless = rootless Docker-in-Docker without --privileged; privileged = rootful DinD (weaker). |
| `GITEA_RUNNER_APPARMOR_PROFILE` | string | no | `1s-rootless-dind` | AppArmor profile for rootless runners (installed by bootstrap; allows user namespaces on Ubuntu 24.04). Use unconfined only on hosts without AppArmor. |
| `GITEA_RUNNER_CA_FILE` | string | no |  | Optional path ON THE SERVER to a PEM CA bundle runners trust for Gitea (private CA setups). Empty = public CAs only. |
| `GITEA_RUNNER_JOB_DOCKER` | bool | no | `true` | Expose the runner's own isolated Docker daemon to jobs (docker build in CI). Never the host daemon. |
| `GITEA_RUNNER_BLOCK_PRIVATE_EGRESS` | bool | no | `true` | Block CI job traffic to private, link-local and metadata addresses and to host services other than Gitea HTTPS. |
| `GITEA_RUNNER_SUBNET_POOL` | cidr | no | `10.203.0.0/16` | /16 pool; runner N gets <pool>.N.0/24. |
| `GITEA_RUNNER_SHUTDOWN_TIMEOUT` | duration | no | `30m` | Grace period for running jobs during runner updates. |
| `GITEA_RUNNER_JOB_TIMEOUT` | duration | no | `3h` | Maximum job duration. |
| `GITEA_RUNNER_PRUNE_AFTER` | duration | no | `72h` | Prune unused images/containers inside each runner's private daemon older than this. |
| `GITEA_BACKUP_SCHEDULE` | calendar | no | `*-*-* 03:00:00` | systemd OnCalendar expression for scheduled backups. |
| `GITEA_BACKUP_RETENTION_DAYS` | int | no | `14` | Delete backups older than this many days. |
| `GITEA_BACKUP_KEEP_MIN` | int | no | `3` | Always keep at least this many backups. |
| `GITEA_BACKUP_BEFORE_DEPLOY` | bool | no | `true` | Take a backup before every deployment/update. |
| `GITEA_BACKUP_STOP_SERVICE` | bool | no | `false` | Stop Gitea while archiving repositories (fully consistent, short downtime). |
| `GITEA_ADMIN_PASSWORD` | **secret** | if-gitea |  | Initial administrator password (only used when the admin does not exist yet). |
| `GITEA_DB_PASSWORD` | **secret** | if-gitea |  | PostgreSQL password (rotation is applied on deploy). |
| `GITEA_SECRET_KEY` | **secret** | if-gitea |  | Gitea [security] SECRET_KEY. Never rotate casually: it encrypts stored secrets. |
| `GITEA_INTERNAL_TOKEN` | **secret** | if-gitea |  | Gitea [security] INTERNAL_TOKEN. |
| `GITEA_OAUTH2_JWT_SECRET` | **secret** | if-gitea |  | Gitea [oauth2] JWT_SECRET (base64url, 32 bytes). |
| `GITEA_LFS_JWT_SECRET` | **secret** | if-gitea |  | Gitea [server] LFS_JWT_SECRET (base64url, 32 bytes). |

## OpenHands Agent Canvas

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `OPENHANDS_DOMAIN` | domain | if-openhands |  | Public HTTPS domain for OpenHands Agent Canvas. |
| `OPENHANDS_BIND_IP` | ipv4 | if-openhands |  | Public IPv4 address Nginx binds for OpenHands. |
| `OPENHANDS_BIND_IP6` | ipv6 | no |  | Public IPv6 address for OpenHands (used when ENABLE_IPV6=true). |
| `OPENHANDS_USERS` | users | if-openhands |  | Comma-separated name:port pairs; each user gets an isolated instance on https://OPENHANDS_DOMAIN:port. |
| `OPENHANDS_IMAGE` | image | no | `ghcr.io/openhands/agent-canvas:1.33.0` | Pinned Agent Canvas image. |
| `OPENHANDS_LOCAL_PORT_BASE` | port | no | `28000` | Loopback port base; user #N is published on 127.0.0.1:(base+N). |
| `OPENHANDS_CPUS` | cpus | no | `2` | CPU limit per user instance. |
| `OPENHANDS_MEMORY` | size | no | `4g` | Memory limit per user instance. |
| `OPENHANDS_PIDS_LIMIT` | int | no | `2048` | PID limit per user instance. |
| `OPENHANDS_SUBNET_POOL` | cidr | no | `10.204.0.0/16` | /16 pool; user #N gets <pool>.N.0/24. |
| `OPENHANDS_AGENT_SUDO` | bool | no | `false` | Allow the agent to use sudo inside its container (disables no-new-privileges and restores default capabilities). Keep false unless agents must apt-get install. |
| `OPENHANDS_BLOCK_PRIVATE_EGRESS` | bool | no | `true` | Block agent traffic to private, link-local and metadata addresses and to host services. |
| `OPENHANDS_ALLOW_GITEA` | bool | no | `false` | Allow agent instances to reach Gitea over HTTPS and Git-over-SSH (adds the OpenHands pool to the Gitea allowlists). |
| `OPENHANDS_MAX_BODY_SIZE` | size | no | `100m` | Nginx client_max_body_size for OpenHands uploads. |
| `OPENHANDS_BACKUP_SCHEDULE` | calendar | no | `*-*-* 03:30:00` | systemd OnCalendar expression for scheduled backups. |
| `OPENHANDS_BACKUP_RETENTION_DAYS` | int | no | `14` | Delete backups older than this many days. |
| `OPENHANDS_BACKUP_KEEP_MIN` | int | no | `3` | Always keep at least this many backups. |
| `OPENHANDS_BACKUP_BEFORE_DEPLOY` | bool | no | `true` | Take a backup before every deployment/update. |
| `OPENHANDS_BACKUP_STOP_SERVICE` | bool | no | `true` | Stop each instance while archiving (its SQLite data must be consistent). |
| `OPENHANDS_API_MASTER_KEY` | **secret** | if-openhands |  | Master key from which each user's Agent Canvas API key is derived (HMAC). Safe to rotate. |
| `OPENHANDS_STORAGE_MASTER_KEY` | **secret** | if-openhands |  | Master key from which each user's OH_SECRET_KEY is derived. Rotating makes stored agent secrets unreadable. |
