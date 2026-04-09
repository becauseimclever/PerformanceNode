#!/usr/bin/env bash
# setup-system.sh – OS-level configuration for Raspberry Pi 5 PerformanceNode.
# Hardens the system, installs base packages, and applies performance tuning.
# Must be run as root.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ "$EUID" -ne 0 ]]; then
  error "Please run as root."
  exit 1
fi

# ── Package updates ───────────────────────────────────────────────────────────
info "Updating package lists and upgrading installed packages..."
apt-get update -y
apt-get upgrade -y --no-install-recommends

# ── Base dependencies ─────────────────────────────────────────────────────────
info "Installing base packages..."
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  git \
  jq \
  lsb-release \
  python3 \
  python3-pip \
  python3-venv \
  i2c-tools \
  libraspberrypi-bin \
  raspi-config \
  unzip \
  wget

# ── Enable required kernel interfaces ─────────────────────────────────────────
info "Enabling I2C, SPI, and UART interfaces..."
raspi-config nonint do_i2c 0
raspi-config nonint do_spi 0
raspi-config nonint do_serial_hw 0   # Enable UART hardware
raspi-config nonint do_serial_cons 0 # Disable serial console (keep hardware)

# ── Performance / CPU governor ────────────────────────────────────────────────
info "Setting CPU governor to 'performance'..."
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$gov"
  done
fi

# Persist across reboots via /etc/rc.local
if ! grep -q 'scaling_governor' /etc/rc.local 2>/dev/null; then
  sed -i '/^exit 0/i # Set CPU governor to performance\nfor g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done' /etc/rc.local
fi

# ── Swap configuration ────────────────────────────────────────────────────────
info "Disabling swap to reduce latency jitter..."
systemctl disable dphys-swapfile 2>/dev/null || true
swapoff -a 2>/dev/null || true

# ── Kernel parameters ─────────────────────────────────────────────────────────
info "Applying sysctl performance tuning..."
cat > /etc/sysctl.d/99-performancenode.conf << 'EOF'
# PerformanceNode – kernel tuning for low-latency / high-throughput testing

# Increase file-descriptor limits
fs.file-max = 2097152

# TCP tuning
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 5000

# Reduce swappiness (swap already disabled, but belt-and-suspenders)
vm.swappiness = 0

# Allow faster local port reuse
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
EOF

sysctl --system

# ── Time synchronisation ──────────────────────────────────────────────────────
info "Configuring NTP (systemd-timesyncd)..."
timedatectl set-ntp true

# ── Hostname ──────────────────────────────────────────────────────────────────
DESIRED_HOSTNAME="performancenode"
CURRENT_HOSTNAME=$(hostname)
if [[ "$CURRENT_HOSTNAME" != "$DESIRED_HOSTNAME" ]]; then
  info "Setting hostname to '${DESIRED_HOSTNAME}'..."
  hostnamectl set-hostname "$DESIRED_HOSTNAME"
  sed -i "s/$CURRENT_HOSTNAME/$DESIRED_HOSTNAME/g" /etc/hosts
fi

info "System configuration complete."
