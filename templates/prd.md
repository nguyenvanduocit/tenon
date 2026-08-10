# PRD — [Capability name]

> Remove all instructional text in brackets before review. Unknown facts stay `TBD`; do not
> silently turn assumptions into requirements.

| Field | Value |
|---|---|
| PRD ID | `[AREA-NNN]` |
| Lifecycle | `proposed` / `planned` / `partial` / `shipped` / `deprecated` / `historical` |
| Owner | `[product owner or owning team]` |
| Reviewers | `[product, design, engineering, test, security/operations when relevant]` |
| Created | `[YYYY-MM-DD]` |
| Last reviewed | `[YYYY-MM-DD]` |
| Target release | `[release, date, or not applicable]` |
| Related work | `[issues, tasks, designs, research, previous PRDs]` |
| Acceptance specification | `[relative path to one or more .feature files]` |

## 1. Executive summary

### Problem

[Describe the user's pain and its consequence in one or two paragraphs. State current
behavior. Do not start with the proposed mechanism.]

### Proposed outcome

[Describe what becomes possible or reliably true for the user. Keep implementation choices
out unless they are contractual constraints.]

### Why now

[State the trigger: observed defect, strategic goal, customer evidence, architecture change,
or risk. Link evidence and distinguish verified facts from assumptions.]

## 2. Discovery record

### Evidence available

| Evidence | Source/date | Confidence | What it establishes |
|---|---|---|---|
| `[user report, observation, telemetry, source inspection, research]` | `[link or path]` | `high` / `medium` / `low` | `[fact supported]` |

### Context questions

| Question | Answer | Source or decision date |
|---|---|---|
| What core problem are we solving? | `[answer]` | `[source]` |
| Who experiences it? | `[answer]` | `[source]` |
| How will we know it worked? | `[answer]` | `[source]` |
| Which constraints cannot move? | `[answer]` | `[source]` |
| What remains unknown? | `[TBD or none]` | `[owner/date]` |

### Assumptions to validate

| ID | Assumption | Validation method | Owner | Due/state |
|---|---|---|---|---|
| `A-001` | `[assumption, not a disguised fact]` | `[test, observation, interview, benchmark]` | `[owner]` | `[date/state]` |

## 3. Users and jobs

### Primary user

[Role, relevant environment, goals, pain points, and current workaround. Avoid fictional
demographics that do not change a requirement.]

### Secondary users and affected actors

[Operators, plugin authors, agents, accessibility users, administrators, or external systems
whose behavior or risk changes.]

### Jobs to be done

- When `[situation]`, I want to `[motivation/action]`, so I can `[expected progress]`.

### Product vocabulary

| Term | Meaning in this PRD | Not to be confused with |
|---|---|---|
| `[domain term]` | `[precise meaning]` | `[nearby term]` |

## 4. Goals and success measures

### Goals

- `G-001` — [Observable user or product outcome.]

### Success metrics

| ID | Metric | Baseline | Target | Measurement method | Review window |
|---|---|---|---|---|---|
| `M-001` | `[metric]` | `[known value or TBD]` | `[numeric/boolean target]` | `[instrument, test, study]` | `[period]` |

### Guardrail metrics

| ID | Regression to prevent | Limit | Measurement method |
|---|---|---|---|
| `GM-001` | `[reliability, latency, error rate, abandonment, resource use]` | `[limit]` | `[method]` |

## 5. Scope

### In scope

- [Capability or workflow included in this delivery.]

### Non-goals

- [Adjacent capability deliberately excluded, with rationale when non-obvious.]

### Later possibilities

- [Plausible follow-up that is not promised by this PRD.]

## 6. User experience

### Entry points

[How the user discovers or invokes the capability. State whether it is focused-view local,
host-wide, plugin-owned, CLI/agent accessible, or not applicable.]

### Primary flow

1. [User-visible starting state.]
2. [Intentional user action.]
3. [Observable system response.]
4. [Completion and feedback.]

### Alternate and edge flows

- **No-op:** [What happens when the requested state already exists.]
- **Cancellation:** [How the user backs out and what remains unchanged.]
- **Invalid input/state:** [Refusal and feedback.]
- **Failure:** [Failure presentation and preserved state.]
- **Recovery:** [Retry, rollback, or safe next action.]
- **Concurrent/stale state:** [Resolution when relevant.]

### Accessibility and input parity

[Keyboard, pointer, VoiceOver, focus, reduced motion, increased contrast, localization, and
alternative route requirements. State not applicable only with a reason.]

## 7. Requirements

Use **MUST**, **MUST NOT**, **SHOULD**, and **MAY** only for normative behavior. Requirements
describe externally meaningful behavior; implementation details belong in constraints or the
implementation mapping.

### Functional requirements

| ID | Requirement | Priority | Delivery | Acceptance reference |
|---|---|---|---|---|
| `AREA-FR-001` | The product **MUST** `[observable behavior]`. | `must` / `should` / `could` | `planned` / `partial` / `shipped` | `@req-area-fr-001` |

### Non-functional requirements

