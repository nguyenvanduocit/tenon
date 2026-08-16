import Foundation
@testable import TenonApp
import TenonCore
import XCTest

/// T-089 — the Timeline account.
///
/// Every rule that decides whether a person is looking at a reading of their session or at an
/// invention is asserted here, without a window and without a model call. The synthesizer is a
/// seam precisely so the interesting half — what the host will and will not believe — is
/// testable at full speed.
final class AgentSessionTimelineTests: XCTestCase {
    // MARK: - The evidence a synthesis is allowed to see

    /// Chat folds execution so it stays readable. A milestone about "found the competing
    /// writers" still stands on the original run, so every digest anchor must resolve through
    /// the fold — while the session's setting remains context rather than something that happened.
    func testTheDigestCarriesExecutionAndDropsTheSessionsSetting() throws {
        let snapshot = Fixture.session()
        let digest = try XCTUnwrap(Fixture.digest(snapshot))

        XCTAssertGreaterThan(
            digest.facts.filter { $0.kind == .toolRun }.count,
            0,
            "a reading with no execution in it can only summarize the conversation"
        )
        XCTAssertFalse(
            digest.facts.contains { $0.body.contains("System policy") },
            "instructions are the session's setting, not an event in it"
        )
        let readModel = snapshot.readModel
        XCTAssertTrue(
            digest.facts.allSatisfy { readModel.conversationAnchor(forFactID: $0.id) != nil },
            "every original digest fact has a return path through the quiet Chat projection"
        )
    }

    /// An empty, a short and an unattached session each say what they are. None of them offers a
    /// button that would spend a model call to rediscover it.
    func testAShortEmptyOrUnattachedSessionRefusesToBeSynthesized() {
        XCTAssertEqual(
            AgentTimelineDigest.build(from: .empty).failure,
            .noSession
        )

        var attachedButEmpty = AgentLensSnapshot.empty
        attachedButEmpty.provider = .claude
        XCTAssertEqual(AgentTimelineDigest.build(from: attachedButEmpty).failure, .empty)

        let short = Fixture.session(userTurns: 1, toolRuns: 1)
        XCTAssertEqual(
            AgentTimelineDigest.build(from: short).failure,
            .tooShort(facts: 3, needed: AgentTimelineBounds.minimumFactsForSynthesis)
        )
    }

    /// The cheap answer the account draws with and the full one a run is built from are two
    /// readings of one rule, so a test stands over the seam between them.
    func testTheTwoSufficiencyAnswersNeverDisagree() {
        var attachedButEmpty = AgentLensSnapshot.empty
        attachedButEmpty.provider = .claude

        var streamingHead = Fixture.session(userTurns: 6, toolRuns: 6)
        streamingHead.status = .running

        let snapshots: [AgentLensSnapshot] = [
            .empty,
            attachedButEmpty,
            Fixture.session(userTurns: 1, toolRuns: 0),
            Fixture.session(userTurns: 1, toolRuns: 1),
            Fixture.session(userTurns: 2, toolRuns: 1),
            Fixture.session(userTurns: 3, toolRuns: 4),
            Fixture.session(userTurns: 3, toolRuns: 4, runningTool: true),
            streamingHead,
            Fixture.session(userTurns: 40, toolRuns: 40),
        ]

        for (index, snapshot) in snapshots.enumerated() {
            XCTAssertEqual(
                AgentTimelineDigest.insufficiency(of: snapshot),
                AgentTimelineDigest.build(from: snapshot).failure,
                """
                snapshot \(index): the account would draw one verdict and a run would reach \
                another
                """
            )
        }
    }

    /// The defect T-102 was opened for: a pane that met Timeline while its session was still
    /// arriving kept saying so afterwards. The verdict has to follow the snapshot, and the only
    /// thing that may survive a growing session is a reading someone asked for.
    @MainActor
    func testAnUnreadableSessionBecomesReadableAsItGrows() {
        let model = Fixture.model(synthesizer: Fixture.FailingSynthesizer())
        XCTAssertEqual(AgentTimelineDigest.insufficiency(of: model.snapshot), .noSession)

        model.receive(Fixture.session(userTurns: 1, toolRuns: 1))
        XCTAssertEqual(
            AgentTimelineDigest.insufficiency(of: model.snapshot),
            .tooShort(facts: 3, needed: AgentTimelineBounds.minimumFactsForSynthesis)
        )

        model.receive(Fixture.session(userTurns: 3, toolRuns: 4))
        XCTAssertNil(
            AgentTimelineDigest.insufficiency(of: model.snapshot),
            "the session grew past the bar and the account still called it unreadable"
        )
        XCTAssertEqual(
            model.timelineGeneration,
            .idle,
            "growing a session is not a request to read it"
        )
    }

    /// `AL-FR-025` after the verdict stopped being a state: a session with nothing to read still
    /// costs no model call, and now it costs one nowhere rather than reporting that it did not.
    @MainActor
    func testAnUnreadableSessionSpendsNoModelCall() {
        let synthesizer = Fixture.FailingSynthesizer()
        let model = Fixture.model(synthesizer: synthesizer)

        model.generateTimeline()

        XCTAssertEqual(model.timelineGeneration, .idle)
        XCTAssertFalse(model.timelineGeneration.isRunning)
    }

