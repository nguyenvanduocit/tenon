# T-040: Plugin mở tab terminal mới chạy một lệnh chỉ định
> Cho plugin yêu cầu host mở MỘT tab terminal mới và chạy một process/lệnh trong đó (vd: `claude "prompt"`), thay vì chỉ ghi vào terminal đang có như `runInTerminal` (T-015).

- **priority**: high
- **effort**: M

## Owner / files (agent lock)
session 247281cf — **DONE 04:4x, ALL LOCKS RELEASED.** Files changed (all free again):
`TenonCore/CoreIntentCatalog.swift`, `TenonApp/{TerminalIntentProvider,SurfacePool}.swift`,
`TenonCore/WorkspaceCatalogStore.swift` (one doc-comment reference to the renamed seam),
`TenonApp/TenonApp.swift` (one call-site rename only), `plugins/claude-sessions/{main.js,manifest.json}`,
`Tests/TenonCoreTests/CoreIntentCatalogTests.swift`,
`Tests/TenonAppStateTests/{TerminalIntentProviderTests,SurfaceLifecycleTests,PaneAttentionTests}.swift`
(the last two: the seam rename only), `docs/architecture-interaction-boundaries.md`.

## Why
`WorkspaceCommand.runInTerminal` (T-015) resolve terminal *đang tồn tại* trong tab active và gửi text vào đó. Use case mới: plugin cần một pane/tab **riêng, mới** chạy một agent theo prompt (vd `claude --resume <id>`, `claude "làm task T-NNN"`) — panel plugin bấm nút → mở tab mới → lệnh chạy trong PTY thật, giữ nguyên harness behavior của agent (đúng VISION: agent execution ở lại CLI/PTY owner).

## Design constraints (theo boundary law — đọc `docs/architecture-interaction-boundaries.md` trước)
- Đây là cross-principal finite work → **INTENT** (vd `terminal.open.v1` với `command`/`cwd` args, hoặc mở rộng verb hiện có), KHÔNG phải helper viết tay mới trên `tenon.*`. Manifest phải declare trong `intents.uses` (invariant 9), policy/consent fail-closed (invariant 5).
- Payload bounded (`IntentValue`): command string, cwd, tùy chọn title. Không trả native handle về plugin (invariant 2) — kết quả là bounded value (vd slot/pane id dạng chuỗi).
- Tận dụng seam sẵn có: `SurfacePool` pending-text flush (T-015) cho lệnh gửi trước khi surface materialize; T-031 lazy materialization không bị phá (tab mới được view thì mới spawn shell).
- Consent: intent này chạy process tùy ý → xếp `.policy` như `process.exec.v1` (T-021), bundled inventory có standing consent.

## Classification — written before the code (2026-07-31 04:20)

**What the tree already does, checked before designing anything.** `WorkspaceCommand` no
longer exists — it was migrated to intents by the boundary-law work, so T-015's
`runInTerminal` shape named in this task's Why is gone. Its behaviour lives in
`terminal.run.v1`, which resolves a terminal in scope, and **already creates a new tab when
there is none** (`TerminalIntentProvider.run`, `store.newTab(content: .terminal)`), then
delivers through `surfaces.sendTextWhenReady` — the T-015 pending-text flush this task
asked for is in place. So the gap is narrow and exact: *there is no way to ask for a fresh
pane when a usable terminal already exists*, and no verb returns the pane it used.

**Ordered decision law.** Reserved control operation? No. CONTRIBUTION? No — nothing
declarative is registered. EVENT? No — the caller requires a result, and a fact that
already happened cannot create a pane. RESOURCE / STREAM / TASK? No, and this is the
interesting one: a pane *does* outlive the call, but the caller does not own it. It cannot
read, cancel, or tear it down through what it gets back; the workspace owns it exactly as
it owns a pane a human opened. That is why the reply is a pane **id**, not a handle —
invariant 2, and the same reasoning T-044 recorded as *a continuation token is not a
handle*. Same-owner DIRECT? No — plugin, CLI and agent are separate principals. SCOPED
FACILITY? Closed allowlist. → **INTENT**, `terminal.open.v1`.

