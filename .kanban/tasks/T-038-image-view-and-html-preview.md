# T-038: Support image view, HTML preview
> Open image files in an image viewer pane and HTML files in a rendered preview pane inside the workspace.

- **priority**: medium
- **effort**: M

## Criteria
- [ ] Opening an image file (png/jpg/gif/webp/svg) shows it rendered in a pane, not raw bytes
- [ ] Opening an HTML file shows a rendered preview pane (WebKit surface)
- [ ] Both flows follow the interaction boundary law (docs/architecture-interaction-boundaries.md) — classified before implementation
- [ ] A broken/unsupported file falls back gracefully without taking down the host
- [ ] Covered by headless tests in `TenonCoreTests` where the rule permits

## Notes
- The browser plugin + `PluginWebSurfacePool` already exist — HTML preview likely reuses that surface path rather than adding a new native view.
- Decide whether these ship as plugins (canonical intents + contributions) or host-native panes; the boundary law selects the mechanism.
