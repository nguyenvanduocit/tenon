# T-041: Plugin `kanban` — hiển thị board .kanban/ và nút Start mở panel AI
> Plugin đọc đúng aio-kanban md convention (`.kanban/board.md` index + `.kanban/tasks/T-NNN-slug.md`), render board theo cột, watch file để cập nhật live, và nút **Start** mở tab mới chạy `claude` với prompt làm task đó (qua T-040).

- **priority**: high
- **effort**: L
- **depends**: T-040

## Owner / files (agent lock)
session 247281cf — **DONE 09:5x, ALL LOCKS RELEASED.** Files: NEW `poc/plugins/kanban/{main.js,manifest.json}`,
NEW `poc/Tests/TenonCoreTests/KanbanPluginTests.swift`, and one line appended to the
shipped-plugin roster in `poc/Tests/TenonCoreTests/ShippedPluginsTests.swift`.

## Why
Tenon là supervision layer; `.kanban/` đã là kênh điều phối giữa các agent trong repo này. Một pane kanban native-trong-Tenon biến board thành attention surface: thấy Backlog/Todo/Doing/Done, bấm Start → một agent nhận task trong PTY thật — đúng luồng "human directs, agent executes".

## Format phải parse (aio-kanban v3 — dùng verbatim, không tự chế)
- Board index: `.kanban/board.md`, section `## Backlog|Todo|Doing|Done|Blocked`, mỗi dòng `- [T-NNN](tasks/T-NNN-slug.md) Title — priority/effort`.
- Task file: `# T-NNN: Title`, `> mô tả`, fields `- **priority**:`, `- **effort**:`, optional `depends/branch/completed/blocked-by`, `## Criteria` checkbox list.
- Parser phải fail-soft: dòng lệch format bị bỏ qua, không làm hỏng cả board.

## Design constraints
- Plugin thuần JS trong `poc/plugins/kanban/`, chỉ dùng surface `tenon` công khai: đọc file qua intent fs đã có, `fs.watch` (RESOURCE) cho `.kanban/`, `views.register/set/onSelect` (CONTRIBUTION) cho UI, Start gửi intent T-040 chạy `claude` kèm prompt (vd "làm task T-NNN theo .kanban/tasks/T-NNN-slug.md, tuân thủ protocol trong CLAUDE.md").
- **Instance model** (T-036): state key theo instanceID, board root resolve từ workspace SỞ HỮU pane — không module-global singleton.
- **Chống leak** (invariant 10 — user nhấn mạnh):
  - Watcher `fs.watch` cancel khi view close / generation retire; hot reload không để watcher mồ côi (ShippedPluginsTests đã có pattern FSEvents thật để soi).
  - Debounce/coalesce sự kiện file (board hay bị ghi dồn dập bởi nhiều agent) — không re-parse per-event storm, không giữ mảng event không giới hạn.
  - View-tree snapshot bounded: board lớn thì cắt (vd Done chỉ hiện N dòng đầu + đếm), string bounded theo `IntentValue`.
- Manifest declare đủ `permissions` + `intents.uses` (fs read/watch + intent T-040) — invariant 9.

## Criteria
- [x] Parser đọc board.md + task file đúng format v3, fail-soft — `testBoardParser…` cho một
      board có dòng hỏng giữa hai task hợp lệ và đòi **chỉ** dòng đó bị bỏ; cũng đòi một
      dòng có nhiều đoạn ` — ` giữ đúng title và meta thay vì nuốt cả ghi chú trạng thái
      vào title
- [x] Pane hiển thị cột + task line, chọn task → chi tiết — `testBoardRendersColumnsWithTheirTasks`
      (đếm mỗi cột) và `testSelectingATaskRevealsItsDescriptionAndCriteria`
- [x] Sửa board trên đĩa → UI cập nhật qua `fs.watch` — `testEditingTheBoardOnDiskReachesThePane`
      ghi file thật vào thư mục tạm thật, đi qua FSEvents thật, đúng mốc `ShippedPluginsTests` đặt
- [x] Start → `terminal.open.v1` — `testStartHandsTheTaskToAnAgentInANewTerminal` assert
      payload: `claude …`, có id task, **có đường dẫn task file**, có `CLAUDE.md`, và
      `workingDirectory` là workspace sở hữu pane
