#!/usr/bin/env bash
# Validate every Compose file (docker compose config) and run the real
# `nginx -t` against a fully rendered configuration. Needs a Docker daemon.
# The temporary directory lives inside the repository so it can be bind-mounted
# even when this script itself runs in a container sharing the host daemon.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"
# shellcheck source=tests/lib.sh
source "${TESTS_DIR}/lib.sh"

TMP="$(mktemp -d "${REPO}/.tmp-tests.XXXXXX")"
chmod 0755 "${TMP}"
trap 'rm -rf -- "${TMP}"' EXIT
export ONES_ETC="${TMP}/etc" ONES_VAR="${TMP}/var" ONES_OPT="${TMP}/opt" ONES_LOCK_DIR="${TMP}/lock" ONES_PREFIX=1s-validate

# shellcheck source=scripts/lib/nginx.sh
source "${REPO}/scripts/lib/nginx.sh"
env_load "${TESTS_DIR}/fixtures/test.env"
config_apply_defaults

echo "== docker compose config"
cat >"${TMP}/compose.env" <<EOF
ONES_PREFIX=1s-validate
ONES_ETC=${ONES_ETC}
ONES_VAR=${ONES_VAR}
NGINX_IMAGE=${NGINX_IMAGE}
GITEA_IMAGE=${GITEA_IMAGE}
GITEA_POSTGRES_IMAGE=${GITEA_POSTGRES_IMAGE}
GITEA_LOCAL_PORT=${GITEA_LOCAL_PORT}
GITEA_SSH_BIND_IP=${GITEA_SSH_BIND_IP}
GITEA_SSH_BIND_IP6=${GITEA_SSH_BIND_IP6}
GITEA_SSH_PORT=${GITEA_SSH_PORT}
GITEA_NETWORK_SUBNET=${GITEA_NETWORK_SUBNET}
GITEA_DOMAIN=${GITEA_DOMAIN}
GITEA_RUNNER_IMAGE=${GITEA_RUNNER_IMAGE}
GITEA_RUNNER_LABELS=${GITEA_RUNNER_LABELS}
RUNNER_INDEX=1
RUNNER_NAME=validate-runner-1
RUNNER_SUBNET=10.203.1.0/24
RUNNER_RUNTIME_DIR=${TMP}/runner
OPENHANDS_IMAGE=${OPENHANDS_IMAGE}
OH_USER=alice
OH_LOCAL_PORT=28001
OH_SUBNET=10.204.1.0/24
OH_RUNTIME_DIR=${TMP}/oh
EOF
mkdir -p "${ONES_ETC}/runtime/gitea" "${TMP}/oh" "${TMP}/runner"
touch "${ONES_ETC}/runtime/gitea/db.env" "${ONES_ETC}/runtime/gitea/gitea.env" "${TMP}/oh/canvas.env"
cc() { docker compose --project-directory "${REPO}/compose/$1" --env-file "${TMP}/compose.env" "${@:2}" config -q; }
C="${REPO}/compose"
assert_ok "nginx compose"               cc nginx -f "${C}/nginx/compose.yml"
assert_ok "gitea compose"               cc gitea -f "${C}/gitea/compose.yml"
assert_ok "gitea compose + ipv6 ssh"    cc gitea -f "${C}/gitea/compose.yml" -f "${C}/gitea/compose.ssh-ipv6.yml"
assert_ok "runner compose (rootless)"   cc gitea-runners -f "${C}/gitea-runners/compose.yml" -f "${C}/gitea-runners/compose.rootless.yml"
assert_ok "runner compose (privileged)" cc gitea-runners -f "${C}/gitea-runners/compose.yml" -f "${C}/gitea-runners/compose.privileged.yml"
assert_ok "openhands compose (hardened)" cc openhands -f "${C}/openhands/compose.yml" -f "${C}/openhands/compose.hardened.yml"
assert_ok "openhands compose (sudo)"    cc openhands -f "${C}/openhands/compose.yml" -f "${C}/openhands/compose.sudo.yml"

