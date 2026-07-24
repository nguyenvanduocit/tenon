# T-001: Bảo lưu active pane theo từng tab
> Khi chuyển sang tab khác rồi quay lại, active pane của tab cũ không được giữ nguyên

- **priority**: high
- **effort**: S

## Criteria
- [x] Mỗi tab lưu riêng active pane (pane B đang active ở tab A phải được nhớ)
- [x] Chuyển sang tab khác rồi quay lại tab A → active pane vẫn là B, không reset về pane mặc định
- [x] Có test ở `TenonCoreTests` khẳng định active pane per-tab được bảo lưu qua chuyển tab (assert được không cần window)

## Resolution
Active pane đã là thuộc tính của core, đúng như hướng điều tra đề xuất — `Tab.activeSlotID` (`Workspace.swift:51`) lưu active pane riêng cho từng tab, và `selectTab` (`Workspace.swift:366`) khôi phục đúng `activeSlotID` của tab khi quay lại, phát `.slotFocused(tab.activeSlotID)`. Shell chỉ project state này: highlight theo `tab.activeSlotID` (`SpatialCanvasView.swift:361`), keyboard focus qua `.slotFocused` → `pool.focusSurface` (`TenonApp.swift:41-43`) — không giữ active-pane state riêng nên không mất khi remount.

Không tái hiện được bug ở tầng core (pane-slots refactor đã đặt state đúng chỗ). Deliverable là test khóa hành vi: `testEachTabPreservesItsOwnActiveSlotAcrossTabSwitches` (`WorkspaceTests.swift`) — split tab A → active pane B, mở tab X (active pane riêng), quay lại A → vẫn B + phát `slotFocused(B)`, và X vẫn giữ pane của nó. Full suite 151/151 pass.

## Notes
Bug quan sát: đang ở tab A, active panel B; sang tab khác rồi quay lại → active panel không được bảo lưu.

Hướng điều tra (chưa verify):
- Active pane state có thể đang được giữ ở tầng shell (`SpatialCanvasView` / `WorkspaceStore`) thay vì gắn theo tab trong `Workspace` core → khi remount view thì mất.
- Kiểm tra model `Workspace` (tabs/splits/panes as pure values) xem active pane thuộc về tab hay là global state.
- Theo invariant của repo: rule phải assert được trong `TenonCore` không cần window → active-pane-per-tab nên là thuộc tính của core, không phải view state.
