#!/usr/bin/env bash
# verify-setup.sh — Post-setup verification script for PerformanceNode Pi 5 runner.
#
# Run this ON the Pi after ./setup.sh completes to confirm the runner is
# correctly configured.  Prints PASS/FAIL per check with colour coding and
# exits 0 if all checks pass, 1 if any fail.
#
# Usage:
#   sudo ./scripts/verify/verify-setup.sh
#
# No options; no side effects — read-only checks only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/runner-service.sh"

# ── Colours (only when writing to a terminal) ──────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; RESET=''
fi

# ── State ──────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
RUNNER_USER="${RUNNER_USER:-actions-runner}"
RUNNER_SERVICE_NAME="${RUNNER_SERVICE_NAME:-}"
SSH_TARGET_USER="${SSH_TARGET_USER:-${SUDO_USER:-$(id -un)}}"
SSH_TARGET_HOME="${SSH_TARGET_HOME:-$(getent passwd "$SSH_TARGET_USER" | cut -d: -f6 || true)}"

if [ -z "$SSH_TARGET_HOME" ]; then
  SSH_TARGET_HOME="$HOME"
fi

# ── Helpers ────────────────────────────────────────────────────────────────
pass() {
  local label="$1"
  local detail="${2:-}"
  echo -e "  ${GREEN}PASS${RESET}  ${label}${detail:+  (${detail})}"
  PASS_COUNT=$(( PASS_COUNT + 1 ))
}

fail() {
  local label="$1"
  local detail="${2:-}"
  echo -e "  ${RED}FAIL${RESET}  ${label}${detail:+  → ${detail}}"
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}

warn() {
  local label="$1"
  local detail="${2:-}"
  echo -e "  ${YELLOW}WARN${RESET}  ${label}${detail:+  (${detail})}"
}

section() {
  echo ""
  echo -e "${CYAN}── $1 ──────────────────────────────────────────────────${RESET}"
}

