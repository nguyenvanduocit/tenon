import AppKit
import SwiftUI
import TenonCore
import XCTest
@testable import TenonApp

/// The pure slot → header projections a built-in pane publishes, asserted without a window.
///
/// This is the fitness test `docs/tdd.md` asks for: "can this rule be asserted in a headless
/// target?" A header is a decision about *what a pane has to say* — which is arithmetic over
/// the pane's own model state — while drawing it is `PaneHeaderBar`'s job and placing it is
/// `PaneHeaderLayout`'s. Keeping the decision in a free function means the interesting half is
/// provable.
///
/// The renderer keeps exactly one rule of its own, and it is at the bottom of this file: a
/// segmented control's per-segment hover text has to survive the SwiftUI→AppKit bridge. That is
/// a fact about the bridge rather than about a value, so no smaller thing can state it and it is
/// asserted on a mounted control instead.
///
/// Every conditional item here is asserted in BOTH directions in the same test. A projection
/// that returned an empty header for every input would satisfy any suppression assertion on
/// its own, so each negative is paired with the positive that rules that failure out.
final class PaneHeaderProjectionTests: XCTestCase {
    // MARK: - Item readers
    //
    // The vocabulary is a flat enum with no accessors beyond `id`, on purpose: a header item is
    // read by the one renderer that switches over it. These local readers are the test's own
    // way in, and they deliberately match on the case as well as the payload, so an assertion
    // cannot be satisfied by the right text arriving in the wrong kind of item.

    private func badgeText(_ item: PaneHeaderItem?) -> String? {
        guard case let .badge(_, text, _, _) = item else { return nil }
        return text
    }

    private func badgeTint(_ item: PaneHeaderItem?) -> ColorToken? {
        guard case let .badge(_, _, tint, _) = item else { return nil }
        return tint
    }

    private func badgeTooltip(_ item: PaneHeaderItem?) -> String? {
        guard case let .badge(_, _, _, tooltip) = item else { return nil }
        return tooltip
    }

    private func labelText(_ item: PaneHeaderItem?) -> String? {
        guard case let .label(_, text, _, _, _, _) = item else { return nil }
        return text
    }

    private func labelTooltip(_ item: PaneHeaderItem?) -> String? {
        guard case let .label(_, _, _, _, _, tooltip) = item else { return nil }
        return tooltip
    }

    private func labelColor(_ item: PaneHeaderItem?) -> ColorToken? {
        guard case let .label(_, _, _, color, _, _) = item else { return nil }
        return color
    }

    private func imageSystemName(_ item: PaneHeaderItem?) -> String? {
        guard case let .image(_, systemName, _, _) = item else { return nil }
        return systemName
    }

    private func isDot(_ item: PaneHeaderItem?) -> Bool {
        guard case .dot = item else { return false }
        return true
    }

    private func dotTooltip(_ item: PaneHeaderItem?) -> String? {
        guard case let .dot(_, _, tooltip) = item else { return nil }
        return tooltip
    }

    private func iconButtonIsEnabled(_ item: PaneHeaderItem?) -> Bool? {
        guard case let .iconButton(_, _, _, isEnabled, _, _) = item else { return nil }
        return isEnabled
    }

    private func segments(_ item: PaneHeaderItem?) -> [PaneHeaderSegment]? {
        guard case let .segmented(_, segments, _, _, _) = item else { return nil }
        return segments
    }

    private func segmentValues(_ item: PaneHeaderItem?) -> [String]? {
        segments(item)?.map(\.value)
    }

    private func segmentedSelection(_ item: PaneHeaderItem?) -> String? {
        guard case let .segmented(_, _, selection, _, _) = item else { return nil }
        return selection
    }

    private func isSpinner(_ item: PaneHeaderItem?) -> Bool {
        guard case .spinner = item else { return false }
        return true
    }

    // MARK: - Diff

    /// The stats badges are the diff pane's only conditional content, and each of the three
    /// conditions suppresses them for a different reason: a loading pane has not counted yet,
    /// a binary file has nothing to count, and an unchanged file's `+0 −0` is noise where "No
    /// changes" is already on screen.
    ///
    /// The positive control is first and asserts the exact texts, so a projection that dropped
    /// the badges unconditionally — the shape a stub has — fails here rather than passing three
    /// suppression checks for the wrong reason.
    func testDiffPublishesStatsOnlyWhenLoadedNonBinaryAndChanged() {
        let shown = DiffPaneHeader.header(
            isLoading: false,
            hasChanges: true,
            isBinary: false,
            added: 12,
            removed: 3,
            isSplit: false
        )
        XCTAssertEqual(
            shown.leading.count,
            2,
            "a loaded, changed, textual diff shows exactly its two stat badges"
        )
        XCTAssertEqual(badgeText(shown.leading.first), "+12")
        XCTAssertEqual(badgeTint(shown.leading.first), .green)
        XCTAssertEqual(badgeText(shown.leading.last), "−3")
        XCTAssertEqual(badgeTint(shown.leading.last), .red)

        for (reason, header) in [
            ("still loading", DiffPaneHeader.header(
                isLoading: true, hasChanges: true, isBinary: false,
                added: 12, removed: 3, isSplit: false
            )),
            ("binary", DiffPaneHeader.header(
                isLoading: false, hasChanges: true, isBinary: true,
                added: 0, removed: 0, isSplit: false
            )),
            ("unchanged", DiffPaneHeader.header(
                isLoading: false, hasChanges: false, isBinary: false,
                added: 0, removed: 0, isSplit: false
            )),
        ] {
            XCTAssertTrue(
                header.leading.isEmpty,
                "a \(reason) diff has no stats to state, so it publishes none"
            )
        }
    }

