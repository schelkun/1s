#!/usr/bin/env bash
# Deploy/update OpenHands Agent Canvas: one isolated instance per user from
# OPENHANDS_USERS. Idempotent; does not touch Gitea.
#
# Users removed from OPENHANDS_USERS are stopped but their data is KEPT.
# Delete it explicitly with: sudo 1s openhands purge-user <name> --yes
set -euo pipefail

# shellcheck source=scripts/lib/deploy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/deploy.sh"

RT_BASE="${RUNTIME_DIR}/openhands"

oh_compose() { # oh_compose USER ARGS...
  local user="$1"; shift
  local overlay="${ONES_ROOT}/compose/openhands/compose.hardened.yml"
  is_true "${OPENHANDS_AGENT_SUDO}" && overlay="${ONES_ROOT}/compose/openhands/compose.sudo.yml"
  compose_cmd "${ONES_ROOT}/compose/openhands" "${RT_BASE}/${user}/compose.env" "${overlay}" -- "$@"
}

render_user() {
  local user="$1" idx="$2" dir="${RT_BASE}/$1"
  install -d -m 0700 "${dir}"
  # Consumed by write_env through indirection.
  # shellcheck disable=SC2034
  { OH_USER="${user}"; OH_LOCAL_PORT="$(oh_local_port "${idx}")"; OH_SUBNET="$(oh_subnet "${idx}")"; OH_RUNTIME_DIR="${dir}"; }
  write_env "${dir}/compose.env" 0600 ONES_PREFIX OH_USER OH_LOCAL_PORT OH_SUBNET OH_RUNTIME_DIR \
    OPENHANDS_IMAGE OPENHANDS_CPUS OPENHANDS_MEMORY OPENHANDS_PIDS_LIMIT
  write_kv "${dir}/canvas.env" 0600 \
    "OH_SESSION_API_KEYS_0=$(oh_user_api_key "${user}")" \
    "OH_SECRET_KEY=$(oh_user_secret_key "${user}")"
}

# The Agent Server API must reject requests without the session key.
verify_auth() {
  local user="$1" port="$2" code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/api/settings" || true)"
  [[ "${code}" == 401 || "${code}" == 403 ]] || die "SECURITY: OpenHands API of ${user} answered ${code} without an API key (expected 401). Refusing to expose it."
}

main() {
  require_root
  require_config
  config_load_server
  config_validate shared openhands
  require_shared
  ensure_base_dirs

  predeploy_backup openhands "${OPENHANDS_BACKUP_BEFORE_DEPLOY}"

  log "Pulling ${OPENHANDS_IMAGE} (large image, first pull takes a while)"
  ensure_image "${OPENHANDS_IMAGE}"
  ensure_image "${HELPER_IMAGE}"

  local user port idx active=" "
  while read -r user port; do
    idx="$(oh_user_index "${user}")"
    render_user "${user}" "${idx}"
    oh_compose "${user}" up -d --remove-orphans
    active+="${user} "
  done < <(oh_users)

  while read -r user port; do
    idx="$(oh_user_index_get "${user}")"
    wait_healthy "${ONES_PREFIX}-openhands-${user}" 600
    verify_auth "${user}" "$(oh_local_port "${idx}")"
    log "OpenHands ${user}: https://${OPENHANDS_DOMAIN}:${port}/"
  done < <(oh_users)

  # Stop instances of users no longer configured (data volumes are kept).
  local c u
  for c in $(docker ps -a --format '{{.Names}}' | grep -E "^${ONES_PREFIX}-openhands-[a-z][a-z0-9-]*$" || true); do
    u="${c#"${ONES_PREFIX}-openhands-"}"
    [[ "${active}" == *" ${u} "* ]] && continue
    log "OpenHands ${u}: no longer configured; stopping (data kept)."
    if [[ -f "${RT_BASE}/${u}/compose.env" ]]; then oh_compose "${u}" down --remove-orphans; else docker rm -f "${c}" >/dev/null; fi
  done

  "${ONES_ROOT}/scripts/certificates/certs.sh" ensure "${OPENHANDS_DOMAIN}"
  mark_deployed openhands
  nginx_apply
  firewall_apply

  if [[ -f "${TLS_DIR}/${OPENHANDS_DOMAIN}/.placeholder" ]]; then
    "${ONES_ROOT}/scripts/certificates/certs.sh" issue "${OPENHANDS_DOMAIN}" \
      || warn "Certificate issuance failed; temporary certificate in use. Retry: sudo 1s certs issue ${OPENHANDS_DOMAIN}"
  fi

  systemd_available && install_backup_timer openhands "${OPENHANDS_BACKUP_SCHEDULE}"
  mark_deployed openhands "$(this_release)"
  "${ONES_ROOT}/scripts/health/health.sh" openhands
  log "OpenHands deployed. Per-user API keys: sudo 1s openhands key <user>  (or on your Mac: scripts/macos/server.sh openhands key <user>)"
}

main "$@"
