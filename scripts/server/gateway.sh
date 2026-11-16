#!/usr/bin/env bash
# 1s deployment gateway: the ONLY program the deployment SSH key can run.
#
# Installed by bootstrap.sh as /usr/local/lib/1s/gateway and referenced by a
# `restrict,command="..."` entry in the deploy user's root-owned
# authorized_keys. It accepts a fixed set of verbs, validates every argument,
# then re-executes itself as root through a single sudoers rule.
#
#   ping
#   status
#   deploy   <all|shared|gitea|openhands> <git-sha>   (bundle on stdin)
#
# Bundles contain only code. Settings and secrets are stored on the server
# (`1s config import`), never sent by GitHub.
#   health   <shared|gitea|openhands|all>
#   backup   <gitea|openhands>
#   rollback <shared|gitea|openhands> [--restore-data]
set -euo pipefail
umask 077

SELF=/usr/local/lib/1s/gateway
ONES_OPT=/opt/1s
ONES_VAR=/var/lib/1s
LOG_DIR=/var/log/1s
MAX_BUNDLE_BYTES=$((512 * 1024 * 1024))
KEEP_RELEASES=8

reject() { echo "1s-gateway: rejected: $*" >&2; exit 64; }

validate() {
  local verb="${1:-}"
  case "${verb}" in
    ping|status) (( $# == 1 )) || reject "usage" ;;
    deploy) (( $# == 3 )) || reject "usage: deploy <target> <sha>"
            [[ "$2" =~ ^(all|shared|gitea|openhands)$ ]] || reject "target"
            [[ "$3" =~ ^[0-9a-f]{40}$ ]] || reject "sha" ;;
    health) (( $# == 2 )) || reject "usage: health <target>"
            [[ "$2" =~ ^(shared|gitea|openhands|all)$ ]] || reject "target" ;;
    backup) (( $# == 2 )) || reject "usage: backup <target>"
            [[ "$2" =~ ^(gitea|openhands)$ ]] || reject "target" ;;
    rollback) (( $# == 2 || $# == 3 )) || reject "usage: rollback <target> [--restore-data]"
              [[ "$2" =~ ^(shared|gitea|openhands)$ ]] || reject "target"
              [[ $# == 2 || "$3" == --restore-data ]] || reject "flag" ;;
    *) reject "unknown verb '${verb}'" ;;
  esac
}

if [[ "${EUID}" -ne 0 ]]; then
  # Invoked by sshd as the deploy user. Never eval the client command.
  read -r -a argv <<<"${SSH_ORIGINAL_COMMAND:-}"
  (( ${#argv[@]} >= 1 && ${#argv[@]} <= 3 )) || reject "bad command"
  validate "${argv[@]}"
  exec sudo -n "${SELF}" "${argv[@]}"
fi

validate "$@"
install -d -m 0750 "${LOG_DIR}"
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) gateway: $* (from ${SUDO_USER:-root})" >>"${LOG_DIR}/gateway.log"
exec > >(tee -a "${LOG_DIR}/gateway.log") 2>&1

tools() { [[ -x "${ONES_OPT}/tools/scripts/server/1s" ]] || reject "not deployed yet"; printf '%s\n' "${ONES_OPT}/tools"; }

state_release() { cat "${ONES_VAR}/state/$1.release" 2>/dev/null || true; }

lock_target() { # lock_target TARGET CMD...
  install -d /run/lock
  local t="$1"; shift
  ( flock -w 3600 9 || reject "lock timeout"; "$@" ) 9>"/run/lock/1s-deploy-${t}.lock"
}

install_release() { # SHA BUNDLE_DIR
  local sha="$1" b="$2" dest="${ONES_OPT}/releases/$1"
  if [[ -d "${dest}" ]]; then echo "Release ${sha} already present."; return 0; fi
  install -d -m 0755 "${ONES_OPT}/releases"
  local tmp="${ONES_OPT}/releases/.incoming-${sha}-$$"
  install -d -m 0755 "${tmp}"
  tar -xzf "${b}/release.tar.gz" -C "${tmp}" --no-same-owner
  [[ -x "${tmp}/scripts/deploy/deploy-shared.sh" ]] || { rm -rf -- "${tmp}"; reject "bundle is not a 1s release"; }
  chown -R root:root "${tmp}"; chmod -R go-w "${tmp}"
  mv "${tmp}" "${dest}"
  echo "Release ${sha} installed."
}

prune_releases() {
  local keep=" " r f
  for f in "${ONES_VAR}"/state/*.release "${ONES_VAR}"/state/*.history; do
    [[ -f "${f}" ]] || continue
    for r in $(awk '{print $NF}' "${f}" | tail -n 3); do keep+="${r} "; done
  done
  keep+="$(basename "$(readlink -f "${ONES_OPT}/tools" 2>/dev/null)") "
  local all=() n=0
  mapfile -t all < <(ls -1t "${ONES_OPT}/releases" 2>/dev/null)
  for r in "${all[@]}"; do
    [[ "${r}" =~ ^[0-9a-f]{40}$ ]] || continue
    n=$((n + 1))
    if (( n > KEEP_RELEASES )) && [[ "${keep}" != *" ${r} "* ]]; then rm -rf -- "${ONES_OPT}/releases/${r:?}"; fi
  done
}

do_deploy() {
  local target="$1" sha="$2" work
  install -d -m 0700 "${ONES_OPT}/incoming"
  work="$(mktemp -d "${ONES_OPT}/incoming/${sha}.XXXXXX")"
  head -c $((MAX_BUNDLE_BYTES + 1)) >"${work}/bundle.tar"
  (( $(stat -c %s "${work}/bundle.tar") <= MAX_BUNDLE_BYTES )) || { rm -rf -- "${work}"; reject "bundle too large"; }
  mkdir "${work}/b"
  tar -xf "${work}/bundle.tar" -C "${work}/b" --no-same-owner --no-same-permissions \
    release.tar.gz meta.env 2>/dev/null || { rm -rf -- "${work}"; reject "malformed bundle"; }
  [[ -z "$(find "${work}/b" -type l -print -quit)" ]] || { rm -rf -- "${work}"; reject "symlinks in bundle"; }
  install_release "${sha}" "${work}/b"
  rm -rf -- "${work}"
  "${ONES_OPT}/releases/${sha}/scripts/deploy/deploy-${target}.sh"
  prune_releases
}

do_rollback() {
  local target="$1" restore="${2:-}" cur prev
  cur="$(state_release "${target}")"
  [[ -n "${cur}" ]] || reject "${target} has no recorded release"
  prev="$(awk '{print $2}' "${ONES_VAR}/state/${target}.history" | awk -v c="${cur}" '$0 != c' | tail -n 1)"
  [[ -n "${prev}" && -d "${ONES_OPT}/releases/${prev}" ]] || reject "no previous release available for ${target}"
  echo "Rolling ${target} back from ${cur} to ${prev}"
  if [[ "${restore}" == --restore-data ]]; then
    [[ "${target}" != shared ]] || reject "shared has no data to restore"
    local rec rel id
    rec="$(cat "${ONES_VAR}/state/${target}.predeploy-backup" 2>/dev/null || true)"
    rel="${rec%% *}"; id="${rec##* }"
    [[ -n "${id}" && "${rel}" == "${prev}" ]] || reject "no pre-deployment backup recorded for release ${prev}"
    "${ONES_OPT}/releases/${prev}/scripts/backup/backup.sh" restore "${target}" "${id}" --yes --no-start
  fi
  "${ONES_OPT}/releases/${prev}/scripts/deploy/deploy-${target}.sh"
}

case "$1" in
  ping)     echo pong ;;
  status)   "$(tools)/scripts/server/1s" status ;;
  deploy)   lock_target "$2" do_deploy "$2" "$3" ;;
  health)   "$(tools)/scripts/health/health.sh" "$2" ;;
  backup)   "$(tools)/scripts/backup/backup.sh" create "$2" --tag manual ;;
  rollback) lock_target "$2" do_rollback "$2" "${3:-}" ;;
esac
