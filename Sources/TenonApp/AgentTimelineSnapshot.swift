// @domain: agent-lens
import AppKit
import SwiftUI
import TenonCore

/// Dev-only offscreen snapshots of the Timeline account, so its layout can be SEEN on a
/// headless machine rather than inferred from a passing test.
///
///     TENON_TIMELINE_SNAPSHOT=/tmp/timeline.png swift run tenon
///     TENON_TIMELINE_SNAPSHOT_SIZE=380x620 TENON_TIMELINE_SNAPSHOT=/tmp/narrow.png swift run tenon
///     TENON_TIMELINE_SNAPSHOT_STATE=running swift run tenon
///
/// A test proves a view tree has the right *shape* and says nothing about its geometry —
/// `docs/design-plugin-views.md` records a board that passed 24 tests and rendered as cards
/// floating at different heights. So the reading here is produced through the REAL loop: a
/// scripted synthesizer's reply goes through the real decoder and the real validator, and what
/// is photographed is whatever survived them.
enum AgentTimelineSnapshot {
    @MainActor
    static func renderIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TENON_TIMELINE_SNAPSHOT"], !path.isEmpty else { return }
        render(
            to: path,
            state: env["TENON_TIMELINE_SNAPSHOT_STATE"] ?? "ready",
            size: size(env["TENON_TIMELINE_SNAPSHOT_SIZE"])
        )
    }

    @MainActor
    private static func render(to path: String, state: String, size: CGSize) -> Never {
        _ = NSApplication.shared
        let session = sampleSession()
        let terminalPool = SurfacePool(backendName: "Timeline snapshot") { _, _ in
            StubTerminalSurface()
        }
        let model = AgentLensViewModel(
            slotID: UUID(),
            terminalPool: terminalPool,
            discovery: AgentLensDiscovery(),
            resolveTimelineSynthesizer: { _ in SnapshotSynthesizer(state: state) }
        )
        model.account = .timeline
        model.receive(state == "insufficient" ? shortSession() : session)

        // The reader list is a filesystem answer the live pane gets from `.task`, and an offscreen
        // render never runs one — so it is asked for here, and the invitation is photographed with
        // the readers this machine actually has. Capped, because a machine with no agent CLI
        // installed would otherwise wait on a list that is legitimately empty.
        let scan = Task { await model.loadAvailableReaders() }
        let scanDeadline = Date(timeIntervalSinceNow: 3)
        while model.availableReaders.isEmpty, Date() < scanDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        scan.cancel()

        // `insufficient` is drawn from the snapshot, not from a generation, so asking for a
        // reading there would be asking the account to refuse one — the picture is the same
        // either way, and this says which state is being photographed.
        if state != "idle", state != "insufficient" {
            model.generateTimeline()
            // `running` is photographed mid-flight, once the run has said something about
            // itself — a picture taken before the first report would show the launching state
            // that lasts a fraction of the reading. Every other state is photographed after the
            // real validator has had its say.
            let deadline = Date(timeIntervalSinceNow: 10)
            while Date() < deadline {
                if state == "running" {
                    guard case .running(_, .launching) = model.timelineGeneration else { break }
                } else if !model.timelineGeneration.isRunning {
                    break
                }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }

        let slot = WorkspaceSlot(
            id: model.slotID,
            rect: GridRect(x: 0, y: 0, width: 12, height: 12),
            content: .terminal
        )
        let headers = PaneHeaderStore()
        headers.publish(
            AgentLensPaneHeader.header(
                isAgentDetected: true,
                provider: .claude,
                status: session.status,
                currentAction: session.currentActionSummary,
                hasDiagnostics: false,
                presentation: .session,
                showsInspector: false,
                account: .timeline
            ),
            for: slot.id
        )

        withExtendedLifetime(terminalPool) {
            PaneViewSnapshotWriter.write(
                AgentSessionTimelineView(
                    model: model,
                    returnToEvidence: { _ in },
                    startsExpanded: ProcessInfo.processInfo.environment["TENON_TIMELINE_SNAPSHOT_EVIDENCE"] == "1"
                ),
                slot: slot,
                title: "claude — tenon",
                headerStore: headers,
                size: size,
                to: path
            )
        }
    }

    private static func size(_ value: String?) -> CGSize {
        guard let parts = value?.split(separator: "x"), parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else {
            return CGSize(width: 900, height: 620)
        }
        return CGSize(width: width, height: height)
    }

    // MARK: - A session worth looking at  @domain: agent-lens

    private static func evidence(_ id: String, at seconds: TimeInterval) -> AgentEvidence {
        AgentEvidence(
            source: .transcript,
            authority: .reported,
            location: "session.jsonl#\(id)",
            byteOffset: UInt64(seconds),
            fingerprint: "snapshot-\(id)",
            capturedAt: Date(timeIntervalSince1970: 1_760_000_000 + seconds),
            freshness: .current
        )
    }

    private static func shortSession() -> AgentLensSnapshot {
        var snapshot = AgentLensSnapshot.empty
        snapshot.provider = .claude
        snapshot.status = .running
        snapshot.messages = [
            AgentLensMessage(
                id: "u0",
                role: .user,
                text: "Fix the pane focus loop",
                isStreaming: false,
                evidence: evidence("u0", at: 0)
            ),
        ]
        return snapshot
    }

    private static func sampleSession() -> AgentLensSnapshot {
        var snapshot = AgentLensSnapshot.empty
        snapshot.provider = .claude
        snapshot.status = .running

        let turns: [(String, AgentMessageRole, String)] = [
            ("u0", .user, "New panes keep stealing focus back and forth. Find out why."),
            ("a0", .assistant, "I'll reproduce it headlessly before changing anything."),
            ("u1", .user, "Yes — and I want the repro in the suite, not in a screenshot."),
            ("a1", .assistant, "Reproduced: the model→responder and responder→model edges form a cycle with no fixed point."),
            ("u2", .user, "So who should own focus?"),
            ("a2", .assistant, "One routing type owns both edges. Three rules, each proved load-bearing by mutation."),
            ("a3", .assistant, "Suite is green at 1510 and the oscillation test fails without any one of the three rules."),
        ]
        for (index, turn) in turns.enumerated() {
            snapshot.messages.append(
                AgentLensMessage(
                    id: turn.0,
                    role: turn.1,
                    text: turn.2,
                    isStreaming: false,
                    evidence: evidence(turn.0, at: TimeInterval(index * 90))
                )
            )
        }

        let runs: [(String, String, AgentToolState, Int?)] = [
            ("t0", "rg 'becomeFirstResponder' Sources/TenonApp", .succeeded, 0),
            ("t1", "swift test --filter PaneFocusTests", .failed, 1),
            ("t2", "swift test --filter PaneFocusRoutingTests", .succeeded, 0),
            ("t3", "swift build", .succeeded, 0),
            ("t4", "swift test", .running, nil),
        ]
        for (index, run) in runs.enumerated() {
            snapshot.tools.append(
                AgentToolRun(
                    id: run.0,
                    name: "Bash",
                    kind: .command,
                    summary: run.1,
                    detail: "",
                    state: run.2,
                    exitCode: run.3,
                    evidence: evidence(run.0, at: TimeInterval(index * 90 + 30))
                )
            )
        }
        return snapshot
    }

    /// Replies the way the real CLI does — with text the host still has to decode and validate.
    private struct SnapshotSynthesizer: AgentTimelineSynthesizer {
        let state: String

        func synthesize(
            _ digest: AgentTimelineDigest,
            options: AgentReadingOptions,
            progress: @escaping @Sendable (AgentTimelineProgress) -> Void
        ) async throws -> String {
            switch state {
            case "failed":
                return "I wasn't able to read that session."
            case "running":
                // The photographed state is a run mid-reply, since that is what a person
                // actually watches for most of a reading.
                progress(.writing(characters: 512))
                try await Task.sleep(for: .seconds(600))
                return ""
            default:
                return reading(digest)
            }
        }

        private func reading(_ digest: AgentTimelineDigest) -> String {
            // Work that has not finished is held out and given to the one milestone that says
            // so. The first version of this fixture sliced blindly and put the still-running
            // `swift test` inside a `settled` milestone — the validator refused the whole
            // reading, which is how this comment came to exist.
            let open = digest.facts.filter(\.isUnsettled).map(\.id)
            let ids = digest.facts.filter { !$0.isUnsettled }.map(\.id)
            let groups: [(String, String, String, String, ArraySlice<String>)] = [
                (
                    "Reproduced the focus oscillation",
                    "The loop was driven from a cold start in a headless test instead of from a screen recording.",
                    "Until it reproduced, the report was a description of a symptom rather than something a fix could be measured against.",
                    "settled",
                    ids.prefix(4)
                ),
                (
                    "Found the two competing focus writers",
                    "The model→responder and responder→model edges were each correct alone and formed a cycle with no fixed point together.",
                    "This is why every earlier patch moved the oscillation instead of ending it.",
                    "settled",
                    ids.dropFirst(4).prefix(3)
                ),
                (
                    "Moved ownership into one routing type",
                    "PaneFocusRouting now owns both edges, and each of its three rules was proved load-bearing by mutation.",
                    "A single owner is what gives the cycle a fixed point; the mutation pass is what stops the rules rotting.",
                    "settled",
                    ids.dropFirst(7)
                ),
                (
                    "Verifying the whole suite",
                    "A full run is in flight after the focused suites went green.",
                    "The focused suites prove the rule; only the full run proves nothing else depended on the old behaviour.",
                    "inProgress",
                    open[...]
                ),
            ]
            let body = groups
                .filter { !$0.4.isEmpty }
                .map { group in
                    let anchors = group.4.map { "\"\($0)\"" }.joined(separator: ",")
                    return """
                    {"title":"\(group.0)","whatChanged":"\(group.1)",\
                    "whyItMattered":"\(group.2)","outcome":"\(group.3)","anchors":[\(anchors)]}
                    """
                }
            return "{\"milestones\":[\(body.joined(separator: ","))]}"
        }
    }
}
