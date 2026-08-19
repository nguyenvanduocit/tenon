// @domain: workspace-model, companion
import Foundation
import TenonIntentCore

/// A pane's default content, chosen in Settings and resolved to a live `SlotContent`
/// when the shell opens a new tab, split, or workspace. A pure, `Codable` enum so the
/// preference persists and the resolution rule stays testable without a window.
public enum DefaultPaneContent: String, CaseIterable, Codable, Sendable {
    case terminal
    case files
    case changes
    case browser
    case empty

    /// Label for the Settings picker.
    public var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .changes: return "Changes"
        case .browser: return "Browser"
        case .empty: return "Empty"
        }
    }

    /// The concrete content a new pane is filled with. `files` and `browser` both open a
    /// bundled plugin's pane — neither is a host content type (VISION: even the shipped
    /// features are plugins).
    public func slotContent() -> SlotContent {
        switch self {
        case .terminal: return .terminal
        case .files:
            return .pluginView(
                pluginID: "dev.tenon.file-explorer",
                viewID: "tree"
            )
        case .changes: return .changes
        case .browser:
            return .pluginView(
                pluginID: "dev.tenon.browser",
                viewID: "browser"
            )
        case .empty: return .empty
        }
    }
}

/// Accent presets for Tenon's own chrome — active borders, focus glyphs, the tab
/// selection. The terminal palette is ghostty's own config and untouched here.
public enum AccentColor: String, CaseIterable, Codable, Sendable {
    case amber
    case red
    case orange
    case yellow
    case blue
    case cyan
    case green
    case mint
    case teal
    case indigo
    case purple
    case pink