    /// The prompt is prose and never compiles, so nothing but a test notices when it stops asking
    /// for the shape the validator enforces.
    func testTheInstructionStatesTheBoundsTheValidatorActuallyHolds() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session(runningTool: true)))
        let prompt = AgentTimelinePrompt.text(for: digest)

        XCTAssertTrue(prompt.contains("\(AgentTimelineBounds.maximumTitleLength) characters"))
        XCTAssertTrue(prompt.contains("\(AgentTimelineBounds.maximumProseLength) characters"))
        for outcome in AgentMilestoneOutcome.allCases {
            XCTAssertTrue(prompt.contains(outcome.rawValue), "the prompt omits \(outcome.rawValue)")
        }
        for number in 1...digest.facts.count {
            XCTAssertTrue(prompt.contains("[\(number)]"), "fact \(number) is not citable from the prompt")
        }
        XCTAssertFalse(
            prompt.contains(digest.facts[0].id),
            """
            A reading names a stretch of the session, not identifiers. Putting the ids back in \
            the prompt is what invited the model to transcribe them, and one bad transcription \
            is what discarded a whole 277 s reading on 2026-08-16.
            """
        )
        XCTAssertTrue(
            prompt.contains("\(AgentTimelineBounds.minimumFactsPerMilestone) facts"),
            "the compression bar the validator holds is not stated to the model"
        )
        XCTAssertTrue(
            prompt.contains("OPEN"),
            "a still-running fact must be marked, or the model cannot avoid the one claim the host refuses"
        )
    }

    // MARK: - Grouping, which is the whole product claim

    func testAGroupedReadingValidatesAndKeepsItsEvidence() throws {
        let snapshot = Fixture.session()
        let digest = try XCTUnwrap(Fixture.digest(snapshot))

        let draft = AgentTimelineDraft(milestones: [
            .init(
                title: "Reproduced the failing pane",
                whatChanged: "The pane's focus loop was reproduced from a cold start.",
                whyItMattered: "Until then the report was a description, not a repro.",
                outcome: "settled",
                from: 1,
                through: 3
            ),
            .init(
                title: "Changed the ownership rule",
                whatChanged: "One routing type now owns both focus edges.",
                whyItMattered: "Two writers with no fixed point was the defect itself.",
                outcome: "settled",
                from: 4,
                through: 6
            ),
        ])

        let timeline = try Fixture.validated(draft, digest)
        XCTAssertEqual(timeline.milestones.count, 2)
        XCTAssertEqual(timeline.factCount, digest.facts.count)
        XCTAssertEqual(timeline.evidenceFingerprint, digest.fingerprint)
        for milestone in timeline.milestones {
            XCTAssertGreaterThan(
                milestone.factCount,
                1,
                "a milestone standing on one fact is that fact wearing a heading"
            )
        }
    }

    /// **The anti-relabelling gate.** A transcript re-emitted one row per fact is the thing this
    /// feature exists NOT to be, and it is refused structurally rather than by review.
    func testATranscriptRenderedAsARawEventListIsNotATimeline() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session(userTurns: 8, toolRuns: 8)))
        let draft = AgentTimelineDraft(
            milestones: zip(1..., digest.facts).map { number, fact in
                .init(
                    title: "Step \(number)",
                    whatChanged: fact.title,
                    whyItMattered: "It happened.",
                    outcome: "settled",
                    from: number,
                    through: number
                )
            }
        )

        XCTAssertEqual(
            Fixture.rejection(draft, digest),
            .tooManyMilestones(
                count: digest.facts.count,
                limit: AgentTimelineBounds.maximumMilestones
            )
        )

        // And the same shape at a length the milestone ceiling alone would let through: the
        // compression bar is what makes the rule hold for a session of any size. It is stated per
        // milestone now, because a span carries its own size and a ratio over the whole reading
        // could be met by one wide milestone paying for eight narrow ones.
        let narrow = AgentTimelineDraft(
            milestones: zip(1..., digest.facts.prefix(9)).map { number, fact in
                .init(
                    title: "Step \(number)",
                    whatChanged: fact.title,
                    whyItMattered: "It happened.",
                    outcome: "settled",
                    from: number,
                    through: number
                )
            }
        )
        XCTAssertEqual(
            Fixture.rejection(narrow, digest),
            .notCompression(milestone: "Step 1", facts: 1),
            "one row per fact passed the compression gate"
        )
    }

    /// Grouping is a partition. Two milestones claiming the same run is double counting, and it
    /// is how a "reading" quietly grows back to the length of the transcript.
    func testOneFactBelongsToOneMilestone() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session()))
        let draft = AgentTimelineDraft(milestones: [
            Fixture.milestone(title: "First pass", from: 1, through: 3),
            Fixture.milestone(title: "Second pass", from: 1, through: 3),
        ])

        XCTAssertEqual(
            Fixture.rejection(draft, digest),
            .sharedAnchor(factID: digest.facts[0].id)
        )
    }

    /// The bound a real session actually runs into.
    ///
    /// Measured 2026-08-16 on three real transcripts of 215 to 320 facts: the phases a reading
    /// picked out covered **28 to 43 facts each**, 13–15% of the digest. The old ceiling of 24 was
    /// sized for how many CITATIONS a person can read in one disclosure, and a span is not a
    /// citation list — so every one of those three readings was refused for describing the session
    /// accurately. What the bound is really protecting is that a reading is more than one
    /// milestone, and that is what it says now.
    func testAMilestoneMayCoverAWholePhaseButNeverHalfTheSession() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session(userTurns: 40, toolRuns: 40)))
        let half = digest.facts.count / 2

        let phase = AgentTimelineDraft(milestones: [
            Fixture.milestone(title: "Wrote the site", from: 1, through: 30),
            Fixture.milestone(title: "Verified it rendered", from: 31, through: 60),
        ])
        XCTAssertEqual(
            try Fixture.validated(phase, digest).milestones.count,
            2,
            "a thirty-fact phase is what real work looks like, not a section"
        )

        let wholeSession = AgentTimelineDraft(milestones: [
            Fixture.milestone(title: "The session", from: 1, through: half + 1),
        ])
        XCTAssertEqual(
            Fixture.rejection(wholeSession, digest),
            .oversizedSpan(milestone: "The session", facts: half + 1, limit: half),
            "one milestone over more than half the evidence is the whole session wearing a heading"
        )
    }

    /// Overlap is refused wherever it falls, including a span that merely reaches back into the
    /// one before it — the partition is what stops a milestone borrowing its neighbour's evidence
    /// to look better supported than it is.
    func testASpanThatReachesIntoItsNeighbourIsRefused() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session(userTurns: 5, toolRuns: 5)))
        let draft = AgentTimelineDraft(milestones: [
            Fixture.milestone(title: "First pass", from: 1, through: 4),
            Fixture.milestone(title: "Second pass", from: 4, through: 7),
        ])

        XCTAssertEqual(
            Fixture.rejection(draft, digest),
            .sharedAnchor(factID: digest.facts[3].id)
        )
    }

    /// Milestones written out of order are read in the order they happened rather than refused.
    /// The writing order carries no claim, so refusing it would throw away a correct reading over
    /// presentation — and the partition is still checked, in time order, afterwards.
    func testMilestonesWrittenOutOfOrderAreReadOldestFirst() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session(userTurns: 5, toolRuns: 5)))
        let draft = AgentTimelineDraft(milestones: [
            Fixture.milestone(title: "Later work", from: 5, through: 8),
            Fixture.milestone(title: "Earlier work", from: 1, through: 4),
        ])

        let timeline = try Fixture.validated(draft, digest)
        XCTAssertEqual(timeline.milestones.map(\.title), ["Earlier work", "Later work"])
    }

    /// A milestone standing on one row used to be caught by a title check — the title being that
    /// row's own opening words. A span of at least three facts cannot be one row at all, so the
    /// rule is now a property of the shape rather than a refusal the reading has to survive.
    func testAMilestoneCannotStandOnASingleRow() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session()))
        let fact = try XCTUnwrap(digest.facts.first { $0.kind == .userMessage })
        let index = try XCTUnwrap(digest.facts.firstIndex(where: { $0.id == fact.id })) + 1
        let draft = AgentTimelineDraft(milestones: [
            Fixture.milestone(title: fact.body, from: index, through: index),
        ])

        XCTAssertEqual(
            Fixture.rejection(draft, digest),
            .notCompression(milestone: fact.body, facts: 1)
        )
    }

    // MARK: - Evidence anchors

    /// The model chooses WHICH facts a milestone stands on. What those facts say, and when they
    /// happened, stay the transcript's answer — otherwise a citation could describe evidence
    /// that does not say that, which is the failure evidence-linking exists to prevent.
    func testAnchorLabelsAndSpansAreHostWrittenNotModelWritten() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session(userTurns: 5, toolRuns: 5)))
        // Deliberately from the MIDDLE of the session. Anchoring to the head would make the
        // milestone's own span coincide with the digest's, and a span quietly widened to the
        // whole session would then be indistinguishable from a correct one.
        let anchored = Array(digest.facts.dropFirst(3).prefix(4))
        let draft = AgentTimelineDraft(milestones: [
            Fixture.milestone(title: "Landed the rule", from: 4, through: 7),
        ])

        let milestone = try XCTUnwrap(Fixture.validated(draft, digest).milestones.first)
        XCTAssertEqual(milestone.anchors.map(\.factID), anchored.map(\.id))
        for (anchor, fact) in zip(milestone.anchors, anchored) {
            XCTAssertEqual(anchor.label, fact.anchorLabel)
            XCTAssertEqual(anchor.location, fact.location)
        }
        XCTAssertEqual(milestone.startedAt, anchored.map(\.occurredAt).min())
        XCTAssertEqual(milestone.endedAt, anchored.map(\.occurredAt).max())
        XCTAssertGreaterThan(
            milestone.startedAt,
            digest.firstFactAt,
            "a milestone covering the middle of a session claimed the whole session's span"
        )
        XCTAssertLessThan(milestone.endedAt, digest.lastFactAt)
    }

    /// A citation that goes nowhere is the most dangerous output this feature can produce: a
    /// return path to nothing reads exactly like one that goes somewhere. It used to be refused;
    /// it is now unspeakable, and this is the test that keeps it that way.
    ///
    /// Measured 2026-08-16, against the reading this change was opened on: a model asked to copy
    /// ~90 forty-four-character ids returned `message-c9f48eda-83a9-4b4d-b8f9-none`, a true
    /// prefix with an invented tail, and 277 seconds of otherwise usable work were thrown away.
    /// A number outside the evidence is held inside it instead, because unlike a misspelt id, a
    /// clamped index still names a fact this session contains.
    func testASpanOutsideTheEvidenceIsHeldInsideItRatherThanInventingAFact() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session()))
        let last = digest.facts.count
        let draft = AgentTimelineDraft(milestones: [
            Fixture.milestone(title: "Started before the session did", from: -400, through: 4),
            Fixture.milestone(title: "Ran past the end of it", from: last - 3, through: 9_000),
        ])

        let milestones = try Fixture.validated(draft, digest).milestones
        XCTAssertEqual(
            milestones.first?.anchors.map(\.factID),
            digest.facts.prefix(4).map(\.id),
            "a span reaching back before the evidence has to start at its first fact"
        )
        XCTAssertEqual(
            milestones.last?.anchors.map(\.factID),
            digest.facts.suffix(4).map(\.id),
            "a span reaching past the evidence has to stop at its last fact"
        )
    }

    /// Every anchor a validated timeline carries resolves to something the pane can actually
    /// show — including the completed tool runs Chat drops, whose return path is the inspector.
    @MainActor
    func testEveryAnchorResolvesToAnInspectableFact() throws {
        let snapshot = Fixture.session()
        let digest = try XCTUnwrap(Fixture.digest(snapshot))
        let draft = AgentTimelineDraft(milestones: [
            Fixture.milestone(
                title: "Read the tree and changed it",
                from: 1,
                through: 4
            ),
        ])
        let timeline = try Fixture.validated(draft, digest)

        let items = Dictionary(
            uniqueKeysWithValues: snapshot.timelineItems.map { ($0.id, $0) }
        )
        for anchor in try XCTUnwrap(timeline.milestones.first).anchors {
            let item = try XCTUnwrap(items[anchor.factID], "\(anchor.factID) left the session")
            XCTAssertNotNil(
                AgentLensInspection(fact: item),
                "\(anchor.factID) has no evidence a person can open"
            )
        }
    }

    // MARK: - Honest states

    /// The one completion claim the host can check, and does. A milestone cannot be `settled`
    /// over a tool that is still running or a question still waiting — the pane can see both.
    func testAMilestoneCannotSettleWorkTheHostSeesIsStillOpen() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session(runningTool: true)))
        let openIndex = try XCTUnwrap(digest.facts.firstIndex(where: \.isUnsettled))
        let open = digest.facts[openIndex]
        // A span reaching the open fact from far enough back to clear the compression bar, so the
        // refusal is about the claim rather than about the milestone being too small.
        let from = max(1, openIndex + 1 - 2)

        XCTAssertEqual(
            Fixture.rejection(
                AgentTimelineDraft(milestones: [
                    Fixture.milestone(title: "All done", from: from, through: openIndex + 1),
                ]),
                digest
            ),
            .falseCompletion(milestone: "All done", factID: open.id)
        )

        // The same grouping told honestly is accepted, so the rule refuses the CLAIM and not the
        // milestone — which is what keeps a live session readable rather than unreadable.
        let honest = AgentTimelineDraft(milestones: [
            Fixture.milestone(
                title: "Still working the failure",
                from: from,
                through: openIndex + 1,
                outcome: "inProgress"
            ),
        ])
        XCTAssertEqual(try Fixture.validated(honest, digest).milestones.count, 1)
    }

    /// The timeline carries no session-level verdict at all, so there is nothing for a synthesis
    /// to be wrong about. Whether the agent is still working is observed, live, and already on
    /// screen. This is asserted as a property of the type, because a field that does not exist
    /// cannot be populated wrongly later.
    func testTheTimelineTypeCannotClaimTheSessionFinished() {
        let mirrored = Mirror(reflecting: AgentSessionTimeline(
            milestones: [],
            evidenceFingerprint: "",
            factCount: 0,
            generatedAt: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(
            Set(mirrored.children.compactMap(\.label)),
            ["milestones", "evidenceFingerprint", "factCount", "generatedAt"]
        )
    }

    // MARK: - Bounds, and failing visibly

    func testOversizedAndMalformedOutputFailsVisiblyRatherThanBecomingUI() {
        let oversized = String(repeating: "x", count: AgentTimelineBounds.maximumOutputBytes + 1)
        guard case .failure(.malformedOutput(let tooBig)) =
            AgentTimelineDraftDecoder.decode(oversized)
        else {
            return XCTFail("an oversized reply was not refused before parsing")
        }
        XCTAssertTrue(tooBig.contains("exceeds"))

        guard case .failure(.malformedOutput) = AgentTimelineDraftDecoder.decode("I could not do that")
        else {
            return XCTFail("prose with no JSON in it was accepted")
        }

        guard case .failure(.malformedOutput(let missing)) = AgentTimelineDraftDecoder.decode(
            #"{"milestones":[{"title":"t","whatChanged":"w","whyItMattered":"y"}]}"#
        ) else {
            return XCTFail("a milestone missing required keys was accepted")
        }
        XCTAssertTrue(missing.contains("outcome") || missing.contains("from"), missing)
    }

    /// A fence or a sentence before the JSON is a formatting habit, not a wrong reading, and
    /// refusing those would refuse correct work for punctuation.
    func testAFencedOrIntroducedReplyIsStillRead() throws {
        let fenced = """
        Here is the reading:
        ```json
        {"milestones":[{"title":"t","whatChanged":"w","whyItMattered":"y","outcome":"settled","from":1,"through":3}]}
        ```
        """
        let draft = try AgentTimelineDraftDecoder.decode(fenced).get()
        XCTAssertEqual(draft.milestones.first?.title, "t")
    }

    func testFieldBoundsAreEnforcedPerMilestone() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session()))

        XCTAssertEqual(
            Fixture.rejection(
                AgentTimelineDraft(milestones: [
                    .init(
                        title: String(repeating: "t", count: AgentTimelineBounds.maximumTitleLength + 1),
                        whatChanged: "w",
                        whyItMattered: "y",
                        outcome: "settled",
                        from: 1,
                        through: 3
                    ),
                ]),
                digest
            )?.isFieldViolation,
            true
        )

        XCTAssertEqual(
            Fixture.rejection(
                AgentTimelineDraft(milestones: [
                    .init(
                        title: "Fine",
                        whatChanged: "   ",
                        whyItMattered: "y",
                        outcome: "settled",
                        from: 1,
                        through: 3
                    ),
                ]),
                digest
            ),
            .fieldOutOfBounds(milestone: "Fine", field: "whatChanged")
        )

        XCTAssertEqual(
            Fixture.rejection(
                AgentTimelineDraft(milestones: [
                    .init(
                        title: "Fine",
                        whatChanged: "w",
                        whyItMattered: "y",
                        outcome: "finished",
                        from: 1,
                        through: 3
                    ),
                ]),
                digest
            ),
            .unknownOutcome(milestone: "Fine", value: "finished")
        )

        XCTAssertEqual(
            Fixture.rejection(AgentTimelineDraft(milestones: []), digest),
            .empty
        )
    }

    /// The CLI's stream, asserted line by line against a recorded shape rather than a live
    /// login. Verified 2026-08-10 against the installed
    /// `claude --print --output-format stream-json --verbose --include-partial-messages`.
    func testTheAgentCLIStreamIsReadLineByLineOrIgnored() {
        let line = { (text: String) in Data(text.utf8) }

        XCTAssertEqual(
            AgentCLIStreamReader.read(
                line: line(#"{"type":"system","subtype":"init","tools":[],"session_id":"s"}"#)
            ),
            .connected
        )
        XCTAssertEqual(
            AgentCLIStreamReader.read(
                line: line(
                    #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"{\"mile"}}}"#
                )
            ),
            .wrote(#"{"mile"#)
        )
        XCTAssertEqual(
            AgentCLIStreamReader.read(
                line: line(
                    #"{"type":"result","subtype":"success","is_error":false,"result":"{\"milestones\":[]}"}"#
                )
            ),
            .finished(.success(#"{"milestones":[]}"#))
        )
        XCTAssertEqual(
            AgentCLIStreamReader.read(
                line: line(
                    #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
                )
            ),
            .finished(.failure(.runFailed("Not logged in · Please run /login")))
        )
        XCTAssertEqual(
            AgentCLIStreamReader.read(
                line: line(#"{"type":"result","subtype":"success","is_error":false,"result":""}"#)
            ),
            .finished(.failure(.malformedOutput("the CLI returned an empty reply")))
        )

        // Framing the host has no use for costs it nothing to see: most of the stream is this.
        // `message_start` left this list under T-137 — it is where the CLI's heartbeat begins, so
        // it decides which phase the deadline is in; `AgentReadingSilenceTests` holds it now.
        for noise in [
            #"{"type":"system","subtype":"status"}"#,
            #"{"type":"rate_limit_event"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}"#,
            "not json at all",
            "",
        ] {
            XCTAssertEqual(AgentCLIStreamReader.read(line: line(noise)), .ignored, noise)
        }
    }

    /// What the pane shows while a reading runs is what the run said about itself, and a run
    /// that has been superseded says nothing — its narration would describe work whose answer
    /// can never be shown.
    @MainActor
    func testAReadingInFlightSaysWhatItIsDoing() async throws {
        let blocking = Fixture.BlockingSynthesizer(reply: #"{"milestones":[]}"#)
        let model = Fixture.model(synthesizer: blocking)
        model.receive(Fixture.session(userTurns: 3, toolRuns: 4))

        model.generateTimeline()
        await blocking.waitUntilEntered()

        // The run announces from whatever thread it is on, so the pane learns about it one hop
        // later. Wait for the fact rather than for a duration.
        let deadline = ContinuousClock.now + .seconds(5)
        var reported: AgentTimelineProgress?
        while ContinuousClock.now < deadline {
            if case let .running(_, progress) = model.timelineGeneration, progress != .launching {
                reported = progress
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reported, .connected, "the pane never showed what the run was doing")

        await blocking.release()
        try await Fixture.settle(model)
    }

    /// The arguments are part of what a reading costs, so they are pinned like any other bound.
    func testAReadingRunsWithoutTheOperatorsCustomizations() {
        let arguments = AgentCLITimelineSynthesizer.arguments(
            provider: .claude,
            model: .providerDefault
        )
        XCTAssertTrue(arguments.contains("--safe-mode"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertTrue(arguments.contains("stream-json"))
        XCTAssertTrue(arguments.contains("--include-partial-messages"))
        XCTAssertFalse(arguments.contains("json"), "the one-shot envelope is gone, not kept beside")
        XCTAssertLessThan(
            AgentCLITimelineSynthesizer.silenceSeconds,
            AgentCLITimelineSynthesizer.ceilingSeconds
        )
    }

    // MARK: - Newest wins

    /// A session grows while it is being read, so two refreshes settle in whatever order the
    /// model finishes them. Newest-wins has to be a property of the run rather than of arrival
    /// order, and it is asserted here without starting a process.
    func testASlowReadingCannotReplaceANewerOne() {
        var ledger = AgentTimelineRunLedger()
        let first = ledger.begin()
        let second = ledger.begin()

        XCTAssertFalse(ledger.settle(run: first), "the superseded run landed on top of a newer one")
        XCTAssertTrue(ledger.settle(run: second))
        XCTAssertFalse(ledger.isRunning)
        XCTAssertFalse(ledger.settle(run: second), "one run settled twice")
    }

    func testCancellingAdvancesPastTheRunInFlight() {
        var ledger = AgentTimelineRunLedger()
        let run = ledger.begin()
        XCTAssertTrue(ledger.isRunning)

        ledger.cancel()
        XCTAssertFalse(ledger.isRunning)
        XCTAssertFalse(ledger.settle(run: run), "a cancelled run's result landed anyway")

        let next = ledger.begin()
        XCTAssertTrue(ledger.settle(run: next), "a fresh run after a cancel could not land")
    }

    // MARK: - The pane

    /// Timeline sits BESIDE Chat. Switching accounts changes no attachment, no renderer, and no
    /// split — the criterion this feature is most likely to violate by accident, because both
    /// pickers live in the same header.
    @MainActor
    func testSwitchingAccountLeavesTheRendererChoiceAlone() async {
        let model = Fixture.model()
        model.mode = .session
        model.showsSplitView = true

        model.account = .timeline

        XCTAssertEqual(model.mode, .session)
        XCTAssertTrue(model.showsSplitView)
        XCTAssertEqual(
            AgentLensPresentation(mode: model.mode, showsSplitView: model.showsSplitView),
            .split
        )
    }

    /// The account picker is a control of the Session renderer, so a Terminal-only pane does not
    /// draw one: its two states would look identical.
    func testTheAccountPickerAppearsOnlyWhereThereIsSomethingToChooseBetween() {
        for presentation in [AgentLensPresentation.session, .split] {
            XCTAssertTrue(
                Fixture.header(presentation: presentation, account: .timeline)
                    .trailing.contains { $0.segmentSelection == "timeline" },
                "\(presentation) draws the Session renderer and must offer its accounts"
            )
        }
        XCTAssertFalse(
            Fixture.header(presentation: .terminal).trailing.contains {
                $0.segmentValues == AgentLensAccount.allCases.map(\.rawValue)
            },
            "a terminal-only pane offered a choice between two things it does not draw"
        )
        XCTAssertEqual(Fixture.header(isAgentDetected: false), .empty)
    }

    /// The whole loop through the pane: a stub agent, a validated reading, and the pane holding
    /// it. Chat stays usable throughout because nothing here touches the snapshot.
    @MainActor
    func testThePaneLandsAValidatedReading() async throws {
        let snapshot = Fixture.session()
        let model = Fixture.model(
            snapshot: snapshot,
            synthesizer: Fixture.ScriptedSynthesizer(
                reply: Fixture.json(
                    milestones: [
                        (title: "Reproduced it", from: 1, through: 3),
                        (title: "Fixed the rule", from: 4, through: 6),
                    ]
                )
            )
        )

        model.generateTimeline()
        XCTAssertTrue(model.timelineGeneration.isRunning)
        try await Fixture.settle(model)

        let timeline = try XCTUnwrap(model.timelineGeneration.timeline)
        XCTAssertEqual(timeline.milestones.map(\.title), ["Reproduced it", "Fixed the rule"])
        XCTAssertFalse(model.timelineIsStale)
        // The verbatim account is untouched by any of this.
        XCTAssertEqual(model.snapshot.factCount, snapshot.factCount)
    }

    @MainActor
    func testARejectedReadingBecomesAVisibleRetryableFailure() async throws {
        let snapshot = Fixture.session()
        let digest = try XCTUnwrap(Fixture.digest(snapshot))
        let model = Fixture.model(
            snapshot: snapshot,
            synthesizer: Fixture.ScriptedSynthesizer(
                reply: Fixture.json(
                    milestones: (1...digest.facts.count).map {
                        (title: "Step \($0)", from: $0, through: $0)
                    }
                )
            )
        )

        model.generateTimeline()
        try await Fixture.settle(model)

        guard case .failed(let failure) = model.timelineGeneration else {
            return XCTFail("a relabelled transcript was rendered as a reading")
        }
        guard case .rejected = failure else {
            return XCTFail("the failure did not name the rejection: \(failure)")
        }
        XCTAssertTrue(failure.isRetryable)
        XCTAssertFalse(failure.message.isEmpty)
    }

    @MainActor
    func testAMissingAgentCLIFailsAndOffersNoRetryItCannotHonour() async throws {
        let model = Fixture.model(snapshot: Fixture.session(), synthesizer: nil)

        model.generateTimeline()
        try await Fixture.settle(model)

        XCTAssertEqual(model.timelineGeneration, .failed(.noSynthesizer))
        XCTAssertFalse(
            AgentTimelineFailure.noSynthesizer.isRetryable,
            "a retry button that provably does nothing is worse than none"
        )
    }

    @MainActor
    func testCancellingLeavesAReadingNobodyIsWaitingOnUnrendered() async throws {
        let snapshot = Fixture.session()
        // A reading that WOULD be accepted if it were still wanted. A reply the validator
        // rejects anyway would let this pass without the rule it is here to prove.
        let synthesizer = Fixture.BlockingSynthesizer(
            reply: Fixture.json(
                milestones: [(title: "Would have landed", from: 1, through: 3)]
            )
        )
        let model = Fixture.model(snapshot: snapshot, synthesizer: synthesizer)

        model.generateTimeline()
        XCTAssertTrue(model.timelineGeneration.isRunning)
        // Cancelling before the pane has reached the synthesizer would release nobody, and the
        // assertion below would then hold having exercised nothing.
        await synthesizer.waitUntilEntered()
        model.cancelTimelineGeneration()
        XCTAssertEqual(model.timelineGeneration, .failed(.cancelled))

        // The run in flight finishes anyway; the ledger is the only thing stopping it landing.
        await synthesizer.release()
        await Fixture.drain(synthesizer)

        XCTAssertEqual(
            model.timelineGeneration,
            .failed(.cancelled),
            "a cancelled reading landed after the person stopped waiting for it"
        )
        XCTAssertNil(model.timelineGeneration.timeline)
    }

    /// A reading is about the session it was made from. New facts make it stale rather than
    /// wrong, and the pane says so instead of quietly presenting an old reading as current.
    @MainActor
    func testANewFactMakesTheReadingStaleWithoutReplacingIt() async throws {
        var snapshot = Fixture.session()
        let model = Fixture.model(
            snapshot: snapshot,
            synthesizer: Fixture.ScriptedSynthesizer(
                reply: Fixture.json(milestones: [(title: "Read it", from: 1, through: 3)])
            )
        )

        model.generateTimeline()
        try await Fixture.settle(model)
        XCTAssertFalse(model.timelineIsStale)

        snapshot.messages.append(Fixture.message(id: "later", role: .user, text: "One more thing"))
        model.receive(snapshot)

        XCTAssertTrue(model.timelineIsStale)
        XCTAssertNotNil(
            model.timelineGeneration.timeline,
            "a stale reading is still the last true one and must not be thrown away"
        )
    }
}

// MARK: - Fixtures

private enum Fixture {
    static func evidence(_ id: String, at seconds: TimeInterval) -> AgentEvidence {
        AgentEvidence(
            source: .transcript,
            authority: .reported,
            location: "session.jsonl#\(id)",
            byteOffset: UInt64(seconds),
            fingerprint: "fixture-\(id)",
            capturedAt: Date(timeIntervalSince1970: 1_000 + seconds),
            freshness: .current
        )
    }

    static func message(
        id: String,
        role: AgentMessageRole,
        kind: AgentMessageKind = .conversation,
        text: String,
        at seconds: TimeInterval = 0
    ) -> AgentLensMessage {
        AgentLensMessage(
            id: id,
            role: role,
            kind: kind,
            text: text,
            isStreaming: false,
            evidence: evidence(id, at: seconds)
        )
    }

    /// A session with the shape a real one has: an instruction that is context, a few turns, and
    /// execution between them.
    static func session(
        userTurns: Int = 3,
        toolRuns: Int = 4,
        runningTool: Bool = false
    ) -> AgentLensSnapshot {
        var snapshot = AgentLensSnapshot.empty
        snapshot.provider = .claude
        snapshot.status = runningTool ? .running : .completed
        snapshot.messages = [
            message(id: "system", role: .system, kind: .instruction, text: "System policy", at: 0),
        ]
        for turn in 0..<userTurns {
            let base = TimeInterval(turn * 10 + 1)
            snapshot.messages.append(
                message(id: "user-\(turn)", role: .user, text: "Ask \(turn)", at: base)
            )
            snapshot.messages.append(
                message(id: "assistant-\(turn)", role: .assistant, text: "Answer \(turn)", at: base + 4)
            )
        }
        for run in 0..<toolRuns {
            let isRunning = runningTool && run == toolRuns - 1
            snapshot.tools.append(
                AgentToolRun(
                    id: "tool-\(run)",
                    name: "Bash",
                    kind: .command,
                    summary: "swift test --filter Focus\(run)",
                    detail: "",
                    state: isRunning ? .running : .succeeded,
                    exitCode: isRunning ? nil : 0,
                    evidence: evidence("tool-\(run)", at: TimeInterval(run * 10 + 2))
                )
            )
        }
        return snapshot
    }

    static func digest(_ snapshot: AgentLensSnapshot) -> AgentTimelineDigest? {
        try? AgentTimelineDigest.build(from: snapshot).get()
    }

    static func milestone(
        title: String,
        from: Int,
        through: Int,
        outcome: String = "settled"
    ) -> AgentTimelineDraft.Milestone {
        .init(
            title: title,
            whatChanged: "Something concrete changed.",
            whyItMattered: "It moved the session forward.",
            outcome: outcome,
            from: from,
            through: through
        )
    }

    static func validated(
        _ draft: AgentTimelineDraft,
        _ digest: AgentTimelineDigest
    ) throws -> AgentSessionTimeline {
        try AgentTimelineValidation
            .validate(draft, against: digest, generatedAt: Date(timeIntervalSince1970: 9_000))
            .get()
    }

    static func rejection(
        _ draft: AgentTimelineDraft,
        _ digest: AgentTimelineDigest
    ) -> AgentTimelineRejection? {
        AgentTimelineValidation
            .validate(draft, against: digest, generatedAt: Date(timeIntervalSince1970: 9_000))
            .failure
    }

    static func json(milestones: [(title: String, from: Int, through: Int)]) -> String {
        let body = milestones.map { milestone in
            """
            {"title":"\(milestone.title)","whatChanged":"It changed.",\
            "whyItMattered":"It mattered.","outcome":"settled",\
            "from":\(milestone.from),"through":\(milestone.through)}
            """
        }
        return "{\"milestones\":[\(body.joined(separator: ","))]}"
    }

    static func header(
        isAgentDetected: Bool = true,
        presentation: AgentLensPresentation = .session,
        account: AgentLensAccount = .chat
    ) -> PaneHeader {
        AgentLensPaneHeader.header(
            isAgentDetected: isAgentDetected,
            presentation: presentation,
            showsInspector: false,
            account: account
        )
    }

    @MainActor
    static func model(
        snapshot: AgentLensSnapshot? = nil,
        synthesizer: (any AgentTimelineSynthesizer)? = ScriptedSynthesizer(reply: "{}")
    ) -> AgentLensViewModel {
        // The reading never touches the terminal — the pool is here only because a pane has one.
        let model = AgentLensViewModel(
            slotID: UUID(),
            terminalPool: SurfacePool(backendName: "Timeline test") { _, _ in
                StubTerminalSurface()
            },
            discovery: AgentLensDiscovery(),
            resolveTimelineSynthesizer: { _ in synthesizer }
        )
        if let snapshot { model.receive(snapshot) }
        return model
    }

    /// Waits for the pane's generation to leave `running` without pinning a wall-clock duration
    /// to it — `.kanban` T-074 is the record of what a sleep-based wait costs this suite.
    @MainActor
    static func settle(_ model: AgentLensViewModel, within: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + within
        while model.timelineGeneration.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.timelineGeneration.isRunning, "the reading never settled")
    }

    struct ScriptedSynthesizer: AgentTimelineSynthesizer {
        let reply: String
        var announces: [AgentTimelineProgress] = []

        func synthesize(
            _ digest: AgentTimelineDigest,
            options: AgentReadingOptions,
            progress: @escaping @Sendable (AgentTimelineProgress) -> Void
        ) async throws -> String {
            for step in announces { progress(step) }
            return reply
        }
    }

    struct FailingSynthesizer: AgentTimelineSynthesizer {
        func synthesize(
            _ digest: AgentTimelineDigest,
            options: AgentReadingOptions,
            progress: @escaping @Sendable (AgentTimelineProgress) -> Void
        ) async throws -> String {
            XCTFail("an agent was asked to read a session the host already knows is unreadable")
            return ""
        }
    }

    /// Blocks until released, so cancellation is asserted against work that is genuinely still
    /// in flight.
    ///
    /// `waitUntilEntered` is the load-bearing part. Cancelling before the pane has actually
    /// reached the synthesizer makes `release` find nobody to release, and the test then passes
    /// having exercised nothing — which is what the first version of it did.
    actor BlockingSynthesizer: AgentTimelineSynthesizer {
        let reply: String

        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var isEntered = false
        private(set) var didReturn = false

        init(reply: String) {
            self.reply = reply
        }

        func synthesize(
            _ digest: AgentTimelineDigest,
            options: AgentReadingOptions,
            progress: @escaping @Sendable (AgentTimelineProgress) -> Void
        ) async throws -> String {
            isEntered = true
            progress(.connected)
            resume(&arrivals)
            await withCheckedContinuation { waiters.append($0) }
            didReturn = true
            return reply
        }

        func waitUntilEntered() async {
            guard !isEntered else { return }
            await withCheckedContinuation { arrivals.append($0) }
        }

        func release() {
            resume(&waiters)
        }

        private func resume(_ continuations: inout [CheckedContinuation<Void, Never>]) {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    /// Lets a released synthesizer's result reach the pane, without a wall-clock sleep standing
    /// in for "the result has arrived by now".
    @MainActor
    static func drain(_ synthesizer: BlockingSynthesizer) async {
        while await synthesizer.didReturn == false { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
    }
}

// MARK: - Small readers

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

private extension AgentTimelineRejection {
    var isFieldViolation: Bool {
        if case .fieldOutOfBounds = self { return true }
        return false
    }
}

private extension PaneHeaderItem {
    var segmentSelection: String? {
        guard case let .segmented(_, _, selection, _, _) = self else { return nil }
        return selection
    }

    var segmentValues: [String]? {
        guard case let .segmented(_, segments, _, _, _) = self else { return nil }
        return segments.map(\.value)
    }
}

/// T-123 — the options a reading is taken with.
///
/// The reason these rules are worth asserting is that every one of them used to be a compile-time
/// constant, and the danger in making them choices is that a choice could widen what the host
/// accepts. So the load-bearing test here is not that the options work — it is that no option can
/// change what a reading has to survive to be shown.
final class AgentReadingOptionsTests: XCTestCase {
    // MARK: - Span

    func testANarrowerSpanKeepsTheNewestWorkAndAsksADifferentQuestion() throws {
        let snapshot = Fixture.session(userTurns: 60, toolRuns: 40)
        let whole = try AgentTimelineDigest.build(from: snapshot, span: .wholeSession).get()
        let recent = try AgentTimelineDigest.build(from: snapshot, span: .recentWork).get()

        XCTAssertGreaterThan(whole.facts.count, recent.facts.count)
        XCTAssertEqual(recent.facts.count, AgentReadingSpan.recentWork.maximumFacts)
        XCTAssertTrue(recent.isTruncated, "a span that cut the session has to say so")
        XCTAssertEqual(
            recent.facts.last?.id,
            whole.facts.last?.id,
            "a narrower span keeps the tail — the newest work is what it means"
        )
        XCTAssertNotEqual(
            recent.fingerprint,
            whole.fingerprint,
            "two spans are two questions, so a reading of one is not a reading of the other"
        )
    }

    func testNoSpanCanTakeASessionBelowTheBarThatRefusesASynthesis() throws {
        // Fewer facts than the narrow span's own cap, so the cap cannot be what decides.
        let snapshot = Fixture.session(userTurns: 4, toolRuns: 3)
        for span in AgentReadingSpan.allCases {
            let digest = try AgentTimelineDigest.build(from: snapshot, span: span).get()
            XCTAssertGreaterThanOrEqual(
                digest.facts.count,
                AgentTimelineBounds.minimumFactsForSynthesis
            )
            XCTAssertNil(
                AgentTimelineDigest.insufficiency(of: snapshot),
                "the two sufficiency answers still agree under \(span)"
            )
        }
    }

    // MARK: - Lens

    func testEveryLensAsksForTheSameCheckableShape() throws {
        let digest = try XCTUnwrap(Fixture.digest(Fixture.session(userTurns: 6, toolRuns: 6)))
        let prompts = AgentReadingLens.allCases.map {
            AgentTimelinePrompt.text(for: digest, lens: $0)
        }
        let rules = AgentTimelinePrompt.rules(forFacts: digest.facts.count)

        for prompt in prompts {
            XCTAssertTrue(
                prompt.contains(rules),
                "every lens carries the identical rules block, byte for byte"
            )
            XCTAssertTrue(
                prompt.contains("Milestones do not overlap"),
                "the partition rule cannot be a property of one lens"
            )
            XCTAssertTrue(
                prompt.contains("`from` and `through` are fact numbers"),
                "every lens names the same numbered evidence, and never an id to transcribe"
            )
        }
        XCTAssertEqual(
            Set(AgentReadingLens.allCases.map(\.framing)).count,
            AgentReadingLens.allCases.count,
            "a lens that asks for the same thing as another is not a choice"
        )
    }

    // MARK: - Reader

    func testAProviderThatCannotBeToldWhichModelToRunNeverCarriesAnAlias() {
        let asked = AgentReadingOptions(provider: .codex, model: .opus)
        XCTAssertEqual(asked.model, .providerDefault)

        var options = AgentReadingOptions(provider: .claude, model: .opus)
        XCTAssertEqual(options.model, .opus)
        options.select(provider: .codex)
        XCTAssertEqual(
            options.model,
            .providerDefault,
            "changing provider carries the model with it rather than leaving another CLI's alias"
        )
    }

    func testEachProviderIsInvokedTheWayItsOwnCLISpellsAOneShotReading() {
        let claude = AgentCLITimelineSynthesizer.arguments(provider: .claude, model: .opus)
        XCTAssertTrue(claude.contains("--print"))
        XCTAssertTrue(claude.contains("stream-json"))
        XCTAssertTrue(claude.contains("--safe-mode"))
        XCTAssertTrue(claude.contains("--no-session-persistence"))
        XCTAssertNotNil(
            zip(claude, claude.dropFirst()).first { $0 == "--model" && $1 == "opus" },
            "the model is spelled with the provider's own documented alias"
        )

        let codex = AgentCLITimelineSynthesizer.arguments(provider: .codex, model: .providerDefault)
        XCTAssertEqual(codex.first, "exec")
        XCTAssertTrue(codex.contains("--json"))
        XCTAssertTrue(codex.contains("--skip-git-repo-check"))
        XCTAssertFalse(codex.contains("--model"), "codex model ids are account-configured")
        XCTAssertEqual(codex.last, "-", "codex reads the prompt from stdin like claude does")
    }

    /// Measured 2026-08-11 against the installed `codex exec --json`, exactly as recorded in the
    /// task file: `thread.started`, `turn.started`, `item.completed` carrying the agent message,
    /// `turn.completed`.
    func testCodexEventsFoldIntoTheSameReadingClaudeStreamDoes() {
        func read(_ line: String) -> AgentCLIStreamReading {
            AgentCLIStreamReader.read(line: Data(line.utf8), provider: .codex)
        }

        XCTAssertEqual(read(#"{"type":"thread.started","thread_id":"019f"}"#), .connected)
        XCTAssertEqual(read(#"{"type":"turn.started"}"#), .ignored)
        XCTAssertEqual(
            read(#"{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"{\"ok\":1}"}}"#),
            .finished(.success(#"{"ok":1}"#))
        )
        XCTAssertEqual(read(#"{"type":"turn.completed","usage":{"output_tokens":9}}"#), .ignored)
        XCTAssertEqual(
            read(#"{"type":"item.completed","item":{"id":"i0","type":"reasoning","text":"thinking"}}"#),
            .ignored,
            "only the agent's message is the reply"
        )
    }

    func testAProviderThatNeverStreamsIsNotKilledForSilence() {
        XCTAssertEqual(
            AgentCLITimelineSynthesizer.silenceSeconds(for: .claude),
            AgentCLITimelineSynthesizer.silenceSeconds
        )
        XCTAssertNil(
            AgentCLITimelineSynthesizer.silenceSeconds(for: .codex),
            "silence is only evidence of death where the CLI streams while it works"
        )
    }

    // MARK: - The request carries them

    @MainActor
    func testTheReadingRunsWithTheOptionsItWasStartedWith() async throws {
        let recorder = RecordingSynthesizer()
        let model = Fixture.model(
            snapshot: Fixture.session(userTurns: 6, toolRuns: 6),
            synthesizer: recorder
        )
        model.readingOptions = AgentReadingOptions(
            provider: .claude,
            model: .opus,
            span: .recentWork,
            lens: .decisions
        )

        model.generateTimeline()
        // Whatever the person picks next belongs to the next reading, not to this one.
        model.readingOptions = AgentReadingOptions()
        try await Fixture.settle(model)

        XCTAssertEqual(recorder.observed?.lens, .decisions)
        XCTAssertEqual(recorder.observed?.model, .opus)
        XCTAssertEqual(recorder.observed?.span, .recentWork)
        XCTAssertEqual(
            model.readingOptionsInUse?.lens,
            .decisions,
            "the finished reading says which options produced it"
        )
    }

    /// Cancelling ends a run, not the choices. The retry the pane offers is a fresh reading, so
    /// it takes whatever is picked when it is asked for — including a different reader, which is
    /// the most useful thing to change after one failed.
    @MainActor
    func testCancellingAReadingKeepsTheChoicesAndTheRetryTakesThem() async throws {
        let recorder = RecordingSynthesizer()
        let model = Fixture.model(
            snapshot: Fixture.session(userTurns: 6, toolRuns: 6),
            synthesizer: recorder
        )
        model.readingOptions = AgentReadingOptions(span: .recentWork, lens: .problems)

        model.generateTimeline()
        try await Fixture.settle(model)
        XCTAssertEqual(recorder.observed?.lens, .problems)
        XCTAssertEqual(recorder.observed?.span, .recentWork)

        model.generateTimeline()
        model.cancelTimelineGeneration()
        XCTAssertEqual(model.readingOptions.lens, .problems, "a cancel ends the run, not the choice")
        XCTAssertEqual(model.readingOptions.span, .recentWork)

        // A retry is a fresh reading, so it takes whatever is picked when it is asked for.
        // Asserted on the pane rather than on the recorder: a cancelled run's task can still
        // reach a synthesizer that does not check for cancellation, so what the recorder saw
        // last is a race, while what the pane attributed the reading to is not.
        model.readingOptions.lens = .decisions
        model.generateTimeline()
        try await Fixture.settle(model)
        XCTAssertEqual(model.readingOptionsInUse?.lens, .decisions)
        XCTAssertEqual(model.readingOptionsInUse?.span, .recentWork)
    }

    @MainActor
    func testTheReaderChoiceIsOnlyTheCLIsThisMachineHas() async {
        let model = Fixture.model(snapshot: Fixture.session(userTurns: 6, toolRuns: 6))
        XCTAssertEqual(model.availableReaders, [], "nothing is offered before the scan answers")

        await model.loadAvailableReaders(using: { [.codex] })

        XCTAssertEqual(model.availableReaders, [.codex])
        XCTAssertEqual(
            model.readingOptions.provider,
            .codex,
            "a default reader this machine does not have is not a reader"
        )
    }

    @MainActor
    func testAScanThatFoundNothingLeavesTheReadingItsDefaultReader() async {
        let model = Fixture.model(snapshot: Fixture.session(userTurns: 6, toolRuns: 6))
        await model.loadAvailableReaders(using: { [] })

        XCTAssertEqual(model.availableReaders, [])
        XCTAssertEqual(
            model.readingOptions.provider,
            .claude,
            "an empty scan is not a reason to leave the pane with no reader at all"
        )
    }

    func testAFinishedReadingNamesEveryChoiceThatIsNotTheDefault() {
        let asked = AgentReadingOptions(
            provider: .claude,
            model: .opus,
            span: .recentWork,
            lens: .decisions
        ).summary
        XCTAssertTrue(asked.contains(AgentCLI.claude.label))
        XCTAssertTrue(asked.contains("Opus"))
        XCTAssertTrue(asked.contains("recent work"))
        XCTAssertTrue(asked.contains("decisions"))

        XCTAssertFalse(
            AgentReadingOptions().summary.contains("Default model"),
            "a reading that took the CLI's own model has no model to report"
        )
    }

    @MainActor
    func testANarrowSpanReachesTheDigestTheReadingIsMadeFrom() async throws {
        let recorder = RecordingSynthesizer()
        let model = Fixture.model(
            snapshot: Fixture.session(userTurns: 60, toolRuns: 40),
            synthesizer: recorder
        )
        model.readingOptions = AgentReadingOptions(span: .recentWork)

        model.generateTimeline()
        try await Fixture.settle(model)

        XCTAssertEqual(
            recorder.digest?.facts.count,
            AgentReadingSpan.recentWork.maximumFacts,
            "the span bounds the evidence before a model ever sees it"
        )
    }
}

/// Answers with a reading built from whatever digest it is given, and remembers what it was asked.
private final class RecordingSynthesizer: AgentTimelineSynthesizer, @unchecked Sendable {
    private let lock = NSLock()
    private var seenOptions: AgentReadingOptions?
    private var seenDigest: AgentTimelineDigest?

    var observed: AgentReadingOptions? { lock.withLock { seenOptions } }
    var digest: AgentTimelineDigest? { lock.withLock { seenDigest } }

    func synthesize(
        _ digest: AgentTimelineDigest,
        options: AgentReadingOptions,
        progress: @escaping @Sendable (AgentTimelineProgress) -> Void
    ) async throws -> String {
        lock.withLock {
            seenOptions = options
            seenDigest = digest
        }
        let anchors = digest.facts.prefix(4).map { "\"\($0.id)\"" }.joined(separator: ",")
        return """
        {"milestones":[{"title":"Read the session","whatChanged":"The pane produced a reading.",\
        "whyItMattered":"It proves the request reached the synthesizer.","outcome":"settled",\
        "anchors":[\(anchors)]}]}
        """
    }
}
