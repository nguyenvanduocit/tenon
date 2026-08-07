// @domain: pane-chrome
import AppKit
import SwiftUI
import TenonCore

/// The ONE renderer of the pane-header vocabulary.
///
/// SwiftUI never decides a rect here. Each control is handed the frame
/// `PaneHeaderLayout.solve` already assigned it, so the rect the card exempts from pane
/// drag, the rect it draws a `.pointingHand` over, and the rect the control actually
/// occupies are the same number. Let SwiftUI lay the run out itself and those three
/// drift apart the moment a font metric or a control's intrinsic size disagrees with the
/// solver — which is exactly the "passes its tests and still feels wrong" defect class
/// (T-055/T-063) this design exists to close.
///
/// One bar draws one *run*. The card mounts two of them with a bare AppKit band between,
/// which is what makes the pane's drag surface a single contiguous rectangle by
/// construction instead of a rect subtraction.
struct PaneHeaderBar: View {
    /// This run's placements, in card space.
    let placements: [PaneHeaderLayout.Placement]
    /// The host's own origin in card space, subtracted so a card-space rect lands
    /// correctly inside the host that draws it.
    let origin: CGPoint
    /// The pane's focus state. Chrome dims with its pane, the same way the glyph and the
    /// title already do, so a header full of controls never makes an inactive pane look
    /// like the focused one.
    let isActive: Bool
    let perform: (PaneHeaderAction) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placements, id: \.item.id) { placement in
                PaneHeaderItemView(
                    item: placement.item,
                    perform: perform
                )
                .frame(width: placement.rect.width, height: placement.rect.height)
                .offset(
                    x: placement.rect.minX - origin.x,
                    y: placement.rect.minY - origin.y
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(isActive ? 1 : 0.62)
        // The card's own `draw(_:)` paints the chrome fill and the hairline under the
        // whole strip; an opaque background here would cover both.
        .background(Color.clear)
    }
}

/// One control, one branch. The vocabulary is flat and closed, so this switch is the
/// complete statement of what a pane header can look like — there is no recursion, no
/// second renderer, and no branch a contributor can add from outside.
struct PaneHeaderItemView: View {
    let item: PaneHeaderItem
    let perform: (PaneHeaderAction) -> Void

    var body: some View {
        switch item {
        case let .dot(_, tint, tooltip):
            centered {
                Circle()
                    .fill(PaneHeaderTint.color(tint))
                    .frame(width: 7, height: 7)
            }
            .paneHeaderHelp(tooltip)

        case let .label(_, text, weight, color, truncation, tooltip):
            Text(text)
                .font(TenonTheme.interfaceFont(size: 10, weight: PaneHeaderTint.weight(weight)))
                .foregroundStyle(PaneHeaderTint.color(color))
                .lineLimit(1)
                // The solver hands a label a width between its floor and its natural
                // size; which END gives way is the label's own token, applied here
                // because the renderer is the layer that knows how to shorten a path.
                .truncationMode(PaneHeaderTint.truncation(truncation))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // `.value`: the label's own text is its spoken name, and a truncated one is
                // exactly when the tooltip matters most — it carries the part the pane ran out
                // of room to draw.
                .paneHeaderHelp(tooltip, spokenAs: .value)

        case let .badge(_, text, tint, tooltip):
            centered {
                Text(text)
                    .font(TenonTheme.interfaceFont(size: 9, weight: .semibold))
                    .foregroundStyle(PaneHeaderTint.color(tint))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(PaneHeaderTint.color(tint).opacity(0.16))
                    )
            }
            // `.value` for the same reason as `label`: a badge draws its own count or word.
            .paneHeaderHelp(tooltip, spokenAs: .value)

        case let .image(_, systemName, tint, tooltip):
            centered {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PaneHeaderTint.color(tint))
            }
            .paneHeaderHelp(tooltip)

        case .spinner:
            centered {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }

        case let .iconButton(id, systemName, tint, isEnabled, tooltip, accessibilityID):
            control(accessibilityID: accessibilityID, tooltip: tooltip) {
                Button {
                    perform(PaneHeaderAction(itemID: id))
                } label: {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PaneHeaderTint.color(tint))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }

