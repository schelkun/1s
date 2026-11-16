#!/usr/bin/env bash
# Regenerate .env.example and docs/configuration.md from config/schema.conf.
#   scripts/dev/generate-reference.sh          write files
#   scripts/dev/generate-reference.sh --check  fail if they are out of date (CI)
set -euo pipefail

# shellcheck source=scripts/lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

declare -A TITLES=(
  [local]="Your Mac (used by scripts/macos only)"
  [shared]="Shared infrastructure (Nginx, TLS, firewall, backups)"
  [gitea]="Gitea, PostgreSQL and runners"
  [openhands]="OpenHands Agent Canvas"
)
ORDER=(local shared gitea openhands)

# Example values for required settings (documentation addresses/domains).
declare -A EXAMPLES=(
  [SERVER_SSH]=root@203.0.113.5 [GITHUB_REPO]=your-org/1s
  [ACME_EMAIL]=admin@example.com
  [GITEA_DOMAIN]=git.example.com [GITEA_BIND_IP]=203.0.113.10 [GITEA_ADMIN_EMAIL]=admin@example.com
  [OPENHANDS_DOMAIN]=ai.example.com [OPENHANDS_BIND_IP]=203.0.113.20 [OPENHANDS_USERS]="alice:443,bob:8444"
)

gen_env_example() {
  cat <<'EOF'
# 1s configuration: copy to .env, edit, then run scripts/macos/push-config.sh.
# Generated from config/schema.conf by scripts/dev/generate-reference.sh.
#
# * .env is git-ignored and stays on your Mac; push-config.sh stores it on the
#   server as root-only files.
# * Secrets (passwords, keys) are generated on the server when left empty, so
#   you normally set none. Read one with:
#   scripts/macos/server.sh config secret GITEA_ADMIN_PASSWORD
# * Commented-out lines show the default.
# * Example addresses are documentation ranges (RFC 5737); use your own.
EOF
  local comp name c kind req def desc
  for comp in "${ORDER[@]}"; do
    printf '\n# ==== %s ====\n' "${TITLES[${comp}]}"
    while IFS='|' read -r name c kind req def desc; do
      [[ "${c}" == "${comp}" ]] || continue
      printf '\n# %s\n' "${desc}"
      if [[ "${kind}" == secret ]]; then
        printf '# Secret: generated on the server when empty.\n#%s=\n' "${name}"; continue
      fi
      [[ "${req}" != no ]] && printf '# Required%s.\n' "$([[ "${req}" == if-* ]] && echo " when ${req#if-} is enabled")"
      if [[ -n "${EXAMPLES[${name}]:-}" ]]; then printf '%s=%s\n' "${name}" "${EXAMPLES[${name}]}"
      elif [[ "${req}" != no ]]; then printf '%s=\n' "${name}"
      else printf '#%s=%s\n' "${name}" "${def}"; fi
    done < <(schema_rows)
  done
}

gen_markdown() {
  cat <<'EOF'
# Configuration reference

Generated from [`config/schema.conf`](../config/schema.conf) by
`scripts/dev/generate-reference.sh`. Do not edit by hand.

How it works:

* You edit `.env` on your Mac and run `scripts/macos/push-config.sh`.
* The server validates it, generates missing secrets and stores
  `/etc/1s/config/<component>.env` (0644) and `/etc/1s/secrets/<component>.env`
  (0600 root). Nothing changes if the file is invalid.
* `local` settings are only read by the macOS scripts.
* GitHub holds only the three deployment secrets `DEPLOY_HOST`,
  `DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS` (plus an optional variable
  `DEPLOY_SSH_PORT`).

Empty values fall back to the defaults below. `${NAME}` means "same as NAME".
EOF
  local comp name c kind req def desc
  for comp in "${ORDER[@]}"; do
    printf '\n## %s\n\n| Name | Type | Required | Default | Description |\n|---|---|---|---|---|\n' "${TITLES[${comp}]}"
    while IFS='|' read -r name c kind req def desc; do
      [[ "${c}" == "${comp}" ]] || continue
      local k="${kind}"; [[ "${kind}" == secret ]] && k="**secret**"
      printf '| `%s` | %s | %s | %s | %s |\n' "${name}" "${k}" "${req}" "${def:+\`${def}\`}" "${desc//|/\\|}"
    done < <(schema_rows)
  done
}

main() {
  local tmp; tmp="$(mktemp -d)"
  gen_env_example >"${tmp}/env"
  gen_markdown >"${tmp}/md"
  if [[ "${1:-}" == --check ]]; then
    local rc=0
    cmp -s "${tmp}/env" "${ONES_ROOT}/.env.example" || { err ".env.example is out of date (run scripts/dev/generate-reference.sh)"; rc=1; }
    cmp -s "${tmp}/md" "${ONES_ROOT}/docs/configuration.md" || { err "docs/configuration.md is out of date (run scripts/dev/generate-reference.sh)"; rc=1; }
    rm -rf -- "${tmp}"; return "${rc}"
  fi
  mv "${tmp}/env" "${ONES_ROOT}/.env.example"
  mv "${tmp}/md" "${ONES_ROOT}/docs/configuration.md"
  rm -rf -- "${tmp}"
  log "Wrote .env.example and docs/configuration.md"
}

main "$@"
