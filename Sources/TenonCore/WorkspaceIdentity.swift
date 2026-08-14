// @domain: workspace-model
import Foundation

/// How a workspace is named, marked, and tinted wherever the host represents it.
///
/// Identity is deliberately *not* identity: a workspace is a `UUID`, and everything here is
/// presentation. Renaming, re-marking and re-tinting a workspace leave its id, root
/// directory, tabs, panes and plugin scope exactly where they were, which is why two
/// workspaces may carry the same display name without anything downstream becoming
/// ambiguous.
///
/// The name is stored on `Workspace` because every surface already reads `workspace.name`.
/// What lives here is the pair of rules that were previously written out at each call site:
/// what Tenon calls a workspace when nobody has named it, and what a typed name becomes
/// before it is stored.
public enum WorkspaceName {
    /// A row, a menu item, and a scope label all render a name on one line. 60 characters is
    /// past the point where any of them still shows the end of it, so it is where a typed
    /// name stops rather than where a layout starts lying.
    public static let maximumLength = 60

    /// What Tenon calls a workspace rooted at `path` when nobody has named it — the name a
    /// new workspace opens with, and the one `resetIdentity` restores.
    public static func derived(for path: URL) -> String {
        sanitized(path.lastPathComponent) ?? path.path
    }

    /// A typed name as it will be stored, or nil when it carries no name at all.
    ///
    /// Surrounding and interior whitespace collapse to single spaces — a name pasted out of
    /// a terminal arrives with newlines and runs of padding, and a one-line row would render
    /// those as a ragged gap it cannot explain. Nil is the reset signal: clearing the field
    /// asks for the derived name back, so "no name" never has to be spelled two ways.
    public static func sanitized(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }
}

/// The curated glyph a workspace is marked with.
///
/// A closed vocabulary rather than a free SF Symbol name: the host draws these at 11 points
/// inside a 29-point frame, and an arbitrary symbol name is both undrawable when misspelled
/// and unannounceable to VoiceOver. Each case carries its own spoken label, so the mark is
/// never carried by shape alone.
public enum WorkspaceSymbol: String, CaseIterable, Codable, Sendable {
    case folder
    case terminal
    case hammer
    case book
    case globe
    case bolt
    case package
    case design
    case metrics
    case bug
    case sandbox
    case starred
    case code
    case braces
    case server
    case drive
    case processor
    case memory
    case network
    case tools
    case document
    case verified
    case shield
    case flame

    /// What a workspace is marked with until someone chooses otherwise.
    public static let `default` = WorkspaceSymbol.folder

    /// The SF Symbol the shell draws. Held here beside the label so the two cannot drift.
    public var systemName: String {
        switch self {
        case .folder: return "folder"
        case .terminal: return "terminal"
        case .hammer: return "hammer"
        case .book: return "book"
        case .globe: return "globe"
        case .bolt: return "bolt"
        case .package: return "shippingbox"
        case .design: return "paintbrush"
        case .metrics: return "chart.bar"
        case .bug: return "ant"
        case .sandbox: return "leaf"
        case .starred: return "star"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .braces: return "curlybraces"
        case .server: return "server.rack"
        case .drive: return "externaldrive"
        case .processor: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .tools: return "wrench.and.screwdriver"
        case .document: return "doc.text"
        case .verified: return "checkmark.seal"
        case .shield: return "shield"
        case .flame: return "flame"
        }
    }

    /// What the picker shows and VoiceOver announces.
    public var label: String {
        switch self {
        case .folder: return "Folder"
        case .terminal: return "Terminal"
        case .hammer: return "Build"
        case .book: return "Docs"
        case .globe: return "Web"
        case .bolt: return "Automation"
        case .package: return "Package"
        case .design: return "Design"
        case .metrics: return "Metrics"
        case .bug: return "Bugs"
        case .sandbox: return "Sandbox"
        case .starred: return "Starred"
        case .code: return "Code"
        case .braces: return "Braces"
        case .server: return "Server"
        case .drive: return "Drive"
        case .processor: return "Processor"
        case .memory: return "Memory"
        case .network: return "Network"
        case .tools: return "Tools"
        case .document: return "Document"
        case .verified: return "Verified"
        case .shield: return "Shield"
        case .flame: return "Flame"
        }
    }
}

/// One uploaded workspace mark after the host has decoded, bounded, and normalized it.
///
/// The bytes live with the catalog rather than pointing back to the selected file: upload
/// means the workspace keeps its mark after the source file moves or disappears. The UUID
/// gives SwiftUI a cheap cache key and survives persistence with the bytes.
public struct WorkspaceCustomIcon: Equatable, Sendable {
    public static let maximumPNGBytes = 128 * 1_024
    public static let maximumPNGBase64Characters =
        ((maximumPNGBytes + 2) / 3) * 4
    private static let pngSignature: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ]

    /// A raw image sent through `workspace.identity.set.v1` is still bounded by the 1 MiB
    /// intent envelope. Base64 expands by about one third, so this leaves room for framing
    /// while accepting a 512 KiB source image that the host then normalizes.
    public static let maximumImportBase64Characters = 700_000

    public let id: UUID
    public let pngData: Data

    public init?(id: UUID = UUID(), pngData: Data) {
        guard pngData.count <= Self.maximumPNGBytes,
              pngData.starts(with: Self.pngSignature)
        else { return nil }
        self.id = id
        self.pngData = pngData
    }
}

