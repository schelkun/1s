#!/bin/bash
# Manage the server allowlists from your Mac.
#
#   scripts/macos/ip-access.sh add    <gitea|openhands|gitea-ssh> <ip|cidr|me>... [--comment TEXT]
#   scripts/macos/ip-access.sh remove <gitea|openhands|gitea-ssh> <ip|cidr|me>...
#   scripts/macos/ip-access.sh list   [<component>]
#   scripts/macos/ip-access.sh check  <component> <ip|me>
#
# "me" is the public address your SSH connection comes from (usually the
# address your browser uses too).
. "$(dirname "$0")/common.sh"

[ $# -gt 0 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
me=""
args=""
for a in "$@"; do
  if [ "${a}" = "me" ]; then
    if [ -z "${me}" ]; then
      me="$(server 'printf "%s" "${SSH_CLIENT%% *}"')"
      [ -n "${me}" ] || die "Could not determine your address."
      info "Your address as seen by the server: ${me}"
    fi
    a="${me}"
  fi
  args="${args} $(q "${a}")"
done
server_t "${SUDO} 1s ip-access${args}"
