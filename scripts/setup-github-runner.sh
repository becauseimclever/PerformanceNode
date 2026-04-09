#!/usr/bin/env bash
# setup-github-runner.sh – Install a GitHub Actions self-hosted runner on the Pi.
# Must be run as root.
#
# Usage:
#   sudo bash setup-github-runner.sh [--url REPO_URL] [--token REG_TOKEN]
#
# The runner runs as the 'github-runner' system user and is managed by systemd.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ "$EUID" -ne 0 ]]; then
  error "Please run as root."
  exit 1
fi

# ── Defaults ──────────────────────────────────────────────────────────────────
RUNNER_VERSION="2.323.0"
RUNNER_USER="github-runner"
RUNNER_HOME="/opt/github-runner"
RUNNER_URL=""
RUNNER_TOKEN=""
RUNNER_NAME="performancenode-$(hostname)"
RUNNER_LABELS="self-hosted,Linux,ARM64,raspberry-pi-5,performancenode"
RUNNER_WORK_DIR="${RUNNER_HOME}/_work"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)   RUNNER_URL="$2";   shift ;;
    --token) RUNNER_TOKEN="$2"; shift ;;
    --name)  RUNNER_NAME="$2";  shift ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ── Create runner user ────────────────────────────────────────────────────────
if ! id "$RUNNER_USER" &>/dev/null; then
  info "Creating system user '${RUNNER_USER}'..."
  useradd -r -m -d "$RUNNER_HOME" -s /bin/bash "$RUNNER_USER"
fi

# Add runner user to the docker group so workflows can use Docker.
if getent group docker &>/dev/null; then
  usermod -aG docker "$RUNNER_USER"
fi

# ── Download runner package ───────────────────────────────────────────────────
RUNNER_ARCHIVE="actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL_DOWNLOAD="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"

mkdir -p "$RUNNER_HOME"

if [[ ! -f "${RUNNER_HOME}/run.sh" ]]; then
  info "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
  TMPFILE="$(mktemp)"
  curl -fsSL "$RUNNER_URL_DOWNLOAD" -o "$TMPFILE"

  info "Extracting runner archive..."
  tar -xzf "$TMPFILE" -C "$RUNNER_HOME"
  rm -f "$TMPFILE"

  chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_HOME"
else
  warn "Runner binaries already present. Skipping download."
fi

# ── Install runner dependencies ───────────────────────────────────────────────
info "Installing runner dependencies..."
bash "${RUNNER_HOME}/bin/installdependencies.sh"

# ── Configure runner ──────────────────────────────────────────────────────────
mkdir -p "$RUNNER_WORK_DIR"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_WORK_DIR"

if [[ -n "$RUNNER_URL" && -n "$RUNNER_TOKEN" ]]; then
  info "Configuring runner for repository: ${RUNNER_URL}..."
  sudo -u "$RUNNER_USER" \
    "${RUNNER_HOME}/config.sh" \
      --url    "$RUNNER_URL" \
      --token  "$RUNNER_TOKEN" \
      --name   "$RUNNER_NAME" \
      --labels "$RUNNER_LABELS" \
      --work   "$RUNNER_WORK_DIR" \
      --unattended \
      --replace
else
  warn "No --url / --token provided. Runner configuration skipped."
  warn "Configure manually later with:"
  warn "  sudo -u ${RUNNER_USER} ${RUNNER_HOME}/config.sh --url <REPO_URL> --token <TOKEN>"
fi

# ── Install as systemd service ────────────────────────────────────────────────
info "Installing runner as a systemd service..."

cat > /etc/systemd/system/github-runner.service << EOF
[Unit]
Description=GitHub Actions Self-Hosted Runner
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=${RUNNER_USER}
WorkingDirectory=${RUNNER_HOME}
ExecStart=${RUNNER_HOME}/run.sh
Restart=on-failure
RestartSec=5
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min

# Environment
Environment=RUNNER_ALLOW_RUNASROOT=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable github-runner

if [[ -n "$RUNNER_URL" && -n "$RUNNER_TOKEN" ]]; then
  systemctl start github-runner
  info "GitHub Actions runner service started."
else
  warn "Runner service installed but NOT started (no configuration yet)."
  warn "Start it after configuring with: sudo systemctl start github-runner"
fi

info "GitHub Actions runner setup complete."
info "Runner home: ${RUNNER_HOME}"
info "Runner labels: ${RUNNER_LABELS}"
