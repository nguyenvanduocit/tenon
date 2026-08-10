# Tenon product-specification templates

This directory defines how Tenon turns product intent into durable requirements and
observable acceptance examples. It exists to prevent a feature's only useful context from
living in chat, a Kanban session note, source comments, or a post-implementation report.

## Research baseline

The templates synthesize the strongest compatible parts of the following sources; they do
not copy one external template blindly.

| Source | Evidence | Adopted | Not adopted |
|---|---|---|---|
| [GitHub `awesome-copilot` PRD skill](https://github.com/github/awesome-copilot/blob/main/skills/prd/SKILL.md) | official GitHub repository, MIT, about 22K skill installs and 37K repository stars when reviewed | discovery before drafting, measurable requirements, explicit non-goals, technical/security constraints, risks, phased delivery | its fixed five-section output, because Tenon needs requirement IDs, shipped-state evidence, architecture classification, and Gherkin traceability |
| [`mattpocock/skills@to-prd`](https://www.skills.sh/mattpocock/skills/to-prd) | about 363K recorded installs; the published skill stresses repository exploration, domain vocabulary, ADRs, and test seams | inspect the live product and existing test seams before specifying implementation | issue-tracker publication and no-interview rule; the advertised `to-prd` file was also absent from the repository's `main` tree when reviewed, so it is not a stable dependency |
| [Dean Peters `prd-development`](https://github.com/deanpeters/Product-Manager-Skills/blob/main/skills/prd-development/SKILL.md) | about 3.5K skill installs and 6K repository stars when reviewed | living-document model, context preservation, decision log, engineering handoff, and explicit “why now” | direct template copying or mandatory market-sizing sections; its license and broad PM workflow do not fit every Tenon feature |
| [Atlassian PRD guidance](https://www.atlassian.com/software/confluence/templates/product-requirements) | maintained product-management template | objectives, success metrics, assumptions, supporting evidence, open questions, and scope protection | Confluence/Jira-specific fields as mandatory product requirements |
| [Cucumber Gherkin reference](https://cucumber.io/docs/gherkin/reference/) | normative syntax reference | one `Feature` per file; `Rule`, `Scenario`, `Given/When/Then`, `Scenario Outline`, examples, tags, data tables, and doc strings | no local syntax inventions |
| [Cucumber BDD guidance](https://cucumber.io/docs/bdd/) and [better Gherkin](https://cucumber.io/docs/bdd/better-gherkin/) | official behavior-design guidance | discovery → formulation → automation; declarative business behavior; observable outcomes; short examples | UI scripts, implementation details, and treating Gherkin as test automation alone |

Reviewed: 2026-08-09.

## Files

- [`prd.md`](prd.md) is the canonical product requirements template. It supports proposed,
  partial, and already-shipped behavior.
- [`gherkin.feature`](gherkin.feature) is the canonical acceptance-example template. It is
  valid Gherkin structure and maps scenarios back to PRD requirement IDs.

## Working agreement

1. Discovery comes before formulation. Answer the core problem, target user, why now,
   success measure, and constraints from user input or verified repository evidence. Mark
   genuinely unknown information `TBD`; never invent it.
2. One PRD owns one coherent product capability. Split a document when separate user
   outcomes can ship, fail, or be rolled back independently.
3. Requirements describe observable product behavior. Architecture and implementation
   mapping explain constraints and delivery, but they do not replace the user problem.
4. Every normative requirement receives a stable ID. Use `<AREA>-FR-###` for functional
   behavior and `<AREA>-NFR-###` for quality constraints.
5. Each acceptance scenario carries `@prd-...` and `@req-...` tags. A scenario may cover
   several requirements only when one observable example genuinely proves them together.
6. Gherkin describes behavior, not clicks and internal calls, unless the input mechanism is
   itself the product contract. Prefer “When the operator reorders the tab” over a script of
   mouse coordinates.
7. A PRD remains after delivery. Change its delivery matrix to `shipped`, map requirements to
   source/tests, and append a dated verification receipt. Do not replace the requirements
   with a retrospective.
8. Exact test counts belong in dated receipts, not durable requirements. A later suite can
   grow without making the requirement false.

## Lifecycle vocabulary

| State | Meaning |
|---|---|
| `proposed` | problem and requirements are still under review |
| `planned` | requirements are accepted; implementation has not shipped |
| `partial` | named requirements shipped and named gaps remain |
| `shipped` | the requirement exists and has relevant verification |
| `deprecated` | present only for migration; removal is planned |
| `historical` | evidence or context, not a current product contract |

## Quality gate

Before accepting a PRD:

- the problem is written from the user's perspective;
- current behavior and evidence are distinguished from assumptions;
- goals have measurable targets or an explicit validation plan;
- scope and non-goals make the boundary unambiguous;
- normal, alternate, cancellation, failure, and recovery behavior are considered;
- accessibility, persistence, performance, privacy/security, compatibility, and lifecycle
  constraints are either specified or marked not applicable with a reason;
- every interaction is classified under `docs/architecture-interaction-boundaries.md`;
- host-native UI is constrained by `docs/designs.md`;
- source ownership and domain tags are identified before implementation;
- acceptance examples use domain language and observable outcomes;
- shipped requirements link to implementation and the smallest relevant test seam;
- risks, assumptions, open questions, and decisions are not blended together.

These checks are intentionally stricter than a generic PRD template because Tenon is a
native host, a plugin platform, and a long-lived workspace product at the same time.
