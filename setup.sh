#!/usr/bin/env bash
# setup.sh — PerformanceNode single-entry-point setup orchestrator.
#
# Runs all setup phases in order on a freshly imaged Raspberry Pi 5.
# Each phase maps to a script (or group of scripts) under scripts/.
# Missing scripts are skipped with a warning — safe to re-run as phases
# are added incrementally.
#
# Usage:
#   ./setup.sh [OPTIONS]
#
# Options:
#   --help                Print this message and exit.
#   --skip=<phase>        Skip a named phase (repeatable).
#   --only=<phase>        Run only the named phase (exclusive with --skip).
#   --non-interactive     Pass through to sub-scripts; disable all prompts.
#
# Phases (in order):
#   ssh       SSH hardening (scripts/setup/setup-ssh.sh)
#   system    System configuration (scripts/setup/setup-system.sh)
#   docker    Docker setup (scripts/setup/setup-docker.sh)
#   runner    GitHub Actions runner install (scripts/setup/setup-runner.sh)
#   cache     Cache scripts (scripts/cache/setup-*.sh + inject-cache-mounts.sh)
#   mcu-deps  MCU flashing dependencies (scripts/mcu/setup-mcu-deps.sh)
#   verify    Post-setup verification (scripts/verify/verify-setup.sh)
#
# Run with --help for options.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colours ───────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  CLR_RESET='\033[0m'
  CLR_CYAN='\033[0;36m'
  CLR_GREEN='\033[0;32m'
  CLR_YELLOW='\033[1;33m'
  CLR_RED='\033[0;31m'
else
  CLR_RESET=''; CLR_CYAN=''; CLR_GREEN=''; CLR_YELLOW=''; CLR_RED=''
fi

# ── Argument parsing ───────────────────────────────────────────────────────
SKIP_PHASES=()
ONLY_PHASE=""
NON_INTERACTIVE=false

usage() {
  cat <<EOF
PerformanceNode — Pi 5 Runner Setup
Run with --help for options.

Usage: ./setup.sh [OPTIONS]

Options:
  --help                Print this message and exit.
  --skip=<phase>        Skip a named phase (repeatable).
  --only=<phase>        Run only the named phase.
  --non-interactive     Pass through to sub-scripts; disable all prompts.

Phases (in order):
  ssh       SSH hardening (scripts/setup/setup-ssh.sh)
  system    System configuration (scripts/setup/setup-system.sh)
  docker    Docker setup (scripts/setup/setup-docker.sh)
  runner    GitHub Actions runner install (scripts/setup/setup-runner.sh)
  cache     Cache scripts (scripts/cache/)
  mcu-deps  MCU flashing dependencies (scripts/mcu/setup-mcu-deps.sh)
  verify    Post-setup verification (scripts/verify/verify-setup.sh)

Examples:
  ./setup.sh                          # Full setup
  ./setup.sh --only=cache             # Run cache phase only
  ./setup.sh --skip=ssh --skip=docker # Skip SSH and Docker phases
  ./setup.sh --non-interactive        # Unattended / CI use
EOF
}

for arg in "$@"; do
  case "$arg" in
    --help)                usage; exit 0 ;;
    --non-interactive)     NON_INTERACTIVE=true ;;
    --only=*)              ONLY_PHASE="${arg#--only=}" ;;
    --skip=*)              SKIP_PHASES+=("${arg#--skip=}") ;;
    *) echo "ERROR: Unknown argument: $arg" >&2; echo "Run ./setup.sh --help for usage." >&2; exit 1 ;;
  esac
done

# Build pass-through args for sub-scripts.
PASSTHROUGH_ARGS=()
[ "$NON_INTERACTIVE" = true ] && PASSTHROUGH_ARGS+=("--non-interactive")

# ── Banner ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CLR_CYAN}╔══════════════════════════════════════════════╗${CLR_RESET}"
echo -e "${CLR_CYAN}║   PerformanceNode — Pi 5 Runner Setup        ║${CLR_RESET}"
echo -e "${CLR_CYAN}╚══════════════════════════════════════════════╝${CLR_RESET}"
echo "  Run with --help for options."
echo ""

# ── Root warning ───────────────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
  echo -e "${CLR_YELLOW}⚠  Running as root. Some sub-scripts require root; this is expected.${CLR_RESET}"
  echo -e "${CLR_YELLOW}   If you did not intend to run as root, re-run as a non-root user.${CLR_RESET}"
  echo ""
fi

# ── Phase tracking ─────────────────────────────────────────────────────────
declare -A PHASE_STATUS   # passed | skipped | failed

# Helper: check if a phase should run.
should_run_phase() {
  local phase="$1"
  # --only takes priority.
  if [ -n "$ONLY_PHASE" ]; then
    [ "$phase" = "$ONLY_PHASE" ] && return 0 || return 1
  fi
  # Check skip list.
  for skip in "${SKIP_PHASES[@]+"${SKIP_PHASES[@]}"}"; do
    [ "$skip" = "$phase" ] && return 1
  done
  return 0
}

# Helper: run a single script for a phase.
# Usage: run_script <phase> <script_path> [extra args...]
run_script() {
  local phase="$1"
  local script="$2"
  shift 2

  if [ ! -f "$script" ]; then
    echo -e "  ${CLR_YELLOW}⚠  $(basename "$script") not found — skipping${CLR_RESET}"
    return 0   # not a failure; placeholder phase
  fi

  bash "$script" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}" "$@"
}

