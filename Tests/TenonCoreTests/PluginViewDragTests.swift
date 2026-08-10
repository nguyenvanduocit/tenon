import XCTest
import TenonIntentCore
@testable import TenonCore

/// T-056. Drag-and-drop is CONTRIBUTION metadata plus the existing select EVENT, so the
/// only thing the host decides is which drags it admits. That decision is pure, and these
/// are the rules it has to keep — each one asserted without a window.
final class PluginViewDragTests: XCTestCase {
    private let kanban: PluginID = "dev.tenon.kanban"
    private let clock: PluginID = "dev.tenon.clock"
    private let pane = "AAAAAAAA-2222-0000-0000-000000000041"
    private let otherPane = "BBBBBBBB-2222-0000-0000-000000000041"

    /// Pane A's scope, varied one field at a time. `instance` is deliberately not an
    /// optional here: "the view has no instance" is its own scope, built explicitly by the
    /// one test about it, so a defaulted nil can never quietly stand in for pane A.
    private func scope(
        plugin: PluginID? = nil,
        view: String = "board",
        instance: String? = nil
    ) -> PluginViewDragScope {
        PluginViewDragScope(
            pluginID: plugin ?? kanban,
            viewID: view,
            instanceID: instance ?? pane
        )
    }

    private func instancelessScope() -> PluginViewDragScope {
        PluginViewDragScope(pluginID: kanban, viewID: "board", instanceID: nil)
    }

    // MARK: - The drag that works

    func testAPayloadTravelsBetweenTwoNodesOfOneViewInstance() throws {
        let here = scope()
        let dragged = try XCTUnwrap(
            PluginViewDrag.encode(payload: "T-101", from: here),
            "a bounded payload inside a real scope must be draggable"
        )
        XCTAssertEqual(
            PluginViewDrag.decode(dragged, into: here),
            "T-101",
            "the drop receives exactly the string the source published"
        )
    }

    /// A view with one instance still has a scope; nil is a value, not "any instance".
    func testASingleInstanceViewCarriesItsOwnScope() throws {
        let here = instancelessScope()
        let dragged = try XCTUnwrap(PluginViewDrag.encode(payload: "row-4", from: here))
        XCTAssertEqual(PluginViewDrag.decode(dragged, into: here), "row-4")
        XCTAssertNil(
            PluginViewDrag.decode(dragged, into: scope()),
            "an instance-less drag must not be admitted by an instance that has one"
        )
        let fromPane = try XCTUnwrap(PluginViewDrag.encode(payload: "row-4", from: scope()))
        XCTAssertNil(
            PluginViewDrag.decode(fromPane, into: here),
            "and the refusal holds in the other direction too"
        )
    }

    // MARK: - The drags that are refused

    func testADragFromAnotherPluginIsRefused() throws {
        let dragged = try XCTUnwrap(
            PluginViewDrag.encode(payload: "T-101", from: scope(plugin: clock))
        )
        XCTAssertNil(
            PluginViewDrag.decode(dragged, into: scope(plugin: kanban)),
            "one plugin's card must never enter another plugin's action route"
        )
    }

    func testADragFromAnotherViewOfTheSamePluginIsRefused() throws {
        let dragged = try XCTUnwrap(
            PluginViewDrag.encode(payload: "T-101", from: scope(view: "backlog"))
        )
        XCTAssertNil(PluginViewDrag.decode(dragged, into: scope(view: "board")))
    }

    /// The T-012 rule, in the drag: two panes showing the same board are two instances,
    /// and a card picked up in one is not dropped into the other.
    func testADragFromAnotherInstanceOfTheSameViewIsRefused() throws {
        let dragged = try XCTUnwrap(
            PluginViewDrag.encode(payload: "T-101", from: scope(instance: otherPane))
        )
        XCTAssertNil(PluginViewDrag.decode(dragged, into: scope(instance: pane)))
    }

    /// Text dragged in from a browser, an editor, or the Finder is the common case here,
    /// and none of it is a plugin view drag.
    func testAStringThatNeverStartedInAPluginViewIsRefused() {
        let here = scope()
        for foreign in [
            "T-101",
            "",
            "{}",
            "[1,2,3]",
            "/Users/someone/Downloads/report.pdf",
            #"{"plugin":"dev.tenon.kanban","view":"board","payload":"T-101"}"#,
        ] {
            XCTAssertNil(
                PluginViewDrag.decode(foreign, into: here),
                "\"\(foreign)\" did not come from a plugin view and must be refused"
            )
        }
    }

    /// A future envelope version must be refused rather than read with today's rules.
    func testAnEnvelopeCarryingAnotherMarkerIsRefused() throws {
        let dragged = try XCTUnwrap(
            PluginViewDrag.encode(payload: "T-101", from: scope())
        )
        let renamed = dragged.replacingOccurrences(
            of: PluginViewDrag.marker,
            with: "tenon.plugin-view-drag.v2"
        )
        XCTAssertNotEqual(renamed, dragged, "the marker must be in the encoded envelope")
        XCTAssertNil(PluginViewDrag.decode(renamed, into: scope()))
    }

    // MARK: - The bound

    func testAPayloadPastTheBoundNeverTravels() {
        let long = String(repeating: "x", count: PluginViewDrag.maximumPayloadLength + 1)
        XCTAssertNil(PluginViewDrag.admissiblePayload(long))
        XCTAssertNil(
            PluginViewDrag.encode(payload: long, from: scope()),
            "a payload past the bound makes the subtree undraggable, not oversized"
        )
    }

    func testAPayloadExactlyAtTheBoundStillTravels() throws {
        let edge = String(repeating: "x", count: PluginViewDrag.maximumPayloadLength)
        XCTAssertEqual(PluginViewDrag.admissiblePayload(edge), edge)
        let dragged = try XCTUnwrap(PluginViewDrag.encode(payload: edge, from: scope()))
        XCTAssertEqual(PluginViewDrag.decode(dragged, into: scope()), edge)
    }

    /// The bound is checked on arrival too, not only on publication: an envelope that was
    /// not built by this host is exactly the case the publication check cannot cover.
    func testAForgedEnvelopePastTheBoundIsRefusedOnArrival() throws {
        let long = String(repeating: "x", count: PluginViewDrag.maximumPayloadLength + 1)
        let forged = try XCTUnwrap(
            String(
                data: JSONSerialization.data(withJSONObject: [
                    "marker": PluginViewDrag.marker,
                    "plugin": kanban.rawValue,
                    "view": "board",
                    "instance": pane,
                    "payload": long,
                ]),
                encoding: .utf8
            )
        )
        XCTAssertNil(PluginViewDrag.decode(forged, into: scope()))
    }

    func testAnEmptyPayloadIsNotADrag() {
        XCTAssertNil(PluginViewDrag.admissiblePayload(""))
        XCTAssertNil(PluginViewDrag.admissiblePayload(nil))
        XCTAssertNil(PluginViewDrag.encode(payload: "", from: scope()))
    }
}
