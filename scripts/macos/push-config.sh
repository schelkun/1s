#!/bin/bash
# Upload your .env to the server. The server validates it, keeps existing
# secrets, generates missing ones and stores everything as root-only files.
# Nothing is changed if the configuration is invalid. Run it after every
# change to .env, then deploy.
#
#   scripts/macos/push-config.sh
. "$(dirname "$0")/common.sh"

tmp=".1s-config-upload-$$"
info "Uploading .env to ${SERVER_SSH}"
server "umask 077 && cat > ${tmp}" <"${ENV_FILE}"
server_t "${SUDO} 1s config import < ${tmp}; rc=\$?; rm -f ${tmp}; exit \$rc"
