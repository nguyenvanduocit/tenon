// @domain: automation, plugin-contributions
import Foundation
import TenonCore
import TenonIntentCore

enum ClockPlugin {
    static let id: PluginID = "dev.tenon.clock"

    static func makeProgram() -> BundledPluginProgram {
        BundledPluginProgram(
            id: id,
            subscribedEvents: ["automation.fired"],
            providedIntents: [],
            activate: { _ in contribution(at: Date()) },
            receiveEvent: { event, _, _ in
                event == "automation.fired" ? contribution(at: Date()) : nil
            },
            invokeIntent: { envelope, _ in
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
        )
    }

    private static func contribution(at date: Date) -> BundledPluginContribution {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return BundledPluginContribution(
            statusBarText: String(format: "🕐 %02d:%02d", hour, minute)
        )
    }
}
