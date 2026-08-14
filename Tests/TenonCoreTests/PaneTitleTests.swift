import Foundation
import XCTest
@testable import TenonCore

final class PaneTitleTests: XCTestCase {
    func testSanitizingCollapsesWhitespaceBoundsLengthAndTreatsBlankAsAutomatic() {
        XCTAssertEqual(PaneTitle.sanitized("  Build\n  API   tests  "), "Build API tests")
        XCTAssertEqual(PaneTitle.sanitized(String(repeating: "a", count: 90))?.count, 60)
        XCTAssertNil(PaneTitle.sanitized(" \n\t "))
    }

    func testRenameChangesOnlyPresentationAndPublishesAnIdentityFact() throws {
        var catalog = WorkspaceCatalog(
            name: "Project",
            path: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let slotID = try XCTUnwrap(catalog.activeSlotID)
        let before = try XCTUnwrap(catalog.slot(id: slotID))
        let owner = try XCTUnwrap(catalog.owner(ofSlot: slotID))

        XCTAssertEqual(
            catalog.renameSlot(slotID, to: "  API\nserver  "),
            [.slotIdentityChanged(
                slot: slotID,
                tab: owner.tabID,
                workspace: owner.workspaceID
            )]
        )

        let renamed = try XCTUnwrap(catalog.slot(id: slotID))
        XCTAssertEqual(renamed.customTitle, "API server")
        XCTAssertEqual(renamed.id, before.id)
        XCTAssertEqual(renamed.rect, before.rect)
        XCTAssertEqual(renamed.content, before.content)
        XCTAssertTrue(catalog.renameSlot(slotID, to: "API server").isEmpty)

        XCTAssertEqual(catalog.renameSlot(slotID, to: "   ").count, 1)
        XCTAssertNil(catalog.slot(id: slotID)?.customTitle)
    }

    func testMovingPaneToANewTabKeepsItsCustomTitle() throws {
        var catalog = WorkspaceCatalog(
            name: "Project",
            path: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let slotID = try XCTUnwrap(catalog.activeSlotID)
        _ = catalog.renameSlot(slotID, to: "Pinned name")

        XCTAssertFalse(catalog.moveSlotToNewTab(slotID).isEmpty)
        XCTAssertEqual(catalog.slot(id: slotID)?.customTitle, "Pinned name")
    }

    func testCustomTitleRoundTripsSeparatelyFromTerminalPlaceholderTitle() throws {
        var catalog = WorkspaceCatalog(
            name: "Project",
            path: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let slotID = try XCTUnwrap(catalog.activeSlotID)
        _ = catalog.renameSlot(slotID, to: "Pinned pane")

        let encoded = try JSONEncoder().encode(WorkspaceCatalogSnapshot.document(
            capturing: catalog,
            titles: [slotID: "dynamic shell title"]
        ))
        let decoded = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: encoded
        )
        let restored = try XCTUnwrap(WorkspaceCatalogSnapshot.restore(
            decoded,
            isDirectory: { _ in true },
            isFileReadable: { _ in true },
            isKnownPluginView: { _, _ in true }
        ))

        XCTAssertEqual(restored.catalog.slot(id: slotID)?.customTitle, "Pinned pane")
        XCTAssertEqual(restored.titles[slotID], "dynamic shell title")
    }

    func testDocumentWithoutCustomTitleDecodesAsAutomatic() throws {
        let catalog = WorkspaceCatalog(
            name: "Project",
            path: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let document = WorkspaceCatalogSnapshot.document(capturing: catalog)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
                as? [String: Any]
        )
        var workspaces = try XCTUnwrap(object["workspaces"] as? [[String: Any]])
        var tabs = try XCTUnwrap(workspaces[0]["tabs"] as? [[String: Any]])
        var slots = try XCTUnwrap(tabs[0]["slots"] as? [[String: Any]])
        slots[0].removeValue(forKey: "customTitle")
        tabs[0]["slots"] = slots
        workspaces[0]["tabs"] = tabs
        object["workspaces"] = workspaces

        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            WorkspaceCatalogSnapshot.Document.self,
            from: oldData
        )
        XCTAssertNil(decoded.workspaces[0].tabs[0].slots[0].customTitle)
    }
}
