# Sleep Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two independent workspace-lifecycle actions — `Sleep` (kills a workspace's live PTYs/plugin-webviews, catalog untouched, wake is ordinary lazy re-materialization) and `Move to Background` (hides a workspace from the sidebar's main list while it keeps running) — each exposed as a public `workspace.*` intent and a sidebar context-menu action.

**Architecture:** Sleep is host-only: no `Workspace` domain-model change, implemented by narrowing the set already passed to `SurfacePool.retainOnly`/`PluginWebSurfacePool` teardown. Because the real teardown needs `PluginHost`, which `TenonApp.swift` constructs *after* `AppIntentRuntime` (`PluginHost.init` takes `intentRuntime.kernel`), the actual teardown closure is late-bound through a small mutable box (`WorkspaceSleepAction`) that both the built-in sidebar button and the `workspace.sleep.v1` intent call — one typed implementation, two callers, per invariant 6. Move to Background is an ordinary domain mutation: a new `Workspace.visibility` field, a `WorkspaceCatalog.setVisibility` mutation modeled on `removeWorkspace`'s active-handoff shape, and sidebar filtering.

**Tech Stack:** Swift 6, SwiftUI, XCTest (`swift test`), the existing `TenonIntentCore`/`TenonCore`/`TenonApp` intent-dispatch stack.

**Spec:** `docs/superpowers/specs/2026-08-20-sleep-workspace-design.md` (committed `7ac1dbd`)

## Global Constraints

- Every new source file needs a `// @domain:` tag above its imports (`docs/domains.md`); every touched existing file keeps its current tag(s) — do not add a domain to a file that does not already carry it unless the task below says so.
- `swift test` must stay green for every concurrent agent after every task — land a type before the test that names it, per this repo's shared-tree TDD rule.
- Both new intents use `audiences: programmatic` (`{plugin, cli, agent}`) and `executionLane: .workspace`, exactly like every existing `workspace.*` intent — no new audience profile, no new execution lane.
- Sleep's confirmation trigger is intentionally coarser than tab-close's off-main process inspector: it fires whenever `SurfacePool.terminalProcessSnapshot(for:).liveTerminalCount > 0` (any live, non-exited terminal surface in the workspace), not the idle-vs-running foreground-process distinction tab-close uses. This avoids adding a second off-main inspection path in this pass; flagged here so a reviewer can push back.
- Drag-to-reorder in the sidebar is scoped to the *visible* workspace list only in this pass. The translation from a visible-list destination to the underlying catalog's absolute array index is implemented and tested as its own function (Task 9) rather than left as an assumption.
- **Deviation from the committed spec, found during planning:** the spec's "Likely implementation surfaces" lists `PluginWebSurfacePool.swift` as "new call site only, no signature change." That is wrong — `reconcile(catalog:host:)` only knows how to recompute *every* workspace's live keys at once, and Sleep must dispose exactly one workspace's keys without touching any other workspace's. Task 4 adds a genuinely new method, `disposeSurfaces(forPluginViewSlots:host:)`, plus an `activeInstallations` extraction shared with `reconcile`. This is a correction, not a scope change.
- **Descoped from this pass:** the spec's Sleep flow step 4 describes a host-local, non-persisted "currently slept" marker driving a sidebar sleep indicator badge. This plan does not build it — the user's approval of the spec ("tốt") did not specifically confirm wanting the badge, and adding it correctly means either workspace-level state living somewhere that does not naturally hold it today (`SurfacePool` is slot-keyed, not workspace-keyed) or a new observable tracker wired into `SurfacePool.surface(for:)`'s materialization path. Flag this to the user; if they want it, it is a follow-on task, not a blocker for this plan's acceptance criteria (none of which depend on a visible "asleep" indicator).

---

## File Structure

New files:
- `Tests/TenonCoreTests/WorkspaceVisibilityTests.swift` — domain-level `WorkspaceCatalog.setVisibility` tests.
- `Tests/TenonAppStateTests/WorkspaceSleepActionTests.swift` — host-level Sleep teardown tests.

Modified files (grouped by task below):
- `Sources/TenonCore/Workspace.swift` — `WorkspaceVisibility`, `Workspace.visibility`, `WorkspaceEvent.workspaceVisibilityChanged`, `WorkspaceCatalog.setVisibility`.
- `Sources/TenonCore/WorkspaceStore.swift` — `setVisibility(_:to:)`.
- `Sources/TenonCore/CoreIntentName.swift` — two new cases + two switch arms.
- `Sources/TenonCore/CoreIntentRules.swift` — two new `CoreIntentRuleData.definition` entries.
- `Sources/TenonApp/WorkspaceIntentProvider.swift` — `WorkspaceSleepAction`, two new handlers/bindings, `visibilityRefused` error code.
- `Sources/TenonApp/PluginWebSurfacePool.swift` — `disposeSurfaces(forPluginViewSlots:host:)`, `activeInstallations` refactor.
- `Sources/TenonApp/TenonApp.swift` — construct `WorkspaceSleepAction`, thread into `AppIntentRuntime`, assign real `.perform` after `host` exists.
- `Sources/TenonApp/AppIntentRuntime.swift` — thread `sleepAction` through to `WorkspaceIntentProvider`.
- `Sources/TenonCore/WorkspaceCatalogStore.swift` — `WorkspaceRecord.visibility`, capture/restore helpers.
- `Sources/TenonApp/WorkspaceSidebarView.swift` — Sleep + Move to Background context-menu items, visible-only filtering + reorder-index translation, `BackgroundedWorkspacesSection`.
- `Tests/TenonCoreTests/CoreIntentCatalogTests.swift` — pinned counts, `expectedSchemaShapes()`, `expectedCapabilityIDs()`.
- `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift` — pinned count.
- `Tests/TenonAppStateTests/WorkspaceIntentProviderTests.swift` — sleep + visibility intent tests.
- `Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift` — visibility round-trip.
- `docs/prds/workspace-shell.prd.md` — new FRs, decision log.

