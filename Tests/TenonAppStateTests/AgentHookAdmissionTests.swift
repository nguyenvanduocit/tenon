import Foundation
@testable import TenonApp
import XCTest

/// T-093. A hook event describes itself, so the pane checks that description against the
/// process it can actually see.
///
/// The pane and surface tokens prove the event came from this terminal. They say nothing about
/// which program in it wrote the event, and both the provider and the process group in a hook
/// are written by the client. The discovery path already refuses a reported transcript whose
/// provider or process group disagrees with the live foreground process; this is the same check
/// for the live channel.
final class AgentHookAdmissionTests: XCTestCase {
    func testAnEventIsAdmittedWhenItAgreesWithTheLiveSession() {
        XCTAssertTrue(
            AgentHookAdmission.admits(
                event(provider: .claude, processGroupID: 4_242),
                resolution: resolution(provider: .claude, foregroundPID: 99),
                processGroupID: { _ in 4_242 }
            )
        )
    }

    func testAnEventClaimingAnotherProviderIsRefused() {
        XCTAssertFalse(
            AgentHookAdmission.admits(
                event(provider: .codex, processGroupID: 4_242),
                resolution: resolution(provider: .claude, foregroundPID: 99),
                processGroupID: { _ in 4_242 }
            )
        )
    }

    func testAnEventFromAnotherProcessGroupIsRefused() {
        XCTAssertFalse(
            AgentHookAdmission.admits(
                event(provider: .claude, processGroupID: 7),
                resolution: resolution(provider: .claude, foregroundPID: 99),
                processGroupID: { _ in 4_242 }
            )
        )
    }

    /// Before the pane resolves anything there is nothing to disagree with, and refusing here
    /// would drop the opening seconds of every session — exactly the moment supervision is for.
    func testEventsAreAdmittedBeforeThePaneHasResolvedASession() {
        XCTAssertTrue(
            AgentHookAdmission.admits(
                event(provider: .claude, processGroupID: 7),
                resolution: nil,
                processGroupID: { _ in 4_242 }
            )
        )
    }

    /// A hook that declares no process group is still bound by its provider and its surface
    /// token; there is nothing further to compare.
    func testAnEventWithoutAProcessGroupIsJudgedOnItsProvider() {
        XCTAssertTrue(
            AgentHookAdmission.admits(
                event(provider: .claude, processGroupID: nil),
                resolution: resolution(provider: .claude, foregroundPID: 99),
                processGroupID: { _ in 4_242 }
            )
        )
        XCTAssertFalse(
            AgentHookAdmission.admits(
                event(provider: .codex, processGroupID: nil),
                resolution: resolution(provider: .claude, foregroundPID: 99),
                processGroupID: { _ in 4_242 }
            )
        )
    }

    // MARK: - Fixture

    private func event(
        provider: AgentProvider,
        processGroupID: UInt64?
    ) -> AgentHookEvent {
        AgentHookEvent(
            paneID: UUID(),
            surfaceToken: UUID(),
            provider: provider,
            sessionID: "session-1",
            transcriptPath: nil,
            hookEventName: "PreToolUse",
            agentID: nil,
            processGroupID: processGroupID,
            activity: AgentHookActivity()
        )
    }

    private func resolution(
        provider: AgentProvider,
        foregroundPID: UInt64
    ) -> AgentLensResolution {
        AgentLensResolution(
            provider: provider,
            sessionID: nil,
            foregroundPID: foregroundPID,
            transcriptURL: nil,
            confidence: .processOnly,
            detail: "fixture"
        )
    }
}
