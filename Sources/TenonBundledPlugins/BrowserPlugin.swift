// @domain: plugin-host, plugin-contributions
import Foundation
import TenonCore
import TenonIntentCore

/// The compiled browser port keeps the host-owned web surface at the same boundary as the JS
/// implementation: this program only publishes declarative view state and sends browser/workspace
/// intents. It never reaches a WKWebView or decides pane placement itself.
enum BrowserPlugin {
    static let id: PluginID = "dev.tenon.browser"
    private static let viewID = "browser"
    private static let openIntent = try! IntentID("dev.tenon.browser.open.v1")
    private static let openContentIntent = try! IntentID("workspace.content.open.v1")
    private static let loadIntent = try! IntentID("browser.surface.load.v1")
    private static let backIntent = try! IntentID("browser.surface.back.v1")
    private static let forwardIntent = try! IntentID("browser.surface.forward.v1")
    private static let reloadIntent = try! IntentID("browser.surface.reload.v1")

    static func makeProgram() -> BundledPluginProgram {
        let state = BrowserState()
        return BundledPluginProgram(
            id: id,
            subscribedEvents: ["web.did-navigate"],
            providedIntents: [openIntent],
            viewCallbacks: [
                viewID: BundledPluginViewCallbacks(
                    select: { select, context in
                        await state.select(select, context: context)
                    },
                    submit: { submit, context in
                        await state.submit(submit, context: context)
                    },
                    open: { instanceID, context in
                        await state.open(instanceID, context: context)
                    },
                    close: { instanceID, _ in
                        await state.close(instanceID)
                        return nil
                    }
                ),
            ],
            activate: { context in
                await state.configure(
                    homeURL: context.setting("homeURL")?.stringValue
                        ?? "https://duckduckgo.com",
                    searchEngine: context.setting("searchEngine")?.stringValue
                        ?? "https://duckduckgo.com/?q="
                )
                return registration()
            },
            receiveEvent: { event, payload, _ in
                guard event == "web.did-navigate",
                      let object = payload.objectValue,
                      let instanceID = object["surfaceID"]?.stringValue,
                      let url = object["url"]?.stringValue
                else { return nil }
                return await state.didNavigate(instanceID: instanceID, url: url)
            },
            invokeIntent: { envelope, providerContext, _ in
                guard envelope.name == openIntent else {
                    throw PluginRuntimeError.providerHandlerUnavailable(envelope.name)
                }
                let requested = envelope.input.objectValue?["url"]?.stringValue
                let address = await state.resolve(requested)
                await state.setPendingAddress(address)
                let result = await providerContext.send(
                    IntentProviderSendRequest(
                        intentID: openContentIntent,
                        input: .object([
                            "content": .object([
                                "kind": .string("plugin"),
                                "pluginID": .string(id.rawValue),
                                "viewID": .string(viewID),
                            ]),
                        ])
                    )
                )
                switch result {
                case .success:
                    return .success(.object([:]))
                case let .failure(failure):
                    await state.setPendingAddress(nil)
                    return .failure(
                        IntentProviderFailure(
                            code: .kernel(.handlerFailed),
                            details: .object([
                                "message": .string(failure.error.code.rawValue),
                            ])
                        )
                    )
                }
            }
        )
    }

    private static func registration() -> BundledPluginContribution {
        BundledPluginContribution(
            statusBarText: nil,
            viewRegistrations: [
                BundledPluginViewRegistration(
                    viewID: viewID,
                    title: "Browser",
                    instanced: true
                ),
            ]
        )
    }

    private actor BrowserState {
        private var homeURL = "https://duckduckgo.com"
        private var searchEngine = "https://duckduckgo.com/?q="
        private var pendingAddress: String?
        private var panes: [String: String] = [:]

        func configure(homeURL: String, searchEngine: String) {
            self.homeURL = homeURL
            self.searchEngine = searchEngine
        }

        func setPendingAddress(_ address: String?) {
            pendingAddress = address
        }

        func resolve(_ input: String?) -> String? {
            let value = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if value.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) != nil {
                return value
            }
            if value.range(of: "^[^\\s]+\\.[^\\s]{2,}(/.*)?$", options: .regularExpression) != nil {
                return "https://" + value
            }
            return searchEngine + (value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)
        }

