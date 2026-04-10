# Spec: Single Entry Point Orchestrator

| Field            | Value                                      |
|------------------|--------------------------------------------|
| **Issue**        | TBD (create GitHub issue)                  |
| **Author**       | Treize                                     |
| **Status**       | 📝 Draft                                   |
| **Created**      | 2026-04-10                                 |
| **Last Updated** | 2026-04-10                                 |

---

## Overview

A single `setup.sh` script at the repository root that orchestrates the entire Pi setup from a fresh Raspberry Pi OS Lite installation to a fully configured and boot-ready GitHub Actions runner. The script runs all setup phases in the correct order, is idempotent, and provides clear feedback on completion status.

## Problem Statement

Setup is currently fragmented across multiple scripts in different directories (`scripts/install-docker.sh`, `scripts/install-runner.sh`, etc.). A fresh Pi owner must:
- Understand the correct order of execution
- Manually locate and run each script in sequence
- Figure out which scripts have already been run if the process fails partway through
- Remember dependencies between scripts (e.g., Docker must be installed before cgroups can be validated)

This is error-prone, undocumented, and discourages users from attempting a fresh setup. A single, idempotent entry point removes friction.

## Proposed Solution

A top-level `setup.sh` script that:

1. **Defines phases in order** — SSH hardening → Docker → cgroups/boot config → GitHub Actions runner → cache setup → smoke test
2. **Runs phases sequentially** — each phase is a function or sub-script call
3. **Detects completion** — each phase checks whether it has already been applied and skips if complete (idempotent)
4. **Reports status clearly** — prints "[SKIP]", "[PASS]", or "[FAIL]" for each phase with a brief description
5. **Allows phase skipping** — accepts a `--skip-phase=<name>` flag to skip a specific phase (useful if a user wants to re-run only failed phases)
6. **Prints usage** — responds to `--help` with clear documentation of flags and phases
7. **Exits with meaningful code** — returns 0 if all phases pass or are skipped, non-zero if any phase fails
8. **Logs to a file** — writes detailed output to `/var/log/performancenode-setup.log` for debugging

### Phase Order

1. **ssh-keys** — Configure SSH key-based authentication (spec 0003)
2. **docker** — Install and configure Docker Engine (spec 0001)
3. **cgroups** — Patch `/boot/firmware/cmdline.txt` for cgroup memory limits (spec 0001)
4. **runner** — Install and configure the GitHub Actions runner (spec 0001)
5. **caches** — Set up dependency cache directories (spec 0002)
6. **smoke-test** — Run a quick validation to confirm the runner is working

## Acceptance Criteria

- [ ] Running `./setup.sh` on a fresh Raspberry Pi OS Lite (64-bit, Bookworm) installation completes without error and produces a working GitHub Actions runner
- [ ] Running `./setup.sh` a second time on an already-configured Pi completes without errors, skips phases that are already complete, and produces no unwanted changes
- [ ] Running `./setup.sh --help` prints usage documentation including available phases and flag options
- [ ] Each phase reports its status as `[SKIP]`, `[PASS]`, or `[FAIL]` in the output, with a brief human-readable description
- [ ] Running `./setup.sh --skip-phase=docker` skips the Docker installation phase but completes all other phases
- [ ] The script exits with code 0 if all run phases pass or are skipped
- [ ] The script exits with a non-zero code if any phase fails
- [ ] Detailed log output is written to `/var/log/performancenode-setup.log` with timestamps
- [ ] The script uses `set -euo pipefail` and produces clear, timestamped output during execution
- [ ] Running the script twice with the same configuration produces identical final state (idempotent verification)

## Out of Scope

- Uninstall or teardown — `setup.sh` configures the Pi; removal of components is not covered
- Multi-Pi orchestration or fleet management (Ansible, parallel deployment, etc.)
- Custom Docker image building — the script installs pre-built images or pulls from registries
- Workflow authoring or GitHub repository setup — this spec covers the runner, not the workflows that use it
- Configuration changes after initial setup (e.g., runner restart, runner re-authentication with a new token) — these are maintenance tasks, not setup

## Dependencies

- Spec 0001 (Pi 5 Base OS Setup) — defines the individual setup scripts and commands this orchestrator calls
- Spec 0002 (Dependency Caching) — defines the cache setup phase
- Spec 0003 (SSH Key Setup) — defines the SSH hardening phase

## Agent Assignment

| Agent  | Role in this spec                                                                |
|--------|----------------------------------------------------------------------------------|
| Heero  | Primary implementer — writes `setup.sh`, integrates existing setup scripts       |
| Noin   | Tests on a fresh image, verifies idempotency, validates phase skipping behavior  |
| Treize | Architecture review, final sign-off                                             |

## Notes

- ⚠️ GitHub issue required — create issue and update this spec with the issue number before merging.
- The script should be at the repository root (`./setup.sh`) so it's the first thing a user encounters when cloning the repo.
- Each phase should be implemented as a bash function or a call to a separate script (e.g., `scripts/phases/01-ssh-keys.sh`). This keeps the orchestrator clean and allows phases to be tested or debugged independently.
- The smoke test phase (phase 6) should verify that the runner can connect to GitHub and receive jobs. This could be a simple `curl` to the runner's status endpoint or a dispatched test workflow.
- Consider using environment variables (`PI_SETUP_SKIP_PHASE`, etc.) as an alternative or complement to CLI flags, for CI/CD automation.
- The script should be idempotent by design — each phase must check its own state and skip if complete. Do not rely on deletion/recreation.
- Future enhancement: add a `--dry-run` flag that prints what would happen without making changes.
