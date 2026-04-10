#!/usr/bin/env bash
# setup-pico-sdk-cache.sh — Install the Raspberry Pi Pico SDK and build
# toolchain on the Pi 5 host, with a shared ccache directory.
#
# What this script does:
#   1. Installs required apt packages: cmake, ninja-build, gcc-arm-none-eabi,
#      git, python3, ccache (pinned versions for reproducibility).
#   2. Clones the Pico SDK (including submodules) to /opt/cache/pico-sdk at
#      the pinned PICO_SDK_VERSION tag.  Skips clone if already at that tag.
#   3. Creates /opt/cache/ccache for ccache's object cache.
#   4. Writes a systemd drop-in so the runner process sees PICO_SDK_PATH
#      and CCACHE_DIR in its environment.
#   5. Writes /etc/profile.d/pico-cache.sh for interactive shell use.
#
# Usage: sudo ./setup-pico-sdk-cache.sh
#
# Environment variables (override defaults as needed):
#   PICO_SDK_VERSION    Git tag to check out             (default: 2.1.1)
#   PICO_SDK_DIR        Host path for the SDK            (default: /opt/cache/pico-sdk)
#   CCACHE_CACHE_DIR    Host path for ccache objects     (default: /opt/cache/ccache)
#   RUNNER_USER         User that owns the cache         (default: actions-runner)
#   ARM_GCC_VERSION     apt package version for gcc-arm-none-eabi
#   CMAKE_VERSION       apt package version for cmake
#   NINJA_VERSION       apt package version for ninja-build
#   CCACHE_APT_VERSION  apt package version for ccache
#
# Pinned package versions below are correct for Debian Bookworm (stable).
# Verify with: apt-cache policy <package>

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────
# Pico SDK 2.1.1 — latest stable at time of authoring (April 2026).
# Supports RP2040 and RP2350 (Pico 2).  Update when a new stable is released.
PICO_SDK_VERSION="${PICO_SDK_VERSION:-2.1.1}"
PICO_SDK_DIR="${PICO_SDK_DIR:-/opt/cache/pico-sdk}"
CCACHE_CACHE_DIR="${CCACHE_CACHE_DIR:-/opt/cache/ccache}"
RUNNER_USER="${RUNNER_USER:-actions-runner}"
SYSTEMD_DROP_IN_DIR="/etc/systemd/system/actions-runner.service.d"

# apt package versions — Debian Bookworm
# Re-verify with `apt-cache policy <pkg>` after a dist-upgrade.
ARM_GCC_VERSION="${ARM_GCC_VERSION:-15:12.2.rel1-1}"
CMAKE_VERSION="${CMAKE_VERSION:-3.25.1-1}"
NINJA_VERSION="${NINJA_VERSION:-1.11.1.1-1}"
CCACHE_APT_VERSION="${CCACHE_APT_VERSION:-4.7.4-1}"

# ── Root check ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "==> Setting up Pico SDK cache (version ${PICO_SDK_VERSION})..."

# ── Helper: install an apt package at a pinned version if not already present
install_apt_pkg() {
  local pkg="$1"
  local version="$2"
  local installed
  installed=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  if [ "$installed" = "$version" ]; then
    echo "  ${pkg}=${version} already installed — skipping"
  else
    echo "  Installing ${pkg}=${version}"
    apt-get install -y --no-install-recommends "${pkg}=${version}"
  fi
}

# ── 1. Install apt dependencies ────────────────────────────────────────────
echo ""
echo "  Updating apt package index..."
apt-get update -qq

install_apt_pkg "gcc-arm-none-eabi"       "$ARM_GCC_VERSION"
install_apt_pkg "cmake"                   "$CMAKE_VERSION"
install_apt_pkg "ninja-build"             "$NINJA_VERSION"
install_apt_pkg "ccache"                  "$CCACHE_APT_VERSION"

# These are needed for the Pico SDK build system and USB/BSP headers.
# No version pin — these are stable system libraries.
apt-get install -y --no-install-recommends \
  git \
  python3 \
  python3-pip \
  libusb-1.0-0-dev \
  pkg-config

# ── 2. Clone / update Pico SDK ─────────────────────────────────────────────
echo ""
echo "  Checking Pico SDK at ${PICO_SDK_DIR}..."

clone_needed=false

