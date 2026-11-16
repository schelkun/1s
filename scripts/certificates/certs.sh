#!/usr/bin/env bash
# Certificate management with acme.sh (never Certbot).
#
#   certs.sh install-acme            install/upgrade the pinned acme.sh
#   certs.sh ensure  <domain>        create a short-lived self-signed placeholder
#                                    if no certificate exists (lets Nginx start)
#   certs.sh issue   <domain> [--force]
#                                    issue/renew via HTTP-01 webroot (default) or
#                                    DNS-01 (ACME_DNS_PROVIDER) and install it
#   certs.sh renew                   renew everything that is due (timer)
#   certs.sh check   [--quiet]       report expiry; non-zero if a certificate is a
#                                    placeholder or expires within ACME_RENEW_DAYS
#   certs.sh list                    show managed certificates
#   certs.sh reload-hook             acme.sh reload command (validate + reload)
set -euo pipefail

# shellcheck source=scripts/lib/nginx.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/nginx.sh"

ACME_VERSION="3.1.6"
ACME_SHA256="0d3f9000ac44a6331314742a88c475f79134e24fc991997883652adc59efc486"
ACME_INSTALL_DIR="${ONES_OPT}/acme.sh"
ACME_CONFIG_HOME="${ONES_VAR}/acme"
ACME_WEBROOT="${ONES_VAR}/acme-webroot"

acme() {
  "${ACME_INSTALL_DIR}/acme.sh" --home "${ACME_INSTALL_DIR}" --config-home "${ACME_CONFIG_HOME}" "$@"
}

install_acme() {
  require_root
  if [[ -x "${ACME_INSTALL_DIR}/acme.sh" && "$(cat "${ACME_INSTALL_DIR}/.1s-version" 2>/dev/null)" == "${ACME_VERSION}" ]]; then
    log "acme.sh ${ACME_VERSION} already installed."
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading acme.sh ${ACME_VERSION}"
  curl -fsSL --retry 3 -o "${tmp}/acme.tar.gz" \
    "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz"
  echo "${ACME_SHA256}  ${tmp}/acme.tar.gz" | sha256sum -c --quiet - \
    || die "acme.sh checksum mismatch; refusing to install."
  tar -xzf "${tmp}/acme.tar.gz" -C "${tmp}"
  local src="${tmp}/acme.sh-${ACME_VERSION}"
  mkdir -p "${ACME_INSTALL_DIR}.new"
  cp -a "${src}/acme.sh" "${src}/dnsapi" "${src}/deploy" "${src}/notify" "${ACME_INSTALL_DIR}.new/"
  echo "${ACME_VERSION}" >"${ACME_INSTALL_DIR}.new/.1s-version"
  chmod 0755 "${ACME_INSTALL_DIR}.new/acme.sh"
  rm -rf -- "${ACME_INSTALL_DIR}.old"
  [[ -d "${ACME_INSTALL_DIR}" ]] && mv "${ACME_INSTALL_DIR}" "${ACME_INSTALL_DIR}.old"
  mv "${ACME_INSTALL_DIR}.new" "${ACME_INSTALL_DIR}"
  rm -rf -- "${ACME_INSTALL_DIR}.old" "${tmp}"
  install -d -m 0700 "${ACME_CONFIG_HOME}"
  install -d -m 0755 "${ACME_WEBROOT}"
  log "acme.sh ${ACME_VERSION} installed in ${ACME_INSTALL_DIR}."
}

cert_dir() { printf '%s/%s\n' "${TLS_DIR}" "$1"; }

ensure_placeholder() {
  local domain="$1" dir
  is_domain "${domain}" || die "Invalid domain: ${domain}"
  dir="$(cert_dir "${domain}")"
  if [[ -s "${dir}/fullchain.pem" && -s "${dir}/key.pem" ]]; then return 0; fi
  install -d -m 0700 "${dir}"
  log "Creating temporary self-signed certificate for ${domain} (until ACME issuance)."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7 \
    -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" \
    -keyout "${dir}/key.pem.tmp" -out "${dir}/fullchain.pem.tmp" 2>/dev/null
  chmod 0600 "${dir}/key.pem.tmp"; chmod 0644 "${dir}/fullchain.pem.tmp"
  mv -f "${dir}/key.pem.tmp" "${dir}/key.pem"
  mv -f "${dir}/fullchain.pem.tmp" "${dir}/fullchain.pem"
  touch "${dir}/.placeholder"
}

# Which bind IPs must the domain resolve to?
domain_ips() {
  case "$1" in
    "${GITEA_DOMAIN:-}") printf '%s\n' "${GITEA_BIND_IP}"; is_true "${ENABLE_IPV6}" && [[ -n "${GITEA_BIND_IP6:-}" ]] && printf '%s\n' "${GITEA_BIND_IP6}" ;;
    "${OPENHANDS_DOMAIN:-}") printf '%s\n' "${OPENHANDS_BIND_IP}"; is_true "${ENABLE_IPV6}" && [[ -n "${OPENHANDS_BIND_IP6:-}" ]] && printf '%s\n' "${OPENHANDS_BIND_IP6}" ;;
  esac
  return 0
}