    /// The style selector is the pane's one control and is never conditional: a diff can always
    /// be read either way, including while it loads, so hiding the picker would make the pane
    /// briefly un-switchable for no reason a reader could see.
    ///
    /// The selection is asserted to be one of the picker's own segment values, in both states.
    /// A segmented control whose selection names no segment draws as an empty picker — the
    /// exact defect that minting the two ends from one `RawRepresentable` enum exists to
    /// prevent, and the one a hand-written literal on either side would reintroduce.
    func testDiffAlwaysOffersItsStyleSelectorWithASelectionItsSegmentsCarry() {
        for isSplit in [false, true] {
            for isLoading in [false, true] {
                let header = DiffPaneHeader.header(
                    isLoading: isLoading,
                    hasChanges: true,
                    isBinary: false,
                    added: 1,
                    removed: 1,
                    isSplit: isSplit
                )
                let picker = header.trailing.first
                let values = segmentValues(picker)
                XCTAssertEqual(
                    header.trailing.count,
                    1,
                    "the diff pane's trailing run is exactly its style picker"
                )
                XCTAssertEqual(
                    picker?.id,
                    PaneHeaderCommand.diffStyle.rawValue,
                    "the picker's id IS the typed command the router resolves it back into"
                )
                XCTAssertEqual(
                    values?.count,
                    2,
                    "unified and split, minted from the view's own style enum"
                )
                guard let values, let selection = segmentedSelection(picker) else {
                    return XCTFail("the style control must be a segmented picker")
                }
                XCTAssertTrue(
                    values.contains(selection),
                    "selection \(selection) names no segment of \(values); a picker whose "
                        + "selection matches nothing draws empty"
                )
                XCTAssertEqual(
                    values.firstIndex(of: selection) == 1,
                    isSplit,
                    "the selected segment must be the style the pane is actually showing"
                )
            }
        }
    }

    /// The receipt that the picker's two ends cannot drift apart, written out by hand.
    ///
    /// Both ends of the contract are minted from `DiffStyle` inside the function under test, so
    /// an expectation derived from `DiffStyle` too would be a restatement of the code: a
    /// renamed raw value would appear on both sides at once and this would stay green while the
    /// wire vocabulary moved underneath it. The literal is what makes a change to that
    /// vocabulary — a rename, a third style — a decision someone has to take HERE, next to the
    /// segments the user sees and the selections the pane publishes.
    func testTheStylePickerOffersExactlyTheStatesThePaneCanBeIn() {
        let headers = [false, true].map { isSplit in
            DiffPaneHeader.header(
                isLoading: false, hasChanges: true, isBinary: false,
                added: 1, removed: 1, isSplit: isSplit
            ).trailing.first
        }
        XCTAssertEqual(
            segmentValues(headers.first ?? nil),
            ["unified", "split"],
            "the picker draws exactly these two options, in this order"
        )
        XCTAssertEqual(
            headers.compactMap { segmentedSelection($0) },
            ["unified", "split"],
            "and each state the pane can be in selects the segment of the same name; a "
                + "selection naming no segment draws as a picker with nothing chosen"
        )
    }

    // MARK: - Changes

    /// The branch name and the change count were the whole point of the 31-point bar this
    /// replaces, so they are what has to survive the move — and each is asserted in both
    /// directions, because a projection that published nothing would satisfy either
    /// suppression check on its own.
    ///
    /// "CHANGES" standing in for a branch is not decoration: a workspace that is not a
    /// repository still opens this pane, and a header that simply went blank there would leave
    /// the pane's own name to the chrome title alone.
    func testChangesNamesItsBranchAndCountsOnlyWhatItHasToCount() {
        let repo = ChangesPaneHeader.header(
            branch: "main",
            total: 4,
            layout: .tree,
            isLoading: false,
            canRefresh: true
        )
        XCTAssertEqual(
            repo.leading.count,
            3,
            "a dirty repository states its icon, its branch and its count"
        )
        XCTAssertEqual(imageSystemName(repo.leading.first), "arrow.trianglehead.branch")
        XCTAssertEqual(labelText(repo.leading.dropFirst().first), "main")
        XCTAssertEqual(badgeText(repo.leading.last), "4")

        let clean = ChangesPaneHeader.header(
            branch: "main",
            total: 0,
            layout: .tree,
            isLoading: false,
            canRefresh: true
        )
        XCTAssertEqual(
            clean.leading.count,
            2,
            "a clean tree has no count to state, and a zero badge is noise beside the "
                + "\"Working tree clean\" placeholder already filling the body"
        )
        XCTAssertNil(badgeText(clean.leading.last))

        let notARepo = ChangesPaneHeader.header(
            branch: nil,
            total: 0,
            layout: .tree,
            isLoading: false,
            canRefresh: true
        )
        XCTAssertEqual(
            labelText(notARepo.leading.dropFirst().first),
            "CHANGES",
            "with no branch to name, the pane still names itself"
        )
    }

