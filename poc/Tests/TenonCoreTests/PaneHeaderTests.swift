import XCTest
@testable import TenonCore

/// `PaneHeader` is the value a pane hands the ONE chrome header the card draws. It is pure —
/// no window, no AppKit, no plugin runtime — so every rule that decides what a 34-point strip
/// will accept is asserted here, headlessly, against a Swift producer.
///
/// That last part is the point of these tests rather than an accident of where they live. The
/// same value arrives from typed built-in Swift and from a plugin's JSON, and the bounds live
/// in `PaneHeader.init` precisely so neither producer can reach a looser door. A test that
/// clamped a plugin at the decoder and trusted Swift would be testing the wrong boundary.
///
/// The boundary these pin: a slot's item budget, the split between display text that truncates
/// and identity that drops its item, which items take the mouse, that exactly one item may
/// absorb slack, and that a control folded into the overflow menu still reads its own state.
final class PaneHeaderTests: XCTestCase {
    // MARK: - Fixtures

    private func segment(_ value: String, label: String? = nil) -> PaneHeaderSegment {
        // Force-unwrapped deliberately: these fixtures are inside the bounds by construction,
        // and a nil here would mean the failable initialiser had changed under the test.
        PaneHeaderSegment(value: value, label: label ?? value.capitalized)!
    }

    private func entry(_ value: String) -> PaneHeaderMenuEntry {
        PaneHeaderMenuEntry(value: value, label: value.capitalized)!
    }

    private func dot(_ id: String) -> PaneHeaderItem {
        .dot(id: id, tint: .green, tooltip: nil)
    }

    // MARK: - Bounds

    /// One header, every bound at once. Each cap is asserted through the initialiser a built-in
    /// Swift pane uses, because that is the door the plugin decoder will also come through.
    func testAHeaderBoundsItsItemsSegmentsMenuEntriesAndTextLengths() {
        // Sized off the caps themselves rather than off round numbers: a fixture that stops
        // being over-long the moment a cap is raised stops testing the clamp it was written for.
        let longLabel = String(repeating: "p", count: PaneHeaderItem.maximumLabelLength + 100)
        let longBadge = String(repeating: "b", count: PaneHeaderItem.maximumBadgeLength + 16)
        let longTooltip = String(repeating: "t", count: PaneHeaderItem.maximumTooltipLength + 160)
        let longValue = String(repeating: "v", count: PaneHeaderItem.maximumTextFieldLength + 952)

        let header = PaneHeader(
            leading: [
                .label(
                    id: "root",
                    text: longLabel,
                    weight: .regular,
                    color: .muted,
                    truncation: .head,
                    tooltip: longTooltip
                ),
                .badge(id: "count", text: longBadge, tint: .muted, tooltip: nil),
                dot("d1"),
                dot("d2"),
                dot("d3"),
                dot("d4"),
                dot("d5"),
            ],
            trailing: [
                .segmented(
                    id: "layout",
                    segments: (0..<7).map { segment("s\($0)") },
                    selection: "s0",
                    isEnabled: true,
                    accessibilityID: nil
                ),
                .menu(
                    id: "more",
                    systemName: "ellipsis",
                    entries: (0..<20).map { entry("e\($0)") },
                    isEnabled: true,
                    tooltip: nil,
                    accessibilityID: nil
                ),
                .textfield(
                    id: "go",
                    value: longValue,
                    placeholder: "",
                    flex: true,
                    isEnabled: true,
                    accessibilityID: nil
                ),
                dot("t1"), dot("t2"), dot("t3"), dot("t4"), dot("t5"), dot("t6"), dot("t7"),
            ]
        )

        XCTAssertEqual(header.leading.count, PaneHeader.maximumLeadingItems)
        XCTAssertEqual(header.leading.map(\.id), ["root", "count", "d1", "d2", "d3"])
        XCTAssertEqual(header.trailing.count, PaneHeader.maximumTrailingItems)
        XCTAssertEqual(
            header.trailing.map(\.id),
            ["layout", "more", "go", "t1", "t2", "t3", "t4", "t5"]
        )

        guard case let .label(_, text, _, _, _, tooltip) = header.leading[0] else {
            return XCTFail("expected the first leading item to still be a label")
        }
        XCTAssertEqual(text.count, PaneHeaderItem.maximumLabelLength)
        XCTAssertEqual(tooltip?.count, PaneHeaderItem.maximumTooltipLength)

        guard case let .badge(_, badgeText, _, _) = header.leading[1] else {
            return XCTFail("expected the second leading item to still be a badge")
        }
        XCTAssertEqual(badgeText.count, PaneHeaderItem.maximumBadgeLength)

        guard case let .segmented(_, segments, _, _, _) = header.trailing[0] else {
            return XCTFail("expected the first trailing item to still be a segmented control")
        }
        XCTAssertEqual(segments.count, PaneHeaderSegment.maximumSegments)

        guard case let .menu(_, _, entries, _, _, _) = header.trailing[1] else {
            return XCTFail("expected the second trailing item to still be a menu")
        }
        XCTAssertEqual(entries.count, PaneHeaderMenuEntry.maximumEntries)

        guard case let .textfield(_, value, _, _, _, _) = header.trailing[2] else {
            return XCTFail("expected the third trailing item to still be a textfield")
        }
        XCTAssertEqual(value.count, PaneHeaderItem.maximumTextFieldLength)
    }

