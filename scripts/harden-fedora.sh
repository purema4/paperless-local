#!/usr/bin/env bash
# Basic hardening of a fresh Fedora server (tested target: Fedora 44, e.g. a DigitalOcean Droplet).
#
#   - updates the system and turns on automatic security updates
#   - adds a 4 GB swap file (SWAP_SIZE=0 to skip; btrfs and ext4/xfs handled)
#   - asks for a new root password
#   - creates an admin user in "wheel" (sudo with password), copies root's SSH keys to it
#   - installs Docker in ROOTLESS mode for that user (the daemon runs as the user, not root)
#   - SSH: no root login, no password login (keys only), fewer auth tries
#   - firewalld: only SSH open
#
# Usage (as root, keep this SSH session open until you've tested the new user):
#   bash harden-fedora.sh USERNAME
set -euo pipefail

USER_NAME="${1:-}"
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -n "$USER_NAME" ]] || { echo "Usage: $0 USERNAME"; exit 1; }
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Invalid user name: $USER_NAME"; exit 1; }

step() { printf '\n==> %s\n' "$*"; }

# --------------------------------------------------------------- updates
step "Updating the system"
dnf -y upgrade --refresh
dnf -y install dnf-plugins-core firewalld policycoreutils-python-utils curl
# dnf5 ships the automatic-updates plugin as dnf5-plugin-automatic
dnf -y install dnf5-plugin-automatic 2>/dev/null || dnf -y install dnf-automatic

step "Automatic security updates (applied daily)"
mkdir -p /etc/dnf
cat > /etc/dnf/automatic.conf <<'EOF'
[commands]
upgrade_type = security
apply_updates = yes
reboot = never
EOF
systemctl enable --now dnf-automatic.timer

# --------------------------------------------------------------- swap
# Disk swap as a safety net behind Fedora's zram (zram has priority 100, this one less).
# SWAP_SIZE=0 skips it.
SWAP_SIZE="${SWAP_SIZE:-4g}"
if [[ "$SWAP_SIZE" != 0 ]] && ! swapon --show=NAME --noheadings | grep -q '^/swap/swapfile$'; then
  step "Swap file ($SWAP_SIZE)"
  if [[ $(findmnt -no FSTYPE /) == btrfs ]]; then
    # own subvolume: no CoW, and kept out of snapshots of /
    [[ -d /swap ]] || btrfs subvolume create /swap
    [[ -f /swap/swapfile ]] || btrfs filesystem mkswapfile --size "$SWAP_SIZE" /swap/swapfile
  else
    install -d -m 700 /swap
    [[ -f /swap/swapfile ]] || { fallocate -l "$SWAP_SIZE" /swap/swapfile; chmod 600 /swap/swapfile; mkswap /swap/swapfile; }
  fi
  semanage fcontext -a -t swapfile_t '/swap/swapfile' 2>/dev/null || true
  restorecon /swap/swapfile
  grep -q '^/swap/swapfile ' /etc/fstab || echo '/swap/swapfile none swap defaults,pri=10 0 0' >> /etc/fstab
  swapon /swap/swapfile
  swapon --show
fi

# --------------------------------------------------------------- root password
step "New password for root"
passwd root

# --------------------------------------------------------------- admin user
step "Creating user $USER_NAME (member of wheel)"
if id "$USER_NAME" &>/dev/null; then
  usermod -aG wheel "$USER_NAME"
  echo "User exists, added to wheel."
else
  useradd -m -s /bin/bash -G wheel "$USER_NAME"
fi
echo "Password for $USER_NAME (needed for sudo):"
passwd "$USER_NAME"

HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
USER_UID=$(id -u "$USER_NAME")

HAS_KEYS=no
if [[ -s /root/.ssh/authorized_keys ]]; then
  install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/.ssh"
  # append, so keys already there are kept
  cat /root/.ssh/authorized_keys >> "$HOME_DIR/.ssh/authorized_keys"
  sort -u -o "$HOME_DIR/.ssh/authorized_keys" "$HOME_DIR/.ssh/authorized_keys"
  chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh/authorized_keys"
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"
  restorecon -R "$HOME_DIR/.ssh"
  HAS_KEYS=yes
  echo "Copied root's SSH keys to $USER_NAME."
fi

# subordinate uid/gid ranges are required by rootless Docker
grep -q "^$USER_NAME:" /etc/subuid || usermod --add-subuids 100000-165535 "$USER_NAME"
grep -q "^$USER_NAME:" /etc/subgid || usermod --add-subgids 100000-165535 "$USER_NAME"

# --------------------------------------------------------------- rootless Docker
step "Installing Docker (rootless)"
dnf config-manager addrepo --overwrite --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
  docker-compose-plugin docker-ce-rootless-extras slirp4netns fuse-overlayfs iptables
# no root daemon: only the user's own daemon runs
systemctl disable --now docker.service docker.socket 2>/dev/null || true

# keep the user's services (and so Docker) running without an open login session
loginctl enable-linger "$USER_NAME"
for _ in $(seq 1 20); do [[ -S /run/user/$USER_UID/bus ]] && break; sleep 1; done

as_user() {
  sudo -u "$USER_NAME" -H env XDG_RUNTIME_DIR="/run/user/$USER_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" "$@"
}
as_user dockerd-rootless-setuptool.sh install
as_user systemctl --user enable --now docker

BASHRC="$HOME_DIR/.bashrc"
grep -q 'DOCKER_HOST=unix:///run/user/' "$BASHRC" 2>/dev/null || \
  echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> "$BASHRC"

as_user env DOCKER_HOST="unix:///run/user/$USER_UID/docker.sock" docker run --rm hello-world >/dev/null \
  && echo "Rootless Docker works for $USER_NAME."

# --------------------------------------------------------------- SSH
step "Hardening SSH"
# 01- sorts before the distro/cloud-init drop-ins, and the first value sshd reads wins
{
  echo "PermitRootLogin no"
  echo "MaxAuthTries 3"
  echo "LoginGraceTime 30"
  echo "X11Forwarding no"
  if [[ $HAS_KEYS == yes ]]; then
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
  fi
} > /etc/ssh/sshd_config.d/01-hardening.conf
sshd -t
systemctl reload sshd
[[ $HAS_KEYS == yes ]] || echo "WARNING: root had no SSH keys, so password login is still ON. Add a key for $USER_NAME, then add 'PasswordAuthentication no' to /etc/ssh/sshd_config.d/01-hardening.conf."

# --------------------------------------------------------------- firewall
step "Firewall: only SSH open"
systemctl enable --now firewalld
ZONE=$(firewall-cmd --get-default-zone)
for svc in $(firewall-cmd --zone="$ZONE" --list-services); do
  [[ $svc == ssh ]] || firewall-cmd --permanent --zone="$ZONE" --remove-service="$svc"
done
firewall-cmd --permanent --zone="$ZONE" --add-service=ssh
# Tailscale: traffic from your tailnet (tailscale serve, Tailscale SSH) must not be
# filtered by the public zone. Only tailnet devices can reach this interface.
if ip link show tailscale0 &>/dev/null; then
  firewall-cmd --permanent --zone=trusted --change-interface=tailscale0
  echo "tailscale0 -> trusted zone"
fi
firewall-cmd --reload
echo "Open in zone $ZONE: $(firewall-cmd --zone="$ZONE" --list-services)"

step "Done"
cat <<EOF
Before closing this root session, open a NEW terminal and check:
  ssh $USER_NAME@<server>      # must work with your key
  sudo -v                      # must ask for $USER_NAME's password and succeed
  docker ps                    # rootless Docker, no sudo
Root can no longer log in over SSH.
EOF
