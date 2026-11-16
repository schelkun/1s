#!/bin/bash
# Deploy with temporary access:
#   enable access -> you run the "Deploy" workflow on GitHub -> access is
#   disabled again (also on Ctrl-C or errors).
#
#   scripts/macos/deploy.sh [--ttl 2h]
#
# If this script is interrupted, access still expires after the TTL.
# To revoke immediately: scripts/macos/deploy-access.sh disable
. "$(dirname "$0")/common.sh"

ttl="${DEPLOY_ACCESS_TTL}"
[ "${1:-}" = "--ttl" ] && ttl="${2:?--ttl needs a value like 30m or 2h}"

disable() {
  trap - EXIT INT TERM
  info "Disabling deployment access"
  server_t "${SUDO} 1s deploy-access disable" ||
    echo "WARNING: could not disable access. Run: scripts/macos/deploy-access.sh disable (it also expires after ${ttl})." >&2
}

info "Enabling deployment access (expires automatically after ${ttl})"
server_t "${SUDO} 1s deploy-access enable --ttl $(q "${ttl}")"
trap disable EXIT
trap 'exit 130' INT TERM

url="https://github.com/${GITHUB_REPO:-<owner>/<repo>}/actions/workflows/deploy.yml"
echo
echo "Now open ${url}"
echo "click \"Run workflow\", choose target and action, and wait until it finishes."
[ -n "${GITHUB_REPO}" ] && command -v open >/dev/null && open "${url}"
printf 'Press Enter when the workflow has finished to disable access again... '
read -r _
