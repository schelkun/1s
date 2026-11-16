#!/usr/bin/env bash
# 1s host firewall rules: firewall.sh apply|status|remove
# apply  : (re)build the Git-over-SSH allowlist and container egress filters
# status : show the rules managed by 1s
# remove : remove every 1s rule (Git-over-SSH becomes reachable by everyone!)
set -euo pipefail
# shellcheck source=scripts/lib/firewall.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/firewall.sh"
require_root
config_load_server
case "${1:-}" in
  apply)  firewall_apply ;;
  status) firewall_status ;;
  remove) [[ "${2:-}" == --yes ]] || die "This opens Git-over-SSH to everyone. Re-run with --yes."; with_lock firewall firewall_remove ;;
  *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
