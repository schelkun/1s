# Operations

Run server commands either on the server (`sudo 1s ...`) or from your Mac with
`scripts/macos/server.sh ...`, which runs the same `1s` command over your admin
SSH login. The `1s` CLI wraps every tool:

```bash
sudo 1s status            # components, releases, containers
sudo 1s health            # all checks (exit code 1 on failure)
sudo 1s help
```

## IP allowlists

```bash
# On the server (the paths from the task description work too):
sudo 1s ip-access add gitea 198.51.100.10
sudo 1s ip-access add gitea 2001:db8:1::/48 --comment "office v6"
sudo 1s ip-access remove gitea 198.51.100.10
sudo 1s ip-access add openhands 198.51.100.20
sudo 1s ip-access list            # or: list gitea | list openhands | list gitea-ssh
sudo 1s ip-access check gitea 198.51.100.10
sudo /opt/1s/tools/scripts/access/ip-access.sh add gitea 198.51.100.10   # equivalent

# From macOS:
scripts/macos/ip-access.sh add gitea me
```

- Lists are **independent**: `gitea`, `openhands`, `gitea-ssh`.
- Empty list means everyone is denied (403, or a dropped connection for SSH).
- Operations are idempotent. Re-adding an entry or removing a missing one is a no-op.
- `0.0.0.0/0` and `::/0` are refused unless you pass `--force`.
- Changes are validated and rolled back automatically if they cannot be applied.
- `/.well-known/acme-challenge/` and `/.1s/healthz` stay reachable for everyone.

### Lockout recovery

The allowlists never affect the server's own sshd. If you lock yourself out of
the web UI:

```bash
ssh ubuntu@server 'sudo 1s ip-access add gitea <your-new-ip>'
# or from macOS:
scripts/macos/ip-access.sh add gitea me
```

If the admin SSH account itself is unreachable, use the provider's console. To
re-render everything from the stored lists, run `sudo 1s ip-access apply`.

## Certificates

```bash
sudo 1s certs check                     # expiry, temporary certificates
sudo 1s certs list                      # acme.sh view
sudo 1s certs issue git.example.com     # issue/renew now (skips if not due)
sudo 1s certs issue git.example.com --force
sudo 1s certs renew                     # what the daily timer runs
systemctl list-timers '1s-*'
```

To move from staging to production, set `ACME_SERVER=letsencrypt`, deploy
shared, then run `sudo 1s certs issue <domain> --force` for each domain.

## Updates

Pull a newer release of this repository, or change the pinned image in `.env`
(for example `GITEA_IMAGE=gitea/gitea:28.4.0-rootless`). Then:

```bash
scripts/macos/push-config.sh             # if .env changed
scripts/macos/deploy.sh                  # then run the workflow with target gitea / openhands / shared
```

What a deployment does:

- **Before** changing anything, it takes a backup (`*_BACKUP_BEFORE_DEPLOY=true`).
- It updates **only the target component**. Containers whose configuration did not change are not restarted. Nginx is reloaded gracefully.
- Runners are updated **one at a time**, and each waits for its running jobs (`GITEA_RUNNER_SHUTDOWN_TIMEOUT`).
- Named volumes are never removed by a deployment. Removing an OpenHands user stops their instance but **keeps the data**. Delete it explicitly with `sudo 1s openhands purge-user <name> --yes`.

Major PostgreSQL upgrades (for example 18 → 19) need a dump and restore. Changing
`GITEA_POSTGRES_IMAGE` to a new major version alone will not start. Use
`1s backup create gitea`, deploy with the new image on an empty volume, then restore.

## Rollback

```bash
scripts/macos/deploy.sh --target gitea --action rollback                  # code/images only
scripts/macos/deploy.sh --target gitea --action rollback --restore-data   # + data
```

- Rollback redeploys the **previous release** (code and pinned images) with the current settings.
- Gitea refuses to start on a database already migrated by a newer version. In that case use `--restore-data`: it restores the pre-deployment backup taken before the current release, then starts the older version. Changes made after that backup are lost.

