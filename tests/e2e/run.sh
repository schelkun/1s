#!/usr/bin/env bash
# End-to-end test of the real deployment path on a simulated Ubuntu server.
#
# Start it from the repository root (it needs the host Docker socket and the
# repository mounted at the same path):
#
#   docker run --rm --name 1s-e2e-ci -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "$PWD:$PWD" -w "$PWD" 1s-test-toolbox:local bash tests/e2e/run.sh
#
# It only creates resources named 1s-e2e-* (containers, one network, one volume)
# and removes them at the end (KEEP=1 keeps them for debugging).
#
#   10.250.0.5   Pebble ACME CA          10.250.0.6  DNS (challtestsrv)
#   10.250.0.10  "server" (sshd, dockerd; .11 Gitea IP, .12 OpenHands IP)
#   10.250.0.40  this container: GitHub Actions runner + macOS operator
#   10.250.0.50  allowlisted client      10.250.0.51 non-allowlisted client
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"
# shellcheck source=tests/lib.sh
source "${TESTS_DIR}/lib.sh"

NET=1s-e2e-net
HOST=1s-e2e-host
VOL=1s-e2e-docker
SELF="${E2E_SELF:-1s-e2e-ci}"
WORK="${REPO}/.tmp-e2e"
# The server pulls its images itself, exactly like production (no duplicate
# copies on the host). OpenHands (3.8 GB image) only runs with E2E_OPENHANDS=1.
E2E_OPENHANDS="${E2E_OPENHANDS:-0}"
oh() { [[ "${E2E_OPENHANDS}" == 1 ]]; }
PEBBLE_IMG=ghcr.io/letsencrypt/pebble:2.9.0
CHALL_IMG=ghcr.io/letsencrypt/pebble-challtestsrv:2.9.0
TOOLBOX=1s-test-toolbox:local

step() { printf '\n### %s  (%s)\n' "$*" "$(date -u +%H:%M:%S)"; }
hx() { docker exec "${HOST}" "$@"; }                        # run on the server as root
cx() { local c="$1"; shift; docker exec "${c}" "$@"; }      # run in a client

