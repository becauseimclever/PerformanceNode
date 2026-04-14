#!/usr/bin/env bash
# setup-runner.sh — Download, install, and register the GitHub Actions
# self-hosted runner on Raspberry Pi OS Bookworm ARM64.
#
# What this script does:
#   1. Validate required environment variables when registration is needed.
#   2. Create /opt/actions-runner/ owned by actions-runner user.
#   3. Install Node.js + @actions/runner-container-hooks on the host.
#   4. Download the latest actions-runner release for linux-arm64 from the
#      GitHub releases API.
#   5. Extract the archive to /opt/actions-runner/.
#   6. Run ./config.sh as the actions-runner user (--unattended --replace).
#   7. Install and enable the systemd service via ./svc.sh.
#
# Required environment variables:
#   GITHUB_OWNER    GitHub organisation or user that owns the repository.
#   GITHUB_REPO     Repository name (e.g. PerformanceNode).
#   RUNNER_TOKEN    Registration token.  Generate one at:
#                   https://github.com/<OWNER>/<REPO>/settings/actions/runners/new
#
# Optional environment variables:
#   RUNNER_NAME     Display name for this runner (default: hostname).
#   RUNNER_LABELS   Comma-separated labels      (default: self-hosted,linux,arm64,performancenode).
#   RUNNER_USER     OS user to run the service  (default: actions-runner).
#   RUNNER_DIR      Installation directory       (default: /opt/actions-runner).
#
# Usage: sudo ./setup-runner.sh [--non-interactive]
#
# Run as root (called via sudo from setup.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/runner-service.sh"

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

# ── Configuration ─────────────────────────────────────────────────────────
RUNNER_USER="${RUNNER_USER:-actions-runner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,arm64,performancenode}"

echo ""
info "==> GitHub Actions runner setup starting..."
info "    Name   : ${RUNNER_NAME}"
info "    Labels : ${RUNNER_LABELS}"
info "    Dir    : ${RUNNER_DIR}"
info "    User   : ${RUNNER_USER}"

# ── Check if runner is already configured ──────────────────────────────────
RUNNER_ALREADY_CONFIGURED=false
EXISTING_SERVICE=""

EXISTING_SERVICE=$(
  find /etc/systemd/system -maxdepth 1 \( -type f -o -type l \) \
    -name 'actions.runner.*.service' -print 2>/dev/null \
    | sort \
    | head -1 || true
)

if [ -n "$EXISTING_SERVICE" ] || [ -f "${RUNNER_DIR}/.runner" ]; then
  RUNNER_ALREADY_CONFIGURED=true
fi

if [ "$RUNNER_ALREADY_CONFIGURED" = false ]; then
  MISSING=false
  for var in GITHUB_OWNER GITHUB_REPO RUNNER_TOKEN; do
    if [ -z "${!var:-}" ]; then
      warn "Required environment variable \$$var is not set."
      MISSING=true
    fi
  done

  if [ "$MISSING" = true ]; then
    echo "" >&2
    echo -e "${C_RED}ERROR: Missing required environment variables.${C_RESET}" >&2
    echo "" >&2
    echo "  To register this runner you need a registration token from GitHub." >&2
    echo "  Steps:" >&2
    echo "    1. Go to: https://github.com/<OWNER>/<REPO>/settings/actions/runners/new" >&2
    echo "    2. Copy the token shown in 'Configure' step." >&2
    echo "    3. Export the required variables, e.g.:" >&2
    echo "" >&2
    echo "       export GITHUB_OWNER=my-org" >&2
    echo "       export GITHUB_REPO=PerformanceNode" >&2
    echo "       export RUNNER_TOKEN=AXXXXXXXXXXXXXXXXXXXXXXXXX" >&2
    echo "" >&2
    echo "    4. Re-run: sudo -E ./setup-runner.sh" >&2
    echo "" >&2
    exit 1
  fi

  info "    Owner  : ${GITHUB_OWNER}"
  info "    Repo   : ${GITHUB_REPO}"
else
  info "    Existing runner registration detected — refreshing host prerequisites only."
fi

# ── 1. Ensure the runner user exists ──────────────────────────────────────
if ! id "$RUNNER_USER" &>/dev/null; then
  die "User '$RUNNER_USER' does not exist. Run setup-system.sh first."
fi

# ── 2. Create runner install directory ────────────────────────────────────
if [ ! -d "$RUNNER_DIR" ]; then
  info "Creating $RUNNER_DIR..."
  mkdir -p "$RUNNER_DIR"
fi
chown "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
ok "Runner directory: $RUNNER_DIR"

