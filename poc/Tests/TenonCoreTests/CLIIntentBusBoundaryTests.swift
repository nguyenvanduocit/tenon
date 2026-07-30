import Foundation
import XCTest

final class CLIIntentBusBoundaryTests: XCTestCase {
    func testCLIHasOneClosedIntentBusDomainPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let actionSource = try source(
            root,
            "Sources/TenonCore/CLIAction.swift"
        )
        let executorSource = try source(
            root,
            "Sources/TenonApp/CLICommandExecutor.swift"
        )
        let clientSource = try source(
            root,
            "Sources/TenonCLI/main.swift"
        )

        for action in [
            "ping",
            "app.focus",
            "intent.list",
            "intent.describe",
            "intent.send",
        ] {
            XCTAssertTrue(
                actionSource.contains(#""\#(action)""#),
                action
            )
        }

        for legacyAction in [
            "command.list",
            "command.run",
            "workspace.state",
            "pane.send",
            "pane.read",
            "pane.wait",
            "pane.focus",
        ] {
            let literal = #""\#(legacyAction)""#
            XCTAssertFalse(
                actionSource.contains(literal),
                legacyAction
            )
            XCTAssertFalse(
                clientSource.contains(#"action: \#(literal)"#),
                legacyAction
            )
        }

        for forbiddenDependency in [
            "WorkspaceStore",
            "SurfacePool",
            "PluginHost",
            "CommandResolution",
            "CLIStateSnapshot",
            "TerminalIdleWatcher",
        ] {
            XCTAssertFalse(
                executorSource.contains(forbiddenDependency),
                forbiddenDependency
            )
        }
        XCTAssertTrue(executorSource.contains("runtime.discover("))
        XCTAssertTrue(executorSource.contains("runtime.send("))
        XCTAssertTrue(clientSource.contains(#"action: "intent.send""#))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "Sources/TenonApp/CLIStateSnapshot.swift"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "Sources/TenonCore/CommandResolution.swift"
                ).path
            )
        )
    }
}

private extension CLIIntentBusBoundaryTests {
    func source(_ root: URL, _ relativePath: String) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
