#!/usr/bin/env bash
# scripts/mcu/setup-mcu-deps.sh — Install system dependencies required for MCU flashing.
#
# Installs:
#   - python3-gpiozero   (GPIO control without root, requires gpio group)
#   - python3-serial     (pyserial — UART communication)
#   - python3-udev       (pyudev — USB device detection)
#   - util-linux         (mount/umount)
#   - Adds actions-runner user to gpio and dialout groups
#
# Idempotent: safe to run multiple times.
# Must be run as root (sudo ./setup-mcu-deps.sh).
#
# Usage:
#   sudo ./scripts/mcu/setup-mcu-deps.sh [--non-interactive]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/runner-service.sh"

RUNNER_USER="${RUNNER_USER:-actions-runner}"
NON_INTERACTIVE=false

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── Colour output (TTY only) ──────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
else
  C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

info()    { echo -e "  ${C_GREEN}▸${C_RESET} $*"; }
warning() { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; }
error()   { echo -e "  ${C_RED}✗${C_RESET}  $*" >&2; }

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  error "This script must be run as root (use sudo)."
  exit 1
fi

echo ""
echo "── MCU Dependency Setup ─────────────────────────────────────────────────"
echo ""

# ── apt packages ──────────────────────────────────────────────────────────────
APT_PACKAGES=(
  openocd            # OpenOCD — SWD programming and debugging
  libgpiod2          # libgpiod library (kernel GPIO interface)
  gpiod              # GPIO tools (gpiodetect, gpioinfo, etc.)
  python3-serial     # pyserial — UART communication
  util-linux         # mount, umount, lsblk
)

info "Updating apt package lists..."
apt-get update -qq

for pkg in "${APT_PACKAGES[@]}"; do
  if dpkg -s "$pkg" &>/dev/null; then
    info "$pkg already installed — skipping"
  else
    info "Installing $pkg..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg"
  fi
done

# ── pip packages (supplements apt versions with latest) ──────────────────────
# Install into the system Python so the runner user can access them without venv.
info "Ensuring pip packages are up to date (pyserial)..."
python3 -m pip install --quiet --upgrade pyserial 2>/dev/null || warning "pip install had warnings (may be normal on Pi OS — check output above)"

# ── Group membership ──────────────────────────────────────────────────────────
REQUIRED_GROUPS=(gpio dialout)

if ! id "$RUNNER_USER" &>/dev/null; then
  warning "User '$RUNNER_USER' does not exist — skipping group assignment."
  warning "Re-run after creating the runner user, or set RUNNER_USER=<name>."
else
  for grp in "${REQUIRED_GROUPS[@]}"; do
    if getent group "$grp" &>/dev/null; then
      if id -nG "$RUNNER_USER" | grep -qw "$grp"; then
        info "$RUNNER_USER already in group '$grp' — skipping"
      else
        info "Adding $RUNNER_USER to group '$grp'..."
        usermod -aG "$grp" "$RUNNER_USER"
      fi
    else
      warning "Group '$grp' does not exist on this system — skipping"
    fi
  done

  echo ""
  warning "Group changes take effect on next login / service restart."
  warning "Restart the runner service: systemctl restart $(runner_detect_service_name)"
fi

# ── udev rules — ensure /dev/gpiomem and serial devices are accessible ───────
UDEV_RULE_FILE="/etc/udev/rules.d/99-performancenode-mcu.rules"
if [ ! -f "$UDEV_RULE_FILE" ]; then
  info "Writing udev rules to $UDEV_RULE_FILE..."
  cat > "$UDEV_RULE_FILE" <<'UDEV'
# PerformanceNode MCU access rules (OpenOCD SWD flashing via GPIO)
# Allow gpio group to access GPIO character devices
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
# Allow dialout group to access UART devices
KERNEL=="ttyAMA[0-9]*", GROUP="dialout", MODE="0660"
KERNEL=="ttyUSB[0-9]*", GROUP="dialout", MODE="0660"
UDEV
  udevadm control --reload-rules 2>/dev/null || warning "udevadm reload failed — reboot may be required"
  udevadm trigger 2>/dev/null || true
else
  info "udev rules already present at $UDEV_RULE_FILE — skipping"
fi

echo ""
echo -e "${C_GREEN}✓ MCU dependency setup complete.${C_RESET}"
echo ""
