# Known Limitations — PerformanceNode QA

**Owner:** Noin (Tester/QA)  
**Last updated:** 2026-04-13

---

## Scope Of This QA Pass

This refresh was performed against the **current working tree**, not the older rate-limited snapshot.

Validation in this pass included:

- source review of setup/cache/verify/performance/MCU artifacts
- syntax validation for shell and Python scripts
- QA artifact refresh

Validation that was **not** possible in this pass:

- running the setup on a real Raspberry Pi 5
- registering a live GitHub Actions runner
- dispatching a workflow to prove container hooks, cache mounts, or MCU access end-to-end

---

## Active Limitations And Follow-Ups

### 1. No live Pi execution yet

This repo still lacks a completed hardware-backed validation cycle on a fresh Pi OS Bookworm image. Static review is enough to identify blockers, but not enough to prove idempotency, service behavior, or real workflow execution.

**Impact:** Acceptance remains provisional until a real Pi run is completed.

---

### 2. Cache drop-ins are still service-name fragile

The QA verifier now auto-detects the actual runner service name, but the cache setup scripts still write drop-ins to the fixed path:

`/etc/systemd/system/actions-runner.service.d`

That does not match the service naming pattern installed by `svc.sh install`.

**Impact:** Fresh installs may appear successful while the real runner service never receives cache or hook environment variables.

---

### 3. Container hooks package installation is still missing

`inject-cache-mounts.sh` assumes both Node.js and the `@actions/runner-container-hooks` package already exist under `/opt/runner-hooks`, but no committed setup script currently provisions them.

**Impact:** The project's enforced-container-isolation story is incomplete until that prerequisite is implemented and validated.

---

### 4. SSH hardening still depends on service-name compatibility

`setup-ssh.sh` still restarts `sshd` only. On Pi OS Bookworm, the expected service is generally `ssh`.

**Impact:** SSH hardening may not take effect immediately after script completion.

---

### 5. Cache permission model is not yet validated against non-root containers

The team decision calls for sticky-bit world-writable cache dirs (`1777`) for NuGet and ccache. Current scripts still set `755`.

**Impact:** Root-based containers may appear fine, while non-root job containers can miss cache writes or fail unexpectedly.

---

### 6. Benchmarks still have environment-sensitivity gaps

- `measure-pico-sdk-cache.sh` defaults to `/opt/pico-sdk` instead of `/opt/runner-cache/pico-sdk`
- benchmark scripts use scratch space under `/tmp`

**Impact:** Manual benchmark runs can report misleading results unless the operator exports the expected environment first.

---

### 7. Documentation/examples still contain stale cache-path references

The example workflow docs still reference `/opt/cache/*` in comments and README text.

**Impact:** Users copying examples may configure or reason about the wrong host paths even though the scripts have already migrated to `/opt/runner-cache`.

---

## Resolved In This Pass

These are no longer active limitations:

- old `/opt/cache` script defaults in the main cache scripts
- missing cgroup cmdline patch in committed setup scripts
- missing QA verifier artifact
- CRLF shell-script compatibility risk in the checked files covered by the new LF policy

---

## Next QA Gate

The next meaningful QA gate is:

1. fix the runner service/drop-in mismatch
2. add committed Node.js + container-hooks provisioning
3. rerun `setup.sh` on a fresh Pi twice
4. run `scripts/verify/verify-setup.sh`
5. dispatch at least one containerized sample workflow

Until then, the repo is **reviewable** but not yet **ready for clean validation sign-off**.
