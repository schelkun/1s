#!/usr/bin/env bash
# Local backups (server only). Gitea and OpenHands are fully independent.
#
#   backup.sh create  <gitea|openhands> [--tag NAME] [--print-id]
#   backup.sh list    <gitea|openhands>
#   backup.sh verify  <gitea|openhands> <backup-id|latest>
#   backup.sh restore <gitea|openhands> <backup-id|latest> --yes [--user NAME]
#                     [--no-safety-backup] [--restore-secrets] [--no-start]
#   backup.sh prune   <gitea|openhands>
#
# Layout: ${BACKUP_DIR}/<component>/<YYYYmmddTHHMMSSZ>[-tag]/ with
#   gitea:     db.dump (pg_dump -Fc), data.tar.gz, config.tar.gz
#   openhands: users/<name>/{data,projects}.tar.gz
#   both:      server-config.tar.gz (settings, secrets, allowlists, state),
#              manifest.env, SHA256SUMS
# Directories are 0700 and files 0600 (they contain secrets).
set -euo pipefail

# shellcheck source=scripts/lib/deploy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/deploy.sh"

NO_START=false

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

comp_dir() { printf '%s/%s\n' "${BACKUP_DIR}" "$1"; }

resolve_id() { # resolve_id COMP ID|latest -> path
  local comp="$1" id="$2" dir
  dir="$(comp_dir "${comp}")"
  if [[ "${id}" == latest ]]; then
    id="$(find "${dir}" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' 2>/dev/null | sort | tail -n1)"
    [[ -n "${id}" ]] || die "No ${comp} backups in ${dir}"
  fi
  [[ "${id}" =~ ^[0-9]{8}T[0-9]{6}Z(-[a-z0-9-]+)?$ ]] || die "Invalid backup id: ${id}"
  [[ -d "${dir}/${id}" ]] || die "Backup not found: ${dir}/${id}"
  printf '%s/%s\n' "${dir}" "${id}"
}

# Archive a named volume to FILE through a read-only helper container.
volume_tar() {
  local vol="$1" out="$2"
  docker volume inspect "${vol}" >/dev/null 2>&1 || die "Volume ${vol} does not exist"
  docker run --rm --network none -v "${vol}:/src:ro" "${HELPER_IMAGE}" \
    tar -C /src -czf - . >"${out}.tmp"
  mv -f "${out}.tmp" "${out}"
}

# Replace the contents of a named volume with an archive (ownership preserved).
volume_restore() {
  local vol="$1" in="$2"
  docker volume create "${vol}" >/dev/null
  docker run --rm -i --network none -v "${vol}:/dst" "${HELPER_IMAGE}" \
    sh -c 'find /dst -mindepth 1 -delete && tar -C /dst -xzpf -' <"${in}"
}

