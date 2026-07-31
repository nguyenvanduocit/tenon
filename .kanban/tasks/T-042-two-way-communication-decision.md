# T-042: Giao tiếp hai chiều — quyết định có cần rung CHANNEL hay không
> Design spike + decision record: đi hết các use case hai chiều thực tế qua ladder hiện tại; hoặc chứng minh các nấc sẵn có compose đủ, hoặc specify một rung mới được classify đàng hoàng. KHÔNG mặc định là cần channel.

- **priority**: medium
- **effort**: M

## Câu hỏi gốc
Intent system chạy tốt cho request/reply hữu hạn. Nhưng giao tiếp HAI CHIỀU (plugin↔host,
plugin↔plugin, plugin↔agent đang chạy) thì sao — có cần intro một hệ thống channel không?

## Hiện trạng (đọc `docs/architecture-interaction-boundaries.md` — normative)
Hai chiều đã tồn tại ở dạng compose:
- Chiều đi: `intents.send` (finite request/reply — reply chính là chiều về của một vòng).
- Chiều về chủ động: principal khác gửi intent tới plugin qua `intents.provides`/`intents.handle` — plugin↔plugin request/reply đã có đủ hai hướng, mỗi hướng một contract khai báo trong manifest.
- Facts: `events.on` (host→plugin, publisher-owned; palette `onQuery` là EVENT owner-scoped).
- Dài hạn caller-owned: RESOURCE/STREAM (`process.stream`, `fs.watch`, timers).

Law CỐ Ý cấm duplex mở: INTENT "no unbounded lifetime", EVENT "no reply", RESOURCE "no
indefinite request held open in place of a handle". Một generic channel bypass policy path
(invariant 5) và phá bounded-everything (invariant 10) nếu làm ẩu.

## Khoảng trống nghi ngờ (điều tra từng cái, đừng gộp)
1. **Plugin không publish được EVENT** — vocabulary chỉ có `events.on`, không có `emit`.
   Plugin A muốn báo fact cho B (không phải request) hiện chỉ còn đường intent — sai semantics.
   Use case thật: plugin kanban (T-041) báo "board changed" cho plugin khác quan tâm.
2. **TASK rung chưa có hiện thực public** — công việc dài hạn có progress/cancel hai chiều
   (vd: Start một agent run từ panel, nhận tiến độ về, cancel được). Ladder đã có tên
   TASK ở nấc 3 nhưng inventory hiện tại chỉ có timers/process.stream/fs.watch.
3. **Hội thoại nhiều vòng plugin↔agent** — agent chạy trong PTY (T-040), muốn hỏi/đáp có
   cấu trúc với panel. Có thể chỉ là chuỗi intent + event, không cần pipe riêng.

## Cách làm
- Thu thập ≥3 use case hai chiều CỤ THỂ (T-041 Start→progress là một; lấy thêm từ
  claude-sessions, git, attention signals).
- Mỗi use case: chạy qua 7 câu hỏi của ladder, ghi rõ nấc nào khớp / kẹt ở đâu.
- Kết luận một trong hai:
  a. **Compose đủ** → ghi pattern chuẩn (intent-cả-hai-hướng, event, resource handle) vào
     boundary doc như hướng dẫn, đóng task, KHÔNG thêm cơ chế.
  b. **Thiếu thật** → specify rung/primitive mới (vd `events.emit` plugin-published với
     audience khai báo trong manifest, hoặc TASK handle) với đầy đủ: owner, cardinality,
     lifetime, bounds, teardown khi generation retire, policy path — sửa boundary doc
     TRƯỚC, mở task hiện thực RIÊNG sau.

## Owner / files (agent lock)
session 247281cf — **DONE 11:4x, LOCKS RELEASED.** Docs only, as the card requires:
`docs/architecture-interaction-boundaries.md`, this file, and a new
`.kanban/tasks/T-049-plugin-published-events.md`. No Swift, no JS.

## Criteria
- [x] ≥3 use cases walked through the ladder step by step — five below
- [x] Decision record — **(a) compose-enough. No new rung.** One genuine gap found, and it
      is a missing *member* on an existing rung, not a new mechanism
- [x] `docs/architecture-interaction-boundaries.md` updated — a "Two-way interaction"
      section giving the three composed patterns, and the named non-goal
- [x] Follow-up opened: **T-049**, `events.emit` for plugin-published facts, with headless
      criteria. This task ships no code
- [x] No Swift or JS changed

## Five two-way use cases, walked

Taken from work that actually shipped this session, not invented.

### UC1 — kanban publishes "board changed"; other plugins care (T-041)

