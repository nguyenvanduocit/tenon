// swift-tools-version: 6.1
import PackageDescription

// Every first-party Swift target treats warnings as errors — the boundary law's
// "Swift 6 warnings-as-errors build" criterion (T-020). `.unsafeFlags` because
// `.treatAllWarnings(as:)` needs tools-version 6.2; acceptable for the same reason
// as the GhosttyKit linker flags below — tenon is an app, never a versioned SwiftPM
// dependency. Vendored packages, dependency packages, and the GhosttyKit C shim are
// deliberately outside the flag: their diagnostics (including the two prebuilt ImGui
// linker warnings) are not ours to fail the build on.
let warningsAsErrors: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "Tenon",
    // Declared so the app has a base language at all. Without it SwiftPM builds no resource
    // bundle, `Text("…")` has nothing to look a key up in, and "translate this later" stays
    // structurally impossible rather than merely undone.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    // Two executables, and nothing else on offer.
    //
    // Tenon's extension surface is the manifest-backed plugin boundary — declared intents,
    // contributions, events — not its implementation language or Swift modules. Publishing
    // `TenonCore`, `TenonIntentCore`, or the compiled bundled-plugin target as libraries would
    // invite a dependency this project has never promised to keep working, and the same file
    // already says the app is never a versioned SwiftPM dependency. The modules stay internal;
    // `package` access is how a target inside this package reaches another (see `PluginHost`),
    // and a Swift SDK would need its own SemVer, documented symbols and a compatibility
    // baseline before it existed as a product.
    products: [
        .executable(name: "tenon", targets: ["TenonApp"]),
        // Thin Foundation-only client that drives the running app over its control socket.
        .executable(name: "tenon-cli", targets: ["TenonCLI"]),
    ],
    dependencies: [
        // The editor carries three source patches that are in no upstream release —
        // see Vendor/STTextView/KERO_PATCHES.md. One is load-bearing: the Neon
        // highlighter sets a rendering attribute over zero-length tree-sitter tokens
        // and TextKit raises on that, so the first markdown file opened would crash.
        .package(path: "Vendor/STTextView"),
        // Exact tree from upstream commit 5a30db4ce7908a5414e7b499e2379bdc49991cd1.
        // Its local manifest routes STTextView to the patched sibling package, giving
        // SwiftPM one deterministic location for the sttextview identity.
        .package(path: "Vendor/STTextView-Plugin-Neon"),
        // The incremental highlighter the plugin drives, plus tree-sitter itself. Named
        // here because Tenon uses them directly: the stock NeonPlugin loads one query
        // file per language, which loses everything a grammar *inherits* (TypeScript
        // inherits JavaScript, C++ inherits C), so the highlighter glue is ours.
        .package(url: "https://github.com/kylemacomber/Neon", revision: "ce8d252"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
        // tree-sitter-typescript ships JSX as a separate grammar and the plugin builds
        // only the typescript half, so `.tsx` needs this one vendored (kero's copy).
        .package(path: "Vendor/TreeSitterTSX"),
        // Canonical JSON Schema 2020-12 validation for the Intent Bus. Pin the exact
        // pre-1.0 release so executable contract acceptance cannot drift on resolve.
        .package(
            url: "https://github.com/ajevans99/swift-json-schema",
            exact: "0.13.1"
        ),
    ],
    targets: [
        // Runtime-independent invocation kernel. It never imports AppKit or JavaScriptCore.
        .target(
            name: "TenonIntentCore",
            dependencies: [
                .product(name: "JSONSchema", package: "swift-json-schema"),
            ],
            swiftSettings: warningsAsErrors
        ),

        // Headless plugin host. No AppKit / SwiftUI — this is what `swift test` exercises.
        .target(
            name: "TenonCore",
            dependencies: ["TenonIntentCore"],
            swiftSettings: warningsAsErrors
        ),

        // Manifest-backed plugins whose implementation ships as Swift in this exact build.
        // This is an internal backend, not a public native SDK or a second authority model.
        .target(
            name: "TenonBundledPlugins",
            dependencies: ["TenonIntentCore", "TenonCore"],
            swiftSettings: warningsAsErrors
        ),

        // Thin C shim over the prebuilt GhosttyKit.xcframework (the Muxy pattern).
        // ghostty.h is synced from the xcframework by scripts/internal/setup-ghostty.sh;
        // the placeholder .c exists only so SwiftPM has something to compile.
        .target(name: "GhosttyKit", path: "GhosttyKit", publicHeadersPath: "."),

        // SwiftUI shell. Owns the TerminalSurface implementations.
        .executableTarget(
            name: "TenonApp",
            dependencies: [
                "TenonIntentCore",
                "TenonCore",
                "TenonBundledPlugins",
                "GhosttyKit",
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "STTextView-Plugin-Neon", package: "STTextView-Plugin-Neon"),
                .product(name: "Neon", package: "Neon"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterTSX", package: "TreeSitterTSX"),
            ],
            resources: [
                // The app mark and icon. Declared so `swift build` handles the catalog
                // instead of warning that it is unhandled; see ShellTitleBar for how the
                // mark is loaded, because SwiftPM does not run `actool`.
                .process("Assets.xcassets"),
                // Where every user-visible string resolves. SwiftUI's `Text("…")` is already a
                // localization key; without a catalog to resolve it against, that was a
                // promise with nothing behind it.
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: warningsAsErrors,
            linkerSettings: [
                // The prebuilt static library inside the xcframework. `.unsafeFlags`
                // is the Muxy pattern too — acceptable because tenon is an
                // executable, never a versioned SwiftPM dependency.
                .unsafeFlags([
                    "GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Speech"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("c++"),
                .linkedLibrary("sqlite3"),
            ]
        ),

        // The `tenon-cli` binary: Foundation + POSIX sockets only, no AppKit/GhosttyKit, so it
        // builds and ships independently of the terminal stack.
        .executableTarget(
            name: "TenonCLI",
            dependencies: ["TenonIntentCore"],
            swiftSettings: warningsAsErrors
        ),

        .testTarget(
            name: "TenonIntentCoreTests",
            dependencies: ["TenonIntentCore"],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "TenonCoreTests",
            dependencies: ["TenonIntentCore", "TenonCore", "TenonBundledPlugins"],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "TenonAppStateTests",
            dependencies: ["TenonApp"],
            swiftSettings: warningsAsErrors
        ),
    ],
    swiftLanguageModes: [.v6]
)
