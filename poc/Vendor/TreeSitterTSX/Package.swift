// swift-tools-version: 5.10

import PackageDescription

// The tree-sitter TSX grammar (TypeScript + JSX), exposed through a
// Tenon-namespaced target so it can coexist with STTextView-Plugin-Neon.
let package = Package(
    name: "TreeSitterTSX",
    products: [
        .library(name: "TreeSitterTSX", targets: ["TenonTreeSitterTSX"])
    ],
    targets: [
        .target(
            name: "TenonTreeSitterTSX",
            path: "Sources/TreeSitterTSX",
            cSettings: [.headerSearchPath("src")]
        )
    ]
)
