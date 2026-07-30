// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Tenon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tenon", targets: ["TenonApp"]),
        // Thin Foundation-only client that drives the running app over its control socket.
        .executable(name: "tenon-cli", targets: ["TenonCLI"]),
        .library(name: "TenonIntentCore", targets: ["TenonIntentCore"]),
        .library(name: "TenonCore", targets: ["TenonCore"]),
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
            ]
        ),

        // Headless plugin host. No AppKit / SwiftUI — this is what `swift test` exercises.
        .target(name: "TenonCore", dependencies: ["TenonIntentCore"]),

        // Thin C shim over the prebuilt GhosttyKit.xcframework (the Muxy pattern).
        // ghostty.h is synced from the xcframework by scripts/setup-ghosttykit.sh;
        // the placeholder .c exists only so SwiftPM has something to compile.
        .target(name: "GhosttyKit", path: "GhosttyKit", publicHeadersPath: "."),

        // SwiftUI shell. Owns the TerminalSurface implementations.
        .executableTarget(
            name: "TenonApp",
            dependencies: [
                "TenonIntentCore",
                "TenonCore",
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
            ],
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
            dependencies: ["TenonIntentCore", "TenonCore"],
            swiftSettings: [
                .define("TENON_CLI_IMPORTS_CORE_MODULE"),
            ]
        ),

        .testTarget(name: "TenonIntentCoreTests", dependencies: ["TenonIntentCore"]),
        .testTarget(
            name: "TenonCoreTests",
            dependencies: ["TenonIntentCore", "TenonCore"]
        ),
        .testTarget(name: "TenonAppStateTests", dependencies: ["TenonApp"]),
    ],
    swiftLanguageModes: [.v6]
)