    /// The refresh control's two conditions are different in kind, and conflating them is the
    /// defect this test exists to catch.
    ///
    /// `canRefresh` is about whether the pane reads git at all — the snapshot pane seeds its
    /// model and never does, so a button there could not work. `isLoading` is about a read
    /// already in flight, and it must DIM the button rather than remove it: the old bar carried
    /// `.disabled(model.isLoading)`, which is the guard against a second read racing the first,
    /// and a projection that dropped the item instead would both lose the guard's meaning and
    /// make the header jump every time the pane reloads.
    func testChangesHidesRefreshWithoutAutoLoadAndDisablesItWhileLoading() {
        let idle = ChangesPaneHeader.header(
            branch: "main", total: 2, layout: .tree, isLoading: false, canRefresh: true
        )
        XCTAssertEqual(
            idle.trailing.map(\.id),
            [
                PaneHeaderCommand.changesLayout.rawValue,
                PaneHeaderCommand.changesRefresh.rawValue,
            ],
            "status first, verbs last: the layout picker then the refresh button"
        )
        XCTAssertEqual(
            iconButtonIsEnabled(idle.trailing.last),
            true,
            "an idle pane can be refreshed"
        )

        let loading = ChangesPaneHeader.header(
            branch: "main", total: 2, layout: .tree, isLoading: true, canRefresh: true
        )
        XCTAssertEqual(
            loading.trailing.last?.id,
            PaneHeaderCommand.changesRefresh.rawValue,
            "a reload dims the button; it does not make it disappear and the header reflow"
        )
        XCTAssertEqual(
            iconButtonIsEnabled(loading.trailing.last),
            false,
            "a read is already in flight, so a second one is refused at the control"
        )

        let seeded = ChangesPaneHeader.header(
            branch: "main", total: 2, layout: .tree, isLoading: false, canRefresh: false
        )
        XCTAssertEqual(
            seeded.trailing.map(\.id),
            [PaneHeaderCommand.changesLayout.rawValue],
            "a pane that never reads git publishes no refresh button at all"
        )
    }

    /// The layout picker's two ends cannot drift apart, written out by hand for the reason the
    /// diff picker's expectation is.
    ///
    /// This one had the failure the literal exists to prevent: both sides came from
    /// `ChangesLayout.allCases`, which is exactly where `ChangesPaneHeader` mints its segments,
    /// so the equality could not fail. Renaming `tree`'s raw value to `"hierarchy"` — a change
    /// to the string the picker reports and the router resolves — left the test green.
    func testTheChangesLayoutPickerOffersExactlyTheLayoutsThePaneCanBeIn() {
        let headers = ChangesLayout.allCases.map { layout in
            ChangesPaneHeader.header(
                branch: "main", total: 1, layout: layout, isLoading: false, canRefresh: true
            ).trailing.first
        }
        XCTAssertEqual(
            segmentValues(headers.first ?? nil),
            ["tree", "flat"],
            "the picker draws exactly these two options, in this order"
        )
        XCTAssertEqual(
            headers.compactMap { segmentedSelection($0) },
            ["tree", "flat"],
            "and each layout the pane can be in selects the segment of the same name; a "
                + "selection naming no segment draws as a picker with nothing chosen"
        )
    }

    /// The layout segments are icon-only, so they draw no words at all — and two readers are
    /// left with nothing unless the projection supplies some: the pointer wants hover text, and
    /// VoiceOver wants a spoken name. The in-body picker this replaced showed "Tree" and "Flat"
    /// as visible text, so losing them is a real regression, not a missing nicety.
    ///
    /// `PaneHeaderSegment` fills whichever of the two its author left blank from the other, so
    /// one written string reaches both surfaces. What has to be pinned is that the projection
    /// writes one at all: drop `accessibilityLabel:` from `ChangesPaneHeader` and both readers
    /// degrade to the raw wire value, hovering "tree" where the user saw "Tree".
    func testTheChangesLayoutSegmentsCarryHoverTextAndASpokenName() {
        let picker = ChangesPaneHeader.header(
            branch: "main", total: 1, layout: .tree, isLoading: false, canRefresh: true
        ).trailing.first

        XCTAssertEqual(
            segments(picker)?.compactMap(\.tooltip),
            ["Tree", "Flat"],
            "an icon-only segment with no tooltip is a glyph the pointer cannot ask about"
        )
        XCTAssertEqual(
            segments(picker)?.compactMap(\.accessibilityLabel),
            ["Tree", "Flat"],
            "and the same sentence is what VoiceOver reads, from the one string its author "
                + "wrote"
        )
        XCTAssertEqual(
            segments(picker)?.compactMap(\.systemName),
            ["list.bullet.indent", "list.dash"],
            "both segments are icon-only, which is why the two readers above have nothing "
                + "else to fall back on"
        )
    }

    // MARK: - Automation

    func testAutomationHeaderProjectsCountAndScheduledDeliveryState() {
        let enabled = AutomationPaneHeader.header(
            scheduleCount: 3,
            schedulesEnabled: true
        )
        XCTAssertEqual(imageSystemName(enabled.leading.first), "clock.arrow.circlepath")
        XCTAssertEqual(badgeText(enabled.leading.last), "3")
        XCTAssertEqual(badgeText(enabled.trailing.first), "SCHEDULED")
        XCTAssertEqual(badgeTint(enabled.trailing.first), .muted)

        let paused = AutomationPaneHeader.header(
            scheduleCount: 0,
            schedulesEnabled: false
        )
        XCTAssertEqual(paused.leading.count, 1, "zero schedules needs no redundant count")
        XCTAssertEqual(badgeText(paused.trailing.first), "PAUSED")
        XCTAssertEqual(badgeTint(paused.trailing.first), .amber)
    }

    func testAutomationPaneReadsItsPublishedHostNativeHeader() {
        let published = AutomationPaneHeader.header(
            scheduleCount: 2,
            schedulesEnabled: false
        )
        let slot = WorkspaceSlot(
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .automation
        )

        XCTAssertEqual(
            PaneHeaderProjection.header(
                for: slot,
                published: published,
                pluginViewSections: []
            ),
            published
        )
    }

    // MARK: - File

