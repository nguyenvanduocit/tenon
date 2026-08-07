// @domain: spatial-canvas
import AppKit
import SwiftUI
import TenonCore
import TenonIntentCore

/// What a mounted pane's content was built from.
///
/// A card keeps this so a reconfigure can tell "the same plugin still owns this pane" from
/// "a different one does now" without rebuilding a live web surface to find out.
struct PluginRenderIdentity: Hashable {
    let installation: PluginInstallationKey
    let allowsWebView: Bool
}

/// How a pane's SwiftUI content is hosted inside the canvas.
///
/// A pane's size is the canvas's answer, not the content's: `SpatialSlotCardView.layout()`
/// sets `contentHost.frame` from the card's own bounds, and nothing reads a size back out
/// of the pane. A hosting view constructed plainly does not know that — it publishes
/// min/ideal/max constraints derived from what it contains, so AppKit can ask a scrolling
/// pane how tall it "wants" to be, and answering that means measuring content the pane
/// never displays. Declaring no sizing options states the arrangement that already holds.
@MainActor
enum PaneContentHost {
    static func make(_ view: AnyView) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.wantsLayer = true
        return host
    }
}
