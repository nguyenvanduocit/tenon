# T-154: A workspace wears the mark you choose

> Expand the native identity form with more semantic choices and an uploaded image, then
> expose the same finite mutation so CLI and supervised AI callers can customize an exact
> workspace without a second domain service.

- **priority**: medium
- **effort**: M
- **PRDs**: `TENON-PRD-001` (workspace shell), `TENON-PRD-007` (CLI control),
  interaction-boundary canonical intent inventory
- **Claimed** by the current Codex session 2026-08-14 11:47, over the existing WIP limit by
  direct operator request.

## Why

The identity popover has twelve marks and five deliberate colours. The operator asked for
more of both, a personally supplied image, and a scriptable route for an AI working through
`tenon-cli`. The dated CLI capability survey classifies workspace rename as app behavior the
CLI cannot reach, not a refused product direction: `WorkspaceStore` already owns the domain
mutation and the missing piece is one canonical public adapter.

## Boundary decision

- Native SwiftUI remains same-owner **DIRECT** to `WorkspaceStore`.
- `{plugin, cli, agent}` customization is one finite **INTENT**,
  `workspace.identity.set.v1`, on the existing workspace lane with the existing
  `workspace.control` capability.
- Scope must name a workspace UUID. It never falls back to selection.
- Custom image input crosses the intent as bounded base64 bytes, not a host-read file path.
  Both UI and provider use the same decoder/normalizer before the small PNG enters state.
- No new control action, `tenon` path, principal, audience, capability, lane, event, resource,
  or CLI-only semantic service is added.

## Criteria

- [x] The closed vocabularies contain 24 drawable, spoken system marks and 12 semantic named
      accents plus Automatic, laid out in balanced grids inside the 320-point native form.
- [x] The form imports one image through the native file picker, decodes and thumbnails it
      off MainActor, and stores at most a 64×64, 128 KiB normalized PNG.
- [x] Catalog and recent-workspace persistence embed the normalized bytes and UUID; legacy
      records still restore, and corrupt custom bytes lose only the bitmap.
- [x] Reset clears the custom image, and selecting a system mark replaces it.
- [x] One atomic `setWorkspaceIdentity` applies name and appearance with one event/snapshot.
- [x] `workspace.identity.set.v1` uses closed patch schemas, exact workspace scope,
      `{plugin, cli, agent}`, `.write`, `workspace.control`, and returns the final identity.
- [x] Canonical inventory, lane map, source fitness counts, PRDs, and feature scenarios change
      in the same review.
- [x] Focused core/app tests and architecture fitness pass; full build outcome is recorded
      honestly against unrelated in-flight failures.
- [x] Render the shipping form offscreen and inspect the resulting snapshot.

## Owner / files (agent lock)

Held until verification completes:

- `Sources/TenonCore/{AppPreferences,WorkspaceIdentity,Workspace,WorkspaceStore,WorkspaceCatalogStore,RecentWorkspaceStore,CoreIntentCatalog}.swift`
- `Sources/TenonApp/{WorkspaceIdentityViews,WorkspaceCustomIconImport,WorkspaceIntentProvider}.swift`
- focused tests for those files
- `docs/architecture-interaction-boundaries.md`
- workspace-shell and CLI-control PRDs/features

Explicitly not held or edited: `Sources/TenonApp/WorkspaceSidebarView.swift`.

## Verification

- 2026-08-14: `swift build --target TenonCore` and `swift build --target TenonApp` passed in
  the isolated scratch build. The final full suite passed **2233 / 0** in 155.114 seconds.
- Focused identity, provider, catalog, recent-store, form, and interaction-boundary coverage
  passed **118 / 0** before the importer split; the final importer/form/provider/domain slice
  passed **42 / 0** after it. `git diff --check` was clean for the held files.
- The shipping form rendered offscreen at its real 320-point width. The inspected image shows
  all 24 marks in a balanced 3-row grid, the native upload control, Automatic plus 12 accents
  in two rows, and no clipping or scroller at roughly 396 points tall.
- Not claimed: no live file-picker gesture or live CLI socket round trip was driven. The
  importer and intent provider boundaries are mounted headlessly, including corrupt and
  oversized input, exact UUID scope, and normalized custom-image output.

All task locks are released.
