#!/usr/bin/env bash
# setup-hat.sh – Configure the custom GP2040-CE latency-test HAT on Raspberry Pi 5.
#
# The HAT connects a GP2040-CE device (gamepad) via USB to the Pi and uses
# GPIO pins to detect button-press signals with microsecond precision, enabling
# end-to-end input-latency measurement:
#
#   [PC sends button press over USB] → [GP2040-CE device] → [GPIO signal]
#   → [Pi records timestamp] → latency = GPIO timestamp – USB send timestamp
#
# GPIO pin assignments (BCM numbering):
#   GPIO 4  – Button signal input (active-high, 3.3 V logic)
#   GPIO 17 – Trigger output (drives test signal into GP2040-CE device)
#   GPIO 27 – Status LED
#
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

HAT_CONFIG_DIR="/etc/performancenode/hat"
UDEV_RULES_FILE="/etc/udev/rules.d/99-gp2040ce.rules"
RUNNER_USER="github-runner"

# ── Install Python dependencies ───────────────────────────────────────────────
info "Installing Python GPIO and USB libraries..."
apt-get install -y --no-install-recommends \
  python3-pip \
  python3-venv \
  libusb-1.0-0 \
  libusb-1.0-0-dev \
  udev

VENV_DIR="/opt/performancenode/venv"
mkdir -p "$(dirname "$VENV_DIR")"
python3 -m venv "$VENV_DIR"
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install \
  RPi.GPIO==0.7.1 \
  pyusb==1.2.1 \
  gpiozero==2.0.1 \
  lgpio==0.2.2.0

# ── GPIO permissions ──────────────────────────────────────────────────────────
info "Configuring GPIO access permissions..."
# Ensure the gpio group exists and the runner user belongs to it.
if ! getent group gpio &>/dev/null; then
  groupadd --system gpio
fi
usermod -aG gpio "$RUNNER_USER" 2>/dev/null || true

# Allow group-writable access to GPIO device nodes.
cat > /etc/udev/rules.d/99-gpio.rules << 'EOF'
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
SUBSYSTEM=="gpiomem", GROUP="gpio", MODE="0660"
EOF

# ── udev rule for GP2040-CE device ────────────────────────────────────────────
info "Installing udev rule for GP2040-CE USB device..."
# GP2040-CE presents itself as a generic HID gamepad.
# VID 0x2E8A (Raspberry Pi / RP2040 bootloader) or vendor-specific.
# Add both the production and BOOTSEL VIDs for convenience.
cat > "$UDEV_RULES_FILE" << 'EOF'
# GP2040-CE – RP2040-based gamepad (production firmware)
SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0005", \
  GROUP="plugdev", MODE="0660", SYMLINK+="gp2040ce"

# RP2040 BOOTSEL mode (for firmware flashing)
SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0003", \
  GROUP="plugdev", MODE="0660", SYMLINK+="rp2040-boot"

# Generic HID gamepad fallback
SUBSYSTEM=="input", ATTRS{name}=="GP2040*", GROUP="input", MODE="0660"
EOF

usermod -aG plugdev "$RUNNER_USER" 2>/dev/null || true

# ── HAT configuration file ────────────────────────────────────────────────────
info "Writing HAT configuration to ${HAT_CONFIG_DIR}/hat-config.json..."
mkdir -p "$HAT_CONFIG_DIR"
cat > "${HAT_CONFIG_DIR}/hat-config.json" << 'EOF'
{
  "version": "1.0",
  "description": "GP2040-CE Latency Test HAT configuration",
  "gpio": {
    "button_signal_pin": 4,
    "trigger_output_pin": 17,
    "status_led_pin": 27,
    "active_high": true,
    "debounce_ms": 1
  },
  "usb": {
    "gp2040ce_vid": "0x2E8A",
    "gp2040ce_pid": "0x0005"
  },
  "latency_test": {
    "sample_count": 1000,
    "warmup_samples": 50,
    "trigger_interval_ms": 100,
    "timeout_ms": 500,
    "results_dir": "/opt/performancenode/results/latency"
  }
}
EOF
chmod 644 "${HAT_CONFIG_DIR}/hat-config.json"

# ── Reload udev ───────────────────────────────────────────────────────────────
info "Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger

# ── config.txt overlay ────────────────────────────────────────────────────────
# Raspberry Pi 5 uses /boot/firmware/config.txt
BOOT_CONFIG="/boot/firmware/config.txt"
if [[ ! -f "$BOOT_CONFIG" ]]; then
  BOOT_CONFIG="/boot/config.txt"
fi

if [[ -f "$BOOT_CONFIG" ]]; then
  if ! grep -q "# PerformanceNode HAT" "$BOOT_CONFIG"; then
    info "Adding HAT overlay settings to ${BOOT_CONFIG}..."
    cat >> "$BOOT_CONFIG" << 'EOF'

# PerformanceNode HAT
dtparam=i2c_arm=on
dtparam=spi=on
# Increase USB current for HAT-powered GP2040-CE device
max_usb_current=1
EOF
  fi
else
  warn "Boot config not found. Skipping dtparam configuration."
fi

# ── Results directory ─────────────────────────────────────────────────────────
info "Creating results directories..."
mkdir -p /opt/performancenode/results/latency
mkdir -p /opt/performancenode/results/performance
if id "$RUNNER_USER" &>/dev/null; then
  chown -R "${RUNNER_USER}:${RUNNER_USER}" /opt/performancenode/results
fi

info "HAT setup complete. A reboot is required for all changes to take effect."