**Interfaces every later task relies on (fixed now so no task guesses a neighbor's signature):**

```swift
// Sources/TenonCore/Workspace.swift
public enum WorkspaceVisibility: Equatable, Sendable { case visible, background }
// on Workspace: public internal(set) var visibility: WorkspaceVisibility
// on WorkspaceEvent: case workspaceVisibilityChanged(UUID)
// on WorkspaceCatalog:
@discardableResult
public mutating func setVisibility(_ id: UUID, to visibility: WorkspaceVisibility) -> [WorkspaceEvent]

// Sources/TenonCore/WorkspaceStore.swift
public func setVisibility(_ id: UUID, to visibility: WorkspaceVisibility)

// Sources/TenonCore/CoreIntentName.swift
case workspaceSleep = "workspace.sleep.v1"
case workspaceVisibilitySet = "workspace.visibility.set.v1"

// Sources/TenonApp/WorkspaceIntentProvider.swift
@MainActor
final class WorkspaceSleepAction {
    var perform: ((UUID) -> Void)?
    func callAsFunction(_ workspaceID: UUID)
}
// WorkspaceIntentProvider.init(store:normalizeCustomIcon:sleepAction:) — sleepAction defaults to WorkspaceSleepAction()

// Sources/TenonApp/PluginWebSurfacePool.swift
func disposeSurfaces(
    forPluginViewSlots slots: [(slotID: UUID, pluginID: PluginID, viewID: String)],
    host: PluginHost
)
```

---

## Task 1: `WorkspaceVisibility` domain model and `WorkspaceCatalog.setVisibility`

**Files:**
- Modify: `Sources/TenonCore/Workspace.swift`
- Test: `Tests/TenonCoreTests/WorkspaceVisibilityTests.swift` (create)

**Interfaces:**
- Produces: `WorkspaceVisibility`, `Workspace.visibility`, `WorkspaceEvent.workspaceVisibilityChanged(UUID)`, `WorkspaceCatalog.setVisibility(_:to:)` — see Global Constraints block above for exact shapes.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TenonCoreTests/WorkspaceVisibilityTests.swift`:

```swift
import Foundation
import TenonCore
import XCTest

final class WorkspaceVisibilityTests: XCTestCase {
    func testNewWorkspaceStartsVisible() {
        let catalog = WorkspaceCatalog()
        XCTAssertEqual(catalog.workspaces[0].visibility, .visible)
    }

    func testSettingBackgroundOnANonActiveWorkspaceEmitsOnlyVisibilityChanged() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let second = catalog.workspaces[1].id
        catalog.selectWorkspace(catalog.workspaces[0].id)

        let events = catalog.setVisibility(second, to: .background)

        XCTAssertEqual(events, [.workspaceVisibilityChanged(second)])
        XCTAssertEqual(catalog.workspaces.first { $0.id == second }?.visibility, .background)
        XCTAssertEqual(catalog.activeWorkspaceID, catalog.workspaces[0].id)
    }

    func testBackgroundingTheActiveWorkspaceReselectsAVisibleNeighbor() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let first = catalog.workspaces[0].id
        let second = catalog.workspaces[1].id
        catalog.selectWorkspace(first)

        let events = catalog.setVisibility(first, to: .background)

        XCTAssertEqual(catalog.activeWorkspaceID, second)
        XCTAssertTrue(events.contains(.workspaceVisibilityChanged(first)))
        XCTAssertTrue(events.contains(.workspaceSelected(second)))
        guard let tab = catalog.workspaces.first(where: { $0.id == second })?.activeTab else {
            return XCTFail("second workspace lost its active tab")
        }
        XCTAssertTrue(events.contains(.tabSelected(tab: tab.id, workspace: second)))
    }

    func testBackgroundingTheOnlyVisibleWorkspaceIsRefused() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let first = catalog.workspaces[0].id
        let second = catalog.workspaces[1].id
        _ = catalog.setVisibility(second, to: .background)

        let events = catalog.setVisibility(first, to: .background)

        XCTAssertEqual(events, [])
        XCTAssertEqual(catalog.workspaces.first { $0.id == first }?.visibility, .visible)
    }

    func testSettingVisibleOnAnAlreadyVisibleWorkspaceIsANoOp() {
        var catalog = WorkspaceCatalog()
        let id = catalog.workspaces[0].id
        XCTAssertEqual(catalog.setVisibility(id, to: .visible), [])
    }

    func testRestoringVisibilityAfterBackgroundingEmitsOnlyVisibilityChanged() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let second = catalog.workspaces[1].id
        _ = catalog.setVisibility(second, to: .background)

        let events = catalog.setVisibility(second, to: .visible)

        XCTAssertEqual(events, [.workspaceVisibilityChanged(second)])
        XCTAssertEqual(catalog.workspaces.first { $0.id == second }?.visibility, .visible)
    }

    func testSettingVisibilityOnAnUnknownWorkspaceIsANoOp() {
        var catalog = WorkspaceCatalog()
        XCTAssertEqual(catalog.setVisibility(UUID(), to: .background), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails to compile**

Run: `swift test --filter WorkspaceVisibilityTests`
Expected: build failure — `WorkspaceVisibility`, `.visibility`, `.workspaceVisibilityChanged`, and `setVisibility` do not exist yet.

- [ ] **Step 3: Add `WorkspaceVisibility` and the `visibility` field**

In `Sources/TenonCore/Workspace.swift`, add right before `public struct Workspace`:

```swift
/// Whether a workspace appears in the sidebar's main catalog list. `.background` keeps
/// every live resource running — it is a list-membership fact, never a resource action.
/// Sleep, which does free resources, has no domain-model state at all (see `SurfacePool`).
public enum WorkspaceVisibility: Equatable, Sendable {
    case visible
    case background
}
```

Add the stored property and thread it through both initializers:

```swift
public struct Workspace: Equatable, Identifiable, Sendable {
    public let id: UUID
    public internal(set) var name: String
    public internal(set) var path: URL
    public internal(set) var appearance: WorkspaceAppearance
    /// Whether this workspace appears in the sidebar's main list. See `WorkspaceVisibility`.
    public internal(set) var visibility: WorkspaceVisibility
    public internal(set) var tabs: [Tab]
    public internal(set) var activeTabID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        appearance: WorkspaceAppearance = .default,
        visibility: WorkspaceVisibility = .visible,
        tabs: [Tab],
        activeTabID: UUID
    ) {
        precondition(
            Self.isValid(tabs: tabs, activeTabID: activeTabID),
            "workspace tabs and slots must have unique identities and valid selection"
        )

        self.id = id
        self.name = name
        self.path = path
        self.appearance = appearance
        self.visibility = visibility
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    public init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        appearance: WorkspaceAppearance = .default,
        visibility: WorkspaceVisibility = .visible,
        content: SlotContent = .terminal,
        sizing: NewPaneSizing = .unlimited
    ) {
        let tab = Tab(content: content, sizing: sizing)
        self.init(
            id: id,
            name: name,
            path: path,
            appearance: appearance,
            visibility: visibility,
            tabs: [tab],
            activeTabID: tab.id
        )
    }
    // ... rest of the type is unchanged
```

- [ ] **Step 4: Add the event case**

In `WorkspaceEvent`, add next to `workspaceIdentityChanged`:

```swift
    /// A workspace's sidebar visibility changed. Its tabs, panes, and live resources are
    /// untouched — this is the same shape as `workspaceIdentityChanged`, one level over.
    case workspaceVisibilityChanged(UUID)
```

- [ ] **Step 5: Add `WorkspaceCatalog.setVisibility`**

In `WorkspaceCatalog`, add right after `resetWorkspaceIdentity` (before `selectWorkspace`):

```swift
    /// Shows or hides a workspace in the sidebar's main list without touching any of its
    /// live resources. At least one `.visible` workspace must remain — mirrors
    /// `removeWorkspace`'s guard — and backgrounding the active workspace reselects a
    /// neighbor exactly like `removeWorkspace` does, because the single main window always
    /// needs a visible workspace to show (`WS-A-001`).
    @discardableResult
    public mutating func setVisibility(
        _ id: UUID,
        to visibility: WorkspaceVisibility
    ) -> [WorkspaceEvent] {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].visibility != visibility
        else { return [] }

        if visibility == .background {
            let remainingVisible = workspaces.contains {
                $0.id != id && $0.visibility == .visible
            }
            guard remainingVisible else { return [] }
        }

        workspaces[index].visibility = visibility
        var events: [WorkspaceEvent] = [.workspaceVisibilityChanged(id)]

        if visibility == .background, activeWorkspaceID == id,
           let neighbor = workspaces.first(where: { $0.visibility == .visible && $0.id != id })
        {
            activeWorkspaceID = neighbor.id
            events.append(.workspaceSelected(neighbor.id))
            if let tab = neighbor.activeTab {
                events.append(.tabSelected(tab: tab.id, workspace: neighbor.id))
                if let slotID = tab.activeSlotID {
                    events.append(.slotFocused(slot: slotID, tab: tab.id, workspace: neighbor.id))
                }
            }
        }

        return events
    }
```

- [ ] **Step 6: Run to verify the tests pass**

Run: `swift test --filter WorkspaceVisibilityTests`
Expected: all 7 tests PASS.

- [ ] **Step 7: Run the full core suite for regressions**

Run: `swift test --filter TenonCoreTests`
Expected: PASS (adding a defaulted field to two `Workspace` initializers must not break any existing literal-argument call site).

- [ ] **Step 8: Commit**

```bash
git add Sources/TenonCore/Workspace.swift Tests/TenonCoreTests/WorkspaceVisibilityTests.swift
git commit -m "feat(workspace-model): add Workspace.visibility and setVisibility"
```

---

## Task 2: `WorkspaceStore.setVisibility`

**Files:**
- Modify: `Sources/TenonCore/WorkspaceStore.swift`

**Interfaces:**
- Consumes: `WorkspaceCatalog.setVisibility(_:to:)` (Task 1).
- Produces: `WorkspaceStore.setVisibility(_:to:)`.

- [ ] **Step 1: Add the method**

In `Sources/TenonCore/WorkspaceStore.swift`, add right after `resetWorkspaceIdentity`:

```swift
    /// Shows or hides a workspace in the sidebar's main list. The workspace's tabs, panes,
    /// and live resources are never touched by this call — only `Workspace.visibility`
    /// changes, exactly like `setWorkspaceAppearance` changes only presentation.
    public func setVisibility(_ id: UUID, to visibility: WorkspaceVisibility) {
        apply { $0.setVisibility(id, to: visibility) }
    }
```

- [ ] **Step 2: Write the failing test**

Add to a new test group in `Tests/TenonCoreTests/WorkspaceVisibilityTests.swift` (append below the existing tests, same file):

```swift
    func testStoreSetVisibilityAppliesThroughTheCatalogAndPublishesEvents() {
        let store = WorkspaceStore()
        var published: [WorkspaceEvent] = []
        store.onEvents = { events, _ in published = events }
        store.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let second = store.catalog.workspaces[1].id

        store.setVisibility(second, to: .background)

        XCTAssertEqual(store.catalog.workspaces.first { $0.id == second }?.visibility, .background)
        XCTAssertEqual(published, [.workspaceVisibilityChanged(second)])
    }
```

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `swift test --filter WorkspaceVisibilityTests`
Expected: fails to compile before Step 1 lands (already landed above, so this is a green-from-the-start check) — run once, confirm PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/TenonCore/WorkspaceStore.swift Tests/TenonCoreTests/WorkspaceVisibilityTests.swift
git commit -m "feat(workspace-model): expose WorkspaceStore.setVisibility"
```

---

## Task 3: Register `workspace.sleep.v1` and `workspace.visibility.set.v1` in the intent catalog

This is the biggest bookkeeping task: `CoreIntentName.allCases` order must exactly match `CoreIntentRules.makeDefinitions`'s returned array order (`testInventoryIsCompleteUniqueVersionedAndFreeOfLegacyNames` asserts `actualNames == expectedNames`), and four places pin the exact case count (`51`).

**Files:**
- Modify: `Sources/TenonCore/CoreIntentName.swift`
- Modify: `Sources/TenonCore/CoreIntentRules.swift`
- Modify: `Tests/TenonCoreTests/CoreIntentCatalogTests.swift`
- Modify: `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`

**Interfaces:**
- Produces: `CoreIntentName.workspaceSleep`, `CoreIntentName.workspaceVisibilitySet`, both `.programmatic` audience / `.workspace` execution lane, both installed with `capability: "workspace.control"`.

- [ ] **Step 1: Add the two new cases**

In `Sources/TenonCore/CoreIntentName.swift`, insert right after `case workspaceSelect = "workspace.select.v1"` (line 57) and before `case networkFetch = "network.fetch.v1"`:

```swift
    case workspaceSleep = "workspace.sleep.v1"
    case workspaceVisibilitySet = "workspace.visibility.set.v1"
```

- [ ] **Step 2: Add both to the `.programmatic` audience arm**

In `audienceProfile`, add `.workspaceSleep, .workspaceVisibilitySet,` to the `case .filesystemDirectoryList, ... .workspaceSelect, ...` list, right after `.workspaceSelect,` and before `.networkFetch,`.

- [ ] **Step 3: Add both to the `.workspace` execution-lane arm**

In `executionLane`, add `.workspaceSleep, .workspaceVisibilitySet,` right after `.workspaceSelect:` and before `.workspace` (i.e. inside the same `case ... .workspaceSelect:` list that resolves to `.workspace`).

- [ ] **Step 4: Run to verify the exhaustive switches still compile and the inventory-mismatch guard trips**

Run: `swift build`
Expected: builds (both switches are exhaustive over `CoreIntentName`, so the new cases must be listed or the build fails — this is the trip-wire).

Run: `swift test --filter CoreIntentCatalogTests`
Expected: several failures — `testConcurrentInstallCompilesIntoAuthoritativeKernelExactlyOnce` and every test asserting `CoreIntentName.allCases.count == 51` now sees `53` and `installCatalog` throws `inventoryMismatch` because `CoreIntentRules.makeDefinitions` has not grown yet.

- [ ] **Step 5: Add the two definitions to `CoreIntentRules.makeDefinitions`**

In `Sources/TenonCore/CoreIntentRules.swift`, insert right after the `.workspaceSelect` definition block ends (`),` closing it) and before the `.networkFetch` definition begins:

```swift
            try CoreIntentRuleData.definition(
                .workspaceSleep,
                title: "Sleep workspace",
                description: """
                Releases every live terminal and plugin-webview resource owned by the \
                workspace identified by invocation scope, leaving its tabs, panes, and \
                layout untouched. Reopening any of its panes materializes a fresh \
                resource, exactly like restoring a workspace after relaunch.
                """,
                input: emptyInput,
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(
                    .destructive,
                    confirmation: .policy
                ),
                errors: ["dev.tenon.core.workspace-not-found"],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
            try CoreIntentRuleData.definition(
                .workspaceVisibilitySet,
                title: "Set workspace visibility",
                description: """
                Shows or hides the workspace identified by invocation scope in the \
                sidebar's main catalog list. A hidden workspace keeps every live \
                resource running unchanged; at least one workspace must remain visible.
                """,
                input: CoreIntentSchema.root(
                    properties: [
                        "visibility": CoreIntentSchema.string(
                            enumValues: ["visible", "background"]
                        )
                    ],
                    required: ["visibility"]
                ),
                output: emptyOutput,
                audiences: programmatic,
                exposure: programmaticExposure,
                effects: try CoreIntentRuleData.effects(.write),
                errors: [
                    "dev.tenon.core.workspace-not-found",
                    "dev.tenon.core.visibility-refused",
                ],
                bindings: [workspaceControl],
                admission: .interactive,
                timeout: .seconds(10),
                trustedProviderID: trustedProviderID
            ),
```

- [ ] **Step 6: Update the four pinned counts**

In `Tests/TenonCoreTests/CoreIntentCatalogTests.swift`:
- Line 68: `XCTAssertEqual(Set(actualNames).count, 51)` → `53`
- Line 69: `XCTAssertEqual(actualNames.count, 51)` → `53`
- Line 932, add a log line and bump:

```swift
        // 50 → 51 (T-154): one finite identity patch exposes the workspace name, colour,
        // and icon that the native form already owns, on the existing workspace lane.
        // 51 → 53 (Sleep Workspace): workspace.sleep.v1 releases live resources without a
        // domain mutation; workspace.visibility.set.v1 shows/hides in the sidebar. Both on
        // the existing workspace lane.
        XCTAssertEqual(CoreIntentName.allCases.count, 53)
```

In `Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift`, line 48, same bump with the same comment convention:

```swift
        // 50 → 51 (T-154): workspace identity, one request/reply on that same lane.
        // 51 → 53 (Sleep Workspace): two new intents on the existing workspace lane.
        XCTAssertEqual(CoreIntentName.allCases.count, 53)
```

- [ ] **Step 7: Add both intents to `expectedSchemaShapes()`**

In `Tests/TenonCoreTests/CoreIntentCatalogTests.swift`, right after `.workspaceSelect: emptyShape(),` and before `.networkFetch: SchemaShape(...)`:

```swift
            .workspaceSleep: emptyShape(),
            .workspaceVisibilitySet: SchemaShape(
                ["visibility"],
                required: ["visibility"],
                output: [],
                requiredOutput: []
            ),
```

- [ ] **Step 8: Add both intents to `expectedCapabilityIDs()`**

Right after `.workspaceSelect: ["workspace.control"],` and before `.networkFetch: ["network"],`:

```swift
            .workspaceSleep: ["workspace.control"],
            .workspaceVisibilitySet: ["workspace.control"],
```

- [ ] **Step 9: Run the full catalog and fitness suites**

Run: `swift test --filter CoreIntentCatalogTests`
Run: `swift test --filter InteractionBoundaryFitnessTests`
Expected: both PASS. If `testInventoryIsCompleteUniqueVersionedAndFreeOfLegacyNames` fails on ordering, the two new `CoreIntentRuleData.definition` calls are not in the same relative position as the two new `CoreIntentName` cases — fix the ordering in `CoreIntentRules.swift` to match.

- [ ] **Step 10: Commit**

```bash
git add Sources/TenonCore/CoreIntentName.swift Sources/TenonCore/CoreIntentRules.swift \
  Tests/TenonCoreTests/CoreIntentCatalogTests.swift Tests/TenonCoreTests/InteractionBoundaryFitnessTests.swift
git commit -m "feat(intent-bus): register workspace.sleep.v1 and workspace.visibility.set.v1"
```

---

## Task 4: `PluginWebSurfacePool.disposeSurfaces(forPluginViewSlots:host:)`

Sleep must dispose exactly the web surfaces owned by one workspace's `pluginView` slots, without recomputing (or disturbing) every other workspace's live keys the way `reconcile` does.

**Files:**
- Modify: `Sources/TenonApp/PluginWebSurfacePool.swift`
- Test: `Tests/TenonAppStateTests/PluginWebSurfacePoolTests.swift` (existing file — add to it)

**Interfaces:**
- Produces: `PluginWebSurfacePool.disposeSurfaces(forPluginViewSlots:host:)`.

- [ ] **Step 1: Extract the shared `activeInstallations` helper**

In `Sources/TenonApp/PluginWebSurfacePool.swift`, add this `private static` helper inside the `private extension PluginWebSurfacePool` block (near `webSurfaceIDs`):

```swift
    static func activeInstallations(
        in host: PluginHost
    ) -> [PluginID: PluginInstallationKey] {
        Dictionary(
            uniqueKeysWithValues: host.plugins.compactMap {
                plugin -> (PluginID, PluginInstallationKey)? in
                guard plugin.isEnabled,
                      plugin.isLoaded,
                      plugin.permissions.contains("web.view"),
                      let installationID = plugin.installationID
                else {
                    return nil
                }
                return (
                    plugin.id,
                    PluginInstallationKey(
                        pluginID: plugin.id,
                        installationID: installationID
                    )
                )
            }
        )
    }
```

Replace `reconcile`'s inline `active` computation (the `let active = Dictionary(uniqueKeysWithValues: host.plugins.compactMap { ... })` block) with:

```swift
        let active = Self.activeInstallations(in: host)
```

- [ ] **Step 2: Write the failing test**

Read `Tests/TenonAppStateTests/PluginWebSurfacePoolTests.swift` first to match its existing fixture-building helpers (plugin snapshot construction, `PluginHost` test double). Add:

```swift
    func testDisposeSurfacesForPluginViewSlotsReleasesOnlyTheNamedSlotsWebviews() {
        // Arrange: a PluginHost with one enabled web-view plugin exposing a view whose
        // body contains one .webview node, and two pluginView slots (A, B) both bound to
        // that same view id but different slot UUIDs — mirrors two panes showing the same
        // plugin view, which is the case `reconcile` already exercises elsewhere in this
        // file. Materialize surfaces for both via `pool.surface(for:)`, then call
        // `disposeSurfaces(forPluginViewSlots: [slotA], host: host)`.
        //
        // Assert: slotA's WebSurfaceKey is gone from `pool.existingSurface(for:)`, slotB's
        // is still present.
    }
```

Fill in the arrange/act/assert using the exact fixture-construction pattern already used by this file's other tests (e.g. its existing `reconcile` test) — copy that fixture's plugin/host/view-body construction verbatim rather than inventing a new one, so the two tests stay consistent with each other.

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter PluginWebSurfacePoolTests`
Expected: FAIL — `disposeSurfaces(forPluginViewSlots:host:)` does not exist.

- [ ] **Step 4: Add the method**

In `Sources/TenonApp/PluginWebSurfacePool.swift`, add right after `retainOnly`:

```swift
    /// Disposes exactly the web surfaces owned by the given pluginView slots, for
    /// `workspace.sleep.v1` — which must release one workspace's webviews without
    /// recomputing or touching any other workspace's live keys the way `reconcile` does.
    func disposeSurfaces(
        forPluginViewSlots slots: [(slotID: UUID, pluginID: PluginID, viewID: String)],
        host: PluginHost
    ) {
        let active = Self.activeInstallations(in: host)
        for slot in slots {
            guard let installation = active[slot.pluginID],
                  let section = host.pluginViews.first(where: {
                      $0.pluginID == slot.pluginID
                          && $0.viewID == slot.viewID
                          && (
                              $0.instanceID == nil
                                  || $0.instanceID == slot.slotID.uuidString
                          )
                  }),
                  let body = section.body
            else { continue }
            for surfaceID in Self.webSurfaceIDs(in: body) {
                dispose(WebSurfaceKey(installation: installation, surfaceID: surfaceID))
            }
        }
    }
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter PluginWebSurfacePoolTests`
Expected: PASS, including the pre-existing `reconcile` tests (proves the `activeInstallations` extraction changed nothing observable).

- [ ] **Step 6: Commit**

```bash
git add Sources/TenonApp/PluginWebSurfacePool.swift Tests/TenonAppStateTests/PluginWebSurfacePoolTests.swift
git commit -m "feat(plugin-web-surface): add disposeSurfaces for one workspace's plugin panes"
```

---

## Task 5: `WorkspaceSleepAction` and the `workspace.sleep.v1` / `workspace.visibility.set.v1` handlers

**Files:**
- Modify: `Sources/TenonApp/WorkspaceIntentProvider.swift`
- Test: `Tests/TenonAppStateTests/WorkspaceIntentProviderTests.swift`

**Interfaces:**
- Consumes: `WorkspaceStore.setVisibility` (Task 2), `CoreIntentName.workspaceSleep`/`.workspaceVisibilitySet` (Task 3).
- Produces: `WorkspaceSleepAction` (see Global Constraints), `WorkspaceIntentProvider.init(store:normalizeCustomIcon:sleepAction:)` with `sleepAction` defaulted.

- [ ] **Step 1: Write the failing tests**

Read the existing test setup in `Tests/TenonAppStateTests/WorkspaceIntentProviderTests.swift` (how it builds `store`, resolves `envelope.scope`, invokes a binding) and match its exact fixture style. Add:

```swift
    func testWorkspaceSleepCallsSleepActionWithTheScopedWorkspaceID() throws {
        let store = WorkspaceStore()
        let sleepAction = WorkspaceSleepAction()
        var invoked: UUID?
        sleepAction.perform = { invoked = $0 }
        let bindings = try WorkspaceIntentProvider(store: store, sleepAction: sleepAction)
            .bindings()
        let binding = try XCTUnwrap(
            bindings.first { $0.intentID == (try CoreIntentName.workspaceSleep.intentID) }
        )

        let reply = try runSync(binding.handler(
            IntentEnvelope(
                input: .object([:]),
                scope: InvocationScope(workspaceID: store.catalog.activeWorkspaceID)
            ),
            /* context matching this file's existing pattern */
        ))

        XCTAssertEqual(invoked, store.catalog.activeWorkspaceID)
        XCTAssertTrue(reply.isSuccess) // match this file's existing success-assertion helper
    }

    func testWorkspaceSleepOnUnknownWorkspaceFails() throws {
        // Same shape as above, scope.workspaceID = UUID(), assert workspace-not-found
        // failure and that sleepAction.perform is never invoked.
    }

    func testWorkspaceVisibilitySetBackgroundsAndRestoresAWorkspace() throws {
        let store = WorkspaceStore()
        store.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let second = store.catalog.workspaces[1].id
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let binding = try XCTUnwrap(
            bindings.first { $0.intentID == (try CoreIntentName.workspaceVisibilitySet.intentID) }
        )

        let reply = try runSync(binding.handler(
            IntentEnvelope(
                input: .object(["visibility": .string("background")]),
                scope: InvocationScope(workspaceID: second)
            ),
            /* context */
        ))

        XCTAssertTrue(reply.isSuccess)
        XCTAssertEqual(store.catalog.workspaces.first { $0.id == second }?.visibility, .background)
    }

    func testWorkspaceVisibilitySetRefusesTheLastVisibleWorkspace() throws {
        let store = WorkspaceStore()
        store.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let first = store.catalog.workspaces[0].id
        let second = store.catalog.workspaces[1].id
        store.setVisibility(second, to: .background)
        let bindings = try WorkspaceIntentProvider(store: store).bindings()
        let binding = try XCTUnwrap(
            bindings.first { $0.intentID == (try CoreIntentName.workspaceVisibilitySet.intentID) }
        )

        let reply = try runSync(binding.handler(
            IntentEnvelope(
                input: .object(["visibility": .string("background")]),
                scope: InvocationScope(workspaceID: first)
            ),
            /* context */
        ))

        // assert failure with codes matching "dev.tenon.core.visibility-refused" per this
        // file's existing failure-assertion helper
        XCTAssertEqual(store.catalog.workspaces.first { $0.id == first }?.visibility, .visible)
    }

    func testWorkspaceVisibilitySetRejectsAnInvalidEnumValue() throws {
        // input .object(["visibility": .string("hidden")]) → invalidInput, matching this
        // file's existing "invalid field" assertion pattern.
    }
```

Adapt the exact `IntentEnvelope`/`context`/reply-assertion plumbing to whatever this test file's *existing* sleep-adjacent tests (e.g. `testWorkspaceSelect...` or `testWorkspaceTabClose...`) already use — do not invent a different calling convention.

- [ ] **Step 2: Run to verify they fail to compile**

Run: `swift test --filter WorkspaceIntentProviderTests`
Expected: build failure — `WorkspaceSleepAction`, the `sleepAction:` init parameter, and both handlers do not exist yet.

- [ ] **Step 3: Add `WorkspaceSleepAction`**

In `Sources/TenonApp/WorkspaceIntentProvider.swift`, add above `final class WorkspaceIntentProvider`:

```swift
/// The one typed implementation `workspace.sleep.v1` and the sidebar's Sleep button both
/// call (invariant 6 forbids two protocols for one operation).
///
/// Late-bound because the real teardown needs `PluginHost`, which `TenonApp.swift`
/// constructs *after* `AppIntentRuntime` — `PluginHost.init` takes `intentRuntime.kernel`,
/// so `PluginHost` cannot exist yet at the point this provider is built. `perform` is `nil`
/// until composition assigns it once every dependency exists; every call before that (and
/// every test that never assigns `perform`) is a safe no-op.
@MainActor
final class WorkspaceSleepAction {
    var perform: ((UUID) -> Void)?

    func callAsFunction(_ workspaceID: UUID) {
        perform?(workspaceID)
    }
}
```

- [ ] **Step 4: Thread `sleepAction` through `init` and add the `visibilityRefused` error code**

In `WorkspaceIntentProvider.ErrorCodes`, add:

```swift
        let visibilityRefused: IntentErrorCode
```

and in its `init`:

```swift
            visibilityRefused = .domain(
                try IntentDomainErrorCode(
                    "dev.tenon.core.visibility-refused"
                )
            )
```

Change the class's stored properties and `init`:

```swift
    private let store: WorkspaceStore
    private let codes: ErrorCodes
    private let normalizeCustomIcon: CustomIconNormalizer
    private let sleepAction: WorkspaceSleepAction

    init(
        store: WorkspaceStore,
        normalizeCustomIcon: @escaping CustomIconNormalizer = {
            try await WorkspaceCustomIconImport.icon(from: $0)
        },
        sleepAction: WorkspaceSleepAction = WorkspaceSleepAction()
    ) throws {
        self.store = store
        self.normalizeCustomIcon = normalizeCustomIcon
        self.sleepAction = sleepAction
        codes = try ErrorCodes()
    }
```

- [ ] **Step 5: Add both bindings**

In `bindings()`, add right after the `workspaceSelect` binding:

```swift
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceSleep.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return self.sleepWorkspace(envelope: envelope)
            },
            IntentProviderBinding(
                intentID: try CoreIntentName.workspaceVisibilitySet.intentID
            ) { envelope, context in
                try context.checkCancellation()
                return try await self.setWorkspaceVisibility(envelope: envelope)
            },
```

- [ ] **Step 6: Add both handlers**

In the `private extension WorkspaceIntentProvider` block, add right after `selectWorkspace`:

```swift
    /// `workspace.sleep.v1` — the public adapter over `WorkspaceSleepAction`, the same
    /// typed action the sidebar's Sleep button calls DIRECT. Handles the active-workspace
    /// handoff itself, so both callers get it for free instead of one of them forgetting it.
    func sleepWorkspace(envelope: IntentEnvelope) -> IntentProviderReply {
        guard envelope.input == .object([:]) else {
            return AppIntentProviderSupport.invalidInput(.expectedObject)
        }
        guard let workspaceID = envelope.scope.workspaceID,
              store.catalog.workspaces.contains(where: { $0.id == workspaceID })
        else {
            return failure(codes.workspaceNotFound, reason: "workspace-scope-not-found")
        }
        sleepAction(workspaceID)
        return AppIntentProviderSupport.emptySuccess
    }

    /// `workspace.visibility.set.v1` — the public adapter over `WorkspaceStore.setVisibility`.
    func setWorkspaceVisibility(
        envelope: IntentEnvelope
    ) async throws -> IntentProviderReply {
        do {
            let object = try AppIntentProviderSupport.object(envelope.input)
            let value = try AppIntentProviderSupport.string("visibility", in: object)
            let visibility: WorkspaceVisibility
            switch value {
            case "visible":
                visibility = .visible
            case "background":
                visibility = .background
            default:
                throw AppIntentInputError.missingOrInvalidField("visibility")
            }
            guard let workspaceID = envelope.scope.workspaceID,
                  store.catalog.workspaces.contains(where: { $0.id == workspaceID })
            else {
                return failure(codes.workspaceNotFound, reason: "workspace-scope-not-found")
            }
            store.setVisibility(workspaceID, to: visibility)
            guard store.catalog.workspaces.first(where: { $0.id == workspaceID })?.visibility
                == visibility
            else {
                return failure(codes.visibilityRefused, reason: "visibility-change-refused")
            }
            return AppIntentProviderSupport.emptySuccess
        } catch let error as AppIntentInputError {
            return AppIntentProviderSupport.invalidInput(error)
        } catch {
            return AppIntentProviderSupport.invalidInput(
                .missingOrInvalidField("$")
            )
        }
    }
```

Note: `sleepWorkspace` currently does **not** perform the active-workspace handoff yet — that lands in Task 6 as part of `WorkspaceSleepAction.perform`'s real body, so it is shared by both the intent and the sidebar button rather than duplicated. This handler only validates scope and calls the shared action.

- [ ] **Step 7: Run to verify the tests pass**

Run: `swift test --filter WorkspaceIntentProviderTests`
Expected: all 5 new tests PASS; every pre-existing test in this file still PASSES (the two new `init` parameters both default, so no existing `WorkspaceIntentProvider(store: store)` call site needed a change).

- [ ] **Step 8: Run the full catalog suite once more**

Run: `swift test --filter CoreIntentCatalogTests`
Expected: PASS — confirms the two handlers' input/output shapes match what Task 3 declared.

- [ ] **Step 9: Commit**

```bash
git add Sources/TenonApp/WorkspaceIntentProvider.swift Tests/TenonAppStateTests/WorkspaceIntentProviderTests.swift
git commit -m "feat(workspace-intents): add workspace.sleep.v1 and workspace.visibility.set.v1 handlers"
```

---

## Task 6: Wire the real Sleep teardown in `TenonApp.swift`

This is where `WorkspaceSleepAction.perform` gets its real body — the only place in the tree where `store`, `terminalSurfaces`, `webSurfaces`, and `host` are all available together, and where the active-workspace handoff actually happens (shared by both the sidebar button and the intent).

**Files:**
- Modify: `Sources/TenonApp/AppIntentRuntime.swift`
- Modify: `Sources/TenonApp/TenonApp.swift`
- Test: `Tests/TenonAppStateTests/WorkspaceSleepActionTests.swift` (create)

**Interfaces:**
- Consumes: `WorkspaceSleepAction` (Task 5), `PluginWebSurfacePool.disposeSurfaces` (Task 4), `SurfacePool.retainOnly` (existing), `WorkspaceCatalog.pluginViewSlots`/`.allSlotIDs` (existing).
- Produces: a real, testable teardown closure assigned to `sleepAction.perform`.

- [ ] **Step 1: Thread `sleepAction` through `AppIntentRuntime`**

In `Sources/TenonApp/AppIntentRuntime.swift`, add a parameter to `init` (defaulted, so the four snapshot-tool call sites need no change):

```swift
    init(
        kernel: IntentKernelComponents,
        workspaceStore: WorkspaceStore,
        terminalSurfaces: SurfacePool,
        webSurfaces: PluginWebSurfacePool,
        userInterface: PluginUIState,
        agentQuestions: AgentAskStore = AgentAskStore(),
        sleepAction: WorkspaceSleepAction = WorkspaceSleepAction()
    ) throws {
        ...
        collected.append(
            contentsOf: try WorkspaceIntentProvider(
                store: workspaceStore,
                sleepAction: sleepAction
            ).bindings()
        )
        ...
```

- [ ] **Step 2: Write the failing host-level test**

Read `Tests/TenonAppStateTests/PluginWebSurfacePoolTests.swift`'s and `WorkspaceIntentProviderTests.swift`'s fixture-construction helpers first (how a real `SurfacePool` with a stub terminal backend and a real `PluginHost` over a temp plugin inventory get built elsewhere in this test target — several existing tests already do this for other host-level features). Create `Tests/TenonAppStateTests/WorkspaceSleepActionTests.swift` following that same fixture pattern:

```swift
    func testSleepingAWorkspaceReleasesOnlyItsOwnTerminalSurfaces() {
        // Arrange: a WorkspaceStore with two workspaces, each holding one terminal pane.
        // Materialize both via pool.surface(for:workspacePath:) so hasEverBeenViewed is
        // true for both. Wire sleepAction.perform with the Task 6 closure (Step 3 below),
        // over a PluginHost with no plugins installed (webSurfaces teardown is then a
        // no-op, isolating this test to the terminal half).
        //
        // Act: sleepAction(firstWorkspaceID)
        //
        // Assert: pool.hasEverBeenViewed(firstWorkspaceSlotID) == false,
        //         pool.hasEverBeenViewed(secondWorkspaceSlotID) == true
    }

    func testSleepingTheActiveWorkspaceSwitchesActiveFirst() {
        // Arrange: two workspaces, first is active.
        // Act: sleepAction(firstWorkspaceID)
        // Assert: store.catalog.activeWorkspaceID == secondWorkspaceID
    }

    func testSleepingTheOnlyWorkspaceLeavesActiveUnchanged() {
        // Arrange: one workspace only.
        // Act: sleepAction(onlyWorkspaceID)
        // Assert: store.catalog.activeWorkspaceID unchanged, and the terminal surface for
        // its pane was still released (sleep does not require a second workspace to exist —
        // there is simply no neighbor to hand off to).
    }
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter WorkspaceSleepActionTests`
Expected: FAIL — `sleepAction.perform` is never assigned in this test's fixture yet (Step 2's fixture wires it using the exact closure this step writes into production, so write the fixture calling a not-yet-existing helper, or inline the closure literally as written in Step 4 into the test fixture, then move it — whichever this test target's convention already uses for "share one closure between test and production." If no such precedent exists in this file's neighbors, inline the same closure body directly into both the test fixture and `TenonApp.swift`, matching them by contract (documented in-repo as `WorkspaceSleepAction`'s intended body) rather than by shared code, since `TenonApp.swift`'s `prepare` is not itself unit-testable.

- [ ] **Step 4: Write the real teardown closure in `TenonApp.swift`**

In `Sources/TenonApp/TenonApp.swift`, before the `let intentRuntime = try AppIntentRuntime(` call (around line 603), add:

```swift
        let sleepAction = WorkspaceSleepAction()
```

Change the `AppIntentRuntime(...)` call to pass it:

```swift
        let intentRuntime = try AppIntentRuntime(
            kernel: prepared.kernel,
            workspaceStore: store,
            terminalSurfaces: terminalSurfaces,
            webSurfaces: webSurfaces,
            userInterface: userInterface,
            agentQuestions: agentQuestions,
            sleepAction: sleepAction
        )
```

After `let host = try PluginHost(...)` finishes (right after its closing `)`, before `let attentionNotifier = ...`), assign the real body:

```swift
        // The real Sleep teardown. Late-bound here because this is the first point in
        // composition where `store`, `terminalSurfaces`, `webSurfaces`, and `host` all
        // exist together — `host` needs `intentRuntime.kernel`, so it cannot be built
        // before `intentRuntime`, and `intentRuntime`'s `WorkspaceIntentProvider` needs
        // this closure at construction time. Both the sidebar's Sleep button and
        // `workspace.sleep.v1` call the SAME `sleepAction`, so this is the one place the
        // active-workspace handoff and the resource teardown are implemented.
        sleepAction.perform = { [weak store, weak terminalSurfaces, weak webSurfaces, weak host] workspaceID in
            guard let store, let terminalSurfaces, let webSurfaces, let host,
                  let workspace = store.catalog.workspaces.first(where: { $0.id == workspaceID })
            else { return }

            if store.catalog.activeWorkspaceID == workspaceID,
               let neighbor = store.catalog.workspaces.first(where: { $0.id != workspaceID })
            {
                store.selectWorkspace(neighbor.id)
            }

            let ownedSlotIDs = Set(workspace.tabs.flatMap { $0.slots.map(\.id) })
            terminalSurfaces.retainOnly(
                Set(store.catalog.allSlotIDs).subtracting(ownedSlotIDs)
            )
            let ownedPluginViewSlots = store.catalog.pluginViewSlots.filter {
                ownedSlotIDs.contains($0.slotID)
            }
            webSurfaces.disposeSurfaces(forPluginViewSlots: ownedPluginViewSlots, host: host)
        }
```

- [ ] **Step 5: Finish the test fixture using this exact closure**

Back in `Tests/TenonAppStateTests/WorkspaceSleepActionTests.swift`, assign `sleepAction.perform` in each test's arrange step with the identical closure body written in Step 4 (copy it verbatim — it is a plain value-capturing closure, not something requiring `TenonApp.swift`'s composition machinery, so it runs the same way over a test-built `store`/`terminalSurfaces`/`webSurfaces`/`host`).

- [ ] **Step 6: Run to verify all three tests pass**

Run: `swift test --filter WorkspaceSleepActionTests`
Expected: PASS.

- [ ] **Step 7: Run the full `TenonAppStateTests` and `TenonCoreTests` targets**

Run: `swift test --filter TenonAppStateTests`
Run: `swift test --filter TenonCoreTests`
Expected: both PASS — no other test constructs `AppIntentRuntime` with positional args that this defaulted parameter would break.

- [ ] **Step 8: `swift build` the full app target**

Run: `swift build`
Expected: PASS — confirms `TitleBarSnapshot.swift`, `PaneRenameSnapshot.swift`, `ShellChromeSnapshot.swift`, `PluginViewSnapshot.swift` still compile unchanged against the new defaulted `AppIntentRuntime` parameter.

- [ ] **Step 9: Expose `sleepAction` on `AppComposition` so the sidebar can reach it (Task 8 needs this)**

`AppComposition` (`final class`, `Sources/TenonApp/TenonApp.swift:388`) is a fixed property list — `let host: PluginHost`, `let intentRuntime: AppIntentRuntime`, etc. — assembled by its `init(prepared:prefs:...)`, the same init body Steps 1-4 above already edit. Add a new stored property right after `let intentRuntime: AppIntentRuntime`:

```swift
    let sleepAction: WorkspaceSleepAction
```

Then, in that `init`'s body, find where it assigns `self.intentRuntime = intentRuntime` (or the equivalent — grep this `init` for its block of `self.x = x` assignments near the end) and add the sibling line:

```swift
        self.sleepAction = sleepAction
```

- [ ] **Step 10: Run**

Run: `swift build`
Expected: PASS — confirms `AppComposition`'s init assigns every stored property (Swift requires every non-optional `let` to be initialized, so a missed assignment is a compile error here, not a silent gap).

- [ ] **Step 11: Commit**

```bash
git add Sources/TenonApp/AppIntentRuntime.swift Sources/TenonApp/TenonApp.swift \
  Tests/TenonAppStateTests/WorkspaceSleepActionTests.swift
git commit -m "feat(workspace-sleep): wire the real teardown into composition"
```

---

## Task 7: Persist `visibility` in `WorkspaceCatalogStore`

**Files:**
- Modify: `Sources/TenonCore/WorkspaceCatalogStore.swift`
- Modify: `Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift`

**Interfaces:**
- Consumes: `Workspace.visibility` (Task 1).
- Produces: `WorkspaceCatalogSnapshot.WorkspaceRecord.visibility: String?`.

- [ ] **Step 1: Write the failing test**

Read the existing round-trip test style in `Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift` (likely something like `testAppearanceRoundTrips` or the general document round-trip test) and add a matching one:

```swift
    func testVisibilityRoundTripsThroughCaptureAndRestore() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "Second", path: URL(fileURLWithPath: "/tmp/second"))
        let second = catalog.workspaces[1].id
        _ = catalog.setVisibility(second, to: .background)

        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)
        let restored = WorkspaceCatalogSnapshot.catalog(from: document)

        XCTAssertEqual(
            restored?.workspaces.first { $0.id == second }?.visibility,
            .background
        )
        XCTAssertEqual(
            restored?.workspaces.first { $0.id != second }?.visibility,
            .visible
        )
    }

    func testADocumentWrittenBeforeVisibilityExistedRestoresEveryWorkspaceVisible() {
        // A WorkspaceRecord built with visibility: nil (the old shape) must restore as
        // .visible — the same forward-compatibility guarantee `appearance: nil` already
        // has. Construct a Document/WorkspaceRecord literal with visibility omitted and
        // assert the restored Workspace.visibility == .visible.
    }
```

(Match the actual restore function name — grep the file for `catalog(from:)` vs whatever it is actually called before writing this; use the real name.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WorkspaceCatalogPersistenceTests`
Expected: build failure — `WorkspaceRecord.visibility` does not exist.

- [ ] **Step 3: Add the record field**

In `Sources/TenonCore/WorkspaceCatalogStore.swift`, add to `WorkspaceRecord`:

```swift
        /// Sleep Workspace: whether this workspace shows in the sidebar's main list.
        /// Absent in every document written before this field existed, which decodes to
        /// nil and restores as `.visible` — the same forward-compatibility shape
        /// `appearance: AppearanceRecord?` already has.
        public var visibility: String?
```

and its `init` parameter (defaulted `nil`, inserted after `appearance`):

```swift
        public init(
            id: UUID,
            name: String,
            path: String,
            appearance: AppearanceRecord? = nil,
            visibility: String? = nil,
            tabs: [TabRecord],
            activeTabID: UUID
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.appearance = appearance
            self.visibility = visibility
            self.tabs = tabs
            self.activeTabID = activeTabID
        }
```

- [ ] **Step 4: Add capture/restore helpers**

Near `appearanceRecord(of:)`/`appearance(of:)`, add:

```swift
    /// `.visible` writes nothing, matching `appearanceRecord`'s "default writes nothing"
    /// shape — an uncustomised catalog produces the same document either way.
    private static func visibilityRecord(of visibility: WorkspaceVisibility) -> String? {
        visibility == .background ? "background" : nil
    }

    private static func visibility(of record: String?) -> WorkspaceVisibility {
        record == "background" ? .background : .visible
    }
```

Wire them into `document(capturing:...)` (add `visibility: visibilityRecord(of: workspace.visibility),` right after `appearance: appearanceRecord(of: workspace.appearance),`) and into the restore loop (add `visibility: visibility(of: workspaceRecord.visibility),` right after `appearance: appearance(of: workspaceRecord.appearance),` in the `Workspace(...)` construction).

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter WorkspaceCatalogPersistenceTests`
Expected: PASS.

- [ ] **Step 6: Run the full core suite**

Run: `swift test --filter TenonCoreTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TenonCore/WorkspaceCatalogStore.swift Tests/TenonCoreTests/WorkspaceCatalogPersistenceTests.swift
git commit -m "feat(workspace-model): persist Workspace.visibility"
```

---

## Task 8: Sidebar context menu — Sleep and Move to Background

**Files:**
- Modify: `Sources/TenonApp/ContentView.swift`
- Modify: `Sources/TenonApp/WorkspaceSidebarView.swift`
- Test: `Tests/TenonAppStateTests/` (a new or existing sidebar-interaction test file — grep for existing `WorkspaceRemovalAction`-style tests first and match that file)

**Interfaces:**
- Consumes: `WorkspaceSleepAction` (Task 5, now live-wired by Task 6), `WorkspaceStore.setVisibility` (Task 2).
- Produces: `WorkspaceRow`'s context menu gains `Sleep` and `Move to Background`.

- [ ] **Step 1: Thread `sleepAction` from `AppComposition` through `ContentView` to `WorkspaceSidebarView`**

`ContentView` (`Sources/TenonApp/ContentView.swift:11-16`) already declares `var store: WorkspaceStore`, `var pool: SurfacePool`, `var closeCoordinator: ShellCloseCoordinator` as plain stored properties. Add:

```swift
    var sleepAction: WorkspaceSleepAction
```

At its construction site (`Sources/TenonApp/TenonApp.swift:43-59`, inside `Window("Tenon", ...)`'s `ContentView(host: composition.host, store: composition.store, pool: composition.terminalSurfaces, closeCoordinator: composition.shellCloseCoordinator, ...)`), add `sleepAction: composition.sleepAction,` (Task 6 Step 9 already put `sleepAction` on `AppComposition`).

Inside `ContentView.body`, at the `WorkspaceSidebarView(store: store, pool: pool, closeCoordinator: closeCoordinator, agentPanes: agentPanes, isCollapsed: !sidebarVisible)` call (`ContentView.swift:84-90`), add `sleepAction: sleepAction,`.

Also update `Sources/TenonApp/ShellChromeSnapshot.swift:96` (`ContentView(bare: ...)`), the other production `ContentView(` call site — pass a fresh `WorkspaceSleepAction()` there (this snapshot tool does not exercise Sleep, so an inert default is correct, matching how `WorkspaceIntentProvider`'s own default already behaves in tests).

- [ ] **Step 2: Add `sleepAction` and per-row computed data to `WorkspaceSidebarView`/`WorkspaceRowList`**

In `Sources/TenonApp/WorkspaceSidebarView.swift`:

```swift
struct WorkspaceSidebarView: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    var closeCoordinator: ShellCloseCoordinator
    var sleepAction: WorkspaceSleepAction
    var agentPanes: AgentPaneRoster?
    var isCollapsed = false
    ...
```

Thread `sleepAction` into `WorkspaceRowList`'s `var sleepAction: WorkspaceSleepAction` the same way `closeCoordinator` already is, and into its `WorkspaceRow(...)` construction call, alongside two new plain-value parameters computed the same way `unseenCount`/`agentEntries` already are:

```swift
                        hasLiveTerminalResources: pool.terminalProcessSnapshot(
                            for: Set(workspace.tabs.flatMap { $0.slots.map(\.id) })
                        ).liveTerminalCount > 0,
                        canBackground: store.catalog.workspaces.filter {
                            $0.id != workspace.id && $0.visibility == .visible
                        }.isEmpty == false,
```

- [ ] **Step 3: Add the two context-menu items to `WorkspaceRow`**

Add stored properties to `WorkspaceRow` (`sleepAction: WorkspaceSleepAction`, `hasLiveTerminalResources: Bool`, `canBackground: Bool`) and one new `@State private var isConfirmingSleep = false`.

In `rowContent`'s `.contextMenu { ... }`, add right after `Button("Customise Workspace…")` and before `Button("Remove Workspace"...)`:

```swift
            Button("Sleep") {
                if hasLiveTerminalResources {
                    isConfirmingSleep = true
                } else {
                    sleepAction(workspace.id)
                }
            }
            Button("Move to Background") {
                store.setVisibility(workspace.id, to: .background)
            }
            .disabled(!canBackground)
```

Add the confirmation dialog as a new modifier on `rowContent` (near the existing `.popover(isPresented: $isCustomizing, ...)`):

```swift
        .confirmationDialog(
            "Sleep \(workspace.name)?",
            isPresented: $isConfirmingSleep,
            titleVisibility: .visible
        ) {
            Button("Sleep", role: .destructive) { sleepAction(workspace.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running terminals and agents in this workspace will be stopped. Its tabs and layout stay exactly as they are.")
        }
```

- [ ] **Step 4: Write the failing/passing test for the enablement rules**

Grep this test target for how an existing sidebar row action (e.g. `WorkspaceRemovalAction`'s `canRemove`) is unit-tested without mounting a real window, and write two matching tests for `canBackground` and `hasLiveTerminalResources`'s computation logic — since both are plain expressions over `store.catalog`/`pool`, they can be tested as pure computed values the same way `canRemove: store.catalog.workspaces.count > 1` presumably already is tested elsewhere, without needing a hosted view.

- [ ] **Step 5: Run**

Run: `swift build`
Run: `swift test --filter TenonAppStateTests`
Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/TenonApp/ContentView.swift Sources/TenonApp/WorkspaceSidebarView.swift
git commit -m "feat(workspace-sidebar): add Sleep and Move to Background row actions"
```

---

## Task 9: Filter the main sidebar list to `.visible` workspaces (with reorder-index translation)

This is the one task in this plan with a genuine open correctness question — the translation is written and tested here, not assumed.

**Files:**
- Modify: `Sources/TenonApp/WorkspaceSidebarView.swift`
- Test: a hosted/XCUITest-level test, or a pure-function unit test if the translation can be isolated (prefer isolating it — see Step 3)

- [ ] **Step 1: Isolate the translation as a pure, directly testable function**

In `Sources/TenonApp/WorkspaceSidebarView.swift`, add this free function near `WorkspaceSidebarDrag`:

```swift
/// Translates a destination position within the *visible-only* row list into the absolute
/// index `WorkspaceCatalog.moveWorkspace` expects over the full (visible + background)
/// array — so dragging a visible row past another visible one lands correctly even with a
/// backgrounded workspace sitting between them. Scoped to this task deliberately: reorder
/// interaction with a backgrounded workspace itself is out of scope, since it never renders
/// a row to drag.
///
/// `destination` is an index into the visible-only ordering, as `WorkspaceReorder` already
/// computes it today for the unfiltered case. The absolute index handed back is "the
/// current (pre-move) position of whichever workspace occupies that visible slot" — which
/// preserves `WorkspaceCatalog.moveWorkspace`'s existing remove-then-insert semantics,
/// because that is exactly the same kind of pre-move absolute index `WorkspaceReorder`
/// already returns for the unfiltered case.
func absoluteWorkspaceIndex(
    forVisibleDestination destination: Int,
    in workspaces: [Workspace]
) -> Int? {
    let visible = workspaces.filter { $0.visibility == .visible }
    guard !visible.isEmpty else { return nil }
    if destination >= visible.count {
        guard let last = visible.last else { return nil }
        return workspaces.firstIndex(where: { $0.id == last.id })
    }
    let targetID = visible[max(0, destination)].id
    return workspaces.firstIndex(where: { $0.id == targetID })
}
```

- [ ] **Step 2: Write the failing test**

Add to a test file matching this project's convention for a small pure function living in `TenonApp` (grep for an existing `Tests/TenonAppStateTests/*Tests.swift` that tests a similarly small free function, e.g. anything testing `WorkspaceReorder` directly, and place this alongside it, or create `Tests/TenonAppStateTests/WorkspaceSidebarVisibilityTests.swift`):

```swift
    func testAbsoluteIndexSkipsAnInterleavedBackgroundWorkspace() {
        var catalog = WorkspaceCatalog()
        catalog.addWorkspace(name: "B", path: URL(fileURLWithPath: "/tmp/b"))
        catalog.addWorkspace(name: "C", path: URL(fileURLWithPath: "/tmp/c"))
        // order: A(visible), B(visible), C(visible) — background B.
        let workspaces0 = catalog.workspaces
        _ = catalog.setVisibility(workspaces0[1].id, to: .background)
        let workspaces = catalog.workspaces
        // visible order is now [A, C]. Moving A to visible-destination 1 (after C) should
        // resolve to C's absolute index, which is 2 (A, B, C).
        let index = absoluteWorkspaceIndex(forVisibleDestination: 1, in: workspaces)
        XCTAssertEqual(index, 2)
    }

    func testAbsoluteIndexPastTheLastVisibleRowTargetsTheLastVisibleWorkspace() {
        // Same setup; forVisibleDestination: 5 (past the end) resolves to C's own absolute
        // index (the last visible workspace), not out of bounds.
    }

    func testAbsoluteIndexWithNoVisibleWorkspacesReturnsNil() {
        XCTAssertNil(absoluteWorkspaceIndex(forVisibleDestination: 0, in: []))
    }
```

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `swift test --filter WorkspaceSidebarVisibilityTests`
Expected: FAIL before Step 1 (function does not exist — but Step 1 already added it above, so run once after both steps and confirm PASS; if `testAbsoluteIndexSkipsAnInterleavedBackgroundWorkspace` fails, the off-by-one is real — adjust the function, re-run, do not adjust the test's expected value without re-deriving it by hand first).

- [ ] **Step 4: Use the translation in `updateReorder`/`moveWorkspace`, and filter the `ForEach`**

In `WorkspaceRowList`, replace every internal use of `store.catalog.workspaces` for row rendering, `rowStrip`, and `horizontalBand` with a computed `visibleWorkspaces: [Workspace]`:

```swift
    private var visibleWorkspaces: [Workspace] {
        store.catalog.workspaces.filter { $0.visibility == .visible }
    }
```

Change the `ForEach` at the top of `body` from `Array(store.catalog.workspaces.enumerated())` to `Array(visibleWorkspaces.enumerated())`, and change `workspaceCount: store.catalog.workspaces.count` to `workspaceCount: visibleWorkspaces.count`.

Change `rowStrip` and `horizontalBand` to iterate `visibleWorkspaces` instead of `store.catalog.workspaces`.

In `updateReorder`, change `let workspaces = store.catalog.workspaces` to `let workspaces = visibleWorkspaces`, and change the final call from `store.moveWorkspace(workspaceID, to: destination)` to:

```swift
        guard let absoluteDestination = absoluteWorkspaceIndex(
            forVisibleDestination: destination,
            in: store.catalog.workspaces
        ) else { return }
        withAnimation(reduceMotion ? nil : WorkspaceSidebarLayout.reorderAnimation) {
            store.moveWorkspace(workspaceID, to: absoluteDestination)
        }
```

Apply the same `workspaces = visibleWorkspaces` substitution and `absoluteWorkspaceIndex` translation in `endReorder`/`restore`/`announceLanding`/`moveWorkspace` (the private one) wherever they currently read `store.catalog.workspaces` and call `store.moveWorkspace`.

- [ ] **Step 5: Run the reorder-specific tests**

Run: `swift test --filter TabStripReorderTests` (if this name covers workspace rows too) or grep for the actual existing workspace-reorder test file name and run it.
Expected: PASS — no backgrounded workspace exists in any pre-existing test, so this should be a pure no-op for every scenario those tests already cover.

- [ ] **Step 6: Add the `BackgroundedWorkspacesSection`**

In `Sources/TenonApp/WorkspaceSidebarView.swift`, add a new private view:

```swift
/// The only way to find a `.background` workspace again — selecting a row here restores
/// `.visible` and makes it active in one action.
private struct BackgroundedWorkspacesSection: View {
    var store: WorkspaceStore

    private var backgrounded: [Workspace] {
        store.catalog.workspaces.filter { $0.visibility == .background }
    }

    var body: some View {
        if !backgrounded.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Backgrounded")
                    .font(TenonTheme.interfaceFont(size: 10, weight: .medium))
                    .foregroundStyle(TenonTheme.textSecondary)
                ForEach(backgrounded) { workspace in
                    Button(workspace.name) {
                        store.setVisibility(workspace.id, to: .visible)
                        store.selectWorkspace(workspace.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
```

(Match `TenonTheme.interfaceFont`/`TenonTheme.textSecondary` to whatever this file's other small-label text already uses — grep for an existing similarly-styled caption in this file, e.g. near `SidebarFooter`, and copy its exact font/color tokens rather than guessing new ones.)

Mount it in `WorkspaceSidebarView.body`, between `WorkspaceFolderDropZone` and `SidebarFooter`:

```swift
            BackgroundedWorkspacesSection(store: store)

            SidebarFooter(isCollapsed: isCollapsed)
```

- [ ] **Step 7: Run**

Run: `swift build`
Run: `swift test --filter TenonAppStateTests`
Expected: both PASS.

- [ ] **Step 8: Take a sidebar snapshot with one backgrounded workspace present**

```bash
TENON_PLUGINS_DIR=plugins TENON_TRUST_PLUGIN_INVENTORY=1 \
TENON_SIDEBAR_SNAPSHOT=/tmp/sidebar-backgrounded.png \
TENON_SIDEBAR_SNAPSHOT_SIZE=232x420 swift run tenon
```

Confirm visually: the main list excludes the backgrounded workspace, and the new section shows its name and is clickable.

- [ ] **Step 9: Commit**

```bash
git add Sources/TenonApp/WorkspaceSidebarView.swift
git commit -m "feat(workspace-sidebar): hide backgrounded workspaces from the main list"
```

---

## Task 10: Update `workspace-shell.prd.md`

**Files:**
- Modify: `docs/prds/workspace-shell.prd.md`

- [ ] **Step 1: Add two functional requirements**

In the requirements section, add (matching this PRD's existing `WS-FR-0NN` numbering — read the file first to find the next free number, do not guess it):

```markdown
- `WS-FR-0NN` — An operator can Sleep a workspace, releasing every live terminal and
  plugin-webview resource it owns while its tabs, panes, and layout remain exactly as they
  were. Reopening any of its panes materializes a fresh resource with no restored process
  or scrollback, identical to opening a workspace after relaunch.
- `WS-FR-0NN+1` — An operator can move a workspace to the background, hiding it from the
  sidebar's main list while every one of its live resources keeps running unchanged. At
  least one workspace remains visible at all times; a backgrounded workspace is found again
  through the sidebar's Backgrounded section, which restores it to visible and active.
```

- [ ] **Step 2: Add a decision-log entry**

```markdown
### 2026-08-20 — Sleep and Move to Background

Two independent workspace-lifecycle actions, brainstormed against Orca's "Sleep Worktree"
reference implementation (`docs/superpowers/specs/2026-08-20-sleep-workspace-design.md`).
Sleep reuses `SurfacePool.retainOnly`/`PluginWebSurfacePool.disposeSurfaces` with zero
`Workspace` domain-model change — wake is the same lazy re-materialization restore already
uses, not a new code path. Move to Background is an ordinary `Workspace.visibility`
mutation modeled on `removeWorkspace`'s active-handoff shape. Neither resumes a live agent
session on wake; that was an explicit product decision, not an oversight.
```

- [ ] **Step 3: Update the delivery-matrix row for `TENON-PRD-001`**

Add the two new task/requirement references and mark them `shipped` with today's date, following this file's existing row format for a shipped requirement (copy the format of an adjacent recently-shipped row rather than inventing a new one).

- [ ] **Step 4: Commit**

```bash
git add docs/prds/workspace-shell.prd.md
git commit -m "docs(prds): add Sleep and Move to Background requirements to workspace-shell"
```

---

## Final verification

- [ ] `swift test` (full suite) — PASS, zero pending.
- [ ] `swift build` — PASS.
- [ ] `rg "workspace.sleep.v1|workspace.visibility.set.v1"` across `Sources/` and `Tests/` — confirm both intents appear in `CoreIntentName`, `CoreIntentRules`, `WorkspaceIntentProvider`, and at least one test per file.
- [ ] Re-read `docs/superpowers/specs/2026-08-20-sleep-workspace-design.md`'s "Acceptance criteria" section and confirm each of its 10 items is now demonstrably true against the implemented code (cite the test that proves each one).
