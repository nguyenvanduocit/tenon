import Darwin
import Foundation
@testable import TenonApp
import TenonCore
import XCTest

/// T-091. The next spin has to leave a receipt taken while it was still a spin.
///
/// The only sample of that two-hour hang was taken by hand near the end, after 10.4 GB had
/// swapped out — by then every turn was slow for reasons that had nothing to do with the cause,
/// and the first turns were invisible. A sample taken seconds into the stall is the evidence
/// the reproduction still needs.
final class StallSampleCaptureTests: XCTestCase {
    func testTheFirstStallSamplesTheProcessOnce() throws {
        let captures = CaptureLog()
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            escalationInterval: 1,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.recordSuccessfulSample($0) }
        )

        clock.value = 0
        runtime.beat()
        clock.value = 10
        runtime.probeOnce()
        captures.waitForCount(1)
        waitForRecord(kind: "stall-sample-completed", in: journalURL)

        XCTAssertEqual(captures.count, 1, "a stall must sample the process")
        let completed = DiagnosticsJournal(fileURL: journalURL).records().first {
            $0.kind == "stall-sample-completed"
        }
        XCTAssertEqual(completed?.figures["exitStatus"], "0")
        XCTAssertGreaterThan(Int(completed?.figures["sampleBytes"] ?? "0") ?? 0, 0)
        guard let relative = completed?.figures["sampleFile"] else {
            return XCTFail("completed capture must name its relative artifact")
        }
        XCTAssertFalse(relative.hasPrefix("/"), "absolute user paths never enter the journal")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: journalURL.deletingLastPathComponent().appendingPathComponent(relative).path
            )
        )

        // A spin lasting hours must not spend those hours writing samples.
        clock.value = 20
        runtime.probeOnce()
        clock.value = 40
        runtime.probeOnce()
        XCTAssertEqual(captures.count, 1, "an ongoing stall re-samples nothing")
    }

    func testARunloopThatKeepsTurningSamplesNothing() throws {
        let captures = CaptureLog()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: try temporaryJournalURL()),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.recordSuccessfulSample($0) }
        )

        for step in stride(from: 0.0, through: 20.0, by: 1.0) {
            clock.value = step
            runtime.beat()
            runtime.probeOnce()
        }

        XCTAssertEqual(captures.count, 0)
    }

    /// A stall that ends and happens again is two incidents, and the second one is often the
    /// interesting one.
    func testASecondStallSamplesAgain() throws {
        let captures = CaptureLog()
        let clock = Clock()
        let journalURL = try temporaryJournalURL()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.recordSuccessfulSample($0) }
        )

        clock.value = 0
        runtime.beat()
        clock.value = 10
        runtime.probeOnce()
        captures.waitForCount(1)

        clock.value = 11
        runtime.beat()
        clock.value = 30
        runtime.probeOnce()
        captures.waitForCount(2)
        waitForRecordCount(kind: "stall-sample-completed", expected: 2, in: journalURL)

        XCTAssertEqual(captures.count, 2)
        let files = DiagnosticsJournal(fileURL: journalURL).records()
            .filter { $0.kind == "stall-sample-completed" }
            .compactMap { $0.figures["sampleFile"] }
        XCTAssertEqual(Set(files).count, 2)
        for file in files {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: journalURL.deletingLastPathComponent().appendingPathComponent(file).path
                )
            )
        }
    }

    func testFailedSamplerNeverClaimsACompletedArtifact() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { nil },
            captureSample: { destination in
                try? destination.write(contentsOf: Data("partial".utf8))
                return .finished(exitStatus: 7)
            }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-failed", in: journalURL)

        let records = DiagnosticsJournal(fileURL: journalURL).records()
        XCTAssertFalse(records.map(\.kind).contains("stall-sample-completed"))
        let failure = records.first { $0.kind == "stall-sample-failed" }
        XCTAssertEqual(failure?.figures["reason"], "nonzero-exit")
        XCTAssertEqual(failure?.figures["exitStatus"], "7")
        let artifacts = try FileManager.default.subpathsOfDirectory(
            atPath: journalURL.deletingLastPathComponent().path
        )
        XCTAssertFalse(artifacts.contains { $0.hasSuffix("sample.txt") || $0.hasSuffix("sample.partial") })
    }

    func testCommittedSampleAndExportRedactUserPathsArgumentsAndPluginIdentifiers() throws {
        let journalURL = try temporaryJournalURL()
        let journal = DiagnosticsJournal(fileURL: journalURL)
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: journal,
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { destination in
                let fixture = """
                Command: /Users/alice/SecretProject/run --token TOP-SECRET
                10 SwiftUI.ViewGraph.update()
                DispatchQueue: dev.tenon.plugin-watch.com.secret.customer.42
                Thread: dev.tenon.plugin.com.secret.executor
                source /Volumes/Private Drive/Secret Project/customer/file.swift
                """
                try? destination.write(contentsOf: Data(fixture.utf8))
                return .finished(exitStatus: 0)
            }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-completed", in: journalURL)
        let completed = journal.records().first { $0.kind == "stall-sample-completed" }
        guard let relative = completed?.figures["sampleFile"] else {
            return XCTFail("completed sample must name its artifact")
        }
        let artifact = journalURL.deletingLastPathComponent().appendingPathComponent(relative)
        let artifactText = try String(contentsOf: artifact, encoding: .utf8)
        let exportURL = journalURL.deletingLastPathComponent().appendingPathComponent("export.txt")
        try journal.export(to: exportURL)
        let exportText = try String(contentsOf: exportURL, encoding: .utf8)

        for text in [artifactText, exportText] {
            XCTAssertTrue(text.contains("SwiftUI.ViewGraph.update"), text)
            XCTAssertFalse(text.contains("TOP-SECRET"), text)
            XCTAssertFalse(text.contains("com.secret.customer"), text)
            XCTAssertFalse(text.contains("/Users/alice"), text)
            XCTAssertFalse(text.contains("/Volumes/Private"), text)
            XCTAssertFalse(text.contains("Secret Project"), text)
        }
    }

    func testPrivacyFilteringCannotExpandACommittedSamplePastItsByteLimit() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            maximumSampleBytes: 100,
            captureSample: { destination in
                // Raw: 90 bytes. Redacted: 210 bytes. The output cap, not only the input cap,
                // is part of the disk-bound contract.
                try? destination.write(
                    contentsOf: Data(String(repeating: "/Users/a\n", count: 10).utf8)
                )
                return .finished(exitStatus: 0)
            }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-failed", in: journalURL)

        let records = DiagnosticsJournal(fileURL: journalURL).records()
        XCTAssertEqual(
            records.first { $0.kind == "stall-sample-failed" }?.figures["reason"],
            "sanitized-output-oversized"
        )
        XCTAssertFalse(records.map(\.kind).contains("stall-sample-completed"))
        XCTAssertTrue(
            ((try? FileManager.default.subpathsOfDirectory(
                atPath: journalURL.deletingLastPathComponent().path
            )) ?? []).allSatisfy { !$0.hasSuffix("sample.txt") }
        )
    }

    func testRawSamplerOutputIsWriterBoundedAndNeverPublishedBeforeRedaction() throws {
        let journalURL = try temporaryJournalURL()
        let diagnosticsRoot = journalURL.deletingLastPathComponent()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            maximumSampleBytes: 64,
            captureSample: { destination in
                let visible = (try? FileManager.default.subpathsOfDirectory(
                    atPath: diagnosticsRoot.path
                )) ?? []
                XCTAssertFalse(
                    visible.contains {
                        $0.hasSuffix("sample.partial") || $0.hasSuffix("sample-staging.tmp")
                    },
                    "raw sample bytes must exist only in the pipe and an unlinked inode"
                )
                try? destination.write(contentsOf: Data(repeating: 0x41, count: 1_048_576))
                return .finished(exitStatus: 0)
            }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-failed", in: journalURL)

        let records = DiagnosticsJournal(fileURL: journalURL).records()
        let failure = records.first { $0.kind == "stall-sample-failed" }
        XCTAssertEqual(failure?.figures["reason"], "oversized-output")
        XCTAssertEqual(failure?.figures["maximumSampleBytes"], "64")
        XCTAssertFalse(records.map(\.kind).contains("stall-sample-completed"))
        XCTAssertTrue(waitForNoSampleArtifacts(beside: journalURL))
    }

    func testIncidentDirectoryFailureDoesNotClaimSamplerLaunchFailure() throws {
        let journalURL = try temporaryJournalURL()
        let incidents = journalURL.deletingLastPathComponent().appendingPathComponent("incidents")
        try Data("not a directory".utf8).write(to: incidents)
        let clock = Clock()
        let captures = CaptureLog()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.recordSuccessfulSample($0) }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-failed", in: journalURL)

        let records = DiagnosticsJournal(fileURL: journalURL).records()
        XCTAssertEqual(captures.count, 0)
        XCTAssertEqual(
            records.first { $0.kind == "stall-sample-failed" }?.figures["reason"],
            "artifact-directory-create-failed"
        )
        XCTAssertTrue(records.map(\.kind).contains("stall-transitions-failed"))
        XCTAssertFalse(records.contains { $0.figures["reason"] == "launch-failed" })
    }

    func testCaptureNeverFollowsAKnownRunSymlinkOutsideDiagnostics() throws {
        let journalURL = try temporaryJournalURL()
        let incidents = journalURL.deletingLastPathComponent()
            .appendingPathComponent("incidents", isDirectory: true)
        try FileManager.default.createDirectory(at: incidents, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-capture-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("must-survive.txt")
        try Data("outside".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: incidents.appendingPathComponent("known-run"),
            withDestinationURL: outside
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let captures = CaptureLog()
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            identity: DiagnosticsRunIdentity(
                runID: "known-run",
                pid: 42,
                version: "1",
                build: "1",
                channel: "test"
            ),
            captureSample: { captures.recordSuccessfulSample($0) }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-failed", in: journalURL)

        let records = DiagnosticsJournal(fileURL: journalURL).records()
        XCTAssertEqual(captures.count, 0)
        XCTAssertEqual(
            records.first { $0.kind == "stall-sample-failed" }?.figures["reason"],
            "artifact-directory-create-failed"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["must-survive.txt"])
    }

    func testSamplerDescriptorCannotBeRedirectedByReplacingItsPathWithASymlink() throws {
        let journalURL = try temporaryJournalURL()
        let diagnosticsRoot = journalURL.deletingLastPathComponent()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-sample-target-\(UUID().uuidString).txt")
        try Data("must survive".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { destination in
                let paths = (try? FileManager.default.subpathsOfDirectory(
                    atPath: diagnosticsRoot.path
                )) ?? []
                XCTAssertFalse(paths.contains { $0.hasSuffix("sample-staging.tmp") })
                if let transitions = paths.first(where: { $0.hasSuffix("transitions.jsonl") }) {
                    let incident = diagnosticsRoot.appendingPathComponent(transitions)
                        .deletingLastPathComponent()
                    try? FileManager.default.createSymbolicLink(
                        at: incident.appendingPathComponent("sample.partial"),
                        withDestinationURL: outside
                    )
                }
                // `/usr/bin/sample` sees only this pipe. The bounded drain writes to an inode
                // that was unlinked before capture began, never to an incident pathname.
                try? destination.write(contentsOf: Data("captured stack".utf8))
                return .finished(exitStatus: 0)
            }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-completed", in: journalURL)

        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "must survive")
        let records = DiagnosticsJournal(fileURL: journalURL).records()
        XCTAssertTrue(records.map(\.kind).contains("stall-sample-completed"))
        XCTAssertFalse(
            ((try? FileManager.default.subpathsOfDirectory(atPath: diagnosticsRoot.path)) ?? [])
                .contains { $0.hasSuffix("sample.partial") || $0.hasSuffix("sample-staging.tmp") }
        )
    }

    func testBlockedSamplerDoesNotBlockEscalationOrRecoveryRecords() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let captures = DelayedFirstCapture()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            escalationInterval: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.capture($0) }
        )

        clock.value = 10
        runtime.probeOnce()
        XCTAssertTrue(captures.waitUntilFirstStarts())
        clock.value = 16
        runtime.probeOnce()
        clock.value = 17
        runtime.beat()
        waitForRecord(kind: "stall-continues", in: journalURL)
        waitForRecord(kind: "recovered", in: journalURL)

        let kinds = DiagnosticsJournal(fileURL: journalURL).records().map(\.kind)
        XCTAssertTrue(kinds.contains("stall-continues"), "got \(kinds)")
        XCTAssertTrue(kinds.contains("recovered"), "got \(kinds)")
        captures.releaseFirst()
        XCTAssertTrue(captures.waitUntilFirstReturns())
    }

    func testTimedOutSamplerRetainingItsWriterCannotBlindTheNextIncident() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let captures = RetainedWriterCapture()
        defer { captures.closeRetainedWriter() }
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.capture($0) }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-failed", in: journalURL)
        XCTAssertEqual(captures.count, 1)

        clock.value = 11
        runtime.beat()
        clock.value = 30
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-completed", in: journalURL)

        XCTAssertEqual(captures.count, 2)
        let records = DiagnosticsJournal(fileURL: journalURL).records()
        XCTAssertEqual(
            records.first { $0.kind == "stall-sample-failed" }?.figures["reason"],
            "timeout"
        )
        XCTAssertEqual(records.filter { $0.kind == "stall-sample-completed" }.count, 1)
    }

    func testIncidentArtifactRetentionDropsOldestWithoutOverwritingNewest() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let captures = CaptureLog()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            retainedIncidentCount: 1,
            captureSample: { captures.recordSuccessfulSample($0) }
        )

        clock.value = 10
        runtime.probeOnce()
        captures.waitForCount(1)
        waitForRecordCount(kind: "stall-sample-completed", expected: 1, in: journalURL)
        clock.value = 11
        runtime.beat()
        clock.value = 30
        runtime.probeOnce()
        captures.waitForCount(2)
        waitForRecordCount(kind: "stall-sample-completed", expected: 2, in: journalURL)
        waitForSampleFileCount(1, beside: journalURL)

        let samples = try FileManager.default.subpathsOfDirectory(
            atPath: journalURL.deletingLastPathComponent().path
        ).filter { $0.hasSuffix("sample.txt") }
        XCTAssertEqual(samples.count, 1)
        let newestReceipt = DiagnosticsJournal(fileURL: journalURL).records()
            .last { $0.kind == "stall-sample-completed" }?.figures["sampleFile"]
        XCTAssertEqual(
            samples.first,
            newestReceipt,
            "the newest incident survives retention at the journal-correlated path"
        )
    }

    @MainActor
    func testLaunchPrunesAbandonedPriorRunIncidentDirectories() throws {
        let journalURL = try temporaryJournalURL()
        let incidentRoot = journalURL.deletingLastPathComponent()
            .appendingPathComponent("incidents/old-run", isDirectory: true)
        for ordinal in 1...3 {
            let directory = incidentRoot.appendingPathComponent("000\(ordinal)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("partial".utf8).write(
                to: directory.appendingPathComponent("sample.partial")
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(ordinal))],
                ofItemAtPath: directory.path
            )
        }
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            retainedIncidentCount: 2,
            captureSample: { _ in .launchFailed }
        )

        runtime.start()
        XCTAssertTrue(waitForNoSampleArtifacts(beside: journalURL))
        runtime.stop()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: incidentRoot.path)
        XCTAssertEqual(Set(remaining), ["0002", "0003"])
        for incident in remaining {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: incidentRoot.appendingPathComponent(incident).path
                ),
                []
            )
        }
    }

    @MainActor
    func testRetentionNeverFollowsRunOrIncidentSymlinksOutsideDiagnostics() throws {
        let journalURL = try temporaryJournalURL()
        let incidentRoot = journalURL.deletingLastPathComponent()
            .appendingPathComponent("incidents", isDirectory: true)
        try FileManager.default.createDirectory(at: incidentRoot, withIntermediateDirectories: true)

        let outsideRun = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-outside-run-\(UUID().uuidString)", isDirectory: true)
        let outsideRunIncident = outsideRun.appendingPathComponent("old-incident", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideRunIncident,
            withIntermediateDirectories: true
        )
        let runSentinel = outsideRunIncident.appendingPathComponent("must-survive.txt")
        try Data("outside run".utf8).write(to: runSentinel)
        try FileManager.default.createSymbolicLink(
            at: incidentRoot.appendingPathComponent("evil-run"),
            withDestinationURL: outsideRun
        )

        let realRun = incidentRoot.appendingPathComponent("real-run", isDirectory: true)
        try FileManager.default.createDirectory(at: realRun, withIntermediateDirectories: true)
        let outsideIncident = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-outside-incident-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideIncident, withIntermediateDirectories: true)
        let incidentSentinel = outsideIncident.appendingPathComponent("must-survive.txt")
        try Data("outside incident".utf8).write(to: incidentSentinel)
        try FileManager.default.createSymbolicLink(
            at: realRun.appendingPathComponent("evil-incident"),
            withDestinationURL: outsideIncident
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: outsideRun)
            try? FileManager.default.removeItem(at: outsideIncident)
        }

        let clock = Clock()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            retainedIncidentCount: 1,
            captureSample: { destination in
                try? destination.write(contentsOf: Data("sample".utf8))
                return .finished(exitStatus: 0)
            }
        )
        runtime.start()
        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-sample-completed", in: journalURL)
        runtime.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: runSentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incidentSentinel.path))
    }

    func testStallFreezesAndCommitsTheTypedTransitionPrelude() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let signals = DiagnosticsRuntimeSignals(capacity: 4, now: { clock.value })
        let pane = signals.registerAgentLensPane()
        signals.noteAgentLensScroll(paneOrdinal: pane, admitted: true, pinned: true)
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            signals: signals,
            captureSample: { destination in
                try? destination.write(contentsOf: Data("stack".utf8))
                return .finished(exitStatus: 0)
            }
        )

        clock.value = 10
        runtime.probeOnce()
        waitForRecord(kind: "stall-transitions-completed", in: journalURL)

        let record = DiagnosticsJournal(fileURL: journalURL).records().first {
            $0.kind == "stall-transitions-completed"
        }
        guard let relative = record?.figures["transitionFile"] else {
            return XCTFail("transition receipt must name its relative artifact")
        }
        let text = try String(
            contentsOf: journalURL.deletingLastPathComponent().appendingPathComponent(relative),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("agent-lens-scroll-admitted"), text)
        XCTAssertFalse(text.contains("slotID"), text)
    }

    func testIncidentPreludeExcludesTransitionsAddedAfterDetection() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let signals = DiagnosticsRuntimeSignals(capacity: 16, now: { clock.value })
        let pane = signals.registerAgentLensPane()
        let captures = DelayedFirstCapture()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            signals: signals,
            captureSample: { captures.capture($0) }
        )

        clock.value = 10
        runtime.probeOnce()
        XCTAssertTrue(captures.waitUntilFirstStarts())
        clock.value = 11
        runtime.beat()
        signals.noteAgentLensScroll(paneOrdinal: pane, admitted: true, pinned: true)
        clock.value = 20
        runtime.probeOnce() // incident two freezes here, queued behind the blocked first sampler
        signals.noteAgentLensScrollExecuted(paneOrdinal: pane) // after incident two detection
        captures.releaseFirst()
        waitForRecordCount(kind: "stall-transitions-completed", expected: 2, in: journalURL)

        let records = DiagnosticsJournal(fileURL: journalURL).records()
        let secondIncidentID = records.filter { $0.kind == "stall" }.last?
            .figures["incidentID"]
        let transitionRecord = records.first {
            $0.kind == "stall-transitions-completed"
                && $0.figures["incidentID"] == secondIncidentID
        }
        guard let relative = transitionRecord?.figures["transitionFile"] else {
            return XCTFail("second incident must retain its transition artifact")
        }
        let text = try String(
            contentsOf: journalURL.deletingLastPathComponent().appendingPathComponent(relative),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("agent-lens-scroll-admitted"), text)
        XCTAssertFalse(text.contains("agent-lens-scroll-executed"), text)
    }

    func testDelayedFirstCaptureKeepsItsIncidentAfterRecoveryAndASecondStall() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let captures = DelayedFirstCapture()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.capture($0) }
        )

        clock.value = 10
        runtime.probeOnce()
        XCTAssertTrue(captures.waitUntilFirstStarts())
        clock.value = 11
        runtime.beat()
        clock.value = 30
        runtime.probeOnce()
        captures.releaseFirst()
        waitForRecordCount(kind: "stall-sample-completed", expected: 2, in: journalURL)

        let records = DiagnosticsJournal(fileURL: journalURL).records()
        let stallIDs = records.filter { $0.kind == "stall" }.compactMap {
            $0.figures["incidentID"]
        }
        let completedIDs = records.filter { $0.kind == "stall-sample-completed" }.compactMap {
            $0.figures["incidentID"]
        }
        XCTAssertEqual(stallIDs.count, 2)
        XCTAssertEqual(Set(completedIDs), Set(stallIDs))
        XCTAssertEqual(
            records.first { $0.kind == "recovered" }?.figures["incidentID"],
            stallIDs.first
        )
    }

    @MainActor
    func testCleanTerminationSuppressesLateCaptureReceipts() throws {
        let journalURL = try temporaryJournalURL()
        let clock = Clock()
        let captures = DelayedFirstCapture()
        let runtime = DiagnosticsRuntime(
            journal: DiagnosticsJournal(fileURL: journalURL),
            threshold: 5,
            now: { clock.value },
            footprintBytes: { 0 },
            captureSample: { captures.capture($0) }
        )

        runtime.start()
        clock.value = 10
        runtime.probeOnce()
        XCTAssertTrue(captures.waitUntilFirstStarts())
        runtime.stop()
        captures.releaseFirst()
        XCTAssertTrue(captures.waitUntilFirstReturns())
        XCTAssertTrue(waitForNoSampleArtifacts(beside: journalURL))

        let records = DiagnosticsJournal(fileURL: journalURL).records()
        XCTAssertEqual(records.last?.kind, "termination")
        XCTAssertFalse(records.map(\.kind).contains("stall-sample-completed"))
        XCTAssertFalse(records.map(\.kind).contains("stall-sample-failed"))
        if let relative = records.first(where: { $0.kind == "stall-transitions-completed" })?
            .figures["transitionFile"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: journalURL.deletingLastPathComponent()
                        .appendingPathComponent(relative).path
                ),
                "a durable transition receipt must keep its artifact after a late sample"
            )
        } else {
            XCTFail("transition receipt must precede clean termination")
        }
    }

    // MARK: - Fixture

    private func temporaryJournalURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tenon-t091-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("health.jsonl")
    }

    private func waitForRecord(
        kind: String,
        in journalURL: URL,
        timeout: TimeInterval = 5
    ) {
        waitForRecordCount(kind: kind, expected: 1, in: journalURL, timeout: timeout)
    }

    private func waitForRecordCount(
        kind: String,
        expected: Int,
        in journalURL: URL,
        timeout: TimeInterval = 5
    ) {
        let journal = DiagnosticsJournal(fileURL: journalURL)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              journal.records().filter({ $0.kind == kind }).count < expected {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func waitForSampleFileCount(
        _ expected: Int,
        beside journalURL: URL,
        timeout: TimeInterval = 5
    ) {
        let root = journalURL.deletingLastPathComponent()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasSuffix("sample.txt") }.count
            if count == expected { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func waitForNoSampleArtifacts(
        beside journalURL: URL,
        timeout: TimeInterval = 5
    ) -> Bool {
        let root = journalURL.deletingLastPathComponent()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let artifacts = ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
                .filter {
                    $0.hasSuffix("sample.partial")
                        || $0.hasSuffix("sample-staging.tmp")
                        || $0.hasSuffix("sample-commit.tmp")
                        || $0.hasSuffix("transitions-commit.tmp")
                        || $0.hasSuffix("sample.txt")
                }
            if artifacts.isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The sample runs off the main queue — the thread it would otherwise be wedged behind — so
/// the test waits for it rather than assuming it already ran.
private final class CaptureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int { lock.withLock { storedCount } }

    func recordSuccessfulSample(_ destination: FileHandle) -> DiagnosticsSampleResult {
        try? destination.write(contentsOf: Data("sample evidence".utf8))
        lock.withLock { storedCount += 1 }
        return .finished(exitStatus: 0)
    }

    func waitForCount(_ expected: Int, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, count < expected {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private final class DelayedFirstCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let firstStarted = DispatchSemaphore(value: 0)
    private let firstRelease = DispatchSemaphore(value: 0)
    private let firstReturned = DispatchSemaphore(value: 0)

    func capture(_ destination: FileHandle) -> DiagnosticsSampleResult {
        lock.lock()
        count += 1
        let index = count
        lock.unlock()
        if index == 1 {
            firstStarted.signal()
            firstRelease.wait()
        }
        try? destination.write(contentsOf: Data("sample \(index)".utf8))
        if index == 1 { firstReturned.signal() }
        return .finished(exitStatus: 0)
    }

    func waitUntilFirstStarts() -> Bool {
        firstStarted.wait(timeout: .now() + 5) == .success
    }

    func releaseFirst() {
        firstRelease.signal()
    }

    func waitUntilFirstReturns() -> Bool {
        firstReturned.wait(timeout: .now() + 5) == .success
    }
}

private final class RetainedWriterCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    private var retainedWriter: Int32 = -1

    var count: Int { lock.withLock { storedCount } }

    func capture(_ destination: FileHandle) -> DiagnosticsSampleResult {
        let index = lock.withLock { () -> Int in
            storedCount += 1
            return storedCount
        }
        if index == 1 {
            let duplicate = Darwin.dup(destination.fileDescriptor)
            lock.withLock { retainedWriter = duplicate }
            return .timedOut
        }
        try? destination.write(contentsOf: Data("later sample".utf8))
        return .finished(exitStatus: 0)
    }

    func closeRetainedWriter() {
        let descriptor = lock.withLock { () -> Int32 in
            defer { retainedWriter = -1 }
            return retainedWriter
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    deinit {
        closeRetainedWriter()
    }
}
