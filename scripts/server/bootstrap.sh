#!/usr/bin/env bash
# One-time (and safely re-runnable) Ubuntu 22.04/24.04 bootstrap. Run as root
# from a copy of this repository, through your ADMINISTRATIVE SSH account:
#
#   sudo ./scripts/server/bootstrap.sh [--deploy-user deploy] [--deploy-pubkey FILE]
#                                      [--skip-docker] [--skip-packages]
#
# --skip-packages: the host is pre-provisioned (packages and Docker already
# installed, or not Ubuntu); implies --skip-docker.
# It installs Docker Engine (official apt repository) and base packages,
# creates the restricted deployment user, its sudoers rule and the deployment
# gateway, installs the AppArmor profile for rootless runners and the `1s` CLI.
# It never changes your sshd configuration or your administrative account.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO}/scripts/lib/common.sh"

DEPLOY_USER=deploy
DEPLOY_PUBKEY=""
SKIP_DOCKER=false
SKIP_PACKAGES=false

while (( $# )); do
  case "$1" in
    --deploy-user) DEPLOY_USER="$2"; shift 2 ;;
    --deploy-pubkey) DEPLOY_PUBKEY="$2"; shift 2 ;;
    --skip-docker) SKIP_DOCKER=true; shift ;;
    --skip-packages) SKIP_PACKAGES=true; SKIP_DOCKER=true; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
