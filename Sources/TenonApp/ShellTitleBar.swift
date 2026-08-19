// @domain: workspace-model, attention
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// The full-width top row shared with the traffic lights. Its left zone (app identity
/// + sidebar toggle) sits above the sidebar column; its right zone holds whichever strip the
/// chrome order gives it, then the host's own trailing controls.
///
/// The row itself never moves. Only its content zone's occupant changes: the tab strip by
/// default, the plugin status items once a supervisor has sent the tabs down to the foot.
/// Traffic lights, identity, resource monitor and quick commands stay here in both orders.
///
/// # Who owns the pointer in this row
///
/// The row is drawn inside the window's title-bar band, and that band is the one place where
/// **macOS**, not this app, decides what a drag means. It decides it *before the press
/// happens*: AppKit computes a drag region for the window and uploads it to the window
/// server, which then starts the move itself, consulting nothing. A view stays out of that
/// region by answering `mouseDownCanMoveWindow` with `false` **and being an `NSControl`
/// descendant that accepts first responder** — the region builder ignores a plain `NSView`
/// saying it, and puts a control that refuses first responder back inside, which is why the
/// traffic lights (`NSButton`) are the baseline hole in the region and ordinary SwiftUI
/// content is not. Both halves are load-bearing and both were learned from a human drag:
/// `scripts/internal/drag-region-probe.swift` measures them. So each zone of this row states
/// who owns its pointer, and the classification is a property of the views, not of the
/// reading order:
///
/// | Zone | Owner | A drag there |
/// |---|---|---|
/// | the chips, when the content zone holds them | `TabStripSurface` — one AppKit view over the chips, and nothing else | reorders the tab |
/// | the status items, when it holds them | SwiftUI | moves the window |
/// | empty chrome | `WindowDragArea` — `performDrag`, so double-click still zooms | moves the window |
/// | identity (icon, wordmark, unseen count, sidebar toggle) | SwiftUI | moves the window |
/// | resource monitor, quick commands | SwiftUI | moves the window |
///
/// All but the chips are deliberate rather than left over: they are chrome that happens to
/// carry a control, and dragging chrome is what a title bar is for. The chips are the zone
/// where that default is wrong, because a tab is a thing you move — so they, and only they,
/// take the pointer away from the window server, and then own everything that pointer can
/// mean. That claim travels with the strip (see `ShellTabStrip`), which is why the rule
/// survives the strip being drawn at the other end of the window.
struct ShellTitleBar<Content: View>: View {
    var store: WorkspaceStore
    var pool: SurfacePool
    /// The resource monitor's presentation state, composed by the app.
    ///
    /// Optional because the title bar is mounted in offscreen renderers and tests that have
    /// no telemetry stack behind them; the trigger simply is not drawn there, rather than
    /// every one of those call sites having to build a sampler.
    var resourceMonitor: ResourceMonitorModel?
    var quickCommands: QuickCommandStore
    let sidebarVisible: Bool
    let sidebarWidth: CGFloat
    let onToggleSidebar: () -> Void
    /// Whichever strip the chrome order puts in this row. Supplied by the composition root,
    /// which is the one place that reads the preference.
    @ViewBuilder let content: () -> Content

    /// Past this much content in the row's own zone, the resource summary drops its caption
    /// and keeps its icon. A caption is what a translation or a larger text size grows, so
    /// dropping it is what makes the crowded case fit instead of clip.
    private static var compactResourceSummaryWidth: CGFloat { 420 }

    /// How wide the row's occupant currently is, published by the tab strip when this row is
    /// the one holding it. The status strip publishes nothing, so the default 0 stands and
    /// the summary keeps its caption — which is right, because the crowding this guards
    /// against is genuinely absent then.
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            leftZone
                .frame(
                    width: sidebarVisible ? sidebarWidth : TenonTheme.sidebarWidth,
                    alignment: .leading
                )

            // With the sidebar expanded, the shell's full-height resize edge draws this
            // seam (and makes it draggable), so the title bar must not stack a second
            // static rule at the same x. With the icon rail there is no draggable edge
            // in the title bar, so the identity/content separator lives here.
            if !sidebarVisible {
                Rectangle()
                    .fill(TenonTheme.line)
                    .frame(width: 1)
            }

