# PerformanceNode

**Status:** 🔄 Rebooting — Ansible-first architecture. See `docs/architecture/ansible-reboot-proposal.md`.

An **Ansible-based automation framework** for setting up Raspberry Pi 5 as a self-hosted GitHub Actions runner for local performance testing. Designed for reproducibility, idempotency, and extensibility to other network hosts.

## Architecture

**Phase 1 scope:** Raspberry Pi 5 runner setup only.

```
inventories/          # Production/development host inventories
playbooks/            # Ansible playbooks (pi-runner.yml, site.yml)
roles/                # Reusable roles (common, docker, github_runner, runner_hooks, caching)
docs/architecture/    # Architecture proposals and decisions
```

See [`docs/architecture/ansible-reboot-proposal.md`](docs/architecture/ansible-reboot-proposal.md) for the full proposal.

## Team

This project uses the **Squad AI team framework**:

| Agent | Role |
|-------|------|
| **Treize** | Lead — architecture, decisions, reviews |
| **Heero** | Infrastructure — Ansible roles, Pi setup |
| **Wufei** | Performance — metrics, benchmarking (Phase 2) |
| **Noin** | QA — validation, idempotency tests |

Team structure, decisions, and history: [`.squad/`](.squad/)

## Status

- **Prior shell-script implementation:** Archived at `archive/main-2026-04-13`
- **Current:** Architecture proposal drafted, awaiting approval
- **Next:** Write spec `0007-ansible-pi-runner-role.md`, then implement

## Quick Links

- [Architecture Proposal](docs/architecture/ansible-reboot-proposal.md)
- [Decision Record](/.squad/decisions/inbox/treize-ansible-reboot.md)
- [Team Decisions](/.squad/decisions.md)
