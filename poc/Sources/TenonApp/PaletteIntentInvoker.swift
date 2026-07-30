import Foundation
import TenonCore
import TenonIntentCore

struct PaletteIntentInvocation: Sendable, Equatable {
    let target: KeyBindingTarget
    let providerID: ProviderID
    let userGestureID: UUID
}

/// The single app-side adapter for invoking a plugin-owned palette intent.
///
/// Palette clicks and manifest keybindings both target the declaring plugin
/// provider and mint a new gesture at the moment the action is accepted.
@MainActor
enum PaletteIntentInvoker {
    static func prepare(
        target: KeyBindingTarget,
        expectedBinding: KeyBinding? = nil,
        host: PluginHost
    ) -> PaletteIntentInvocation? {
        if let expectedBinding,
           host.keyBindingIndex.binding(for: target) != expectedBinding
        {
            return nil
        }
        guard host.intentPresentation(for: target) != nil,
              let providerID = try? ProviderID(target.pluginID.rawValue)
        else {
            return nil
        }
        return PaletteIntentInvocation(
            target: target,
            providerID: providerID,
            userGestureID: UUID()
        )
    }

    static func send(
        target: KeyBindingTarget,
        expectedBinding: KeyBinding? = nil,
        host: PluginHost,
        runtime: AppIntentRuntime
    ) async -> IntentResult? {
        guard let invocation = prepare(
            target: target,
            expectedBinding: expectedBinding,
            host: host
        ) else {
            return nil
        }
        return await runtime.send(
            invocation.target.intentID,
            as: AppIntentRuntime.palettePrincipal,
            target: invocation.providerID,
            userGestureID: invocation.userGestureID
        )
    }
}
