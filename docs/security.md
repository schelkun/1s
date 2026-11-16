# Security model

## Trust boundaries

| Actor | Can do | Cannot do |
|---|---|---|
| You (admin SSH account) | everything on the server | — |
| GitHub Actions deploy job | `ping`, `status`, `deploy`, `health`, `backup`, `rollback` through the gateway, **only while you have enabled access** | open a shell, forward ports, get a PTY, run arbitrary commands, add keys |
| Pull requests / forks | run `ci.yml` without secrets | reach any secret or the server |
| Allowlisted web client | use Gitea / OpenHands normally | anything else |
| Other Internet clients | ACME challenge, `/.1s/healthz`, HTTP→HTTPS redirect | see any application page (403) or Git-over-SSH (dropped) |
| CI job (runner) | its own rootless Docker daemon, outbound Internet, Gitea HTTPS | the host Docker daemon, other runners, private networks, host services, cloud metadata |
| OpenHands agent | its own container, outbound Internet | sudo, the Docker socket, other users' instances, Gitea (unless allowed), private networks, host services |

**Important:** a deployment necessarily runs code from your repository as
root, so whoever can push to `main` and approve the `production` environment
controls the server. Protect `main` and the environment accordingly. The
temporary-access design limits *when* that is possible and *what a stolen key*
can do, not what a merged commit can do.

## Deployment access

- Dedicated Ed25519 key, only for deployments. The private key exists on your
  Mac (`~/.ssh/1s_deploy_ed25519`, 0600) and as a GitHub environment secret.
  It is never on the server.
- The key is accepted only while enabled. The entry uses
  `restrict,command="/usr/local/lib/1s/gateway"`: no PTY, no port, agent or X11
  forwarding, no user rc.
- `authorized_keys` and the deploy user's home and `~/.ssh` are owned by root.
- The deploy user has no password, no `docker` group membership and exactly one
  sudo rule: the gateway.
- The gateway never evaluates the client command. It splits it into words,
  matches every word against fixed patterns, and limits bundle size, symlinks
  and file names.
- Access expires automatically (`DEPLOY_ACCESS_TTL`) in case disabling is missed.
- The SSH host key is pinned: `DEPLOY_KNOWN_HOSTS` is read over your already
  trusted admin SSH connection.
- The admin account is never modified, so you cannot lock yourself out with
  these tools.

## Web access

- Default deny with independent allowlists. A request for an unknown name is
  rejected at TLS (`ssl_reject_handshake`) or with 444.
- Client IP is the TCP peer unless `TRUSTED_PROXIES` is set. Forwarding headers
  are overwritten, not appended, so they cannot be spoofed.
- TLS 1.2/1.3 with Mozilla intermediate ciphers, HSTS, `server_tokens off`,
  `nosniff`, `Referrer-Policy`.
- Configuration changes are validated (`nginx -t` including socket binding)
  before an atomic switch, with automatic rollback.

## Containers

- No container gets the host Docker socket.
- Nginx: read-only root filesystem, `cap_drop: ALL` plus the four capabilities
  it needs, `no-new-privileges`.
- Gitea: rootless image (UID 1000), `cap_drop: ALL`, `no-new-privileges`,
  PostgreSQL on an `internal` network, HTTP only on 127.0.0.1.
- Runners: rootless Docker-in-Docker without `--privileged` and without added
  capabilities. The relaxations needed are documented in
  `compose/gitea-runners/compose.rootless.yml`: `/dev/net/tun`, unconfined
  seccomp and system paths, and an AppArmor profile that only adds `userns`.
  Unconfined seccomp widens the kernel attack surface compared to a default
  container, while it is still far narrower than `--privileged` or socket
  mounting. For hostile workloads, use Sysbox or one VM per runner.
- OpenHands: one container per user, unprivileged user, `cap_drop: ALL`,
  `no-new-privileges`, private network, egress filter.
- Every container has CPU, memory and PID limits and log rotation.

## Secrets

- Stored **on the server only**: `/etc/1s/secrets/<component>.env`, 0600 root.
  They are generated there with `openssl rand` on the first `push-config.sh`
  (or taken from your `.env` if you set them). Backups that contain them are 0700/0600.
- GitHub holds only the three deployment secrets; deployments send code only.
- `.env` (git-ignored) is uploaded over SSH into a 0600 temporary file, which is
  deleted right after the import.
- Never committed: `.gitignore` covers `.env`, keys and backups.
- Container environments are visible to root on the server (`docker inspect`),
  which is equivalent to root access anyway.
- The Gitea runner registration token is emptied right after registration.
- OpenHands per-user keys are derived from master secrets with HMAC-SHA256, and
  the key is passed through the environment, not argv.

## Known limitations

- Single server, local backups only: copy `/var/backups/1s` off the server
  yourself.
- Containers are not VMs. Kernel vulnerabilities can cross container boundaries.
  For untrusted CI or agent users, use VM-based isolation.
- Agent Canvas has no user accounts. Anyone with a user's API key and an
  allowlisted IP is that user.
- Agent Canvas 1.33.0 leaves its API unauthenticated when only
  `LOCAL_BACKEND_API_KEY` is set. 1s works around this and checks it on every
  deploy and health check. Keep the check when upgrading.
- `actions/checkout` is referenced by tag. Pin it to a reviewed commit SHA if
  your policy requires it.
