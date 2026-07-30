import CoreServices
import Foundation

/// Recursive FSEvents watch over the plugins root.
///
/// Reports *plugin names* (the directory component directly under the root), not raw paths,
/// so the host never has to think about editor temp files or atomic-rename dances.
public final class PluginWatcher {
    private let worker: Worker

    /// - Parameter onChange: called on the **main queue** with the set of plugin names touched.
    public init(root: URL, onChange: @escaping @MainActor (Set<String>) -> Void) {
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

        worker = Worker(
            watchPath: spellings.contains(declared) ? declared : (spellings.first ?? declared),
            rootPrefixes: spellings.map { $0.hasSuffix("/") ? $0 : $0 + "/" },
            onChange: onChange
        )
    }

    public func start() {
        worker.start()
    }

    public func stop() {
        worker.stop()
    }

    deinit {
        worker.stop()
    }

    /// Queue-confined FSEvents owner. Only the collected plugin-name value crosses from this
    /// queue to `MainActor`; stream lifetime and debounce state never leave the queue.
    private final class Worker {
        private let watchPath: String
        private let rootPrefixes: [String]
        private let onChange: @MainActor (Set<String>) -> Void
        private let queue = DispatchQueue(label: "tenon.plugin-watcher")

        private var stream: FSEventStreamRef?
        private var pending: Set<String> = []
        private var debounce: DispatchWorkItem?

        init(
            watchPath: String,
            rootPrefixes: [String],
            onChange: @escaping @MainActor (Set<String>) -> Void
        ) {
            self.watchPath = watchPath
            self.rootPrefixes = rootPrefixes
            self.onChange = onChange
        }

        func start() {
            queue.sync {
                startOnQueue()
            }
        }

        func stop() {
            queue.sync {
                stopOnQueue()
            }
        }

        private func startOnQueue() {
            dispatchPrecondition(condition: .onQueue(queue))
            guard stream == nil else { return }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let callback: FSEventStreamCallback = { _, info, count, pathsPointer, _, _ in
                guard let info else { return }
                let worker = Unmanaged<Worker>.fromOpaque(info).takeUnretainedValue()
                let paths = pathsPointer.bindMemory(to: UnsafeMutableRawPointer?.self, capacity: count)
                var touched: [String] = []
                for index in 0..<count {
                    guard let raw = paths[index] else { continue }
                    touched.append(String(cString: raw.assumingMemoryBound(to: CChar.self)))
                }
                worker.ingest(paths: touched)
            }

            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )

            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [watchPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.1,
                flags
            ) else { return }

            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
        }

        private func stopOnQueue() {
            dispatchPrecondition(condition: .onQueue(queue))
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            debounce?.cancel()
            debounce = nil
            pending.removeAll()
        }

        private func ingest(paths: [String]) {
            dispatchPrecondition(condition: .onQueue(queue))
            for path in paths {
                guard let prefix = rootPrefixes.first(where: { path.hasPrefix($0) }) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                guard let pluginName = relative.split(separator: "/").first.map(String.init),
                      !pluginName.hasPrefix(".")
                else { continue }
                pending.insert(pluginName)
            }
            guard !pending.isEmpty else { return }

            debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let batch = self.pending
                self.pending.removeAll()
                guard !batch.isEmpty else { return }
                let onChange = self.onChange
                Task { @MainActor in
                    onChange(batch)
                }
            }
            debounce = work
            queue.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
}