if [ -d "${PICO_SDK_DIR}/.git" ]; then
  installed_tag=$(git -C "$PICO_SDK_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)
  if [ "$installed_tag" = "$PICO_SDK_VERSION" ]; then
    echo "  Pico SDK ${PICO_SDK_VERSION} already installed — skipping clone"
  else
    echo "  Pico SDK found at tag '${installed_tag}', expected '${PICO_SDK_VERSION}' — re-cloning"
    rm -rf "$PICO_SDK_DIR"
    clone_needed=true
  fi
else
  clone_needed=true
fi

if [ "$clone_needed" = true ]; then
  echo "  Cloning Pico SDK ${PICO_SDK_VERSION} (with submodules)..."
  mkdir -p "$(dirname "$PICO_SDK_DIR")"
  git clone \
    --branch "$PICO_SDK_VERSION" \
    --depth 1 \
    --recurse-submodules \
    --shallow-submodules \
    https://github.com/raspberrypi/pico-sdk.git \
    "$PICO_SDK_DIR"
  echo "  Clone complete."
fi

echo "  Setting ownership: ${PICO_SDK_DIR} → ${RUNNER_USER}"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "$PICO_SDK_DIR"
chmod -R a+rX "$PICO_SDK_DIR"

# ── 3. Create ccache directory ─────────────────────────────────────────────
if [ ! -d "$CCACHE_CACHE_DIR" ]; then
  echo "  Creating ${CCACHE_CACHE_DIR}"
  mkdir -p "$CCACHE_CACHE_DIR"
else
  echo "  ${CCACHE_CACHE_DIR} already exists — skipping"
fi

echo "  Setting ownership: ${CCACHE_CACHE_DIR} → ${RUNNER_USER}"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "$CCACHE_CACHE_DIR"
chmod 755 "$CCACHE_CACHE_DIR"

# ── 4. Systemd drop-in: expose PICO_SDK_PATH / CCACHE_DIR to runner ────────
mkdir -p "$SYSTEMD_DROP_IN_DIR"
DROP_IN="${SYSTEMD_DROP_IN_DIR}/10-pico-cache.conf"

if [ ! -f "$DROP_IN" ]; then
  echo "  Writing systemd drop-in: $DROP_IN"
  cat > "$DROP_IN" <<EOF
# Generated by setup-pico-sdk-cache.sh — do not edit manually.
[Service]
Environment="PICO_SDK_PATH=${PICO_SDK_DIR}"
Environment="CCACHE_DIR=${CCACHE_CACHE_DIR}"
EOF
  systemctl daemon-reload
  echo "  daemon-reload done"
else
  echo "  $DROP_IN already exists — skipping"
fi

# ── 5. /etc/profile.d snippet for interactive shell sessions ───────────────
PROFILE_SCRIPT="/etc/profile.d/pico-cache.sh"
if [ ! -f "$PROFILE_SCRIPT" ]; then
  echo "  Writing $PROFILE_SCRIPT"
  cat > "$PROFILE_SCRIPT" <<EOF
# Pico SDK + ccache — written by setup-pico-sdk-cache.sh
export PICO_SDK_PATH="${PICO_SDK_DIR}"
export CCACHE_DIR="${CCACHE_CACHE_DIR}"

# Add ccache compiler shims to PATH (arm-none-eabi wrappers)
if [ -d /usr/lib/ccache ]; then
  export PATH="/usr/lib/ccache:\$PATH"
fi
EOF
else
  echo "  $PROFILE_SCRIPT already exists — skipping"
fi

# ── 6. Quick sanity check ──────────────────────────────────────────────────
echo ""
echo "  Sanity checks:"
arm-none-eabi-gcc --version | head -1 || echo "    WARNING: arm-none-eabi-gcc not found"
cmake --version | head -1              || echo "    WARNING: cmake not found"
ninja --version | head -1              || echo "    WARNING: ninja not found"
ccache --version | head -1             || echo "    WARNING: ccache not found"
[ -f "${PICO_SDK_DIR}/pico_sdk_init.cmake" ] && \
  echo "    pico_sdk_init.cmake: OK" || \
  echo "    WARNING: pico_sdk_init.cmake not found in ${PICO_SDK_DIR}"

echo ""
echo "==> Pico SDK cache setup complete."
echo "    SDK path     : ${PICO_SDK_DIR}  (tag: ${PICO_SDK_VERSION})"
echo "    ccache dir   : ${CCACHE_CACHE_DIR}"
echo "    Systemd drop : ${DROP_IN}"
echo ""
echo "  NOTE: Run inject-cache-mounts.sh to bind-mount the SDK and ccache"
echo "        into job containers at /opt/pico-sdk and /root/.ccache."