# Main phase runner.
run_phase() {
  local phase="$1"
  shift   # remaining args are phase-specific scripts / callables

  if ! should_run_phase "$phase"; then
    echo -e "${CLR_YELLOW}[ Phase: ${phase} ]${CLR_RESET} (skipped by --skip/--only)"
    PHASE_STATUS["$phase"]="skipped"
    return 0
  fi

  echo -e "${CLR_CYAN}[ Phase: ${phase} ]${CLR_RESET}"

  # The caller passes a function name or an inline block via "$@".
  if "$@"; then
    echo -e "${CLR_GREEN}✓ ${phase} complete${CLR_RESET}"
    PHASE_STATUS["$phase"]="passed"
  else
    echo -e "${CLR_RED}✗ ${phase} FAILED${CLR_RESET}"
    PHASE_STATUS["$phase"]="failed"
    # Return non-zero so the caller can track overall failure.
    return 1
  fi
}

# ── Overall result tracker ─────────────────────────────────────────────────
OVERALL_EXIT=0

safe_run_phase() {
  local phase="$1"
  shift
  run_phase "$phase" "$@" || OVERALL_EXIT=1
  echo ""
}

# ── Phase implementations ──────────────────────────────────────────────────

phase_ssh() {
  run_script "ssh" "${REPO_ROOT}/scripts/setup/setup-ssh.sh"
}

phase_system() {
  run_script "system" "${REPO_ROOT}/scripts/setup/setup-system.sh"
}

phase_docker() {
  run_script "docker" "${REPO_ROOT}/scripts/setup/setup-docker.sh"
}

phase_runner() {
  run_script "runner" "${REPO_ROOT}/scripts/setup/setup-runner.sh"
}

phase_cache() {
  local any_run=false
  local cache_dir="${REPO_ROOT}/scripts/cache"
  local failed=false

  for script in \
    "${cache_dir}/setup-nuget-cache.sh" \
    "${cache_dir}/setup-pico-sdk-cache.sh" \
    "${cache_dir}/setup-docker-image-cache.sh" \
    "${cache_dir}/inject-cache-mounts.sh"
  do
    if [ -f "$script" ]; then
      any_run=true
      echo "  Running $(basename "$script")..."
      bash "$script" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}" || { failed=true; echo -e "  ${CLR_RED}✗ $(basename "$script") failed${CLR_RESET}"; }
    else
      echo -e "  ${CLR_YELLOW}⚠  $(basename "$script") not found — skipping${CLR_RESET}"
    fi
  done

  if [ "$any_run" = false ]; then
    echo -e "  ${CLR_YELLOW}⚠  cache${CLR_RESET} skipped (no scripts found)"
    PHASE_STATUS["cache"]="skipped"
    return 0
  fi

  [ "$failed" = false ]
}

phase_verify() {
  local script="${REPO_ROOT}/scripts/verify/verify-setup.sh"
  if [ ! -f "$script" ]; then
    echo -e "  ${CLR_YELLOW}⚠  verify${CLR_RESET} skipped (not found)"
    PHASE_STATUS["verify"]="skipped"
    return 0
  fi
  run_script "verify" "$script"
}

phase_mcu_deps() {
  local script="${REPO_ROOT}/scripts/mcu/setup-mcu-deps.sh"
  if [ ! -f "$script" ]; then
    echo -e "  ${CLR_YELLOW}⚠  mcu-deps${CLR_RESET} skipped (not found)"
    PHASE_STATUS["mcu-deps"]="skipped"
    return 0
  fi
  run_script "mcu-deps" "$script"
}

# ── Run phases ─────────────────────────────────────────────────────────────
safe_run_phase "ssh"      phase_ssh
safe_run_phase "system"  phase_system
safe_run_phase "docker"  phase_docker
safe_run_phase "runner"  phase_runner
safe_run_phase "cache"   phase_cache
safe_run_phase "mcu-deps" phase_mcu_deps
safe_run_phase "verify"  phase_verify

# ── Summary ────────────────────────────────────────────────────────────────
echo -e "${CLR_CYAN}╔══════════════════════════════════════════════╗${CLR_RESET}"
echo -e "${CLR_CYAN}║   Setup Summary                              ║${CLR_RESET}"
echo -e "${CLR_CYAN}╚══════════════════════════════════════════════╝${CLR_RESET}"

for phase in ssh system docker runner cache mcu-deps verify; do
  status="${PHASE_STATUS[$phase]:-skipped}"
  case "$status" in
    passed)  echo -e "  ${CLR_GREEN}✓ ${phase}${CLR_RESET}" ;;
    skipped) echo -e "  ${CLR_YELLOW}⚠ ${phase} (skipped)${CLR_RESET}" ;;
    failed)  echo -e "  ${CLR_RED}✗ ${phase} FAILED${CLR_RESET}" ;;
  esac
done

echo ""
if [ "$OVERALL_EXIT" -eq 0 ]; then
  echo -e "${CLR_GREEN}All phases completed successfully.${CLR_RESET}"
else
  echo -e "${CLR_RED}One or more phases failed. Review output above.${CLR_RESET}"
fi
echo ""

exit "$OVERALL_EXIT"
