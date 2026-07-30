# T-007: More view-tree components (grid, stat, keyValue, progress, field)
> Extend the plugin view-tree vocabulary (T-004) with a curated status/dashboard set: a `grid` layout primitive and `stat` / `keyValue` / `progress` / `field` components.

- **priority**: medium
- **effort**: S

## Owner / files (agent lock)
session 8f863f56 — released (done). Co-edited PluginRuntime.swift (parseNode only) and
BuiltInSlotViews.swift (PluginNodeView only) alongside T-005/T-006 on disjoint regions;
edits landed cleanly, no clobber. Peers were offline on the inter-session bus, so the
disjoint-split path (user-approved) was used instead of a live ack.

## Criteria
- [x] `grid` (columns, spacing, children) — LazyVGrid layout primitive
- [x] `stat` (label, value) — prominent metric + caption
- [x] `keyValue` (label, value, tint) — inline label→value status row
- [x] `progress` (value 0..1, tint) — linear bar, value clamped
- [x] `field` (label, children) — small header over composed content
- [x] parseNode: malformed/missing-field nodes skipped with a log; tokens fall back to default
- [x] Recursive renderer maps each to TenonTheme
- [x] view-gallery demo showcases the new components
- [x] swift build + swift test green (232 tests, 0 failures)
