#!/usr/bin/env bash
# inject-cache-mounts.sh — Install the cache-hook-wrapper that injects
# bind mounts and environment variables into every job container.
#
# How it works:
#   The @actions/runner-container-hooks Docker hook orchestrates job containers.
#   This script installs a thin Node.js wrapper that intercepts the
#   `prepare_job` hook call, injects the cache bind mounts and env vars into
#   the container spec, and then delegates to the real hook.
#
#   ACTIONS_RUNNER_CONTAINER_HOOKS   → /opt/runner-hooks/cache-hook-wrapper.js (wrapper)
#   ACTIONS_RUNNER_CONTAINER_HOOKS_REAL → real docker hook index.js (called by wrapper)
#
# Cache mounts injected into every job container:
#   /opt/runner-cache/nuget     → /root/.nuget/packages   (rw)  — NuGet package cache
#   /opt/runner-cache/pico-sdk  → /opt/pico-sdk            (ro)  — Pico SDK (read-only)
#   /opt/runner-cache/ccache    → /root/.ccache            (rw)  — ccache objects
#
# Environment variables injected (workflow env takes priority):
#   NUGET_PACKAGES=/root/.nuget/packages
#   PICO_SDK_PATH=/opt/pico-sdk
#   CCACHE_DIR=/root/.ccache
#
# Prerequisites:
#   • @actions/runner-container-hooks installed (Treize's Docker setup)
#   • Node.js available on the host (required by the hooks package)
#   • GitHub Actions runner systemd service exists
#
# Usage: sudo ./inject-cache-mounts.sh
#
# Environment variables:
#   RUNNER_HOOKS_DIR    Base dir for hook scripts (default: /opt/runner-hooks)
#   RUNNER_USER         Runner service user       (default: actions-runner)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/runner-service.sh"

# ── Configuration ─────────────────────────────────────────────────────────
RUNNER_HOOKS_DIR="${RUNNER_HOOKS_DIR:-/opt/runner-hooks}"
RUNNER_USER="${RUNNER_USER:-actions-runner}"

# Path to the real @actions/runner-container-hooks Docker hook.
# This matches Treize's architecture decision (treize-container-execution-arch.md).
REAL_HOOK="${RUNNER_HOOKS_DIR}/node_modules/@actions/runner-container-hooks/packages/docker/dist/index.js"

WRAPPER="${RUNNER_HOOKS_DIR}/cache-hook-wrapper.js"

# ── Root check ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

# ── Pre-flight checks ──────────────────────────────────────────────────────
echo "==> Installing cache-hook-wrapper..."

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: Node.js is not installed. Run the runner setup script first." >&2
  exit 1
fi

if [ ! -f "$REAL_HOOK" ]; then
  echo "ERROR: Real hook not found at:" >&2
  echo "       ${REAL_HOOK}" >&2
  echo "  Run the runner container-hooks setup script first." >&2
  exit 1
fi

# ── 1. Write the Node.js wrapper ──────────────────────────────────────────
mkdir -p "$RUNNER_HOOKS_DIR"

if [ -f "$WRAPPER" ]; then
  echo "  ${WRAPPER} already exists — overwriting to ensure latest version"
fi

echo "  Writing ${WRAPPER}"
cat > "$WRAPPER" <<'NODESCRIPT'
#!/usr/bin/env node
/**
 * cache-hook-wrapper.js
 *
 * Wraps @actions/runner-container-hooks to inject cache bind mounts and
 * environment variables into every job container that the runner starts.
 *
 * Set ACTIONS_RUNNER_CONTAINER_HOOKS      → this file
 * Set ACTIONS_RUNNER_CONTAINER_HOOKS_REAL → real docker hook index.js
 *
 * Only prepare_job is modified; all other hook calls are forwarded unchanged.
 */
'use strict';

const fs = require('fs');
const { spawnSync } = require('child_process');

// ── Cache mounts: [hostPath, containerPath, readOnly] ────────────────────
const CACHE_MOUNTS = [
  ['/opt/runner-cache/nuget',    '/root/.nuget/packages', false],
  ['/opt/runner-cache/pico-sdk', '/opt/pico-sdk',         true],
  ['/opt/runner-cache/ccache',   '/root/.ccache',         false],
];

// ── Env vars to set inside containers (workflow env takes priority) ───────
const CACHE_ENV = {
  NUGET_PACKAGES: '/root/.nuget/packages',
  PICO_SDK_PATH:  '/opt/pico-sdk',
  CCACHE_DIR:     '/root/.ccache',
};