server_config_tar() { # COMP OUT
  local comp="$1" out="$2" files=()
  local f
  for f in "config/${comp}.env" "secrets/${comp}.env" "config/shared.env"; do
    [[ -f "${ONES_ETC}/${f}" ]] && files+=("etc/${f}")
  done
  if [[ "${comp}" == gitea ]]; then
    for f in access/gitea.allow access/gitea-ssh.allow; do [[ -f "${ONES_ETC}/${f}" ]] && files+=("etc/${f}"); done
  else
    [[ -f "${ONES_ETC}/access/openhands.allow" ]] && files+=("etc/access/openhands.allow")
    [[ -f "${OH_USERS_MAP}" ]] && files+=("var/openhands/users.map")
  fi
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "${tmp}/etc" "${tmp}/var"
  for f in "${files[@]}"; do
    mkdir -p "${tmp}/$(dirname "${f}")"
    case "${f}" in etc/*) cp -p "${ONES_ETC}/${f#etc/}" "${tmp}/${f}" ;; var/*) cp -p "${ONES_VAR}/${f#var/}" "${tmp}/${f}" ;; esac
  done
  tar -C "${tmp}" -czf "${out}" .
  rm -rf -- "${tmp}"
}

write_manifest() { # DIR COMP TAG
  local dir="$1" comp="$2" tag="$3"
  {
    printf 'COMPONENT=%s\n' "${comp}"
    printf 'CREATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'TAG=%s\n' "${tag}"
    printf 'HOST=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'RELEASE=%s\n' "$(current_release "${comp}")"
    if [[ "${comp}" == gitea ]]; then
      printf 'GITEA_IMAGE=%s\nPOSTGRES_IMAGE=%s\n' "${GITEA_IMAGE}" "${GITEA_POSTGRES_IMAGE}"
      printf 'GITEA_VERSION=%s\n' "$(docker exec "${ONES_PREFIX}-gitea" gitea --version 2>/dev/null | awk '{print $3}' || true)"
      printf 'SECRET_KEY_SHA256=%s\n' "$(printf '%s' "${GITEA_SECRET_KEY}" | sha256sum | cut -c1-16)"
    else
      printf 'OPENHANDS_IMAGE=%s\nUSERS=%s\n' "${OPENHANDS_IMAGE}" "$(cut -d' ' -f1 "${OH_USERS_MAP}" 2>/dev/null | tr '\n' ' ')"
    fi
  } >"${dir}/manifest.env"
}

finalize() { # DIR
  local dir="$1"
  ( cd "${dir}" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs -r sha256sum ) >"${dir}.sums"
  mv -f "${dir}.sums" "${dir}/SHA256SUMS"
  find "${dir}" -type d -exec chmod 0700 {} + ; find "${dir}" -type f -exec chmod 0600 {} +
}

backup_gitea() {
  local dir="$1" stopped=false
  log "Dumping PostgreSQL (consistent snapshot)"
  docker exec "${ONES_PREFIX}-gitea-db" pg_dump -U gitea -d gitea -Fc -Z 6 >"${dir}/db.dump.tmp"
  mv "${dir}/db.dump.tmp" "${dir}/db.dump"
  if is_true "${GITEA_BACKUP_STOP_SERVICE}"; then
    log "Stopping Gitea for a fully consistent repository archive"
    docker stop -t 60 "${ONES_PREFIX}-gitea" >/dev/null && stopped=true
  fi
  local rc=0
  log "Archiving repositories and application data"
  { volume_tar "${ONES_PREFIX}-gitea-data" "${dir}/data.tar.gz" \
    && volume_tar "${ONES_PREFIX}-gitea-config" "${dir}/config.tar.gz"; } || rc=$?
  if [[ "${stopped}" == true ]]; then docker start "${ONES_PREFIX}-gitea" >/dev/null; fi
  return "${rc}"
}

backup_openhands() {
  local dir="$1" user idx c running
  [[ -f "${OH_USERS_MAP}" ]] || { warn "No OpenHands users deployed."; return 0; }
  while read -r user idx; do
    c="${ONES_PREFIX}-openhands-${user}"
    docker volume inspect "${c}-data" >/dev/null 2>&1 || continue
    mkdir -p "${dir}/users/${user}"
    running="$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)"
    if [[ "${running}" == true ]] && is_true "${OPENHANDS_BACKUP_STOP_SERVICE}"; then
      log "OpenHands ${user}: stopping for a consistent archive"
      docker stop -t 60 "${c}" >/dev/null
    fi
    volume_tar "${c}-data" "${dir}/users/${user}/data.tar.gz"
    volume_tar "${c}-projects" "${dir}/users/${user}/projects.tar.gz"
    if [[ "${running}" == true ]] && is_true "${OPENHANDS_BACKUP_STOP_SERVICE}"; then
      docker start "${c}" >/dev/null
    fi
    log "OpenHands ${user}: archived"
  done <"${OH_USERS_MAP}"
}

cmd_create() {
  local comp="$1"; shift
  local tag="" print_id=false
  while (( $# )); do
    case "$1" in
      --tag) tag="$2"; [[ "${tag}" =~ ^[a-z0-9-]{1,32}$ ]] || die "Invalid tag"; shift 2 ;;
      --print-id) print_id=true; shift ;;
      *) usage ;;
    esac
  done
  component_deployed "${comp}" || die "${comp} is not deployed."
  local id dir
  id="$(date -u +%Y%m%dT%H%M%SZ)${tag:+-${tag}}"
  dir="$(comp_dir "${comp}")/${id}"
  install -d -m 0700 "$(comp_dir "${comp}")"
  install -d -m 0700 "${dir}.partial"
  log "Creating ${comp} backup ${id}"
  if ! { "backup_${comp}" "${dir}.partial" && server_config_tar "${comp}" "${dir}.partial/server-config.tar.gz" \
         && write_manifest "${dir}.partial" "${comp}" "${tag}" && finalize "${dir}.partial"; }; then
    rm -rf -- "${dir}.partial"; die "Backup failed; partial data removed."
  fi
  mv "${dir}.partial" "${dir}"
  cmd_verify "${comp}" "${id}" >/dev/null
  log "Backup complete: ${dir} ($(du -sh "${dir}" | cut -f1))"
  cmd_prune "${comp}"
  if [[ "${print_id}" == true ]]; then printf '%s\n' "${id}"; fi
}

cmd_list() {
  local comp="$1" d
  for d in $(find "$(comp_dir "${comp}")" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' 2>/dev/null | sort); do
    printf '%-40s %8s\n' "${d}" "$(du -sh "$(comp_dir "${comp}")/${d}" | cut -f1)"
  done
}

cmd_verify() {
  local comp="$1" dir f
  dir="$(resolve_id "${comp}" "$2")"
  ( cd "${dir}" && sha256sum --quiet -c SHA256SUMS ) || die "Checksum verification failed for ${dir}"
  while read -r f; do
    gzip -t "${dir}/${f}" || die "Corrupt archive: ${f}"
  done < <(cd "${dir}" && find . -name '*.tar.gz' -printf '%P\n')
  if [[ -f "${dir}/db.dump" ]]; then
    docker run --rm -i --network none --entrypoint pg_restore "${GITEA_POSTGRES_IMAGE}" -l <"${dir}/db.dump" >/dev/null \
      || die "PostgreSQL dump is not readable: ${dir}/db.dump"
  fi
  log "Backup verified: ${dir}"
}

cmd_prune() {
  local comp="$1" days keep all=() i d now age
  if [[ "${comp}" == gitea ]]; then days="${GITEA_BACKUP_RETENTION_DAYS}"; keep="${GITEA_BACKUP_KEEP_MIN}"
  else days="${OPENHANDS_BACKUP_RETENTION_DAYS}"; keep="${OPENHANDS_BACKUP_KEEP_MIN}"; fi
  mapfile -t all < <(find "$(comp_dir "${comp}")" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' 2>/dev/null | sort -r)
  now="$(date +%s)"
  for ((i = keep; i < ${#all[@]}; i++)); do
    d="$(comp_dir "${comp}")/${all[i]}"
    age=$(( (now - $(stat -c %Y "${d}")) / 86400 ))
    if (( age >= days )); then log "Pruning ${d} (${age} days old)"; rm -rf -- "${d:?}"; fi
  done
  find "$(comp_dir "${comp}")" -mindepth 1 -maxdepth 1 -type d -name '*.partial' -mmin +720 -exec rm -rf -- {} + 2>/dev/null || true
}

restore_gitea() {
  local dir="$1"
  local db="${ONES_PREFIX}-gitea-db" app="${ONES_PREFIX}-gitea"
  log "Stopping Gitea"
  docker stop -t 60 "${app}" >/dev/null
  log "Restoring PostgreSQL"
  docker exec -i "${db}" psql -q -v ON_ERROR_STOP=1 -U gitea -d postgres >/dev/null <<'SQL'
DROP DATABASE IF EXISTS gitea WITH (FORCE);
CREATE DATABASE gitea OWNER gitea;
SQL
  docker exec -i "${db}" pg_restore -U gitea -d gitea --no-owner --role=gitea --exit-on-error <"${dir}/db.dump"
  log "Restoring repositories and configuration volumes"
  volume_restore "${ONES_PREFIX}-gitea-data" "${dir}/data.tar.gz"
  volume_restore "${ONES_PREFIX}-gitea-config" "${dir}/config.tar.gz"
  if [[ "${NO_START}" == true ]]; then log "Leaving Gitea stopped (--no-start)."; return 0; fi
  docker start "${app}" >/dev/null
  wait_healthy "${app}" 300
}

restore_openhands() {
  local dir="$1" only="$2" user c
  for user in $(find "${dir}/users" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort); do
    [[ -z "${only}" || "${only}" == "${user}" ]] || continue
    c="${ONES_PREFIX}-openhands-${user}"
    log "OpenHands ${user}: restoring"
    docker stop -t 60 "${c}" >/dev/null 2>&1 || true
    volume_restore "${c}-data" "${dir}/users/${user}/data.tar.gz"
    volume_restore "${c}-projects" "${dir}/users/${user}/projects.tar.gz"
    if [[ "${NO_START}" != true ]] && docker inspect "${c}" >/dev/null 2>&1; then docker start "${c}" >/dev/null; wait_healthy "${c}" 600; fi
  done
}

cmd_restore() {
  local comp="$1" id="$2"; shift 2
  local yes=false safety=true secrets=false only=""
  while (( $# )); do
    case "$1" in
      --yes) yes=true; shift ;;
      --no-safety-backup) safety=false; shift ;;
      --restore-secrets) secrets=true; shift ;;
      --user) only="$2"; shift 2 ;;
      --no-start) NO_START=true; shift ;;
      *) usage ;;
    esac
  done
  local dir; dir="$(resolve_id "${comp}" "${id}")"
  [[ "${yes}" == true ]] || die "Restoring REPLACES the current ${comp} data with ${dir}. Re-run with --yes."
  [[ -z "${only}" || "${comp}" == openhands ]] || die "--user only applies to openhands"
  component_deployed "${comp}" || die "Deploy ${comp} first, then restore into it."
  cmd_verify "${comp}" "$(basename "${dir}")"
  if [[ "${safety}" == true ]]; then
    log "Creating safety backup before restore"
    cmd_create "${comp}" --tag pre-restore
  fi
  if [[ "${comp}" == gitea ]]; then
    local want; want="$(sed -n 's/^SECRET_KEY_SHA256=//p' "${dir}/manifest.env")"
    if [[ -n "${want}" && "${want}" != "$(printf '%s' "${GITEA_SECRET_KEY}" | sha256sum | cut -c1-16)" && "${secrets}" != true ]]; then
      die "The backup was made with a different GITEA_SECRET_KEY. Re-run with --restore-secrets (and update the GitHub secret to match), or encrypted data (2FA, tokens) will be unreadable."
    fi
    restore_gitea "${dir}"
  else
    restore_openhands "${dir}" "${only}"
  fi
  if [[ "${secrets}" == true ]]; then
    local tmp; tmp="$(mktemp -d)"
    tar -C "${tmp}" -xzf "${dir}/server-config.tar.gz"
    if [[ -f "${tmp}/etc/secrets/${comp}.env" ]]; then
      install -m 0600 "${tmp}/etc/secrets/${comp}.env" "${ONES_ETC}/secrets/${comp}.env"
      warn "Secrets restored from the backup. Update the GitHub secrets to the same values, or the next deployment overwrites them."
    fi
    rm -rf -- "${tmp}"
    [[ "${comp}" == gitea ]] && warn "Re-run the Gitea deployment so the restored secrets are applied."
  fi
  log "Restore of ${comp} from $(basename "${dir}") complete."
  [[ "${NO_START}" == true ]] || "${ONES_ROOT}/scripts/health/health.sh" "${comp}" || true
}

main() {
  require_root
  local cmd="${1:-}" comp="${2:-}"
  [[ -n "${cmd}" ]] || usage
  [[ "${comp}" == gitea || "${comp}" == openhands ]] || usage
  shift 2
  config_load_server
  case "${cmd}" in
    create)  with_lock "backup-${comp}" cmd_create "${comp}" "$@" ;;
    list)    cmd_list "${comp}" ;;
    verify)  [[ $# -eq 1 ]] || usage; cmd_verify "${comp}" "$1" ;;
    restore) [[ $# -ge 1 ]] || usage; with_lock "backup-${comp}" cmd_restore "${comp}" "$@" ;;
    prune)   with_lock "backup-${comp}" cmd_prune "${comp}" ;;
    *) usage ;;
  esac
}

main "$@"
