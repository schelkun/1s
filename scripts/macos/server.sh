#!/bin/bash
# Run any `1s` server command from your Mac, for example:
#
#   scripts/macos/server.sh status
#   scripts/macos/server.sh health
#   scripts/macos/server.sh config secret GITEA_ADMIN_PASSWORD
#   scripts/macos/server.sh openhands key alice
#   scripts/macos/server.sh certs check
#   scripts/macos/server.sh backup list gitea
. "$(dirname "$0")/common.sh"

[ $# -gt 0 ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
args=""
for a in "$@"; do args="${args} $(q "${a}")"; done
server_t "${SUDO} 1s${args}"
