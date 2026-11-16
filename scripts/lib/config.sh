# shellcheck shell=bash
# Configuration schema, loading and validation.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ONES_SCHEMA="${ONES_SCHEMA:-${ONES_ROOT}/config/schema.conf}"

# Print schema rows as NAME|COMPONENT|KIND|REQUIRED|DEFAULT|DESCRIPTION.
schema_rows() {
  grep -Ev '^[[:space:]]*(#|$)' "${ONES_SCHEMA}"
}

# schema_names COMPONENT [secret|plain|all]
schema_names() {
  local want_comp="$1" want_type="${2:-all}" name comp kind _rest
  while IFS='|' read -r name comp kind _rest; do
    [[ "${want_comp}" == all || "${comp}" == "${want_comp}" ]] || continue
    case "${want_type}" in
      secret) [[ "${kind}" == secret ]] || continue ;;
      plain)  [[ "${kind}" != secret ]] || continue ;;
    esac
    printf '%s\n' "${name}"
  done < <(schema_rows)
}

schema_field() { # schema_field NAME FIELD_INDEX(1-based)
  schema_rows | awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f; exit }'
}

# Fill unset/empty settings with their schema defaults (supports ${OTHER}).
config_apply_defaults() {
  local name comp kind req def _desc pass
  # Two passes so defaults that reference other defaults resolve.
  for pass in 1 2; do
    while IFS='|' read -r name comp kind req def _desc; do
      [[ -n "${!name:-}" || -z "${def}" ]] && continue
      if [[ "${def}" =~ ^\$\{([A-Z0-9_]+)\}$ ]]; then
        local ref="${BASH_REMATCH[1]}"
        [[ -n "${!ref:-}" ]] || continue
        def="${!ref}"
      fi
      printf -v "${name}" '%s' "${def}"
      export "${name?}"
    done < <(schema_rows)
  done
  : "${pass}"
}

# validate_kind KIND VALUE -> 0 when valid
validate_kind() {
  local kind="$1" v="$2" item
  case "${kind}" in
    bool)     [[ "${v,,}" =~ ^(true|false|1|0|yes|no|on|off)$ ]] ;;
    int)      is_uint "${v}" ;;
    port)     is_port "${v}" ;;
    domain)   is_domain "${v}" ;;
    host)     is_domain "${v}" || is_ipv4 "${v}" || is_ipv6 "${v}" ;;
    ipv4)     is_ipv4 "${v}" ;;
    ipv6)     is_ipv6 "${v}" ;;
    cidr)     is_cidr "${v}" ;;
    cidrs)    local -a items; IFS=, read -r -a items <<<"${v// /}"
              for item in "${items[@]}"; do is_cidr "${item}" || return 1; done ;;
    email)    is_email "${v}" ;;
    image)    [[ "${v}" =~ ^[a-z0-9]([a-z0-9._/-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9._-]+)*:[A-Za-z0-9._-]+(@sha256:[a-f0-9]{64})?$ ]] ;;
    size)     [[ "${v}" =~ ^[1-9][0-9]*[kmgKMG]?$ ]] ;;
    cpus)     [[ "${v}" =~ ^([1-9][0-9]*(\.[0-9]+)?|0\.[0-9]*[1-9][0-9]*)$ ]] ;;
    duration) [[ "${v}" =~ ^[1-9][0-9]*(s|m|h)$ ]] ;;
    calendar) [[ "${v}" =~ ^[A-Za-z0-9*:,./~\ -]+$ ]] ;;
    users)    openhands_users_parse "${v}" >/dev/null ;;
    string)   [[ "${v}" != *$'\n'* ]] ;;
    secret)   [[ -n "${v}" ]] ;;
    enum:*)   local -a opts; IFS=/ read -r -a opts <<<"${kind#enum:}"
              for item in "${opts[@]}"; do [[ "${v}" == "${item}" ]] && return 0; done; return 1 ;;
    *)        die "Unknown schema kind: ${kind}" ;;
  esac
}

