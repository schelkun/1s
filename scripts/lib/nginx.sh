# shellcheck shell=bash
# Nginx configuration rendering and safe application.
#
# Every change (deploy, allowlist update, certificate install) renders a
# complete new "generation" directory, validates it with `nginx -t`, atomically
# swaps the `current` symlink and gracefully reloads Nginx. An invalid
# generation is discarded and the running configuration is left untouched.

# shellcheck source=scripts/lib/openhands.sh
source "$(dirname "${BASH_SOURCE[0]}")/openhands.sh"

NGINX_DIR="${ONES_ETC}/nginx"
NGINX_CONTAINER="${ONES_PREFIX}-nginx"
NGINX_IN_CONTAINER="/etc/nginx/1s"
ACCESS_DIR="${ONES_ETC}/access"
TLS_DIR="${ONES_ETC}/tls"
NGINX_KEEP_GENERATIONS="${NGINX_KEEP_GENERATIONS:-5}"

nginx_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${NGINX_CONTAINER}" 2>/dev/null)" == true ]]
}

# Allowlist entries (normalised CIDRs) of a component, one per line.
access_entries() {
  local file="${ACCESS_DIR}/$1.allow" line addr
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    addr="${line%%#*}"; addr="${addr//[[:space:]]/}"
    [[ -n "${addr}" ]] || continue
    normalize_cidr "${addr}" || warn "Skipping invalid allowlist entry '${addr}' in ${file}"
  done <"${file}"
}

_ngx_listen() { # _ngx_listen IP PORT -> listen address
  if [[ "$1" == *:* ]]; then printf '[%s]:%s' "$(ipv6_compress "$1")" "$2"; else printf '%s:%s' "$1" "$2"; fi
}

# Print the bind IPs of a component (IPv4 and, when enabled, IPv6).
_ngx_ips() {
  local v4="$1" v6="$2"
  printf '%s\n' "${v4}"
  if is_true "${ENABLE_IPV6:-false}" && [[ -n "${v6}" ]]; then printf '%s\n' "${v6}"; fi
}

_ngx_real_ip_block() {
  local cidr
  [[ -n "${TRUSTED_PROXIES:-}" ]] || { printf '    # (no trusted proxies configured)\n'; return; }
  local -a items; IFS=, read -r -a items <<<"${TRUSTED_PROXIES// /}"
  for cidr in "${items[@]}"; do printf '    set_real_ip_from %s;\n' "$(normalize_cidr "${cidr}")"; done
  printf '    real_ip_header X-Forwarded-For;\n    real_ip_recursive on;\n'
}

_ngx_hsts() {
  if (( ${HSTS_MAX_AGE:-0} > 0 )); then
    printf '    add_header Strict-Transport-Security "max-age=%s" always;\n' "${HSTS_MAX_AGE}"
  fi
}

# _ngx_access_file COMPONENT OUT -- allow rules for a component.
_ngx_access_file() {
  local comp="$1" out="$2" e
  {
    printf '# Generated allowlist for %s. Default deny follows the include.\n' "${comp}"
    while read -r e; do printf 'allow %s;\n' "${e}"; done < <(access_entries "${comp}" | sort -u)
    if [[ "${comp}" == gitea ]]; then
      printf '# Gitea Actions runners (internal pool).\nallow %s;\n' "$(normalize_cidr "${GITEA_RUNNER_SUBNET_POOL}")"
      if component_deployed openhands && is_true "${OPENHANDS_ALLOW_GITEA:-false}"; then
        printf '# OpenHands agents (OPENHANDS_ALLOW_GITEA=true).\nallow %s;\n' "$(normalize_cidr "${OPENHANDS_SUBNET_POOL}")"
      fi
    fi
  } >"${out}"
}

_ngx_redirect_server() { # DOMAIN IPS...
  local domain="$1"; shift
  local ip
  printf 'server {\n'
  for ip in "$@"; do printf '    listen %s;\n' "$(_ngx_listen "${ip}" 80)"; done
  printf '    server_name %s;\n' "${domain}"
  printf '    include %s/snippets/acme.conf;\n' "${GEN_PATH}"
  printf '    location / { return 301 https://%s$request_uri; }\n' "${domain}"
  printf '}\n\n'
}

_ngx_tls_head() { # DOMAIN PORT IPS...
  local domain="$1" port="$2"; shift 2
  local ip
  printf 'server {\n'
  for ip in "$@"; do printf '    listen %s ssl;\n' "$(_ngx_listen "${ip}" "${port}")"; done
  printf '    http2 on;\n'
  printf '    server_name %s;\n' "${domain}"
  printf '    ssl_certificate     /etc/nginx/tls/%s/fullchain.pem;\n' "${domain}"
  printf '    ssl_certificate_key /etc/nginx/tls/%s/key.pem;\n' "${domain}"
  _ngx_hsts
  printf '    add_header X-Content-Type-Options nosniff always;\n'
  printf '    add_header Referrer-Policy same-origin always;\n'
}