        case let .toggle(id, systemName, isOn, isEnabled, tooltip, accessibilityID):
            control(accessibilityID: accessibilityID, tooltip: tooltip) {
                Button {
                    // `isOn` is the item's CURRENT state; the owner flips it and
                    // republishes, so the control never guesses at the next one.
                    perform(PaneHeaderAction(itemID: id))
                } label: {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isOn ? TenonTheme.amber : TenonTheme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isOn ? TenonTheme.amber.opacity(0.14) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }

        case let .segmented(id, segments, selection, isEnabled, accessibilityID):
            control(accessibilityID: accessibilityID, tooltip: nil) {
                Picker(
                    "",
                    selection: Binding(
                        get: { selection },
                        set: { perform(PaneHeaderAction(itemID: id, value: $0)) }
                    )
                ) {
                    ForEach(segments) { segment in
                        segmentLabel(segment).tag(segment.value)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!isEnabled)
            }

        case let .menu(id, systemName, entries, isEnabled, tooltip, accessibilityID):
            control(accessibilityID: accessibilityID, tooltip: tooltip) {
                Menu {
                    ForEach(entries) { entry in
                        if entry.separatorBefore {
                            Divider()
                        }
                        Button {
                            perform(PaneHeaderAction(itemID: id, value: entry.value))
                        } label: {
                            menuEntryLabel(entry)
                        }
                    }
                } label: {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TenonTheme.muted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(!isEnabled)
            }

        case let .textfield(id, value, placeholder, _, isEnabled, accessibilityID):
            control(accessibilityID: accessibilityID, tooltip: nil) {
                PaneHeaderTextFieldView(
                    itemID: id,
                    value: value,
                    placeholder: placeholder,
                    isEnabled: isEnabled,
                    perform: perform
                )
            }
        }
    }

    /// Decoration sits in the middle of its solved rect; a label is the one item that
    /// reads from the leading edge, because a truncated label must start where the eye
    /// expects the text to start.
    private func centered<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// The two things every interactive item carries and no decoration does: an
    /// XCUITest anchor its host-native producer may have set, and a tooltip.
    private func control<Content: View>(
        accessibilityID: String?,
        tooltip: String?,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paneHeaderHelp(tooltip)
            .accessibilityIdentifier(accessibilityID ?? "")
    }

    /// The hover text goes on the SEGMENT, never on the picker around it. A tooltip naming the
    /// selected option while the pointer sits over a different one would be worse than none,
    /// and an icon-only picker is where a tooltip is needed most: two glyphs, no words.
    ///
    /// `PaneHeaderSegment` keeps `tooltip` and `accessibilityLabel` equal unless the author
    /// wrote both, so the pointer and VoiceOver are told the same thing from one authored
    /// string. AppKit does carry a per-segment help string out of a `.segmented` `Picker` — it
    /// arrives as `NSSegmentedControl.toolTip(forSegment:)`, which is what
    /// `testASegmentedHeaderControlCarriesItsPerSegmentTooltipsIntoAppKit` reads back off a
    /// mounted control.
    @ViewBuilder
    private func segmentLabel(_ segment: PaneHeaderSegment) -> some View {
        if let systemName = segment.systemName {
            Image(systemName: systemName)
                .accessibilityLabel(segment.accessibilityLabel ?? segment.value)
                .paneHeaderHelp(segment.tooltip)
        } else {
            Text(segment.label ?? segment.value)
                .paneHeaderHelp(segment.tooltip)
        }
    }

    /// A checked entry shows the checkmark instead of its own symbol: once a picker has
    /// folded into the menu, reading its state back matters more than its iconography.
    @ViewBuilder
    private func menuEntryLabel(_ entry: PaneHeaderMenuEntry) -> some View {
        if entry.isOn {
            Label(entry.label, systemImage: "checkmark")
        } else if let systemName = entry.systemName {
            Label(entry.label, systemImage: systemName)
        } else {
            Text(entry.label)
        }
    }
}

/// The header's one editable control.
///
/// It keeps its own draft and only accepts a pushed `value` while the field is NOT
/// focused. Without that guard a publish landing mid-typing — a redirect, a status tick,
/// any republish of the owning view — overwrites the characters the user is entering,
/// which is a regression a browser address bar makes obvious within seconds.
private struct PaneHeaderTextFieldView: View {
    let itemID: String
    let value: String
    let placeholder: String
    let isEnabled: Bool
    let perform: (PaneHeaderAction) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(TenonTheme.interfaceFont(size: 11))
            .foregroundStyle(TenonTheme.text)
            .focused($focused)
            .disabled(!isEnabled)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TenonTheme.chrome)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).stroke(
                    focused ? TenonTheme.amber.opacity(0.55) : TenonTheme.line,
                    lineWidth: 1
                )
            )
            // A field COMMITS, it does not select: the owner hears about the text once,
            // when the user says so.
            .onSubmit { perform(PaneHeaderAction(itemID: itemID, value: draft)) }
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !focused { draft = new } }
    }
}

