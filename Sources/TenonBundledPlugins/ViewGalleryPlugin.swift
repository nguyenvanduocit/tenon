// @domain: plugin-host, plugin-contributions
import TenonCore
import TenonIntentCore

/// A compiled counterpart of the view-gallery fixture. Its view is declarative data; the shell
/// still owns rendering and each demo still crosses the intent bus for its answer.
enum ViewGalleryPlugin {
    static let id: PluginID = "dev.tenon.view-gallery"
    private static let viewID = "gallery"

    static func makeProgram() -> BundledPluginProgram {
        let state = State()
        return BundledPluginProgram(
            id: id,
            subscribedEvents: [],
            providedIntents: [],
            viewCallbacks: [
                viewID: BundledPluginViewCallbacks(
                    select: { select, context in
                        await state.select(select.action, context: context)
                    }
                ),
            ],
            activate: { _ in await state.contribution() },
            receiveEvent: { _, _, _ in nil },
            invokeIntent: { envelope, _, _ in
                throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
            }
        )
    }

    private actor State {
        private var reruns = 0
        private var lastAnswer = "—"

        func select(
            _ action: PluginNodeAction,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            if action.stringValue == "rerun" {
                reruns += 1
                await context.log("rerun #\(reruns)")
                return contribution()
            }
            guard case let .structured(.object(fields)) = action,
                  let demo = fields["demo"]?.stringValue
            else { return nil }
            await runDemo(demo, context: context)
            return contribution()
        }

        func contribution() -> BundledPluginContribution {
            BundledPluginContribution(
                viewRegistrations: [
                    BundledPluginViewRegistration(
                        viewID: viewID,
                        title: "Gallery",
                        instanced: false
                    ),
                ],
                viewBodies: [
                    BundledPluginViewBody(
                        viewID: viewID,
                        instanceID: nil,
                        body: body()
                    ),
                ]
            )
        }

        private func runDemo(_ demo: String, context: BundledPluginContext) async {
            switch demo {
            case "pick":
                let result = await context.intents.send(
                    PluginIntentSendRequest(
                        intentID: try! IntentID("ui.pick.v1"),
                        input: .object([
                            "items": .array([
                                .object(["id": .string("main"), "label": .string("main"), "detail": .string("current"), "icon": .string("arrow.triangle.branch")]),
                                .object(["id": .string("dev"), "label": .string("dev"), "detail": .string("2 ahead"), "icon": .string("arrow.triangle.branch")]),
                                .object(["id": .string("release"), "label": .string("release/1.0"), "icon": .string("tag")]),
                            ]),
                            "placeholder": .string("Pick a branch"),
                        ])
                    )
                )
                lastAnswer = successValue(result)?.objectValue?["selectedID"]?.stringValue ?? "dismissed"
            case "prompt":
                let result = await context.intents.send(
                    PluginIntentSendRequest(
                        intentID: try! IntentID("ui.prompt.v1"),
                        input: .object([
                            "title": .string("Commit message"),
                            "initialValue": .string("wip: "),
                            "multiline": .bool(true),
                        ])
                    )
                )
                if let value = successValue(result)?.objectValue?["value"] {
                    lastAnswer = value.stringValue.map { "\(String(reflecting: $0))" } ?? "dismissed"
                } else {
                    lastAnswer = "dismissed"
                }
            case "confirm":
                let result = await context.intents.send(
                    PluginIntentSendRequest(
                        intentID: try! IntentID("ui.confirm.v1"),
                        input: .object([
                            "title": .string("Discard 3 files?"),
                            "destructive": .bool(true),
                        ])
                    )
                )
                lastAnswer = successValue(result)?.objectValue?["confirmed"]?.boolValue == true
                    ? "confirmed"
                    : "cancelled"
            case "toast":
                let result = await context.intents.send(
                    PluginIntentSendRequest(
                        intentID: try! IntentID("ui.toast.v1"),
                        input: .object([
                            "message": .string("That is a toast — it expires on its own."),
                            "kind": .string("success"),
                        ])
                    )
                )
                lastAnswer = successValue(result) == nil ? "toast failed" : "toast shown"
            default:
                return
            }
        }

        private func body() -> PluginViewNode {
            .vstack(spacing: 10, children: [
                .text("Component gallery", style: .title, weight: .semibold, color: .default),
                .text("Tokens map to the app theme — light/dark is automatic.", style: .caption, weight: .regular, color: .muted),
                .card(children: [
                    .hstack(spacing: 8, children: [
                        .text("Build", style: .body, weight: .semibold, color: .default),
                        .spacer,
                        .badge("passing", tint: .green),
                    ]),
                    .text("1,204 tests · 2.1s", style: .caption, weight: .regular, color: .muted),
                    .divider,
                    .hstack(spacing: 6, children: [
                        .badge("main", tint: .amber),
                        .badge("\(reruns) reruns", tint: .muted),
                        .spacer,
                        .button(label: "Rerun", action: "rerun", style: .primary),
                    ]),
                ]),
                .card(children: [
                    .text("Status components", style: .body, weight: .semibold, color: .default),
                    .grid(columns: 2, spacing: 10, children: [
                        .stat(label: "Tests", value: "1204"),
                        .stat(label: "Duration", value: "2.1s"),
                    ]),
                    .divider,
                    .keyValue(label: "Branch", value: "main", tint: .green),
                    .keyValue(label: "Ahead / behind", value: "2 / 0", tint: .amber),
                    .field(label: "Coverage", children: [
                        .progress(value: 0.86, tint: .green),
                        .text("86%", style: .caption, weight: .regular, color: .muted),
                    ]),
                ]),
                .card(children: [
                    .text("Asking the user", style: .body, weight: .semibold, color: .default),
                    .text("UI intents describe the question; the shell draws it and returns one typed result.", style: .caption, weight: .regular, color: .muted),
                    .hstack(spacing: 6, children: [
                        .button(label: "Pick", action: .structured(.object(["demo": .string("pick")])), style: .plain),
                        .button(label: "Prompt", action: .structured(.object(["demo": .string("prompt")])), style: .plain),
                        .button(label: "Confirm", action: .structured(.object(["demo": .string("confirm")])), style: .plain),
                        .button(label: "Toast", action: .structured(.object(["demo": .string("toast")])), style: .plain),
                        .spacer,
                    ]),
                    .keyValue(label: "Last answer", value: lastAnswer, tint: .amber),
                ]),
                .card(children: [
                    .text("Composability", style: .body, weight: .semibold, color: .default),
                    .text("vstack + hstack + box + grid + text + badge + button + stat + keyValue + progress + field — enough to build most panels without waiting on the host.", style: .body, weight: .regular, color: .muted),
                ]),
            ])
        }

        private func successValue(_ result: IntentResult) -> IntentValue? {
            guard case let .success(success) = result else { return nil }
            return success.value
        }
    }
}

private extension IntentValue {
    var objectValue: [String: IntentValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}
