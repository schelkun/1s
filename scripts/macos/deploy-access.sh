#!/bin/bash
# Turn the temporary deployment access on or off (via your admin login,
# which these scripts never change).
#
#   scripts/macos/deploy-access.sh enable [--ttl 2h]   auto-disables after the TTL
#   scripts/macos/deploy-access.sh disable [--kill]    --kill also ends running sessions
#   scripts/macos/deploy-access.sh status
. "$(dirname "$0")/common.sh"

case "${1:-}" in
  enable)
    ttl="${DEPLOY_ACCESS_TTL}"
    [ "${2:-}" = "--ttl" ] && ttl="${3:?--ttl needs a value like 30m or 2h}"
    server_t "${SUDO} 1s deploy-access enable --ttl $(q "${ttl}")" ;;
  disable)
    kill=""; [ "${2:-}" = "--kill" ] && kill="--kill"
    server_t "${SUDO} 1s deploy-access disable ${kill}" ;;
  status)
    server_t "${SUDO} 1s deploy-access status" ;;
  *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
