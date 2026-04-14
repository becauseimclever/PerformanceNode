# QA Script Review — PerformanceNode

**Reviewer:** Noin (Tester/QA)  
**Review date:** 2026-04-13  
**Method:** Static review of the current tree plus host-side syntax validation (`bash -n` for shell, Python compile checks for `scripts/mcu/*.py`). No live Pi hardware or GitHub runner job was exercised in this pass.

---

## Verdict

**Not validation-ready yet.**

The smallest blocking set is:

1. **Cache drop-ins target the wrong systemd service name.**
2. **No committed script installs Node.js + `@actions/runner-container-hooks`, so container isolation cannot be validated end-to-end.**

Until those two are fixed, cache injection and enforced containerized job execution cannot be trusted on a fresh Pi.

---

## Closed Since The Prior QA Snapshot

These older findings are now stale and should not be carried forward as active defects:

| Item | Status | Evidence |
|---|---|---|
| Cache path migration (`/opt/cache` → `/opt/runner-cache`) | **Closed** | Cache setup scripts and hook wrapper now default to `/opt/runner-cache/*`. |
| Hook wrapper hardcoded old cache paths | **Closed** | `scripts/cache/inject-cache-mounts.sh` now injects `/opt/runner-cache/nuget`, `/opt/runner-cache/pico-sdk`, and `/opt/runner-cache/ccache`. |
| cgroup cmdline patch missing from committed scripts | **Closed** | `scripts/setup/setup-system.sh` now patches `/boot/firmware/cmdline.txt`. |
| Post-setup verification script missing | **Closed** | `scripts/verify/verify-setup.sh` exists and has been refreshed in this pass. |
| Linux shell compatibility blocked by CRLF line endings | **Closed by QA compatibility fix** | Repo now has `.gitattributes` LF rules for shell/Python/YAML/Markdown, and relevant files were normalized to LF. |

---

## Current Blocking Issues

| ID | Severity | Area | Finding | Why it blocks validation |
|---|---|---|---|---|
| B-1 | **CRITICAL** | Cache + hooks | `setup-nuget-cache.sh`, `setup-pico-sdk-cache.sh`, and `inject-cache-mounts.sh` all write drop-ins to `/etc/systemd/system/actions-runner.service.d`, but `setup-runner.sh` installs a dynamic service named `actions.runner.*.service`. | The runner will not receive cache env vars or hook env vars on a real install, so cache mounts and container hooks cannot be validated reliably. |
| B-2 | **CRITICAL** | Runner container isolation | No committed setup script installs Node.js and `@actions/runner-container-hooks` at the path expected by `inject-cache-mounts.sh` (`/opt/runner-hooks/node_modules/@actions/runner-container-hooks/...`). | The project requirement is "all jobs run in disposable containers." Without the actual hooks package present, that core acceptance path is incomplete. |
| B-3 | **HIGH** | SSH hardening | `scripts/setup/setup-ssh.sh` still restarts `sshd` only. | On Raspberry Pi OS Bookworm the service is typically `ssh`; hardening may be written but not applied until reboot/manual restart. |
| B-4 | **HIGH** | Cache correctness | `scripts/cache/setup-nuget-cache.sh` and `scripts/cache/setup-pico-sdk-cache.sh` still set NuGet/ccache dirs to mode `755`, not `1777`. | Non-root container users can miss or fail cache writes, making warm-cache validation unreliable. |

---

## Still-Open Non-Blocking Issues

| ID | Severity | Finding | Notes |
|---|---|---|---|
| N-1 | MEDIUM | `scripts/performance/cache-metrics/measure-pico-sdk-cache.sh` defaults `PICO_SDK_PATH=/opt/pico-sdk` instead of `/opt/runner-cache/pico-sdk`. | Benchmark can report misleading zeroed results outside the runner service environment. |
| N-2 | MEDIUM | `setup.sh` verify phase still points to `scripts/verify/smoke-test.sh`, which does not exist. | Post-setup verification exists as `scripts/verify/verify-setup.sh`, but the orchestrator does not call it yet. |
| N-3 | MEDIUM | Example workflow docs still mention legacy `/opt/cache/*` paths. | Documentation drift; does not block the core setup scripts but will mislead users. |
| N-4 | LOW | Example workflow still lacks an explicit `timeout-minutes`. | Usability/safety issue, not a setup correctness blocker by itself. |

---

## Verification Notes

### Syntax checks run in this pass

- `bash -n setup.sh scripts/setup/*.sh scripts/cache/*.sh scripts/performance/cache-metrics/*.sh scripts/verify/*.sh scripts/mcu/setup-mcu-deps.sh` ✅
- Python compile checks for `scripts/mcu/*.py` ✅

### Important reviewer note

`scripts/verify/verify-setup.sh` was updated in this pass to:

- detect the actual runner service name instead of assuming `actions-runner`
- verify the service-specific drop-in directory
- require `/opt/runner-cache`
- fail on incorrect NuGet/ccache permissions (`1777` expected)
- check that `ACTIONS_RUNNER_CONTAINER_HOOKS` is actually exported by the runner service

That makes the QA verifier stricter than the current production scripts in the exact places that still need Heero fixes.

---

## Readiness Summary

**Current tree status:** close, but **not ready** for a clean validation run.

If Heero fixes only:

1. the runner service/drop-in name mismatch, and
2. the missing Node.js/container-hooks installation path,

then QA can do a meaningful end-to-end validation pass. The SSH service-name fix and cache permission fix should be folded in at the same time, but the first two items are the hard stop.
