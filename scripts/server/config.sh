#!/usr/bin/env bash
# Server-side configuration (run as root; the macOS scripts call it over SSH).
#
#   config.sh import            read a .env file on stdin, generate missing
#                               secrets, validate, store per component
#   config.sh show              print the effective settings (no secrets)
#   config.sh secret NAME       print one secret (e.g. GITEA_ADMIN_PASSWORD)
#   config.sh rotate NAME       generate a new value for one secret
#
# Files: /etc/1s/config/<component>.env (0644) and
#        /etc/1s/secrets/<component>.env (0600 root).
# Importing replaces the settings (removed lines fall back to defaults).
# Secrets are kept unless the imported file sets them or you rotate them.
set -euo pipefail

# shellcheck source=scripts/lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

COMPONENTS=(shared gitea openhands)

gen_password() { # 24 letters/digits: safe in every shell, URL and SQL context
  local p=""
  while (( ${#p} < 24 )); do p+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"; done
  printf '%s' "${p:0:24}"
}

gen_value() {
  case "$1" in
    GITEA_ADMIN_PASSWORD|GITEA_DB_PASSWORD) gen_password ;;
    ACME_DNS_CREDENTIALS) ;;                      # provided by you, never generated
    *) gen_secret ;;
  esac
}

# Write NAME=value lines for the given names (from current shell variables).
write_names() { # FILE MODE NAME...
  local file="$1" mode="$2" n; shift 2
  for n in "$@"; do
    if [[ -n "${!n:-}" ]]; then printf '%s=%s\n' "${n}" "$(env_quote "${!n}")"; fi
  done | atomic_write "${file}" "${mode}"
}

cmd_import() {
  local tmp n c
  tmp="$(mktemp)"
  head -c 262144 >"${tmp}"
  # Start from a clean slate: only what the file says, plus existing secrets.
  while read -r n; do unset "${n}"; done < <(schema_names all)
  env_load "${tmp}"; rm -f "${tmp}"

  local -A existing=()
  for c in "${COMPONENTS[@]}"; do
    while read -r n; do
      existing[${n}]="$(env_get "${ONES_ETC}/secrets/${c}.env" "${n}")"
    done < <(schema_names "${c}" secret)
  done
  local generated=()
  for c in "${COMPONENTS[@]}"; do
    while read -r n; do
      if [[ -z "${!n:-}" && -n "${existing[${n}]}" ]]; then printf -v "${n}" '%s' "${existing[${n}]}"; fi
      if [[ -z "${!n:-}" ]]; then
        printf -v "${n}" '%s' "$(gen_value "${n}")"
        [[ -n "${!n}" ]] && generated+=("${n}")
      fi
    done < <(schema_names "${c}" secret)
  done

  # Validate with defaults applied (in a subshell, so only explicitly set
  # settings are stored and defaults stay upgradable).
  local comps
  comps="$(
    config_apply_defaults
    list=(shared)
    is_true "${ENABLE_GITEA}" && list+=(gitea)
    is_true "${ENABLE_OPENHANDS}" && list+=(openhands)
    config_validate "${list[@]}" >&2 || exit 1
    echo "${list[*]}"
  )" || die "Nothing was changed. Fix .env and import again."

  install -d -m 0755 "${ONES_ETC}" "${ONES_ETC}/config"
  install -d -m 0700 "${ONES_ETC}/secrets"
  for c in "${COMPONENTS[@]}"; do
    local plain=() secret=()
    mapfile -t plain < <(schema_names "${c}" plain)
    mapfile -t secret < <(schema_names "${c}" secret)
    write_names "${ONES_ETC}/config/${c}.env" 0644 "${plain[@]}"
    write_names "${ONES_ETC}/secrets/${c}.env" 0600 "${secret[@]}"
  done
  log "Configuration stored. Enabled: ${comps}."
  if (( ${#generated[@]} )); then log "Generated secrets: ${generated[*]}"; fi
  log "Next: deploy (scripts/macos/deploy.sh). Admin password: sudo 1s config secret GITEA_ADMIN_PASSWORD"
}

cmd_show() {
  config_load_server
  local c name comp kind _r _d _desc
  for c in "${COMPONENTS[@]}"; do
    echo "[${c}]"
    while IFS='|' read -r name comp kind _r _d _desc; do
      [[ "${comp}" == "${c}" ]] || continue
      if [[ "${kind}" == secret ]]; then
        printf '  %-36s %s\n' "${name}" "$([[ -n "${!name:-}" ]] && echo '(set)' || echo '(empty)')"
      else
        printf '  %-36s %s\n' "${name}" "${!name:-}"
      fi
    done < <(schema_rows)
  done
}

secret_component() {
  local comp; comp="$(schema_field "$1" 2)"
  [[ -n "${comp}" && "$(schema_field "$1" 3)" == secret ]] || die "Unknown secret: $1"
  printf '%s\n' "${comp}"
}

cmd_secret() {
  local comp; comp="$(secret_component "$1")"
  env_get "${ONES_ETC}/secrets/${comp}.env" "$1"; echo
}

cmd_rotate() {
  local name="$1" comp file v
  comp="$(secret_component "${name}")"
  [[ "${name}" != ACME_DNS_CREDENTIALS ]] || die "Edit ACME_DNS_CREDENTIALS in .env and import instead."
  case "${name}" in
    GITEA_SECRET_KEY|OPENHANDS_STORAGE_MASTER_KEY)
      [[ "${2:-}" == --yes ]] || die "${name} encrypts stored data; rotating makes it unreadable. Re-run with --yes if you are sure." ;;
  esac
  file="${ONES_ETC}/secrets/${comp}.env"
  v="$(gen_value "${name}")"
  { grep -v "^${name}=" "${file}" 2>/dev/null || true; printf '%s=%s\n' "${name}" "$(env_quote "${v}")"; } \
    | atomic_write "${file}.new" 0600
  mv -f "${file}.new" "${file}"
  log "${name} rotated. Deploy ${comp} to apply it."
}

main() {
  require_root
  case "${1:-}" in
    import) with_lock config cmd_import ;;
    show)   cmd_show ;;
    secret) [[ -n "${2:-}" ]] || die "usage: config.sh secret NAME"; cmd_secret "$2" ;;
    rotate) [[ -n "${2:-}" ]] || die "usage: config.sh rotate NAME [--yes]"; with_lock config cmd_rotate "$2" "${3:-}" ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
}

main "$@"
