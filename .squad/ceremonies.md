# Ceremonies

> Team meetings that happen before or after work. Each squad configures their own.

## Design Review

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | before |
| **Condition** | multi-agent task involving 2+ agents modifying shared systems |
| **Facilitator** | lead |
| **Participants** | all-relevant |
| **Time budget** | focused |
| **Enabled** | ✅ yes |

**Agenda:**
1. Review the task and requirements
2. Agree on interfaces and contracts between components
3. Identify risks and edge cases
4. Assign action items

---

## Retrospective

| Field | Value |
|-------|-------|
| **Trigger** | auto |
| **When** | after |
| **Condition** | build failure, test failure, or reviewer rejection |
| **Facilitator** | lead |
| **Participants** | all-involved |
| **Time budget** | focused |
| **Enabled** | ✅ yes |

**Agenda:**
1. What happened? (facts only)
2. Root cause analysis
3. What should change?
4. Action items for next iteration

---

## Spec Review

| Field | Value |
|-------|-------|
| **Trigger** | manual or auto |
| **When** | before |
| **Condition** | any new implementation work item that does not yet have an approved spec |
| **Facilitator** | Treize |
| **Participants** | spec author + lead |
| **Time budget** | quick |
| **Enabled** | ✅ yes |

**Purpose:** Gate check — no implementation starts without a reviewed spec.

**Agenda:**
1. Confirm all sections of `docs/specs/TEMPLATE.md` are filled in
2. Verify acceptance criteria are specific and testable (no vague language)
3. Confirm agent assignment is explicit and appropriate
4. Verify a GitHub issue exists and links to the spec
5. Mark spec `Status: ✅ Ready` or return with specific feedback

**Output:** Spec status updated to `✅ Ready` (proceed) or returned to author with written feedback on what needs to change.

**Note:** This is a gate check, not a design meeting. If the spec needs design discussion, schedule a Design Review instead.