private extension View {
    /// Hangs hover text only when there IS hover text.
    ///
    /// `.help("")` is not "no tooltip". It registers the empty string, and AppKit shows a
    /// registered `""` as a blank yellow box — which is the same thing `PaneHeaderSegment.init`
    /// already says about an empty authored string, applied to the renderer that would otherwise
    /// manufacture one out of `tooltip ?? ""`.
    ///
    /// On a `.segmented` `Picker` it is worse than cosmetic. AppKit carries a per-segment help
    /// string through to `NSSegmentedControl.toolTip(forSegment:)`, but a help string hung on the
    /// picker REPLACES all of them with its own — so `.help("")` anywhere around a picker leaves
    /// every segment's tooltip nil and takes away the only words an icon-only picker has.
    /// Measured both ways, and pinned by
    /// `testASegmentedHeaderControlCarriesItsPerSegmentTooltipsIntoAppKit`.
    ///
    /// The branch changes view identity when a tooltip appears or disappears on an item that is
    /// already on screen. That is safe here because the one control holding state of its own —
    /// `textfield`, with its draft and its focus — is the one case the vocabulary gives no
    /// tooltip at all, so its branch never flips.
    /// `spokenAs` is the half `.help` alone does not cover. On macOS a help string becomes an
    /// accessibility HELP — a hint — never a label, so a control whose only words are its
    /// tooltip reaches VoiceOver named after its SF Symbol string instead of after the sentence
    /// its author wrote. Three of Agent Lens's own controls lost their spoken names that way.
    ///
    /// Which half a tooltip becomes depends on whether the item draws text of its own, and the
    /// rule is the one `PaneHeaderSegment.init` already applies to an icon-only segment:
    ///
    /// - `.name` for `dot`, `image`, `iconButton`, `toggle`, `menu` — a glyph has no words, so
    ///   the tooltip IS the name and lending it is the whole fix.
    /// - `.value` for `label` and `badge` — their text is already the name. Overwriting it with
    ///   the tooltip would trade one fact for another; the tooltip is the detail beside it, which
    ///   is exactly the `.accessibilityValue` shape the Agent Lens mode bar used before this
    ///   header existed.
    @ViewBuilder
    func paneHeaderHelp(_ text: String?, spokenAs role: PaneHeaderSpokenRole = .name) -> some View {
        if let text, !text.isEmpty {
            switch role {
            case .name:
                help(text).accessibilityLabel(text)
            case .value:
                help(text).accessibilityValue(text)
            }
        } else {
            self
        }
    }
}

/// Whether an item's tooltip is the only name it has, or a detail beside a name it already draws.
enum PaneHeaderSpokenRole {
    case name
    case value
}

/// Token resolution at header scale.
///
/// Colour is NOT here: `ColorToken` has one resolution point, `ViewTokenPalette`, shared
/// with the body renderer, and this file passes `.caption` to it. Header items draw at
/// the pane title's 10 points — caption scale — so `.default` reads as `muted`, leaving
/// the pane's own name the primary text in the strip; an unqualified accessory that
/// out-shouted it would undo the compression this header exists to buy.
private enum PaneHeaderTint {
    /// The header's own caption scale, passed to the shared palette so both renderers
    /// answer the token question in one switch.
    @MainActor
    static func color(_ token: ColorToken) -> Color {
        ViewTokenPalette.color(token, style: .caption)
    }

    static func weight(_ weight: FontWeight) -> Font.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }

    static func truncation(_ truncation: PaneHeaderTruncation) -> Text.TruncationMode {
        switch truncation {
        case .head: return .head
        case .middle: return .middle
        case .tail: return .tail
        }
    }
}

/// The AppKit host one run is drawn into.
///
/// It exists for one reason: SwiftUI's `Color.clear` **is** hit-testable, so an
/// `NSHostingView` covering a run would swallow every point between its controls and the
/// gaps in a header would stop being pane-drag surface. The override answers only for the
/// rects the solver actually placed a control in, and declines everything else — which
/// keeps "the header is draggable except where a control is" a property of the solution
/// rather than of SwiftUI's internal view tree.
final class PaneHeaderHostView: NSHostingView<PaneHeaderBar> {
    /// Card-space rects of this run's interactive items. Card space, not host space,
    /// because `hitTest` receives its point in the host's superview — the card.
    private var interactiveRects: [CGRect] = []

    required init(rootView: PaneHeaderBar) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    convenience init() {
        self.init(
            rootView: PaneHeaderBar(
                placements: [],
                origin: .zero,
                isActive: false,
                perform: { _ in }
            )
        )
    }

    /// Rebuilds this run from a fresh solution. Called only when the solution or the
    /// pane's focus state actually changed, so an idle pane rebuilds no view tree.
    func apply(
        _ solution: PaneHeaderLayout.Solution,
        run: PaneHeaderLayout.Run,
        isActive: Bool,
        perform: @escaping (PaneHeaderAction) -> Void
    ) {
        // Filter by the placement's own `run`, never by comparing x against the other
        // host's extent: the run is recorded in the solution precisely so the two hosts
        // cannot disagree about who owns a placement.
        let mine = solution.placements.filter { $0.run == run }
        interactiveRects = mine.filter { $0.item.isInteractive }.map(\.rect)
        let hostRect = run == .leading
            ? solution.leadingHostRect
            : solution.trailingHostRect
        rootView = PaneHeaderBar(
            placements: mine,
            origin: hostRect?.origin ?? .zero,
            isActive: isActive,
            perform: perform
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRects.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point)
    }
}
