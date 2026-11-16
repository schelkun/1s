# shellcheck shell=bash
# Helpers shared by the server-side deploy scripts.

# shellcheck source=scripts/lib/firewall.sh
source "$(dirname "${BASH_SOURCE[0]}")/firewall.sh"

RUNTIME_DIR="${ONES_ETC}/runtime"
STATE_DIR="${ONES_VAR}/state"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

# write_env FILE MODE NAME... -- write NAME=value lines for the named variables.
write_env() {
  local file="$1" mode="$2" n; shift 2
  for n in "$@"; do printf '%s=%s\n' "${n}" "$(env_quote "${!n:-}")"; done | atomic_write "${file}" "${mode}"
}

# write_kv FILE MODE KEY=VALUE... -- like write_env but with literal pairs.
write_kv() {
  local file="$1" mode="$2" kv; shift 2
  for kv in "$@"; do printf '%s=%s\n' "${kv%%=*}" "$(env_quote "${kv#*=}")"; done | atomic_write "${file}" "${mode}"
}

container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo missing
}

# wait_healthy CONTAINER [TIMEOUT_SECONDS]
wait_healthy() {
  local c="$1" timeout="${2:-300}" waited=0 s
  while true; do
    s="$(container_health "${c}")"
    case "${s}" in
      healthy|running) [[ "${s}" == running ]] && sleep 2; log "${c}: ${s}"; return 0 ;;
      unhealthy|exited|dead|missing) if (( waited > 30 )); then err "${c} is ${s}"; docker logs --tail 50 "${c}" >&2 || true; return 1; fi ;;
    esac
    (( waited >= timeout )) && { err "Timed out waiting for ${c} (state: ${s})"; docker logs --tail 50 "${c}" >&2 || true; return 1; }
    sleep 3; waited=$((waited + 3))
  done
}

ensure_base_dirs() {
  install -d -m 0755 "${ONES_ETC}" "${ONES_ETC}/config" "${ONES_ETC}/nginx" "${ONES_ETC}/access" "${ONES_VAR}" "${ONES_VAR}/acme-webroot"
  install -d -m 0700 "${ONES_ETC}/secrets" "${ONES_ETC}/tls" "${RUNTIME_DIR}" "${STATE_DIR}"
  install -d -m 0700 "${BACKUP_DIR}"
}

require_shared() {
  component_deployed shared || die "Deploy the shared infrastructure first (target: shared)."
}

mark_deployed() {
  local comp="$1" release="${2:-}"
  install -d -m 0700 "${STATE_DIR}"
  date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR}/${comp}.deployed"
  if [[ -n "${release}" ]]; then
    local cur; cur="$(cat "${STATE_DIR}/${comp}.release" 2>/dev/null || true)"
    printf '%s\n' "${release}" >"${STATE_DIR}/${comp}.release"
    if [[ "${cur}" != "${release}" ]]; then
      printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${release}" >>"${STATE_DIR}/${comp}.history"
    fi
  fi
}

current_release() { cat "${STATE_DIR}/$1.release" 2>/dev/null || true; }

# Release id of the running scripts (directory name under ${ONES_OPT}/releases).
this_release() {
  local base; base="$(basename "${ONES_ROOT}")"
  if [[ "$(dirname "${ONES_ROOT}")" == "${ONES_OPT}/releases" ]]; then printf '%s\n' "${base}"; fi
}

# Point ${ONES_OPT}/tools (used by timers, hooks and the 1s CLI) at this release.
link_tools() {
  local rel; rel="$(this_release)"
  [[ -n "${rel}" ]] || { warn "Not running from ${ONES_OPT}/releases; tools link unchanged."; return 0; }
  ln -sfn "releases/${rel}" "${ONES_OPT}/.tools.tmp"
  mv -Tf "${ONES_OPT}/.tools.tmp" "${ONES_OPT}/tools"
  ln -sfn "${ONES_OPT}/tools/scripts/server/1s" /usr/local/sbin/1s
}

# retry N CMD... -- run CMD up to N times with growing pauses (registry hiccups).
retry() {
  local n="$1" i; shift
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    (( i < n )) && { warn "Attempt ${i}/${n} failed: $*; retrying in $((i * 10))s"; sleep $((i * 10)); }
  done
  return 1
}

# ensure_image IMAGE -- pull only when missing (all images are pinned tags).
ensure_image() {
  docker image inspect "$1" >/dev/null 2>&1 || retry 4 docker pull -q "$1" >/dev/null
}

systemd_available() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; }

# install_unit NAME -- copy config/systemd/NAME into place (if changed).
install_unit() {
  local name="$1" src="${ONES_ROOT}/config/systemd/$1"
  if ! cmp -s "${src}" "${SYSTEMD_DIR}/${name}" 2>/dev/null; then
    install -m 0644 "${src}" "${SYSTEMD_DIR}/${name}"
    _UNITS_CHANGED=1
  fi
}

# install_backup_timer COMPONENT CALENDAR
install_backup_timer() {
  local comp="$1" cal="$2"
  systemd_available || { warn "systemd not available; skipping backup timer."; return 0; }
  cat <<EOF | atomic_write "${SYSTEMD_DIR}/1s-backup-${comp}.service" 0644
[Unit]
Description=1s scheduled backup of ${comp}
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=${ONES_OPT}/tools/scripts/backup/backup.sh create ${comp} --tag scheduled
EOF
  cat <<EOF | atomic_write "${SYSTEMD_DIR}/1s-backup-${comp}.timer" 0644
[Unit]
Description=1s scheduled backup of ${comp}

[Timer]
OnCalendar=${cal}
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "1s-backup-${comp}.timer" >/dev/null
}

# compose_cmd DIR ENVFILE [extra -f files...] -- ARGS
# An operator-maintained overlay ${ONES_ETC}/overrides/<dirname>.yml (e.g.
# overrides/gitea.yml) is appended automatically when present.
compose_cmd() {
  local dir="$1" envf="$2"; shift 2
  local files=(-f "${dir}/compose.yml")
  while (( $# )) && [[ "$1" != -- ]]; do files+=(-f "$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  local override
  override="${ONES_ETC}/overrides/$(basename "${dir}").yml"
  [[ -f "${override}" ]] && files+=(-f "${override}")
  docker compose --project-directory "${dir}" "${files[@]}" --env-file "${envf}" "$@"
}

# Pre-deployment backup for COMPONENT; records its id for data rollback.
predeploy_backup() {
  local comp="$1" flag="$2" id
  component_deployed "${comp}" || return 0
  is_true "${flag}" || { log "Pre-deployment backup disabled for ${comp}."; return 0; }
  log "Creating pre-deployment backup of ${comp}"
  id="$("${ONES_ROOT}/scripts/backup/backup.sh" create "${comp}" --tag predeploy --print-id)"
  printf '%s %s\n' "$(current_release "${comp}")" "${id}" >"${STATE_DIR}/${comp}.predeploy-backup"
}
