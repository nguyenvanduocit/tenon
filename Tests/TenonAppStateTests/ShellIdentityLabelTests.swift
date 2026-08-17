import XCTest
@testable import TenonApp

/// The title bar's identity zone keeps its full 232 pt whether the sidebar is expanded or
/// collapsed, but the workspace name only survives on screen in the first case — collapsed,
/// the 48 pt rail draws marks and keeps the name in a tooltip. So the zone says which
/// workspace you are in exactly when nothing else does, and says the app's name otherwise.
final class ShellIdentityLabelTests: XCTestCase {
    func testTheZoneNamesTheWorkspaceOnlyWhileNothingElseDoes() {
        let cases: [(
            sidebarVisible: Bool,
            workspaceName: String?,
            expected: ShellIdentityLabel,
            why: String
        )] = [
            (
                false,
                "tenon",
                ShellIdentityLabel(text: "tenon", namesWorkspace: true),
                "Collapsed, the rail shows a mark and no name — this is the only place left."
            ),
            (
                false,
                "  spaced workspace  ",
                ShellIdentityLabel(text: "spaced workspace", namesWorkspace: true),
                "Surrounding space would read as a gap beside the mark, not as a name."
            ),
            (
                false,
                "   ",
                ShellIdentityLabel(text: "Tenon", namesWorkspace: false),
                "A name of nothing but space names nothing; the wordmark is the honest label."
            ),
            (
                false,
                nil,
                ShellIdentityLabel(text: "Tenon", namesWorkspace: false),
                "No active workspace, so there is no name to carry."
            ),
            (
                true,
                "tenon",
                ShellIdentityLabel(text: "Tenon", namesWorkspace: false),
                "Expanded, the sidebar already lists the workspace and marks the active one."
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ShellIdentityLabel.resolve(
                    sidebarVisible: testCase.sidebarVisible,
                    workspaceName: testCase.workspaceName
                ),
                testCase.expected,
                testCase.why
            )
        }
    }
}