**Ladder.** (1) CONTRIBUTION? No: nothing durable is registered, and the observers are not
the host. (2) EVENT? **Yes** — it is a fact that already happened, on a channel the kanban
plugin owns, whose producer exists whether or not anyone listens.

**Where it sticks.** The rung is right and the mechanism exists, but the vocabulary has only
`events.on`. A plugin can *observe* facts and cannot *publish* one. The workaround is for
the observer to declare an intent and the publisher to send it — which is wrong on two
counts: a fact has 0..n observers while an intent has exactly one provider, so the publisher
now fails when nobody is listening; and it inverts the dependency, making the publisher name
its consumers.

**Verdict:** real gap, and it is EVENT missing a member — not a new rung. → **T-049**.

### UC2 — start an agent from a panel, watch it, stop it (T-040, T-041, T-048)

**Ladder.** (3) RESOURCE/STREAM/TASK? This is the case that *looks* like it needs a handle:
work that outlives the call, with progress and cancellation.

**It composes, and the pieces are already shipped.**
- *Start* is `terminal.open.v1` → returns the pane id.
- *Progress* is `terminal.wait.v1` scoped to that pane, plus `terminal.scrollback.read.v1`
  paged — which is exactly what `tenon.agents.run` spells.
- *Cancel* is **`workspace.pane.close.v1` on that pane**, and this is the part worth
  writing down: an agent's lifetime *is* its pane's lifetime. Verified in the tree — closing
  a pane drops it from the catalog, `SurfacePool.retainOnly` releases the surface, and ARC
  runs `GhosttyNSViewResources.deinit` → `ghostty_surface_free`, taking the PTY and its child
  process with it.

So the pane id already **is** the handle. It is a bounded value, not a live object; it
survives a reload, it can be persisted, and dropping it leaks nothing. A TASK rung here
would add a second way to name work the workspace already names.

**Verdict:** composes. No gap.

### UC3 — structured question/answer between a panel and a running agent

**Ladder.** (3) STREAM? Multiple correlated values in both directions — this is the one that
sounds most like a channel.

**It is not Tenon's boundary.** The agent is a CLI in a PTY, and a PTY is bytes. Any
structure has to be a protocol *inside* those bytes — which is exactly what OSC 133 already
is, and how `terminal.wait.v1 --for command-finished` works at all. A Tenon-level duplex
channel would not help, because the agent process does not speak it; it speaks its own
stdio. Adding a rung here would give us a channel with nothing on the other end.

**Verdict:** out of scope by construction. The framing belongs to the CLI's protocol, and
Tenon's job is to carry and observe it — which it does.

### UC4 — a plugin wants to see pane attention (T-029, explicitly deferred there)

**Ladder.** (2) EVENT — a host-owned fact, published whether or not a plugin listens.

T-029 recorded this deliberately: pane attention is host-native typed state, same-owner
DIRECT today, and *"if a plugin ever needs visibility into pane attention, that is a NEW
classified EVENT."* That remains right. It needs a channel, not a mechanism: the host already
publishes events and plugins already observe them.

**Verdict:** composes. A future channel, not a future rung.

### UC5 — palette asks a plugin for results as the user types (T-006, shipped)

Included because it is the closest thing to duplex already in the tree, and it stayed inside
the ladder. Registration and results are CONTRIBUTIONs; the query is an owner-scoped EVENT.
Notably a query may be answered zero or many times and is never a held call — which is
precisely why it is not an intent. This is the worked example that a two-way *interaction*
does not imply a two-way *channel*.

## Decision: (a) compose-enough. No channel rung.

Four of five cases compose from rungs that exist. The fifth is a missing member on EVENT.

The card warned against the trap and it is worth naming: the thing people reach for when
they say "channel" is usually **an event with a reply**, which is a command wearing an
event's clothes. The law forbids it for a reason — a reply means someone must answer, which
means failure, deadline and authority semantics, which is an intent. Every case above either
had exactly one answerer (intent), or none (event), and none needed both at once.

The one case that genuinely holds state across calls — UC2 — is answered by a value, not a
handle: the pane id. That is the same shape T-044 reached for scrollback paging, where the
cursor is a value rather than a resource. Two independent cases landing on "an opaque value,
re-presented" is a pattern worth stating rather than rediscovering.

## Evidence
No build or test change: this task ships documentation. Suite unchanged at **876 / 0**.

## Notes
- Tham chiếu: `docs/design-intent-bus.md` §"distinguish one-way from two-way" (dòng ~111)
  và bảng so sánh "Per-verb public channels" (~995) — bus phổ quát đã bị bác có chủ đích.
- Bẫy cần tránh: đặt tên "channel" cho một thứ thực chất là EVENT có reply — đó là command
  giấu trong event, law cấm rõ.
