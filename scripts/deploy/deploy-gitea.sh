#!/usr/bin/env bash
# Deploy/update Gitea, PostgreSQL and the runner pool. Idempotent.
# Does not touch OpenHands. Nginx is reloaded gracefully, never restarted.
set -euo pipefail

# shellcheck source=scripts/lib/deploy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/deploy.sh"

GITEA_C="${ONES_PREFIX}-gitea"
DB_C="${ONES_PREFIX}-gitea-db"
RT="${RUNTIME_DIR}/gitea"

gitea_compose() {
  local extra=()
  if is_true "${ENABLE_IPV6}" && [[ -n "${GITEA_SSH_BIND_IP6:-}" ]]; then
    extra+=("${ONES_ROOT}/compose/gitea/compose.ssh-ipv6.yml")
  fi
  compose_cmd "${ONES_ROOT}/compose/gitea" "${RT}/compose.env" "${extra[@]}" -- "$@"
}

# First usable address of the frontend network = Docker gateway (the peer Gitea
# sees for proxied requests, because the port is published on 127.0.0.1).
frontend_gateway() {
  local net a b c d
  net="$(normalize_cidr "${GITEA_NETWORK_SUBNET}")"
  IFS=. read -r a b c d <<<"${net%/*}"
  printf '%s.%s.%s.%s\n' "${a}" "${b}" "${c}" $((d + 1))
}

render_runtime() {
  install -d -m 0700 "${RT}"
  write_env "${RT}/compose.env" 0600 ONES_PREFIX ONES_ETC GITEA_IMAGE GITEA_POSTGRES_IMAGE \
    GITEA_LOCAL_PORT GITEA_SSH_BIND_IP GITEA_SSH_BIND_IP6 GITEA_SSH_PORT GITEA_CPUS GITEA_MEMORY \
    GITEA_DB_MEMORY GITEA_NETWORK_SUBNET

  write_kv "${RT}/db.env" 0600 \
    POSTGRES_USER=gitea POSTGRES_DB=gitea "POSTGRES_PASSWORD=${GITEA_DB_PASSWORD}" \
    "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256"

  local ssh_port_public="${GITEA_SSH_PORT}"
  write_kv "${RT}/gitea.env" 0600 \
    "GITEA__APP_NAME=${GITEA_APP_NAME}" \
    GITEA__RUN_MODE=prod \
    GITEA__database__DB_TYPE=postgres \
    GITEA__database__HOST=db:5432 \
    GITEA__database__NAME=gitea \
    GITEA__database__USER=gitea \
    "GITEA__database__PASSWD=${GITEA_DB_PASSWORD}" \
    GITEA__database__SSL_MODE=disable \
    "GITEA__server__DOMAIN=${GITEA_DOMAIN}" \
    "GITEA__server__ROOT_URL=https://${GITEA_DOMAIN}/" \
    GITEA__server__PROTOCOL=http \
    GITEA__server__HTTP_ADDR=0.0.0.0 \
    GITEA__server__HTTP_PORT=3000 \
    GITEA__server__DISABLE_SSH=false \
    GITEA__server__START_SSH_SERVER=true \
    "GITEA__server__SSH_DOMAIN=${GITEA_SSH_DOMAIN}" \
    "GITEA__server__SSH_PORT=${ssh_port_public}" \
    GITEA__server__SSH_LISTEN_PORT=2222 \
    GITEA__server__LFS_START_SERVER=true \
    "GITEA__server__LFS_JWT_SECRET=${GITEA_LFS_JWT_SECRET}" \
    GITEA__server__OFFLINE_MODE=true \
    GITEA__security__INSTALL_LOCK=true \
    "GITEA__security__SECRET_KEY=${GITEA_SECRET_KEY}" \
    "GITEA__security__INTERNAL_TOKEN=${GITEA_INTERNAL_TOKEN}" \
    "GITEA__security__REVERSE_PROXY_TRUSTED_PROXIES=127.0.0.0/8,::1/128,$(frontend_gateway)/32" \
    GITEA__security__REVERSE_PROXY_LIMIT=1 \
    GITEA__security__MIN_PASSWORD_LENGTH=12 \
    "GITEA__oauth2__JWT_SECRET=${GITEA_OAUTH2_JWT_SECRET}" \
    "GITEA__service__DISABLE_REGISTRATION=${GITEA_DISABLE_REGISTRATION}" \
    "GITEA__service__REQUIRE_SIGNIN_VIEW=${GITEA_REQUIRE_SIGNIN_VIEW}" \
    GITEA__service__DEFAULT_KEEP_EMAIL_PRIVATE=true \
    GITEA__session__COOKIE_SECURE=true \
    GITEA__actions__ENABLED=true \
    GITEA__actions__DEFAULT_ACTIONS_URL=github \
    GITEA__webhook__ALLOWED_HOST_LIST=external \
    GITEA__migrations__ALLOW_LOCALNETWORKS=false \
    "GITEA__cron.update_checker__ENABLED=false" \
    GITEA__log__LEVEL=Info
}

