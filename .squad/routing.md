# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Architecture, overall structure, decisions, code review, ambiguous requests | Treize | Architecture, reviews, triage |
| Pi OS setup, system packages, networking, services, GitHub Actions runner install/config, security hardening, systemd | Heero | Pi setup, runner config |
| Performance test scripts, benchmarks, metrics collection, test harness design, results output format | Wufei | Benchmarks, metrics |
| Script validation, edge cases, smoke tests, idempotency checks, shell scripting pitfalls, post-setup verification | Noin | QA, validation |
| Scope & priorities | Treize | Architecture decisions, trade-offs, what to build next |
| Async issue work (bugs, tests, small features) | @copilot 🤖 | Well-defined tasks matching capability profile |
| Session logging | Scribe | Automatic — never needs routing |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, evaluate @copilot fit, assign `squad:{member}` label | Lead |
| `squad:{name}` | Pick up issue and complete the work | Named member |
| `squad:copilot` | Assign to @copilot for autonomous work (if enabled) | @copilot 🤖 |

### How Issue Assignment Works

1. When a GitHub issue gets the `squad` label, the **Lead** triages it — analyzing content, evaluating @copilot's capability profile, assigning the right `squad:{member}` label, and commenting with triage notes.
2. **@copilot evaluation:** The Lead checks if the issue matches @copilot's capability profile (🟢 good fit / 🟡 needs review / 🔴 not suitable). If it's a good fit, the Lead may route to `squad:copilot` instead of a squad member.
3. When a `squad:{member}` label is applied, that member picks up the issue in their next session.
4. When `squad:copilot` is applied and auto-assign is enabled, `@copilot` is assigned on the issue and picks it up autonomously.
5. Members can reassign by removing their label and adding another member's label.
6. The `squad` label is the "inbox" — untriaged issues waiting for Lead review.

### Lead Triage Guidance for @copilot

When triaging, the Lead should ask:

1. **Is this well-defined?** Clear title, reproduction steps or acceptance criteria, bounded scope → likely 🟢
2. **Does it follow existing patterns?** Adding a test, fixing a known bug, updating a dependency → likely 🟢
3. **Does it need design judgment?** Architecture, API design, UX decisions → likely 🔴
4. **Is it security-sensitive?** Auth, encryption, access control → always 🔴
5. **Is it medium complexity with specs?** Feature with clear requirements, refactoring with tests → likely 🟡

## Spec Routing

| Work Type | Route To | Notes |
|-----------|----------|-------|
| "write a spec" / "draft a spec" | Treize reviews → domain expert authors | Treize ensures process compliance; author with domain expertise writes `docs/specs/` |
| "spec for infra/setup/Docker/systemd" | Heero (author) → Treize (review) | Heero has infrastructure domain knowledge |
| "spec for perf/benchmarks/metrics/caching" | Wufei (author) → Treize (review) | Wufei has performance domain knowledge |
| "spec for tests/validation/QA" | Noin (author) → Treize (review) | Noin has testing domain knowledge |
| "review spec" | Treize | Lead reviews all specs before marking ready |
| New spec received (any source) | Trigger **Spec Review** ceremony before routing implementation work | No implementation agents spawn until spec is ✅ Ready |

**Spec gate rule:** The Squad Coordinator must verify that a spec (`docs/specs/{issue}-{slug}.md`) and a linked GitHub issue exist before spawning implementation agents. If either is missing, route to Treize first.

## Rules

1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work.
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Anticipate downstream work.** If a feature is being built, spawn the tester to write test cases from requirements simultaneously.
7. **Issue-labeled work** — when a `squad:{member}` label is applied to an issue, route to that member. The Lead handles all `squad` (base label) triage.
8. **@copilot routing** — when evaluating issues, check @copilot's capability profile in `team.md`. Route 🟢 good-fit tasks to `squad:copilot`. Flag 🟡 needs-review tasks for PR review. Keep 🔴 not-suitable tasks with squad members.