        func open(_ instanceID: String, context: BundledPluginContext) async -> BundledPluginContribution? {
            let address = pendingAddress ?? homeURL
            pendingAddress = nil
            panes[instanceID] = address
            let result = await send(
                loadIntent,
                input: .object([
                    "surfaceID": .string(instanceID),
                    "url": .string(address),
                ]),
                context: context
            )
            if case let .failure(failure) = result {
                await context.log("browser: initial load failed: \(failure.error.code.rawValue)")
            }
            return contribution(for: instanceID)
        }

        func close(_ instanceID: String) {
            panes.removeValue(forKey: instanceID)
        }

        func submit(
            _ submit: BundledPluginViewSubmit,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            guard submit.itemID == "go",
                  let instanceID = submit.instanceID,
                  let address = resolve(submit.text),
                  panes[instanceID] != nil
            else { return nil }
            let result = await send(
                loadIntent,
                input: .object([
                    "surfaceID": .string(instanceID),
                    "url": .string(address),
                ]),
                context: context
            )
            guard case .success = result else {
                if case let .failure(failure) = result {
                    await context.log("browser: navigation failed: \(failure.error.code.rawValue)")
                }
                return nil
            }
            panes[instanceID] = address
            return contribution(for: instanceID)
        }

        func select(
            _ select: BundledPluginViewSelect,
            context: BundledPluginContext
        ) async -> BundledPluginContribution? {
            guard let instanceID = select.instanceID,
                  panes[instanceID] != nil
            else { return nil }
            let intent: IntentID?
            switch select.itemID {
            case "back": intent = backIntent
            case "forward": intent = forwardIntent
            case "reload": intent = reloadIntent
            default: intent = nil
            }
            guard let intent else { return nil }
            let result = await send(
                intent,
                input: .object(["surfaceID": .string(instanceID)]),
                context: context
            )
            if case let .failure(failure) = result {
                await context.log("browser: navigation failed: \(failure.error.code.rawValue)")
            }
            return nil
        }

        func didNavigate(instanceID: String, url: String) -> BundledPluginContribution? {
            guard panes[instanceID] != nil else { return nil }
            panes[instanceID] = url
            return contribution(for: instanceID)
        }

        private func contribution(for instanceID: String) -> BundledPluginContribution {
            BundledPluginContribution(
                statusBarText: nil,
                viewRegistrations: [
                    BundledPluginViewRegistration(
                        viewID: viewID,
                        title: "Browser",
                        instanced: true
                    ),
                ],
                viewBodies: [
                    BundledPluginViewBody(
                        viewID: viewID,
                        instanceID: instanceID,
                        body: .webview(surfaceID: instanceID),
                        header: header(address: panes[instanceID] ?? homeURL)
                    ),
                ]
            )
        }

        private func header(address: String) -> PaneHeader {
            PaneHeader(
                leading: [
                    .iconButton(id: "back", systemName: "chevron.left", tint: .default, isEnabled: true, tooltip: "Back", accessibilityID: nil),
                    .iconButton(id: "forward", systemName: "chevron.right", tint: .default, isEnabled: true, tooltip: "Forward", accessibilityID: nil),
                    .iconButton(id: "reload", systemName: "arrow.clockwise", tint: .default, isEnabled: true, tooltip: "Reload", accessibilityID: nil),
                ],
                trailing: [
                    .textfield(id: "go", value: address, placeholder: "Search or enter website", flex: true, isEnabled: true, accessibilityID: nil),
                ]
            )
        }

        private func send(
            _ intentID: IntentID,
            input: IntentValue,
            context: BundledPluginContext
        ) async -> IntentResult {
            await context.intents.send(
                PluginIntentSendRequest(intentID: intentID, input: input)
            )
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
}
