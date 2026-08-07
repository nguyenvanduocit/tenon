# T-077: The in-app browser tells sites it is not a browser

> `WebSurface` builds a bare `WKWebViewConfiguration`, so WebKit sends a User-Agent that
> ends at `(KHTML, like Gecko)` — an engine token with no browser product token. UA-sniffing
> sites route that string to legacy or unsupported-browser variants. Reported by the user as
> "in-app browser can't open Google, says the browser is not supported".

- **priority**: high
- **effort**: S

## Owner / files (agent lock)

Released 2026-08-07 12:1x by session 75342883. Every file below is free; the edits are in the
tree, uncommitted like the rest of the shared checkout. `PluginWebSurfacePool.swift` returns to
T-076's sole claim — its `WebSurface` region now carries the UA line, the `WKUIDelegate`
conformance, and `popupTarget`.

- `Sources/TenonApp/WebUserAgent.swift` (new)
- `Sources/TenonApp/PluginWebSurfacePool.swift`
- `Tests/TenonAppStateTests/PluginWebSurfacePoolTests.swift`
- `Sources/TenonApp/FilePreviewSlotViews.swift` — comment only.

## Evidence

Token matrix measured on this machine, 2026-08-07 (macOS 26.4.1, Safari 26.4):

- Default WKWebView UA: `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)` — no `Version/`, no `Safari/`.
- Adding `Safari/605.1.15` alone flips `accounts.google.com` from `flowName=WebLiteSignIn` (844,028 bytes) to `flowName=GlifWebSignIn` (1,232,647 bytes) — the legacy sign-in variant against the modern one. Reproduced twice, by curl and by a real `WKWebView`. An earlier `csp/gws/sf` vs `csp/gws/xsrp` claim was **withdrawn**: verification found that token in none of the fetched bodies.
- Adding `Version/18.5` alone changes nothing. The **product token is the discriminator**.

Rejected with evidence: sandbox/entitlements (app is unsandboxed, no `.entitlements` exists),
JavaScript disabled (`allowsContentJavaScript` defaults true), cookie/data-store failure
(persistent store already asserted in tests), ATS, and the https-only navigation filter.

## Criteria

- [x] `WebUserAgent` is a pure value in `TenonApp` composing `Version/<n> Safari/605.1.15`; no WebKit type in its signature.
- [x] `WebSurface.init` sets `configuration.applicationNameForUserAgent` before the `WKWebView` is constructed. `customUserAgent` stays unused — one knob, one semantic.
- [x] Headless test asserts the composed string for a macOS 26 triple and for an older triple.
- [x] Headless test reads `webView.configuration.applicationNameForUserAgent` back off a real `WebSurface` and tears down its data store.
- [x] `WKUIDelegate.createWebViewWith` loads `target="_blank"` / `window.open` targets in place, gated by the existing `allowsTopLevelNavigation` rule, so new-window links stop silently vanishing.
- [x] Only the top document may redirect the pane that way. `popupTarget` also reads `sourceFrame.isMainFrame`, so an embedded third party — which reaches the same delegate, with no user gesture required — is declined. Measured before the gate: a `data:` iframe inside `https://a.example` moved the top-level document to the target it named.
- [x] `WebPreviewSlotView` records why it keeps the stock UA (it makes no network requests).
- [x] `swift build` and `swift test` green.
