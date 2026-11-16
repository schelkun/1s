# shellcheck shell=bash
# Host firewall rules managed by 1s (iptables/ip6tables, nft backend friendly).
#
# Only two hooks are added, never touching the rest of your firewall:
#   DOCKER-USER -> ONES-DU-{A,B}   (traffic forwarded to/from containers)
#   INPUT       -> ONES-IN-{A,B}   (traffic from 1s containers to the host)
#
# Rules:
#   * Git-over-SSH: default deny; only gitea-ssh allowlist entries may connect
#     to GITEA_SSH_BIND_IP(6):GITEA_SSH_PORT (matched on the pre-DNAT address).
#   * OpenHands agents / CI runners: optional egress block to private,
#     link-local and metadata networks and to host services.
# New chains are fully built before the jump is swapped (A/B), so a failure
# never leaves the host half-configured.

# shellcheck source=scripts/lib/nginx.sh
source "$(dirname "${BASH_SOURCE[0]}")/nginx.sh"

FW_PRIVATE_V4=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 0.0.0.0/8 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4)

_fw_active() { # _fw_active IPT PREFIX -> A|B|none
  local ipt="$1" prefix="$2" hook="$3"
  if "${ipt}" -w -S "${hook}" 2>/dev/null | grep -q -- "-j ${prefix}-A\$"; then echo A
  elif "${ipt}" -w -S "${hook}" 2>/dev/null | grep -q -- "-j ${prefix}-B\$"; then echo B
  else echo none; fi
}

# _fw_swap IPT HOOK PREFIX RULES_FN -- build PREFIX-{A|B} via RULES_FN and swap.
_fw_swap() {
  local ipt="$1" hook="$2" prefix="$3" fn="$4" cur new
  cur="$(_fw_active "${ipt}" "${prefix}" "${hook}")"
  if [[ "${cur}" == A ]]; then new=B; else new=A; fi
  "${ipt}" -w -N "${prefix}-${new}" 2>/dev/null || "${ipt}" -w -F "${prefix}-${new}"
  if ! "${fn}" "${ipt}" "${prefix}-${new}"; then
    "${ipt}" -w -F "${prefix}-${new}"; "${ipt}" -w -X "${prefix}-${new}" 2>/dev/null || true
    return 1
  fi
  "${ipt}" -w -I "${hook}" 1 -j "${prefix}-${new}"
  if [[ "${cur}" != none ]]; then
    while "${ipt}" -w -D "${hook}" -j "${prefix}-${cur}" 2>/dev/null; do :; done
    "${ipt}" -w -F "${prefix}-${cur}"; "${ipt}" -w -X "${prefix}-${cur}"
  fi
}

_fw_ssh_targets() { # print "ip" lines of SSH bind addresses for this family
  local fam="$1"
  component_deployed gitea || return 0
  if [[ "${fam}" == 4 ]]; then printf '%s\n' "${GITEA_SSH_BIND_IP}"
  elif is_true "${ENABLE_IPV6:-false}" && [[ -n "${GITEA_SSH_BIND_IP6:-}" ]]; then printf '%s\n' "$(ipv6_compress "${GITEA_SSH_BIND_IP6}")"
  fi
}

_fw_rules_docker_user() {
  local ipt="$1" chain="$2" fam=4 ip e
  [[ "${ipt}" == ip6tables ]] && fam=6
  "${ipt}" -w -A "${chain}" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN || return 1

  while read -r ip; do
    [[ -n "${ip}" ]] || continue
    local m=(-m conntrack --ctproto tcp --ctorigdst "${ip}" --ctorigdstport "${GITEA_SSH_PORT}")
    if [[ "${fam}" == 4 ]] && component_deployed openhands && is_true "${OPENHANDS_ALLOW_GITEA:-false}"; then
      "${ipt}" -w -A "${chain}" -s "$(normalize_cidr "${OPENHANDS_SUBNET_POOL}")" "${m[@]}" -j RETURN || return 1
    fi
    while read -r e; do
      if [[ "${fam}" == 4 && "${e}" == *:* ]] || [[ "${fam}" == 6 && "${e}" != *:* ]]; then continue; fi
      "${ipt}" -w -A "${chain}" -s "${e}" "${m[@]}" -j RETURN || return 1
    done < <(access_entries gitea-ssh | sort -u)
    "${ipt}" -w -A "${chain}" "${m[@]}" -j DROP || return 1
  done < <(_fw_ssh_targets "${fam}")

  if [[ "${fam}" == 4 ]]; then
    local pool net
    for pool in $(_fw_blocked_pools); do
      for net in "${FW_PRIVATE_V4[@]}"; do
        "${ipt}" -w -A "${chain}" -s "${pool}" -d "${net}" -j DROP || return 1
      done
    done
  fi
  "${ipt}" -w -A "${chain}" -j RETURN
}

