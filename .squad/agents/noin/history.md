# Project Context

- **Project:** PerformanceNode
- **What:** Bash/shell setup scripts for a Raspberry Pi 5 running as a GitHub Actions self-hosted performance runner. Starting from a fresh Raspberry Pi OS Lite (latest, 64-bit, headless/Bookworm) install.
- **Owner:** Fortinbra
- **Team:** Treize (Lead), Heero (Infrastructure Dev), Wufei (Performance Engineer), Noin (Tester/QA)

## Core Context

Noin initialized as Tester/QA on 2026-04-10.

## Learnings

_Appended during sessions._

### 2026-04-14: Stage 1 inventory/bootstrap QA

**Scope:** Reviewed Stage 1 against `docs/specs/2-inventory-bootstrap.md` and validated from Ubuntu WSL.

**Key outcomes:**
- Ubuntu WSL validation is the correct path; on `/mnt/c/...` Ansible ignores repo-local `ansible.cfg` unless `ANSIBLE_CONFIG=$PWD/ansible.cfg` is set explicitly.
- `inventories/production/hosts.yml` currently declares only the `pi5-runner` alias and does not set `ansible_host`/`ansible_user`, so Ansible tries to SSH to the literal hostname `pi5-runner` instead of `192.168.27.222`.
- The committed Pi details in `host_vars/pi5-runner.yml` match the spec (`PiTester`, `192.168.27.222`, `fortinbra`), but those values are not wired into the actual inventory host entry.
- Result: Stage 1 is not complete yet because the required `ansible-playbook ... playbooks/ping.yml` acceptance check still fails with hostname resolution/unreachable output.

### 2026-04-13: QA refresh against current tree

**Scope:** Refreshed QA artifacts against the live working tree after earlier rate-limit interruption.

**Key outcomes:**
- Older `/opt/cache` findings were stale; current cache scripts now target `/opt/runner-cache`.
- The real blocking issue is now **runner service-name mismatch**: cache scripts write drop-ins under `actions-runner.service.d`, while `setup-runner.sh` installs a dynamic `actions.runner.*.service`.
- Container-isolation validation is still blocked because no committed setup script provisions Node.js + `@actions/runner-container-hooks` at the path expected by `inject-cache-mounts.sh`.
- Added LF enforcement via `.gitattributes` after CRLF endings broke shell parsing during QA validation.

### 2026-04-10: QA & Validation Charter

**Role:** Noin is the acceptance gatekeeper — no spec closes until acceptance criteria are verified and signed off.

**Validation approach for specs 0001 & 0002:**
- **Idempotency:** Run all setup scripts twice in sequence; second run should produce no changes (exit 0, no file modifications)
- **Permission enforcement:** Verify file ownership and mode on all cache directories (actions-runner:actions-runner for nuget/ccache, root:root for pico-sdk)
- **Cache effectiveness:** Compare timing of cold build (empty cache) vs. warm build (populated cache) for both NuGet and Pico SDK
- **Edge cases:** What happens if scripts run multiple times? If cache dirs already exist? If permissions are wrong?

**Key pattern:** Idempotency is a security and reliability feature. Scripts must detect existing state and skip redundant work. No file should be touched twice.

**Cross-agent context:**
- **From Heero:** Cache scripts are idempotent with `set -euo pipefail`; Noin validates this on real Pi hardware
- **From Wufei:** Cache-metrics benchmarks provide baseline numbers for cold vs. warm comparison
- **From Treize:** Specs 0001 and 0002 have 8–10 testable acceptance criteria each; Noin verifies all before signing off

### 2026-04-14: Stage 2 common-role QA baseline

**Scope:** Checked `docs/specs/3-common-role.md` against the current repo state and re-validated the Ansible control path from Ubuntu WSL.

**Key outcomes:**
- Stage 1 is now verifiable from WSL with `ANSIBLE_CONFIG=$(pwd)/ansible.cfg`; `ansible-playbook -i inventories/production playbooks/ping.yml` succeeds against `PiTester (192.168.27.222)` as `fortinbra`.
- Stage 2 implementation is not present yet: there is no `roles/common/` tree and no `playbooks/pi-runner.yml`, so none of the Stage 2 acceptance criteria can be executed.
- Readiness checklist for Heero's handoff: `roles/common/tasks/{main,ssh,packages,locale,users}.yml`, `roles/common/handlers/main.yml`, `roles/common/defaults/main.yml`, optional `roles/common/templates/sshd_config.j2`, a playbook entry point that can run `--tags common`, and tags/idempotent tasks for SSH hardening, packages, locale/timezone, runner user creation, and passwordless sudo.
- Stage 2 cannot be considered complete until the role exists and WSL validation proves: SSH password auth disabled, root login disabled, packages installed from defaults, timezone set, `actions-runner` in `sudo`, and a second `--tags common` run reports `changed=0`.
