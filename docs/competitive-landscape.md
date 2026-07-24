# Competitive Landscape — nơi Tenon đứng trong hệ sinh thái libghostty

**Date:** 2026-07-24
**Scope:** Quét thị trường các sản phẩm "cùng concept" với Tenon (native macOS + libghostty + terminal-as-workspace, phục vụ kỷ nguyên AI coding agent), và định vị điểm khác biệt của Tenon so với chúng. Đây là tài liệu **định vị cạnh tranh**, bổ trợ cho `research-reference-terminals.md` (teardown *kỹ thuật* của kero & muxy) và `research-plugin-runtimes.md` (teardown *runtime/permission* của muxy).

**Confidence labels:** `HIGH` (nhiều nguồn độc lập khớp nhau, hoặc đọc thẳng repo), `MEDIUM` (từ snippet tìm kiếm / danh mục cộng đồng, chưa mở từng repo), `LOW` (đoán, cần verify).

---

## 0. Một phát hiện đóng khung tất cả

> **Concept nền của Tenon đã là red ocean; định vị riêng của Tenon vẫn gần như là ô trống.**

Trong ~120 dự án dựng trên libghostty (danh mục cộng đồng `awesome-libghostty`), có **~30 terminal native macOS nhắm thẳng vào AI coding agent** — tức "terminal native cho kỷ nguyên agent" **không còn là khác biệt**. Nhưng **gần như không dự án nào có plugin system thật**; và **không dự án nào** theo đuổi luận điểm đầy đủ của Tenon: *kernel tối giản + mọi feature (kể cả của chính mình) là plugin + API để LLM viết plugin phát ăn ngay + no-private-API governance*. Điều này **xác nhận VISION.md đang đặt cược đúng chỗ** — và cảnh báo rằng cửa sổ khác biệt nằm ở lớp plugin-platform, không nằm ở lớp terminal. (`HIGH` — xem §5.)

---

## 1. Phương pháp & nguồn