**Required statements.** Semantic owner: `WorkspaceStore` for the tab, `SurfacePool` for the
surface. Caller principals: programmatic `{plugin, cli, agent}`, as every other terminal
verb. Result cardinality: one reply carrying one pane id. Lifetime: the call; the pane
belongs to the workspace afterwards. Authority: **`terminal.write`, the same capability as
`terminal.run.v1`, and deliberately no more** — that verb can already create a tab and run
an arbitrary command in it, so making the fresh pane unconditional grants nothing new.
Inventing a second gate for the same power would be authority theatre. Failure semantics:
typed refusals for an unresolvable workspace scope, a tab that fails to create, and a
`workingDirectory` that is not an existing directory. Backpressure: the existing
`terminalImmediate` serial lane, where the tab-creating path already lives.

**`title` is dropped from scope, with a reason.** A terminal pane's title is owned by the
shell through OSC 0/2 (`SurfacePool.onTitleChange`), and the workspace model carries no
title field for a tab or slot. A host-set title would be overwritten by the first title
escape the command emits — `claude`, `vim` and `ssh` all send one immediately. Offering the
knob would mean shipping a parameter that silently loses, which is worse than not having it.

**`workingDirectory`, not `cwd`.** `process.exec.v1` already names this concept
`workingDirectory` with `CoreIntentSchema.path`. One name for one thing.

## Criteria
- [x] Classify trước khi code — walk ghi ở trên lúc 04:20, trước dòng code đầu tiên;
      `docs/architecture-interaction-boundaries.md` thêm `terminal.open.v1` vào bảng INTENT
      inventory và lane `terminalImmediate`
- [x] Plugin gửi intent → tab terminal **MỚI** mở, lệnh chạy trong pane đó —
      `testOpenAlwaysCreatesANewPaneEvenWhenAUsableTerminalIsInScope` dựng sẵn một terminal
      đã materialize trong scope (đúng điều kiện `terminal.run.v1` sẽ tái dùng) và đòi pane
      trả về phải khác, số tab phải tăng
- [x] Cổng declared-use + capability — **generic, không có nhánh riêng cho intent này**:
      `PluginHost.swift:926-931` nạp `manifest.intents.uses` vào policy và cổng chặn theo
      `IntentID`. Điều làm `terminal.open.v1` nằm trong cổng đó được assert bởi bảng vét cạn
      `testCapabilityInventoryAndArgumentBindingsAreExact` (`terminal.write`) và
      `testAudienceExposureProviderAndResourcePoliciesAreCoherent`. Viết thêm một cặp
      blocked/allowed riêng sẽ chỉ test lại đúng đường policy dùng chung — không phải thứ
      task này thêm vào
- [x] Lệnh gửi trước khi surface tồn tại vẫn tới nơi —
      `testOpenDeliversItsCommandToTheNewPaneOnceThatPaneMaterialises` khẳng định pane mới
      **chưa có surface** ngay sau lời gọi, rồi materialize nó và đọc đúng chuỗi ra; đồng
      thời đòi pane cũ nhận **rỗng**
- [x] Kết quả là bounded value — output schema chỉ có `paneID` dạng uuid string; không
      handle, không native type (invariant 2)
- [x] Demo trên plugin thật, không phải fixture — `claude-sessions` đổi cả "new" lẫn
      "resume" sang `terminal.open.v1`. Trước đó Resume gửi `terminal.run.v1`, tức là
      **chiếm dụng terminal đang có trong tab**: resume một phiên sẽ cướp shell người dùng
      đang làm việc, và hai phiên resume sẽ tranh nhau một pane
- [x] `swift build` exit 0 (warnings-as-errors) + full `swift test` **843 / 0** (838 trước)

## Điều tra trước khi thiết kế đã sửa chính đề bài

