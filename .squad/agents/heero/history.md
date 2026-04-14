# Project Context

- **Project:** PerformanceNode
- **What:** Bash/shell setup scripts for a Raspberry Pi 5 running as a GitHub Actions self-hosted performance runner. Starting from a fresh Raspberry Pi OS Lite (latest, 64-bit, headless/Bookworm) install.
- **Owner:** Fortinbra
- **Team:** Treize (Lead), Heero (Infrastructure Dev), Wufei (Performance Engineer), Noin (Tester/QA)

## Core Context

Heero initialized as Infrastructure Dev on 2026-04-10.

## Learnings

### 2026-04-10: Cache scripts implemented

- Cache scripts live in `scripts/cache/`.  All use `set -euo pipefail` and are idempotent.
- The key architectural insight: NuGet/ccache directories live on the Pi host at `/opt/cache/*` and are bind-mounted into containers by `cache-hook-wrapper.js` intercepting the `prepare_job` container hook call.
- The Pico SDK is cloned once at a pinned git tag (`PICO_SDK_VERSION`) and mounted read-only into containers at `/opt/pico-sdk`.  Workers do not need write access to the SDK tree.
- ccache works across jobs because the host `/opt/cache/ccache` dir is persistent between container runs.  Jobs see it at `/root/.ccache`.
- BaGet (local NuGet mirror) is optional (`--with-local-feed`); it is a BaGetter Docker container with a transparent proxy to nuget.org.
- systemd drop-ins in `/etc/systemd/system/actions-runner.service.d/` are the correct mechanism for injecting env vars into the runner service.  File naming convention: `10-*` for per-feature env, `20-*` for hook routing.
- The `cache-hook-wrapper.js` wrapper rewrites the `prepare_job` JSON in-place before forwarding to the real Docker hook.  Field names to verify against installed package: `userMountVolumes`, `sourceVolumePath`, `targetVolumePath`, `environmentVariables` (under `args.container`).
- apt package version pins are Debian Bookworm values (April 2026); they must be re-verified after dist-upgrades.
- Do NOT install QEMU emulation — per Treize's architecture, fail fast on missing ARM64 images.  All pre-pulled images are `--platform linux/arm64`.

### 2026-04-10: SSH hardening, setup orchestrator, and example workflow implemented

- `scripts/setup/setup-ssh.sh` — SSH hardening script.  Idempotent: skips key import if `authorized_keys` already has entries.  Accepts `--non-interactive` flag and `SSH_PUBLIC_KEY` env var.  Uses `sed -i` to patch only the specific sshd_config lines that need changing; does not rewrite the whole file.  Requires explicit `y/N` confirmation before disabling password auth (bypassed by `--non-interactive`).
- `setup.sh` (repo root) — Single-entry-point orchestrator.  Phases: ssh, system, docker, runner, cache, verify.  Placeholder phases are skipped gracefully if their script does not exist yet.  Supports `--skip=`, `--only=`, `--non-interactive`, and `--help`.  Passes `--non-interactive` through to sub-scripts.  Exits non-zero if any phase fails; prints colour-coded summary.
- `examples/workflows/dotnet-test.yml` — Ready-to-copy GitHub Actions workflow for .NET 10 on this runner.  Uses `container: mcr.microsoft.com/dotnet/sdk:10.0` with ACTIONS_RUNNER_CONTAINER_HOOKS.  NuGet cache provided automatically via host mount at `/root/.nuget/packages`; no `actions/cache` step needed.  Uploads TRX test results as an artifact (always, even on failure).
- `examples/workflows/README.md` — Index of example workflows with cache mount table and runner label notes.
- Path note: the task spec referenced `/opt/runner-cache/nuget` as the NuGet env var path, but the actual cache scripts use `/opt/cache/nuget` (host) → `/root/.nuget/packages` (container) as the canonical path.  The workflow uses `/root/.nuget/packages` (the container-visible path set by the hook wrapper) and documents this clearly.  Open item for Noin: verify the env var path resolves correctly when the hook wrapper and workflow both set `NUGET_PACKAGES`.

### 2026-04-11: OpenOCD SWD MCU flash system implemented

