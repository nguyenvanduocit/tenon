import CoreServices
import Foundation

/// Recursive FSEvents watch over the plugins root.
///
/// Reports *plugin names* (the directory component directly under the root), not raw paths,
/// so the host never has to think about editor temp files or atomic-rename dances.
public final class PluginWatcher {
    private let watchPath: String
    /// Every spelling of the root a delivered event path might use, each with a trailing "/".
    ///
    /// FSEvents reports fully-resolved paths (`/private/var/...`) while `URL` APIs like
    /// `resolvingSymlinksInPath()` deliberately *strip* a leading `/private` — so a naive
    /// prefix check against a single spelling silently drops every event under /tmp, /var,
    /// or any symlinked parent.
    private let rootPrefixes: [String]

    private let onChange: (Set<String>) -> Void
    private let queue = DispatchQueue(label: "tenon.plugin-watcher")

    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var debounce: DispatchWorkItem?

    /// - Parameter onChange: called on the **main queue** with the set of plugin names touched.
    public init(root: URL, onChange: @escaping (Set<String>) -> Void) {
        let declared = root.standardizedFileURL.path

        var spellings: Set<String> = [declared]
        if let resolved = realpath(declared, nil) {
            spellings.insert(String(cString: resolved))
            free(resolved)
        }
        for path in spellings {
            if path.hasPrefix("/private/") {
                spellings.insert(String(path.dropFirst("/private".count)))
            } else {
                spellings.insert("/private" + path)
            }
        }

        self.watchPath = spellings.contains(declared) ? declared : (spellings.first ?? declared)
        self.rootPrefixes = spellings.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, pathsPtr, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<PluginWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = pathsPtr.bindMemory(to: UnsafeMutableRawPointer?.self, capacity: count)
            var touched: [String] = []
            for i in 0..<count {
                guard let raw = paths[i] else { continue }
                touched.append(String(cString: raw.assumingMemoryBound(to: CChar.self)))
            }
            watcher.ingest(paths: touched)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            [watchPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // latency (s)
            flags
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync {
            debounce?.cancel()
            debounce = nil
            pending.removeAll()
        }
    }

    /// Runs on `queue`.
    private func ingest(paths: [String]) {
        for path in paths {
            guard let prefix = rootPrefixes.first(where: { path.hasPrefix($0) }) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard let pluginName = relative.split(separator: "/").first.map(String.init),
                  !pluginName.hasPrefix(".")
            else { continue }
            pending.insert(pluginName)
        }
        guard !pending.isEmpty else { return }

        // Coalesce the burst an editor produces when saving (write temp, rename, chmod...).
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pending
            self.pending.removeAll()
            guard !batch.isEmpty else { return }
            DispatchQueue.main.async { self.onChange(batch) }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    deinit { stop() }
}
