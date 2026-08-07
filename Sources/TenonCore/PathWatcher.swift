// @domain: plugin-host
import CoreServices
import Foundation

struct PathWatcherPendingBuffer: Sendable {
    enum InsertResult: Sendable, Equatable {
        case inserted
        case duplicate
        case overflowed
        case alreadyOverflowed
    }

    private let capacity: Int
    private var paths: Set<String> = []
    private var overflowed = false

    init(capacity: Int) {
        precondition(capacity >= 0, "path watcher capacity must be nonnegative")
        self.capacity = capacity
    }

    var count: Int {
        paths.count
    }

    mutating func insert(_ path: String) -> InsertResult {
        guard !overflowed else { return .alreadyOverflowed }
        guard !paths.contains(path) else { return .duplicate }
        guard paths.count < capacity else {
            paths.removeAll(keepingCapacity: false)
            overflowed = true
            return .overflowed
        }
        paths.insert(path)
        return .inserted
    }

    mutating func drain() -> [String] {
        guard !overflowed else { return [] }
        let batch = paths.sorted()
        paths.removeAll(keepingCapacity: true)
        return batch
    }

    mutating func reset() {
        paths.removeAll(keepingCapacity: false)
        overflowed = false
    }
}

/// An FSEvents watch over one arbitrary path, for `tenon.fs.watch`.
///
/// The sibling of `PluginWatcher`, which watches the plugins root and reports *plugin names*.
/// This one reports the paths themselves, because a plugin watching a project directory
/// wants to know which file moved — and because the host has no idea what the plugin
/// considers a unit of change.
///
/// Deliberately separate rather than generalised: the plugins-root watcher's whole job is
/// the root → plugin-name mapping and the dot-file filtering that hot reload depends on.
public final class PathWatcher {
    static let maximumPendingPaths = 256
    private let worker: Worker

    public convenience init(
        path: URL,
        recursive: Bool,
        label: String = "tenon.path-watcher",
        onOverflow: @escaping @Sendable () -> Void = {},
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.init(
            path: path,
            recursive: recursive,
            label: label,
            pendingCapacity: Self.maximumPendingPaths,
            onOverflow: onOverflow,
            onChange: onChange
        )
    }

    init(
        path: URL,
        recursive: Bool,
        label: String,
        pendingCapacity: Int,
        onOverflow: @escaping @Sendable () -> Void,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        let declared = path.standardizedFileURL.path
        var spellings: Set<String> = [declared]
        if let resolved = realpath(declared, nil) {
            spellings.insert(String(cString: resolved))
            free(resolved)
        }
        for spelling in spellings {
            if spelling.hasPrefix("/private/") {
                spellings.insert(String(spelling.dropFirst("/private".count)))
            } else {
                spellings.insert("/private" + spelling)
            }
        }

        worker = Worker(
            watchPath: declared,
            recursive: recursive,
            prefixes: spellings.map { $0.hasSuffix("/") ? $0 : $0 + "/" },
            label: label,
            pendingCapacity: pendingCapacity,
            onOverflow: onOverflow,
            onChange: onChange
        )
    }

    @discardableResult
    public func start() -> Bool {
        worker.start()
    }

    public func stop() {
        worker.stop()
    }

    func ingestForTesting(_ paths: [String]) {
        worker.ingestForTesting(paths)
    }

    deinit {
        worker.stop()
    }

    /// Owns the FSEvents stream and every mutable debounce field. Public calls enter through
    /// `queue.sync`, and FSEvents invokes its callback on this same queue.
    private final class Worker: @unchecked Sendable {
        private let watchPath: String
        private let recursive: Bool
        private let prefixes: [String]
        private let onOverflow: @Sendable () -> Void
        private let onChange: @Sendable ([String]) -> Void
        private let queue: DispatchQueue

        private var stream: FSEventStreamRef?
        private var pending: PathWatcherPendingBuffer
        private var debounce: DispatchWorkItem?

        init(
            watchPath: String,
            recursive: Bool,
            prefixes: [String],
            label: String,
            pendingCapacity: Int,
            onOverflow: @escaping @Sendable () -> Void,
            onChange: @escaping @Sendable ([String]) -> Void
        ) {
            self.watchPath = watchPath
            self.recursive = recursive
            self.prefixes = prefixes
            self.onOverflow = onOverflow
            self.onChange = onChange
            self.queue = DispatchQueue(label: label)
            pending = PathWatcherPendingBuffer(capacity: pendingCapacity)
        }

        func start() -> Bool {
            queue.sync {
                startOnQueue()
            }
        }

        func stop() {
            queue.sync {
                stopOnQueue()
            }
        }

        func ingestForTesting(_ paths: [String]) {
            queue.async { [weak self] in
                self?.ingest(paths: paths)
            }
        }

        private func startOnQueue() -> Bool {
            dispatchPrecondition(condition: .onQueue(queue))
            guard stream == nil else { return true }

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

            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [watchPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.1,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            ) else { return false }

            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
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
            pending.reset()
        }

        private func ingest(paths: [String]) {
            dispatchPrecondition(condition: .onQueue(queue))
            for path in paths {
                guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                guard recursive || !relative.contains("/") else { continue }
                switch pending.insert(path) {
                case .inserted, .duplicate, .alreadyOverflowed:
                    break
                case .overflowed:
                    debounce?.cancel()
                    debounce = nil
                    onOverflow()
                    return
                }
            }
            guard pending.count > 0 else { return }

            debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let batch = self.pending.drain()
                guard !batch.isEmpty else { return }
                self.onChange(batch)
            }
            debounce = work
            queue.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
}