    /// Identity is the one thing that is never repaired. Two over-long values sharing a 64-
    /// character prefix would truncate into the *same* option and report a selection their
    /// owner never published, so both are refused instead.
    func testAnOverLongSegmentValueDropsItsOptionInsteadOfTruncatingIt() {
        let prefix = String(repeating: "a", count: PaneHeaderSegment.maximumValueLength)
        XCTAssertNil(PaneHeaderSegment(value: prefix + "1", label: "First"))
        XCTAssertNil(PaneHeaderSegment(value: prefix + "2", label: "Second"))
        XCTAssertNil(PaneHeaderMenuEntry(value: prefix + "1", label: "First"))

        let admissible = PaneHeaderSegment(value: prefix, label: "Kept")
        XCTAssertEqual(admissible?.value, prefix, "an admissible value is stored verbatim")
        XCTAssertEqual(PaneHeaderMenuEntry(value: prefix, label: "Kept")?.value, prefix)

        // A segmented control that loses too many options to the rule loses its place in the
        // header rather than rendering as a one-choice picker.
        let starved = PaneHeader(trailing: [
            .segmented(
                id: "layout",
                segments: [segment("tree")],
                selection: "tree",
                isEnabled: true,
                accessibilityID: nil
            ),
        ])
        XCTAssertTrue(starved.isEmpty)
    }

