#!/usr/bin/env bash
# Real-host checks that are safe on ANY Linux machine (run as root):
#   * firewall rules built inside a private, throwaway network namespace
#     (`unshare -n`) -- the host firewall is never touched
#   * systemd calendar expressions, systemd-run, AppArmor version branch,
#     sudoers syntax (checked on a temporary file only)
# Nothing is installed, no service or container is started.
#
#   sudo tests/host-checks.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TESTS_DIR}/.." && pwd)"
# shellcheck source=tests/lib.sh
source "${TESTS_DIR}/lib.sh"

[[ "${EUID}" -eq 0 ]] || { echo "run as root (needs unshare -n)"; exit 2; }

# Inside the private namespace: apply the firewall and print the result.
if [[ "${1:-}" == --in-netns ]]; then
  export ONES_ETC="$2/etc" ONES_VAR="$2/var" ONES_LOCK_DIR="$2/lock"
  # shellcheck source=scripts/lib/firewall.sh
  source "${REPO}/scripts/lib/firewall.sh"
  env_load "${TESTS_DIR}/fixtures/test.env"; config_apply_defaults
  mkdir -p "${ONES_VAR}/state" "${ACCESS_DIR}"
  touch "${ONES_VAR}/state/gitea.deployed" "${ONES_VAR}/state/openhands.deployed"
  printf '198.51.100.10\n2001:db8:1::/48\n' >"${ACCESS_DIR}/gitea-ssh.allow"
  firewall_apply_locked >/dev/null 2>&1 || { echo "APPLY-FAILED"; exit 1; }
  iptables -w -S; echo "--- v6"; ip6tables -w -S
  echo "--- reapply"
  firewall_apply_locked >/dev/null 2>&1 || { echo "REAPPLY-FAILED"; exit 1; }
  iptables -w -S | grep -c -- '-j ONES-' ; ip6tables -w -S | grep -c -- '-j ONES-'
  echo "--- remove"
  firewall_remove >/dev/null 2>&1
  iptables -w -S | grep -c 'ONES-' || true
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT

echo "== firewall rules in a private network namespace (host firewall untouched)"
host_before="$(iptables -w -S | md5sum)"
OUT="${TMP}/fw.txt"
unshare -n bash "${BASH_SOURCE[0]}" --in-netns "${TMP}" >"${OUT}" 2>&1
assert_not_contains "apply succeeded" "${OUT}" 'APPLY-FAILED|REAPPLY-FAILED'
assert_contains "DOCKER-USER hook installed" "${OUT}" '^-A DOCKER-USER -j ONES-DU-[AB]$'
assert_contains "INPUT hook installed" "${OUT}" '^-A INPUT -j ONES-IN-[AB]$'
assert_contains "established traffic passes" "${OUT}" 'ctstate RELATED,ESTABLISHED -j RETURN'
assert_contains "allowlisted IPv4 may use Git SSH" "${OUT}" '-s 198\.51\.100\.10/32 -m conntrack --ctproto (tcp|6) --ctorigdst 203\.0\.113\.10(/32)? --ctorigdstport 2222 -j RETURN'
assert_contains "everyone else dropped (IPv4 Git SSH)" "${OUT}" '^-A ONES-DU-[AB] -m conntrack --ctproto (tcp|6) --ctorigdst 203\.0\.113\.10(/32)? --ctorigdstport 2222 -j DROP$'
assert_contains "allowlisted IPv6 may use Git SSH" "${OUT}" '-s 2001:db8:1::/48 -m conntrack --ctproto (tcp|6) --ctorigdst 2001:db8::10(/128)? --ctorigdstport 2222 -j RETURN'
assert_contains "everyone else dropped (IPv6 Git SSH)" "${OUT}" '^-A ONES-DU-[AB] -m conntrack --ctproto (tcp|6) --ctorigdst 2001:db8::10(/128)? --ctorigdstport 2222 -j DROP$'
assert_contains "agents blocked from metadata" "${OUT}" '-s 10\.204\.0\.0/16 -d 169\.254\.0\.0/16 -j DROP'
assert_contains "agents blocked from private nets" "${OUT}" '-s 10\.204\.0\.0/16 -d 10\.0\.0\.0/8 -j DROP'
assert_contains "CI jobs blocked from private nets" "${OUT}" '-s 10\.203\.0\.0/16 -d 192\.168\.0\.0/16 -j DROP'
assert_contains "runners may reach Gitea HTTPS" "${OUT}" '-s 10\.203\.0\.0/16 -d 203\.0\.113\.10/32 -p tcp -m tcp --dport 443 -j RETURN'
assert_contains "agents blocked from host services" "${OUT}" '^-A ONES-IN-[AB] -s 10\.204\.0\.0/16 -j DROP$'
assert_not_contains "agents not allowed to Gitea by default" "${OUT}" '-s 10\.204\.0\.0/16 -d 203\.0\.113\.10/32'
re_counts="$(sed -n '/--- reapply/,/--- remove/p' "${OUT}" | grep -E '^[0-9]+$' | tr '\n' ' ')"
assert_eq "re-apply keeps exactly one hook per chain (v4: 2, v6: 1)" "2 1 " "${re_counts}"
assert_eq "remove leaves no 1s rules" "0" "$(sed -n '/--- remove/,$p' "${OUT}" | grep -E '^[0-9]+$' | tail -n1)"
assert_eq "host firewall unchanged" "${host_before}" "$(iptables -w -S | md5sum)"

echo "== systemd"
if command -v systemd-analyze >/dev/null; then
  # shellcheck source=scripts/lib/config.sh
  source "${REPO}/scripts/lib/config.sh"
  while IFS='|' read -r name _ kind _ def _; do
    [[ "${kind}" == calendar ]] || continue
    assert_ok "OnCalendar default of ${name} valid" systemd-analyze calendar "${def}"
  done < <(schema_rows)
  for u in "${REPO}"/config/systemd/*.service "${REPO}"/config/systemd/*.timer; do
    # Only messages about our own unit; "not executable" is expected before install.
    msgs="$(systemd-analyze verify "${u}" 2>&1 | grep -F "$(basename "${u}")" | grep -v 'is not executable' || true)"
    assert_eq "unit file valid: $(basename "${u}")" "" "${msgs}"
  done
fi
assert_ok "systemd-run available (deploy access auto-expiry)" command -v systemd-run

echo "== sudoers rule (temporary file only)"
printf 'Defaults:deploy !requiretty, env_reset, !mail_badpass\ndeploy ALL=(root) NOPASSWD: /usr/local/lib/1s/gateway\n' >"${TMP}/sudoers"
assert_ok "sudoers rule parses" visudo -cqf "${TMP}/sudoers"

echo "== AppArmor"
if command -v apparmor_parser >/dev/null; then
  major="$(apparmor_parser --version | sed -n 's/.*version \([0-9]*\)\..*/\1/p' | head -n1)"
  if (( major >= 4 )); then
    assert_ok "runner profile compiles (AppArmor ${major})" apparmor_parser -QK "${REPO}/config/apparmor/1s-rootless-dind"
  else
    restrict="$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)"
    assert_eq "AppArmor ${major}.x: no userns restriction, runners use unconfined" absent "${restrict}"
  fi
fi
assert_ok "/dev/net/tun available for rootless runners" test -c /dev/net/tun

summary
