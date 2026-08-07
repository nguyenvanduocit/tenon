# T-005: Browser as a plugin + declarative plugin settings
> Extend the manifest settings schema (select/options/group/icon), render each plugin's settings flat like the current Browser pane, add a `web.view` capability, and reimplement the browser as a real plugin — deleting BrowserConfigStore and the built-in browser view.
- **priority**: high
- **effort**: L

## Design
See `docs/design-plugin-settings.md`. User decisions (2026-07-24): browser becomes a
real JS plugin (not a built-in settings provider); do the whole package in one go after
T-004 releases the shared files.

## Blocked on
T-004 (session 8f863f56) owns `BuiltInSlotViews.swift`, `PluginRuntime.swift`,
`PluginHost.swift`. Start once those locks clear.

## Owner / files (agent lock)
session 537832b5 — RELEASED (all phases done, tree green 225/225). Files below are free.
Historical claim:
- Sources/TenonCore/PluginManifest.swift (schema: select/options/group/icon/displayName)
- Sources/TenonCore/PluginRuntime.swift (web.view gate + tenon.web API)  ⚠️ T-004
- Sources/TenonCore/PluginHost.swift (web surface aggregation)           ⚠️ T-004
- Sources/TenonApp/SettingsView.swift (flat render, generic spec renderer)
- Sources/TenonApp/BuiltInSlotViews.swift (host-owned WKWebView surface)  ⚠️ T-004
- plugins/browser/ (new plugin: manifest + main.js)
- delete: BrowserConfig.swift, SlotContent.browser, WebBrowserSlotView, BrowserSettingsDetail
- Tests/TenonCoreTests/ (schema + web.view capability pair + ShippedPlugins browser)

## Status
- Phase 1 (schema) + Phase 2 (flat render) DONE + verified: 224/224.
- Phase 3 Increment 1 (core platform extension) DONE + verified: **237/237**.
  - `textfield`/`webview` nodes: PluginViewNode + parseNode + renderer (textfield live;
    webview threads an optional `webSurface` closure, placeholder until Increment 2).
  - `web.view` permission + `tenon.web` (load/back/forward/reload) gated in installAPI;
    `WebCommand` + `onWebCommand` sink; `invokeViewSelect` widened to carry textfield text.
  - Invariant #5 updated to seven capabilities (CLAUDE.md + PluginCapabilityTests).
  - Files touched: PluginViewNode.swift, PluginRuntime.swift (parseNode/installAPI/init/
    invokeViewSelect), PluginHost.swift (WebCommand/onWebCommand/invokeViewSelect),
    PluginManifest.swift, BuiltInSlotViews.swift (renderer), + new PluginWebCapabilityTests.
- REMAINING (Increment 2 → Phase 5):
  - Increment 2 (App): `PluginWebSurfacePool` (new) + PluginSlotView binds webview node to
    it + TenonApp wires `onWebCommand`→pool + creates/injects pool. ⚠️ touches TenonApp.swift
    (T-006 phase-3 dirty) — coordinate/defer.
  - Phase 4: `plugins/browser/` (manifest web.view + settings; main.js chrome+nav).
  - Phase 5: delete SlotContent.browser/WebBrowserSlotView/BrowserConfig/BrowserSettingsDetail;
    DefaultPaneContent.browser + launcher → browser plugin pane; ShippedPlugins e2e.
- GUI note: the actual web rendering/navigation is only verifiable by a human running the app.

## Criteria
- [x] `PluginSettingSpec` gains `select` + `options` + `group`; `PluginManifest` gains optional `icon`/`displayName`; lenient decode; core tests
- [x] Settings sidebar renders each settings-bearing plugin flat (icon + name), grouped Form by `group`, select→Picker; one generic renderer for plugin + browser
- [x] `web.view` permission gated in `PluginRuntime.installAPI` with blocked+allowed test pair (invariant #5 now = 7 caps); host owns the WKWebView via `PluginWebSurfacePool` (invariant #2 — plugins never touch the web type)
- [x] `browser` plugin renders the pane + drives navigation + declares its settings; `BrowserConfigStore`, `SlotContent.browser`, `WebBrowserSlotView`, `BrowserAddress`, `BrowserSettingsDetail` deleted (invariant #6 — no browser symbol left in host)
- [x] `DefaultPaneContent.browser` resolves to the browser plugin's pane; launcher + add-slot menu open it
- [x] `ShippedPluginsTests` exercises the browser plugin end-to-end (chrome + webview + opens home)
- [x] swift build + swift test green (225/225); app launches with the browser plugin, no crash
- GUI note: the actual web page rendering/navigation is only verifiable by a human running the app.
