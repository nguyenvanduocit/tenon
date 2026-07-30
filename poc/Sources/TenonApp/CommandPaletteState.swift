import Foundation
import TenonCore

/// Presentation state for the command palette (⌘⇧P) plus the persisted frecency that
/// floats a developer's habitual commands to the top. The ranking lives in
/// `TenonCore` (`CommandIndex`); this shell object only holds what's on screen and
/// records which command was picked. Frecency survives relaunch in a dot-file.
@Observable
final class CommandPaletteState {
    var isPresented = false
    var query = ""
    /// Index of the highlighted result. Clamped to the live result count by the view.
    var selection = 0
    var isRunning = false
    var errorMessage: String?

    @ObservationIgnored private var store: Frecency
    @ObservationIgnored private let storeURL: URL

    /// The current frecency, read fresh each time the palette ranks results.
    var frecency: Frecency { store }

    init(storeURL: URL? = nil) {
        let url = storeURL ?? Self.defaultStoreURL()
        self.storeURL = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Frecency.self, from: data) {
            self.store = decoded
        } else {
            self.store = Frecency()
        }
    }

    /// Open the palette on a clean query with the first result selected.
    func present() {
        query = ""
        selection = 0
        isRunning = false
        errorMessage = nil
        isPresented = true
    }

    func dismiss() {
        isRunning = false
        errorMessage = nil
        isPresented = false
    }

    /// Toggle from the ⌘⇧P menu command: a second press of the launch key closes it
    /// (destiner.io: a palette should disappear on its own hotkey).
    func toggle() {
        if isPresented { dismiss() } else { present() }
    }

    /// Record that the user ran a command, so it ranks higher next time, and persist.
    func record(_ commandID: String, now: Date = Date()) {
        store.record(commandID, at: now)
        try? JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }

    private static func defaultStoreURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Tenon", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(".command-frecency.json")
    }
}