/// The colour a workspace is drawn in, and where it comes from when nobody has chosen one.
///
/// A workspace exists to be told apart from the other workspaces, and the cheapest moment
/// to do that is the moment it is opened — before anyone has customised anything. So the
/// default is not "the same as everything else": it is a colour derived from the folder the
/// workspace is rooted at, which costs a person nothing and requires them to remember no
/// mapping they chose. Choosing a colour explicitly still wins; this is only what stands in.
///
/// What it cannot promise: twelve colours cannot keep eight workspaces distinct — by
/// birthday alone a couple will share one, and a wider palette would only buy hues too close
/// to tell apart. The popover is how a clash that matters gets settled.
public enum WorkspaceTint {
    /// Ten hues at one lightness and saturation, so no colour reads as more important than
    /// another — a workspace is not ranked by the folder it happens to sit in. The pair
    /// (65% saturation, 66% lightness) is what keeps the darkest of them legible on
    /// `tenonChrome`.
    ///
    /// The hues are spaced by eye rather than evenly, because the eye is not even: twelve
    /// hues at a tidy 30° apart put three of them in the greens, where human hue
    /// discrimination is weakest, and a sidebar drawn that way showed the three greens
    /// reading as one colour. Ten chosen hues sit 25.1 apart in CIELAB against the even
    /// twelve's 16.7 — visibly different rather than different on measurement — and the
    /// two colours given up cost about a third of a workspace in collisions.
    /// `WorkspaceTintTests` holds both properties.
    public static let palette: [UInt32] = [
        0xE1_70_70,
        0xE1_9F_70,
        0xE1_CE_70,
        0x70_E1_7F,
        0x70_E1_CA,
        0x70_C3_E1,
        0x70_92_E1,
        0x99_70_E1,
        0xE1_70_E1,
        0xE1_70_A8,
    ]

    /// The colour the folder at `path` derives.
    ///
    /// The path is normalized the way `RecentWorkspaceStore.folderKey` normalizes it, so the
    /// directory URL an open panel hands back and the plain path restored from disk are one
    /// workspace with one colour. The full path is hashed rather than the folder name
    /// because two checkouts named `app` in different trees are exactly the pair a person
    /// most needs told apart.
    public static func derived(forPath path: URL) -> UInt32 {
        palette[Int(fnv1a(RecentWorkspaceStore.folderKey(path)) % UInt32(palette.count))]
    }

    /// The colour a workspace at `path` is actually drawn in: the one chosen, or the one
    /// derived. One resolver, so no surface spells that precedence its own way.
    public static func hex(for accent: AccentColor?, at path: URL) -> UInt32 {
        accent?.hex ?? derived(forPath: path)
    }

    /// FNV-1a, written out rather than reached for.
    ///
    /// `String.hashValue` is seeded per process: a workspace would come back a different
    /// colour after every relaunch, which destroys precisely the recognition this rule
    /// exists to create. A hash whose value is part of what the product promises has to be
    /// one whose value is ours.
    private static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return hash
    }
}

/// A workspace's mark and tint. The name lives on `Workspace` itself; these are the two
/// values that had nowhere to live before.
///
/// `accent` is optional and nil is not a colour: it means automatic, and the colour that
/// stands in is the one `WorkspaceTint` derives from the workspace's own folder. So a
/// catalog nobody has customised already reads as a set of distinct workspaces, and the
/// twelve named accents remain available to anyone who wants to settle a colour themselves.
public struct WorkspaceAppearance: Equatable, Sendable {
    public var symbol: WorkspaceSymbol
    public var accent: AccentColor?
    public var customIcon: WorkspaceCustomIcon?

    public init(
        symbol: WorkspaceSymbol = .default,
        accent: AccentColor? = nil,
        customIcon: WorkspaceCustomIcon? = nil
    ) {
        self.symbol = symbol
        self.accent = accent
        self.customIcon = customIcon
    }

    /// What a row and VoiceOver call the selected mark. A custom bitmap has no trustworthy
    /// embedded label, so its product meaning is exactly the choice the person made.
    public var iconLabel: String {
        customIcon == nil ? symbol.label : "Custom icon"
    }

    /// What every workspace looks like until someone customises it, and what `resetIdentity`
    /// restores.
    public static let `default` = WorkspaceAppearance()

    public var isDefault: Bool { self == .default }
}
