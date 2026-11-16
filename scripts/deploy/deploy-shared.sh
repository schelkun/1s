#!/usr/bin/env bash
# Deploy/update the shared infrastructure: Nginx, acme.sh, firewall hooks and
# timers. Safe to re-run; it never restarts Gitea or OpenHands.
set -euo pipefail

# shellcheck source=scripts/lib/deploy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/deploy.sh"

main() {
  require_root
  require_config
  config_load_server
  config_validate shared
  ensure_base_dirs
  link_tools

  "${ONES_ROOT}/scripts/certificates/certs.sh" install-acme

  write_env "${RUNTIME_DIR}/nginx/compose.env" 0600 NGINX_IMAGE ONES_PREFIX ONES_ETC ONES_VAR
  ensure_image "${NGINX_IMAGE}"
  ensure_image "${HELPER_IMAGE}"

  # Every deployed domain needs at least a placeholder certificate before Nginx
  # can load its vhost.
  local domains=()
  component_deployed gitea && domains+=("${GITEA_DOMAIN}")
  component_deployed openhands && domains+=("${OPENHANDS_DOMAIN}")
  local d
  for d in "${domains[@]}"; do "${ONES_ROOT}/scripts/certificates/certs.sh" ensure "${d}"; done

  nginx_apply
  nginx_up
  local i
  for i in $(seq 1 20); do nginx_running && break; sleep 1; done
  nginx_running || die "Nginx did not start; see: docker logs ${NGINX_CONTAINER}"

  if systemd_available; then
    _UNITS_CHANGED=0
    install_unit 1s-firewall.service
    install_unit 1s-certs.service
    install_unit 1s-certs.timer
    (( _UNITS_CHANGED )) && systemctl daemon-reload
    systemctl enable 1s-firewall.service >/dev/null
    systemctl enable --now 1s-certs.timer >/dev/null
  else
    warn "systemd not available: certificate renewal timer and firewall persistence not installed."
  fi
  firewall_apply

  for d in "${domains[@]}"; do
    if [[ -f "${TLS_DIR}/${d}/.placeholder" ]]; then
      "${ONES_ROOT}/scripts/certificates/certs.sh" issue "${d}" || warn "Certificate issuance for ${d} failed; the temporary certificate stays in place. Retry: sudo 1s certs issue ${d}"
    fi
  done

  mark_deployed shared "$(this_release)"
  log "Shared infrastructure deployed."
}

main "$@"
