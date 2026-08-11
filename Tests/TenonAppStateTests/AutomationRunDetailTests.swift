import XCTest
import TenonCore
import TenonIntentCore
@testable import TenonApp

/// T-125. A run row used to be inert text while the plugins that received the run took a
/// pane on their own, unasked. These tests hold the exchange: the panel is reached by
/// going to look at a run, and a row that has nothing to open is not a control.
@MainActor
final class AutomationRunDetailTests: XCTestCase {
    func testARunLeadsToTheSharedPanelOfThePluginThatReceivedIt() {
        let target = AutomationPanePresentation.runDetail(
            for: "dev.local.vault-sync",
            in: [
                section(plugin: "dev.local.vault-sync", view: "status", title: "Vault sync"),
            ]
        )

        XCTAssertEqual(
            target,
            AutomationRunDetailTarget(
                pluginID: "dev.local.vault-sync",
                viewID: "status",
                title: "Vault sync"
            )
        )
    }

    func testARunNeverLeadsToAnotherPluginsPanel() {
        let target = AutomationPanePresentation.runDetail(
            for: "dev.local.vault-sync",
            in: [
                section(plugin: "dev.local.watch", view: "status", title: "supremor"),
                section(plugin: "dev.local.git-auto-update", view: "main", title: "Git"),
            ]
        )

        XCTAssertNil(
            target,
            "A run row may only open the panel of the plugin that received that run."
        )
    }

    func testAPluginThatDrawsNoPanelOffersNoRunDetail() {
        let target = AutomationPanePresentation.runDetail(
            for: "dev.tenon.clock",
            in: []
        )

        XCTAssertNil(
            target,
            """
            The clock plugin contributes a status item and no view. Its run rows must \
            present as text rather than as a control that opens nothing.
            """
        )
    }

    func testAnInstancedViewIsNotAPanelARunCanLeadTo() {
        let target = AutomationPanePresentation.runDetail(
            for: "dev.local.explorer",
            in: [
                section(
                    plugin: "dev.local.explorer",
                    view: "tree",
                    title: "Files",
                    instanceID: UUID().uuidString,
                    instanced: true
                ),
            ]
        )

        XCTAssertNil(
            target,
            """
            An instanced view is one pane's private surface. Opening it from a run row \
            would have to invent which pane's instance the run meant.
            """
        )
    }

    func testSeveralSharedPanelsResolveInPublishOrderSoTheTargetNeverMoves() {
        let sections = [
            section(plugin: "dev.local.fleet", view: "overview", title: "Overview"),
            section(plugin: "dev.local.fleet", view: "history", title: "History"),
        ]

        XCTAssertEqual(
            AutomationPanePresentation.runDetail(for: "dev.local.fleet", in: sections)?.viewID,
            "overview"
        )
        XCTAssertEqual(
            AutomationPanePresentation.runDetail(
                for: "dev.local.fleet",
                in: sections.reversed()
            )?.viewID,
            "history",
            """
            Publish order is the host's stable order and the plugin's own registration \
            order. The row must follow it rather than sort by a value of its own.
            """
        )
    }

    func testASharedPanelIsFoundEvenWhenAnInstancedViewComesFirst() {
        let target = AutomationPanePresentation.runDetail(
            for: "dev.local.fleet",
            in: [
                section(
                    plugin: "dev.local.fleet",
                    view: "tree",
                    title: "Files",
                    instanceID: UUID().uuidString,
                    instanced: true
                ),
                section(plugin: "dev.local.fleet", view: "overview", title: "Overview"),
            ]
        )

        XCTAssertEqual(target?.viewID, "overview")
    }

    // MARK: - The row is the way in

    func testTheActivityRowIsAControlThatOpensItsRunDetail() throws {
        let source = try automationSlotViewSource()
        let rowStart = try XCTUnwrap(
            source.range(of: "private struct AutomationActivityRow")?.lowerBound
        )
        let rowEnd = try XCTUnwrap(
            source.range(
                of: "private struct AutomationEmptyDetail",
                range: rowStart ..< source.endIndex
            )?.lowerBound
        )
        let row = source[rowStart ..< rowEnd]

        XCTAssertTrue(
            row.contains("let detail: AutomationRunDetailTarget?"),
            "The row must know whether it has a panel to open before it draws as a control."
        )
        XCTAssertTrue(
            row.contains("Button(action: openDetail)"),
            "A run with a panel behind it must be activatable, not decorative text."
        )
        XCTAssertTrue(
            row.contains("if let detail"),
            "A run whose plugin draws no panel must fall back to a non-interactive row."
        )
    }

    func testThePaneOpensARunPanelThroughTypedHostActionsOnly() throws {
        let source = try automationSlotViewSource()

        XCTAssertTrue(
            source.contains("let openRunDetail: (PluginID, String) -> Void"),
            "Run-detail placement is a typed same-owner action on AutomationPaneActions."
        )
        XCTAssertTrue(
            source.contains("actions.openRunDetail("),
            "The pane must call that typed action rather than reach for an intent runtime."
        )
        XCTAssertTrue(
            source.contains("AutomationPanePresentation.runDetail("),
            "Which panel a row opens is a pure projection, not a decision taken in a view body."
        )
    }

    func testTheCompositionRootPlacesTheRunPanelAsOrdinaryWorkspaceContent() throws {
        let composition = try compositionSource()

        XCTAssertTrue(
            composition.contains("openRunDetail: { pluginID, viewID in"),
            "The composition root supplies the run-detail action."
        )
        XCTAssertTrue(
            composition.contains(".pluginView(pluginID: pluginID, viewID: viewID)"),
            """
            A run panel is ordinary workspace content placed by host policy — the same \
            typed store call workspace.content.open.v1 adapts.
            """
        )
    }

    // MARK: - Fixtures

    private func section(
        plugin: PluginID,
        view: String,
        title: String,
        instanceID: String? = nil,
        instanced: Bool = false
    ) -> PluginViewSection {
        PluginViewSection(
            pluginID: plugin,
            viewID: view,
            instanceID: instanceID,
            instanced: instanced,
            title: title,
            items: [],
            body: nil
        )
    }

    private func automationSlotViewSource() throws -> String {
        try packageSource("Sources/TenonApp/AutomationSlotView.swift")
    }

    private func compositionSource() throws -> String {
        try packageSource("Sources/TenonApp/TenonApp.swift")
    }

    private func packageSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