    /// The file pane's status is a rank, not a set. All three states can be true at once — a
    /// save can fail on a buffer that is dirty AND conflicted — and the old top-right overlay
    /// resolved that with a single `if / else if / else if`. The header keeps that resolution
    /// rather than stacking two badges saying overlapping things in a 34-point strip.
    ///
    /// The exhaustive sweep at the end is what makes "exactly one" an invariant instead of
    /// three spot checks: no combination of the three inputs may produce two items.
    func testFilePublishesExactlyOneOfErrorConflictOrDirty() {
        let failed = FilePaneHeader.header(
            error: "Permission denied",
            hasDiskConflict: true,
            isDirty: true
        )
        XCTAssertEqual(failed.trailing.count, 1, "the loudest state wins outright")
        XCTAssertEqual(
            labelText(failed.trailing.first),
            "Permission denied",
            "a filesystem message is prose, so it is a label — 200 characters that shorten "
                + "with a visible ellipsis — and not a badge, whose 24-character chip cuts "
                + "mid-word and is sized for a count"
        )
        XCTAssertEqual(labelColor(failed.trailing.first), .red)

        let conflicted = FilePaneHeader.header(
            error: nil,
            hasDiskConflict: true,
            isDirty: true
        )
        XCTAssertEqual(conflicted.trailing.count, 1)
        XCTAssertEqual(
            badgeText(conflicted.trailing.first),
            "Changed on disk",
            "fifteen characters of fixed host text is genuinely badge-shaped"
        )
        XCTAssertEqual(badgeTint(conflicted.trailing.first), .amber)
        XCTAssertEqual(
            badgeTooltip(conflicted.trailing.first),
            "Another program edited this file while you had unsaved changes. "
                + "⌘S keeps what you see here.",
            "the badge states the fact; the tooltip is the ONLY place that says another "
                + "program touched the file, which is the thing a reader cannot infer from "
                + "\"Changed on disk\" and cannot act on without knowing"
        )

        let dirty = FilePaneHeader.header(error: nil, hasDiskConflict: false, isDirty: true)
        XCTAssertEqual(dirty.trailing.count, 1)
        XCTAssertTrue(
            isDot(dirty.trailing.first),
            "unsaved work is a dot, not a badge — it has no text worth 60 points of header"
        )
        XCTAssertEqual(dotTooltip(dirty.trailing.first), "Unsaved changes — ⌘S to save")

        XCTAssertEqual(
            FilePaneHeader.header(error: nil, hasDiskConflict: false, isDirty: false),
            .empty,
            "a clean, loaded file has nothing to say and draws the bare chrome"
        )

        for error in [nil, "Permission denied"] {
            for hasDiskConflict in [false, true] {
                for isDirty in [false, true] {
                    let header = FilePaneHeader.header(
                        error: error,
                        hasDiskConflict: hasDiskConflict,
                        isDirty: isDirty
                    )
                    XCTAssertLessThanOrEqual(
                        header.trailing.count,
                        1,
                        "error=\(error ?? "nil") conflict=\(hasDiskConflict) dirty=\(isDirty) "
                            + "published \(header.trailing.count) items; the three states are "
                            + "ranked, never combined"
                    )
                    XCTAssertTrue(
                        header.leading.isEmpty,
                        "the chrome title already names the file"
                    )
                }
            }
        }
    }

    /// A read or write failure is prose of whatever length the filesystem cares to produce, and
    /// both of the bounds it meets are probed here at their exact edge — a message that merely
    /// looks long proves nothing about a cap it never reaches.
    ///
    /// The label's 200 characters are what the reader sees shortened; the tooltip's 1024 are
    /// `PATH_MAX`, sized so a message can always at least name the file it failed on. Past
    /// that, the tooltip clamps too: it is a bound, not infinity, and a producer holding a
    /// genuinely unbounded string has to summarise it rather than assume this will hold.
    func testALongFileErrorTruncatesInItsLabelAndSurvivesInItsTooltip() {
        let atTheTooltipCap = String(
            repeating: "u", count: PaneHeaderItem.maximumTooltipLength
        )
        let header = FilePaneHeader.header(
            error: atTheTooltipCap,
            hasDiskConflict: false,
            isDirty: false
        )
        XCTAssertEqual(
            labelText(header.trailing.first)?.count,
            PaneHeaderItem.maximumLabelLength,
            "the label is clamped by the vocabulary, not by the producer"
        )
        XCTAssertEqual(
            labelTooltip(header.trailing.first),
            atTheTooltipCap,
            "a message the length of PATH_MAX survives whole, which the 200-character label "
                + "does not"
        )

        let overTheTooltipCap = atTheTooltipCap + "!"
        let clamped = FilePaneHeader.header(
            error: overTheTooltipCap,
            hasDiskConflict: false,
            isDirty: false
        )
        XCTAssertEqual(
            labelTooltip(clamped.trailing.first)?.count,
            PaneHeaderItem.maximumTooltipLength,
            "one character past the cap is one character dropped — the header is a bounded "
                + "value at every length, not only at plausible ones"
        )

        // A message that fits says everything twice on purpose: the reader who hovers gets the
        // sentence whether or not the width happened to cut it.
        let short = FilePaneHeader.header(
            error: "Permission denied",
            hasDiskConflict: false,
            isDirty: false
        )
        XCTAssertEqual(labelText(short.trailing.first), "Permission denied")
        XCTAssertEqual(labelTooltip(short.trailing.first), "Permission denied")
    }

    // MARK: - Typed routing

