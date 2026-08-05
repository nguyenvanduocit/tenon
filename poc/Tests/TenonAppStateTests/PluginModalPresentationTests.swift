import TenonCore
import TenonIntentCore
import XCTest
@testable import TenonApp

/// T-066: which modal the shell shows.
///
/// The rule has to be a pure function of the published sections, because the alternative
/// — deciding inside the SwiftUI overlay — is exactly the kind of layout rule that cannot
/// be asserted without a window (docs/tdd.md), and the T-055 board proved how much a
/// green suite can miss there.
final class PluginModalPresentationTests: XCTestCase {
    func testNoSectionAskingForAModalPresentsNothing() {
        XCTAssertNil(
            PluginModalPresentation.resolve(from: [
                section(plugin: "dev.tenon.kanban", view: "board", instance: "pane-1"),
            ])
        )
    }

    func testTheModalCarriesItsOwningViewSoDismissRoutesBackToIt() {
        let resolved = PluginModalPresentation.resolve(from: [
            section(plugin: "dev.tenon.clock", view: "clock"),
            section(
                plugin: "dev.tenon.kanban",
                view: "board",
                instance: "pane-1",
                modal: PluginViewModal(
                    title: "T-101",
                    body: .text("detail", style: .body, weight: .regular, color: .default),
                    dismissAction: "close"
                )
            ),
        ])

        let presentation = try? XCTUnwrap(resolved)
        XCTAssertEqual(presentation?.pluginID, "dev.tenon.kanban")
        XCTAssertEqual(presentation?.viewID, "board")
        XCTAssertEqual(presentation?.instanceID, "pane-1")
        XCTAssertEqual(presentation?.modal.dismissAction, "close")
    }

    /// Two panes of the same plugin can each hold a modal — two kanban boards, both with
    /// a task open. Exactly one is shown, and it is the first in publish order rather than
    /// whichever section the renderer reached last, so the sheet does not flicker between
    /// them on every republish.
    func testOnlyOneModalIsPresentedAndItIsTheFirstInPublishOrder() {
        let resolved = PluginModalPresentation.resolve(from: [
            section(
                plugin: "dev.tenon.kanban",
                view: "board",
                instance: "pane-1",
                modal: PluginViewModal(title: "first", body: nil, dismissAction: "close")
            ),
            section(
                plugin: "dev.tenon.kanban",
                view: "board",
                instance: "pane-2",
                modal: PluginViewModal(title: "second", body: nil, dismissAction: "close")
            ),
        ])

        XCTAssertEqual(resolved?.modal.title, "first")
        XCTAssertEqual(resolved?.instanceID, "pane-1")
    }

    /// The header is bounded like every other string that crosses the boundary: a plugin
    /// cannot publish a title that pushes the close control off the sheet.
    func testTheModalTitleIsBounded() {
        let modal = PluginViewModal(
            title: String(repeating: "x", count: 400),
            body: nil,
            dismissAction: "close"
        )
        XCTAssertEqual(modal.title.count, PluginViewModal.maximumTitleLength)
    }

    private func section(
        plugin: PluginID,
        view: String,
        instance: String? = nil,
        modal: PluginViewModal? = nil
    ) -> PluginViewSection {
        PluginViewSection(
            pluginID: plugin,
            viewID: view,
            instanceID: instance,
            instanced: instance != nil,
            title: view,
            subtitle: nil,
            actions: [],
            items: [],
            body: nil,
            modal: modal
        )
    }
}
