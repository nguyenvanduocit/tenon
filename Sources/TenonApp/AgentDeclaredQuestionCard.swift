// @domain: agent-control, agent-lens
import AppKit
import SwiftUI
import TenonCore

/// The first-class human surface for `agent.ask.v1`.
///
/// The card is a projection of the pane-owned record only. Choosing an answer calls the
/// same typed store that settles the public intent; no terminal key dialect exists here.
struct AgentDeclaredQuestionCard: View {
    let question: AgentQuestionRecord
    let answer: @MainActor (AgentQuestionChoice) async -> Bool

    @State private var submittedChoiceID: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(TenonTheme.amber)
                    .accessibilityHidden(true)
                Text("Declared question")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TenonTheme.amber)
                Spacer(minLength: 8)
                countdown
            }

            Text(question.question)
                .font(.callout.weight(.medium))
                .foregroundStyle(TenonTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(contextLabel)
                .font(TenonTheme.utilityFont(size: 9.5))
                .foregroundStyle(TenonTheme.muted)
                .lineLimit(1)
                .help("Pane \(question.paneID.uuidString), asked by \(question.asker.id)")

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(question.choices, id: \.id) { choice in
                        Button {
                            submit(choice)
                        } label: {
                            Text(verbatim: choice.label)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(submittedChoiceID != nil)
                        .accessibilityHidden(true)
                        .background {
                            AgentQuestionAccessibilityControl(
                                role: .button,
                                label: choice.label,
                                identifier: "tenon.agentQuestion.choice.\(choice.id)",
                                help: "Answers the declared question without typing into the terminal",
                                isEnabled: submittedChoiceID == nil,
                                press: { submit(choice) }
                            )
                        }
                    }
                }
            }
            .tenonScrollbarStyle()
            .scrollIndicators(.hidden)
            .accessibilityLabel("Declared answers")

            HStack(spacing: 8) {
                Text("Evidence")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TenonTheme.muted)
                ForEach(Array(question.evidence.enumerated()), id: \.offset) { index, item in
                    if let destination = URL(string: item.url) {
                        Link(destination: destination) {
                            Text(verbatim: item.label)
                        }
                        .font(.caption2)
                        .accessibilityHidden(true)
                        .background {
                            AgentQuestionAccessibilityControl(
                                role: .link,
                                label: item.label,
                                identifier: "tenon.agentQuestion.evidence.\(index)",
                                isEnabled: true,
                                press: { openURL(destination) }
                            )
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(TenonTheme.panel, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(TenonTheme.amber.opacity(0.65))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Declared question from \(question.asker.id) in pane \(question.paneID.uuidString)"
        )
        .accessibilityIdentifier("tenon.agentQuestion")
    }

    private var contextLabel: String {
        let pane = question.paneID.uuidString.prefix(8)
        return "Pane \(pane) • \(question.asker.id)"
    }

    private func submit(_ choice: AgentQuestionChoice) {
        guard submittedChoiceID == nil else { return }
        submittedChoiceID = choice.id
        Task {
            guard await answer(choice) else {
                submittedChoiceID = nil
                return
            }
        }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(
                0,
                Int(ceil(question.expiresAt.timeIntervalSince(context.date)))
            )
            Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                .font(TenonTheme.utilityFont(size: 9.5).monospacedDigit())
                .foregroundStyle(remaining == 0 ? TenonTheme.muted : TenonTheme.amber)
                .accessibilityLabel("\(remaining) seconds remaining")
        }
    }
}

private struct AgentQuestionAccessibilityControl: NSViewRepresentable {
    let role: NSAccessibility.Role
    let label: String
    let identifier: String
    var help: String?
    let isEnabled: Bool
    let press: @MainActor () -> Void

    func makeNSView(context _: Context) -> AgentQuestionAccessibilityView {
        AgentQuestionAccessibilityView()
    }

    func updateNSView(_ view: AgentQuestionAccessibilityView, context _: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(role)
        view.setAccessibilityLabel(label)
        view.setAccessibilityTitle(label)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityHelp(help)
        view.setAccessibilityEnabled(isEnabled)
        view.press = press
    }
}

private final class AgentQuestionAccessibilityView: NSView {
    var press: (@MainActor () -> Void)?

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }
}