    /// An icon-only segment is the one control in this vocabulary with no text of its own, and
    /// two different readers need one: the pointer, which wants hover text, and VoiceOver,
    /// which wants a spoken name. They are the same sentence, so the segment takes it from
    /// whichever side its author wrote it on and fills the other in.
    ///
    /// This is the regression the migration made concrete. The Changes bar gave its Tree/Flat
    /// buttons `.help("Tree")` / `.help("Flat")`; the segment that replaced them could carry an
    /// `accessibilityLabel` and nothing else, so the hover text had no field to live in and no
    /// producer — built-in or plugin — could have put it back.
    func testAnIconOnlySegmentTakesItsHoverTextAndSpokenNameFromEitherSide() {
        // What `ChangesPaneHeader` writes today, unchanged: naming the segment for VoiceOver
        // is what restores the pointer's hover text.
        let spoken = PaneHeaderSegment(
            value: "tree",
            systemName: "list.bullet.indent",
            accessibilityLabel: "Tree"
        )
        XCTAssertEqual(spoken?.tooltip, "Tree")
        XCTAssertEqual(spoken?.accessibilityLabel, "Tree")

        // And the other way, for the author who reaches for the word `tooltip` because they are
        // porting a `.help(…)`: the spoken name comes back from the hover text.
        let hovered = PaneHeaderSegment(
            value: "flat",
            systemName: "list.dash",
            tooltip: "Flat"
        )
        XCTAssertEqual(hovered?.accessibilityLabel, "Flat")
        XCTAssertEqual(hovered?.tooltip, "Flat")

        // Both written means both kept: the fallback fills a gap, it never overwrites a choice.
        let both = PaneHeaderSegment(
            value: "split",
            systemName: "rectangle.split.2x1",
            accessibilityLabel: "Split",
            tooltip: "Show both panes side by side"
        )
        XCTAssertEqual(both?.accessibilityLabel, "Split")
        XCTAssertEqual(both?.tooltip, "Show both panes side by side")

        // A segment that already shows its name gets no synthesised tooltip — a hover that
        // repeats the text under the pointer is noise, not an affordance.
        let visible = PaneHeaderSegment(value: "unified", label: "Unified")
        XCTAssertNil(visible?.tooltip)
        XCTAssertNil(visible?.accessibilityLabel)

        // A nameless icon-only segment KEEPS its place. Refusing it would starve the picker
        // below `minimumSegments` and delete the whole control, leaving its author nothing to
        // see; degrading to the value leaves a visibly wrong `"seg-a"` in the hover text and
        // in the overflow menu, which is the fault reporting itself.
        let nameless = PaneHeaderSegment(value: "seg-a", systemName: "circle")
        XCTAssertNotNil(nameless)
        XCTAssertNil(nameless?.tooltip)
        let picker = PaneHeaderItem.segmented(
            id: "layout",
            segments: [nameless!, PaneHeaderSegment(value: "seg-b", systemName: "square")!],
            selection: "seg-a",
            isEnabled: true,
            accessibilityID: nil
        )
        XCTAssertEqual(picker.overflowEntries().map(\.label), ["seg-a", "seg-b"])

        // A segment's tooltip is a tooltip like any other and takes the vocabulary's one bound
        // for the concept; the name it lends back is bounded like a segment's visible label,
        // because that is what it is standing in for.
        let essay = String(repeating: "e", count: PaneHeaderItem.maximumTooltipLength + 50)
        let clamped = PaneHeaderSegment(value: "long", systemName: "circle", tooltip: essay)
        XCTAssertEqual(clamped?.tooltip?.count, PaneHeaderItem.maximumTooltipLength)
        XCTAssertEqual(clamped?.accessibilityLabel?.count, PaneHeaderSegment.maximumLabelLength)
    }

    /// The cap on a tooltip is the one bound in this vocabulary that buys no layout, so it is
    /// sized by the longest thing a pane has to be able to SAY rather than by anything it has
    /// to fit — and the worst case in the shipped product is a filesystem failure that names
    /// the file it failed on.
    ///
    /// 240 characters could not do that: a message plus a real project path is past it before
    /// the sentence ends, and the File pane's own comment promised the tooltip was where the
    /// whole message stayed reachable. This is that promise, made checkable.
    func testATooltipHoldsAFilesystemFailureThatStillNamesItsFile() {
        let path = "/Users/tenon/projects/tenon/poc/Sources/TenonApp/"
            + String(repeating: "deeply/nested/", count: 20)
            + "ChangesPanelView.swift"
        let message = "The file “\(path)” could not be opened because you do not have "
            + "permission to view it."
        XCTAssertGreaterThan(
            message.count,
            240,
            "the fixture must exceed the old cap or it proves nothing"
        )

        let header = PaneHeader(
            trailing: [.badge(id: "error", text: message, tint: .red, tooltip: message)]
        )
        guard case let .badge(_, text, _, tooltip) = header.trailing.first else {
            return XCTFail("expected the file pane's error badge to survive the header's bounds")
        }
        XCTAssertEqual(tooltip, message, "the reason a file would not open was cut")
        XCTAssertEqual(
            text.count,
            PaneHeaderItem.maximumBadgeLength,
            "a badge is still a 24-character chip; the tooltip is what carries the sentence"
        )

        // Raised, not removed. A producer holding a genuinely unbounded string still has to
        // summarise it, and the header still publishes a bounded value (invariant 10).
        let unbounded = String(repeating: "u", count: PaneHeaderItem.maximumTooltipLength * 3)
        let flooded = PaneHeader(
            trailing: [.dot(id: "dirty", tint: .amber, tooltip: unbounded)]
        )
        guard case let .dot(_, _, clamped) = flooded.trailing.first else {
            return XCTFail("expected a dot")
        }
        XCTAssertEqual(clamped?.count, PaneHeaderItem.maximumTooltipLength)
    }

