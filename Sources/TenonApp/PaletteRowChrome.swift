// @domain: command-surface
import SwiftUI

/// The row every palette and launcher surface draws, with no opinion on why the row is
/// there.
///
/// Three different things reach this shape: a fuzzy-ranked command, a plugin's appended
/// provider result, and a tab's own Copy Tab ID utility. Only the first is an answer from
/// the ranking system, so a row presentation typed on `CommandMatch` left the other two
/// choosing between impersonating a ranked command and restating the highlight by hand —
/// and both of those shipped. Membership in the ranked catalog is a question about data;
/// looking and behaving like a row is a question about presentation. This type answers only
/// the second, which is what lets a local action look like what it is without pretending to
/// be something it is not.
struct PaletteRowChrome: View {
    /// Row metrics. The overlay is a destination the user summons and looks at; the
    /// launcher is a menu they flick through. Same anatomy, two scales.
    enum Density {
        case regular
        case compact

        var height: CGFloat { self == .compact ? 28 : 40 }
        var horizontalPadding: CGFloat { self == .compact ? 12 : 14 }
        /// Inset of the highlight from the row edge, so the accent reads as a pill
        /// inside the surface instead of a full-bleed band.
        var railInset: CGFloat { self == .compact ? 6 : 8 }
        var cornerRadius: CGFloat { self == .compact ? 6 : 8 }
        var spacing: CGFloat { self == .compact ? 8 : 10 }
        var iconWidth: CGFloat { self == .compact ? 15 : 18 }
        var iconSize: CGFloat { self == .compact ? 11 : 13 }
        var titleSize: CGFloat { self == .compact ? 12 : 14 }
        var accessorySize: CGFloat { self == .compact ? 11 : 12 }
    }

    let icon: String?
    /// Text rather than a generic view: every row title is a run of characters, and a
    /// ranked one is that same run with its matched characters accented. Concatenated
    /// `Text` covers both, and keeping it concrete is what lets `Density` be referenced
    /// without generic arguments by the height arithmetic in `LauncherListHeight`.
    let title: Text
    let isSelected: Bool
    var density: Density = .regular
    var subtitle: String? = nil
    var trailing: String? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: density.spacing) {
            Image(systemName: icon ?? "command")
                .font(.system(size: density.iconSize))
                .frame(width: density.iconWidth)
                .foregroundStyle(isSelected ? TenonTheme.amber : TenonTheme.muted)

            title
                .font(TenonTheme.interfaceFont(size: density.titleSize))
                .foregroundStyle(TenonTheme.text)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 12)

            if let subtitle {
                Text(subtitle)
                    .font(TenonTheme.interfaceFont(size: density.accessorySize))
                    .foregroundStyle(TenonTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let trailing {
                Text(trailing)
                    .font(TenonTheme.utilityFont(size: density.accessorySize))
                    .foregroundStyle(TenonTheme.muted)
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .frame(height: density.height)
        .background {
            RoundedRectangle(cornerRadius: density.cornerRadius, style: .continuous)
                .fill(highlight)
                .padding(.horizontal, density.railInset)
        }
        // Keyboard selection and pointer hover are separate signals: arrowing never
        // moves under the mouse, so the hovered row gets its own quieter wash and the
        // accent stays with whatever Enter would run.
        .onHover { isHovered = $0 }
    }

    private var highlight: Color {
        if isSelected {
            return TenonTheme.amber.opacity(isHovered ? 0.24 : 0.16)
        }
        return isHovered ? TenonTheme.text.opacity(0.07) : .clear
    }
}
