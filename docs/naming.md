# Naming Decision Record

**Final name: Tenon** — decided 2026-07-23, after two candidates were eliminated by namespace sweeps.

A tenon is the part of a timber shaped to plug into another's mortise — the most literal "plugin" metaphor available, with a story that matches the architecture: mortise-and-tenon structures use no nails and no glue, and any member can be replaced without collapsing the frame.

## Evidence for Tenon (swept 2026-07-23)

| Surface | Status |
| --- | --- |
| npm `tenon` | Taken but dormant since 2022 — legacy front-end package of tenon.io, a brand retired after the 2021 Level Access acquisition. SDK will ship scoped (e.g. `@tenon/api` or `@tenon-term/*`). |
| crates.io `tenon` | Squatted at v0.0.1 (2022), inactive. |
| PyPI `tenon` | Taken, inactive. |
| Homebrew formula + cask | **Available.** |
| GitHub top repos | Small/dormant (largest 191★, last push 2024). No active devtool in our category. |
| Mac App Store | **Zero apps named Tenon.** |
| Domains | tenon.dev / tenon.app taken; **tenon.sh available** (register immediately). |
| Trademark | Not yet checked with counsel — required before commercialization or App Store listing. |

Overall risk: **LOW–MEDIUM.** Remaining action items: register tenon.sh, claim a GitHub org (e.g. `tenon-terminal`), reserve the npm scope.

## Post-mortems

### Tessera (chosen and killed the same day, 2026-07-23)

Disqualified by `horang-labs/tessera` — an actively developed open-source macOS terminal/AI-session workspace (277★, AGPL, signed DMGs, pushed the day of the check): same category, same platform, same name. Additionally: npm/crates/PyPI/GitHub org all taken, six Mac App Store apps, every good domain gone, and at least one live USPTO Class 9 "TESSERA" software mark (Reg. 5418777; USPTO returned 403, needs attorney confirmation). Full sweep in `research-plugin-runtimes.md` §5.

### Trellis (chosen and killed the same day, 2026-07-23)

Disqualified by `mindfold-ai/Trellis` — "The best agent harness," 13,019★, active daily, same AI-developer audience — plus `microsoft/TRELLIS` + `TRELLIS.2` (13.2k★ + 8.8k★) dominating SEO, `roots/trellis` (2.6k★, active, ships its own `trellis-cli`), and npm `trellis`, `trellis-cli` (an AI-dev tool for claude-code/codex users, itself), and `create-trellis` all taken. GitHub org taken, crates/PyPI taken.

### Also swept and rejected (2026-07-23)

- **Kitbash** — npm taken the day before the sweep by an active "package manager and compiler for AI agent skills"; crates taken 2026; KitBash3D trademark adjacency.
- **Kumiko** — registries taken and the name loses search to a globally famous anime character.
- **Mycel** — crates active (v0.4.1, 2026-05), crypto-protocol residue, `psilva261/mycel` active.
- **Tatami** (runner-up) — clean-ish but the metaphor describes layout, not plugins.
- **Pegboard** (runner-up) — "Pegboard – Toolbox & Shortcuts" already ships on the Mac App Store, an adjacent utility on the target platform.

## Lessons

1. **Sweep before proposing.** Both dead names were picked from shortlists that had only been gut-checked. The sweep battery (npm, crates, PyPI, Homebrew API, GitHub search, iTunes Search API, RDAP) takes minutes and is decisive.
2. **The AI-tools gold rush is consuming names fast** — `trellis-cli` and `kitbash` were both claimed by AI-dev tools within weeks of this sweep. Real-word maker/craft vocabulary is contested territory; move quickly once a name clears.
3. **Avoid the tile/mosaic metaphor family entirely** — Zellij literally means Moroccan mosaic tilework; that semantic lane is occupied by two incumbents (Zellij, horang-labs/tessera).
