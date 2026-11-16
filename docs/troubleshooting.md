# Troubleshooting

## Deployment

| Symptom | Cause / fix |
|---|---|
| `Cannot reach the deployment gateway` | Run `scripts/macos/deploy-access.sh enable` (or use `deploy.sh`) and check `deploy-access.sh status`. If access is enabled, compare the "Deploy key fingerprint" in the workflow log with the `key:` line of `status`. If they differ, paste `~/.ssh/1s_deploy_ed25519` into `DEPLOY_SSH_KEY` again (`pbcopy < ~/.ssh/1s_deploy_ed25519`). |
| `Host key verification failed` in Actions | The server was reinstalled or `DEPLOY_KNOWN_HOSTS` is stale: run `generate-deploy-key.sh` and paste the secrets again. |
| `Permission denied (publickey)` | Key mismatch: `generate-deploy-key.sh --rotate`. Or sshd `AllowUsers`/`AllowGroups` excludes `deploy` (bootstrap warns about this). |
| `1s-gateway: rejected: ...` | The workflow sent an unknown command; use the provided workflow and scripts. |
| `No configuration on this server yet` / validation errors | Run `scripts/macos/push-config.sh`; it lists every invalid or missing setting. |
| `Deploy the shared infrastructure first` | Deploy `--target shared` (or `all`) once. |
| The wrapper was interrupted | Access expires after the TTL anyway. To revoke now: `scripts/macos/deploy-access.sh disable`. If that also fails: provider console → `sudo 1s deploy-access disable`. A deployment that was still running finishes on its own; check with `sudo 1s status` and `sudo tail /var/log/1s/gateway.log`. |
| Workflow stuck at "Waiting" | The `production` environment needs your approval (required reviewers). |

## Web access

| Symptom | Fix |
|---|---|
| 403 everywhere | Your IP is not allowlisted, or it changed: `scripts/macos/ip-access.sh add gitea me`. Check with `sudo 1s ip-access check gitea <ip>`. |
| 403 behind a CDN/proxy | Set `TRUSTED_PROXIES` to the proxy ranges, then deploy shared. |
| Browser certificate warning | A temporary certificate is still in place: `sudo 1s certs check`, then `sudo 1s certs issue <domain>`. Check DNS and that port 80 on the bind IP is reachable from the Internet (cloud firewall!). |
| `bind() ... Address not available` | The bind IP is not configured on the server: `ip -br addr`. Add it (netplan/provider), then deploy shared. |
| `address already in use` | Something else listens on 80/443 or a user port: `sudo ss -ltnp`. |
| OpenHands loads, then "Invalid API key" | Use the user's key: `scripts/macos/server.sh openhands key <user>`. |
| WebSocket/agent stream stops | Check client-side proxies/VPNs; Nginx allows 1 h idle connections. |

## Gitea and runners

| Symptom | Fix |
|---|---|
| `git clone ssh://...:2222` times out | Allowlist the IP for Git-over-SSH: `ip-access.sh add gitea-ssh me`. Also open the port in your cloud firewall. |
| Runner not registering | `docker logs 1s-gitea-runner-1`. The runner must reach `https://GITEA_DOMAIN` from the server: check DNS from the server and that the certificate is not a placeholder (or set `GITEA_RUNNER_CA_FILE` for private CAs). |
| `AppArmor profile 1s-rootless-dind is not loaded` | Re-run bootstrap (`scripts/macos/bootstrap-server.sh`). |
| Rootless dockerd fails (`failed to setup network`, `/dev/net/tun`) | `modprobe tun` / bootstrap. As a last resort `GITEA_RUNNER_ISOLATION=privileged` with a `-dind` image. |
| Jobs stuck "waiting" | No runner with a matching label: compare `runs-on` with `GITEA_RUNNER_LABELS`. |
| Disk filling up | `sudo 1s runners prune`; lower `GITEA_RUNNER_PRUNE_AFTER`; check `docker system df`. |

## Lockout recovery

- **Web UI**: allowlists never affect sshd. Use admin SSH: `sudo 1s ip-access add gitea <ip>`.
- **Admin SSH lost**: use the provider's console/rescue system. Nothing in 1s
  touches your admin account or sshd configuration.
- **Broken Nginx configuration**: `sudo 1s nginx test`. The previous generation
  is kept under `/etc/1s/nginx/generations`. Re-render with `sudo 1s nginx apply`.

## Collecting information

```bash
sudo 1s status
sudo 1s health
sudo 1s firewall status
sudo tail -n 200 /var/log/1s/gateway.log
docker logs --tail 200 1s-nginx
```
