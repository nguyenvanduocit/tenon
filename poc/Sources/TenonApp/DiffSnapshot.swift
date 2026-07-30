import AppKit
import SwiftUI
import TenonCore

/// Dev-only offscreen snapshots of the native diff/changes views, so they can be seen
/// on a headless machine (no display / `screencapture`). Gated by env vars:
///
///     TENON_DIFF_SNAPSHOT=/path/out.png swift run tenon-poc
///     TENON_CHANGES_SNAPSHOT=/path/out.png swift run tenon-poc
///
/// Renders the real view through an offscreen `NSHostingView` + `cacheDisplay`, writes
/// the PNG, and exits before any window opens. Not part of normal operation.
enum DiffSnapshot {
    @MainActor
    static func renderIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["TENON_DIFF_SNAPSHOT"], !path.isEmpty { renderDiff(to: path) }
        if let path = env["TENON_CHANGES_SNAPSHOT"], !path.isEmpty { renderChanges(to: path) }
    }

    @MainActor
    private static func renderDiff(to path: String) {
        let old = """
        func resolveRepo(_ setting: String) -> String? {
            if setting.isEmpty { return nil }
            return setting
        }

        func status(in repo: String) -> [Entry] {
            let out = run(["status", "--porcelain"], in: repo)
            return out.split(separator: "\\n").map { Entry(line: String($0)) }
        }
        """
        let new = """
        func resolveRepo(_ setting: String) -> String? {
            let trimmed = setting.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "~", FileManager.default.fileExists(atPath: trimmed), isDirectory(trimmed) else { return nil }
            return trimmed
        }

        func status(in repo: String) -> [Entry] {
            let out = run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: repo)
            return out.split(separator: "\\0", omittingEmptySubsequences: true).compactMap { Entry(record: String($0)) }
        }
        """
        let request = DiffRequest(
            source: .inline(oldText: old, newText: new),
            fileName: "GitStatus.swift",
            title: "GitStatus.swift"
        )
        write(DiffSlotView(request: request, startSplit: true),
              size: CGSize(width: 900, height: 560), to: path)
    }

    @MainActor
    private static func renderChanges(to path: String) {
        let staged = [
            ChangeEntry(path: "Sources/TenonCore/LineDiff.swift", badge: "A", tint: .added, staged: true, untracked: false),
            ChangeEntry(path: "Sources/TenonApp/DiffSlotView.swift", badge: "M", tint: .modified, staged: true, untracked: false),
        ]
        let changed = [
            ChangeEntry(path: "plugins/git/main.js", badge: "M", tint: .modified, staged: false, untracked: false),
            ChangeEntry(path: "Sources/TenonCore/PluginRuntime.swift", badge: "M", tint: .modified, staged: false, untracked: false),
            ChangeEntry(path: "Sources/TenonApp/ChangesPanelView.swift", badge: "?", tint: .untracked, staged: false, untracked: true),
            ChangeEntry(path: "docs/legacy-changes-view.md", badge: "D", tint: .removed, staged: false, untracked: false),
        ]
        let model = ChangesModel(previewBranch: "main", staged: staged, changed: changed)
        write(ChangesPanelView(previewModel: model), size: CGSize(width: 460, height: 620), to: path)
    }

    @MainActor
    private static func write(_ view: some View, size: CGSize, to path: String) {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Give SwiftUI real runloop turns to lay out its ScrollView content and
        // commit its layer before the offscreen capture.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("snapshot: no bitmap rep\n".utf8))
            exit(2)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: png encode failed\n".utf8))
            exit(3)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("snapshot: wrote \(path)\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot: write failed: \(error)\n".utf8))
            exit(3)
        }
    }
}