    /// The receipt that the built-in half of the header stays typed.
    ///
    /// Every interactive item a built-in pane publishes must resolve back into a
    /// `PaneHeaderCommand`, because that resolution is the ONLY route the canvas offers a
    /// non-plugin pane: an id that fails it is a control the user can click and nothing
    /// happens. The exact-set assertion is what gives this test teeth — a projection that
    /// published no controls at all would satisfy "every id resolves" vacuously.
    func testEveryInteractiveBuiltInHeaderItemIDResolvesBackToAPaneHeaderCommand() {
        let headers = [
            DiffPaneHeader.header(
                isLoading: false, hasChanges: true, isBinary: false,
                added: 4, removed: 4, isSplit: true
            ),
            ChangesPaneHeader.header(
                branch: "main", total: 2, layout: .tree, isLoading: false, canRefresh: true
            ),
            ChangesPaneHeader.header(
                branch: nil, total: 0, layout: .flat, isLoading: true, canRefresh: false
            ),
            FilePaneHeader.header(error: "boom", hasDiskConflict: true, isDirty: true),
            FilePaneHeader.header(error: nil, hasDiskConflict: false, isDirty: false),
        ]
        let interactive = headers
            .flatMap { $0.leading + $0.trailing }
            .filter(\.isInteractive)
            .map(\.id)

        XCTAssertEqual(
            Set(interactive),
            [
                PaneHeaderCommand.diffStyle.rawValue,
                PaneHeaderCommand.changesLayout.rawValue,
                PaneHeaderCommand.changesRefresh.rawValue,
            ],
            "the migrated built-in panes contribute exactly these interactive controls"
        )
        for id in interactive {
            XCTAssertNotNil(
                PaneHeaderCommand(rawValue: id),
                "\(id) is clickable but resolves to no typed command, so its click is dropped"
            )
        }
    }

    // MARK: - The round trip
    //
    // Everything above is the UP half: what a pane decides to say. These two mount a real
    // pane and drive the DOWN half — `PaneHeaderStore.perform` — to the state the control
    // names and back out through the header the pane republishes. Nothing else covers that
    // path: the `.onAppear` registration, the `PaneHeaderCommand` → view-state decode and the
    // freshness of what the handler closed over are all checked by the compiler alone, and the
    // compiler is happy with a handler that reads a value captured three re-roots ago.
    //
    // They mount rather than call a helper because the defect they exist to catch is a
    // property of the MOUNT: `SpatialSlotCardView.configure` assigns `contentHost.rootView`
    // in place instead of remounting, so `.onAppear` fires once for the life of the pane while
    // `.onChange(of: root)` keeps firing. A test that called the registration itself would
    // register it as often as it liked and never see the difference.

    /// The style picker's whole loop, in the order a user makes it happen: the pane publishes
    /// its picker, a click on that picker arrives as a typed command, the pane's own `@State`
    /// takes it, and the next header says so.
    ///
    /// Diff is the pane whose handler capture is SAFE — it closes over `$style`, a `Binding`
    /// into `@State`, which survives the rootView being replaced — so this is the control that
    /// proves the harness reports a working loop as working, next to the Changes test below
    /// that proves it reports a broken one as broken.
    @MainActor
    func testTheDiffStyleCommandReachesThePaneAndComesBackInItsHeader() {
        let slotID = UUID()
        let headers = PaneHeaderStore()
        let mounted = mount(
            DiffSlotView(
                request: DiffRequest(
                    source: .inline(oldText: "one\ntwo\n", newText: "one\ntwo\nthree\n"),
                    fileName: "sample.swift",
                    title: "sample.swift"
                ),
                slotID: slotID,
                headerStore: headers
            )
        )
        defer { mounted.window.close() }

        func selection() -> String? {
            segmentedSelection((headers.headers[slotID] ?? .empty).trailing.first)
        }

        settle(
            until: { selection() != nil },
            "a mounted diff pane must publish its style picker"
        )
        XCTAssertEqual(selection(), "unified", "the pane starts unified")

        headers.perform(.diffStyle, value: "split", for: slotID)

        settle(
            until: { selection() == "split" },
            "a `diff.style` command carrying \"split\" must reach the pane's own style state "
                + "and come back out in the header it republishes"
        )
    }

    /// The refresh button must re-read the workspace the pane is SHOWING, not the one it was
    /// mounted with.
    ///
    /// A pane survives its root changing — `SpatialSlotCardView.configure` hands the same
    /// hosting view a new root rather than building a new pane, which is why `ChangesPanelView`
    /// carries an `.onChange(of: root)` at all. `.onAppear` does not fire again, so a handler
    /// registered there holding a captured root holds the mount-time one forever, and the
    /// refresh button quietly re-reads a repository the user is no longer looking at.
    ///
    /// Both repositories are renamed on disk before the refresh, so a refresh of the right root
    /// and a refresh of the stale one produce different, equally non-empty answers — the
    /// failure is a wrong branch name, never an absent one, which is what stops "nothing
    /// happened" from passing for "the right thing happened".
    @MainActor
    func testChangesRefreshRereadsTheRootThePaneIsShowingNotTheOneItMountedWith() throws {
        let first = try makeRepository(branch: "alpha")
        let second = try makeRepository(branch: "beta")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let slotID = UUID()
        let headers = PaneHeaderStore()
        let mounted = mount(
            ChangesPanelView(root: first, slotID: slotID, headerStore: headers, store: nil)
        )
        defer { mounted.window.close() }

        func branch() -> String? {
            labelText((headers.headers[slotID] ?? .empty).leading.dropFirst().first)
        }

        settle(until: { branch() == "alpha" }, "the pane reads the root it mounted with")

        // Exactly what the canvas does to a live pane: same hosting view, same `@State`, new
        // root. `.onAppear` is behind us; only `.onChange(of: root)` runs.
        mounted.hosting.rootView = ChangesPanelView(
            root: second,
            slotID: slotID,
            headerStore: headers,
            store: nil
        )
        settle(until: { branch() == "beta" }, "a re-rooted pane reads its new root")

        try git(["symbolic-ref", "HEAD", "refs/heads/alpha-again"], in: first)
        try git(["symbolic-ref", "HEAD", "refs/heads/beta-again"], in: second)

        headers.perform(.changesRefresh, value: nil, for: slotID)

        settle(
            until: { branch() != "beta" },
            "the refresh command must reach the pane and re-read something"
        )
        XCTAssertEqual(
            branch(),
            "beta-again",
            "the refresh re-read the wrong workspace: the handler is holding the root the "
                + "pane mounted with instead of the one it is showing"
        )
    }

