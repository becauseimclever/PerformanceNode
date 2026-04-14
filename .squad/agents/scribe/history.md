# Project Context

- **Project:** PerformanceNode
- **Created:** 2026-04-10

## Core Context

Agent Scribe initialized and ready for work.

## Recent Updates

📌 Team initialized on 2026-04-10

## Learnings

### 2026-04-10: Session Logging & Decision Archival

**Session:** 2026-04-10-caching-and-spec-workflow

**Deliverables:**
- Orchestration logs for all 5 agents (Wufei, Treize, Heero, Noin, Scribe) written to `.squad/orchestration-log/`
- Comprehensive session log written to `.squad/log/2026-04-10-caching-and-spec-workflow.md` (agent contributions, decisions, open items)
- Decision records merged from `.squad/decisions/inbox/` into `.squad/decisions.md` (9 files total)
- Inbox files deleted after merge
- Cross-agent history files updated (.squad/agents/*/history.md)

**Pattern learned:** Scribe is silent; all outputs are documentation artifacts. Session logs are YAML-like markdown for quick scanning by team members. Orchestration logs are per-agent narrative of work completed in that session.

**Governance enforcement:**
- Spec-driven process: all features require `docs/specs/{issue}-{slug}.md` + GitHub issue before work begins
- Decision merging: consolidate inbox into canonical `.squad/decisions.md` for single source of truth
- Cross-team memory: agent history files are read by other agents to understand dependencies and learnings

**Git workflow:**
- Stage `.squad/` changes (logs, decisions, orchestration records)
- Stage `docs/` (specs, strategy docs)
- Stage `scripts/` (setup scripts, benchmarks)
- Commit with message: "feat: caching strategy, cache scripts, metrics, spec-driven process"
- Include Copilot co-author trailer (per charter)

### 2026-04-14: Stage 1 & 2 Inventory/Bootstrap and Common Role Completion

**Session:** Stages 1–2 implementation and validation

**Deliverables committed:**
- **Stage 1:** `ansible.cfg`, `inventories/production/hosts.yml`, `playbooks/ping.yml` — Ansible connectivity to PiTester
- **Stage 2:** `roles/common/{tasks,handlers,defaults}` — SSH hardening, packages, locale, runner user, passwordless sudo
- **Playbook structure:** `playbooks/site.yml` (main entry), `playbooks/pi-runner.yml` (Pi-specific)
- **Spec renumbering:** 0007–0009 → 2–4 (inventory-bootstrap, common-role, docker-role)
- **Architecture docs updated:** ansible-reboot-proposal, staged-rollout with WSL control node warning
- **Agent histories updated:** Treize, Heero, Noin with per-session learnings

**Key team learnings documented:**
- Heero: WSL validation uncovered `ansible.cfg` path gotcha on `/mnt/c/...` (needs `ANSIBLE_CONFIG=$PWD/...`)
- Heero: SSH pre-flight check (test actual key login) catches operator mistakes before lockout
- Noin: Stage 1 acceptance verified from Ubuntu WSL; Stage 2 not yet implemented (awaiting Heero)
- Treize: Stage boundary pattern — each stage produces a verifiable capability (connectivity, base OS, containers, etc.)

**Governance maintained:**
- Spec-driven gates active: Stage 3 (docker-role) drafted but not implemented until approval
- No implementation without spec + issue
- Ansible as primary tool; shell scripts archived to `archive/main-2026-04-13` for reference

**Pattern reinforced:** Spec renumbering (0007→2) signals phase restart. Keeps numbering human-readable and aligns with task-numbering scheme for issue tracking.
