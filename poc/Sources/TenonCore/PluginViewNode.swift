import Foundation

/// A node in a plugin's declarative view-tree (`tenon.views.set(id, { body })`).
///
/// This is the vocabulary a plugin composes UI from — a pure value tree with no
/// AppKit/SwiftUI here (invariant 3); `TenonApp` renders it. Two tiers:
///
/// - **primitives** a plugin is never blocked on: `vstack`, `hstack`, `box`, `text`,
///   `image`, `spacer`, `divider`. A card the host has not shipped is just a `box`
///   with a background and a corner radius.
/// - **components** composed from those, pretty and consistent by default: `card`,
///   `badge`, `button`.
///
/// See `docs/design-plugin-views.md`.
public indirect enum PluginViewNode: Sendable, Equatable {
    case vstack(spacing: Double, children: [PluginViewNode])
    case hstack(spacing: Double, children: [PluginViewNode])
    /// A container. `width` is the one escape from "fill whatever is offered": a board
    /// column has to stay the same size whether the pane is wide or narrow, and whether
    /// it holds one card or twelve. `nil` keeps the fill behaviour every other caller
    /// relies on.
    case box(
        padding: Double,
        background: Bool,
        cornerRadius: Double,
        width: Double?,
        children: [PluginViewNode]
    )
    case card(children: [PluginViewNode])
    case text(String, style: TextStyle, weight: FontWeight, color: ColorToken)
    case badge(String, tint: ColorToken)
    case button(label: String, action: String, style: ButtonStyle)
    /// An editable field; its `action` fires on submit, carrying the typed text.
    case textfield(value: String, placeholder: String, action: String)
    /// A host-owned `WKWebView` surface keyed by `surfaceID`; the plugin drives it
    /// through `browser.surface.*.v1` intents and never touches the web type.
    case webview(surfaceID: String)
    case image(systemName: String)
    case spacer
    case divider
    /// Scrolls its children along one or both axes. The pane's own wrapper scrolls
    /// vertically, so content wider than the pane — fixed-width columns, a wide table —
    /// is only reachable when the plugin says where the overflow goes.
    case scroll(axis: ScrollAxis, children: [PluginViewNode])

    // Status/dashboard set (T-007). `grid` is a layout primitive; the rest are
    // components composed from tier-1 — see docs/design-plugin-views.md.
    case grid(columns: Int, spacing: Double, children: [PluginViewNode])
    case stat(label: String, value: String)
    case keyValue(label: String, value: String, tint: ColorToken)
    case progress(value: Double, tint: ColorToken)
    case field(label: String, children: [PluginViewNode])
}

/// Which way a `scroll` node lets its content overflow. An unknown or omitted token
/// falls back to `.vertical` — the axis a pane already scrolls — so a typo degrades to
/// today's behaviour instead of dropping the node and its whole subtree.
public enum ScrollAxis: String, Sendable, Equatable {
    case horizontal, vertical, both
    public init(token: String?) { self = token.flatMap(ScrollAxis.init(rawValue:)) ?? .vertical }
}

/// Text role — maps to a font size/family in the shell, never a raw point value,
/// so every plugin's typography stays on the app's scale.
public enum TextStyle: String, Sendable, Equatable {
    case title, body, caption, code
    /// An unknown or omitted token falls back to `.body` (never a silent nil).
    public init(token: String?) { self = token.flatMap(TextStyle.init(rawValue:)) ?? .body }
}

public enum FontWeight: String, Sendable, Equatable {
    case regular, medium, semibold
    public init(token: String?) { self = token.flatMap(FontWeight.init(rawValue:)) ?? .regular }
}

/// A semantic color that resolves against `TenonTheme` in the shell, so plugins get
/// automatic light/dark without ever naming a hex value.
public enum ColorToken: String, Sendable, Equatable {
    case `default`, text, muted, amber, green, red
    public init(token: String?) { self = token.flatMap(ColorToken.init(rawValue:)) ?? .default }
}

public enum ButtonStyle: String, Sendable, Equatable {
    case primary, plain
    public init(token: String?) { self = token.flatMap(ButtonStyle.init(rawValue:)) ?? .plain }
}
