// @domain: diagnostics

import Darwin
import Foundation
import TenonCore

/// Watches the main runloop from outside it, and writes down what it sees.
///
/// The arrangement that matters: the **beat** is a `CFRunLoopObserver` on the main runloop,
/// and the **probe** is a timer on a private queue. A probe scheduled on the main queue would
/// be wedged by exactly the condition it exists to detect — during the T-091 hang the main
/// thread never returned from one observer call, so anything queued behind it waited two
/// hours with it. The watchdog has to live somewhere the stall cannot reach.
///
/// The judgement itself is `RunloopHealth`, which is pure and tested without a window. This
/// type owns only the clock, the threads, and the writing down.
final class DiagnosticsRuntime: @unchecked Sendable {
    private let journal: DiagnosticsJournal
    private let now: @Sendable () -> TimeInterval
    private let footprintBytes: @Sendable () -> UInt64
    /// Takes the stack sample. Injected so the capture policy can be tested without spawning
    /// anything, and so a test never samples the test runner.
    private let captureSample: @Sendable (URL) -> Void

    private let lock = NSLock()
    private var health: RunloopHealth

    private var observer: CFRunLoopObserver?
    private var probeTimer: DispatchSourceTimer?
    private let probeQueue = DispatchQueue(label: "com.firegroup.tenon.diagnostics.watchdog")

    /// How often the watchdog looks. Frequent enough that a stall is noticed while it is
    /// still worth sampling, rare enough to cost nothing.
    private let probeInterval: TimeInterval

    init(
        journal: DiagnosticsJournal,
        threshold: TimeInterval = 5,
        escalationInterval: TimeInterval = 60,
        probeInterval: TimeInterval = 1,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        footprintBytes: @escaping @Sendable () -> UInt64 = DiagnosticsRuntime.physicalFootprint,
        captureSample: @escaping @Sendable (URL) -> Void = DiagnosticsRuntime.sampleThisProcess
    ) {
        self.journal = journal
        self.now = now
        self.footprintBytes = footprintBytes
        self.captureSample = captureSample
        self.probeInterval = probeInterval
        self.health = RunloopHealth(
            threshold: threshold,
            escalationInterval: escalationInterval,
            startedAt: now()
        )
    }

    deinit {
        probeTimer?.cancel()
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    // MARK: - Lifetime  @domain: diagnostics

    /// Begin watching. Records that the app started, so a journal whose newest entry is a
    /// launch tells you the last session ended without ever recovering.
    @MainActor
    func start() {
        installObserver()
        startProbe()
        write(kind: "launch", message: "diagnostics started")
    }

    func stop() {
        probeTimer?.cancel()
        probeTimer = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
    }

    @MainActor
    private func installObserver() {
        guard observer == nil else { return }
        // Every activity counts as a beat: the claim under test is only "the runloop is still
        // turning", and any phase firing proves it.
        let activities: CFRunLoopActivity = [
            .entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit,
        ]
        let created = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities.rawValue,
            true,
            // Order matters: a large value puts this observer late in the phase, so a
            // framework observer that never returns stops the beat rather than being masked
            // by ours running first. That is the T-091 shape exactly.
            .max
        ) { [weak self] _, _ in
            self?.beat()
        }
        guard let created else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
    }

    /// Start only the watchdog, without touching the main runloop. Separate from `start()`
    /// because the probe is the half that must work when the main runloop does not — a caller
    /// that wants to observe that property has to be able to run it alone.
    func startProbe() {
        guard probeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + probeInterval, repeating: probeInterval)
        timer.setEventHandler { [weak self] in
            self?.probeOnce()
        }
        timer.resume()
        probeTimer = timer
    }

    // MARK: - The two signals  @domain: diagnostics

    /// The main runloop completed a turn.
    func beat() {
        lock.lock()
        let event = health.beat(at: now())
        lock.unlock()
        if let event { record(event) }
    }

    /// The watchdog looked. Exposed so a test can drive it without waiting on a timer.
    func probeOnce() {
        lock.lock()
        let event = health.probe(at: now())
        lock.unlock()
        if let event { record(event) }
    }

    // MARK: - Writing it down  @domain: diagnostics

    private func record(_ event: RunloopHealth.Event) {
        switch event {
        case let .stalled(duration):
            write(
                kind: "stall",
                message: "main runloop stopped completing turns",
                seconds: duration
            )
            TenonLog.diagnostics.error(
                "main runloop stalled for \(duration, format: .fixed(precision: 1))s"
            )
            captureFirstStallSample()
        case let .stillStalled(duration):
            write(kind: "stall-continues", message: "main runloop still stalled", seconds: duration)
            TenonLog.diagnostics.error(
                "main runloop still stalled after \(duration, format: .fixed(precision: 0))s"
            )
        case let .recovered(stallDuration):
            write(
                kind: "recovered",
                message: "main runloop resumed",
                seconds: stallDuration
            )
            TenonLog.diagnostics.notice(
                "main runloop recovered after \(stallDuration, format: .fixed(precision: 1))s"
            )
        }
    }

    /// Samples the process the first time a stall is seen, and only then.
    ///
    /// This is the piece T-091 could not get: the only sample of that hang was taken by hand
    /// two hours in, after 10.4 GB had swapped, when every turn was slow for reasons that had
    /// nothing to do with the cause. A sample taken five seconds into the stall shows the
    /// cycle while it is still just a cycle. Once per stall — a spin lasting two hours must not
    /// spend those hours writing samples.
    private func captureFirstStallSample() {
        let destination = journal.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("stall-sample.txt")
        let capture = captureSample
        // Off the main queue on purpose: the main thread is precisely what is wedged.
        probeQueue.async { capture(destination) }
        write(kind: "stall-sample", message: "sampling the process at \(destination.path)")
    }

    /// `/usr/bin/sample` against our own pid. It reads the target's threads from outside, so
    /// it works while the main thread is inside a call that will never return — which is the
    /// only condition under which it is ever run.
    static let sampleThisProcess: @Sendable (URL) -> Void = { destination in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            "3",
            "-file", destination.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func write(kind: String, message: String, seconds: TimeInterval? = nil) {
        var figures = ["footprintMB": "\(footprintBytes() / 1_048_576)"]
        if let seconds {
            figures["seconds"] = String(format: "%.1f", seconds)
        }
        journal.append(
            DiagnosticsRecord(at: Date(), kind: kind, message: message, figures: figures)
        )
    }

    // MARK: - Process figures  @domain: diagnostics

    /// The number that told the T-091 story: 11.0 GB of physical footprint, which is what
    /// `heap` and `vmmap` report and what Activity Monitor calls Memory. `ru_maxrss` and
    /// resident size both understate it once memory is compressed or swapped — during that
    /// hang `ps` showed 232 MB resident while the real footprint was 11 GB.
    static let physicalFootprint: @Sendable () -> UInt64 = {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}
