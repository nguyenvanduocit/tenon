# T-031: A pane nobody opened costs nothing
> A pane that has never been viewed holds no terminal surface, no PTY and no renderer
> buffers. Once viewed, it keeps them until the slot closes — a live PTY is never torn
> down to save memory.

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
UNCLAIMED. Pairs with T-027 (a restored tree is the case that makes this matter) and with
the process-resource-monitor design under review.

Expected files:
- `poc/Sources/TenonApp/SurfacePool.swift` — the lifecycle rule
- `poc/Sources/TenonApp/SpatialCanvasView.swift` / `BuiltInSlotViews.swift` — the
  not-yet-materialized pane placeholder
- `poc/Sources/TenonApp/GhosttySurface.swift` — hidden-surface renderer cost
- `poc/Tests/TenonAppStateTests/` — surface lifecycle assertions

## Why / evidence
- `SurfacePool.surface(for:workspacePath:)` builds a surface on first call and keeps it in
  `surfaces` (`SurfacePool.swift:49-67`); `docs/research-reference-terminals.md` already
  records that surfaces of inactive workspaces are retained until their slots leave the
  catalog. With one pane per agent, that is the memory curve. (HIGH)
- Kero v0.1.26: *"Sessions you never open no longer cost any GPU memory"* — panes claim
  buffers only when first viewed, and previously viewed panes keep them until closure.
  v0.1.30 additionally reduced hidden Ghostty tab renderer memory.
- The constraint to respect: `research-reference-terminals.md` shows both reference
  terminals independently cure *SwiftUI tearing down the surface kills the PTY* (Kero parks,
  Muxy reparents). So the win here is **never building** a surface for an unviewed pane, and
  trimming renderer cost for hidden ones — not releasing live ones.
- `pendingText` (`SurfacePool.swift:36-39`) is the existing precedent that a slot can be
  addressed before its surface exists; the lazy path must keep that behaviour.

## Criteria
- [ ] A slot that has never been viewed has no entry in `SurfacePool.surfaces` and no PTY;
      asserted headlessly by driving the pool, not by looking at a window
- [ ] Such a pane still renders something useful — its recorded title and cwd — and
      materializes on first view, with the first frame not losing `pendingText`
- [ ] A viewed pane's surface survives tab switches, workspace switches and split changes;
      a test asserts a live PTY is never torn down for memory reasons
- [ ] Hidden viewed panes cost less than visible ones (renderer/buffer trim), with the
      before/after measured and recorded here — 20 hidden tabs is the shape of the case
- [ ] Restored-but-unviewed panes from T-027 go through this same path, so a relaunch with
      30 panes does not spawn 30 shells
- [ ] Surfaces are still released when a slot leaves the catalog (no leak on close) — the
      existing behaviour keeps its own assertion
- [ ] `swift build` + `swift test` green; measurement method stated (what was sampled, how),
      since the process-resource-monitor collector may not exist yet
