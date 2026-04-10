#!/usr/bin/env bash
# setup-ssh.sh — SSH hardening for the PerformanceNode Pi 5 runner.
#
# 1. Imports the operator's SSH public key into authorized_keys (idempotent).
# 2. Hardens /etc/ssh/sshd_config: disable password auth, enable pubkey auth.
# 3. Restarts sshd to apply changes.
#
# Usage:
#   sudo ./setup-ssh.sh [--non-interactive]
#
# Options:
#   --non-interactive   Skip confirmation prompts (for CI/automation).
#                       Requires SSH_PUBLIC_KEY env var to be set.
#
# Environment variables:
#   SSH_PUBLIC_KEY   Public key string to import (skips interactive prompt).

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────
SSH_DIR="${HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"
NON_INTERACTIVE=false

# ── Argument parsing ───────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=true ;;
    *) echo "ERROR: Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── Root check ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

echo ""
echo "==> SSH Hardening Setup"
echo "    Target user home : ${HOME}"
echo "    authorized_keys  : ${AUTH_KEYS}"
echo "    sshd_config      : ${SSHD_CONFIG}"
echo ""

# ── Phase 1: SSH key import ────────────────────────────────────────────────
echo "--> Phase 1: SSH key import"

# Check whether authorized_keys already has entries (idempotency guard).
if [ -f "$AUTH_KEYS" ] && [ -s "$AUTH_KEYS" ]; then
  echo "    authorized_keys already has entries — skipping key import."
  KEY_ALREADY_PRESENT=true
else
  KEY_ALREADY_PRESENT=false

  # Resolve the key to import.
  if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    echo "    Using SSH_PUBLIC_KEY from environment."
    PUBLIC_KEY="$SSH_PUBLIC_KEY"
  elif [ "$NON_INTERACTIVE" = true ]; then
    echo "ERROR: --non-interactive requires SSH_PUBLIC_KEY env var to be set." >&2
    exit 1
  else
    echo "    No authorized_keys found and SSH_PUBLIC_KEY is not set."
    echo "    Paste your SSH public key below (single line, e.g. 'ssh-ed25519 AAAA... user@host'):"
    echo -n "    > "
    read -r PUBLIC_KEY
    if [ -z "$PUBLIC_KEY" ]; then
      echo "ERROR: No key provided." >&2
      exit 1
    fi
  fi

  # Write the key.
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
  echo "    Key written to ${AUTH_KEYS}"
fi

# Enforce correct permissions regardless of whether we just wrote the key.
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
echo "    Permissions: ${SSH_DIR} → 700, ${AUTH_KEYS} → 600"

# Verify the key file is non-empty.
if [ ! -s "$AUTH_KEYS" ]; then
  echo "ERROR: authorized_keys is empty after write — aborting." >&2
  exit 1
fi
echo "    Verified: authorized_keys is non-empty. ✓"

# ── Phase 2: sshd_config hardening ────────────────────────────────────────
echo ""
echo "--> Phase 2: sshd_config hardening"

if [ ! -f "$SSHD_CONFIG" ]; then
  echo "ERROR: ${SSHD_CONFIG} not found. Is openssh-server installed?" >&2
  exit 1
fi

echo "⚠️   Password authentication will be disabled."
echo "⚠️   Ensure your SSH key works before closing this session."
echo ""

# Require explicit confirmation unless running non-interactively.
if [ "$NON_INTERACTIVE" = false ]; then
  echo -n "    Proceed with disabling password authentication? [y/N] "
  read -r CONFIRM
  case "$CONFIRM" in
    y|Y) echo "    Confirmed." ;;
    *)   echo "    Aborted by user. sshd_config was not modified." ; exit 0 ;;
  esac
fi

# Helper: set or replace a directive in sshd_config (sed in-place).
# Usage: set_sshd_option KEY VALUE
set_sshd_option() {
  local key="$1"
  local value="$2"
  local current

  # Check current value (match the key at line start, case-insensitive, ignoring #comments).
  current=$(grep -iP "^\s*${key}\s+" "$SSHD_CONFIG" | tail -1 || true)

  if echo "$current" | grep -qiP "^\s*${key}\s+${value}\s*$"; then
    echo "    ${key} already set to '${value}' — no change needed."
  elif echo "$current" | grep -qiP "^\s*${key}\s+"; then
    # Replace the existing (uncommented) line.
    sed -i -E "s|^\s*(${key})\s+.*|${key} ${value}|I" "$SSHD_CONFIG"
    echo "    ${key} updated → ${value}"
  else
    # The directive is absent or only commented — append it.
    echo "${key} ${value}" >> "$SSHD_CONFIG"
    echo "    ${key} appended → ${value}"
  fi
}

set_sshd_option "PasswordAuthentication" "no"
set_sshd_option "PubkeyAuthentication"   "yes"
set_sshd_option "AuthorizedKeysFile"     ".ssh/authorized_keys"
set_sshd_option "PermitRootLogin"        "no"

echo ""
echo "--> Restarting sshd..."
systemctl restart sshd
echo "    sshd restarted. ✓"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "==> SSH hardening complete."
echo "    authorized_keys     : ${AUTH_KEYS}"
echo "    PasswordAuthentication : no"
echo "    PubkeyAuthentication   : yes"
echo "    PermitRootLogin        : no"
if [ "$KEY_ALREADY_PRESENT" = true ]; then
  echo "    (Key import skipped — authorized_keys already had entries)"
fi
echo ""
echo "    Test your key login in a NEW terminal before closing this session."
