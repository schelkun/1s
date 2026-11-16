#!/usr/bin/env bash
# Runs INSIDE the simulated server container (1s-e2e-host): adds the public
# test addresses, starts a private dockerd and sshd, creates an admin user.
set -euo pipefail
ADMIN_PUBKEY="$1"

ip addr add 10.250.0.11/24 dev eth0 2>/dev/null || true   # GITEA_BIND_IP
ip addr add 10.250.0.12/24 dev eth0 2>/dev/null || true   # OPENHANDS_BIND_IP
grep -q ' pebble$' /etc/hosts || echo "10.250.0.5 pebble" >>/etc/hosts
install -m 0644 /e2e/pebble.minica.pem /usr/local/share/ca-certificates/pebble-minica.crt
update-ca-certificates >/dev/null 2>&1

if ! docker info >/dev/null 2>&1; then
  # cgroup v2 nesting (same as the official docker:dind entrypoint): move our
  # processes into a leaf cgroup so dockerd can delegate all controllers.
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    mkdir -p /sys/fs/cgroup/init
    xargs -rn1 </sys/fs/cgroup/cgroup.procs >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
    sed -e 's/ / +/g' -e 's/^/+/' </sys/fs/cgroup/cgroup.controllers >/sys/fs/cgroup/cgroup.subtree_control
  fi
  (dockerd >/var/log/dockerd.log 2>&1 &)
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
docker info >/dev/null

mkdir -p /run/sshd
ssh-keygen -A >/dev/null
pgrep -x sshd >/dev/null || /usr/sbin/sshd
id admin >/dev/null 2>&1 || useradd -m -s /bin/bash admin
usermod -p '*' admin   # key-only but not "locked" (sshd without PAM rejects locked accounts)
echo 'admin ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/admin; chmod 0440 /etc/sudoers.d/admin
install -d -m 0700 -o admin -g admin /home/admin/.ssh
printf '%s\n' "${ADMIN_PUBKEY}" >/home/admin/.ssh/authorized_keys
chown admin:admin /home/admin/.ssh/authorized_keys; chmod 0600 /home/admin/.ssh/authorized_keys
echo "host ready"
