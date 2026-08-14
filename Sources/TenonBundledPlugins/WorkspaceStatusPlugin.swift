// @domain: workspace-model, plugin-contributions
import TenonCore
import TenonIntentCore

enum WorkspaceStatusPlugin {
    static let id: PluginID = "dev.tenon.workspace-status"

    static func makeProgram() -> BundledPluginProgram {
        BundledPluginProgram(
            id: id,
            subscribedEvents: ["workspace.changed"],
            providedIntents: [],
            activate: { _ in
                BundledPluginContribution(statusBarText: "⊞ workspace")
            },
            receiveEvent: { event, payload, _ in
                guard event == "workspace.changed",
                      case let .object(value) = payload,
                      let tabs = value["tabs"]?.wholeNumber,
                      let slots = value["slots"]?.wholeNumber
                else {
                    return nil
                }
                let tabLabel = tabs == 1 ? "tab" : "tabs"
                let slotLabel = slots == 1 ? "slot" : "slots"
                return BundledPluginContribution(
                    statusBarText: "⊞ \(tabs) \(tabLabel) · \(slots) \(slotLabel)"
                )
            },
            invokeIntent: { envelope, _ in
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
        )
    }
}

private extension IntentValue {
    var wholeNumber: Int64? {
        switch self {
        case let .integer(value):
            value
        case let .number(value) where value.isFinite && value.rounded() == value:
            Int64(exactly: value)
        default:
            nil
        }
    }
}
