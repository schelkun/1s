#!/bin/bash
# Prepare the Ubuntu server (safe to re-run): copies this repository to the
# server over SSH and runs scripts/server/bootstrap.sh with your admin login.
#
#   scripts/macos/bootstrap-server.sh
. "$(dirname "$0")/common.sh"

tmp="/tmp/1s-bootstrap-$$"
info "Copying the repository to ${SERVER_SSH}:${tmp}"
COPYFILE_DISABLE=1 tar -C "${ROOT}" --exclude=.git --exclude=.env --exclude='.tmp-*' -czf - . |
  server "umask 077 && mkdir -p ${tmp} && tar -xzf - -C ${tmp}"
info "Running bootstrap (installs Docker, the restricted deploy user and the 1s tools)"
server_t "${SUDO} bash ${tmp}/scripts/server/bootstrap.sh; rc=\$?; rm -rf ${tmp}; exit \$rc"
info "Next: scripts/macos/push-config.sh"
