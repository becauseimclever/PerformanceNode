# Copilot Instructions — PerformanceNode

## Project Overview
PerformanceNode is a collection of setup scripts and configuration for turning a **Raspberry Pi 5** into a **self-hosted GitHub Actions runner** purpose-built for local performance testing of GitHub repositories.

Starting point: a fresh **Raspberry Pi OS Lite** (latest, 64-bit, headless) install — no desktop, no GUI.

## Goal
- Automate the full setup of a Pi 5 from bare OS to a fully registered, running GitHub Actions runner
- Run performance benchmarks against target GitHub repositories (clone, build, test cycle timing, resource usage)
- Report results back to GitHub Actions workflow artifacts or job summaries

## Tech Stack
- **Target hardware:** Raspberry Pi 5
- **Target OS:** Raspberry Pi OS Lite (64-bit, headless, latest Bookworm-based)
- **Scripting language:** Bash/Shell
- **CI platform:** GitHub Actions (self-hosted runner)
- **Service management:** systemd
- **Package manager:** apt

## Coding Conventions
- All setup scripts MUST be **idempotent** — safe to run multiple times on the same system
- Always use `set -euo pipefail` at the top of every bash script
- Echo clear progress messages to stdout; errors to stderr
- Use meaningful exit codes (0 = success, non-zero = failure with descriptive message)
- Performance results output in **JSON or CSV** for machine consumption downstream
- The GitHub Actions runner MUST run as a dedicated non-root user (e.g., `actions-runner`)
- SSH: disable password authentication, enforce key-based auth, harden sshd_config
- Scripts should work unattended (no interactive prompts in normal flow; use env vars or config files for inputs)

## Project Structure (evolving)
```
/
├── scripts/          # Setup and configuration scripts
│   ├── setup/        # OS-level setup (packages, users, SSH, etc.)
│   ├── runner/       # GitHub Actions runner install and registration
│   └── performance/  # Benchmark and metrics scripts
├── config/           # Configuration templates and defaults
├── tests/            # Validation and smoke test scripts
└── .github/
    └── workflows/    # Any CI workflows for this repo itself
```

## Squad AI Team
This project uses the Squad AI team framework. See `.squad/team.md` for the full roster.

| Agent | Role | Domain |
|-------|------|--------|
| Treize | Lead | Architecture, decisions, reviews |
| Heero | Infrastructure Dev | Pi setup, runner configuration |
| Wufei | Performance Engineer | Benchmarks, metrics, test harness |
| Noin | Tester/QA | Validation, edge cases, smoke tests |

## Out of Scope
- GUI or desktop environment setup (headless only)
- Multi-Pi runner clustering
- Cloud infrastructure or remote deployment
- Docker/container-based runner (native only)