    // MARK: - The rendered control

    /// A segmented header control's per-segment hover text has to survive all the way into
    /// AppKit, and the only place that can be checked is on the AppKit object.
    ///
    /// `PaneHeaderItemView` draws `segmented` as a SwiftUI `Picker` with `.pickerStyle(.segmented)`,
    /// which macOS bridges to an `NSSegmentedControl` by extracting each label's Text or Image.
    /// Whether a `.help` hung on one of those labels comes out the other side as
    /// `toolTip(forSegment:)` is not a fact the value type can state and not a fact the solver
    /// can state — it is a fact about the bridge, and `PaneHeaderSegment.tooltip` is a lie unless
    /// it holds. So this mounts the real `PaneHeaderHostView` the card mounts, hands it the real
    /// solution the card hands it, and asks the real control.
    ///
    /// The two shipped pickers are asserted together because they disagree on purpose, and that
    /// disagreement is what stops this from passing vacuously. Changes' segments are icon-only,
    /// so `PaneHeaderSegment` lends the spoken name to the hover text and both segments must
    /// carry one. Diff's segments show their own words, so nothing is synthesised and neither
    /// segment may carry any — an empty string included, because AppKit shows a registered `""`
    /// as a blank yellow box. A renderer that dropped every tooltip fails the first half; one
    /// that manufactured a tooltip per segment fails the second.
    @MainActor
    func testASegmentedHeaderControlCarriesItsPerSegmentTooltipsIntoAppKit() throws {
        let iconOnly = ChangesPaneHeader.header(
            branch: "main",
            total: 0,
            layout: .tree,
            isLoading: false,
            canRefresh: false
        )
        XCTAssertEqual(
            try XCTUnwrap(segments(iconOnly.trailing.first)).map(\.tooltip),
            ["Tree", "Flat"],
            "the Changes picker no longer authors the hover text this test is about"
        )
        XCTAssertEqual(
            try renderedSegmentTooltips(of: iconOnly),
            ["Tree", "Flat"],
            "the icon-only layout picker reaches AppKit with no per-segment hover text: two "
                + "unlabelled glyphs the pointer cannot explain"
        )

        let labelled = DiffPaneHeader.header(
            isLoading: false,
            hasChanges: true,
            isBinary: false,
            added: 1,
            removed: 1,
            isSplit: false
        )
        XCTAssertEqual(
            try XCTUnwrap(segments(labelled.trailing.first)).map(\.tooltip),
            [nil, nil],
            "the Diff picker shows its own words, so it authors no hover text"
        )
        XCTAssertEqual(
            try renderedSegmentTooltips(of: labelled),
            [nil, nil],
            "a segment nobody wrote hover text for arrived in AppKit carrying some"
        )
    }

    /// `NSSegmentedControl.toolTip(forSegment:)` for every segment of the one picker in
    /// `header.trailing`, read off a live view tree mounted the way the card mounts one.
    ///
    /// The solution comes from the real solver and `LivePaneHeaderMetrics`, and the run is drawn
    /// by the real `PaneHeaderHostView` inside a plain `NSView` standing in for the card — the
    /// nesting matters, because what is being checked is whether the bridge survives it.
    @MainActor
    private func renderedSegmentTooltips(
        of header: PaneHeader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String?] {
        let solution = PaneHeaderLayout.solve(
            header: header,
            showsDot: false,
            titleIdealWidth: 96,
            glyphSize: CGSize(width: 19, height: 13),
            titleHeight: 13,
            bounds: CGSize(width: 520, height: 200),
            headerHeight: 34,
            metrics: LivePaneHeaderMetrics()
        )
        let hostRect = try XCTUnwrap(
            solution.trailingHostRect,
            "the solver placed no trailing run, so there is no picker to read",
            file: file,
            line: line
        )

        let card = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
        let host = PaneHeaderHostView()
        host.frame = hostRect
        card.addSubview(host)
        host.apply(solution, run: .trailing, isActive: true, perform: { _ in })

        let window = NSWindow(
            contentRect: card.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Same reason as `mount`: a programmatic window's `close()` would otherwise over-release.
        window.isReleasedWhenClosed = false
        window.contentView = card
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        card.layoutSubtreeIfNeeded()
        // SwiftUI builds its AppKit representation on a later turn of the run loop, so the
        // control does not exist the instant `apply` returns.
        settle(
            until: { Self.segmentedControl(in: host) != nil },
            "the segmented picker never reached AppKit at all",
            file: file,
            line: line
        )
        let control = try XCTUnwrap(
            Self.segmentedControl(in: host),
            "no NSSegmentedControl under the header host",
            file: file,
            line: line
        )
        return (0..<control.segmentCount).map { control.toolTip(forSegment: $0) }
    }

    @MainActor
    private static func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews {
            if let found = segmentedControl(in: subview) { return found }
        }
        return nil
    }