// ── Validate runtime environment ──────────────────────────────────────────
const realHook = process.env.ACTIONS_RUNNER_CONTAINER_HOOKS_REAL;
if (!realHook) {
  process.stderr.write(
    'cache-hook-wrapper: ACTIONS_RUNNER_CONTAINER_HOOKS_REAL is not set.\n'
  );
  process.exit(1);
}

if (!fs.existsSync(realHook)) {
  process.stderr.write(
    `cache-hook-wrapper: real hook not found: ${realHook}\n`
  );
  process.exit(1);
}

// ── Inject mounts/env for prepare_job ────────────────────────────────────
const hookName    = process.argv[2];
const requestFile = process.argv[3];

if (hookName === 'prepare_job' && requestFile && fs.existsSync(requestFile)) {
  try {
    const request   = JSON.parse(fs.readFileSync(requestFile, 'utf8'));
    const container = request.args && request.args.container;

    if (container) {
      // Inject env: our defaults first, then workflow env overrides.
      container.environmentVariables = Object.assign(
        {},
        CACHE_ENV,
        container.environmentVariables || {}
      );

      // Inject bind mounts: skip any target path already mapped by the job.
      const existingTargets = new Set(
        (container.userMountVolumes || []).map(v => v.targetVolumePath)
      );

      const newMounts = CACHE_MOUNTS
        .filter(([, target]) => !existingTargets.has(target))
        .map(([source, target, readOnly]) => ({
          sourceVolumePath: source,
          targetVolumePath: target,
          readOnly,
        }));

      container.userMountVolumes = [
        ...(container.userMountVolumes || []),
        ...newMounts,
      ];
    }

    fs.writeFileSync(requestFile, JSON.stringify(request));
  } catch (err) {
    // Log but do NOT abort — let the real hook run and surface any real error.
    process.stderr.write(
      `cache-hook-wrapper: warning: failed to inject mounts: ${err.message}\n`
    );
  }
}

// ── Delegate to the real hook ─────────────────────────────────────────────
const result = spawnSync(
  process.execPath,
  [realHook, ...process.argv.slice(2)],
  { stdio: 'inherit', env: process.env }
);

process.exit(result.status !== null ? result.status : 1);
NODESCRIPT

chmod +x "$WRAPPER"
chown "${RUNNER_USER}:${RUNNER_USER}" "$WRAPPER"

# ── 2. Write systemd drop-in ───────────────────────────────────────────────
DROP_IN="$(runner_detect_drop_in_dir)/20-cache-hooks.conf"
DROP_IN_CONTENT=$(cat <<EOF
# Generated by inject-cache-mounts.sh — do not edit manually.
# Routes the runner through the cache-hook-wrapper before the real Docker hook.
[Service]
Environment="ACTIONS_RUNNER_CONTAINER_HOOKS=${WRAPPER}"
Environment="ACTIONS_RUNNER_CONTAINER_HOOKS_REAL=${REAL_HOOK}"
EOF
)

echo "  Writing systemd drop-in: $DROP_IN"
runner_write_drop_in "20-cache-hooks.conf" "$DROP_IN_CONTENT"
systemctl daemon-reload
echo "  daemon-reload done"

# ── 3. Verify wrapper is syntactically valid ──────────────────────────────
echo "  Verifying wrapper syntax..."
node --check "$WRAPPER"
echo "  Syntax OK."

# ── 4. Ensure host cache directories exist ────────────────────────────────
echo ""
echo "  Verifying host cache directories..."
missing=false
for dir in /opt/runner-cache/nuget /opt/runner-cache/pico-sdk /opt/runner-cache/ccache; do
  if [ -d "$dir" ]; then
    echo "    OK   $dir"
  else
    echo "    WARN $dir — does not exist (run the relevant setup script)"
    missing=true
  fi
done
if [ "$missing" = true ]; then
  echo ""
  echo "  WARNING: One or more cache directories are missing."
  echo "  Run setup-nuget-cache.sh and/or setup-pico-sdk-cache.sh first."
fi

echo ""
echo "==> Cache hook wrapper installed."
echo "    Wrapper  : ${WRAPPER}"
echo "    Real hook: ${REAL_HOOK}"
echo "    Drop-in  : ${DROP_IN}"
echo ""
echo "  Restart the runner service to apply:"
echo "    sudo systemctl restart actions-runner"
