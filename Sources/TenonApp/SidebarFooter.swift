// @domain: workspace-model
import SwiftUI

/// One fixed host utility offered beneath the workspace list.
///
/// The vocabulary is closed on purpose: the footer is the quietest strip in the shell, and
/// the width rule in `SidebarFooterLayout` is what stops it growing — a fourth entry no
/// longer fits the narrowest sidebar, so adding one is a decision, not a drive-by.
enum SidebarFooterAction: String, CaseIterable, Identifiable, Sendable {
    case help
    case feedback
    case settings

    var id: String { rawValue }

    /// Where the action lands. Unchanged by the restyle — this type only names what the
    /// buttons already did.
    enum Destination: Equatable, Sendable {
        case url(URL)
        case appSettings
    }

    /// Shown to no one and spoken to everyone: the controls are icon-only, so this is the
    /// tooltip and the VoiceOver label rather than a caption. Kept as literals so the string
    /// catalog still extracts them.
    var title: LocalizedStringKey {
        switch self {
        case .help: "Help"
        case .feedback: "Feedback"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .help: "questionmark.circle"
        case .feedback: "bubble.left"
        case .settings: "gearshape"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .help: "tenon.sidebarHelp"
        case .feedback: "tenon.sidebarFeedback"
        case .settings: "tenon.sidebarSettings"
        }
    }

    var destination: Destination {
        switch self {
        case .help: .url(Self.projectURL())
        case .feedback: .url(Self.projectURL(path: "issues/new"))
        case .settings: .appSettings
        }
    }

    private static func projectURL(path: String? = nil) -> URL {
        let suffix = path.map { "/\($0)" } ?? ""
        guard let url = URL(string: "https://github.com/nguyenvanduocit/tenon\(suffix)") else {
            fatalError("The fixed Tenon project URL must be valid")
        }
        return url
    }
}

/// The footer's density budget, in one place so it can be asserted without a window.
///
/// Every number is borrowed rather than invented: 28 pt is `docs/designs.md`'s compact
/// control (and its hit target), 6 pt its control radius, 7 pt the inset the workspace rows
/// above already use, and 34 pt the same band a pane's header strip occupies.
enum SidebarFooterLayout {
    static let controlSide: CGFloat = 28
    static let controlRadius: CGFloat = 6
    static let spacing: CGFloat = 2
    static let horizontalInset: CGFloat = 7
    static let height: CGFloat = 34

    /// Narrowest sidebar this many controls can occupy without one being clipped. The
    /// sidebar may stay open at `SidebarResize.minWidth`, so this has to fit inside it.
    static func minimumWidth(actionCount: Int) -> CGFloat {
        let insets = horizontalInset * 2
        guard actionCount > 0 else { return insets }
        return insets
            + CGFloat(actionCount) * controlSide
            + CGFloat(actionCount - 1) * spacing
    }
}

/// Fixed host utilities beneath the workspace list: one 34 pt row of quiet icon buttons.
///
/// Icon-only at every width, which is what lets the row be one control tall. A caption
/// beside each icon is what forced the previous 44×38 tiles and the `ViewThatFits` pair
/// that swapped them out — and a caption is also the part localization and a larger text
/// size can clip. The names did not disappear with the labels: they are the tooltip and the
/// VoiceOver label, which carry them at any width and in any language.
struct SidebarFooter: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: SidebarFooterLayout.spacing) {
            ForEach(SidebarFooterAction.allCases) { action in
                SidebarFooterButton(action: action) { run(action) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SidebarFooterLayout.horizontalInset)
        .frame(height: SidebarFooterLayout.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TenonTheme.line)
                .frame(height: 1)
        }
    }

    private func run(_ action: SidebarFooterAction) {
        switch action.destination {
        case .url(let url): openURL(url)
        case .appSettings: openSettings()
        }
    }
}

private struct SidebarFooterButton: View {
    let action: SidebarFooterAction
    let run: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: run) {
            // `.iconOnly` drops the caption from the picture and keeps it for VoiceOver, so
            // the spoken name and the tooltip cannot drift apart from the drawn control.
            Label(action.title, systemImage: action.symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TenonTheme.muted)
                .frame(
                    width: SidebarFooterLayout.controlSide,
                    height: SidebarFooterLayout.controlSide
                )
                .background {
                    RoundedRectangle(cornerRadius: SidebarFooterLayout.controlRadius)
                        // The wash the workspace rows above hover with, at the same value:
                        // the footer reads as part of the sidebar, not a strip bolted under it.
                        .fill(isHovering ? Color.primary.opacity(0.04) : .clear)
                }
                // Keyboard focus is drawn, not assumed. An icon-only control gives a
                // keyboard user less to recognise than a captioned one did, so it borrows
                // the accent stroke the pane header's field already focuses with.
                .overlay {
                    RoundedRectangle(cornerRadius: SidebarFooterLayout.controlRadius)
                        .stroke(
                            isFocused ? TenonTheme.amber.opacity(0.55) : .clear,
                            lineWidth: 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: SidebarFooterLayout.controlRadius))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .help(action.title)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}