    /// A tooltip on an item the header does NOT let the pointer touch still reaches AppKit.
    ///
    /// `dot`, `label`, `badge` and `image` all answer `isInteractive == false`, so
    /// `PaneHeaderHostView.hitTest` returns `nil` over every one of them — the header hands
    /// those points back to the pane's drag surface. That reads like it should take the tooltip
    /// with it, because the tooltip is the ONLY pointer affordance those four kinds have: the
    /// vocabulary decodes `tooltip` on all of them and `PaneHeaderItemView` hangs
    /// `.paneHeaderHelp` on all of them. Agent Lens now keeps current action in one spoken
    /// Session status line instead of putting it in chrome, while plugin-contributed decorative
    /// items still rely on this tooltip path. If the string does not arrive, that contributor's
    /// sentence is reachable by nobody and the honest fix is to stop offering the field.
    ///
    /// It arrives, and hit-testing is not the mechanism that carries it. SwiftUI does not put
    /// these strings on `NSView.toolTip` — that is `nil` on every view in the mounted tree,
    /// for the interactive items too. It installs one full-bounds `NSTrackingArea` per
    /// `NSHostingView` owned by a `SwiftUI.TooltipBridge.DynamicTooltipManager`, and AppKit asks
    /// THAT object, per point, through `dynamicToolTipStringAtPoint:trackingRect:`. So this
    /// mounts the runs the card mounts and puts the same question to the same resolver AppKit
    /// puts it to, at each item's own centre. The two mechanisms are independent, which is the
    /// whole finding, and the helper asserts both halves of it: the header really does decline
    /// the pointer over each of these items, and the tooltip really does resolve there anyway.
    ///
    /// Both directions in one header, so it cannot pass vacuously. A resolver that answered
    /// `nil` everywhere fails the four authored strings; one that manufactured a string per item
    /// fails the two written with none. The exact strings are asserted rather than mere
    /// presence, because a bridge that returned a neighbour's tooltip would be worse than one
    /// that returned nothing.
    ///
    /// The selector is SPI. If a future macOS renames it this test stops finding a resolver and
    /// fails loudly — which is the correct outcome, because that is the same event as "the
    /// tooltip mechanism changed underneath a vocabulary that promises tooltips on four kinds
    /// of item", and it wants re-measuring rather than a green suite.
    @MainActor
    func testANonInteractiveHeaderItemCarriesItsTooltipIntoAppKit() throws {
        let header = PaneHeader(
            leading: [
                .dot(id: "dot-with", tint: .amber, tooltip: "Waiting on you"),
                .label(
                    id: "label-with",
                    text: "Editing",
                    weight: .regular,
                    color: .muted,
                    truncation: .tail,
                    tooltip: "Editing README.md"
                )
            ],
            trailing: [
                .badge(id: "badge-with", text: "3", tint: .amber, tooltip: "3 files changed"),
                .image(
                    id: "image-with",
                    systemName: "exclamationmark.triangle",
                    tint: .amber,
                    tooltip: "Agent Lens has diagnostics"
                ),
                .badge(id: "badge-without", text: "9", tint: .muted, tooltip: nil),
                .image(id: "image-without", systemName: "circle", tint: .muted, tooltip: nil)
            ]
        )

        XCTAssertEqual(
            try renderedItemTooltips(of: header),
            [
                "dot-with": "Waiting on you",
                "label-with": "Editing README.md",
                "badge-with": "3 files changed",
                "image-with": "Agent Lens has diagnostics",
                "badge-without": nil,
                "image-without": nil
            ],
            "a non-interactive header item's hover text no longer reaches AppKit: the four kinds "
                + "that decode `tooltip` and draw no control offer a field the pointer never sees"
        )
    }