cleanup() {
  [[ "${KEEP:-0}" == 1 ]] && { echo "KEEP=1: leaving 1s-e2e-* resources in place"; return; }
  step "cleanup (only 1s-e2e-* resources)"
  docker network disconnect -f "${NET}" "${SELF}" >/dev/null 2>&1 || true
  for c in "${HOST}" 1s-e2e-pebble 1s-e2e-chall 1s-e2e-client-ok 1s-e2e-client-bad; do
    docker container rm -f "${c}" >/dev/null 2>&1 || true
  done
  docker network rm "${NET}" >/dev/null 2>&1 || true
  docker volume rm "${VOL}" >/dev/null 2>&1 || true
  rm -rf -- "${WORK}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
step "infrastructure: network, ACME CA, DNS, server, clients"
KEEP=0 cleanup >/dev/null 2>&1   # always start from a clean slate
mkdir -p "${WORK}"; chmod 0700 "${WORK}"
docker network create --subnet 10.250.0.0/24 "${NET}" >/dev/null
docker network connect --ip 10.250.0.40 "${NET}" "${SELF}"
cat >"${WORK}/pebble.json" <<'EOF'
{"pebble": {"listenAddress": "0.0.0.0:14000", "managementListenAddress": "0.0.0.0:15000",
  "certificate": "test/certs/localhost/cert.pem", "privateKey": "test/certs/localhost/key.pem",
  "httpPort": 80, "tlsPort": 443, "ocspResponderURL": "", "externalAccountBindingRequired": false}}
EOF
chmod 0644 "${WORK}/pebble.json"
docker run -d --name 1s-e2e-chall --network "${NET}" --ip 10.250.0.6 "${CHALL_IMG}" \
  -defaultIPv4 "" -defaultIPv6 "" -http01 "" -https01 "" -tlsalpn01 "" -doh "" >/dev/null
docker run -d --name 1s-e2e-pebble --network "${NET}" --ip 10.250.0.5 -e PEBBLE_VA_NOSLEEP=1 \
  -v "${WORK}/pebble.json:/test/e2e-config.json:ro" "${PEBBLE_IMG}" \
  -config /test/e2e-config.json -dnsserver 10.250.0.6:8053 >/dev/null
docker cp 1s-e2e-pebble:/test/certs/pebble.minica.pem "${WORK}/pebble.minica.pem"
for name in git.e2e.test:10.250.0.11 ai.e2e.test:10.250.0.12; do
  curl -fsS -X POST -d "{\"host\":\"${name%%:*}.\",\"addresses\":[\"${name##*:}\"]}" http://10.250.0.6:8055/add-a >/dev/null
done
for c in ok:50 bad:51; do
  docker run -d --name "1s-e2e-client-${c%%:*}" --network "${NET}" --ip "10.250.0.${c##*:}" "${TOOLBOX}" sleep infinity >/dev/null
done

ssh-keygen -q -t ed25519 -N "" -f "${WORK}/admin_key"
docker run -d --name "${HOST}" --hostname e2e-host --privileged --network "${NET}" --ip 10.250.0.10 \
  -v "${VOL}:/var/lib/docker" "${TOOLBOX}" sleep infinity >/dev/null
docker exec "${HOST}" mkdir -p /e2e
docker cp "${WORK}/pebble.minica.pem" "${HOST}:/e2e/pebble.minica.pem"
docker cp "${REPO}/tests/e2e/host-setup.sh" "${HOST}:/e2e/host-setup.sh"
hx bash /e2e/host-setup.sh "$(cat "${WORK}/admin_key.pub")" || { echo "server setup failed"; exit 1; }

# ---------------------------------------------------------------------------
step "operator side: repository commit, keys, SSH"
SRC="${WORK}/src"; mkdir -p "${SRC}"
tar -C "${REPO}" --exclude=.git --exclude=.env --exclude='.tmp-*' -cf - . | tar -C "${SRC}" -xf -
git -C "${SRC}" init -q -b main
git -C "${SRC}" add -A && git -C "${SRC}" -c user.name=e2e -c user.email=e2e@example.com commit -qm "release A"
SHA_A="$(git -C "${SRC}" rev-parse HEAD)"
ssh-keyscan -T 10 10.250.0.10 2>/dev/null >"${WORK}/known_hosts"
ssh-keygen -q -t ed25519 -N "" -f "${WORK}/deploy_key"
ADMIN_SSH=(ssh -i "${WORK}/admin_key" -o IdentitiesOnly=yes -o UserKnownHostsFile="${WORK}/known_hosts" -o StrictHostKeyChecking=yes -o BatchMode=yes admin@10.250.0.10)
DEPLOY_SSH=(ssh -T -i "${WORK}/deploy_key" -o IdentitiesOnly=yes -o UserKnownHostsFile="${WORK}/known_hosts" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10 deploy@10.250.0.10)
assert_ok "admin SSH with verified host key" "${ADMIN_SSH[@]}" true

step "bootstrap the server (as the admin would)"
tar -C "${SRC}" -cf - . | "${ADMIN_SSH[@]}" "rm -rf /tmp/1s-src && mkdir -p /tmp/1s-src && tar -xf - -C /tmp/1s-src"
if "${ADMIN_SSH[@]}" "sudo bash /tmp/1s-src/scripts/server/bootstrap.sh --skip-packages" >"${WORK}/bootstrap.log" 2>&1; then
  pass "bootstrap.sh"
else
  fail "bootstrap.sh" "$(tail -20 "${WORK}/bootstrap.log")"; exit 1
fi
assert_ok "bootstrap is idempotent" "${ADMIN_SSH[@]}" "sudo bash /tmp/1s-src/scripts/server/bootstrap.sh --skip-packages"
assert_fail "deploy user not in docker group" hx sh -c 'id -nG deploy | grep -qw docker'
assert_eq "deploy home owned by root" "root" "$(hx stat -c %U /home/deploy/.ssh/authorized_keys)"

step "temporary deployment access"
"${ADMIN_SSH[@]}" "sudo 1s deploy-access install-key '$(cut -d' ' -f1,2 "${WORK}/deploy_key.pub")'" >/dev/null
assert_fail "deploy key rejected while disabled" "${DEPLOY_SSH[@]}" ping
assert_ok   "enable access (admin)" "${ADMIN_SSH[@]}" "sudo 1s deploy-access enable"
assert_eq   "gateway ping" "pong" "$("${DEPLOY_SSH[@]}" ping 2>/dev/null)"
out="$("${DEPLOY_SSH[@]}" "bash -c id" 2>&1)"; [[ "${out}" == *rejected* ]] && pass "arbitrary command rejected" || fail "arbitrary command rejected" "${out}"
out="$("${DEPLOY_SSH[@]}" 'deploy gitea $(id)' 2>&1)"; [[ "${out}" == *rejected* ]] && pass "injection rejected" || fail "injection rejected" "${out}"
"${DEPLOY_SSH[@]}" -N -L 127.0.0.1:47001:127.0.0.1:22 >/dev/null 2>&1 &
fwd_pid=$!; sleep 3
fwd="$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/47001; head -c 7 <&3' 2>/dev/null || true)"
kill "${fwd_pid}" 2>/dev/null; wait "${fwd_pid}" 2>/dev/null
assert_eq "port forwarding refused (no tunnel to the server's sshd)" "" "${fwd}"
assert_fail "deploy user cannot sudo anything else" hx runuser -u deploy -- sudo -n /bin/true
assert_ok   "disable access" "${ADMIN_SSH[@]}" "sudo 1s deploy-access disable"
assert_fail "deploy key rejected after disable" "${DEPLOY_SSH[@]}" ping
assert_ok   "admin access unaffected" "${ADMIN_SSH[@]}" true
"${ADMIN_SSH[@]}" "sudo 1s deploy-access enable" >/dev/null

# ---------------------------------------------------------------------------
step "configuration (scripts/macos/push-config.sh equivalent)"
hx sh -c 'curl -fsSk https://10.250.0.5:15000/roots/0 >/etc/1s/e2e-pebble-root.pem'
cat >"${WORK}/vars.env" <<'EOF'
ACME_EMAIL=ops@one-s.dev
ACME_SERVER=https://pebble:14000/dir
ACME_SKIP_DNS_CHECK=true
GITEA_DOMAIN=git.e2e.test
GITEA_BIND_IP=10.250.0.11
GITEA_SSH_PORT=2222
GITEA_ADMIN_EMAIL=admin@one-s.dev
GITEA_CPUS=2
GITEA_MEMORY=1g
GITEA_DB_MEMORY=512m
GITEA_RUNNER_COUNT=1
GITEA_RUNNER_CPUS=1
GITEA_RUNNER_MEMORY=1g
GITEA_RUNNER_LABELS=e2e:docker://alpine:3.22
GITEA_RUNNER_CA_FILE=/etc/1s/e2e-pebble-root.pem
GITEA_RUNNER_SHUTDOWN_TIMEOUT=60s
OPENHANDS_DOMAIN=ai.e2e.test
OPENHANDS_BIND_IP=10.250.0.12
OPENHANDS_USERS=alice:443,bob:8444
OPENHANDS_MEMORY=1536m
OPENHANDS_CPUS=1
GITEA_ADMIN_PASSWORD=E2eAdminPassw0rd42
EOF
if oh; then echo ENABLE_OPENHANDS=true; else echo ENABLE_OPENHANDS=false; fi >>"${WORK}/vars.env"
# Same as scripts/macos/push-config.sh: the server stores it and generates the other secrets.
push_config() { "${ADMIN_SSH[@]}" "sudo 1s config import" <"${WORK}/vars.env"; }
assert_ok "config import (other secrets generated on the server)" push_config
assert_fail "invalid config rejected" "${ADMIN_SSH[@]}" "printf 'ACME_EMAIL=x\n' | sudo 1s config import"
assert_eq "admin password readable by the admin" E2eAdminPassw0rd42 "$("${ADMIN_SSH[@]}" "sudo 1s config secret GITEA_ADMIN_PASSWORD")"
mkdir -p ~/.ssh
cat >~/.ssh/config <<EOF
Host 1s-server
  HostName 10.250.0.10
  User deploy
  IdentityFile ${WORK}/deploy_key
  IdentitiesOnly yes
  UserKnownHostsFile ${WORK}/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
EOF
# Runners resolve the Gitea domain like any client would (test-only overlay).
hx sh -c 'mkdir -p /etc/1s/overrides && printf "services:\n  runner:\n    extra_hosts: [\"git.e2e.test:10.250.0.11\"]\n" >/etc/1s/overrides/gitea-runners.yml'

step "deploy all (scripts/deploy/ci-run.sh, exactly as GitHub Actions runs it)"
if (cd "${SRC}" && bash scripts/deploy/ci-run.sh all deploy) >"${WORK}/deploy1.log" 2>&1; then
  pass "deploy all"
else
  fail "deploy all" "$(tail -40 "${WORK}/deploy1.log")"
  hx docker ps -a; exit 1
fi
grep -E 'RESULT|FAIL|WARN' "${WORK}/deploy1.log" | sed 's/^/    /'

# ---------------------------------------------------------------------------
step "TLS via acme.sh (Pebble)"
issuer() { cx 1s-e2e-client-bad sh -c "echo | openssl s_client -connect $1 -servername $2 2>/dev/null | openssl x509 -noout -issuer"; }
[[ "$(issuer 10.250.0.11:443 git.e2e.test)" == *Pebble* ]] && pass "gitea certificate issued by ACME CA" || fail "gitea certificate issued by ACME CA" "$(issuer 10.250.0.11:443 git.e2e.test)"
if oh; then [[ "$(issuer 10.250.0.12:8444 ai.e2e.test)" == *Pebble* ]] && pass "openhands certificate issued by ACME CA" || fail "openhands certificate issued by ACME CA"; fi
assert_fail "no temporary certificate left" hx test -e /etc/1s/tls/git.e2e.test/.placeholder
assert_eq "key file is 0600" "600" "$(hx stat -c %a /etc/1s/tls/git.e2e.test/key.pem)"

step "default deny, allowlists and client IP handling"
code() { local c="$1"; shift; cx "${c}" curl -sk -o /dev/null -w '%{http_code}' -m 15 "$@"; }
G=(--resolve git.e2e.test:443:10.250.0.11); GU=https://git.e2e.test
A=(--resolve ai.e2e.test:443:10.250.0.12); AU=https://ai.e2e.test
B=(--resolve ai.e2e.test:8444:10.250.0.12); BU=https://ai.e2e.test:8444
assert_eq "gitea 403 before allowlisting" 403 "$(code 1s-e2e-client-ok "${G[@]}" "${GU}/")"
oh && assert_eq "openhands 403 before allowlisting" 403 "$(code 1s-e2e-client-ok "${A[@]}" "${AU}/canvas/")"
"${ADMIN_SSH[@]}" "sudo 1s ip-access add gitea 10.250.0.50 --comment e2e && sudo 1s ip-access add openhands 10.250.0.50" >/dev/null
assert_eq "gitea 200 for allowlisted client" 200 "$(code 1s-e2e-client-ok "${G[@]}" "${GU}/user/login")"
assert_eq "gitea 403 for other client" 403 "$(code 1s-e2e-client-bad "${G[@]}" "${GU}/user/login")"
assert_eq "spoofed X-Forwarded-For ignored" 403 "$(code 1s-e2e-client-bad -H 'X-Forwarded-For: 10.250.0.50' -H 'X-Real-IP: 10.250.0.50' "${G[@]}" "${GU}/")"
assert_eq "health endpoint open" 200 "$(code 1s-e2e-client-bad "${G[@]}" "${GU}/.1s/healthz")"
assert_eq "ACME path reachable on :80 (404 for unknown token)" 404 "$(code 1s-e2e-client-bad --resolve git.e2e.test:80:10.250.0.11 http://git.e2e.test/.well-known/acme-challenge/x)"
assert_eq "http redirects to https" 301 "$(code 1s-e2e-client-bad --resolve git.e2e.test:80:10.250.0.11 http://git.e2e.test/)"
assert_eq "unknown host on :80 dropped" 000 "$(code 1s-e2e-client-ok http://10.250.0.11/)"
if oh; then
assert_eq "openhands alice 200" 200 "$(code 1s-e2e-client-ok "${A[@]}" "${AU}/canvas/")"
assert_eq "openhands bob 200" 200 "$(code 1s-e2e-client-ok "${B[@]}" "${BU}/canvas/")"
assert_eq "openhands 403 for other client" 403 "$(code 1s-e2e-client-bad "${B[@]}" "${BU}/canvas/")"
fi
assert_eq "gitea not served on openhands IP" 000 "$(code 1s-e2e-client-ok --resolve git.e2e.test:443:10.250.0.12 https://git.e2e.test/)"
assert_fail "gitea list independent of openhands" "${ADMIN_SSH[@]}" "sudo 1s ip-access check gitea 10.250.0.51"
NGINX_LOG="$(hx docker logs 1s-nginx 2>&1)"
assert_ok "nginx logs the real allowed client IP" grep -qE '^10\.250\.0\.50 .*"GET /user/login [^"]*" 200 ' <<<"${NGINX_LOG}"
assert_ok "spoofed request logged with the real source IP" grep -qE '^10\.250\.0\.51 .*"GET / [^"]*" 403 ' <<<"${NGINX_LOG}"

if oh; then
step "OpenHands authentication and per-user isolation"
KEY_A="$("${ADMIN_SSH[@]}" "sudo 1s openhands key alice")"
KEY_B="$("${ADMIN_SSH[@]}" "sudo 1s openhands key bob")"
assert_eq "API without key -> 401" 401 "$(code 1s-e2e-client-ok "${A[@]}" "${AU}/api/settings")"
assert_eq "alice key on alice -> 200" 200 "$(code 1s-e2e-client-ok -H "X-Session-API-Key: ${KEY_A}" "${A[@]}" "${AU}/api/settings")"
assert_eq "alice key on bob -> 401" 401 "$(code 1s-e2e-client-ok -H "X-Session-API-Key: ${KEY_A}" "${B[@]}" "${BU}/api/settings")"
assert_eq "bob key on bob -> 200" 200 "$(code 1s-e2e-client-ok -H "X-Session-API-Key: ${KEY_B}" "${B[@]}" "${BU}/api/settings")"
assert_ok "key not embedded in the page" sh -c "! docker exec 1s-e2e-client-ok curl -sk ${A[*]} ${AU}/canvas/ | grep -q '${KEY_A}'"
assert_fail "agent cannot sudo" hx docker exec 1s-openhands-alice sudo -n true
BOB_IP="$(hx docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 1s-openhands-bob)"
assert_fail "alice cannot reach bob's container" hx docker exec 1s-openhands-alice curl -s -m 5 "http://${BOB_IP}:8000/alive"
assert_fail "alice cannot reach host sshd" hx docker exec 1s-openhands-alice bash -c 'timeout 5 bash -c "exec 3<>/dev/tcp/10.250.0.10/22"'
assert_fail "alice cannot reach gitea" hx docker exec 1s-openhands-alice curl -sk -m 5 --resolve git.e2e.test:443:10.250.0.11 https://git.e2e.test/
assert_fail "alice cannot reach bob's loopback port" hx docker exec 1s-openhands-alice curl -s -m 5 http://10.250.0.10:28002/alive
assert_fail "no docker socket in agent" hx docker exec 1s-openhands-alice test -S /var/run/docker.sock
fi

step "Git-over-SSH allowlist (firewall)"
banner() { cx "$1" timeout 6 bash -c 'exec 3<>/dev/tcp/10.250.0.11/2222; head -c 7 <&3' 2>/dev/null; }
assert_eq "git ssh denied by default" "" "$(banner 1s-e2e-client-ok)"
"${ADMIN_SSH[@]}" "sudo 1s ip-access add gitea-ssh 10.250.0.50" >/dev/null
assert_eq "git ssh allowed after add" "SSH-2.0" "$(banner 1s-e2e-client-ok)"
assert_eq "git ssh still denied for others" "" "$(banner 1s-e2e-client-bad)"

step "Gitea Actions runner executes a job in its private daemon"
API=(--resolve git.e2e.test:443:10.250.0.11 -u "gitea-admin:E2eAdminPassw0rd42" -H 'Content-Type: application/json')
api() { cx 1s-e2e-client-ok curl -sk -m 30 "${API[@]}" "$@"; }
nr="$(api https://git.e2e.test/api/v1/admin/actions/runners | jq -r '.total_count // (.runners | length) // 0')"
assert_eq "one runner registered" 1 "${nr}"
api -X POST https://git.e2e.test/api/v1/user/repos -d '{"name":"e2e","auto_init":true}' >/dev/null
wf="$(printf 'name: e2e\non: [push]\njobs:\n  hello:\n    runs-on: e2e\n    steps:\n      - run: echo "hello-from-1s" && id\n' | base64 -w0)"
api -X POST https://git.e2e.test/api/v1/repos/gitea-admin/e2e/contents/.gitea/workflows/e2e.yml \
  -d "{\"content\":\"${wf}\",\"message\":\"add workflow\"}" >/dev/null
result=""
for _ in $(seq 1 90); do
  result="$(api 'https://git.e2e.test/api/v1/repos/gitea-admin/e2e/actions/tasks' | jq -r '.workflow_runs[0].status // empty')"
  [[ "${result}" == success || "${result}" == failure || "${result}" == cancelled ]] && break
  sleep 5
done
assert_eq "workflow job succeeded" success "${result}"
assert_fail "runner container is not privileged" sh -c "[ \"\$(docker exec ${HOST} docker inspect -f '{{.HostConfig.Privileged}}' 1s-gitea-runner-1)\" = true ]"
assert_ok "runner token removed after registration" hx sh -c '[ ! -s /etc/1s/runtime/gitea-runners/1/registration-token ]'

step "independent lifecycles and idempotency"
started() { hx docker inspect -f '{{.State.StartedAt}}' "$1"; }
oh_before=""; oh && oh_before="$(started 1s-openhands-alice)"
gitea_before="$(started 1s-gitea)"; nginx_before="$(started 1s-nginx)"
if (cd "${SRC}" && bash scripts/deploy/ci-run.sh gitea deploy) >"${WORK}/deploy2.log" 2>&1; then pass "gitea redeploy"; else fail "gitea redeploy" "$(tail -20 "${WORK}/deploy2.log")"; fi
assert_eq "gitea not restarted by an unchanged redeploy" "${gitea_before}" "$(started 1s-gitea)"
oh && assert_eq "openhands untouched by gitea deploy" "${oh_before}" "$(started 1s-openhands-alice)"
assert_eq "nginx reloaded, not restarted" "${nginx_before}" "$(started 1s-nginx)"
assert_ok "pre-deployment backup recorded" hx test -s /var/lib/1s/state/gitea.predeploy-backup

step "runner pool scaling (1 -> 2 -> 1 with deregistration)"
sed -i 's/^GITEA_RUNNER_COUNT=.*/GITEA_RUNNER_COUNT=2/' "${WORK}/vars.env"; push_config >/dev/null
(cd "${SRC}" && bash scripts/deploy/ci-run.sh gitea deploy) >"${WORK}/deploy3.log" 2>&1 || fail "scale up deploy" "$(tail -20 "${WORK}/deploy3.log")"
assert_eq "two runners registered" 2 "$(api https://git.e2e.test/api/v1/admin/actions/runners | jq -r '.total_count // (.runners | length)')"
sed -i 's/^GITEA_RUNNER_COUNT=.*/GITEA_RUNNER_COUNT=1/' "${WORK}/vars.env"; push_config >/dev/null
(cd "${SRC}" && bash scripts/deploy/ci-run.sh gitea deploy) >"${WORK}/deploy4.log" 2>&1 || fail "scale down deploy" "$(tail -20 "${WORK}/deploy4.log")"
assert_eq "runner 2 deregistered" 1 "$(api https://git.e2e.test/api/v1/admin/actions/runners | jq -r '.total_count // (.runners | length)')"
assert_fail "runner 2 container removed" hx docker inspect 1s-gitea-runner-2

step "backup, integrity verification and restore"
assert_ok "backup via gateway" "${DEPLOY_SSH[@]}" backup gitea
BID="$(hx sh -c 'ls -1 /var/backups/1s/gitea | grep manual | tail -n1')"
assert_ok "backup verifies" hx /usr/local/sbin/1s backup verify gitea "${BID}"
assert_eq "backup dir is 0700" 700 "$(hx stat -c %a "/var/backups/1s/gitea/${BID}")"
api -X POST https://git.e2e.test/api/v1/user/repos -d '{"name":"after-backup"}' >/dev/null
assert_eq "repo created after backup" 200 "$(cx 1s-e2e-client-ok curl -sk -o /dev/null -w '%{http_code}' "${API[@]}" https://git.e2e.test/api/v1/repos/gitea-admin/after-backup)"
assert_fail "restore requires --yes" hx /usr/local/sbin/1s backup restore gitea "${BID}"
assert_ok "restore gitea" hx /usr/local/sbin/1s backup restore gitea "${BID}" --yes
assert_eq "post-backup repo gone after restore" 404 "$(cx 1s-e2e-client-ok curl -sk -o /dev/null -w '%{http_code}' "${API[@]}" https://git.e2e.test/api/v1/repos/gitea-admin/after-backup)"
assert_eq "pre-backup repo still there" 200 "$(cx 1s-e2e-client-ok curl -sk -o /dev/null -w '%{http_code}' "${API[@]}" https://git.e2e.test/api/v1/repos/gitea-admin/e2e)"
if oh; then
hx docker exec 1s-openhands-alice sh -c 'echo marker >/projects/marker.txt'
assert_ok "openhands backup" "${DEPLOY_SSH[@]}" backup openhands
OBID="$(hx sh -c 'ls -1 /var/backups/1s/openhands | grep manual | tail -n1')"
hx docker exec 1s-openhands-alice rm -f /projects/marker.txt
assert_ok "restore one openhands user" hx /usr/local/sbin/1s backup restore openhands "${OBID}" --yes --user alice --no-safety-backup
assert_eq "user data restored" marker "$(hx docker exec 1s-openhands-alice cat /projects/marker.txt 2>/dev/null)"
fi

step "certificate renewal and reload hook"
serial() { cx 1s-e2e-client-bad sh -c "echo | openssl s_client -connect 10.250.0.11:443 -servername git.e2e.test 2>/dev/null | openssl x509 -noout -serial"; }
s1="$(serial)"
assert_ok "forced renewal" hx /usr/local/sbin/1s certs issue git.e2e.test --force
s2="$(serial)"
[[ -n "${s2}" && "${s1}" != "${s2}" ]] && pass "nginx serves the renewed certificate" || fail "nginx serves the renewed certificate" "${s1} vs ${s2}"
assert_ok "cert check" hx /usr/local/sbin/1s certs check

step "lockout recovery through admin SSH"
"${ADMIN_SSH[@]}" "sudo 1s ip-access reset gitea --yes" >/dev/null
assert_eq "locked out" 403 "$(code 1s-e2e-client-ok "${G[@]}" "${GU}/user/login")"
"${ADMIN_SSH[@]}" "sudo 1s ip-access add gitea 10.250.0.50" >/dev/null
assert_eq "access restored" 200 "$(code 1s-e2e-client-ok "${G[@]}" "${GU}/user/login")"

step "release rollback"
echo "# release B" >>"${SRC}/README.md"
git -C "${SRC}" -c user.name=e2e -c user.email=e2e@example.com commit -qam "release B"
SHA_B="$(git -C "${SRC}" rev-parse HEAD)"
(cd "${SRC}" && bash scripts/deploy/ci-run.sh gitea deploy) >"${WORK}/deploy5.log" 2>&1 || fail "deploy release B" "$(tail -20 "${WORK}/deploy5.log")"
assert_eq "release B active" "${SHA_B}" "$(hx cat /var/lib/1s/state/gitea.release)"
(cd "${SRC}" && bash scripts/deploy/ci-run.sh gitea rollback) >"${WORK}/rollback.log" 2>&1 || fail "rollback" "$(tail -20 "${WORK}/rollback.log")"
assert_eq "release A active after rollback" "${SHA_A}" "$(hx cat /var/lib/1s/state/gitea.release)"
assert_eq "gitea healthy after rollback" 200 "$(code 1s-e2e-client-ok "${G[@]}" "${GU}/user/login")"

step "health and access teardown"
assert_ok "health all via gateway" "${DEPLOY_SSH[@]}" health all
"${ADMIN_SSH[@]}" "sudo 1s deploy-access disable" >/dev/null
assert_fail "deployment access disabled at the end" "${DEPLOY_SSH[@]}" ping

summary
