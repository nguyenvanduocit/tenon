// @domain: plugin-events
import Foundation
import os
import TenonCore

/// Serializes `WorkspaceStore.onEvents` broadcasts to `PluginHost.emit` so a burst of firings
/// cannot fan out into overlapping calls.
///
/// `PluginHost.emit` (`PluginHost.swift`) is reentrant at its own internal
/// `await session.runtime.handles(event:)`, so when many concurrent, unawaited calls race
/// through it — as `onEvents` firing in a rapid burst used to produce, one detached `Task` per
/// firing — their loop iterations interleave and race synchronous `acceptEvent`/mailbox writes
/// into every subscribed plugin's own bounded callback pump at once, fast enough to outrun that
/// plugin's single-consumer drain and overflow it. A bundled-swift plugin generation has no
/// hot-reload path to recover from that, so it stays permanently unavailable (T-182).
///
/// Routing every broadcast through one FIFO queue with exactly one consumer removes the
/// amplification at its source instead of only hardening each plugin's receiving end:
/// `enqueue` never suspends, so `onEvents` still returns immediately, but only one broadcast is
/// ever in flight, and every plugin still observes every event, in the order it fired.
final class WorkspaceEventBroadcastPump {
    struct Item: Sendable {
        let events: [WorkspaceEvent]
        let snapshot: WorkspaceCatalog
    }

    /// Generous relative to any realistic firing rate: `PluginHost.emit` resolves one queued
    /// item in low milliseconds (a `Set.contains` check per plugin plus a synchronous mailbox
    /// write), so this backstop only engages if the drain side is genuinely stuck — a
    /// different bug, not normal workspace churn. Bounded rather than unbounded per invariant
    /// 10 ("every queue... is bounded") and to match `BundledPluginCallbackMailbox`
    /// (`BundledPluginRuntime.swift`), the sibling queue this same fix introduced today.
    private static let capacity = 1024

    private let continuation: AsyncStream<Item>.Continuation
    private let drainTask: Task<Void, Never>

    /// `@MainActor`, not `@Sendable`: `PluginHost` is main-actor-isolated and every caller in
    /// this app touches `WorkspaceStore` (itself not `Sendable`) from the main actor by
    /// convention, so the one consumer that ever calls `handle` runs there too.
    init(handle: @escaping @MainActor (Item) async -> Void) {
        let pair = AsyncStream.makeStream(
            of: Item.self,
            bufferingPolicy: .bufferingNewest(Self.capacity)
        )
        continuation = pair.continuation
        drainTask = Task { @MainActor in
            for await item in pair.stream {
                guard !Task.isCancelled else { return }
                await handle(item)
            }
        }
    }

    func enqueue(_ item: Item) {
        if case .dropped = continuation.yield(item) {
            TenonLog.diagnostics.fault(
                "WorkspaceEventBroadcastPump dropped a workspace-event broadcast — the drain side is stuck or capacity (\(Self.capacity)) was exceeded; plugins may miss the events this broadcast carried"
            )
        }
    }

    deinit {
        continuation.finish()
        drainTask.cancel()
    }
}
