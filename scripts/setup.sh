#!/usr/bin/env bash
# setup.sh – Main entry-point for PerformanceNode Raspberry Pi 5 setup.
# Run as root (or with sudo) on a fresh Raspberry Pi OS Lite (64-bit) image.
#
# Usage:
#   sudo bash setup.sh [OPTIONS]
#
# Options:
#   --skip-docker       Skip Docker installation
#   --skip-runner       Skip GitHub Actions runner installation
#   --skip-hat          Skip custom HAT setup
#   --runner-url URL    GitHub repository URL for the Actions runner
#   --runner-token TOK  Registration token for the Actions runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
SKIP_DOCKER=false
SKIP_RUNNER=false
SKIP_HAT=false
RUNNER_URL=""
RUNNER_TOKEN=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-docker)  SKIP_DOCKER=true ;;
    --skip-runner)  SKIP_RUNNER=true ;;
    --skip-hat)     SKIP_HAT=true ;;
    --runner-url)   RUNNER_URL="$2";  shift ;;
    --runner-token) RUNNER_TOKEN="$2"; shift ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ── Root check ────────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  error "Please run as root: sudo bash $0"
  exit 1
fi

info "=== PerformanceNode – Raspberry Pi 5 Setup ==="
info "Starting at $(date)"

# ── Step 1: System ────────────────────────────────────────────────────────────
info "Step 1/4 – Configuring system..."
bash "${SCRIPT_DIR}/setup-system.sh"

# ── Step 2: Docker ────────────────────────────────────────────────────────────
if [[ "$SKIP_DOCKER" == "false" ]]; then
  info "Step 2/4 – Installing Docker..."
  bash "${SCRIPT_DIR}/setup-docker.sh"
else
  warn "Step 2/4 – Docker setup skipped."
fi

# ── Step 3: GitHub Actions runner ─────────────────────────────────────────────
if [[ "$SKIP_RUNNER" == "false" ]]; then
  info "Step 3/4 – Installing GitHub Actions self-hosted runner..."
  RUNNER_ARGS=()
  [[ -n "$RUNNER_URL"   ]] && RUNNER_ARGS+=(--url   "$RUNNER_URL")
  [[ -n "$RUNNER_TOKEN" ]] && RUNNER_ARGS+=(--token "$RUNNER_TOKEN")
  bash "${SCRIPT_DIR}/setup-github-runner.sh" "${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"}"
else
  warn "Step 3/4 – GitHub Actions runner setup skipped."
fi

# ── Step 4: Custom HAT ────────────────────────────────────────────────────────
if [[ "$SKIP_HAT" == "false" ]]; then
  info "Step 4/4 – Configuring GP2040-CE latency-test HAT..."
  bash "${SCRIPT_DIR}/setup-hat.sh"
else
  warn "Step 4/4 – HAT setup skipped."
fi

info "=== Setup complete. Please reboot the device. ==="
info "  sudo reboot"