# openhands_users_parse "alice:443,bob:8444" -> "alice 443" lines
openhands_users_parse() {
  local spec="${1// /}" entry name port seen_names=" " seen_ports=" "
  [[ -n "${spec}" ]] || return 1
  local -a entries
  IFS=, read -r -a entries <<<"${spec}"
  for entry in "${entries[@]}"; do
    [[ "${entry}" =~ ^([a-z][a-z0-9-]{0,30}):([0-9]+)$ ]] || { err "Invalid OPENHANDS_USERS entry: '${entry}' (expected name:port)"; return 1; }
    name="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    is_port "${port}" || { err "Invalid port for OpenHands user ${name}: ${port}"; return 1; }
    [[ "${port}" != 80 ]] || { err "Port 80 is reserved for HTTP/ACME (user ${name})"; return 1; }
    [[ "${seen_names}" != *" ${name} "* ]] || { err "Duplicate OpenHands user: ${name}"; return 1; }
    [[ "${seen_ports}" != *" ${port} "* ]] || { err "Duplicate OpenHands port: ${port}"; return 1; }
    seen_names+="${name} "; seen_ports+="${port} "
    printf '%s %s\n' "${name}" "${port}"
  done
}

_cidr4_range() { # prints "start end" integers for an IPv4 CIDR
  local c a b cc d p n
  c="$(normalize_cidr "$1")" || return 1
  [[ "${c}" == */* ]] || c="${c}/32"
  p="${c##*/}"; IFS=. read -r a b cc d <<<"${c%/*}"
  n=$(( (a << 24) | (b << 16) | (cc << 8) | d ))
  printf '%s %s\n' "${n}" $(( n + (1 << (32 - p)) - 1 ))
}

cidr4_overlap() {
  local s1 e1 s2 e2
  read -r s1 e1 < <(_cidr4_range "$1") || return 1
  read -r s2 e2 < <(_cidr4_range "$2") || return 1
  (( s1 <= e2 && s2 <= e1 ))
}

# pool_subnet POOL INDEX -> /24 subnet number INDEX inside a /16 pool
pool_subnet() {
  local pool a b _c _d
  pool="$(normalize_cidr "$1")"
  IFS=. read -r a b _c _d <<<"${pool%/*}"
  printf '%s.%s.%s.0/24\n' "${a}" "${b}" "$2"
}

# config_validate COMPONENT... -- validate settings of the given components.
# Components: shared gitea openhands deploy local. Errors are collected.
config_validate() {
  local comps=" $* " name comp kind req def desc errors=0 v
  while IFS='|' read -r name comp kind req def desc; do
    [[ "${comps}" == *" ${comp} "* ]] || continue
    v="${!name:-}"
    if [[ -z "${v}" ]]; then
      case "${req}" in
        yes) err "Missing required setting ${name} (${desc})"; errors=$((errors + 1)) ;;
        if-gitea|if-openhands)
          if [[ "${comps}" == *" ${req#if-} "* ]]; then
            err "Missing required setting ${name} (${desc})"; errors=$((errors + 1))
          fi ;;
      esac
      continue
    fi
    if ! validate_kind "${kind}" "${v}"; then
      if [[ "${kind}" == secret ]]; then err "Invalid value for ${name}"
      else err "Invalid value for ${name}: '${v}' (expected ${kind})"; fi
      errors=$((errors + 1))
    fi
  done < <(schema_rows)

  # Cross-field checks.
  if [[ "${comps}" == *" gitea "* ]]; then
    [[ "$(normalize_cidr "${GITEA_RUNNER_SUBNET_POOL}" 2>/dev/null)" == */16 ]] \
      || { err "GITEA_RUNNER_SUBNET_POOL must be a /16 network"; errors=$((errors + 1)); }
    if (( ${GITEA_RUNNER_COUNT:-0} > 250 )); then err "GITEA_RUNNER_COUNT must be <= 250"; errors=$((errors + 1)); fi
    if (( ${GITEA_RUNNER_CAPACITY:-1} < 1 )); then err "GITEA_RUNNER_CAPACITY must be >= 1"; errors=$((errors + 1)); fi
    if cidr4_overlap "${GITEA_NETWORK_SUBNET}" "${GITEA_RUNNER_SUBNET_POOL}"; then
      err "GITEA_NETWORK_SUBNET overlaps GITEA_RUNNER_SUBNET_POOL"; errors=$((errors + 1)); fi
    if [[ "${GITEA_SSH_BIND_IP}" == "${GITEA_BIND_IP}" ]] && [[ "${GITEA_SSH_PORT}" =~ ^(80|443)$ ]]; then
      err "GITEA_SSH_PORT ${GITEA_SSH_PORT} collides with Nginx on ${GITEA_BIND_IP}"; errors=$((errors + 1)); fi
    if [[ "${GITEA_RUNNER_ISOLATION}" == rootless && "${GITEA_RUNNER_IMAGE}" != *dind-rootless* ]]; then
      err "GITEA_RUNNER_ISOLATION=rootless requires a *-dind-rootless runner image"; errors=$((errors + 1)); fi
    if [[ "${GITEA_RUNNER_ISOLATION}" == privileged && ( "${GITEA_RUNNER_IMAGE}" != *-dind* || "${GITEA_RUNNER_IMAGE}" == *rootless* ) ]]; then
      err "GITEA_RUNNER_ISOLATION=privileged requires a *-dind (rootful) runner image"; errors=$((errors + 1)); fi
  fi
  if [[ "${comps}" == *" openhands "* && -n "${OPENHANDS_USERS:-}" ]]; then
    [[ "$(normalize_cidr "${OPENHANDS_SUBNET_POOL}" 2>/dev/null)" == */16 ]] || { err "OPENHANDS_SUBNET_POOL must be a /16 network"; errors=$((errors + 1)); }
    local u p
    while read -r u p; do
      if [[ "${comps}" == *" gitea "* && -n "${GITEA_SSH_BIND_IP:-}" && "${GITEA_SSH_BIND_IP}" == "${OPENHANDS_BIND_IP}" && "${p}" == "${GITEA_SSH_PORT}" ]]; then
        err "OpenHands user ${u} port ${p} collides with Git-over-SSH"; errors=$((errors + 1)); fi
    done < <(openhands_users_parse "${OPENHANDS_USERS}" 2>/dev/null)
  fi
  if [[ "${comps}" == *" gitea "* && "${comps}" == *" openhands "* ]]; then
    for v in "${GITEA_NETWORK_SUBNET}" "${GITEA_RUNNER_SUBNET_POOL}"; do
      if cidr4_overlap "${v}" "${OPENHANDS_SUBNET_POOL}"; then
        err "OPENHANDS_SUBNET_POOL overlaps ${v}"; errors=$((errors + 1)); fi
    done
  fi
  if is_true "${ENABLE_IPV6:-false}"; then
    if [[ "${comps}" == *" gitea "* && -z "${GITEA_BIND_IP6:-}" ]]; then
      warn "ENABLE_IPV6=true but GITEA_BIND_IP6 is empty; Gitea will be IPv4-only."; fi
    if [[ "${comps}" == *" openhands "* && -z "${OPENHANDS_BIND_IP6:-}" ]]; then
      warn "ENABLE_IPV6=true but OPENHANDS_BIND_IP6 is empty; OpenHands will be IPv4-only."; fi
  fi
  (( errors == 0 )) || { err "${errors} configuration error(s)."; return 1; }
}

# ---------------------------------------------------------------------------
# Server-side configuration
#   ${ONES_ETC}/config/<component>.env   non-secret settings (0644)
#   ${ONES_ETC}/secrets/<component>.env  secrets (0600 root)
# ---------------------------------------------------------------------------

config_load_server() {
  local c
  for c in shared gitea openhands; do
    env_load "${ONES_ETC}/config/${c}.env"
    env_load "${ONES_ETC}/secrets/${c}.env"
  done
  config_apply_defaults
}

# Deploy scripts call this first: settings must have been imported.
require_config() {
  [[ -f "${ONES_ETC}/config/shared.env" ]] \
    || die "No configuration on this server yet. On your Mac run: scripts/macos/push-config.sh"
}

# Is a component deployed on this server?
component_deployed() { [[ -f "${ONES_VAR}/state/$1.deployed" ]]; }
