#!/usr/bin/env bash
# Build a deployment bundle (tar on stdout) for the server gateway:
# the code of one commit plus a small metadata file. Settings and secrets are
# NOT included: they live on the server (`1s config import`).
#
#   make-bundle.sh <git-sha> > bundle.tar
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sha="${1:?usage: make-bundle.sh <git-sha>}"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid sha: ${sha}" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
git -C "${root}" archive --format=tar.gz -o "${work}/release.tar.gz" "${sha}"
printf 'SHA=%s\nCREATED=%s\nGITHUB_RUN_ID=%s\nGITHUB_ACTOR=%s\n' \
  "${sha}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GITHUB_RUN_ID:-local}" "${GITHUB_ACTOR:-local}" >"${work}/meta.env"
tar -C "${work}" -cf - release.tar.gz meta.env
