# T-008: Empty slot reuses the empty-tab launcher card
> An empty pane/slot must present the same rich launcher card (Add terminal, Open a view, Recently opened, cheatsheet) as an empty tab, filling itself in place.

- **priority**: high
- **effort**: S

## Owner / files (agent lock)
Session 60875de9 (main):
- poc/Sources/TenonApp/EmptyStateCard.swift (NEW — shared launcher card)
- poc/Sources/TenonApp/WorkspaceStageView.swift (EmptyTabCallToAction → thin wrapper over EmptyStateCard; move helper structs out)
- poc/Sources/TenonApp/BuiltInSlotViews.swift (ONLY: BuiltInSlotContentView L7-40 add store/isActive params; EmptySlotView L1219-1231 rewrite). NOT touching T-005 regions (installAPI/tenon.web ~446/664, parseNode ~709, invokeViewSelect ~800, webCommand ~121-157).
- poc/Sources/TenonApp/SpatialCanvasView.swift (slot-cell configure() ~927 + call site ~353: thread store + isActive into BuiltInSlotContentView; empty-slot cache-key includes isActive)

## Criteria
- [x] Empty slot renders the same card as empty tab (icon badge, "empty" title, Add terminal, Open a view grid, Recently opened, cheatsheet)
- [x] Launcher actions on an empty slot fill THAT slot via setSlotContent (not addSlot)
- [x] Shared EmptyStateCard component — no duplicated card markup
- [x] swift build clean, swift test green (225/225, 0 failures)

## Result
- New: poc/Sources/TenonApp/EmptyStateCard.swift (shared launcher card).
- WorkspaceStageView.swift: EmptyTabCallToAction → thin wrapper (onLaunch = addSlot).
- BuiltInSlotViews.swift: EmptySlotView → EmptyStateCard (onLaunch = setSlotContent, fills in place); BuiltInSlotContentView gained store/isActive.
- SpatialCanvasView.swift: threads store + isActive; empty-slot cache-key includes isActive so ↩ default-action rebinds on focus change.
- GUI not screenshot-verified (headless) — build + test is the project's evidence bar.
