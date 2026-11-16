# shellcheck shell=bash disable=SC2034  # variables are used by the sourcing scripts
# Shared helpers for the macOS scripts. Works with the Bash 3.2 that ships
# with macOS and needs only ssh/ssh-keygen/tar (no Homebrew).

set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ONES_ENV_FILE:-${ROOT}/.env}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*" >&2; }

[ -f "${ENV_FILE}" ] || die "Missing ${ENV_FILE}. Create it: cp .env.example .env (then edit it)."

# envval NAME -- value of NAME in .env (last occurrence, quotes and comments stripped)
envval() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "${ENV_FILE}" | tail -n 1 |
    sed -e "s/^'\(.*\)'[[:space:]]*\$/\1/" -e 's/^"\(.*\)"[[:space:]]*$/\1/' -e 's/[[:space:]]\{1,\}#.*$//' -e 's/[[:space:]]*$//'
}

SERVER_SSH="$(envval SERVER_SSH)"
SERVER_SSH_PORT="$(envval SERVER_SSH_PORT)"; SERVER_SSH_PORT="${SERVER_SSH_PORT:-22}"
GITHUB_REPO="$(envval GITHUB_REPO)"
DEPLOY_ACCESS_TTL="$(envval DEPLOY_ACCESS_TTL)"; DEPLOY_ACCESS_TTL="${DEPLOY_ACCESS_TTL:-2h}"
[ -n "${SERVER_SSH}" ] || die "Set SERVER_SSH in .env (e.g. SERVER_SSH=root@203.0.113.5)."
SERVER_HOST="${SERVER_SSH#*@}"

# root logins need no sudo; other admin users use sudo (may ask for a password).
SUDO="sudo"
case "${SERVER_SSH}" in root@*) SUDO="" ;; esac

# server CMD -- run a command on the server (no terminal; for data/stdin use).
server() { ssh -p "${SERVER_SSH_PORT}" -o ConnectTimeout=15 "${SERVER_SSH}" "$@"; }
# server_t CMD -- same, with a terminal (sudo password prompts, colours).
server_t() { ssh -t -p "${SERVER_SSH_PORT}" -o ConnectTimeout=15 "${SERVER_SSH}" "$@"; }

# Quote one argument for the remote shell.
q() { printf '%q' "$1"; }
