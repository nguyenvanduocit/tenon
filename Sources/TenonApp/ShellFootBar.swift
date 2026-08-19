// @domain: workspace-model
import SwiftUI

/// The row across the bottom of the content column, below the stage and right of the sidebar.
///
/// It holds whichever strip the chrome order gives it — the plugin status items by default,
/// the tab strip when a supervisor has moved the tabs down to where they are already looking.
/// The height comes from its occupant, because an 8-pt line of status text and a 26-pt chip
/// need different rows.
///
/// It asks for no window drag, and that is the point of the file rather than an omission: the
/// title-bar band is the one place macOS hands a press to the window server, and a bottom row
/// that behaved like a title bar would move the window from the wrong edge and run a
/// double-click handler that reads a System Settings key about title bars.
/// `ShellChromeLayoutTests.testOnlyTheTitleBarRowAsksForAWindowDrag` holds that line.
///
/// It also stays inside the content column and never spans the window: the sidebar's resize
/// edge is a full-height grab strip drawn over everything at `sidebarWidth`, and a full-width
/// foot row would have an 8-pt dead band cut through it.
struct ShellFootBar<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(TenonTheme.chrome)
    }
}