detect_runner_service() {
  if [ -n "$RUNNER_SERVICE_NAME" ]; then
    echo "$RUNNER_SERVICE_NAME"
    return 0
  fi

  if [ -e "/etc/systemd/system/actions-runner.service" ]; then
    echo "actions-runner"
    return 0
  fi

  local matches=(/etc/systemd/system/actions.runner.*.service)
  if [ ${#matches[@]} -gt 0 ] && [ -e "${matches[0]}" ]; then
    basename "${matches[0]}" .service
    return 0
  fi

  return 1
}

# ── Banner ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║   PerformanceNode — Post-Setup Verification  ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${RESET}"
echo ""

# ── 1. Docker ──────────────────────────────────────────────────────────────
section "Docker"

if command -v docker >/dev/null 2>&1; then
  pass "docker binary present" "$(docker --version 2>/dev/null | head -1)"
else
  fail "docker binary present" "docker not found in PATH"
fi

if docker info >/dev/null 2>&1; then
  pass "Docker daemon running" "docker info succeeded"
else
  fail "Docker daemon running" "docker info failed — daemon may not be running or user lacks access"
fi

# Verify Docker can pull/run a minimal ARM64 image (smoke test)
if docker image inspect hello-world >/dev/null 2>&1 || \
   docker pull --platform linux/arm64 hello-world >/dev/null 2>&1; then
  pass "Docker ARM64 image pull" "hello-world reachable"
else
  warn "Docker ARM64 image pull" "could not verify — network or registry may be unavailable"
fi

# ── 2. System user ─────────────────────────────────────────────────────────
section "System User"

if id "$RUNNER_USER" >/dev/null 2>&1; then
  pass "User '${RUNNER_USER}' exists" "$(id "$RUNNER_USER")"
else
  fail "User '${RUNNER_USER}' exists" "user not found — run the runner setup script"
fi

# Check runner user is in the docker group
if id "$RUNNER_USER" 2>/dev/null | grep -q "docker"; then
  pass "User '${RUNNER_USER}' in docker group"
else
  fail "User '${RUNNER_USER}' in docker group" "not a member of docker group — containers will fail"
fi

# ── 3. Cache directories ───────────────────────────────────────────────────
section "Cache Directories"

if [ -d "/opt/runner-cache" ]; then
  CACHE_ROOT="/opt/runner-cache"
  pass "Cache root exists" "$CACHE_ROOT"

  for subdir in nuget ccache pico-sdk; do
    dir="${CACHE_ROOT}/${subdir}"
    if [ -d "$dir" ]; then
      owner=$(stat -c '%U:%G' "$dir" 2>/dev/null || echo "unknown")
      mode=$(stat -c '%a' "$dir" 2>/dev/null || echo "unknown")
      if [ "$subdir" = "pico-sdk" ]; then
        pass "  ${dir} exists" "owner=${owner} mode=${mode}"
        if [ "$owner" != "root:root" ]; then
          warn "  ${dir} owner" "expected root:root per cache design, got ${owner}"
        fi
      elif [ "$owner" = "${RUNNER_USER}:${RUNNER_USER}" ] && [ "$mode" = "1777" ]; then
        pass "  ${dir} ownership/mode" "owner=${owner} mode=${mode}"
      else
        fail "  ${dir} ownership/mode" "got owner=${owner} mode=${mode}, expected ${RUNNER_USER}:${RUNNER_USER} and 1777"
      fi
    else
      fail "  ${CACHE_ROOT}/${subdir} exists" "directory not found — run setup-${subdir}-cache.sh"
    fi
  done
else
  fail "Cache root exists" "/opt/runner-cache not found — run cache setup scripts"
fi

if [ -d "/opt/cache" ]; then
  warn "Legacy cache root present" "/opt/cache exists — stale pre-migration state"
fi

# ── 4. cgroup v2 ───────────────────────────────────────────────────────────
section "cgroup v2"

CGROUP_CONTROLLERS="/sys/fs/cgroup/cgroup.controllers"
if [ -f "$CGROUP_CONTROLLERS" ]; then
  controllers=$(cat "$CGROUP_CONTROLLERS")
  pass "cgroup v2 active" "controllers: ${controllers}"
  if echo "$controllers" | grep -q "memory"; then
    pass "cgroup memory controller present"
  else
    fail "cgroup memory controller present" "not in cgroup.controllers — check /boot/firmware/cmdline.txt for cgroup_memory=1 cgroup_enable=memory"
  fi
else
  fail "cgroup v2 active" "${CGROUP_CONTROLLERS} not found — system may be using cgroup v1 or cgroups not mounted"
fi

# ── 5. GitHub Actions runner service ──────────────────────────────────────
section "Actions Runner Service"

RUNNER_SERVICE="$(detect_runner_service || true)"

if [ -n "$RUNNER_SERVICE" ]; then
  pass "Runner service detected" "$RUNNER_SERVICE"

  runner_state=$(systemctl is-active "$RUNNER_SERVICE" 2>/dev/null || echo "unknown")
  if [ "$runner_state" = "active" ]; then
    pass "Runner service is active"
  else
    fail "Runner service is active" "state=${runner_state} — run: systemctl start ${RUNNER_SERVICE}"
  fi

  runner_enabled=$(systemctl is-enabled "$RUNNER_SERVICE" 2>/dev/null || echo "unknown")
  if [ "$runner_enabled" = "enabled" ]; then
    pass "Runner service is enabled"
  else
    fail "Runner service is enabled" "state=${runner_enabled}"
  fi
else
  fail "Runner service detected" "no actions.runner.*.service (or actions-runner.service) found — run the runner setup script"
fi

# Check systemd drop-ins exist for cache env vars
DROP_IN_DIR=""
if [ -n "$RUNNER_SERVICE" ]; then
  DROP_IN_DIR="/etc/systemd/system/${RUNNER_SERVICE}.service.d"
fi

if [ -n "$DROP_IN_DIR" ] && [ -d "$DROP_IN_DIR" ]; then
  drop_ins=$(ls "$DROP_IN_DIR" 2>/dev/null | tr '\n' ' ')
  pass "Systemd drop-in directory exists" "${drop_ins:-empty}"
  for expected_dropin in "10-nuget-cache.conf" "10-pico-cache.conf" "20-cache-hooks.conf"; do
    if [ -f "${DROP_IN_DIR}/${expected_dropin}" ]; then
      pass "  Drop-in ${expected_dropin} present"
    else
      fail "  Drop-in ${expected_dropin} present" "missing — cache env vars may not be injected"
    fi
  done
else
  fail "Systemd drop-in directory exists" "${DROP_IN_DIR:-runner service unknown} not found"
fi

if [ -d "$(runner_staging_drop_in_dir)" ] && [ "$(runner_staging_drop_in_dir)" != "$DROP_IN_DIR" ]; then
  warn "Compatibility drop-ins present" "$(runner_staging_drop_in_dir)"
fi

# ── 6. SSH hardening ───────────────────────────────────────────────────────
section "SSH Hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
  pass "sshd_config present"

  # Check PasswordAuthentication is set to no (active, uncommented)
  if grep -iP "^\s*PasswordAuthentication\s+no\s*$" "$SSHD_CONFIG" >/dev/null 2>&1; then
    pass "PasswordAuthentication no"
  else
    fail "PasswordAuthentication no" "not set or set to 'yes' in ${SSHD_CONFIG}"
  fi

  # Check PubkeyAuthentication is yes
  if grep -iP "^\s*PubkeyAuthentication\s+yes\s*$" "$SSHD_CONFIG" >/dev/null 2>&1; then
    pass "PubkeyAuthentication yes"
  else
    fail "PubkeyAuthentication yes" "not set or disabled in ${SSHD_CONFIG}"
  fi

  # Check PermitRootLogin is no
  if grep -iP "^\s*PermitRootLogin\s+no\s*$" "$SSHD_CONFIG" >/dev/null 2>&1; then
    pass "PermitRootLogin no"
  else
    fail "PermitRootLogin no" "not set or set to 'yes' in ${SSHD_CONFIG}"
  fi
else
  fail "sshd_config present" "${SSHD_CONFIG} not found — is openssh-server installed?"
fi

# Check authorized_keys has entries
AUTH_KEYS="${SSH_TARGET_HOME}/.ssh/authorized_keys"
if [ -f "$AUTH_KEYS" ] && [ -s "$AUTH_KEYS" ]; then
  key_count=$(grep -c "ssh-" "$AUTH_KEYS" 2>/dev/null || echo 0)
  pass "authorized_keys has entries" "${key_count} key(s) in ${AUTH_KEYS}"
else
  fail "authorized_keys has entries" "${AUTH_KEYS} is missing or empty — SSH key login will not work"
fi

# Verify SSH service is running (accepts both 'ssh' and 'sshd' unit names)
ssh_active=false
for svc in ssh sshd; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    pass "SSH service active" "unit=${svc}"
    ssh_active=true
    break
  fi
done
if [ "$ssh_active" = false ]; then
  fail "SSH service active" "neither ssh nor sshd service is active"
fi

# ── 7. Container hooks ─────────────────────────────────────────────────────
section "Container Hook Wrapper"

RUNNER_HOOKS_DIR="${RUNNER_HOOKS_DIR:-/opt/runner-hooks}"
WRAPPER="${RUNNER_HOOKS_DIR}/cache-hook-wrapper.js"

if [ -f "$WRAPPER" ]; then
  pass "Cache hook wrapper present" "$WRAPPER"
  if command -v node >/dev/null 2>&1; then
    if node --check "$WRAPPER" >/dev/null 2>&1; then
      pass "Cache hook wrapper syntax valid"
    else
      fail "Cache hook wrapper syntax valid" "node --check reported errors"
    fi
  else
    warn "Node.js not found" "cannot verify wrapper syntax — install Node.js"
  fi
else
  fail "Cache hook wrapper present" "${WRAPPER} not found — run inject-cache-mounts.sh"
fi

if [ -n "$RUNNER_SERVICE" ]; then
  runner_env=$(systemctl show "$RUNNER_SERVICE" -p Environment --value 2>/dev/null || true)
  if echo "$runner_env" | grep -q "ACTIONS_RUNNER_CONTAINER_HOOKS="; then
    pass "Runner service exports ACTIONS_RUNNER_CONTAINER_HOOKS"
  else
    fail "Runner service exports ACTIONS_RUNNER_CONTAINER_HOOKS" "missing from systemd environment"
  fi
fi

REAL_HOOK="${RUNNER_HOOKS_DIR}/node_modules/@actions/runner-container-hooks/packages/docker/dist/index.js"
if [ -f "$REAL_HOOK" ]; then
  pass "Real container hook present" "$REAL_HOOK"
else
  fail "Real container hook present" "${REAL_HOOK} not found — run runner container-hooks setup"
fi

# ── 8. Boot firmware (cgroup cmdline) ─────────────────────────────────────
section "Boot Firmware"

CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ]; then
  pass "Firmware cmdline.txt present" "$CMDLINE"
  cmdline_content=$(cat "$CMDLINE")
  if echo "$cmdline_content" | grep -q "cgroup_memory=1"; then
    pass "cgroup_memory=1 in cmdline.txt"
  else
    fail "cgroup_memory=1 in cmdline.txt" "add 'cgroup_memory=1 cgroup_enable=memory' to ${CMDLINE}"
  fi
  if echo "$cmdline_content" | grep -q "cgroup_enable=memory"; then
    pass "cgroup_enable=memory in cmdline.txt"
  else
    fail "cgroup_enable=memory in cmdline.txt" "container memory limits will not work"
  fi
else
  if [ -f "/boot/cmdline.txt" ]; then
    fail "Firmware cmdline at /boot/firmware/cmdline.txt" "found at /boot/cmdline.txt — wrong path for Pi OS Bookworm (uses /boot/firmware/)"
  else
    fail "Firmware cmdline.txt present" "${CMDLINE} not found"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║   Verification Summary                       ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${RESET}"
echo -e "  ${RED}FAIL: ${FAIL_COUNT}${RESET}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✓ All checks passed. Runner appears correctly configured.${RESET}"
  echo ""
  exit 0
else
  echo -e "${RED}✗ ${FAIL_COUNT} check(s) failed. Review FAIL items above and re-run setup.${RESET}"
  echo ""
  exit 1
fi
