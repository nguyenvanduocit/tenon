// @domain: agent-control
import SwiftUI
import TenonCore

/// What a recorded pane shows where a live pane shows its terminal.
///
/// The pane genuinely holds no PTY, so this is not a placeholder for a terminal that is
/// loading — it is the honest state of the pane, and the one control that changes it. Pressing
/// `+ Resume` converts THIS pane rather than opening a second one: the session the person is
/// reading and the session they continue are the same session, and two panes claiming it
/// would immediately disagree about which is current.
struct AgentSessionResumeView: View {
    let ref: AgentSessionRef
    /// Precomputed, so the button can state its reason before it is pressed rather than
    /// failing under it.
    let offer: AgentSessionResumeOffer
    let resume: @MainActor (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("This session has already happened")
                .font(.callout.weight(.medium))
                .foregroundStyle(TenonTheme.text)
            Text(
                "The reading beside this tab is the recorded transcript. "
                    + "No shell is running in this pane."
            )
            .font(.caption)
            .foregroundStyle(TenonTheme.muted)
            .multilineTextAlignment(.center)

            switch offer {
            case .ready(let commandLine):
                Button("+ Resume") { resume(commandLine) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(commandLine)
                    .accessibilityIdentifier("tenon.agentSession.resume")
            case .unavailable(let reason):
                // The refusal is drawn where the button would have been, carrying the reason
                // rather than a disabled control that explains nothing.
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(TenonTheme.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("tenon.agentSession.resumeUnavailable")
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TenonTheme.ink)
    }
}