_ngx_gitea_servers() {
  local -a ips; mapfile -t ips < <(_ngx_ips "${GITEA_BIND_IP}" "${GITEA_BIND_IP6:-}")
  _ngx_redirect_server "${GITEA_DOMAIN}" "${ips[@]}"
  _ngx_tls_head "${GITEA_DOMAIN}" 443 "${ips[@]}"
  cat <<EOF
    include ${GEN_PATH}/snippets/acme.conf;
    include ${GEN_PATH}/snippets/denied.conf;

    # Default deny: only allowlisted clients reach Gitea.
    include ${GEN_PATH}/access/gitea.conf;
    deny all;

    client_max_body_size ${GITEA_MAX_BODY_SIZE};

    location / {
        include ${GEN_PATH}/snippets/proxy.conf;
        proxy_pass http://127.0.0.1:${GITEA_LOCAL_PORT};
    }
}

EOF
}

_ngx_openhands_servers() {
  local -a ips; mapfile -t ips < <(_ngx_ips "${OPENHANDS_BIND_IP}" "${OPENHANDS_BIND_IP6:-}")
  local user port idx
  _ngx_redirect_server "${OPENHANDS_DOMAIN}" "${ips[@]}"
  while read -r user port; do
    idx="$(oh_user_index_get "${user}")"
    [[ -n "${idx}" ]] || { warn "OpenHands user ${user} has no instance yet; skipping vhost."; continue; }
    printf '# OpenHands instance of user "%s"\n' "${user}"
    _ngx_tls_head "${OPENHANDS_DOMAIN}" "${port}" "${ips[@]}"
    cat <<EOF
    include ${GEN_PATH}/snippets/acme.conf;
    include ${GEN_PATH}/snippets/denied.conf;

    # Default deny: only allowlisted clients reach OpenHands.
    include ${GEN_PATH}/access/openhands.conf;
    deny all;

    client_max_body_size ${OPENHANDS_MAX_BODY_SIZE};

    location / {
        include ${GEN_PATH}/snippets/proxy.conf;
        proxy_pass http://127.0.0.1:$(oh_local_port "${idx}");
    }
}

EOF
  done < <(oh_users)
}

# Default servers: reject unknown hosts on every socket we listen on.
_ngx_default_servers() {
  local sock ip port
  for sock in "$@"; do
    ip="${sock% *}"; port="${sock#* }"
    if [[ "${port}" == 80 ]]; then
      printf 'server {\n    listen %s default_server;\n    server_name _;\n' "$(_ngx_listen "${ip}" 80)"
      printf '    include %s/snippets/acme.conf;\n    location / { return 444; }\n}\n\n' "${GEN_PATH}"
    else
      printf 'server {\n    listen %s ssl default_server;\n    server_name _;\n    ssl_reject_handshake on;\n}\n\n' "$(_ngx_listen "${ip}" "${port}")"
    fi
  done
}

