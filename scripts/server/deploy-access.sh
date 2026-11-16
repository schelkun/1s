#!/usr/bin/env bash
# Temporary deployment SSH access (run as root via the ADMIN SSH account).
#
#   deploy-access.sh install-key [KEY]      install the deployment PUBLIC key
#                                           (argument, or stdin when omitted)
#   deploy-access.sh enable [--ttl 2h]      allow the deploy key (auto-expires)
#   deploy-access.sh disable [--kill]       revoke it (--kill also ends sessions)
#   deploy-access.sh status
#
# The deploy key can only run the 1s gateway (forced command, no shell, no
# forwarding, no PTY). The administrative account is never modified here.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

env_load "${ONES_ETC}/bootstrap.env"   # DEPLOY_USER chosen at bootstrap
DEPLOY_USER="${DEPLOY_USER:-deploy}"
KEY_FILE="${ONES_ETC}/deploy/deploy_key.pub"
# The deploy user's home and ~/.ssh are owned by root (see bootstrap.sh), so
# only root can change which keys are accepted.
DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
AUTH_DIR="${DEPLOY_HOME:-/nonexistent}/.ssh"
AUTH_FILE="${AUTH_DIR}/authorized_keys"
GATEWAY="/usr/local/lib/1s/gateway"
EXPIRY_FILE="${ONES_VAR}/state/deploy-access.expires"
EXPIRE_UNIT="1s-deploy-access-expire"

ttl_seconds() {
  [[ "$1" =~ ^([1-9][0-9]*)(s|m|h)$ ]] || die "Invalid TTL '$1' (examples: 30m, 2h)"
  case "${BASH_REMATCH[2]}" in s) echo "${BASH_REMATCH[1]}" ;; m) echo $(( BASH_REMATCH[1] * 60 )) ;; h) echo $(( BASH_REMATCH[1] * 3600 )) ;; esac
}

install_key() {
  local key tmp src
  if (( $# )); then src="$*"; else src="$(head -c 4096)"; fi
  key="$(printf '%s\n' "${src}" | tr -d '\r' | grep -E '^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' | head -n1 || true)"
  [[ -n "${key}" ]] || die "stdin must contain one ssh-ed25519 PUBLIC key."
  tmp="$(mktemp)"; printf '%s\n' "${key}" >"${tmp}"
  ssh-keygen -l -f "${tmp}" >/dev/null || { rm -f "${tmp}"; die "Not a valid public key."; }
  install -d -m 0755 "${ONES_ETC}/deploy"
  install -m 0644 "${tmp}" "${KEY_FILE}"; rm -f "${tmp}"
  log "Deployment public key installed: $(ssh-keygen -l -f "${KEY_FILE}")"
  if [[ -s "${AUTH_FILE}" ]]; then enable_access ""; fi   # refresh if currently enabled
}

write_auth() { # content via stdin
  [[ -n "${DEPLOY_HOME}" ]] || die "User ${DEPLOY_USER} missing; run bootstrap.sh."
  install -d -m 0755 -o root -g root "${AUTH_DIR}"
  atomic_write "${AUTH_FILE}" 0644
}

enable_access() {
  local ttl="$1"
  [[ -s "${KEY_FILE}" ]] || die "No deployment key installed (run generate-deploy-key.sh on macOS)."
  id "${DEPLOY_USER}" >/dev/null 2>&1 || die "User ${DEPLOY_USER} missing; run bootstrap.sh."
  local key; key="$(cut -d' ' -f1,2 "${KEY_FILE}")"
  printf 'restrict,command="%s" %s 1s-deploy\n' "${GATEWAY}" "${key}" | write_auth
  if [[ -n "${ttl}" ]]; then
    local secs; secs="$(ttl_seconds "${ttl}")"
    if command -v systemd-run >/dev/null && [[ -d /run/systemd/system ]]; then
      systemctl stop "${EXPIRE_UNIT}.timer" >/dev/null 2>&1 || true
      systemctl reset-failed "${EXPIRE_UNIT}.service" "${EXPIRE_UNIT}.timer" >/dev/null 2>&1 || true
      systemd-run --quiet --unit="${EXPIRE_UNIT}" --on-active="${secs}" --timer-property=AccuracySec=10s \
        /usr/local/sbin/1s deploy-access disable
      date -u -d "@$(( $(date +%s) + secs ))" +%Y-%m-%dT%H:%M:%SZ >"${EXPIRY_FILE}"
    else
      warn "systemd-run unavailable: access will NOT auto-expire."
    fi
  fi
  log "Deployment access ENABLED for ${DEPLOY_USER}${ttl:+ (auto-disable in ${ttl})}."
}

disable_access() {
  local kill="${1:-}"
  : | write_auth
  rm -f "${EXPIRY_FILE}"
  if command -v systemctl >/dev/null; then systemctl stop "${EXPIRE_UNIT}.timer" >/dev/null 2>&1 || true; fi
  if [[ "${kill}" == --kill ]]; then pkill -KILL -u "${DEPLOY_USER}" 2>/dev/null || true; fi
  log "Deployment access DISABLED for ${DEPLOY_USER}."
}

status() {
  if [[ -s "${AUTH_FILE}" ]]; then
    echo "state:    ENABLED"
    [[ -f "${EXPIRY_FILE}" ]] && echo "expires:  $(cat "${EXPIRY_FILE}")"
  else
    echo "state:    disabled"
  fi
  if [[ -s "${KEY_FILE}" ]]; then echo "key:      $(ssh-keygen -l -f "${KEY_FILE}")"; else echo "key:      (none installed)"; fi
  echo "sessions: $(pgrep -u "${DEPLOY_USER}" -c 2>/dev/null || echo 0) process(es) of ${DEPLOY_USER}"
}

require_root
case "${1:-}" in
  install-key) shift; install_key "$@" ;;
  enable)      ttl=""; [[ "${2:-}" == --ttl ]] && ttl="${3:?--ttl needs a value}"; enable_access "${ttl}" ;;
  disable)     disable_access "${2:-}" ;;
  status)      status ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
