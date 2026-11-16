#!/usr/bin/env bash
# Manage the default-deny IP allowlists (run on the server as root).
#
# Usage:
#   ip-access.sh add    <component> <ip|cidr>... [--comment "text"] [--force]
#   ip-access.sh remove <component> <ip|cidr>...
#   ip-access.sh list   [<component>|all]
#   ip-access.sh check  <component> <ip>      is this address allowed?
#   ip-access.sh apply  [<component>|all]     re-apply stored allowlists
#   ip-access.sh reset  <component> --yes     remove every entry (deny all)
#
# Components:
#   gitea       Gitea web UI/API (HTTP 403 for everyone else)
#   openhands   All OpenHands user instances (HTTP 403 for everyone else)
#   gitea-ssh   Git-over-SSH port (dropped at the firewall for everyone else)
#
# IPv4, IPv6 and CIDR are accepted; host bits are cleared and duplicates are
# ignored. Every change is atomic, validated (nginx -t / iptables) and rolled
# back automatically if it cannot be applied. Allowlists live in
# /etc/1s/access/<component>.allow.
#
# Locked out? Use your administrative SSH session (not affected by these lists):
#   sudo 1s ip-access add gitea <your-ip>
set -euo pipefail

# shellcheck source=scripts/lib/firewall.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/firewall.sh"

COMPONENTS=(gitea openhands gitea-ssh)

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

valid_component() {
  local c
  for c in "${COMPONENTS[@]}"; do [[ "$1" == "${c}" ]] && return 0; done
  die "Unknown component '$1' (expected: ${COMPONENTS[*]})"
}

allow_file() { printf '%s/%s.allow\n' "${ACCESS_DIR}" "$1"; }

# Apply a component's allowlist to the running services.
apply_component() {
  local comp="$1"
  case "${comp}" in
    gitea|openhands)
      if component_deployed "${comp}"; then nginx_apply
      else log "${comp} is not deployed yet; the allowlist is stored and applied on deploy."; fi ;;
    gitea-ssh)
      if component_deployed gitea; then firewall_apply
      else log "gitea is not deployed yet; the allowlist is stored and applied on deploy."; fi ;;
  esac
}

# Replace the allowlist with stdin, apply it, roll back on failure.
commit_allowlist() {
  local comp="$1" file backup
  file="$(allow_file "${comp}")"
  backup="$(mktemp "${ACCESS_DIR}/.${comp}.allow.bak.XXXXXX")"
  if [[ -f "${file}" ]]; then cp -p "${file}" "${backup}"; else : >"${backup}"; fi
  atomic_write "${file}" 0644
  if ! apply_component "${comp}"; then
    err "Applying the new ${comp} allowlist failed; rolling back."
    mv -f "${backup}" "${file}"
    apply_component "${comp}" || err "Rollback apply failed too; the previous running configuration is still active."
    return 1
  fi
  rm -f "${backup}"
}