# nginx_render DIR -- write a complete generation into DIR.
nginx_render() {
  local dir="$1" gen_id
  gen_id="$(basename "${dir}")"
  GEN_PATH="${NGINX_IN_CONTAINER}/generations/${gen_id}"
  mkdir -p "${dir}/snippets" "${dir}/servers" "${dir}/access"
  cp "${ONES_ROOT}/config/nginx/snippets/"*.conf "${dir}/snippets/"

  local tmpl real_ip
  tmpl="$(<"${ONES_ROOT}/config/nginx/nginx.conf")"
  real_ip="$(_ngx_real_ip_block)"
  tmpl="${tmpl//@GEN@/${GEN_PATH}}"
  printf '%s\n' "${tmpl//@REAL_IP@/${real_ip}}" >"${dir}/nginx.conf"

  local -a sockets=()
  local ip user port
  if component_deployed gitea; then
    _ngx_access_file gitea "${dir}/access/gitea.conf"
    _ngx_gitea_servers >"${dir}/servers/10-gitea.conf"
    while read -r ip; do sockets+=("${ip} 80" "${ip} 443"); done < <(_ngx_ips "${GITEA_BIND_IP}" "${GITEA_BIND_IP6:-}")
  fi
  if component_deployed openhands; then
    _ngx_access_file openhands "${dir}/access/openhands.conf"
    _ngx_openhands_servers >"${dir}/servers/20-openhands.conf"
    while read -r ip; do
      sockets+=("${ip} 80")
      while read -r user port; do sockets+=("${ip} ${port}"); done < <(oh_users)
    done < <(_ngx_ips "${OPENHANDS_BIND_IP}" "${OPENHANDS_BIND_IP6:-}")
  fi
  local -a uniq=()
  if (( ${#sockets[@]} )); then mapfile -t uniq < <(printf '%s\n' "${sockets[@]}" | sort -u); fi
  _ngx_default_servers "${uniq[@]}" >"${dir}/servers/00-default.conf"
}

# Run `nginx -t` for a generation, in the running container or a throwaway one
# on the host network. nginx -t also binds the listen sockets, so missing bind
# addresses and port conflicts are caught before anything is switched.
nginx_test() {
  local conf="${NGINX_IN_CONTAINER}/generations/$1/nginx.conf"
  if nginx_running; then
    docker exec "${NGINX_CONTAINER}" nginx -t -q -c "${conf}"
  else
    docker run --rm --network host --entrypoint nginx \
      -v "${NGINX_DIR}:${NGINX_IN_CONTAINER}:ro" \
      -v "${TLS_DIR}:/etc/nginx/tls:ro" \
      "${NGINX_IMAGE}" -t -q -c "${conf}"
  fi
}

# PIDs of workers accepting connections (excludes "is shutting down").
_nginx_active_workers() {
  docker exec "${NGINX_CONTAINER}" ps -o pid= -o args= 2>/dev/null \
    | awk '/nginx: worker process$/ { print $1 }' | sort
}

# Graceful reload that returns only once the new configuration serves new
# connections: every accepting worker must be new. Old workers keep finishing
# their long-running connections (WebSockets) in the background. Fails if the
# master rejected the configuration (no new workers appear).
nginx_reload() {
  local before now i
  before="$(_nginx_active_workers)"
  docker exec "${NGINX_CONTAINER}" nginx -s reload || return 1
  for ((i = 0; i < 100; i++)); do
    now="$(_nginx_active_workers)"
    if [[ -n "${now}" ]] && [[ -z "$(comm -12 <(printf '%s\n' "${before}") <(printf '%s\n' "${now}"))" ]]; then
      return 0
    fi
    sleep 0.1
  done
  err "Nginx did not start new workers after reload (configuration rejected at runtime?)."
  docker logs --tail 20 "${NGINX_CONTAINER}" >&2 2>&1 || true
  return 1
}

_nginx_apply_locked() {
  local gen_id dir prev
  mkdir -p "${NGINX_DIR}/generations"
  gen_id="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
  dir="${NGINX_DIR}/generations/${gen_id}"
  nginx_render "${dir}"
  if ! nginx_test "${gen_id}"; then
    err "Rendered Nginx configuration is invalid; keeping the current configuration."
    mv "${dir}" "${NGINX_DIR}/generations/.failed-${gen_id}"
    return 1
  fi
  prev="$(readlink "${NGINX_DIR}/current" 2>/dev/null || true)"
  ln -sfn "generations/${gen_id}" "${NGINX_DIR}/.current.tmp"
  mv -Tf "${NGINX_DIR}/.current.tmp" "${NGINX_DIR}/current"
  if nginx_running; then
    if ! nginx_reload; then
      err "Nginx reload failed; restoring previous generation ${prev:-<none>}."
      if [[ -n "${prev}" ]]; then
        ln -sfn "${prev}" "${NGINX_DIR}/.current.tmp" && mv -Tf "${NGINX_DIR}/.current.tmp" "${NGINX_DIR}/current"
        nginx_reload || true
      fi
      return 1
    fi
  fi
  log "Nginx configuration generation ${gen_id} is active."
  # Prune old generations (keep the newest N plus the active one) and failures.
  local g keep=0
  while read -r g; do
    keep=$((keep + 1))
    if (( keep > NGINX_KEEP_GENERATIONS )) && [[ "generations/${g}" != "$(readlink "${NGINX_DIR}/current")" ]]; then
      rm -rf -- "${NGINX_DIR}/generations/${g:?}"
    fi
  done < <(find "${NGINX_DIR}/generations" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' | sort -r)
  find "${NGINX_DIR}/generations" -mindepth 1 -maxdepth 1 -name '.failed-*' -mtime +7 -exec rm -rf -- {} +
}

# nginx_apply -- render, validate, swap and reload (serialised).
nginx_apply() { with_lock nginx _nginx_apply_locked; }

# Start (or update) the Nginx container.
nginx_up() {
  local files=(-f "${ONES_ROOT}/compose/nginx/compose.yml")
  [[ -f "${ONES_ETC}/overrides/nginx.yml" ]] && files+=(-f "${ONES_ETC}/overrides/nginx.yml")
  docker compose --project-directory "${ONES_ROOT}/compose/nginx" "${files[@]}" \
    --env-file "${ONES_ETC}/runtime/nginx/compose.env" up -d --remove-orphans
}
