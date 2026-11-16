# shellcheck shell=bash
# OpenHands per-user helpers.

# shellcheck source=scripts/lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

OH_USERS_MAP="${ONES_VAR}/openhands/users.map"

# Stable per-user index (1..250). Indices are allocated once and never reused
# while the user's data exists, so subnets and loopback ports stay stable.
oh_user_index() {
  local user="$1" idx used=" "
  mkdir -p "$(dirname "${OH_USERS_MAP}")"
  touch "${OH_USERS_MAP}"
  idx="$(awk -v u="${user}" '$1 == u { print $2; exit }' "${OH_USERS_MAP}")"
  if [[ -n "${idx}" ]]; then printf '%s\n' "${idx}"; return 0; fi
  while read -r _ idx; do used+="${idx} "; done <"${OH_USERS_MAP}"
  for ((idx = 1; idx <= 250; idx++)); do
    [[ "${used}" == *" ${idx} "* ]] && continue
    printf '%s %s\n' "${user}" "${idx}" >>"${OH_USERS_MAP}"
    printf '%s\n' "${idx}"
    return 0
  done
  die "No free OpenHands user index (max 250 users)"
}

# Read-only lookup; empty when the user was never deployed.
oh_user_index_get() {
  [[ -f "${OH_USERS_MAP}" ]] || return 0
  awk -v u="$1" '$1 == u { print $2; exit }' "${OH_USERS_MAP}"
}

oh_local_port() { printf '%s\n' $(( OPENHANDS_LOCAL_PORT_BASE + $1 )); }
oh_subnet()     { pool_subnet "${OPENHANDS_SUBNET_POOL}" "$1"; }

# Deterministic per-user secrets derived from the master keys (HMAC-SHA256).
# Show a key with: sudo 1s openhands key <user>
oh_user_api_key()    { hmac_hex "${OPENHANDS_API_MASTER_KEY}" "1s/openhands/api/$1"; }
oh_user_secret_key() { hmac_hex "${OPENHANDS_STORAGE_MASTER_KEY}" "1s/openhands/storage/$1"; }

# Users currently configured: "name port" lines.
oh_users() { openhands_users_parse "${OPENHANDS_USERS}"; }