            rightZone
                .frame(maxWidth: .infinity)
        }
        .background(WindowDragArea(color: TenonTheme.chromeNS))
    }

    // MARK: - The identity zone  @domain: workspace-model

    private var leftZone: some View {
        HStack(spacing: 8) {
            // Reserved for the OS traffic-light buttons, which overlay this corner.
            Color.clear
                .frame(width: TenonTheme.trafficLightInset)

            // Drop the wordmark first when the sidebar column is too narrow to hold
            // the full identity + toggle without the title crowding into the divider.
            // ViewThatFits keeps the last (title-less) candidate once nothing fits.
            //
            // A workspace name goes through neither branch: it is the only place that name
            // appears while the rail is collapsed, so it shrinks and truncates rather than
            // being dropped — the zone's width is fixed at 232 pt there anyway.
            if label.namesWorkspace {
                identityRow(showTitle: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    identityRow(showTitle: true)
                    identityRow(showTitle: false)
                }
            }
        }
        .padding(.trailing, 8)
    }

    /// What the zone says beside the mark: the active workspace's name while the sidebar is
    /// collapsed, and the app's wordmark otherwise.
    private var label: ShellIdentityLabel {
        ShellIdentityLabel.resolve(
            sidebarVisible: sidebarVisible,
            workspaceName: activeWorkspace?.name
        )
    }

    /// The label itself. A workspace name is content and takes the tail truncation content
    /// gets, plus the tooltip that gives the cut-off part back; the wordmark is chrome, and
    /// `fixedSize` is what lets `ViewThatFits` see it stop fitting rather than watch it
    /// shorten to "Ten…".
    @ViewBuilder
    private var identityLabel: some View {
        let text = Text(label.text)
            .font(TenonTheme.interfaceFont(size: 13, weight: .bold))
            .foregroundStyle(TenonTheme.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier("tenon.identityLabel")

        if label.namesWorkspace {
            text
                .help(label.text)
                .accessibilityLabel("Workspace \(label.text)")
        } else {
            text.fixedSize()
        }
    }

    /// Icon + optional label, with the sidebar toggle pinned to the right.
    private func identityRow(showTitle: Bool) -> some View {
        HStack(spacing: 8) {
            (AppMark.image.map { Image(nsImage: $0) } ?? Image(systemName: "terminal.fill"))
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(TenonTheme.text)
                .accessibilityHidden(true)

            if showTitle {
                identityLabel
            }

            Spacer(minLength: 6)

            // T-029: how many panes across the whole catalog await a human. The one
            // machine's rollup — hidden entirely while nothing needs attention.
            if totalUnseen > 0 {
                Text("\(totalUnseen)")
                    .font(TenonTheme.utilityFont(size: 9, weight: .bold))
                    .foregroundStyle(TenonTheme.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TenonTheme.amber))
                    .help("\(totalUnseen) pane(s) finished and are waiting for you")
                    .accessibilityIdentifier("tenon.unseenCount")
            }

            ShellIconButton(
                symbol: sidebarVisible ? "sidebar.left" : "sidebar.leading",
                help: sidebarVisible ? "Collapse sidebar" : "Expand sidebar",
                action: onToggleSidebar
            )
            .accessibilityIdentifier("tenon.toggleSidebar")
        }
    }

    // MARK: - The content zone and the host's trailing controls  @domain: workspace-model

    private var rightZone: some View {
        HStack(spacing: 0) {
            content()

            if let resourceMonitor {
                // Host chrome, and never inside `WorkspaceStatusBar`: that strip is a closed
                // plugin-contribution surface and a host control in it would end the promise
                // it makes. Sitting *beside* it in the same row is a different thing — the
                // container is still the plugin's alone. The July design said "before Add
                // Slot"; the title bar has no Add Slot control any more, so this sits before
                // the trailing host control that does exist.
                ResourceMonitorButton(
                    model: resourceMonitor,
                    isCompact: contentWidth > Self.compactResourceSummaryWidth
                )
                .padding(.leading, 8)
                .accessibilityIdentifier("tenon.resourceMonitor.trigger")
            }

            QuickCommandControl(
                commands: quickCommands,
                workspaceStore: store,
                terminalPool: pool
            )
            .padding(.leading, 8)
            .accessibilityIdentifier("tenon.quickCommands.control")
        }
        .padding(.horizontal, 8)
        .onPreferenceChange(ShellTabStripWidthKey.self) { width in
            contentWidth = width
        }
    }

    // MARK: - Derived state  @domain: attention

    private var activeWorkspace: Workspace? {
        store.catalog.activeWorkspace
    }

    private var totalUnseen: Int {
        PaneAttentionProjection.totalUnseen(
            catalog: store.catalog,
            attention: pool.paneAttention
        )
    }
}

/// Says a completed reorder out loud.
///
/// VoiceOver has no way to notice that a chip changed places in a strip it is not focused
/// on: the move produces no focus change and no new element. Without this, the drag and the
/// custom action are both silent, and the person who most needs the confirmation is the one
/// who cannot see it.
///
/// It lives here rather than with the strip because the sidebar's workspace rows announce
/// their own reorders through it too.
enum ReorderAnnouncer {
    @MainActor
    static func say(_ message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