- **Flash method switched from BOOTSEL USB to OpenOCD SWD.** The new `scripts/mcu/flash-mcu.py` uses Python 3 stdlib only (`subprocess`, `tempfile`, `time`, `pathlib`). No external deps, no USB requirement.
- **MCU config is hardcoded in flash-mcu.py** as a dict with MCU names → {swdio, swdclk, reset, target_cfg}. Supports rp2040-h, rp2040-d, rp2350b-d, rp2350a-d (Treize's final topology).
- **GPIO reset control via sysfs** (`/sys/class/gpio/export` and `/sys/class/gpio/gpioN/value`). No gpiozero dependency. Asserts RESET before OpenOCD (LOW), releases after (HIGH).
- **OpenOCD config generated at runtime** in tmpdir. Inline `interface linuxgpiod` + `source [find target/...]` + `program ... verify reset` + `exit 0`. The `linuxgpiod_jtag_nums` format is `{swdclk} 0 0 {swdio}` (TCO, TDO, TDI, TMS pins).
- **Action updated: `.github/actions/mcu-test/action.yml`** — new inputs: `firmware-rp2040-h`, `firmware-rp2040-d`, `firmware-rp2350b-d`, `firmware-rp2350a-d` (individual paths). Removed BOOTSEL pins, removed 4 parallel UARTs. Single UART read from harness MCU (`/dev/ttyAMA2`). Flash step no longer calls `pip install` (openocd from apt, pyserial still needed for UART read).
- **Setup script updated: `scripts/mcu/setup-mcu-deps.sh`** — now installs `openocd`, `libgpiod2`, `gpiod` tools (not gpiozero, RPi.GPIO, pyudev). Requires `gpio` group for `/dev/gpiochip0` access. Removed `plugdev` group (no USB mass-storage). udev rules cleaned: only GPIO and UART device access.
- **Spec updated: `docs/specs/0006-gpio-mcu-flash-test-action.md`** — pin assignments now match Treize's final architecture (17,27,22 for rp2040-h; 23,24,25 for rp2040-d; 5,6,13 for rp2350b-d; 19,26,16 for rp2350a-d). OpenOCD config syntax corrected from `adapter driver` + `adapter gpio` to `interface linuxgpiod` + `linuxgpiod_jtag_nums`. Removed USB/BOOTSEL references.
- **Test it locally**: `python3 scripts/mcu/flash-mcu.py --mcu rp2040-h --firmware firmware.elf` (needs openocd + sysfs GPIO access + /dev/gpiochip0).

### 2026-04-11: Cache path fix + spec 0001 base setup scripts implemented

**Task A — Cache path fix:**
- Migrated all `/opt/cache/` → `/opt/runner-cache/` across every script and README that referenced the old path.
- Files updated: `scripts/cache/setup-nuget-cache.sh`, `setup-pico-sdk-cache.sh`, `setup-docker-image-cache.sh`, `inject-cache-mounts.sh`, `scripts/cache/README.md`.
- Also updated `scripts/performance/cache-metrics/measure-nuget-cache.sh`, `measure-pico-sdk-cache.sh`, and `README.md` (same stale paths, Wufei-domain scripts, but canonical path is Treize's architecture call).
- `setup.sh` had no `/opt/cache/` references — already clean.

**Task B — Spec 0001 setup scripts:**
- `scripts/setup/setup-system.sh` — apt update/upgrade, baseline packages, cgroup v2 cmdline patch (`/boot/firmware/cmdline.txt`), `actions-runner` user creation (nologin, added to docker group if it exists), hostname to `performance-node`. Prints reboot reminder if cmdline was patched.
- `scripts/setup/setup-docker.sh` — Official Docker apt repo (Bookworm ARM64), `daemon.json` (overlay2 + json-file log rotation 10m/3), systemd enable, `actions-runner` docker group assignment, optional hello-world verify (skipped with `--non-interactive`).
- `scripts/setup/setup-runner.sh` — GitHub API latest linux-arm64 release download, extract to `/opt/actions-runner/`, `config.sh --unattended --replace` as `actions-runner` user, `svc.sh install` + systemd enable. Requires `GITHUB_OWNER`, `GITHUB_REPO`, `RUNNER_TOKEN`; prints clear guidance if missing. Idempotent: skips if service already active.
- `setup.sh` phase stubs for system/docker/runner already existed — removed redundant file-exists guards (handled by `run_script` helper) and updated comment strings from "placeholder" to actual script paths.

### 2026-04-13: Validation-state cleanup and service/drop-in reconciliation

- Added `scripts/lib/runner-service.sh` so cache/setup/verify scripts can consistently detect the real runner unit, stage drop-ins before registration, and sync them after `svc.sh install`.
- `scripts/setup/setup-runner.sh` now installs Node.js + `@actions/runner-container-hooks`, refreshes prerequisites even when the runner is already registered, syncs staged drop-ins to the real unit, and creates an `actions-runner` compatibility alias for operator commands.
- Cache scripts now write dynamic runner drop-ins through the shared helper and use `chmod 1777` for writable cache dirs (`nuget`, `ccache`) to match the container UID-mismatch design.
- `setup.sh` now points its verify phase at `scripts/verify/verify-setup.sh`; `setup-ssh.sh` targets the intended SSH user home instead of blindly using root's `$HOME`, and restarts `ssh` with `sshd` fallback.
- Docs/examples/spec text were reconciled with current paths (`/opt/runner-cache`), current runner labels (`self-hosted,linux,arm64,performancenode`), and current MCU action inputs.
- Validation run used `git diff --check` on touched files, `bash -n` for shell scripts, `python -m py_compile` for MCU Python scripts, and `npx js-yaml` for the modified workflow/action YAML.
