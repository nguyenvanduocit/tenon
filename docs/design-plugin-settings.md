# Design — declarative plugin settings and browser plugin

**Status:** landed; interaction surfaces reconciled · **Date:** 2026-07-25
**Normative boundary:** [`architecture-interaction-boundaries.md`](architecture-interaction-boundaries.md)

## Goal

Each plugin declares settings in `manifest.json`. Tenon renders one generic native settings
form for bundled and third-party plugins. The browser remains a normal bundled plugin:
declarative UI and settings, host-owned WebKit resources, and canonical browser-navigation
intents.

## Boundary classification

| Interaction | Mechanism |
|---|---|
| setting schema in manifest | CONTRIBUTION |
| Settings UI reads/writes host stores | DIRECT typed host calls |
| plugin reads its current setting snapshot | SCOPED FACILITY `tenon.settings.get` |
| plugin persists non-secret private state | SCOPED FACILITY `tenon.storage.get/set` |
| plugin reacts to setting change | EVENT |
| plugin contributes browser chrome/view tree | CONTRIBUTION |
| host creates/retains/disposes WebKit surface | RESOURCE + DIRECT pool lifecycle |
| plugin requests load/back/forward/reload | INTENT |
| URL/title/loading/navigation changed | targeted EVENT |

Settings are not product intents: they are plugin-authored declarative configuration and a
plugin-private snapshot facility. Browser navigation is a finite cross-principal host action
and therefore is an intent.

## Manifest settings schema

```json
{
  "id": "dev.tenon.browser",
  "name": "Browser",
  "version": "1.0.0",
  "icon": "globe",
  "settings": [
    {
      "key": "homeURL",
      "label": "Home URL",
      "type": "string",
      "default": "https://duckduckgo.com",
      "group": "Home and search"
    },
    {
      "key": "searchEngine",
      "label": "Search engine",
      "type": "select",
      "default": "duckduckgo",
      "group": "Home and search",
      "options": [
        {"value":"duckduckgo","label":"DuckDuckGo"},
        {"value":"google","label":"Google"},
        {"value":"bing","label":"Bing"}
      ]
    },
    {
      "key": "rememberLastURL",
      "label": "Remember last page per pane",
      "type": "boolean",
      "default": true,
      "group": "Behaviour"
    }
  ]
}
```

Supported field types are `string`, `boolean`, `number`, and `select`. A select's stored
value is a string and MUST be one of its declared option values. `group`, `icon`, and
`displayName` are presentation metadata.

Manifest validation runs before JavaScript. Invalid defaults/options produce an explicit
plugin load diagnostic rather than a silent runtime fallback.

## Host settings UI

The Settings sidebar contains General, one entry per settings-bearing plugin, and
Extensions management. One generic form renders all plugin schemas:

- `string` → `TextField`;
- `boolean` → `Toggle`;
- `number` → validated numeric field;
- `select` → `Picker`;
- sections preserve declared group/order.

The host reads and writes `SettingsStore` through typed DIRECT calls. A successful change
publishes a targeted setting-change event to the owning plugin generation.

Plugin code reads:

```js
const homeURL = tenon.settings.get("homeURL");
```

The facility is synchronous because it reads the immutable bootstrap/current snapshot for
this plugin. It cannot enumerate another plugin or select a provider.

Secrets never use settings or storage. They use the policy-gated `secrets.*.v1` intents.

## Browser plugin

The browser manifest declares:

- `web.view` capability;
- uses of `browser.surface.load.v1`, `browser.surface.back.v1`,
  `browser.surface.forward.v1`, and `browser.surface.reload.v1`;
- settings schema;
- one instanced plugin view;
- any plugin-owned palette intent it provides, such as “Open Browser.”

Simplified runtime shape:

```js
tenon.views.register("browser", { title: "Browser", instanced: true });

tenon.views.onOpen("browser", async instanceID => {
  const home = tenon.settings.get("homeURL");
  render(instanceID, home);
  await tenon.intents.send(
    "browser.surface.load.v1",
    { surfaceID: instanceID, url: home }
  );
});

tenon.views.onSelect("browser", async (action, value, instanceID) => {
  if (action === "back") {
    await tenon.intents.send(
      "browser.surface.back.v1",
      { surfaceID: instanceID }
    );
  }
});

tenon.events.on("web.did-navigate", event => {
  // targeted to the owning plugin + surface
  render(event.surfaceID, event.url);
});
```

The exact contract schema, not this abbreviated example, is authoritative.

## Host-owned web resource

`PluginWebSurfacePool` owns native `WKWebView` instances keyed by `(PluginID, surfaceID)`.
The plugin sees opaque IDs only.

Lifecycle:

1. workspace reconciliation detects an opened instanced plugin view;
2. host retains/creates the corresponding web resource DIRECT;
3. finite plugin navigation requests enter through browser intents;
4. WebKit delegate facts publish targeted browser events;
5. closing the pane or retiring the plugin generation removes the surface and delegates.

Navigation intents and lifecycle are intentionally different mechanisms. Load/back/forward/
reload settle once and require policy. Surface allocation, retention, observation, and
disposal outlive any one call.

Isolation requirements:

- key includes the validated full `PluginID`, not a display/directory name;
- website data/configuration is scoped according to host browser policy;
- navigation and redirect URLs are validated at use time;
- a plugin cannot address another plugin's surface;
- delegate events go only to the owning active generation;
- pool work required by AppKit/WebKit runs on `MainActor`; policy/schema/network work does
  not.

## View contribution

The browser renders chrome through native declarative nodes, including `browserBar` and a
web-surface node. The host paints native controls; JavaScript keeps navigation state and
decides which intent to send for user actions.

The browser is not represented by a browser-specific host content enum. A pane stores a
generic plugin-view reference; disabling the browser plugin leaves a valid unavailable
placeholder.

## Persistence

- settings: `SettingsStore`, keyed by full `PluginID`;
- non-secret per-instance state such as last URL: plugin-private storage keyed by
  `PluginID`;
- secrets/tokens: Keychain intent provider only;
- live `WKWebView`: resource pool, never serialized as plugin data.

Hot reload intentionally recreates JavaScript state and rebinds contributions/providers.
Persisted settings/storage survive; resource reconciliation restores only resources still
required by the workspace catalog.

## Fitness functions

- settings schema decode/validation covers every type, option, group, and default;
- generic form tests prove no plugin-specific settings renderer exists;
- plugin settings/storage cannot access another `PluginID`;
- the browser declares every navigation intent use;
- browser navigation reaches `PluginWebSurfacePool` only through intent provider adapters;
- browser lifecycle/reconcile calls the injected pool DIRECT and creates no lifecycle
  intent;
- WebKit delegate facts target only the owning plugin/surface;
- two browser panes have independent state and web resources;
- closing/reloading releases the correct resource exactly once;
- no browser-specific host content/store/API survives;
- Swift 6 build and full tests pass.

Falsification: if a setting requires arbitrary host behavior, it is not declarative setting
state. If browser navigation needs multiple results, its observation belongs in events or a
resource. If the plugin must receive a `WKWebView`, the adapter/resource boundary has failed.