Task này viết `WorkspaceCommand.runInTerminal` là điểm xuất phát. **Type đó không còn tồn
tại** — nó đã được migrate sang intent trong đợt boundary-law. Hành vi của nó sống trong
`terminal.run.v1`, và verb đó **đã** tạo tab mới khi không có terminal nào, đã dùng
`sendTextWhenReady` (pending-text flush mà criteria yêu cầu). Nên khoảng trống thật hẹp và
chính xác hơn đề bài: *không có cách nào xin một pane mới khi đã sẵn một terminal dùng
được*, và không verb nào trả về pane nó đã dùng.

## Hai quyết định thu hẹp phạm vi, kèm lý do

- **`title` bị bỏ.** Tiêu đề pane terminal do shell sở hữu qua OSC 0/2
  (`SurfacePool.onTitleChange`), và model workspace không có trường title cho tab/slot. Một
  title do host đặt sẽ bị ghi đè bởi escape đầu tiên mà lệnh phát ra — `claude`, `vim`,
  `ssh` đều gửi ngay. Ship một tham số âm thầm mất tác dụng còn tệ hơn không có.
- **`workingDirectory`, không phải `cwd`.** `process.exec.v1` đã đặt tên khái niệm này là
  `workingDirectory`. Một tên cho một thứ.

## Seam được đặt lại tên, không nhân bản

`SurfacePool.seedRestoredDirectory` → **`seedSpawnDirectory`** (5 call site). Ngữ nghĩa của
nó vốn tổng quát — "pane này sẽ khởi động ở đâu, quyết trước khi có surface" — chỉ cái tên
bị buộc vào T-027. Giờ nó phục vụ cả replay lúc khôi phục lẫn `terminal.open.v1`, một
implementation cho một ngữ nghĩa (invariant 6), thay vì thêm hàm thứ hai làm cùng việc.

## Mutation proofs

| # | Mutation | Test đỏ |
|---|---|---|
| M15 | manifest khai `terminal.run.v1` trong khi JS gửi `terminal.open.v1` | `testEveryLiteralSendAndHandlerMatchesItsManifestExactly` |
| M16 | `open` tái dùng terminal trong scope thay vì luôn tạo mới | 3 test, gồm `testOpenAlwaysCreatesANewPaneEvenWhenAUsableTerminalIsInScope` |
| M17 | `workingDirectory` nhận nhưng không gieo | `testOpenStartsTheShellInTheRequestedDirectory` |
| M18 | bỏ kiểm tra thư mục tồn tại, chỉ còn kiểm tra đường dẫn tuyệt đối | `testOpenRefusesAWorkingDirectoryThatIsNotAnExistingDirectory` |

Sau mỗi lần: `cmp` xác nhận source khôi phục byte-identical.

⚠️ Ghi lại một phép đo sai của chính tôi: ban đầu tôi dùng `git diff --quiet` để xác nhận
"đã khôi phục". Phép đo đó so với HEAD, mà code của task này vốn chưa commit — nên nó luôn
báo "dirty" và không nói gì về việc mutation đã được gỡ hay chưa. `cmp` với bản backup mới
là phép đo đúng.

## Ghi chú cho test stub

`TestTerminalSurface` trước đây không ghi lại `sendText` — nó dùng default của protocol,
vốn **vứt đi**. Một test khẳng định "lệnh đã tới nơi" sẽ xanh mà chẳng có gì tới nơi. Stub
giờ ghi lại, và `SurfaceRegistry` cấp surface riêng cho từng slot để câu hỏi "pane **nào**
nhận lệnh" trả lời được.

## Notes
- Cân nhắc đặt tên theo catalog hiện có (`CoreIntentCatalog`): vd `terminal.open.v1 { command?, cwd?, title? }`.
- KHÔNG đưa execution semantics của agent vào host — host chỉ mở PTY và chạy lệnh; mọi tương tác sau đó là terminal bình thường.
