#!/usr/bin/env bash
# setup-system.sh — System-level configuration for a fresh Raspberry Pi OS Lite
# (Bookworm, 64-bit) install.
#
# What this script does:
#   1. apt-get update && apt-get upgrade -y
#   2. Install baseline packages: curl, git, jq, ca-certificates, gnupg,
#      lsb-release, apt-transport-https, software-properties-common
#   3. Configure cgroup v2 in /boot/firmware/cmdline.txt (idempotent)
#   4. Create actions-runner user if it does not already exist
#   5. Set hostname to performance-node if not already set
#   6. Remind operator that a reboot is needed for cgroup changes
#
# Usage: sudo ./setup-system.sh [--non-interactive]
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

echo ""
info "==> System configuration starting..."

# ── 1. Package update + upgrade ────────────────────────────────────────────
info "Updating package index..."
apt-get update -qq

info "Upgrading installed packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "Packages upgraded."

# ── 2. Install baseline packages ───────────────────────────────────────────
BASELINE_PACKAGES=(
  curl
  git
  jq
  ca-certificates
  gnupg
  lsb-release
  apt-transport-https
  software-properties-common
)

info "Installing baseline packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${BASELINE_PACKAGES[@]}"
ok "Baseline packages installed: ${BASELINE_PACKAGES[*]}"

# ── 3. Configure cgroup v2 in /boot/firmware/cmdline.txt ──────────────────
CMDLINE_FILE="/boot/firmware/cmdline.txt"

# Required cgroup parameters for Docker container memory limits.
CGROUP_PARAMS="cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory systemd.unified_cgroup_hierarchy=1"

REBOOT_NEEDED=false

if [ ! -f "$CMDLINE_FILE" ]; then
  warn "$CMDLINE_FILE not found — skipping cgroup configuration."
  warn "  (Expected path on Pi OS Bookworm: /boot/firmware/cmdline.txt)"
else
  CURRENT_CMDLINE=$(cat "$CMDLINE_FILE")
  NEEDS_UPDATE=false

  for param in cgroup_enable=cpuset "cgroup_memory=1" "cgroup_enable=memory" "systemd.unified_cgroup_hierarchy=1"; do
    if ! echo "$CURRENT_CMDLINE" | grep -qF "$param"; then
      NEEDS_UPDATE=true
      break
    fi
  done

  if [ "$NEEDS_UPDATE" = true ]; then
    info "Patching $CMDLINE_FILE with cgroup parameters..."
    # cmdline.txt is a single line; append params before the newline.
    # Strip any trailing newline first, then append our params.
    CURRENT_LINE=$(tr -d '\n' < "$CMDLINE_FILE")
    echo "${CURRENT_LINE} ${CGROUP_PARAMS}" > "$CMDLINE_FILE"
    ok "cgroup parameters added to $CMDLINE_FILE"
    REBOOT_NEEDED=true
  else
    ok "cgroup parameters already present in $CMDLINE_FILE — skipping"
  fi
fi

# ── 4. Create actions-runner user ─────────────────────────────────────────
RUNNER_USER="actions-runner"

if id "$RUNNER_USER" &>/dev/null; then
  ok "User '$RUNNER_USER' already exists — skipping creation"
else
  info "Creating user '$RUNNER_USER'..."
  useradd \
    --system \
    --no-create-home \
    --shell /usr/sbin/nologin \
    "$RUNNER_USER"
  ok "User '$RUNNER_USER' created."
fi

# Add to docker group if the group exists (Docker may not be installed yet).
if getent group docker &>/dev/null; then
  if id -nG "$RUNNER_USER" | grep -qw docker; then
    ok "User '$RUNNER_USER' is already in group 'docker'"
  else
    info "Adding '$RUNNER_USER' to group 'docker'..."
    usermod -aG docker "$RUNNER_USER"
    ok "Added '$RUNNER_USER' to group 'docker'."
  fi
else
  warn "Group 'docker' does not exist yet — '$RUNNER_USER' will be added when Docker is installed."
fi

# ── 5. Set hostname ────────────────────────────────────────────────────────
TARGET_HOSTNAME="performance-node"
CURRENT_HOSTNAME=$(hostname)

if [ "$CURRENT_HOSTNAME" = "$TARGET_HOSTNAME" ]; then
  ok "Hostname is already '$TARGET_HOSTNAME' — skipping"
else
  info "Setting hostname to '$TARGET_HOSTNAME' (was: '$CURRENT_HOSTNAME')..."
  hostnamectl set-hostname "$TARGET_HOSTNAME"
  # Keep /etc/hosts consistent.
  if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/127\.0\.1\.1\s.*/127.0.1.1\t${TARGET_HOSTNAME}/" /etc/hosts
  else
    echo "127.0.1.1	${TARGET_HOSTNAME}" >> /etc/hosts
  fi
  ok "Hostname set to '$TARGET_HOSTNAME'."
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
ok "==> System configuration complete."
echo ""

if [ "$REBOOT_NEEDED" = true ]; then
  echo -e "${C_YELLOW}⚠  REBOOT REQUIRED${C_RESET}"
  echo "   cgroup parameters were added to $CMDLINE_FILE."
  echo "   These changes take effect after the next reboot:"
  echo ""
  echo "     sudo reboot"
  echo ""
fi