[[ "${DEPLOY_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid deploy user name"
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" == "${DEPLOY_USER}" ]]; then
  die "The deploy user must not be your administrative user (${SUDO_USER})."
fi

check_os() {
  . /etc/os-release
  if [[ "${ID}" != ubuntu || ! "${VERSION_ID}" =~ ^(22\.04|24\.04)$ ]]; then
    warn "Tested on Ubuntu 22.04/24.04; this is ${PRETTY_NAME}. Continuing."
  fi
}

install_packages() {
  log "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg jq openssl iptables dnsutils \
    python3 apparmor apparmor-utils uidmap util-linux procps >/dev/null
}

install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
  else
    log "Installing Docker Engine from download.docker.com"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  fi
  if [[ ! -f /etc/docker/daemon.json ]]; then
    install -d -m 0755 /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
EOF
    systemctl restart docker
  else
    log "Keeping existing /etc/docker/daemon.json"
  fi
  systemctl enable --now docker >/dev/null
}

setup_kernel() {
  modprobe tun 2>/dev/null || true
  echo tun >/etc/modules-load.d/1s.conf
  [[ -c /dev/net/tun ]] || warn "/dev/net/tun is missing: rootless runners will not start."
}

setup_apparmor() {
  command -v apparmor_parser >/dev/null || { warn "AppArmor tools missing; skipping runner profile."; return 0; }
  [[ -d /sys/kernel/security/apparmor ]] || { warn "AppArmor not active; skipping runner profile."; return 0; }
  local major
  major="$(apparmor_parser --version | sed -n 's/.*version \([0-9]*\)\..*/\1/p' | head -n1)"
  if (( ${major:-0} >= 4 )); then
    install -m 0644 "${REPO}/config/apparmor/1s-rootless-dind" /etc/apparmor.d/1s-rootless-dind
    apparmor_parser -r -W /etc/apparmor.d/1s-rootless-dind
    log "AppArmor profile 1s-rootless-dind loaded."
  else
    log "AppArmor ${major}.x does not restrict user namespaces; runners use apparmor=unconfined."
  fi
}

setup_dirs() {
  install -d -m 0755 /etc/1s /opt/1s /opt/1s/releases /var/lib/1s /usr/local/lib/1s /usr/local/sbin
  install -d -m 0700 /etc/1s/secrets /var/lib/1s/state /var/backups/1s
  install -d -m 0750 /var/log/1s
  printf 'DEPLOY_USER=%s\n' "${DEPLOY_USER}" >/etc/1s/bootstrap.env
}

setup_deploy_user() {
  if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
    log "Creating restricted deployment user ${DEPLOY_USER}"
    useradd --create-home --home-dir "/home/${DEPLOY_USER}" --shell /bin/bash \
      --comment "1s restricted deployment user" "${DEPLOY_USER}"
  fi
  usermod -p '*' "${DEPLOY_USER}"           # no password, key-only (not "locked")
  if id -nG "${DEPLOY_USER}" | grep -qwE 'sudo|docker|adm|lxd'; then
    die "${DEPLOY_USER} is in a privileged group ($(id -nG "${DEPLOY_USER}")); remove it first."
  fi
  local home; home="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
  # Root owns the home and ~/.ssh: the deploy user cannot add its own keys.
  chown root:root "${home}"; chmod 0755 "${home}"
  install -d -m 0755 -o root -g root "${home}/.ssh"
  [[ -f "${home}/.ssh/authorized_keys" ]] || install -m 0644 -o root -g root /dev/null "${home}/.ssh/authorized_keys"
  chown root:root "${home}/.ssh/authorized_keys"; chmod 0644 "${home}/.ssh/authorized_keys"

  install -m 0755 -o root -g root "${REPO}/scripts/server/gateway.sh" /usr/local/lib/1s/gateway
  local tmp; tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
# 1s: the deployment user may run exactly one program as root.
Defaults:${DEPLOY_USER} !requiretty, env_reset, !mail_badpass
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/local/lib/1s/gateway
EOF
  visudo -cqf "${tmp}" || die "Generated sudoers file is invalid."
  install -m 0440 -o root -g root "${tmp}" /etc/sudoers.d/1s-deploy; rm -f "${tmp}"
}

install_tools() {
  # Initial copy of the tooling so `1s deploy-access` works before the first
  # GitHub Actions deployment replaces it with a real release.
  local dest=/opt/1s/releases/bootstrap
  rm -rf -- "${dest}.new"
  mkdir -p "${dest}.new"
  tar -C "${REPO}" --exclude=.git --exclude=.local -cf - . | tar -C "${dest}.new" -xf - --no-same-owner
  chmod -R go-w "${dest}.new"
  rm -rf -- "${dest}"; mv "${dest}.new" "${dest}"
  if [[ ! -e /opt/1s/tools ]] || [[ "$(readlink /opt/1s/tools)" == releases/bootstrap ]]; then
    ln -sfn releases/bootstrap /opt/1s/tools
  fi
  ln -sfn /opt/1s/tools/scripts/server/1s /usr/local/sbin/1s
}

check_sshd() {
  local t; t="$(sshd -T 2>/dev/null || true)"
  [[ -n "${t}" ]] || { warn "Could not read sshd configuration."; return 0; }
  grep -qi '^pubkeyauthentication yes' <<<"${t}" || warn "sshd: PubkeyAuthentication is not 'yes'; deployments will fail."
  if grep -qiE '^(allowusers|allowgroups) ' <<<"${t}"; then
    warn "sshd restricts logins (AllowUsers/AllowGroups). Add ${DEPLOY_USER} there, keeping your admin user."
  fi
  grep -qiE '^authorizedkeysfile .*\.ssh/authorized_keys' <<<"${t}" \
    || warn "sshd AuthorizedKeysFile does not include .ssh/authorized_keys; the deploy key will not be found."
}

main() {
  check_os
  [[ "${SKIP_PACKAGES}" == true ]] || install_packages
  [[ "${SKIP_DOCKER}" == true ]] || install_docker
  setup_kernel
  setup_apparmor
  setup_dirs
  setup_deploy_user
  install_tools
  if [[ -n "${DEPLOY_PUBKEY}" ]]; then
    /usr/local/sbin/1s deploy-access install-key <"${DEPLOY_PUBKEY}"
  fi
  /usr/local/sbin/1s deploy-access disable >/dev/null
  check_sshd
  log "Bootstrap complete. Deployment access is DISABLED until you enable it."
  echo "SSH host key fingerprints (should match what your ssh client accepted on first connect):"
  for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -l -f "${k}"; done
}

main
