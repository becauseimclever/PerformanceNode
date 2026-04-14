#!/usr/bin/env bash
# setup-docker.sh — Install Docker Engine on Raspberry Pi OS Bookworm ARM64.
#
# Uses the official Docker apt repository for Debian (Pi OS Bookworm is
# Debian-based).  Configures the daemon with overlay2 storage driver and
# JSON-file log rotation per the container execution architecture decision.
#
# What this script does:
#   1. Install Docker Engine (docker-ce, docker-ce-cli, containerd.io,
#      docker-buildx-plugin, docker-compose-plugin) via official Docker repo.
#   2. Configure /etc/docker/daemon.json (overlay2 + log rotation).
#   3. Enable and start the docker systemd service.
#   4. Add actions-runner user to the docker group.
#   5. Optionally run `docker run --rm hello-world` to verify the install.
#
# Usage: sudo ./setup-docker.sh [--non-interactive]
#
# Run as root (called via sudo from setup.sh).

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'
else
  C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''
fi

ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
info() { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
die()  { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; exit 1; }

NON_INTERACTIVE=false
for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=true ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ── Root check ─────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "This script must be run as root (use sudo)."

RUNNER_USER="${RUNNER_USER:-actions-runner}"

echo ""
info "==> Docker Engine setup starting..."

# ── 1. Install Docker Engine ───────────────────────────────────────────────
if command -v docker &>/dev/null && docker --version &>/dev/null; then
  ok "Docker is already installed: $(docker --version)"
else
  info "Installing Docker Engine from the official Docker apt repository..."

  # Ensure dependencies are present.
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg

  # Add Docker's official GPG key.
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    info "Fetching Docker GPG key..."
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    ok "Docker GPG key installed."
  else
    ok "Docker GPG key already present — skipping."
  fi

  # Add Docker apt repository (Bookworm, ARM64).
  if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    info "Adding Docker apt repository..."
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    ok "Docker apt repository added."
  else
    ok "Docker apt repository already configured — skipping."
    apt-get update -qq
  fi

  info "Installing Docker packages..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  ok "Docker Engine installed: $(docker --version)"
fi

# ── 2. Configure Docker daemon ─────────────────────────────────────────────
DAEMON_JSON="/etc/docker/daemon.json"
mkdir -p /etc/docker

DESIRED_CONFIG='{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}'

if [ -f "$DAEMON_JSON" ]; then
  EXISTING=$(cat "$DAEMON_JSON")
  if [ "$EXISTING" = "$DESIRED_CONFIG" ]; then
    ok "$DAEMON_JSON already correct — skipping."
  else
    warn "$DAEMON_JSON exists but differs from desired config — updating."
    echo "$DESIRED_CONFIG" > "$DAEMON_JSON"
    ok "$DAEMON_JSON updated."
  fi
else
  info "Writing $DAEMON_JSON..."
  echo "$DESIRED_CONFIG" > "$DAEMON_JSON"
  ok "$DAEMON_JSON written."
fi

# ── 3. Enable and start Docker service ────────────────────────────────────
info "Enabling and starting Docker service..."
systemctl enable --now docker
ok "Docker service is enabled and running."

# ── 4. Add actions-runner to docker group ─────────────────────────────────
if id "$RUNNER_USER" &>/dev/null; then
  if id -nG "$RUNNER_USER" | grep -qw docker; then
    ok "User '$RUNNER_USER' is already in group 'docker'."
  else
    info "Adding '$RUNNER_USER' to group 'docker'..."
    usermod -aG docker "$RUNNER_USER"
    ok "Added '$RUNNER_USER' to group 'docker'."
  fi
else
  warn "User '$RUNNER_USER' does not exist yet — skipping docker group assignment."
  warn "  Run setup-system.sh first, then re-run this script."
fi

# ── 5. Verify with hello-world ─────────────────────────────────────────────
if [ "$NON_INTERACTIVE" = false ]; then
  info "Running docker hello-world to verify installation..."
  if docker run --rm --platform linux/arm64 hello-world 2>&1 | grep -q "Hello from Docker"; then
    ok "hello-world ran successfully."
  else
    warn "hello-world did not produce expected output — Docker may still be starting up."
    warn "  Try manually: docker run --rm hello-world"
  fi
else
  info "Skipping hello-world test (--non-interactive)."
fi

echo ""
ok "==> Docker Engine setup complete."