| ID | Category | Requirement and measurable bound | Delivery | Acceptance/evidence |
|---|---|---|---|---|
| `AREA-NFR-001` | performance | `[bound, load, device/environment, measurement]` | `[state]` | `[scenario/test/receipt]` |
| `AREA-NFR-002` | reliability/lifecycle | `[cancellation, ownership, timeout, recovery]` | `[state]` | `[reference]` |
| `AREA-NFR-003` | accessibility | `[observable parity or standard]` | `[state]` | `[reference]` |
| `AREA-NFR-004` | privacy/security | `[data/authority/refusal requirement]` | `[state]` | `[reference]` |
| `AREA-NFR-005` | persistence/migration | `[save/restore/compatibility requirement]` | `[state]` | `[reference]` |

## 8. Acceptance specification

Gherkin scenarios are concrete examples of these requirements, not a second requirements
list. Use [`templates/gherkin.feature`](gherkin.feature) and link each scenario by tag.

| Requirement | Feature/scenario | Automation seam | State |
|---|---|---|---|
| `AREA-FR-001` | `[path.feature: Scenario name]` | `[pure core, hosted AppKit, XCUITest, manual/visual]` | `draft` / `red` / `green` / `manual` |

## 9. Product and architecture constraints

### Interaction boundary classification

Complete this table before adding or changing an interaction. The ordered law in
[`docs/architecture-interaction-boundaries.md`](../docs/architecture-interaction-boundaries.md)
is normative.

| Interaction | Semantic owner/caller | Classification | Why this rung applies | Public inventory change? |
|---|---|---|---|---|
| `[interaction]` | `[owner → caller]` | `CONTROL PLANE` / `CONTRIBUTION` / `EVENT` / `RESOURCE` / `DIRECT` / `SCOPED FACILITY` / `INTENT` | `[law-based reason]` | `no` or `[exact inventory work]` |

### Native design-system constraints

[Name the existing Tenon components/tokens that own the presentation. Any host-native UI
MUST follow `docs/designs.md`; external references inform workflow, not local visual tokens.]

### Domain and ownership map

| Product domain | Existing owner/source | Expected change | Retrieval/tests |
|---|---|---|---|
| `[domain from docs/domains.md]` | `[service/file/module]` | `[none or expected responsibility]` | `[symbol edges and tests]` |

### Data, resource, and lifecycle model

[Identity, ownership, lifetime, cancellation, bounds, persistence, migration, stale state,
and teardown. State which component owns each resource and when that ownership ends.]

### Security and privacy

[Principals, permissions, sensitive data, trust boundary, denial behavior, logging, retention,
and threat assumptions.]

### Compatibility

[OS/runtime floor, file/schema compatibility, plugin/API compatibility, upgrade/downgrade,
and fallback behavior.]

## 10. Delivery plan

### Requirement delivery matrix

This matrix is mandatory for PRDs that include already-shipped work.

| Requirement | State | Implementation/source | Test/evidence | Remaining gap |
|---|---|---|---|---|
| `AREA-FR-001` | `planned` / `partial` / `shipped` | `[path/symbol or none]` | `[path/test/receipt]` | `[gap or none]` |

### Phases

| Phase | User-visible outcome | Included requirements | Exit criteria | Rollback/fallback |
|---|---|---|---|---|
| `0 — discovery` | `[learning]` | `[IDs]` | `[decision evidence]` | `[stop condition]` |
| `1 — delivery` | `[minimum coherent value]` | `[IDs]` | `[acceptance]` | `[safe rollback]` |
| `2 — follow-up` | `[optional later value]` | `[IDs]` | `[acceptance]` | `[fallback]` |

### Migration and rollout

[Existing-state migration, feature flag/channel strategy, telemetry/diagnostics, staged
verification, rollback trigger, and user communication.]

## 11. Dependencies, risks, and mitigations

### Dependencies

| Dependency | Owner | Needed by | Failure/fallback |
|---|---|---|---|
| `[dependency]` | `[owner]` | `[phase/requirement]` | `[behavior]` |

### Risks

| ID | Risk | Likelihood | Impact | Mitigation | Trigger/owner |
|---|---|---|---|---|---|
| `R-001` | `[specific risk]` | `low` / `medium` / `high` | `low` / `medium` / `high` | `[action]` | `[signal/owner]` |

## 12. Open questions and decisions

### Open questions

| ID | Question | Why it matters | Owner | Due/blocking state |
|---|---|---|---|---|
| `Q-001` | `[question]` | `[affected requirements]` | `[owner]` | `[date/state]` |

### Decision log

| Date | Decision | Rationale/evidence | Requirements affected | Supersedes |
|---|---|---|---|---|
| `[YYYY-MM-DD]` | `[decision]` | `[reason/link]` | `[IDs]` | `[prior decision or none]` |

## 13. Verification receipts

Append receipts; do not rewrite the requirements around one run.

| Date | Worktree/commit | Environment | Scope/command | Result | Known exclusions |
|---|---|---|---|---|---|
| `[YYYY-MM-DD]` | `[ref and dirty/clean state]` | `[OS, channel, hardware when relevant]` | `[test or manual flow]` | `[pass/fail and artifact]` | `[unrelated failures/not run]` |

## 14. Change history

| Date | Change | Why | Author/decision owner |
|---|---|---|---|
| `[YYYY-MM-DD]` | `Initial PRD` | `[trigger]` | `[owner]` |
