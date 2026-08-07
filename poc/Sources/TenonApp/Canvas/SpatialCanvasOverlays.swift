// @domain: spatial-canvas
/// The two transient views a drag puts on screen: the thumbnail under the pointer and the
/// highlight over the target. Both are pure decoration with no hit-testing of their own — a
/// drag must never be interrupted by the picture of itself.
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

final class SpatialDragThumbnailView: NSView {
    private let imageView = NSImageView()

    init(image: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0.9
        layer?.backgroundColor = TenonTheme.inkNS.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.5
        layer?.borderColor = TenonTheme.amberNS.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -6)

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class SpatialDropHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = TenonTheme.amberNS.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 2
        layer?.borderColor = TenonTheme.amberNS.cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
