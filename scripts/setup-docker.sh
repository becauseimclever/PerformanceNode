#!/usr/bin/env bash
# setup-docker.sh – Install and configure Docker Engine on Raspberry Pi 5 (arm64).
# Must be run as root.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ "$EUID" -ne 0 ]]; then
  error "Please run as root."
  exit 1
fi

# ── Skip if Docker is already installed ───────────────────────────────────────
if command -v docker &>/dev/null; then
  warn "Docker is already installed ($(docker --version)). Skipping installation."
else
  info "Adding Docker's official GPG key and repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # Raspberry Pi OS is Debian-based; use the Debian repository.
  DPKG_ARCH="$(dpkg --print-architecture)"
  VERSION_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  echo \
    "deb [arch=${DPKG_ARCH} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian \
${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  info "Docker installed: $(docker --version)"
fi

# ── Service configuration ─────────────────────────────────────────────────────
info "Enabling and starting Docker service..."
systemctl enable docker
systemctl start docker

# ── Add default non-root user to the docker group ─────────────────────────────
# Determine the primary non-root user (first user with UID >= 1000).
NON_ROOT_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
if [[ -n "$NON_ROOT_USER" ]]; then
  info "Adding '${NON_ROOT_USER}' to the 'docker' group..."
  usermod -aG docker "$NON_ROOT_USER"
  warn "User '${NON_ROOT_USER}' must log out and back in for group membership to take effect."
fi

# ── Daemon configuration ──────────────────────────────────────────────────────
info "Writing /etc/docker/daemon.json..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "features": {
    "buildkit": true
  }
}
EOF

systemctl restart docker

info "Docker setup complete."
