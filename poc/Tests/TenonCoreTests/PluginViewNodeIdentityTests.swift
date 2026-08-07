import Foundation
@testable import TenonCore
import XCTest

/// T-093. A plugin republishing its tree must not move one control's state onto another.
///
/// SwiftUI keeps a subtree's state — a text field's draft, focus, a live web surface — attached
/// to that subtree's identity. Identifying siblings by position makes "insert a row above" mean
/// "hand every field below it the draft of the field that used to be there".
final class PluginViewNodeIdentityTests: XCTestCase {
    func testAFieldKeepsItsIdentityWhenASiblingIsInsertedAboveIt() {
        let field = PluginViewNode.textfield(
            value: "https://example.com",
            placeholder: "URL",
            action: "navigate"
        )
        let before = IdentifiedPluginViewNode.identify([field])
        let after = IdentifiedPluginViewNode.identify([
            .text("a new status line", style: .body, weight: .regular, color: .text),
            field,
        ])

        XCTAssertEqual(
            before.first?.id,
            after.last?.id,
            "the field is the same control before and after the insertion"
        )
    }

    func testAWebSurfaceKeepsItsIdentityWhenSiblingsReorder() {
        let surface = PluginViewNode.webview(surfaceID: "browser-main")
        let first = IdentifiedPluginViewNode.identify([surface, .divider])
        let reordered = IdentifiedPluginViewNode.identify([.divider, surface])

        XCTAssertEqual(first.first?.id, reordered.last?.id)
    }

    /// The case that makes positional identity actively wrong rather than merely fragile: the
    /// stateful node is nested, so rebuilding its container takes its draft with it.
    func testAContainerInheritsTheIdentityOfTheStatefulNodesInsideIt() {
        let card = PluginViewNode.card(children: [
            .text("Title", style: .body, weight: .semibold, color: .text),
            .textfield(value: "", placeholder: "Name", action: "rename"),
        ])
        let before = IdentifiedPluginViewNode.identify([card])
        let after = IdentifiedPluginViewNode.identify([.divider, card])

        XCTAssertEqual(before.first?.id, after.last?.id)
    }

    func testStatelessSiblingsKeepPositionalIdentity() {
        let identified = IdentifiedPluginViewNode.identify([.divider, .spacer])

        XCTAssertEqual(identified.map(\.id), ["position:0", "position:1"])
    }

    /// Two controls that authored the same identifier is a plugin bug. Rendering one of them is
    /// a worse answer than rendering both, so identity stays unique.
    func testDuplicateAuthoredIdentifiersStayDistinct() {
        let duplicate = PluginViewNode.textfield(
            value: "",
            placeholder: "",
            action: "same"
        )
        let identified = IdentifiedPluginViewNode.identify([duplicate, duplicate])

        XCTAssertEqual(identified.count, 2)
        XCTAssertNotEqual(identified[0].id, identified[1].id)
    }
}
