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
