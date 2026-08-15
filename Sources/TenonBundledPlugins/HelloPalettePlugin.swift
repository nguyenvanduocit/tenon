// @domain: plugin-host, plugin-events
import TenonCore
import TenonIntentCore

/// The smallest compiled provider: its state is generation-owned and its log is the only
/// product effect, so the plugin never needs a second command surface.
enum HelloPalettePlugin {
    static let id: PluginID = "dev.tenon.hello-palette"
    private static let greet = try! IntentID("dev.tenon.hello-palette.greet.v1")
    private static let reset = try! IntentID("dev.tenon.hello-palette.reset.v1")

    static func makeProgram() -> BundledPluginProgram {
        let state = State()
        return BundledPluginProgram(
            id: id,
            subscribedEvents: ["terminal.title-changed"],
            providedIntents: [greet, reset],
            activate: { _ in
                BundledPluginContribution(statusBarText: "palette: 2 intents")
            },
            receiveEvent: { event, payload, context in
                guard event == "terminal.title-changed",
                      case let .object(fields) = payload,
                      case let .string(title)? = fields["title"]
                else { return nil }
                await context.log("terminal title → \(title)")
                return nil
            },
            invokeIntent: { envelope, _, context in
                switch envelope.name {
                case greet:
                    let count = await state.greet()
                    await context.log("hello #\(count) 👋")
                    return .success(.object([:]))
                case reset:
                    await state.reset()
                    await context.log("counter reset")
                    return .success(.object([:]))
                default:
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
            }
        )
    }

    private actor State {
        private var count = 0

        func greet() -> Int {
            count += 1
            return count
        }

        func reset() {
            count = 0
        }
    }
}