    public var label: String {
        switch self {
        case .amber: return "Amber"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .green: return "Green"
        case .mint: return "Mint"
        case .teal: return "Teal"
        case .indigo: return "Indigo"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    /// 0xRRGGBB the shell builds its accent colour from.
    public var hex: UInt32 {
        switch self {
        case .amber: return 0xE6A33A
        case .red: return 0xE17070
        case .orange: return 0xE19F70
        case .yellow: return 0xE1CE70
        case .blue: return 0x4C8DFF
        case .cyan: return 0x70C3E1
        case .green: return 0x4CC38A
        case .mint: return 0x70E1CA
        case .teal: return 0x36B7B4
        case .indigo: return 0x7092E1
        case .purple: return 0x9B7BFF
        case .pink: return 0xF06AA0
        }
    }
}

/// Everything the user can personalise about how the workspace opens and looks,
/// persisted by the shell. A pure value: no AppKit, fully `Codable`, and decoded
/// leniently so a preferences file written by an older build (missing keys) still
/// loads with the current defaults — adding a setting stays a one-field change.
public struct AppPreferences: Equatable, Sendable, Codable {
    public var newTabContent: DefaultPaneContent
    public var newSplitContent: DefaultPaneContent
    public var newWorkspaceContent: DefaultPaneContent
    /// The widest automatic layout may make a pane through creation or close-time absorption,
    /// or nil to let the layout decide as it always has. Changing the value alone never
    /// disturbs a pane already on the canvas, and manual resize remains unrestricted.
    public var newPaneMaximumWidth: SpatialExtentFraction?
    public var sidebarVisibleOnLaunch: Bool
    public var sidebarWidth: Double
    public var accent: AccentColor
    /// Which of the shell's two chrome rows holds the tab strip, and which holds the plugin
    /// status items. Changing it redraws the open window; nothing about the workspace, its
    /// tabs, or a live terminal is disturbed by the move.
    public var chromeOrder: ShellChromeOrder
    /// Global host preference for scheduled automation delivery. Disabling it pauses
    /// wall-clock firings without disabling or unloading the plugins that declared them.
    public var automationSchedulesEnabled: Bool
    /// Host-owned per-schedule pauses. The manifest still owns the declaration; this
    /// preference only controls whether its scheduled firing is delivered automatically.
    public var pausedAutomationSchedules: Set<AutomationScheduleKey>
    /// Whether the host answers every permission confirmation itself instead of asking.
    ///
    /// On by default, which is a product decision taken with its consequence stated: a
    /// plugin the person installed from outside the bundled inventory then runs its
    /// declared `.policy` contracts, and even the `.always` ones, without anyone being
    /// asked. What the switch cannot reach is the rest of the policy path — declared use,
    /// audience, capability, scope, and provider eligibility are checked on every single
    /// invocation either way, exactly as they are behind standing consent. It answers the
    /// confirmation phase and nothing else.
    public var bypassAllPermissionPrompts: Bool
    /// Defaults shared by short host-owned AI assistance tasks. Per-run controls may override
    /// these values, but no feature should invent another persistent provider preference.
    public var companion: CompanionProfile

    public init(
        newTabContent: DefaultPaneContent = .terminal,
        newSplitContent: DefaultPaneContent = .terminal,
        newWorkspaceContent: DefaultPaneContent = .terminal,
        newPaneMaximumWidth: SpatialExtentFraction? = nil,
        sidebarVisibleOnLaunch: Bool = true,
        sidebarWidth: Double = 232,
        accent: AccentColor = .amber,
        chromeOrder: ShellChromeOrder = .tabsOnTop,
        automationSchedulesEnabled: Bool = true,
        pausedAutomationSchedules: Set<AutomationScheduleKey> = [],
        bypassAllPermissionPrompts: Bool = true,
        companion: CompanionProfile = CompanionProfile()
    ) {
        self.newTabContent = newTabContent
        self.newSplitContent = newSplitContent
        self.newWorkspaceContent = newWorkspaceContent
        self.newPaneMaximumWidth = newPaneMaximumWidth
        self.sidebarVisibleOnLaunch = sidebarVisibleOnLaunch
        self.sidebarWidth = sidebarWidth
        self.accent = accent
        self.chromeOrder = chromeOrder
        self.automationSchedulesEnabled = automationSchedulesEnabled
        self.pausedAutomationSchedules = pausedAutomationSchedules
        self.bypassAllPermissionPrompts = bypassAllPermissionPrompts
        self.companion = companion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences()
        // A pane content this build cannot name — a newer Tenon's, one this build retired,
        // or a hand-edited file — falls back to the default for that one key. Failing the
        // whole document instead would take accent, sidebar width and paused schedules down
        // with it, which is a large loss to answer a single unreadable word.
        newTabContent = (try? container.decode(DefaultPaneContent.self, forKey: .newTabContent))
            ?? defaults.newTabContent
        newSplitContent = (try? container.decode(DefaultPaneContent.self, forKey: .newSplitContent))
            ?? defaults.newSplitContent
        newWorkspaceContent = (try? container.decode(DefaultPaneContent.self, forKey: .newWorkspaceContent))
            ?? defaults.newWorkspaceContent
        // A width this build cannot name — a newer Tenon's, or a hand-edited file — is
        // dropped instead of failing the whole document. An unreadable maximum means the
        // layout decides, which is exactly the behaviour of no maximum at all.
        newPaneMaximumWidth = try? container.decode(
            SpatialExtentFraction.self,
            forKey: .newPaneMaximumWidth
        )
        sidebarVisibleOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisibleOnLaunch)
            ?? defaults.sidebarVisibleOnLaunch
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth)
            ?? defaults.sidebarWidth
        accent = try container.decodeIfPresent(AccentColor.self, forKey: .accent)
            ?? defaults.accent
        // A chrome order this build cannot name costs that key alone, for the same reason a
        // pane content does: the person's sidebar width, accent and paused schedules are not
        // worth losing to one unreadable word. A document written before the choice existed
        // has no key at all, and opens on the layout its author was looking at.
        chromeOrder = (try? container.decode(ShellChromeOrder.self, forKey: .chromeOrder))
            ?? defaults.chromeOrder
        automationSchedulesEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .automationSchedulesEnabled
        ) ?? defaults.automationSchedulesEnabled
        pausedAutomationSchedules = try container.decodeIfPresent(
            Set<AutomationScheduleKey>.self,
            forKey: .pausedAutomationSchedules
        ) ?? defaults.pausedAutomationSchedules
        // A preferences blob written before this switch existed carries the default, which
        // is on. Someone who has already turned it off has the key, so their choice stands.
        bypassAllPermissionPrompts = try container.decodeIfPresent(
            Bool.self,
            forKey: .bypassAllPermissionPrompts
        ) ?? defaults.bypassAllPermissionPrompts
        // Companion was added after the original preferences document. An unknown future
        // provider costs this field only; workspace and permission choices still load.
        companion = (try? container.decode(CompanionProfile.self, forKey: .companion))
            ?? defaults.companion
    }
}
