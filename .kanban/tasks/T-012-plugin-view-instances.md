# T-012: Plugin view instances (fix browser singleton)
> Split "view type" from "view instance" so multiple panes of one plugin view are
> independent. Instance key = `WorkspaceSlot.id`. Views opt in via `instanced:true`;
> host assigns each pane an instanceID, drives onOpen/onClose lifecycle, per-instance
> body + web surface + title + onSelect. Fixes: opening the browser in several
> tabs/workspaces shared one WKWebView + one address bar. Singleton views (Git/Files)
> unchanged. See docs/design-plugin-view-instances.md.

- **priority**: high
- **effort**: L

## Root cause (verified, Explore trace 2026-07-25)
`SlotContent.pluginView(plugin,viewID)` carries no instance id; host aggregates one
`PluginViewSection` per (plugin,viewID); `PluginWebSurfacePool` keys `"plugin/surfaceID"`;
browser uses fixed VIEW/SURFACE="browser" + JS global `address`. Every browser pane
resolves to the same view state + WKWebView + title. Predates T-011 (from T-005).
No on-disk catalog persist (greenfield) → SlotContent enum stays unchanged.

## Design decision (user, 2026-07-25)
"General instance model", keyed by slot.id. Opt-in `instanced`; onOpen/onClose;
per-instance set/onSelect(3rd arg)/web surface. Invariants 2/5/6 intact.

## Owner / files (agent lock)
session 4564041c — RELEASED (done, 307/307 green + build complete). Files below are free.
- Sources/TenonCore/Workspace.swift (add `WorkspaceCatalog.pluginViewSlots()`; NO SlotContent change)
- Sources/TenonCore/PluginRuntime.swift (views registry/bodies per instance; onOpen/onClose;
  set(viewID,payload,instanceID?); onSelect 3rd arg; open/closeViewInstance; views computed)
- Sources/TenonCore/PluginHost.swift (PluginViewSection +instanceID/+instanced; publish
  aggregation; invokeViewSelect +instanceID; reconcileViewInstances; WebCommand.dispose)
- Sources/TenonCore/WorkspaceStore.swift (reconcile trigger in emit(workspaceEvents:in:))
- Sources/TenonApp/BuiltInSlotViews.swift (PluginSlotView +slotID lookup; title by slotID; webSurface)
- Sources/TenonApp/PluginWebSurfacePool.swift (remove(plugin,surfaceID); handle .dispose)
- Sources/TenonApp/TenonApp.swift (wire .dispose → pool.remove)
- poc/plugins/browser/main.js (instance-aware rewrite)
- Tests: PluginViewsTests / new PluginViewInstanceTests / ShippedPluginsTests / WorkspaceTests

## Criteria
- [x] `WorkspaceCatalog.pluginViewSlots()` enumerates every `.pluginView` slot across workspaces/tabs (core test)
- [x] `tenon.views.register(viewID,{instanced:true})` + `onOpen`/`onClose`; `set(viewID,body,instanceID)`; `onSelect(id,value,instanceID)` (core tests)
- [x] Two panes of an instanced view → two `onOpen` distinct instanceIDs; each body/onSelect isolated; close fires its `onClose` + a `WebCommand.dispose`
- [x] Singleton view unchanged: one section, `onSelect(id,value)` no instanceID (Git/Files regression-free)
- [x] Reconcile idempotent + reentrancy-safe (no double onOpen); driven from workspace catalog (survives tab switch)
- [x] Shell: each browser pane = its own WKWebView + address + tab title (ShippedPlugins e2e: 2 panes → 2 surfaces); browser main.js instance-aware
- [x] swift build + swift test green (307/307, no regressions); app builds/links
- GUI note: independent web pages/titles are only fully verifiable by a human running the app (not smoked here — repo convention).
