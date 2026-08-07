import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

/// The plugin half of the pane header contract, driven through the REAL JavaScript runtime.
///
/// Every test here writes JSON the way a plugin author writes it and reads the decoded
/// `PaneHeader` off the published snapshot, because the thing under test is the *contract*
/// — what a contributor may say and what the host does with it — and a decoder exercised
/// through a Swift literal proves nothing about the JSON a plugin can actually reach it
/// with. The value type's own bounds are asserted separately in `PaneHeaderTests`; what is
/// asserted here is only what the boundary adds: which keys are read, which are refused,
/// what a mistake costs, and where the sentence explaining it goes.
///
/// Nothing in this file touches `tenon` itself. `header` is a key inside a value already
/// passed to `tenon.views.set`, so the closed-surface tests in `PluginBuiltinsTests` stay
/// byte-identical — that is the receipt that this contract grew no public surface.
final class PaneHeaderSchemaTests: XCTestCase {
    // MARK: - What decodes

    /// All ten item kinds, through JSON, into the two slots — including every optional
    /// field, so a kind that quietly stopped reading one of them fails here rather than in
    /// a pane nobody is looking at.
    func testAViewSetPublishesLeadingAndTrailingHeaderItems() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              header: {
                leading: [
                  { type: "dot", id: "state", tint: "green", tooltip: "Clean working tree" },
                  { type: "label", id: "root", text: "/src", weight: "semibold",
                    color: "muted", truncation: "head", tooltip: "Project root" },
                  { type: "badge", id: "count", text: "12", tint: "amber" },
                  { type: "image", id: "warn", systemName: "exclamationmark.triangle.fill",
                    tint: "red", tooltip: "Diagnostics" },
                  { type: "spinner", id: "loading" }
                ],
                trailing: [
                  { type: "iconButton", id: "reveal", systemName: "arrow.up.forward.app",
                    tint: "text", isEnabled: false, tooltip: "Reveal in Finder" },
                  { type: "toggle", id: "hidden", systemName: "eye", isOn: true,
                    tooltip: "Show hidden files" },
                  { type: "segmented", id: "layout", selection: "flat", segments: [
                      { value: "tree", systemName: "list.bullet.indent",
                        accessibilityLabel: "Tree" },
                      { value: "flat", label: "Flat" }
                  ] },
                  { type: "menu", id: "sort", systemName: "arrow.up.arrow.down",
                    tooltip: "Sort by", entries: [
                      { value: "name", label: "Name", isOn: true },
                      { value: "size", label: "Size", separatorBefore: true }
                  ] },
                  { type: "textfield", id: "go", value: "https://tenon.dev",
                    placeholder: "Search", flex: true }
                ]
              }
            });
            """
        )
        _ = try await runtime.start()
        let views = await runtime.snapshot().views
        let view = try XCTUnwrap(views.first)

        XCTAssertEqual(
            view.header.leading,
            [
                .dot(id: "state", tint: .green, tooltip: "Clean working tree"),
                .label(
                    id: "root",
                    text: "/src",
                    weight: .semibold,
                    color: .muted,
                    truncation: .head,
                    tooltip: "Project root"
                ),
                .badge(id: "count", text: "12", tint: .amber, tooltip: nil),
                .image(
                    id: "warn",
                    systemName: "exclamationmark.triangle.fill",
                    tint: .red,
                    tooltip: "Diagnostics"
                ),
                .spinner(id: "loading"),
            ]
        )

        let tree = try XCTUnwrap(
            PaneHeaderSegment(
                value: "tree",
                systemName: "list.bullet.indent",
                accessibilityLabel: "Tree"
            )
        )
        let flat = try XCTUnwrap(PaneHeaderSegment(value: "flat", label: "Flat"))
        let byName = try XCTUnwrap(
            PaneHeaderMenuEntry(value: "name", label: "Name", isOn: true)
        )
        let bySize = try XCTUnwrap(
            PaneHeaderMenuEntry(value: "size", label: "Size", separatorBefore: true)
        )
        XCTAssertEqual(
            view.header.trailing,
            [
                .iconButton(
                    id: "reveal",
                    systemName: "arrow.up.forward.app",
                    tint: .text,
                    isEnabled: false,
                    tooltip: "Reveal in Finder",
                    accessibilityID: nil
                ),
                .toggle(
                    id: "hidden",
                    systemName: "eye",
                    isOn: true,
                    isEnabled: true,
                    tooltip: "Show hidden files",
                    accessibilityID: nil
                ),
                .segmented(
                    id: "layout",
                    segments: [tree, flat],
                    selection: "flat",
                    isEnabled: true,
                    accessibilityID: nil
                ),
                .menu(
                    id: "sort",
                    systemName: "arrow.up.arrow.down",
                    entries: [byName, bySize],
                    isEnabled: true,
                    tooltip: "Sort by",
                    accessibilityID: nil
                ),
                .textfield(
                    id: "go",
                    value: "https://tenon.dev",
                    placeholder: "Search",
                    flex: true,
                    isEnabled: true,
                    accessibilityID: nil
                ),
            ]
        )
        _ = await runtime.shutdown()
    }

    // MARK: - What a mistake costs

    /// A header is a strip of independent controls, so one malformed entry is a defect in
    /// one control. Refusing the whole header over it would take away the ones that were
    /// fine, and failing the plugin over it would take away the pane — so the blast radius
    /// of a typo is exactly the item carrying it, and `phase == .active` is the assertion
    /// that says so.
    func testAMalformedHeaderItemIsSkippedAndItsSiblingsSurvive() async throws {
        let runtime = try makeRuntime(source: Self.malformedHeaderSource)
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)

        XCTAssertEqual(
            snapshot.phase,
            .active,
            "a header a plugin got wrong is a defect in a control, never in the plugin"
        )
        XCTAssertEqual(
            view.header.leading.map(\.id),
            ["kept-a", "kept-b"],
            "a label with no text, a button with no symbol, an unknown kind and an item "
                + "with no id each cost themselves their place and nothing else"
        )
        XCTAssertEqual(
            view.header.trailing.map(\.id),
            ["kept-c"],
            "a picker starved below its minimum options is refused as a whole control"
        )
        _ = await runtime.shutdown()
    }

    /// Silence would leave an author looking at a control that is simply not there, with
    /// nothing to read and no way to tell a typo from a bound. The sentence names the slot,
    /// the item and the field it wanted — and it goes to the PLUGIN'S own log, the way a
    /// rejected palette result already does, because it is that plugin's mistake to fix.
    func testASkippedHeaderItemNamesItsMissingFieldInTheLoadTimeLog() async throws {
        let logs = ViewLogSink()
        let runtime = try makeRuntime(
            source: Self.malformedHeaderSource,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()

        // The `[plugin-name]` prefix is the runtime's own attribution — the reason a plugin
        // logs through `tenon.log` rather than a `console` the bootstrap deletes — so it is
        // asserted along with the sentence rather than stripped out of it.
        let prefix = "[pane-header-tests] tenon.views.set(panel): "
        // A diagnostic is delivered by launching a host task, so `start()` returning proves
        // the plugin ran, never that the sentence has landed in the sink. Settling on the
        // FACT — the last of the six lines this source produces — is what makes the
        // assertions below read the finished delivery rather than whatever happened to have
        // arrived; waiting on wall-clock time instead is how this passed alone and failed
        // under the load of the full suite.
        let delivered = await eventually {
            await logs.values().count == 5
        }
        let lines = await logs.values()
        XCTAssertTrue(
            delivered,
            "the five malformed items produced \(lines.count) of 5 sentences: \(lines)"
        )
        XCTAssertTrue(
            lines.contains(
                prefix + #"dropped leading header item "no-text": a label needs "text""#
            ),
            "the missing field is named, not merely reported as invalid: \(lines)"
        )
        XCTAssertTrue(
            lines.contains(
                prefix
                    + #"dropped leading header item "no-symbol": an iconButton needs "systemName""#
            ),
            "the article agrees with the kind — an author reads this sentence: \(lines)"
        )
        XCTAssertTrue(
            lines.contains(
                prefix
                    + #"dropped leading header item "unknown-kind": "wormhole" is not a header item type"#
            ),
            lines.description
        )
        XCTAssertTrue(
            lines.contains(prefix + #"dropped a leading badge header item with no "id""#),
            "an item with no id cannot be named, so the sentence names its kind instead: \(lines)"
        )
        XCTAssertTrue(
            lines.contains {
                $0.hasPrefix(prefix + #"dropped trailing header item "starved""#)
            },
            lines.description
        )
        _ = await runtime.shutdown()
    }

    /// An unrecognised adjective is a typo about APPEARANCE, and the item still has
    /// something true to say — so a token degrades to its documented default and the item
    /// keeps its place. The log assertion is the other half: a producer is told when it
    /// loses a control, and must not be told anything when it merely misspelled a colour.
    func testUnknownTintWeightAndTruncationTokensFallBackToTheirDefaults() async throws {
        let logs = ViewLogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              header: {
                leading: [
                  { type: "label", id: "l", text: "x", weight: "chunky",
                    color: "puce", truncation: "sideways" },
                  { type: "badge", id: "b", text: "y", tint: "ultraviolet" },
                  { type: "badge", id: "control" }
                ]
              }
            });
            """,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()
        let views = await runtime.snapshot().views
        let view = try XCTUnwrap(views.first)

        XCTAssertEqual(
            view.header.leading,
            [
                .label(
                    id: "l",
                    text: "x",
                    weight: .regular,
                    color: .default,
                    truncation: .tail,
                    tooltip: nil
                ),
                .badge(id: "b", text: "y", tint: .default, tooltip: nil),
            ],
            "three unknown tokens on one label cost it three defaults, never its place"
        )

        // The positive control, and the reason it shares this `views.set` rather than living
        // in a test of its own: the claim below is that NOTHING was said about `l` and `b`,
        // and an empty sink satisfies that claim for the wrong reason. `control` is a badge
        // with no text, so the same decode, through the same channel, into the same sink,
        // MUST produce exactly one sentence — settling on it is what makes the silence about
        // its two siblings evidence instead of an unread mailbox.
        let sentence = "[pane-header-tests] tenon.views.set(panel): "
            + #"dropped leading header item "control": a badge needs "text""#
        let delivered = await eventually { await logs.values().contains(sentence) }
        let lines = await logs.values()
        XCTAssertTrue(delivered, "the control's own diagnostic never arrived: \(lines)")
        XCTAssertEqual(
            lines.filter { $0.contains("header item") },
            [sentence],
            "a misspelled adjective is not a dropped control and must not read as one: \(lines)"
        )
        _ = await runtime.shutdown()
    }

    /// The two drops no field-level check can see coming.
    ///
    /// An item can also lose its place for a reason that is nowhere in the item: an id
    /// another control already took, or a slot that was already full. Those are the hardest
    /// drops for an author to diagnose — the control is perfectly well formed, so there is
    /// nothing in it to look at — which is exactly why the decoder's promise of one sentence
    /// per lost control has to cover them too.
    func testADuplicateIDAndAFullSlotEachCostTheirItemItsPlaceAndSayWhy() async throws {
        let logs = ViewLogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              header: {
                leading: [
                  { type: "badge", id: "a", text: "1" },
                  { type: "badge", id: "b", text: "2" },
                  { type: "badge", id: "c", text: "3" },
                  { type: "badge", id: "d", text: "4" },
                  { type: "badge", id: "e", text: "5" },
                  { type: "badge", id: "f", text: "6" }
                ],
                trailing: [
                  { type: "badge", id: "a", text: "again" },
                  { type: "badge", id: "g", text: "7" }
                ]
              }
            });
            """,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()
        let views = await runtime.snapshot().views
        let view = try XCTUnwrap(views.first)

        XCTAssertEqual(
            view.header.leading.map(\.id),
            ["a", "b", "c", "d", "e"],
            "the sixth item of a five-item slot is refused, and the five before it are not"
        )
        XCTAssertEqual(
            view.header.trailing.map(\.id),
            ["g"],
            "the id belongs to whoever took it first, across both slots, and the item that "
                + "came after it under a free id still gets its place"
        )

        let prefix = "[pane-header-tests] tenon.views.set(panel): "
        let expected = [
            prefix
                + #"dropped leading header item "f": a header's leading slot holds at most "#
                + "5 items",
            prefix
                + #"dropped trailing header item "a": another header item is already using "#
                + "that id",
        ]
        let delivered = await eventually { await logs.values().count == expected.count }
        let lines = await logs.values()
        XCTAssertTrue(delivered, "\(lines)")
        XCTAssertEqual(lines, expected)
        _ = await runtime.shutdown()
    }

    /// What a header may SAY back is bounded, because saying it costs a host task.
    ///
    /// Each sentence is delivered by launching one, and that ledger holds 512 per runtime,
    /// while a `header` slot may legally carry a whole `IntentValue` collection — 1,024
    /// items. An all-malformed slot would therefore ask for twice the ledger in one
    /// `views.set` and start losing lines silently, including the very diagnostics this
    /// channel exists to deliver and every other log line the plugin had in flight. So the
    /// first few are named and the rest are counted: bounded like every other queue here
    /// (invariant 10), and still an answer rather than a silence.
    func testAHeaderFullOfMalformedItemsNamesTheFirstFewAndCountsTheRest() async throws {
        let logs = ViewLogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            var leading = [];
            for (var i = 0; i < 1024; i++) {
              leading.push({ type: "badge", id: "i-" + i });
            }
            tenon.views.set("panel", { header: { leading: leading } });
            """,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()
        let views = await runtime.snapshot().views
        let view = try XCTUnwrap(views.first)
        XCTAssertTrue(view.header.isEmpty, "a badge with no text is a badge with nothing to say")

        let delivered = await eventually { await logs.values().count == 16 }
        let lines = await logs.values()
        XCTAssertTrue(
            delivered,
            "1,024 dropped items produced \(lines.count) sentences, not 16: \(lines.prefix(3))"
        )
        XCTAssertEqual(
            lines.first,
            "[pane-header-tests] tenon.views.set(panel): "
                + #"dropped leading header item "i-0": a badge needs "text""#,
            "the ones that are named are named in full, exactly as a lone mistake would be"
        )
        XCTAssertEqual(
            lines.last,
            "[pane-header-tests] tenon.views.set(panel): dropped 1009 further header items, "
                + "not named here because a header holds at most 13",
            "and the rest are counted, so the author is told the size of what went wrong"
        )
        _ = await runtime.shutdown()
    }

    /// The published state IS the state: anything a plugin stopped saying, it stopped
    /// meaning. That is how a control is taken away — `views.set` without the key — and it
    /// is the rule `modal` already follows, for the same reason.
    func testAViewSetWithoutAHeaderClearsThePreviousOne() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              header: { leading: [{ type: "badge", id: "count", text: "1" }] }
            });
            tenon.views.set("panel", { body: { type: "text", value: "done" } });
            """
        )
        _ = try await runtime.start()
        let views = await runtime.snapshot().views
        let view = try XCTUnwrap(views.first)

        XCTAssertTrue(
            view.header.isEmpty,
            "a header outliving the state that published it is chrome the plugin cannot remove"
        )
        // The control. Without it an always-empty header would pass this test for the
        // wrong reason — this is what proves the second `views.set` landed at all.
        XCTAssertEqual(
            view.body,
            .text("done", style: .body, weight: .regular, color: .default)
        )
        _ = await runtime.shutdown()
    }

    /// An accessibility identifier is XCUITest identity, not contributor data. A plugin
    /// able to mint one could rename the host's own test anchors out from under the UI
    /// suite, so the key is absent by construction rather than filtered.
    func testAPluginCannotSetAnAccessibilityIdentifier() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              header: {
                trailing: [
                  { type: "iconButton", id: "reveal", systemName: "eye",
                    accessibilityID: "tenon.agentLens.mode" },
                  { type: "toggle", id: "t", systemName: "eye", accessibilityID: "stolen" },
                  { type: "segmented", id: "s", selection: "a", accessibilityID: "stolen",
                    segments: [{ value: "a", label: "A" }, { value: "b", label: "B" }] },
                  { type: "menu", id: "m", systemName: "eye", accessibilityID: "stolen",
                    entries: [{ value: "e", label: "E" }] },
                  { type: "textfield", id: "f", accessibilityID: "stolen" }
                ]
              }
            });
            """
        )
        _ = try await runtime.start()
        let views = await runtime.snapshot().views
        let view = try XCTUnwrap(views.first)

        XCTAssertEqual(
            view.header.trailing.map(\.id),
            ["reveal", "t", "s", "m", "f"],
            "the items are kept — it is the one field that is refused, not the control"
        )
        XCTAssertEqual(
            view.header.trailing.map(Self.accessibilityID(of:)),
            [nil, nil, nil, nil, nil],
            "every interactive kind refuses a contributor-authored accessibility identifier"
        )
        // The control, and the reason this is a boundary rule rather than a value-type
        // one: a HOST-NATIVE producer sets the same field on the same case and keeps it.
        let native = PaneHeader(trailing: [
            .iconButton(
                id: "reveal",
                systemName: "eye",
                tint: .default,
                isEnabled: true,
                tooltip: nil,
                accessibilityID: "tenon.agentLens.mode"
            ),
        ])
        XCTAssertEqual(
            native.trailing.map(Self.accessibilityID(of:)),
            ["tenon.agentLens.mode"],
            "host anchors must survive the move into chrome; only the DECODER refuses them"
        )
        _ = await runtime.shutdown()
    }

    // MARK: - How a click comes back

    /// No new API surface. A header control reports through the view's own `onSelect` and
    /// `onSubmit` — the same two handlers a row click, a body button and an inline rename
    /// already use — and which one it takes is a property of the item's KIND: a picker
    /// selects, a field commits.
    func testSegmentedAndMenuDeliverTheirValueThroughOnSelectAndATextfieldThroughOnSubmit()
        async throws
    {
        let logs = ViewLogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              header: {
                trailing: [
                  { type: "segmented", id: "layout", selection: "tree", segments: [
                      { value: "tree", label: "Tree" },
                      { value: "flat", label: "Flat" }
                  ] },
                  { type: "menu", id: "sort", systemName: "arrow.up.arrow.down", entries: [
                      { value: "name", label: "Name" },
                      { value: "size", label: "Size" }
                  ] },
                  { type: "textfield", id: "go", value: "" }
                ]
              }
            });
            tenon.views.onSelect("panel", function (itemID, value) {
              tenon.log("select:" + itemID + "=" + value);
            });
            tenon.views.onSubmit("panel", function (itemID, text) {
              tenon.log("submit:" + itemID + "=" + text);
            });
            """,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()

        let pickedLayout = try await runtime.invokeViewSelect(
            viewID: "panel",
            itemID: "layout",
            value: .string("flat")
        )
        let pickedSort = try await runtime.invokeViewSelect(
            viewID: "panel",
            itemID: "sort",
            value: .string("size")
        )
        let committedAddress = try await runtime.invokeViewSubmit(
            viewID: "panel",
            itemID: "go",
            text: "https://tenon.dev"
        )
        XCTAssertTrue(pickedLayout)
        XCTAssertTrue(pickedSort)
        XCTAssertTrue(committedAddress)

        let delivered = await eventually {
            await logs.values() == [
                "[pane-header-tests] select:layout=flat",
                "[pane-header-tests] select:sort=size",
                "[pane-header-tests] submit:go=https://tenon.dev",
            ]
        }
        let received = await logs.values()
        XCTAssertTrue(delivered, "\(received)")
        _ = await runtime.shutdown()
    }

    /// A header's lifetime is its view's lifetime, and an instanced view has one per pane.
    /// Two panes of one view showing each other's chrome is the T-012 defect wearing a new
    /// hat, so each instance's header is asserted against its own instance id.
    func testASingletonAndAnInstancedViewEachPublishTheirOwnHeader() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("solo", { title: "Solo" });
            tenon.views.register("pane", { title: "Pane", instanced: true });
            tenon.views.set("solo", {
              header: { leading: [{ type: "badge", id: "n", text: "solo" }] }
            });
            tenon.views.onOpen("pane", function (instanceID) {
              tenon.views.set("pane", {
                header: { leading: [{ type: "badge", id: "n", text: instanceID }] }
              }, instanceID);
            });
            """
        )
        _ = try await runtime.start()
        try await runtime.openViewInstance(viewID: "pane", instanceID: "pane-a")
        try await runtime.openViewInstance(viewID: "pane", instanceID: "pane-b")

        let published = await eventually {
            let views = await runtime.snapshot().views
            return Self.badgeText(of: views.first { $0.instanceID == "pane-a" }) == "pane-a"
                && Self.badgeText(of: views.first { $0.instanceID == "pane-b" }) == "pane-b"
        }
        XCTAssertTrue(published, "each pane must carry the header its own instance published")

        let views = await runtime.snapshot().views
        XCTAssertEqual(
            Self.badgeText(of: views.first { $0.viewID == "solo" }),
            "solo",
            "a singleton has no instance and keeps its own header alongside the instanced one"
        )
        _ = await runtime.shutdown()
    }

    // MARK: - Helpers

    /// One source, two tests: what survives a batch of malformed items (test above) and
    /// what its author is told about the ones that did not (the test after it). Sharing it
    /// is what makes those two assertions provably about the same five mistakes.
    private static let malformedHeaderSource = """
    tenon.views.register("panel", { title: "Panel" });
    tenon.views.set("panel", {
      header: {
        leading: [
          { type: "label", id: "kept-a", text: "shown" },
          { type: "label", id: "no-text" },
          { type: "iconButton", id: "no-symbol" },
          { type: "wormhole", id: "unknown-kind" },
          { type: "badge", text: "no id at all" },
          { type: "badge", id: "kept-b", text: "9" }
        ],
        trailing: [
          { type: "segmented", id: "starved", selection: "a",
            segments: [{ value: "a", label: "A" }] },
          { type: "toggle", id: "kept-c", systemName: "eye" }
        ]
      }
    });
    """

    /// `PaneHeaderItem` publishes no `accessibilityID` accessor — the renderer reads the
    /// field off the case it is already destructuring — so the test does the same.
    private static func accessibilityID(of item: PaneHeaderItem) -> String? {
        switch item {
        case let .iconButton(_, _, _, _, _, accessibilityID): return accessibilityID
        case let .toggle(_, _, _, _, _, accessibilityID): return accessibilityID
        case let .segmented(_, _, _, _, accessibilityID): return accessibilityID
        case let .menu(_, _, _, _, _, accessibilityID): return accessibilityID
        case let .textfield(_, _, _, _, _, accessibilityID): return accessibilityID
        case .dot, .label, .badge, .image, .spinner: return nil
        }
    }

    private static func badgeText(of view: PluginViewInfo?) -> String? {
        guard case let .badge(_, text, _, _) = view?.header.leading.first else { return nil }
        return text
    }

    private func makeRuntime(
        source: String,
        log: @escaping PluginRuntimeConfiguration.Log = { _ in }
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-pane-header-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try source.write(
            to: directory.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )
        return try PluginRuntime(
            configuration: PluginRuntimeConfiguration(
                manifest: try PluginManifest(
                    id: "dev.tenon.pane-header-tests",
                    name: "pane-header-tests",
                    version: "1"
                ),
                directory: directory,
                intents: PluginRuntimeIntentBridge(
                    send: { _ in Self.unavailable() },
                    list: { .array([]) }
                ),
                log: log
            )
        )
    }

    private func eventually(
        attempts: Int = 200,
        operation: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await operation() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private static func unavailable() -> IntentResult {
        .failure(
            error: IntentError(
                code: .kernel(.providerUnavailable),
                details: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                outcome: .notStarted
            ),
            requestID: UUID(),
            providerID: nil
        )
    }
}

private actor ViewLogSink {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }

    func values() -> [String] {
        lines
    }
}
