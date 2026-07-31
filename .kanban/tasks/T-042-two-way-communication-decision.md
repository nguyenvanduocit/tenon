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

## Criteria
- [ ] ≥3 use case hai chiều được ghi lại và walk qua ladder từng bước trong task file
- [ ] Decision record: compose-đủ HOẶC spec primitive mới (ownership/bounds/lifecycle/policy đầy đủ)
- [ ] `docs/architecture-interaction-boundaries.md` cập nhật tương ứng (pattern hướng dẫn hoặc rung mới)
- [ ] Nếu (b): task hiện thực riêng được mở với criteria kiểm chứng được headless; task này KHÔNG code
- [ ] Không có thay đổi Swift/JS nào ship trong task này ngoài docs

## Notes
- Tham chiếu: `docs/design-intent-bus.md` §"distinguish one-way from two-way" (dòng ~111)
  và bảng so sánh "Per-verb public channels" (~995) — bus phổ quát đã bị bác có chủ đích.
- Bẫy cần tránh: đặt tên "channel" cho một thứ thực chất là EVENT có reply — đó là command
  giấu trong event, law cấm rõ.
