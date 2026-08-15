import Foundation
import TenonIntentCore
import XCTest
@testable import TenonCore

final class PluginViewsTests: XCTestCase {
    func testCompiledPathHelpersMatchBootstrapPOSIXSemantics() {
        XCTAssertEqual(PluginPath.normalize("/a/./b/../c//"), "/a/c")
        XCTAssertEqual(PluginPath.normalize("a/../../b"), "../b")
        XCTAssertEqual(PluginPath.join("/a", "b", "..", "c"), "/a/c")
        XCTAssertEqual(PluginPath.basename("/"), "/")
        XCTAssertEqual(PluginPath.dirname("relative"), ".")
        XCTAssertEqual(PluginPath.dirname("/relative"), "/")
        XCTAssertEqual(PluginPath.extname(".env"), "")
        XCTAssertEqual(PluginPath.extname("archive.tar.gz"), ".gz")
    }

    /// T-056. Both drag wrappers are transparent: the subtree is exactly what the plugin
    /// published, and the wrapper adds only the gesture.
    func testDragSourceAndDropTargetWrapTheirSubtreeUnchanged() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("board", { title: "Board" });
            tenon.views.set("board", { body: {
              type: "dropTarget",
              action: "drop-into:1",
              children: [{
                type: "dragSource",
                payload: "T-101",
                children: [{ type: "text", value: "First thing" }]
              }]
            }});
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        var dropAction: String?
        var dragPayload: String?
        var leaf: [PluginViewNode] = []
        if case let .dropTarget(action, targetChildren) = view.body,
           case let .dragSource(payload, sourceChildren) = targetChildren.first {
            dropAction = action.stringValue ?? action.description
            dragPayload = payload
            leaf = sourceChildren
        }
        XCTAssertEqual(dropAction, "drop-into:1", "a dropTarget node survives parsing")
        XCTAssertEqual(dragPayload, "T-101", "a dragSource node survives parsing")
        XCTAssertEqual(
            leaf,
            [.text("First thing", style: .body, weight: .regular, color: .default)],
            "the wrapper carries the subtree through untouched"
        )
        _ = await runtime.shutdown()
    }

    /// A card must not vanish because its id was long or its action was forgotten. Unlike
    /// `button`, which IS its content, these wrap content the plugin still meant to show:
    /// the gesture is what is dropped, not the subtree.
    func testAMalformedDragWrapperKeepsItsSubtreeAndLosesOnlyTheGesture() async throws {
        let overlong = String(repeating: "x", count: PluginViewDrag.maximumPayloadLength + 1)
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("board", { title: "Board" });
            tenon.views.set("board", { body: { type: "vstack", children: [
              {
                type: "dragSource",
                payload: "\(overlong)",
                children: [{ type: "text", value: "still here" }]
              },
              { type: "dropTarget", children: [{ type: "text", value: "also here" }] }
            ]}});
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        var dragPayload: String?
        var dragChildren: [PluginViewNode] = []
        var dropAction: String?
        var dropChildren: [PluginViewNode] = []
        if case let .vstack(_, children) = view.body {
            if case let .dragSource(payload, kept) = children.first {
                dragPayload = payload
                dragChildren = kept
            }
            if case let .dropTarget(action, kept) = children.last {
                dropAction = action.stringValue ?? action.description
                dropChildren = kept
            }
        }
        XCTAssertEqual(
            dragPayload,
            "",
            "a payload past the bound makes the node undraggable, not absent"
        )
        XCTAssertEqual(dragChildren.count, 1, "and its subtree still renders")
        XCTAssertEqual(
            dropAction,
            "",
            "a dropTarget with no action stays as a plain container"
        )
        XCTAssertEqual(dropChildren.count, 1)
        _ = await runtime.shutdown()
    }

    func testDeclarativeBodyParsesIntoNativeViewTree() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              title: "Panel",
              header: {
                leading: [{ type: "label", id: "source", text: "native" }],
                trailing: [
                  { type: "iconButton", id: "refresh", systemName: "arrow.clockwise" }
                ]
              },
              body: {
                type: "vstack",
                spacing: 8,
                children: [
                  { type: "text", value: "Build passing", weight: "semibold" },
                  { type: "badge", value: "main", tint: "green" },
                  { type: "progress", value: 0.42, tint: "amber" }
                ]
              }
            });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertEqual(view.title, "Panel")
        // A view that publishes a `body` carries its header too. The pane's own chrome is
        // where its name, its state and its controls go, so the two halves of one
        // contribution arrive together instead of the body silently swallowing the rest.
        XCTAssertEqual(
            view.header.leading,
            [
                .label(
                    id: "source",
                    text: "native",
                    weight: .regular,
                    color: .default,
                    truncation: .tail,
                    tooltip: nil
                ),
            ]
        )
        XCTAssertEqual(
            view.header.trailing,
            [
                .iconButton(
                    id: "refresh",
                    systemName: "arrow.clockwise",
                    tint: .default,
                    isEnabled: true,
                    tooltip: nil,
                    accessibilityID: nil
                ),
            ]
        )
        XCTAssertEqual(
            view.body,
            .vstack(
                spacing: 8,
                children: [
                    .text(
                        "Build passing",
                        style: .body,
                        weight: .semibold,
                        color: .default
                    ),
                    .badge("main", tint: .green),
                    .progress(value: 0.42, tint: .amber),
                ]
            )
        )
        _ = await runtime.shutdown()
    }

    func testStructuredAndStringActionsRoundTripToHandler() async throws {
        let logs = ViewLogSink()
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              body: {
                type: "vstack",
                children: [
                  {
                    type: "button",
                    label: "Stage",
                    action: { operation: "stage", path: "a.swift" }
                  },
                  { type: "button", label: "Refresh", action: "refresh" }
                ]
              }
            });
            tenon.views.onSelect("panel", function (action) {
              tenon.log(typeof action === "string"
                ? action
                : action.operation + ":" + action.path);
            });
            """,
            log: { line in await logs.append(line) }
        )
        _ = try await runtime.start()

        let snapshot = await runtime.snapshot()
        guard case let .vstack(_, children) = try XCTUnwrap(
            snapshot.views.first?.body
        ),
            case let .button(_, structuredAction, _) = children[0],
            case let .button(_, stringAction, _) = children[1]
        else {
            return XCTFail("expected two parsed buttons")
        }
        let structured = try await runtime.invokeViewSelect(
            viewID: "panel",
            itemID: structuredAction
        )
        let string = try await runtime.invokeViewSelect(
            viewID: "panel",
            itemID: stringAction
        )
        XCTAssertTrue(structured)
        XCTAssertTrue(string)
        let delivered = await eventually {
            let lines = await logs.values()
            return lines.contains("[view-tests] stage:a.swift")
                && lines.contains("[view-tests] refresh")
        }
        XCTAssertTrue(delivered)
        _ = await runtime.shutdown()
    }

    func testProgressValuesAreClampedAtParsingBoundary() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              body: {
                type: "vstack",
                children: [
                  { type: "progress", value: -2 },
                  { type: "progress", value: 5 }
                ]
              }
            });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertEqual(
            view.body,
            .vstack(
                spacing: 8,
                children: [
                    .progress(value: 0, tint: .default),
                    .progress(value: 1, tint: .default),
                ]
            )
        )
        _ = await runtime.shutdown()
    }

    /// T-066. A column that resizes with the pane is not a column, so a `box` may declare
    /// its width — and the declaration is bounded at the parsing boundary exactly like
    /// `progress`'s clamp, because a 4-point or 40 000-point column is a plugin bug, not
    /// a layout. Omitting `width` must keep the fill behaviour every other plugin relies
    /// on, which is why the third box here asserts `nil` rather than a default number.
    func testBoxWidthIsOptionalAndClampedAtParsingBoundary() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              body: {
                type: "hstack",
                children: [
                  { type: "box", width: 260, children: [] },
                  { type: "box", width: 4, children: [] },
                  { type: "box", width: 40000, children: [] },
                  { type: "box", children: [] }
                ]
              }
            });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        guard case let .hstack(_, boxes) = try XCTUnwrap(view.body) else {
            return XCTFail("the body is an hstack of boxes")
        }
        let widths: [Double?] = boxes.map { node in
            guard case let .box(_, _, _, width, _) = node else { return nil }
            return width
        }
        XCTAssertEqual(widths[0], 260)
        XCTAssertEqual(widths[1], 60, "a width below the floor is clamped, not honoured")
        XCTAssertEqual(widths[2], 1200, "a width above the ceiling is clamped")
        XCTAssertNil(widths[3], "an undeclared width still means fill, not a default size")
        _ = await runtime.shutdown()
    }

    /// T-066. Fixed-width content overflows the pane by construction, and the pane's own
    /// wrapper only scrolls vertically — so the sideways scroll is something the plugin
    /// declares. An unknown axis degrades to vertical rather than dropping the node: the
    /// alternative loses the whole subtree over one typo.
    func testScrollNodeCarriesItsAxisAndFallsBackToVertical() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              body: {
                type: "vstack",
                children: [
                  { type: "scroll", axis: "horizontal", children: [{ type: "spacer" }] },
                  { type: "scroll", axis: "diagonal", children: [] },
                  { type: "scroll", axis: "both", children: [] }
                ]
              }
            });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let view = try XCTUnwrap(snapshot.views.first)
        XCTAssertEqual(
            view.body,
            .vstack(
                spacing: 8,
                children: [
                    .scroll(axis: .horizontal, children: [.spacer]),
                    .scroll(axis: .vertical, children: []),
                    .scroll(axis: .both, children: []),
                ]
            )
        )
        _ = await runtime.shutdown()
    }

    /// T-066. A modal is part of the view's published state, not a new member on `tenon`:
    /// the plugin sets one to open it and omits it to close it. The host supplies the
    /// dismiss action id when the plugin names none, so a modal can never be published
    /// without a way out of it.
    func testModalIsPublishedWithTheViewAndDefaultsItsDismissAction() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              body: { type: "text", value: "board" },
              modal: {
                title: "T-101",
                body: { type: "text", value: "detail" }
              }
            });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        let modal = try XCTUnwrap(snapshot.views.first?.modal)
        XCTAssertEqual(modal.title, "T-101")
        XCTAssertEqual(modal.body, .text("detail", style: .body, weight: .regular, color: .default))
        XCTAssertEqual(modal.dismissAction, PluginViewModal.defaultDismissAction)
        _ = await runtime.shutdown()
    }

    /// T-066. Closing is a plugin state change, so the next `views.set` without a `modal`
    /// must actually take it away — a modal that outlived the state that opened it would
    /// be a sheet the plugin cannot close.
    func testAViewSetWithoutAModalClearsThePreviousOne() async throws {
        let runtime = try makeRuntime(
            source: """
            tenon.views.register("panel", { title: "Panel" });
            tenon.views.set("panel", {
              modal: { title: "open", dismissAction: "close-me" }
            });
            tenon.views.set("panel", { body: { type: "text", value: "board" } });
            """
        )
        _ = try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertNil(try XCTUnwrap(snapshot.views.first).modal)
        _ = await runtime.shutdown()
    }

    private func makeRuntime(
        source: String,
        log: @escaping PluginRuntimeConfiguration.Log = { _ in }
    ) throws -> PluginRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tenon-views-\(UUID().uuidString)",
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
                    id: "dev.tenon.view-tests",
                    name: "view-tests",
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
