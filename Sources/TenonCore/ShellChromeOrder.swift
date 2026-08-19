// @domain: workspace-model
import Foundation

/// Which of the shell's two movable strips a chrome row is holding.
///
/// There are exactly two strips and exactly two rows, so the order is a swap rather than a
/// pair of independent positions: naming one row's occupant names the other's.
public enum ShellChromeStrip: String, CaseIterable, Codable, Sendable, Equatable {
    /// The tab chips, their `+` launcher, and everything a pointer can mean inside them.
    case tabs
    /// The plugin-contributed status items.
    case status
}

/// The window edge a chrome row is attached to.
///
/// Read by the strip for the three things that genuinely depend on which way is out: the fill
/// behind its trailing stretch, the side a launcher popover opens toward, and the room that
/// launcher has to grow into. It is a property of the *row*, not of the preference — each
/// container states its own edge and never branches on the order.
public enum ShellChromeEdge: String, Sendable, Equatable {
    case top
    case bottom
}

/// Where the shell draws its two movable chrome strips.
///
/// Supervising parallel agents means reading the *bottom* of a pane for minutes at a time —
/// the newest output is there — so every tab switch from a strip pinned under the traffic
/// lights costs a full-window eye travel. `tabsOnBottom` puts the chips next to the thing a
/// person is already looking at and sends the status items up in exchange.
///
/// The traffic lights, the identity zone, the resource monitor and the quick commands do not
/// move: they stay in the title bar in both orders. Only the occupant of the title bar's
/// content zone and the occupant of the foot row trade places.
public enum ShellChromeOrder: String, CaseIterable, Codable, Sendable, Equatable {
    /// Tabs in the title bar, status items at the foot. What Tenon has always drawn.
    case tabsOnTop
    /// Tabs at the foot, status items in the title bar's content zone.
    case tabsOnBottom

    /// The strip drawn in the title bar's content zone.
    public var titleBarStrip: ShellChromeStrip {
        switch self {
        case .tabsOnTop: return .tabs
        case .tabsOnBottom: return .status
        }
    }

    /// The strip drawn in the foot row, below the stage and right of the sidebar.
    public var footStrip: ShellChromeStrip {
        switch self {
        case .tabsOnTop: return .status
        case .tabsOnBottom: return .tabs
        }
    }

    /// The window edge the tab strip's row is attached to, which is what the strip itself
    /// needs to know. Derived rather than stored, so the two can never disagree.
    public var tabStripEdge: ShellChromeEdge {
        titleBarStrip == .tabs ? .top : .bottom
    }

    /// What the Settings picker says. The choice a person makes is about the tabs — the
    /// status items are what moves in exchange — so the labels name the tab strip's edge.
    public var label: String {
        switch self {
        case .tabsOnTop: return "Top"
        case .tabsOnBottom: return "Bottom"
        }
    }
}
