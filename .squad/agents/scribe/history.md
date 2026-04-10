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
