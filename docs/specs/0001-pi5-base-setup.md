# Spec: Pi 5 Base OS Setup

| Field            | Value                                      |
|------------------|--------------------------------------------|
| **Issue**        | TBD (retroactive — create GitHub issue)    |
| **Author**       | Treize                                     |
| **Status**       | 🚧 In Progress                             |
| **Created**      | 2026-04-10                                 |
| **Last Updated** | 2026-04-10                                 |

---

## Overview

Take a stock Raspberry Pi OS Lite (64-bit, Bookworm, headless) installation and configure it as a GitHub Actions self-hosted runner with full container isolation. The entire setup is driven by idempotent bash scripts that can be re-run safely on an already-configured system.

## Problem Statement

A fresh Raspberry Pi OS Lite install cannot run GitHub Actions jobs. It lacks Docker, the runner agent, container hooks, correct user accounts, cgroup configuration, and the systemd service unit needed to start the runner on boot. Manual setup is error-prone, undocumented, and not repeatable. If the SD card fails or a second Pi is added, the entire process must be reconstructed from memory.

## Proposed Solution

A set of idempotent bash scripts, executed in sequence (or via a top-level orchestrator script), that take the Pi from stock OS to a fully functional, boot-ready GitHub Actions runner. Each script is independently re-runnable and checks existing state before making changes.

Key components:
- **System packages and updates** — apt update/upgrade, install baseline tools.
- **User account** — create a dedicated `actions-runner` user (non-root), add to `docker` group.
- **Docker Engine** — install from the official Docker apt repository (ARM64, Bookworm), configure daemon with overlay2, log rotation, and appropriate defaults.
- **cgroup v2 configuration** — patch `/boot/firmware/cmdline.txt` with `cgroup_memory=1 cgroup_enable=memory` for container memory limits.
- **GitHub Actions Runner** — download and configure the runner agent under the `actions-runner` user.
- **Container Hooks** — install Node.js (LTS, ARM64) and `@actions/runner-container-hooks` so all jobs execute inside disposable Docker containers (per the container execution architecture decision).
- **systemd service** — create and enable a service unit that starts the runner on boot, sets `ACTIONS_RUNNER_CONTAINER_HOOKS` and `DOCKER_HOST` env vars, runs as `actions-runner`, restarts on failure.
- **Security hardening** — disable password SSH (key-only), firewall basics, no QEMU emulation installed (fail fast on amd64-only images).

## Acceptance Criteria

- [ ] Running the setup scripts on a fresh Pi OS Lite (64-bit, Bookworm) image produces a working GitHub Actions runner with zero manual intervention
- [ ] Running the setup scripts a second time completes without errors and without changing already-correct state (idempotent)
- [ ] `actions-runner` user exists, is non-root, and is a member of the `docker` group
- [ ] Docker Engine (24.x+) is installed, running, and configured with overlay2 storage driver and JSON-file log rotation (max-size: 10m, max-file: 3)
- [ ] `/boot/firmware/cmdline.txt` contains `cgroup_memory=1 cgroup_enable=memory`
- [ ] Node.js (LTS, ARM64) is installed and `@actions/runner-container-hooks` is available at the configured path
- [ ] The `ACTIONS_RUNNER_CONTAINER_HOOKS` environment variable is set in the runner's systemd service unit, pointing to the correct hook entrypoint
- [ ] The runner systemd service is enabled and starts on boot (`systemctl is-enabled actions-runner` returns `enabled`)
- [ ] The runner systemd service starts successfully and connects to GitHub (`systemctl is-active actions-runner` returns `active`)
- [ ] A test workflow dispatched from GitHub executes its steps inside a Docker container (not on the host) and completes successfully
- [ ] QEMU/binfmt_misc is NOT installed — an amd64-only container image fails fast rather than emulating
- [ ] All scripts use `set -euo pipefail` and produce clear log output indicating what was done or skipped

## Out of Scope

- Dependency caching setup (NuGet, Pico SDK, ccache) — covered by spec 0002
- Performance benchmarking and metrics collection — separate spec (Wufei's domain)
- Custom Docker images for specific build environments (e.g., `pico-builder`)
- Workflow authoring — this spec covers the runner, not the workflows that run on it
- Multi-Pi fleet management or auto-scaling
- Wi-Fi/Bluetooth configuration (headless, wired Ethernet assumed)

## Dependencies

- None — this is the foundational spec. All other specs depend on this one.

## Agent Assignment

| Agent  | Role in this spec                                                       |
|--------|-------------------------------------------------------------------------|
| Heero  | Primary implementer — writes all setup scripts                          |
| Noin   | Validates idempotency, tests on a fresh image, verifies acceptance criteria |
| Treize | Architecture review, systemd/hooks design decisions                     |

## Notes

- The container execution architecture decision (2026-04-10) is the authoritative reference for Docker and container hooks configuration. See `.squad/decisions/inbox/treize-container-execution-arch.md`.
- Pi OS Bookworm ships Linux 6.1.x with native cgroups v2 support. No custom kernel needed.
- The runner user is named `actions-runner` (not `runner`) to avoid collision with any system accounts and to be self-documenting.
- Scripts target `/opt/actions-runner/` as the runner install directory and `/opt/runner-hooks/` for hook scripts.
- 2026-04-10: Retroactive spec created as part of the spec-driven process adoption. Work was already in progress prior to this spec.
