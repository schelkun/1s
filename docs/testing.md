# Testing

All tests run in Linux containers (macOS Bash 3.2 is too old) and only create
resources named `1s-test-*` / `1s-e2e-*` / `1s-validate-*`.

```bash
docker build -t 1s-test-toolbox:local tests/docker            # ~450 MB Alpine toolbox

# Static (no Docker daemon access needed)
docker run --rm -v "$PWD":/src:ro -w /src 1s-test-toolbox:local bash tests/shellcheck.sh
docker run --rm -v "$PWD":/src:ro -w /src 1s-test-toolbox:local bash tests/unit.sh

# Compose validation + real `nginx -t` (pulls nginx, ~60 MB)
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD:$PWD" -w "$PWD" \
  1s-test-toolbox:local bash tests/validate-configs.sh

# Real-host checks on any Linux machine, as root. Firewall rules are built in a
# private network namespace; nothing is installed and the host firewall is untouched.
sudo tests/host-checks.sh

# End to end (~1 GB in a temporary volume; removed afterwards)
docker run --rm --name 1s-e2e-ci -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" 1s-test-toolbox:local bash tests/e2e/run.sh
# add -e E2E_OPENHANDS=1 to include OpenHands (+3.8 GB image); -e KEEP=1 to keep resources
```

| Suite | Covers |
|---|---|
| `shellcheck.sh` | every shell script |
| `unit.sh` | IPv4/IPv6/CIDR validation and normalisation; dotenv parsing never executes code; configuration rules (collisions, pools, required secrets); per-user key derivation; Nginx rendering (explicit listeners, default deny, allowlists, XFF handling, SNI rejection); `ip-access` add/remove/idempotency/validation and **rollback on invalid Nginx config**; gateway rejection of malformed/injected commands; bundle filtering and validation |
| `validate-configs.sh` | `docker compose config` for every stack and overlay; security properties of the rendered models (no privileged, no socket, loopback ports, internal DB network); real `nginx -t` with the bind addresses present; rejection of bad configs |
| `host-checks.sh` | firewall chains on the real kernel/iptables (Git-SSH allowlist, egress blocks, idempotent re-apply, clean removal, host firewall unchanged); systemd calendar and unit syntax; sudoers rule; AppArmor version branch; `/dev/net/tun` |
| `e2e/run.sh` | a simulated server (privileged test container with its own dockerd and sshd), Pebble ACME CA and DNS, an operator/CI container and two clients. Bootstrap; temporary deploy access (disabled/enabled, forced command, no forwarding, admin unaffected); `ci-run.sh` deployment exactly as in Actions; ACME HTTP-01 issuance and forced renewal with reload; 403/200 by allowlist, XFF spoofing, ACME path, redirects; Git-over-SSH firewall allowlist; runner registration and a real job in the private rootless daemon; idempotent redeploy without restarts; runner scaling with deregistration; backup, verification and restore; lockout recovery; release rollback; health via the gateway |

The end-to-end test needs `--privileged` for the simulated server container only
(nested dockerd and iptables), on your local Docker. Nothing it does touches
other containers, images, networks or volumes.