check_dns() {
  local domain="$1" ip resolved ok=0
  is_true "${ACME_SKIP_DNS_CHECK:-false}" && { warn "ACME_SKIP_DNS_CHECK=true: not verifying DNS for ${domain}"; return 0; }
  command -v dig >/dev/null || { warn "dig not installed; skipping DNS check"; return 0; }
  while read -r ip; do
    [[ -n "${ip}" ]] || continue
    if [[ "${ip}" == *:* ]]; then resolved="$(dig +short AAAA "${domain}" | while read -r r; do ipv6_compress "${r}" 2>/dev/null; done)"; ip="$(ipv6_compress "${ip}")"
    else resolved="$(dig +short A "${domain}")"; fi
    if grep -qxF "${ip}" <<<"${resolved}"; then
      log "DNS OK: ${domain} -> ${ip}"
    else
      err "DNS for ${domain} does not resolve to ${ip} (got: ${resolved//$'\n'/ })"; ok=1
    fi
  done < <(domain_ips "${domain}")
  return "${ok}"
}

issue() {
  require_root
  local domain="$1" force="${2:-}" dir rc=0
  is_domain "${domain}" || die "Invalid domain: ${domain}"
  [[ -x "${ACME_INSTALL_DIR}/acme.sh" ]] || install_acme
  dir="$(cert_dir "${domain}")"
  install -d -m 0700 "${dir}"
  install -d -m 0755 "${ACME_WEBROOT}"

  acme --register-account -m "${ACME_EMAIL}" --server "${ACME_SERVER}" >/dev/null

  local -a args=(--issue -d "${domain}" --server "${ACME_SERVER}" --keylength "${ACME_KEY_TYPE}")
  if [[ -n "${ACME_DNS_PROVIDER:-}" ]]; then
    [[ "${ACME_DNS_PROVIDER}" =~ ^dns_[a-z0-9_]+$ ]] || die "Invalid ACME_DNS_PROVIDER: ${ACME_DNS_PROVIDER}"
    local pair
    for pair in ${ACME_DNS_CREDENTIALS:-}; do
      [[ "${pair}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.+)$ ]] || die "Invalid ACME_DNS_CREDENTIALS entry"
      export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    done
    args+=(--dns "${ACME_DNS_PROVIDER}")
  else
    check_dns "${domain}" || die "Fix DNS first (or use ACME_DNS_PROVIDER). Let's Encrypt validation would fail."
    nginx_running || die "Nginx must be running to answer HTTP-01 challenges."
    args+=(-w "${ACME_WEBROOT}")
  fi
  [[ "${force}" == --force ]] && args+=(--force)

  acme "${args[@]}" || rc=$?
  # acme.sh returns 2 when the certificate is still valid and renewal is skipped.
  if (( rc != 0 && rc != 2 )); then
    die "acme.sh failed to issue a certificate for ${domain} (exit ${rc})."
  fi

  local ecc=()
  [[ "${ACME_KEY_TYPE}" == ec-* ]] && ecc=(--ecc)
  acme --install-cert -d "${domain}" "${ecc[@]}" \
    --key-file "${dir}/key.pem" \
    --fullchain-file "${dir}/fullchain.pem" \
    --reloadcmd "${ONES_OPT}/tools/scripts/certificates/certs.sh reload-hook"
  chmod 0600 "${dir}/key.pem"
  rm -f "${dir}/.placeholder"
  log "Certificate for ${domain} installed."
}

reload_hook() {
  if nginx_running; then
    docker exec "${NGINX_CONTAINER}" nginx -t -q && nginx_reload
    log "Nginx reloaded after certificate change."
  fi
}

renew() {
  require_root
  [[ -x "${ACME_INSTALL_DIR}/acme.sh" ]] || { warn "acme.sh not installed"; return 0; }
  acme --cron
}

check() {
  local quiet="${1:-}" dir domain end days rc=0 now
  now="$(date +%s)"
  [[ -d "${TLS_DIR}" ]] || { [[ -n "${quiet}" ]] || log "No certificates."; return 0; }
  for dir in "${TLS_DIR}"/*/; do
    [[ -f "${dir}fullchain.pem" ]] || continue
    domain="$(basename "${dir}")"
    end="$(date -d "$(openssl x509 -enddate -noout -in "${dir}fullchain.pem" | cut -d= -f2)" +%s)"
    days=$(( (end - now) / 86400 ))
    if [[ -f "${dir}.placeholder" ]]; then
      warn "${domain}: TEMPORARY self-signed certificate (${days} days left). Run: certs.sh issue ${domain}"; rc=1
    elif (( days < ${ACME_RENEW_DAYS:-30} )); then
      warn "${domain}: expires in ${days} days"; rc=1
    else
      [[ -n "${quiet}" ]] || log "${domain}: OK, expires in ${days} days"
    fi
  done
  return "${rc}"
}

list() {
  [[ -x "${ACME_INSTALL_DIR}/acme.sh" ]] && acme --list
  check || true
}

main() {
  config_load_server
  local cmd="${1:-}"; shift || true
  case "${cmd}" in
    install-acme) install_acme ;;
    ensure)       [[ $# -eq 1 ]] || die "usage: certs.sh ensure <domain>"; ensure_placeholder "$1" ;;
    issue)        [[ $# -ge 1 ]] || die "usage: certs.sh issue <domain> [--force]"; with_lock certs issue "$@" ;;
    renew)        with_lock certs renew ;;
    check)        check "${1:-}" ;;
    list)         list ;;
    reload-hook)  reload_hook ;;
    *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; [[ -z "${cmd}" || "${cmd}" == -h || "${cmd}" == --help ]] || exit 2 ;;
  esac
}

main "$@"
