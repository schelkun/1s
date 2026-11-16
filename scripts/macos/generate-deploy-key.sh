#!/bin/bash
# Create the dedicated deployment key and give GitHub what it needs.
#
#   scripts/macos/generate-deploy-key.sh [--rotate]
#
# 1. Creates ~/.ssh/1s_deploy_ed25519 (only for deployments; --rotate replaces it).
# 2. Installs the PUBLIC key on the server (deployment access stays disabled).
# 3. Copies the three GitHub secrets to your clipboard one by one:
#    DEPLOY_HOST, DEPLOY_SSH_KEY, DEPLOY_KNOWN_HOSTS.
. "$(dirname "$0")/common.sh"

key="${HOME}/.ssh/1s_deploy_ed25519"
if [ -f "${key}" ] && [ "${1:-}" != "--rotate" ]; then
  info "Using existing key ${key} (use --rotate to replace it)"
else
  rm -f "${key}" "${key}.pub"
  mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
  ssh-keygen -q -t ed25519 -a 100 -N "" -C "1s-deploy-$(date +%Y%m%d)" -f "${key}"
  info "Created ${key}"
fi

info "Installing the public key on the server"
server_t "${SUDO} 1s deploy-access install-key $(q "$(cut -d' ' -f1,2 "${key}.pub")")"

# The host key comes over your already-trusted admin SSH connection.
known="$(server 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '{print "1s-server " $1 " " $2}')"
[ -n "${known}" ] || die "Could not read the server host key."

url="https://github.com/${GITHUB_REPO:-<owner>/<repo>}/settings/environments"
echo
echo "Add three secrets to the GitHub environment \"production\":"
echo "  ${url}  (New environment -> production -> Add environment secret)"
echo
copy() { # NAME VALUE
  if command -v pbcopy >/dev/null; then
    printf '%s' "$2" | pbcopy
    printf 'Copied %s to the clipboard. Paste it as secret %s, then press Enter. ' "$1" "$1"
  else
    printf '\n--- %s ---\n%s\n--- end ---\nPress Enter when added. ' "$1" "$2"
  fi
  read -r _
}
copy DEPLOY_HOST "${SERVER_HOST}"
copy DEPLOY_SSH_KEY "$(cat "${key}")"
copy DEPLOY_KNOWN_HOSTS "${known}"
command -v pbcopy >/dev/null && printf '' | pbcopy
[ "${SERVER_SSH_PORT}" = 22 ] || echo "Also add a repository VARIABLE DEPLOY_SSH_PORT=${SERVER_SSH_PORT}."
info "Done. The private key stays in ${key} and in GitHub; it is never stored on the server."
