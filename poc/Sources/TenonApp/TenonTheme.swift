import AppKit
import SwiftUI

enum TenonTheme {
    static let ink = Color(nsColor: .tenonInk)
    static let chrome = Color(nsColor: .tenonChrome)
    static let chromeRaised = Color(nsColor: .tenonChromeRaised)
    static let panel = Color(nsColor: .tenonPanel)
    static let line = Color(nsColor: .tenonLine)
    static let text = Color(nsColor: .tenonText)
    static let muted = Color(nsColor: .tenonMuted)
    static let amber = Color(nsColor: .tenonAmber)
    static let inkNS = NSColor.tenonInk
    static let chromeNS = NSColor.tenonChrome
    static let chromeRaisedNS = NSColor.tenonChromeRaised
    static let panelNS = NSColor.tenonPanel
    static let lineNS = NSColor.tenonLine
    static let textNS = NSColor.tenonText
    static let mutedNS = NSColor.tenonMuted
    static let amberNS = NSColor.tenonAmber

    static let sidebarWidth: CGFloat = 232
    static let titleBarHeight: CGFloat = 46
    static let trafficLightInset: CGFloat = 78
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
    static let tenonAmber = NSColor(hex: 0xE6A33A)

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
