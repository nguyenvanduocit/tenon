# T-087: New panes respect the default max width
> Let the user choose a preferred maximum width so a newly created pane does not expand beyond the size they find useful.

- **priority**: medium
- **effort**: M

## Criteria
- [ ] Host-native Settings exposes an optional default maximum width for newly created panes, following `docs/designs.md` and the existing settings vocabulary instead of introducing feature-local tokens.
- [ ] The preference is validated, persisted, and restored across app launches; invalid or out-of-range values cannot create an unusable layout.
- [ ] Initial pane sizing considers both available space and the configured limit: a new pane is never wider than the available layout permits or the user's maximum.
- [ ] When the preference is unset or disabled, pane creation behaves exactly as it does today.
- [ ] Changing the preference affects future pane creation only; existing panes keep their current size and remain freely resizable by the user.
- [ ] Every pane-creation entry point uses the same typed sizing policy, with built-in SwiftUI calling it directly in accordance with `docs/architecture-interaction-boundaries.md`.
- [ ] Tests cover unset, wide-space, narrow-space, boundary-value, persistence, and existing-pane cases.

## Notes
The product intent is a default creation constraint, not a permanent width lock. Compute the
new pane's initial width from the space-based layout first, then cap that result with the
configured maximum; the sibling or remaining layout retains the unused width.
