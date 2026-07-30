import AppKit
import SwiftUI
import TenonCore

/// The live accent colour for Tenon's chrome, swapped from the user's `AccentColor`
/// preference at launch and whenever Settings changes it. Kept process-wide so
/// `TenonTheme.amber` stays the single accent source every view already reads; the
/// shell rebuilds its view tree on an accent change so the new colour propagates.
enum ThemeRuntime {
    @MainActor
    private(set) static var accentNS = NSColor(
        hex: AccentColor.amber.hex
    )

    @MainActor
    static func setAccent(_ accent: AccentColor) {
        accentNS = NSColor(hex: accent.hex)
    }
}

enum TenonTheme {
    static let ink = Color(nsColor: .tenonInk)
    static let chrome = Color(nsColor: .tenonChrome)
    static let chromeRaised = Color(nsColor: .tenonChromeRaised)
    static let panel = Color(nsColor: .tenonPanel)
    static let line = Color(nsColor: .tenonLine)
    static let text = Color(nsColor: .tenonText)
    static let muted = Color(nsColor: .tenonMuted)
    /// The user's accent. Computed so a launch/Settings accent swap is reflected the
    /// next time a view reads it (the shell forces that read by rebuilding on change).
    @MainActor
    static var amber: Color { Color(nsColor: .tenonAmber) }
    static let inkNS = NSColor.tenonInk
    static let chromeNS = NSColor.tenonChrome
    static let chromeRaisedNS = NSColor.tenonChromeRaised
    static let panelNS = NSColor.tenonPanel
    static let lineNS = NSColor.tenonLine
    static let textNS = NSColor.tenonText
    static let mutedNS = NSColor.tenonMuted
    @MainActor
    static var amberNS: NSColor { .tenonAmber }

    static let sidebarWidth: CGFloat = 232
    // Kept close to the 28-pt band macOS lays the traffic lights out in, so the tab
    // strip reads as one row with them instead of floating below their centre line.
    static let titleBarHeight: CGFloat = 36
    static let trafficLightInset: CGFloat = 78
    // A tab chip's floor. A short title — "~/p/t/poc" — would otherwise shrink the chip
    // to a stub the pointer has to hunt for; the title's own cap keeps the ceiling.
    static let tabMinWidth: CGFloat = 140
    static let statusBarHeight: CGFloat = 24
    static let slotHeaderHeight: CGFloat = 31
    static let slotGutter: CGFloat = 8
    static let slotCornerRadius: CGFloat = 7

    static func interfaceFont(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func utilityFont(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func interfaceNSFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func utilityNSFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    static let tenonInk = NSColor(hex: 0x090B0E)
    static let tenonChrome = NSColor(hex: 0x111419)
    static let tenonChromeRaised = NSColor(hex: 0x171B21)
    static let tenonPanel = NSColor(hex: 0x0D1014)
    static let tenonLine = NSColor(hex: 0x282E36)
    static let tenonText = NSColor(hex: 0xE8EBEF)
    static let tenonMuted = NSColor(hex: 0x8E96A2)
    /// Reads the live accent so every existing `TenonTheme.amber*` reference follows
    /// the user's chosen colour without any call site changing.
    @MainActor
    static var tenonAmber: NSColor { ThemeRuntime.accentNS }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