    /// Every placed item's id mapped to the string AppKit's own dynamic-tooltip resolver returns
    /// at that item's centre, read off a live view tree mounted the way the card mounts one.
    ///
    /// Along the way it asserts the thing that made the question worth asking: for each
    /// non-interactive item, the card's hit test declines the point. That is measured here
    /// rather than described in prose so the day it stops being true — the day these items
    /// start taking the mouse — this helper says so instead of quietly proving something easier.
    @MainActor
    private func renderedItemTooltips(
        of header: PaneHeader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: String?] {
        let bounds = CGSize(width: 720, height: 200)
        let solution = PaneHeaderLayout.solve(
            header: header,
            showsDot: false,
            titleIdealWidth: 96,
            glyphSize: CGSize(width: 19, height: 13),
            titleHeight: 13,
            bounds: bounds,
            headerHeight: 34,
            metrics: LivePaneHeaderMetrics()
        )

        let card = NSView(frame: NSRect(origin: .zero, size: bounds))
        var hosts: [(run: PaneHeaderLayout.Run, view: PaneHeaderHostView)] = []
        for run in [PaneHeaderLayout.Run.leading, .trailing] {
            let hostRect = run == .leading
                ? solution.leadingHostRect
                : solution.trailingHostRect
            guard let hostRect else { continue }
            let host = PaneHeaderHostView()
            host.frame = hostRect
            card.addSubview(host)
            host.apply(solution, run: run, isActive: true, perform: { _ in })
            hosts.append((run, host))
        }

        let window = NSWindow(
            contentRect: card.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Same reason as `mount`: a programmatic window's `close()` would otherwise over-release.
        window.isReleasedWhenClosed = false
        window.contentView = card
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        card.layoutSubtreeIfNeeded()
        // SwiftUI installs the tooltip bridge on a later turn of the run loop, so it does not
        // exist the instant `apply` returns.
        settle(
            until: { hosts.allSatisfy { Self.toolTipResolver(of: $0.view) != nil } },
            "SwiftUI never installed a tooltip resolver on a mounted header run: nothing in the "
                + "strip can answer the pointer, whatever the vocabulary decoded",
            file: file,
            line: line
        )

        var resolved: [String: String?] = [:]
        for (run, host) in hosts {
            let resolver = try XCTUnwrap(
                Self.toolTipResolver(of: host),
                "no dynamic-tooltip resolver under the \(run) header host",
                file: file,
                line: line
            )
            for placement in solution.placements where placement.run == run {
                let centre = CGPoint(x: placement.rect.midX, y: placement.rect.midY)
                if !placement.item.isInteractive {
                    let hit = card.hitTest(centre)
                    XCTAssertFalse(
                        hit?.isDescendant(of: host) ?? false,
                        "\(placement.item.id) is non-interactive, so the header must hand its "
                            + "point back to the pane's drag surface; this test's premise is gone",
                        file: file,
                        line: line
                    )
                }
                resolved[placement.item.id] = Self.dynamicToolTip(
                    from: resolver,
                    at: CGPoint(x: centre.x - host.frame.minX, y: centre.y - host.frame.minY)
                )
            }
        }
        return resolved
    }

    /// AppKit's per-point tooltip question, asked of the object AppKit asks.
    private static let dynamicToolTipSelector =
        NSSelectorFromString("dynamicToolTipStringAtPoint:trackingRect:")

    /// The `NSTrackingArea` owner SwiftUI installs to answer that question, if it installed one.
    @MainActor
    private static func toolTipResolver(of host: NSView) -> NSObject? {
        host.trackingAreas
            .lazy
            .compactMap { $0.owner as? NSObject }
            .first { $0.responds(to: dynamicToolTipSelector) }
    }

    /// `- (id)dynamicToolTipStringAtPoint:(CGPoint)point trackingRect:(CGRect *)outRect`, whose
    /// shape is read off the live method's ObjC type encoding rather than assumed. The out-rect
    /// is the region the returned string covers; AppKit re-asks once the pointer leaves it, and
    /// it is discarded here because the question is which string, not for how long.
    @MainActor
    private static func dynamicToolTip(from resolver: NSObject, at point: CGPoint) -> String? {
        guard let method = class_getInstanceMethod(type(of: resolver), dynamicToolTipSelector)
        else { return nil }
        typealias Resolve = @convention(c) (
            NSObject, Selector, CGPoint, UnsafeMutablePointer<CGRect>?
        ) -> AnyObject?
        let resolve = unsafeBitCast(method_getImplementation(method), to: Resolve.self)
        var covered = CGRect.zero
        return resolve(resolver, dynamicToolTipSelector, point, &covered) as? String
    }

    // MARK: - The snapshot's copy of the card

    /// The offscreen snapshot draws the ✕ from its own copy of the card's geometry, because the
    /// solver deliberately does not place that control — it only reserves room for it. The
    /// duplication is documented in `DiffSnapshot.swift`, which makes it deliberate but not
    /// safe: nothing stopped the card from moving its close button and leaving the snapshot
    /// drawing one 4 points off, silently, in the only render a headless machine can look at.
    ///
    /// So the two are read against each other. This asserts on source text rather than on a
    /// laid-out card because `SpatialSlotCardView.closeButton` is private and constructing a
    /// card means standing up the whole canvas; the literals in `layout()` are the thing being
    /// copied, so they are the honest thing to compare. A reformat of that assignment fails
    /// this test, and that failure is the prompt to re-check the copy — which is the same
    /// prompt a real drift would give.
    func testTheSnapshotsCloseControlMatchesTheCardsOwnGeometry() throws {
        let card = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/TenonApp/Canvas/SpatialSlotCardView.swift"),
            encoding: .utf8
        )
        let assignment = try XCTUnwrap(
            card.range(of: "closeButton.frame = CGRect("),
            "the card no longer assigns its close button a frame; the snapshot's copy of that "
                + "geometry has nothing left to track"
        )
        let body = String(card[assignment.upperBound...].prefix(200))

        XCTAssertEqual(
            try firstNumber(in: body, matching: #"x: max\(bounds\.width - (\d+), 0\)"#),
            PaneChromeMetrics.closeInset,
            "the card insets its close button from the trailing edge by a different amount "
                + "than the snapshot draws one"
        )
        XCTAssertEqual(
            try firstNumber(in: body, matching: #"width: (\d+)"#),
            PaneChromeMetrics.closeWidth,
            "the card's close button is a different width than the snapshot draws"
        )
    }

    private func firstNumber(in text: String, matching pattern: String) throws -> CGFloat {
        let expression = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(
            expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            "no \(pattern) in the card's close-button frame; the snapshot's copy cannot be "
                + "checked against a shape that changed"
        )
        let captured = try XCTUnwrap(Range(match.range(at: 1), in: text))
        return try CGFloat(XCTUnwrap(Double(text[captured])))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - Mounting

    /// A pane in a window, which is what makes `.onAppear` run.
    ///
    /// The window is returned so the caller closes it: these panes start real work — a git
    /// read, a diff — and one left attached to a key window outlives the test that made it.
    ///
    /// `isReleasedWhenClosed` is turned OFF, and that is not tidiness. It defaults to `true`
    /// for a programmatically created `NSWindow`, a Cocoa-era contract under which `close()`
    /// hands back the window's own retain — which ARC has already accounted for through the
    /// reference this function returns. Leaving it on makes `close()` an over-release, and an
    /// over-release does not fail here: it corrupts the process and takes down some unrelated
    /// suite a thousand tests later. Verified by running the whole suite both ways.
    @MainActor
    private func mount<Content: View>(
        _ content: Content
    ) -> (window: NSWindow, hosting: NSHostingView<Content>) {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    /// Turns the main run loop until the condition holds.
    ///
    /// A mounted pane's work is spread across a SwiftUI update, a `Task`, and a subprocess, so
    /// there is no single thing to await; running the loop is what lets all three make
    /// progress. The condition is polled rather than slept on so a passing test costs
    /// milliseconds, and the timeout is generous because the only thing a short one buys is a
    /// flake on a loaded machine.
    @MainActor
    private func settle(
        until reached: () -> Bool,
        _ message: @autoclosure () -> String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !reached(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(reached(), message(), file: file, line: line)
    }

    /// An empty repository on a named branch. `symbolic-ref` names the branch without a commit,
    /// which is all `git status --branch` needs to report one.
    private func makeRepository(branch: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tenon-pane-header-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--quiet"], in: root)
        try git(["symbolic-ref", "HEAD", "refs/heads/" + branch], in: root)
        return root
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "git \(arguments.joined(separator: " ")) failed in \(directory.path)"
        )
    }
}
