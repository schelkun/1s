#!/usr/bin/env bash
# GitHub Actions entry point: run ACTION for TARGET over the restricted
# deployment SSH connection (host alias "1s-server", written by the workflow).
#
#   ci-run.sh <all|shared|gitea|openhands> <deploy|health|backup|rollback|status> [--restore-data]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target="${1:?target}"; action="${2:?action}"; flag="${3:-}"
remote() { ssh -T 1s-server "$@"; }

if ! remote ping >/dev/null; then
  echo "::error::Cannot reach the deployment gateway. Enable access first: scripts/macos/deploy-access.sh enable" >&2
  exit 1
fi

case "${action}" in
  deploy)
    sha="$(git -C "${root}" rev-parse HEAD)"
    "${root}/scripts/deploy/make-bundle.sh" "${sha}" | remote deploy "${target}" "${sha}" ;;
  health)
    remote health "${target}" ;;
  status)
    remote status ;;
  backup)
    if [[ "${target}" == all ]]; then remote backup gitea || true; remote backup openhands || true
    else remote backup "${target}"; fi ;;
  rollback)
    [[ "${target}" != all ]] || { echo "::error::Roll back one component at a time." >&2; exit 1; }
    remote rollback "${target}" ${flag:+"${flag}"} ;;
  *) echo "invalid action: ${action}" >&2; exit 1 ;;
esac