## Backups

- **Gitea**: `pg_dump -Fc` (a consistent snapshot), the repositories and data volume, the Gitea configuration volume, and the server settings, secrets and allowlists.
- **OpenHands**: for each user, the data and projects volumes. Each instance is stopped briefly for SQLite consistency (`OPENHANDS_BACKUP_STOP_SERVICE`).
- Each backup has a `manifest.env` (versions, release, key fingerprint) and `SHA256SUMS`, and is verified right after creation.
- Stored under `/var/backups/1s/<component>/<timestamp>[-tag]` with modes 0700/0600. **Local only.** Copy them off the server yourself if needed.
- Scheduled by `1s-backup-gitea.timer` and `1s-backup-openhands.timer` (`*_BACKUP_SCHEDULE`). Pruned after `*_BACKUP_RETENTION_DAYS`, always keeping `*_BACKUP_KEEP_MIN`.

```bash
sudo 1s backup create gitea
sudo 1s backup list gitea
sudo 1s backup verify gitea latest
```

### Restore

```bash
sudo 1s backup restore gitea 20261113T030000Z-scheduled --yes
sudo 1s backup restore openhands latest --yes --user alice
```

1. Restore verifies the checksums and archives first.
2. It takes a safety backup (`pre-restore`). Skip it with `--no-safety-backup`.
3. It stops only the affected containers, replaces their data, starts them and runs the health check.

If the backup was made with a different `GITEA_SECRET_KEY`, restore stops. Add
`--restore-secrets` to bring the old secrets back. They are stored on the
server, so nothing else needs to change.

## Runners

```bash
sudo 1s runners status
sudo 1s runners reconcile   # what a deployment does
sudo 1s runners prune       # cleanup inside each runner's private daemon
```

Labels: `GITEA_RUNNER_LABELS` (`label:docker://image`). Concurrency equals
`GITEA_RUNNER_COUNT` × `GITEA_RUNNER_CAPACITY`. The CPU and memory limits apply
per runner and are shared by that runner's jobs.

## Rotating credentials

| Credential | How | Effect |
|---|---|---|
| Deploy key | `scripts/macos/generate-deploy-key.sh --rotate` (then paste `DEPLOY_SSH_KEY` again) | old key dead immediately |
| Host key pin | `generate-deploy-key.sh` again (pastes `DEPLOY_KNOWN_HOSTS`) | after a server reinstall |
| `GITEA_DB_PASSWORD` | `server.sh config rotate GITEA_DB_PASSWORD` → deploy gitea | applied with `ALTER ROLE` during deploy |
| `GITEA_INTERNAL_TOKEN`, `GITEA_*_JWT_SECRET` | `server.sh config rotate <NAME>` → deploy gitea | users must log in again, LFS tokens renewed |
| `GITEA_SECRET_KEY` | **avoid** (`rotate ... --yes`) | it encrypts 2FA secrets and tokens stored in the DB; they become unreadable |
| `GITEA_ADMIN_PASSWORD` | change it in the Gitea UI; deploys never reset an existing admin | — |
| `OPENHANDS_API_MASTER_KEY` | `server.sh config rotate OPENHANDS_API_MASTER_KEY` → deploy openhands | every user gets a new API key (`server.sh openhands key <user>`) |
| `OPENHANDS_STORAGE_MASTER_KEY` | **avoid** | secrets stored inside Agent Canvas become unreadable; users re-enter them |
| Admin SSH login | your own process | the scripts never change it |

To set a secret yourself instead of the generated one, put it in `.env` and run
`push-config.sh`.

## Logs

```bash
docker logs --tail 100 1s-nginx | 1s-gitea | 1s-gitea-db | 1s-gitea-runner-1 | 1s-openhands-alice
sudo tail -f /var/log/1s/gateway.log
journalctl -u 1s-certs.service -u 1s-backup-gitea.service
```