sync_db_password() {
  # Applies GITEA_DB_PASSWORD on every deploy (supports rotation). Sent over
  # stdin so it never appears in a process list.
  printf "ALTER ROLE gitea WITH PASSWORD '%s';\n" "${GITEA_DB_PASSWORD//\'/\'\'}" \
    | docker exec -i "${DB_C}" psql -q -v ON_ERROR_STOP=1 -U gitea -d gitea >/dev/null
}

gitea_cli() { docker exec -u git "${GITEA_C}" gitea "$@"; }

ensure_admin() {
  if gitea_cli admin user list --admin 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qxF -- "${GITEA_ADMIN_USER}"; then
    log "Gitea administrator ${GITEA_ADMIN_USER} exists (password is not changed by deploys)."
    return 0
  fi
  log "Creating Gitea administrator ${GITEA_ADMIN_USER}"
  # Password via stdin into the container shell, not via the host command line.
  printf '%s\n' "${GITEA_ADMIN_PASSWORD}" | docker exec -i -u git "${GITEA_C}" sh -c \
    'IFS= read -r p; exec gitea admin user create --admin --username "$1" --email "$2" --password "$p" --must-change-password=false' \
    _ "${GITEA_ADMIN_USER}" "${GITEA_ADMIN_EMAIL}" >/dev/null
}

main() {
  require_root
  require_config
  config_load_server
  config_validate shared gitea
  require_shared
  ensure_base_dirs

  predeploy_backup gitea "${GITEA_BACKUP_BEFORE_DEPLOY}"
  render_runtime

  log "Pulling Gitea images"
  ensure_image "${HELPER_IMAGE}"
  retry 4 gitea_compose pull -q --policy missing
  gitea_compose up -d --remove-orphans db
  wait_healthy "${DB_C}" 180
  retry 3 sync_db_password
  gitea_compose up -d --remove-orphans
  wait_healthy "${GITEA_C}" 300
  ensure_admin

  "${ONES_ROOT}/scripts/certificates/certs.sh" ensure "${GITEA_DOMAIN}"
  mark_deployed gitea
  nginx_apply
  firewall_apply

  if [[ -f "${TLS_DIR}/${GITEA_DOMAIN}/.placeholder" ]]; then
    "${ONES_ROOT}/scripts/certificates/certs.sh" issue "${GITEA_DOMAIN}" \
      || warn "Certificate issuance failed; temporary certificate in use. Retry: sudo 1s certs issue ${GITEA_DOMAIN}"
  fi

  "${ONES_ROOT}/scripts/deploy/runners.sh" reconcile

  if systemd_available; then
    install_backup_timer gitea "${GITEA_BACKUP_SCHEDULE}"
    _UNITS_CHANGED=0
    install_unit 1s-runner-prune.service
    install_unit 1s-runner-prune.timer
    (( _UNITS_CHANGED )) && systemctl daemon-reload
    systemctl enable --now 1s-runner-prune.timer >/dev/null
  fi

  mark_deployed gitea "$(this_release)"
  "${ONES_ROOT}/scripts/health/health.sh" gitea
  log "Gitea deployed: https://${GITEA_DOMAIN}/  (ssh://git@${GITEA_SSH_DOMAIN}:${GITEA_SSH_PORT}/)"
}

main "$@"
