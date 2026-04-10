# Spec-Driven Development — PerformanceNode

## What Is a Spec?

A spec is a short, structured document that describes **what** a feature does, **why** it exists, and **how we'll know it's done**. Every implementation task in PerformanceNode must start from a spec. No spec, no code.

Specs exist so that:

- **Everyone understands the work** before it starts — including team members who weren't in the original conversation.
- **Scope is explicit.** The "Out of Scope" section prevents scope creep.
- **Acceptance criteria are testable.** QA (Noin) can verify completion without guessing what "done" means.
- **Decisions are traceable.** Months later, you can read the spec to understand why something was built a certain way.

## Lifecycle

```
1. Write spec        → Author creates docs/specs/{issue-number}-{slug}.md using TEMPLATE.md
2. Create issue       → Open a GitHub issue; link to the spec file in the issue body
3. Spec Review        → Treize (Lead) reviews: acceptance criteria testable? Agent assignment clear?
4. Mark ready         → Spec header updated to "Status: ✅ Ready"
5. Branch + implement → Assigned agent(s) branch off main, implement against acceptance criteria
6. PR + review        → Pull request references the issue; code review against spec
7. Merge              → PR merged; spec status updated to "✅ Complete"
```

No code merges without both a spec and a linked GitHub issue.

## File Naming Convention

```
docs/specs/{issue-number}-{slug}.md
```

- `{issue-number}` — the GitHub issue number (zero-padded to 4 digits for sorting: `0001`, `0042`).
- `{slug}` — a short kebab-case description of the feature.

**Examples:**
- `docs/specs/0001-pi5-base-setup.md`
- `docs/specs/0002-dependency-caching.md`
- `docs/specs/0015-runner-auto-update.md`

For retroactive specs (work that predates this process), use a sequential number starting from `0001` and create the GitHub issue afterward.

## Who Can Author a Spec?

Anyone on the team: Treize, Heero, Wufei, Noin, or Fortinbra (owner). Domain expertise matters more than role — if you know the problem space, write the spec. Treize reviews all specs before they're marked ready.

## Definition of Ready

A spec is **ready for implementation** when all of the following are true:

- [ ] All sections from `TEMPLATE.md` are filled in (even if "Out of Scope" or "Dependencies" say "None")
- [ ] Acceptance criteria are **specific and testable** — each item can be verified with a command, a test, or an observable behavior
- [ ] Agent assignment is explicit — at least one team member is named
- [ ] A GitHub issue exists and links to the spec file
- [ ] Treize has reviewed and marked the spec `Status: ✅ Ready`

## Updating Specs

Specs are living documents. If requirements change during implementation:

1. Update the spec file directly (don't create a new one).
2. Add a dated note in the **Notes** section explaining what changed and why.
3. Comment on the linked GitHub issue with a summary of the change.

Acceptance criteria changes after "Ready" require Treize's sign-off.
