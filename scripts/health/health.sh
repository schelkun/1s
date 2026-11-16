#!/usr/bin/env bash
# Health checks: health.sh [shared|gitea|openhands|all]
# Exit 0 when everything is healthy, 1 otherwise. Certificate expiry and
# temporary certificates are reported as warnings.
set -uo pipefail

# shellcheck source=scripts/lib/deploy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/deploy.sh"

FAILS=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS + 1)); }
note() { printf '  [WARN] %s\n' "$*"; }

http_code() { curl -sk -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null || echo 000; }

check_container() {
  local s; s="$(container_health "$1")"
  if [[ "${s}" == healthy || "${s}" == running ]]; then ok "$1 ${s}"; else bad "$1 ${s}"; fi
}

# Requests from the server itself use the bind IP as source address, which is
# not on any allowlist unless you added it: they must get 403.
check_vhost() { # NAME DOMAIN IP PORT
  local name="$1" domain="$2" ip="$3" port="$4" host="$2" code url
  [[ "${ip}" == *:* ]] && ip="[${ip}]"
  [[ "${port}" == 443 ]] || host="${domain}:${port}"
  url="https://${host}"
  code="$(http_code --resolve "${domain}:${port}:${ip//[\[\]]/}" "${url}/.1s/healthz")"
  [[ "${code}" == 200 ]] && ok "${name}: Nginx ${ip}:${port} answers" || bad "${name}: Nginx health on ${ip}:${port} returned ${code}"
  code="$(http_code --resolve "${domain}:${port}:${ip//[\[\]]/}" "${url}/")"
  case "${code}" in
    403) ok "${name}: default deny active (403 for non-allowlisted source)" ;;
    000) bad "${name}: no response from ${url}" ;;
    *)   note "${name}: ${url}/ returned ${code} for this server's own address (is it allowlisted?)" ;;
  esac
}

check_shared() {
  echo "shared:"
  if nginx_running; then
    ok "nginx running"
    docker exec "${NGINX_CONTAINER}" nginx -t -q 2>/dev/null && ok "nginx configuration valid" || bad "nginx -t failed"
  else
    bad "nginx not running"
  fi
  "${ONES_ROOT}/scripts/certificates/certs.sh" check --quiet >/dev/null 2>&1 \
    && ok "certificates valid" || note "certificate attention needed: sudo 1s certs check"
  if command -v iptables >/dev/null && [[ "${EUID}" -eq 0 ]]; then
    iptables -w -S DOCKER-USER 2>/dev/null | grep -q -- '-j ONES-DU-' && ok "firewall hooks present" || bad "firewall hooks missing (sudo 1s firewall apply)"
  fi
}

check_gitea() {
  echo "gitea:"
  check_container "${ONES_PREFIX}-gitea-db"
  check_container "${ONES_PREFIX}-gitea"
  local code
  code="$(http_code "http://127.0.0.1:${GITEA_LOCAL_PORT}/api/healthz")"
  [[ "${code}" == 200 ]] && ok "gitea /api/healthz" || bad "gitea /api/healthz returned ${code}"
  check_vhost gitea "${GITEA_DOMAIN}" "${GITEA_BIND_IP}" 443
  if is_true "${ENABLE_IPV6}" && [[ -n "${GITEA_BIND_IP6:-}" ]]; then check_vhost gitea "${GITEA_DOMAIN}" "${GITEA_BIND_IP6}" 443; fi
  if timeout 5 bash -c "exec 3<>/dev/tcp/${GITEA_SSH_BIND_IP}/${GITEA_SSH_PORT}; head -c 7 <&3" 2>/dev/null | grep -q '^SSH-2.0'; then
    ok "git ssh ${GITEA_SSH_BIND_IP}:${GITEA_SSH_PORT}"
  else
    note "git ssh ${GITEA_SSH_BIND_IP}:${GITEA_SSH_PORT} not reachable from the host (expected if this host is not allowlisted for gitea-ssh)"
  fi
  local i c
  for ((i = 1; i <= GITEA_RUNNER_COUNT; i++)); do
    c="${ONES_PREFIX}-gitea-runner-${i}"
    if [[ "$(container_health "${c}")" == running ]] && docker exec "${c}" test -s /data/.runner 2>/dev/null; then
      ok "${c} running and registered"
    else
      bad "${c} not running or not registered"
    fi
  done
}

check_openhands() {
  echo "openhands:"
  local user port idx lp code
  while read -r user port; do
    idx="$(oh_user_index_get "${user}")"
    [[ -n "${idx}" ]] || { bad "openhands ${user}: not deployed"; continue; }
    lp="$(oh_local_port "${idx}")"
    check_container "${ONES_PREFIX}-openhands-${user}"
    code="$(http_code "http://127.0.0.1:${lp}/alive")"
    [[ "${code}" == 200 ]] && ok "openhands ${user} /alive" || bad "openhands ${user} /alive returned ${code}"
    code="$(http_code "http://127.0.0.1:${lp}/api/settings")"
    [[ "${code}" == 401 || "${code}" == 403 ]] && ok "openhands ${user} API requires a key" || bad "openhands ${user} API answered ${code} without a key"
    check_vhost "openhands ${user}" "${OPENHANDS_DOMAIN}" "${OPENHANDS_BIND_IP}" "${port}"
  done < <(oh_users)
}

main() {
  config_load_server
  local target="${1:-all}"
  case "${target}" in
    shared)    check_shared ;;
    gitea|openhands)
               if component_deployed "${target}"; then "check_${target}"; else echo "${target}: not deployed"; fi ;;
    all)       check_shared
               if component_deployed gitea; then check_gitea; fi
               if component_deployed openhands; then check_openhands; fi ;;
    *) die "usage: health.sh [shared|gitea|openhands|all]" ;;
  esac
  if (( FAILS )); then echo "RESULT: ${FAILS} check(s) failed"; exit 1; fi
  echo "RESULT: healthy"
}

main "$@"