# ── 3. Install Node.js + container hooks prerequisites ────────────────────
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  ok "Node.js already installed: $(node --version)"
else
  info "Installing Node.js and npm..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs npm
  ok "Node.js installed: $(node --version)"
fi

HOOKS_DIR="/opt/runner-hooks"
HOOKS_PACKAGE_DIR="${HOOKS_DIR}/node_modules/@actions/runner-container-hooks"
mkdir -p "$HOOKS_DIR"

if [ -d "$HOOKS_PACKAGE_DIR" ]; then
  ok "@actions/runner-container-hooks already installed — skipping npm install."
else
  info "Installing @actions/runner-container-hooks into ${HOOKS_DIR}..."
  pushd "$HOOKS_DIR" > /dev/null
  npm install --no-save @actions/runner-container-hooks
  popd > /dev/null
  ok "Container hooks package installed."
fi

# ── 4. Download latest linux-arm64 runner release ─────────────────────────
RUNNER_TARBALL="${RUNNER_DIR}/runner.tar.gz"

if [ ! -f "${RUNNER_DIR}/config.sh" ]; then
  info "Fetching latest runner release info from GitHub API..."
  LATEST_RELEASE=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/actions/runner/releases/latest)

  DOWNLOAD_URL=$(echo "$LATEST_RELEASE" \
    | grep -oP '"browser_download_url":\s*"\Khttps://[^"]*linux-arm64[^"]*\.tar\.gz')

  if [ -z "$DOWNLOAD_URL" ]; then
    die "Could not find linux-arm64 runner download URL in GitHub API response."
  fi

  RUNNER_VERSION=$(echo "$LATEST_RELEASE" | grep -oP '"tag_name":\s*"\Kv[^"]+')
  info "Downloading runner ${RUNNER_VERSION} from ${DOWNLOAD_URL}..."
  curl -fsSL -o "$RUNNER_TARBALL" "$DOWNLOAD_URL"
  ok "Runner archive downloaded."

  info "Extracting to ${RUNNER_DIR}..."
  tar -xzf "$RUNNER_TARBALL" -C "$RUNNER_DIR"
  rm -f "$RUNNER_TARBALL"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
  ok "Runner extracted."
else
  INSTALLED_VERSION=$("${RUNNER_DIR}/config.sh" --version 2>/dev/null || echo "unknown")
  ok "Runner already extracted (version: ${INSTALLED_VERSION}) — skipping download."
fi

# ── 5. Configure the runner ────────────────────────────────────────────────
if [ "$RUNNER_ALREADY_CONFIGURED" = false ]; then
  info "Configuring runner (--unattended --replace)..."
  sudo -u "$RUNNER_USER" \
    "${RUNNER_DIR}/config.sh" \
      --unattended \
      --replace \
      --url "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}" \
      --token "$RUNNER_TOKEN" \
      --name "$RUNNER_NAME" \
      --labels "$RUNNER_LABELS" \
      --work "_work"
  ok "Runner configured."

  # ── 6. Install and enable systemd service ───────────────────────────────
  info "Installing runner as systemd service..."
  pushd "$RUNNER_DIR" > /dev/null
  ./svc.sh install "$RUNNER_USER"
  popd > /dev/null
  ok "Systemd service installed."
else
  info "Runner registration already present — skipping config.sh and svc.sh install."
fi

INSTALLED_SERVICE=$(find /etc/systemd/system -maxdepth 1 \( -type f -o -type l \) -name 'actions.runner.*.service' -print 2>/dev/null | sort | head -1 || true)
if [ -z "$INSTALLED_SERVICE" ]; then
  warn "Could not find installed service file — service name may differ."
  INSTALLED_SERVICE_NAME="$(runner_detect_service_name)"
else
  INSTALLED_SERVICE_NAME="$(basename "$INSTALLED_SERVICE" .service)"
fi

runner_sync_staged_drop_ins "$INSTALLED_SERVICE_NAME"
runner_ensure_service_alias "$INSTALLED_SERVICE_NAME"
systemctl daemon-reload

systemctl enable --now "${INSTALLED_SERVICE_NAME}"
ok "Service '${INSTALLED_SERVICE_NAME}' enabled and started."

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
ok "==> GitHub Actions runner setup complete."
echo ""
if [ -n "${GITHUB_OWNER:-}" ] && [ -n "${GITHUB_REPO:-}" ]; then
  info "  Verify the runner appears at:"
  info "    https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/settings/actions/runners"
  echo ""
fi

info "  Service management:"
info "    sudo systemctl status ${INSTALLED_SERVICE_NAME}"
info "    sudo systemctl restart ${INSTALLED_SERVICE_NAME}"
info "    sudo systemctl restart actions-runner"
info "    sudo journalctl -u ${INSTALLED_SERVICE_NAME} -f"