- [x] Watcher được thả khi đóng pane — `testClosingThePaneReleasesItsWatcherAndTimer` đóng
      pane rồi ghi board và đòi **0** lần đọc. ⚠️ Nửa hot-reload thì đi theo đường retirement
      chung của runtime (đã có test riêng), task này không assert lại
- [x] Debounce: N sự kiện → 1 lần re-parse — xem mục dưới, test đầu tiên **không** load-bearing
- [x] Hai workspace → mỗi instance theo board của workspace mình —
      `testTwoPanesEachFollowTheBoardOfTheirOwningWorkspace`, mỗi board có một task cái kia
      không có, và assert cả hai chiều (không thấy task của nhau)
- [x] `swift build` exit 0 + full `swift test` **852 / 0** (843 trước)

## Plugin-only, đúng như đề bài yêu cầu chứng minh

Không dòng Swift nào trong host bị sửa. File đến qua `filesystem.file.read.v1`, cây là
CONTRIBUTION, watcher là RESOURCE do pane sở hữu, Start là `terminal.open.v1` (T-040).
Các cổng có sẵn của `ShippedPluginsTests` nhận plugin mà không cần nới: danh tính chuẩn,
chỉ dùng surface hiện hành, và **`testEveryLiteralSendAndHandlerMatchesItsManifestExactly`
tự động kiểm mọi `intents.send` khớp `manifest.intents.uses`** — đó là invariant 9 được
thực thi sẵn, tôi không phải viết thêm gì.

## 🐞 Test debounce đầu tiên của tôi là đồ trang trí

Bản đầu ghi 8 lần vào board rồi đòi số lần đọc `< 8`. Khi chạy mutation gỡ **sạch** debounce,
test **vẫn xanh** — vì nó đang đo khả năng gộp sự kiện của **FSEvents**, không phải của
plugin: macOS đã hợp nhất các sự kiện trước khi plugin kịp nhìn thấy. Một test không thể
đỏ thì không phải bằng chứng.

Bản mới gọi thẳng `debouncedRefresh` 8 lần rồi đòi **đúng 1** lần đọc. Nó tách phép đo khỏi
hệ thống file, và mutation làm nó đỏ ngay.

## Mutation proofs

| # | Mutation | Test đỏ |
|---|---|---|
| M19 | dòng board hỏng format thành task thay vì bị bỏ | `testBoardParser…`, `testBoardRendersColumnsWithTheirTasks` |
| M20 | gỡ debounce, mỗi sự kiện một lần re-parse | `testABurstOfWritesCoalescesIntoOneReparse` (sau khi viết lại) |
| M21 | đóng pane nhưng không cancel watcher | `testClosingThePaneReleasesItsWatcherAndTimer` |
| M22 | prompt Start bỏ tham chiếu task file | `testStartHandsTheTaskToAnAgentInANewTerminal` |
| M23 | board resolve theo workspace đang chọn thay vì workspace sở hữu pane | `testTwoPanes…`, `testABurstOf…` |

`cmp` xác nhận `main.js` khôi phục byte-identical sau mỗi lần.

## Lệch so với đề bài, có chủ ý

Đề bài nói đặt fixture test trong `ShippedPluginsTests`. Chín test này nằm ở file riêng
`KanbanPluginTests.swift` — `ShippedPluginsTests` là các cổng áp cho **mọi** plugin, trộn
test riêng của một plugin vào đó sẽ làm mờ ranh giới ấy. Đây là lần thứ hai một harness
kiểu này được viết (T-036 có bản của nó, `private`); theo quy tắc "3 lần mới trích xuất"
của repo thì nhân đôi ở đây là đúng, chưa phải lúc gom lại.

## Bounds (invariant 10)

Mỗi cột chỉ render tối đa 12 dòng rồi hiện `… N more` — board này có 42 mục Done và còn
tăng. Nhãn cắt ở 160 ký tự, criteria tối đa 12 mục. Snapshot gửi cho host vì thế bị chặn
theo hằng số, không theo độ dài file.

## Notes
- Không đụng host Swift trừ khi T-040 còn thiếu seam; mục tiêu là plugin-only để chứng minh boundary đủ mạnh.
- Cột Doing có thể hiện owner/lock info nếu dòng board có — chỉ hiển thị, không parse sâu.
