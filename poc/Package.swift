// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tenon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tenon", targets: ["TenonApp"]),
        .library(name: "TenonCore", targets: ["TenonCore"]),
    ],
    targets: [
        // Headless plugin host. No AppKit / SwiftUI — this is what `swift test` exercises.
        .target(name: "TenonCore"),

        // Thin C shim over the prebuilt GhosttyKit.xcframework (the Muxy pattern).
        // ghostty.h is synced from the xcframework by scripts/setup-ghosttykit.sh;
        // the placeholder .c exists only so SwiftPM has something to compile.
        .target(name: "GhosttyKit", path: "GhosttyKit", publicHeadersPath: "."),

        // SwiftUI shell. Owns the TerminalSurface implementations.
        .executableTarget(
            name: "TenonApp",
            dependencies: [
                "TenonCore",
                "GhosttyKit",
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

        .testTarget(name: "TenonCoreTests", dependencies: ["TenonCore"]),
    ]
)
