// @domain: workspace-model
import Foundation
import TenonIntentCore

/// A pane's default content, chosen in Settings and resolved to a live `SlotContent`
/// when the shell opens a new tab, split, or workspace. A pure, `Codable` enum so the
/// preference persists and the resolution rule stays testable without a window.
public enum DefaultPaneContent: String, CaseIterable, Codable, Sendable {
    case terminal
    case files
    case changes
    case docs
    case browser
    case empty

    /// Label for the Settings picker.
    public var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .changes: return "Changes"
        case .docs: return "Docs"
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
        case .docs: return .docs
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
    case blue
    case green
    case purple
    case pink

    public var label: String {
        switch self {
        case .amber: return "Amber"
        case .blue: return "Blue"
        case .green: return "Green"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    /// 0xRRGGBB the shell builds its accent colour from.
    public var hex: UInt32 {
        switch self {
        case .amber: return 0xE6A33A
        case .blue: return 0x4C8DFF
        case .green: return 0x4CC38A
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
    public var sidebarVisibleOnLaunch: Bool
    public var sidebarWidth: Double
    public var accent: AccentColor
    /// Global host preference for scheduled automation delivery. Disabling it pauses
    /// wall-clock firings without disabling or unloading the plugins that declared them.
    public var automationSchedulesEnabled: Bool
    /// Host-owned per-schedule pauses. The manifest still owns the declaration; this
    /// preference only controls whether its scheduled firing is delivered automatically.
    public var pausedAutomationSchedules: Set<AutomationScheduleKey>

    public init(
        newTabContent: DefaultPaneContent = .terminal,
        newSplitContent: DefaultPaneContent = .terminal,
        newWorkspaceContent: DefaultPaneContent = .terminal,
        sidebarVisibleOnLaunch: Bool = true,
        sidebarWidth: Double = 232,
        accent: AccentColor = .amber,
        automationSchedulesEnabled: Bool = true,
        pausedAutomationSchedules: Set<AutomationScheduleKey> = []
    ) {
        self.newTabContent = newTabContent
        self.newSplitContent = newSplitContent
        self.newWorkspaceContent = newWorkspaceContent
        self.sidebarVisibleOnLaunch = sidebarVisibleOnLaunch
        self.sidebarWidth = sidebarWidth
        self.accent = accent
        self.automationSchedulesEnabled = automationSchedulesEnabled
        self.pausedAutomationSchedules = pausedAutomationSchedules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppPreferences()
        newTabContent = try container.decodeIfPresent(DefaultPaneContent.self, forKey: .newTabContent)
            ?? defaults.newTabContent
        newSplitContent = try container.decodeIfPresent(DefaultPaneContent.self, forKey: .newSplitContent)
            ?? defaults.newSplitContent
        newWorkspaceContent = try container.decodeIfPresent(DefaultPaneContent.self, forKey: .newWorkspaceContent)
            ?? defaults.newWorkspaceContent
        sidebarVisibleOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisibleOnLaunch)
            ?? defaults.sidebarVisibleOnLaunch
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth)
            ?? defaults.sidebarWidth
        accent = try container.decodeIfPresent(AccentColor.self, forKey: .accent)
            ?? defaults.accent
        automationSchedulesEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .automationSchedulesEnabled
        ) ?? defaults.automationSchedulesEnabled
        pausedAutomationSchedules = try container.decodeIfPresent(
            Set<AutomationScheduleKey>.self,
            forKey: .pausedAutomationSchedules
        ) ?? defaults.pausedAutomationSchedules
    }
}