Quét thực hiện ngày 2026-07-24 bằng web search + fetch, KHÔNG mở từng repo (trừ muxy/kero vốn đã có trong `references/`). Nguồn xương sống là danh mục cộng đồng [`awesome-libghostty`](https://github.com/Uzaaft/awesome-libghostty) (liệt kê 120 dự án tại thời điểm quét), bổ sung bằng các bài so sánh 2026 và landing sản phẩm (xem §7).

**Cảnh báo độ tin cậy:** danh mục cộng đồng có sai sót. Ví dụ đã bắt được: awesome-libghostty ghi **Muxy "No plugin system"** — **SAI**. Repo muxy thật (trong `references/muxy`) rõ ràng có `MuxyExtensionHost` chạy JavaScriptCore, `window.muxy` API, extension npm+Vite, permissions, extension store. Khi danh mục và repo mâu thuẫn → **tin repo**. Do đó, chi tiết per-product ở đây để mức `MEDIUM` trừ khi ghi rõ khác.

---

## 2. Lớp 1 — Concept nền: đã bão hoà (`HIGH`)

"Native macOS terminal trên libghostty, lấy terminal làm trung tâm, phục vụ giám sát AI agent (worktree, sidebar repo, review diff, status agent)." Đây chính là khuôn của kero, muxy, và Tenon — và giờ có hàng chục sản phẩm cùng khuôn.

### 2.1 Terminal-workspace cho agent (trùng khớp nhất)

| Sản phẩm | Mô tả 1 dòng | Vì sao trùng Tenon/kero/muxy |
|---|---|---|
| **Supacode** | Command center open-source chạy 50+ agent song song | Được nhắc nhiều nhất; v0.10.2 (6/2026) |
| **cmux** | Terminal + vertical tabs, nhiều agent + browser nhúng | Có landing riêng, cộng đồng đang lớn |
| **Mux0** | Workspace + tab + split + live status Claude Code/Codex/OpenCode | Gần như y hệt kero |
| **Factory Floor** | Worktree + Claude Code + dev server nhúng, auto port detect | Trùng "workspace" của kero |
| **Forge** | Multiplexer cho agent song song + long-running task | |
| **TheCommander** | AI workspace native + **diff review** | Trùng đúng "review agent changes" của kero PRODUCT.md |
| **Mori / Aizen / moss / in0 / limpid / Zentty / agtmux / AiyuTerm / paulatty / moai-studio / YEN / Forjara** | Đều là "workspace terminal cho agent, multi-repo/worktree sidebar" | Cùng một khuôn, khác nhãn |

### 2.2 Orchestrator (cùng bài toán, khác hình thái — KHÔNG lấy terminal làm trung tâm)

- **Conductor** — app macOS chạy nhiều Claude Code/Codex song song, mỗi agent một git worktree.
- **Crystal → Nimbalyst** — desktop app review diff/test đa-worktree trong một cửa sổ (đã đổi tên thành Nimbalyst).
- **Vibe Kanban** — board kanban điều phối agent (Bloop đã đóng cửa đầu 2026, project vẫn open-source, community-maintained).
- **Claude Squad**, **Superset**, **Composio AO**, **Munder Difflin** — các biến thể session-manager / worktree-dispatch / hive.

**Hệ quả chiến lược:** split-pane, worktree, git sidebar, diff review, agent status → giờ là **table stakes**, không phải điểm bán. Bán Tenon bằng những thứ này = chết chìm.

---

## 3. Lớp 2 — Định vị riêng của Tenon: gần như một mình (`HIGH` cho kết luận, `MEDIUM` cho từng mục)

Trong ~120 dự án libghostty, **gần như không cái nào có plugin system thật**. Các ngoại lệ:

- **Muxy** — **đối thủ gần nhất**, nằm ngay trong `references/`. Có `window.muxy` API, extension npm+Vite, permissions, webview UI, extension store, mobile companion. **Nhưng** (đúng như VISION.md §"The landscape, honestly"): core là **native code mà extension không thay được**; extension là **bolt-on**, không phải nền móng; và **không ship TypeScript types**. → Muxy chứng minh *nhu cầu extension có thật*, nhưng bỏ ngỏ đúng ba chỗ Tenon nhắm vào (everything-is-a-plugin, no-private-API, AI-writable/types-as-contract).
- **agterm** — native macOS cho agent, có "API and CLI" — mức **scripting/automation**, không phải plugin platform thay được feature lõi.
- **hollow** — terminal Zig có **LuaJIT scripting** (nhưng không nhắm macOS; là config/scripting, không phải "feature = plugin").
- **Enso** — chỉ có **command palette** (không phải plugin system).
- Các plugin-first *ngoài* libghostty làm điểm tham chiếu authoring: **Tabby** (plugin npm, cài trong app), **Hyper** (Electron, plugin JS), **Zellij** (UI là WASM plugin — plugin-first thật nhưng là TUI, viết bằng Rust→WASM, rào cản quá cao cho kỷ nguyên AI), **WezTerm** (plugin Lua). **Raycast** là existence-proof cho mô hình authoring "tool = exported function + JSDoc + confirmation callback" — AI-writable nhất từng ship, nhưng không phải terminal và không open-source.

**Kết luận:** không ai đang làm *"kernel tối giản + mọi feature kể cả của mình đều là plugin + API để LLM viết plugin phát ăn ngay + no-private-API"*. Đây vẫn là ô trống. Muxy là hàng xóm sát vách nhưng đã lỡ xây core native cứng nên khó xoay sang mô hình này.

---

## 4. Ba kết luận chiến lược (góc cố vấn)

1. **Đừng định vị Tenon là "một agent-terminal nữa."** Sẽ chìm giữa Supacode/cmux/Mux0/Conductor. Feature terminal + agent giờ là table stakes.
2. **Moat thật = plugin platform + AI-writable API + no-private-API governance.** Đây là thứ 119/120 dự án kia *không* có và *khó* có (đa số đã lỡ xây core native cứng). Toàn bộ narrative/marketing nên dồn vào đây, không dồn vào "chạy nhiều agent".
3. **Rủi ro thời gian — category đang chín rất nhanh.** Nếu Muxy (đã có extension store + mobile + đà cộng đồng) quyết định mở công khai API và ship types, khoảng cách khác biệt của Tenon co lại nhanh. → **Phase 1 "dogfood gate"** (rebuild tab bar / status bar / file browser / git bằng *chính public SDK*) là thứ **chứng minh** moat, nên là ưu tiên số 1 — trên cả việc thêm feature terminal.

---

## 5. Độ tin cậy & caveat

- **Bức tranh tổng thể** (category bão hoà; plugin-platform trống) — `HIGH`: nhiều nguồn độc lập khớp nhau (awesome-libghostty + 3-4 bài so sánh 2026 + landing sản phẩm).
- **Chi tiết từng sản phẩm** — `MEDIUM`: đa phần từ snippet + danh mục cộng đồng, chưa mở từng repo. Một số tên có thể là project nhỏ/thử nghiệm/đã chết. Muxy "No plugin system" trong danh mục đã được chứng minh SAI — coi đây là dấu hiệu danh mục cần kiểm chứng khi dùng cho quyết định.
- **Chưa làm:** chưa mở repo/landing thật của 3-4 đối thủ sát nhất (Supacode, cmux, agterm) để so từng điểm. Đó là bước tiếp theo nếu cần bảng competitive positioning đưa vào VISION.md.

---

## 6. Nguồn

- [awesome-libghostty — danh mục 120 dự án](https://github.com/Uzaaft/awesome-libghostty)
- [Supacode](https://rywalker.com/research/supacode) · [cmux review 2026](https://vibecoding.app/blog/cmux-review) · [cmux.com](https://cmux.com/)
- [Muxy repo](https://github.com/muxy-app/muxy) · [Muxy extension store](https://muxy.app/store)
- [9 Open-Source Agent Orchestrators 2026 — Augment](https://www.augmentcode.com/tools/open-source-agent-orchestrators) · [Conductor vs Vibe Kanban vs Nimbalyst — Nimbalyst](https://nimbalyst.com/compare/nimbalyst-vs-conductor-vs-vibe-kanban/)
- [Best Terminal for AI Coding Agents 2026 — Superset](https://superset.sh/compare/best-terminal-for-ai-coding) · [Best multi-agent coding tools 2026 — agentsroom](https://agentsroom.dev/blog/best-multi-agent-coding-tools)