    /// The host's own ids, refused at the door — and the same rule one step out, that no id is
    /// spoken for twice in one header.
    ///
    /// Both halves guard the same fault. `PaneHeaderBar` draws a run with a single
    /// `ForEach(id: \.item.id)` and the card routes a click by `itemID` alone, so two items
    /// answering one id means a duplicate SwiftUI identity and a click delivered to whichever
    /// owner happens to match first. The `…` is the one id both a contributor and the host
    /// could mint, which is why it is unrepresentable in a header rather than merely
    /// undocumented; a repeated contributor id is the same fault without the host in it.
    func testAHeaderRefusesTheHostsReservedIdentitiesAndAnyRepeatedID() {
        for reserved in PaneHeaderItem.reservedIDs {
            XCTAssertNil(
                PaneHeaderItem.spinner(id: reserved).bounded(),
                "\(reserved) survived the item's own bound"
            )
            let collider = PaneHeader(
                leading: [
                    .label(
                        id: reserved,
                        text: "mine",
                        weight: .regular,
                        color: .text,
                        truncation: .tail,
                        tooltip: nil
                    ),
                ],
                trailing: [
                    .menu(
                        id: reserved,
                        systemName: "ellipsis",
                        entries: [entry("open")],
                        isEnabled: true,
                        tooltip: nil,
                        accessibilityID: nil
                    ),
                ]
            )
            XCTAssertTrue(collider.isEmpty, "\(reserved) reached a header")
        }

        // An id already taken in this header costs the later item its place, in either slot:
        // the two ends of the contract — the renderer's key and the router's token — are the
        // id and nothing else, so a second claimant has no way to be told apart from the first.
        let repeated = PaneHeader(
            leading: [dot("state"), dot("state"), dot("fresh")],
            trailing: [dot("state"), .spinner(id: "fresh"), .spinner(id: "loading")]
        )
        XCTAssertEqual(repeated.leading.map(\.id), ["state", "fresh"])
        XCTAssertEqual(repeated.trailing.map(\.id), ["loading"])
        let ids = (repeated.leading + repeated.trailing).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "a header handed out one id twice")
    }

    /// The set that answers `true` here is exactly the set of holes punched in the pane's drag
    /// surface, so status decoration must stay outside it.
    func testOnlyActionableItemsAreInteractive() {
        let inert: [PaneHeaderItem] = [
            dot("state"),
            .label(
                id: "root",
                text: "~/tenon",
                weight: .regular,
                color: .muted,
                truncation: .head,
                tooltip: nil
            ),
            .badge(id: "count", text: "12", tint: .muted, tooltip: nil),
            .image(id: "warn", systemName: "exclamationmark.triangle.fill", tint: .amber, tooltip: nil),
            .spinner(id: "loading"),
        ]
        let actionable: [PaneHeaderItem] = [
            .iconButton(
                id: "reload",
                systemName: "arrow.clockwise",
                tint: .default,
                isEnabled: true,
                tooltip: nil,
                accessibilityID: nil
            ),
            .toggle(
                id: "hidden",
                systemName: "eye",
                isOn: false,
                isEnabled: true,
                tooltip: nil,
                accessibilityID: nil
            ),
            .segmented(
                id: "layout",
                segments: [segment("tree"), segment("flat")],
                selection: "tree",
                isEnabled: true,
                accessibilityID: nil
            ),
            .menu(
                id: "more",
                systemName: "ellipsis",
                entries: [entry("open")],
                isEnabled: true,
                tooltip: nil,
                accessibilityID: nil
            ),
            .textfield(
                id: "go",
                value: "",
                placeholder: "Search",
                flex: false,
                isEnabled: true,
                accessibilityID: nil
            ),
        ]

        XCTAssertEqual(inert.map(\.isInteractive), [false, false, false, false, false])
        XCTAssertEqual(actionable.map(\.isInteractive), [true, true, true, true, true])

        // The card asks this question one placement at a time — `interactiveRects` is the
        // whole of the exemption — so the item is the only level at which it is ever asked.
        let mixed = PaneHeader(leading: inert, trailing: [actionable[0]])
        XCTAssertEqual(
            (mixed.leading + mixed.trailing).filter(\.isInteractive).map(\.id),
            ["reload"]
        )
        XCTAssertTrue(PaneHeader.empty.leading.isEmpty)
    }

    /// Two address bars in one 34-point strip is not a layout: the first claimant takes the
    /// gap and every later one is laid out at its natural width.
    func testAtMostOneItemIsFlexible() {
        func field(_ id: String, flex: Bool) -> PaneHeaderItem {
            .textfield(
                id: id,
                value: "",
                placeholder: "",
                flex: flex,
                isEnabled: true,
                accessibilityID: nil
            )
        }

        XCTAssertNil(PaneHeader(trailing: [field("go", flex: false)]).flexibleItemID)
        XCTAssertEqual(
            PaneHeader(trailing: [field("go", flex: true)]).flexibleItemID,
            "go"
        )
        XCTAssertEqual(
            PaneHeader(
                leading: [field("filter", flex: true)],
                trailing: [field("go", flex: true)]
            ).flexibleItemID,
            "filter",
            "leading is packed first, so its claim is the one that stands"
        )
        XCTAssertEqual(
            PaneHeader(trailing: [field("go", flex: true), field("filter", flex: true)])
                .flexibleItemID,
            "go"
        )
    }

    /// Nothing folds silently. A picker that ran out of room becomes its options, and the
    /// checkmark is how it still reads its own state from inside the overflow menu.
    func testAFoldedSegmentedKeepsItsSelectionAsACheckedOverflowEntry() {
        let picker = PaneHeaderItem.segmented(
            id: "layout",
            segments: [
                PaneHeaderSegment(
                    value: "tree",
                    systemName: "list.bullet.indent",
                    accessibilityLabel: "Tree"
                )!,
                PaneHeaderSegment(value: "flat", label: "Flat")!,
            ],
            selection: "flat",
            isEnabled: true,
            accessibilityID: nil
        )

        let folded = picker.overflowEntries()
        XCTAssertEqual(folded.map(\.value), ["tree", "flat"])
        XCTAssertEqual(folded.map(\.isOn), [false, true])
        XCTAssertEqual(
            folded.map(\.label),
            ["Tree", "Flat"],
            "an icon-only segment reads by the name VoiceOver would have spoken"
        )

        // The neighbouring rules of the same fold: a toggle keeps its state as one checked
        // line, and pure decoration is the only thing allowed to vanish.
        let toggle = PaneHeaderItem.toggle(
            id: "hidden",
            systemName: "eye",
            isOn: true,
            isEnabled: true,
            tooltip: "Show hidden files",
            accessibilityID: nil
        )
        XCTAssertEqual(toggle.overflowEntries().map(\.value), ["hidden"])
        XCTAssertEqual(toggle.overflowEntries().map(\.label), ["Show hidden files"])
        XCTAssertEqual(toggle.overflowEntries().map(\.isOn), [true])
        XCTAssertTrue(dot("state").overflowEntries().isEmpty)
        XCTAssertTrue(PaneHeaderItem.spinner(id: "loading").overflowEntries().isEmpty)
    }
}