# Security properties of the rendered compose models.
model() { docker compose --project-directory "${C}/$1" --env-file "${TMP}/compose.env" "${@:2}" config --format json; }
m="$(model gitea-runners -f "${C}/gitea-runners/compose.yml" -f "${C}/gitea-runners/compose.rootless.yml")"
assert_eq "rootless runner not privileged" "false" "$(jq -r '.services.runner.privileged // false' <<<"${m}")"
assert_eq "rootless runner adds no caps" "0" "$(jq -r '.services.runner.cap_add // [] | length' <<<"${m}")"
assert_eq "no docker socket in runner" "0" "$(jq -r '[.services.runner.volumes[]? | select(.source // "" | test("docker.sock"))] | length' <<<"${m}")"
m="$(model openhands -f "${C}/openhands/compose.yml" -f "${C}/openhands/compose.hardened.yml")"
assert_eq "openhands drops all caps" '["ALL"]' "$(jq -c '.services.canvas.cap_drop' <<<"${m}")"
assert_eq "openhands no-new-privileges" "true" "$(jq -r '[.services.canvas.security_opt[] | select(startswith("no-new-privileges"))] | length > 0' <<<"${m}")"
assert_eq "openhands bound to loopback" "127.0.0.1" "$(jq -r '.services.canvas.ports[0].host_ip' <<<"${m}")"
assert_eq "no docker socket in openhands" "0" "$(jq -r '[.services.canvas.volumes[]? | select(.source // "" | test("docker.sock"))] | length' <<<"${m}")"
m="$(model gitea -f "${C}/gitea/compose.yml")"
assert_eq "gitea http on loopback" "127.0.0.1" "$(jq -r '.services.gitea.ports[] | select(.target == 3000) | .host_ip' <<<"${m}")"
assert_eq "gitea ssh on explicit IP" "${GITEA_SSH_BIND_IP}" "$(jq -r '.services.gitea.ports[] | select(.target == 2222) | .host_ip' <<<"${m}")"
assert_eq "database network internal" "true" "$(jq -r '.networks.backend.internal' <<<"${m}")"

echo "== nginx -t on a rendered configuration"
mkdir -p "${ONES_VAR}/state" "${ACCESS_DIR}"
touch "${ONES_VAR}/state/gitea.deployed" "${ONES_VAR}/state/openhands.deployed"
printf '198.51.100.10\n2001:db8:1::/48\n' >"${ACCESS_DIR}/gitea.allow"
oh_user_index alice >/dev/null; oh_user_index bob >/dev/null
for d in "${GITEA_DOMAIN}" "${OPENHANDS_DOMAIN}"; do
  bash "${REPO}/scripts/certificates/certs.sh" ensure "${d}" >/dev/null 2>&1
done
gen="validate-$$"
nginx_render "${NGINX_DIR}/generations/${gen}"
chmod -R a+rX "${ONES_ETC}"
# Disposable network namespace that owns the configured bind addresses.
ntest() {
  docker run --rm --network none --cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv6.conf.lo.disable_ipv6=0 --entrypoint sh \
    -v "${NGINX_DIR}:/etc/nginx/1s:ro" -v "${TLS_DIR}:/etc/nginx/tls:ro" "${NGINX_IMAGE}" -c "
      ip addr add ${GITEA_BIND_IP}/32 dev lo && ip addr add ${OPENHANDS_BIND_IP}/32 dev lo &&
      ip -6 addr add ${GITEA_BIND_IP6}/128 dev lo && nginx -t -c /etc/nginx/1s/generations/${gen}/nginx.conf"
}
if out="$(ntest 2>&1)"; then
  pass "nginx -t accepts the rendered configuration"
else
  fail "nginx -t accepts the rendered configuration" "${out}"
fi
cp -a "${NGINX_DIR}/generations/${gen}" "${TMP}/good"
printf 'server { listen 192.0.2.99:443 ssl; }\n' >"${NGINX_DIR}/generations/${gen}/servers/90-bad.conf"
if ntest >/dev/null 2>&1; then fail "nginx -t rejects an unavailable bind address"; else pass "nginx -t rejects an unavailable bind address"; fi
rm -f "${NGINX_DIR}/generations/${gen}/servers/90-bad.conf"
printf 'this is not nginx syntax\n' >>"${NGINX_DIR}/generations/${gen}/servers/10-gitea.conf"
if ntest >/dev/null 2>&1; then fail "nginx -t rejects a syntax error"; else pass "nginx -t rejects a syntax error"; fi

summary