cmd_add() {
  local comp="$1"; shift
  local comment="" force=false entries=() e n file
  while (( $# )); do
    case "$1" in
      --comment) comment="${2:-}"; shift 2 ;;
      --force) force=true; shift ;;
      *) entries+=("$1"); shift ;;
    esac
  done
  (( ${#entries[@]} )) || die "No address given."
  [[ "${comment}" != *$'\n'* ]] || die "Comment must be a single line."
  file="$(allow_file "${comp}")"
  mkdir -p "${ACCESS_DIR}"; touch "${file}"
  local -a existing; mapfile -t existing < <(access_entries "${comp}")
  local -a add=()
  for e in "${entries[@]}"; do
    n="$(normalize_cidr "${e}")" || die "Invalid IP address or CIDR: ${e}"
    [[ "${n}" != "${e}" ]] && log "Normalised ${e} -> ${n}"
    if [[ "${n}" == 0.0.0.0/0 || "${n}" == ::/0 ]] && [[ "${force}" != true ]]; then
      die "${n} would allow the whole Internet. Re-run with --force if you really mean it."
    fi
    if printf '%s\n' "${existing[@]}" "${add[@]}" | grep -qxF -- "${n}"; then
      log "${n} is already allowed for ${comp}."
      continue
    fi
    add+=("${n}")
  done
  (( ${#add[@]} )) || { log "Nothing to change."; return 0; }
  {
    cat "${file}"
    for n in "${add[@]}"; do
      printf '%s  # added %s%s\n' "${n}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${comment:+ ${comment}}"
    done
  } | commit_allowlist "${comp}"
  log "Allowed for ${comp}: ${add[*]}"
}

cmd_remove() {
  local comp="$1"; shift
  (( $# )) || die "No address given."
  local file e n removed=() line addr
  file="$(allow_file "${comp}")"
  [[ -f "${file}" ]] || { log "Allowlist for ${comp} is empty."; return 0; }
  local -a targets=()
  for e in "$@"; do
    n="$(normalize_cidr "${e}")" || die "Invalid IP address or CIDR: ${e}"
    targets+=("${n}")
  done
  local tmp; tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    addr="${line%%#*}"; addr="${addr//[[:space:]]/}"
    if [[ -n "${addr}" ]] && n="$(normalize_cidr "${addr}" 2>/dev/null)" && printf '%s\n' "${targets[@]}" | grep -qxF -- "${n}"; then
      removed+=("${n}"); continue
    fi
    printf '%s\n' "${line}" >>"${tmp}"
  done <"${file}"
  if (( ${#removed[@]} == 0 )); then rm -f "${tmp}"; log "No matching entries in ${comp}."; return 0; fi
  commit_allowlist "${comp}" <"${tmp}"; rm -f "${tmp}"
  log "Removed from ${comp}: ${removed[*]}"
}

cmd_list() {
  local comp="${1:-all}" c
  if [[ "${comp}" == all ]]; then
    for c in "${COMPONENTS[@]}"; do echo "[${c}]"; cmd_list "${c}"; done; return 0
  fi
  valid_component "${comp}"
  local file; file="$(allow_file "${comp}")"
  if [[ ! -s "${file}" ]] || [[ -z "$(access_entries "${comp}")" ]]; then
    echo "  (empty: everyone is denied)"; return 0
  fi
  grep -Ev '^[[:space:]]*(#|$)' "${file}" | sed 's/^/  /'
}

# Is IP inside CIDR? (IPv4 and IPv6) -- compare network addresses.
ip_in_cidr() {
  local ip="$1" cidr="$2" prefix
  if [[ "${cidr}" == */* ]]; then prefix="${cidr##*/}"
  elif [[ "${cidr}" == *:* ]]; then prefix=128
  else prefix=32; fi
  [[ "$(normalize_cidr "${ip}/${prefix}" 2>/dev/null)" == "$(normalize_cidr "${cidr}")" ]]
}

cmd_check() {
  local comp="$1" ip="$2" e
  is_ipv4 "${ip}" || is_ipv6 "${ip}" || die "Invalid IP: ${ip}"
  while read -r e; do
    if ip_in_cidr "${ip}" "${e}"; then echo "ALLOWED (${comp}) via ${e}"; return 0; fi
  done < <(access_entries "${comp}")
  echo "DENIED (${comp})"; return 1
}

cmd_reset() {
  local comp="$1" confirm="${2:-}"
  [[ "${confirm}" == --yes ]] || die "This removes every ${comp} entry (deny all). Re-run with --yes."
  printf '# Reset %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | commit_allowlist "${comp}"
  log "${comp} allowlist cleared: everyone is denied."
}

main() {
  local cmd="${1:-}"; shift || true
  case "${cmd}" in -h|--help|help|"") usage 0 ;; esac
  config_load_server
  case "${cmd}" in
    add)    require_root; (( $# >= 2 )) || usage; valid_component "$1"; with_lock access cmd_add "$@" ;;
    remove) require_root; (( $# >= 2 )) || usage; valid_component "$1"; with_lock access cmd_remove "$@" ;;
    list)   cmd_list "${1:-all}" ;;
    check)  (( $# == 2 )) || usage; valid_component "$1"; cmd_check "$1" "$2" ;;
    apply)  require_root
            case "${1:-all}" in
              all) nginx_apply; component_deployed gitea && firewall_apply; true ;;
              *)   valid_component "$1"; apply_component "$1" ;;
            esac ;;
    reset)  require_root; (( $# >= 1 )) || usage; valid_component "$1"; with_lock access cmd_reset "$@" ;;
    *) usage ;;
  esac
}

main "$@"
