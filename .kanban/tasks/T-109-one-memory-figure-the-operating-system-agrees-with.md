# T-109: One memory figure the operating system agrees with
> The Resource Monitor reported resident size in binary units while macOS reports physical footprint in decimal ones, so every number disagreed with Activity Monitor sitting beside it.

- **priority**: high
- **effort**: S

## The defect, measured

Photographed by the user: Activity Monitor showing Tenon at **226,5 MB** while Tenon's own
monitor showed **138.3 MiB** for the same process at the same moment. Two independent causes,
measured on PID 37334:

```
ri_resident_size    155.1 MiB / 162.7 MB   <- what Tenon showed
ri_phys_footprint   368.5 MiB / 386.4 MB   <- what Activity Monitor shows
vmmap --summary 37334 -> Physical footprint: 368.5M   (Apple's own tool agrees)
```

1. **Wrong quantity.** Activity Monitor's Memory column is physical footprint — what a process
   is answerable for, including compressed pages and IOKit mappings. Resident size counts only
   what is in RAM now, so compression and swap shrink it. The direction is not even consistent:
   for the Tenon app footprint was 2.4× resident, while for the xctest process footprint was
   *smaller* (6.5 MB against 29.5 MB), because resident counts shared file-backed pages that
   footprint attributes elsewhere. The two cannot be converted into one another.
2. **Wrong units.** Tenon wrote MiB (2^20) where macOS writes MB (10^6) — a further 4.9%.

This also contradicted the app's own reasoning. PRD-016 §1 says the T-091 incident's **11 GB
physical footprint was hidden because compression and swap reduced the visible RSS**, and the
health journal records footprint for exactly that reason. The supervision surface an operator
actually watches was using the figure the PRD had already called blind.

## Criteria
- [x] The monitor's memory figure is `ri_phys_footprint`, matching Activity Monitor and `vmmap --summary`.
- [x] Sizes are written in the SI units macOS prints: 305,100,000 bytes reads `305.1 MB`.
- [x] One vocabulary in the tree — no field, local, or comment still says resident/RSS for this figure.
- [x] PRD-016 requirements and decision log state the single figure; the superseded decision is recorded as history, not left in the requirements.
- [x] Verified through the built sampler against real panes, and cross-checked against Apple's own tool.

## Evidence

`TelemetryMemoryFigureTests` (3) and `SamplerMemoryFigureTests` (1) were **red first**: the
formatter returned `291.0 MiB` for the expected `305.1 MB`, and the sampler's figure sat 3.33×
away from footprint. Full suite **1854 / 0**. Live, through the shipped formatter: `claude`
431.6 MB, `codex` 140.6 MB, 18 processes aggregating 1.2 GB — figures that now line up with
Activity Monitor instead of reading 40–60% low.

`testMemoryUsesIECUnits` was deleted rather than adapted: it pinned the behaviour this task
replaced, and `TelemetryMemoryFigureTests` covers the same ground affirmatively.

`proc_taskinfo` left `DarwinProcessSampler` entirely — `pti_resident_size` was its only caller,
and `ri_phys_footprint` arrives in the `rusage` read already being made, so the sweep now makes
one fewer syscall per process.

## Owner / files (agent lock)

Session `2c553190` — **RELEASED 2026-08-10 16:4x, holds nothing.** Not committed.

- `Sources/TenonApp/DarwinProcessSampler.swift`, `Sources/TenonApp/ResourceMonitorView.swift`
- `Sources/TenonCore/ProcessTelemetry.swift`, `ProcessTelemetrySnapshot.swift`, `ProcessTelemetryCoordinator.swift`
- `Tests/TenonCoreTests/TelemetryMemoryFigureTests.swift` (NEW), `Tests/TenonAppStateTests/SamplerMemoryFigureTests.swift` (NEW)
- `Tests/TenonCoreTests/ProcessTelemetryTests.swift`, `ProcessTelemetryCoordinatorTests.swift`, `Tests/TenonAppStateTests/TerminalProcessProjectionTests.swift`, `DiagnosticsRuntimeTests.swift`, `StallSampleCaptureTests.swift` (rename only)
- `docs/prds/diagnostics-and-resource-monitor.prd.md`, `.feature`
- `.kanban/board.md`, this file

Requirements: `DRM-FR-029`, `DRM-FR-031` (rewritten), `DRM-FR-022`, `DRM-FR-023`, `DRM-FR-033`.