# Container pools whose egress to private networks/host is blocked.
_fw_blocked_pools() {
  if component_deployed openhands && is_true "${OPENHANDS_BLOCK_PRIVATE_EGRESS:-true}"; then
    normalize_cidr "${OPENHANDS_SUBNET_POOL}"; fi
  if component_deployed gitea && is_true "${GITEA_RUNNER_BLOCK_PRIVATE_EGRESS:-true}"; then
    normalize_cidr "${GITEA_RUNNER_SUBNET_POOL}"; fi
}

_fw_rules_input() {
  local ipt="$1" chain="$2" pool
  "${ipt}" -w -A "${chain}" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN || return 1
  if component_deployed gitea; then
    # Runners reach Gitea through Nginx (HTTPS) on the Gitea bind address.
    "${ipt}" -w -A "${chain}" -s "$(normalize_cidr "${GITEA_RUNNER_SUBNET_POOL}")" -d "${GITEA_BIND_IP}" -p tcp --dport 443 -j RETURN || return 1
    if component_deployed openhands && is_true "${OPENHANDS_ALLOW_GITEA:-false}"; then
      "${ipt}" -w -A "${chain}" -s "$(normalize_cidr "${OPENHANDS_SUBNET_POOL}")" -d "${GITEA_BIND_IP}" -p tcp --dport 443 -j RETURN || return 1
    fi
  fi
  for pool in $(_fw_blocked_pools); do
    "${ipt}" -w -A "${chain}" -s "${pool}" -j DROP || return 1
  done
  "${ipt}" -w -A "${chain}" -j RETURN
}

firewall_apply_locked() {
  require_cmd iptables
  iptables -w -N DOCKER-USER 2>/dev/null || true
  _fw_swap iptables DOCKER-USER ONES-DU _fw_rules_docker_user || { err "Failed to apply IPv4 DOCKER-USER rules"; return 1; }
  _fw_swap iptables INPUT ONES-IN _fw_rules_input || { err "Failed to apply IPv4 INPUT rules"; return 1; }
  if command -v ip6tables >/dev/null && ip6tables -w -S >/dev/null 2>&1; then
    ip6tables -w -N DOCKER-USER 2>/dev/null || true
    _fw_swap ip6tables DOCKER-USER ONES-DU _fw_rules_docker_user || { err "Failed to apply IPv6 DOCKER-USER rules"; return 1; }
  fi
  log "Firewall rules applied."
}

firewall_apply() { with_lock firewall firewall_apply_locked; }

firewall_status() {
  local ipt
  for ipt in iptables ip6tables; do
    command -v "${ipt}" >/dev/null || continue
    echo "== ${ipt}"
    "${ipt}" -w -S 2>/dev/null | grep -E -- '(-N|-A) ONES-|-j ONES-' || echo "(no 1s rules)"
  done
}

firewall_remove() {
  local ipt hook prefix s
  for ipt in iptables ip6tables; do
    command -v "${ipt}" >/dev/null || continue
    for hook in DOCKER-USER INPUT; do
      for prefix in ONES-DU ONES-IN; do
        for s in A B; do
          while "${ipt}" -w -D "${hook}" -j "${prefix}-${s}" 2>/dev/null; do :; done
          "${ipt}" -w -F "${prefix}-${s}" 2>/dev/null || true
          "${ipt}" -w -X "${prefix}-${s}" 2>/dev/null || true
        done
      done
    done
  done
  log "1s firewall rules removed."
}
