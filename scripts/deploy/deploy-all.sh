#!/usr/bin/env bash
# Deploy shared infrastructure, then every enabled component
# (ENABLE_GITEA / ENABLE_OPENHANDS in the server configuration).
set -euo pipefail

# shellcheck source=scripts/lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

require_root
require_config
config_load_server
dir="$(dirname "${BASH_SOURCE[0]}")"
"${dir}/deploy-shared.sh"
if is_true "${ENABLE_GITEA}"; then "${dir}/deploy-gitea.sh"; else log "Gitea disabled (ENABLE_GITEA=false)."; fi
if is_true "${ENABLE_OPENHANDS}"; then "${dir}/deploy-openhands.sh"; else log "OpenHands disabled (ENABLE_OPENHANDS=false)."; fi
