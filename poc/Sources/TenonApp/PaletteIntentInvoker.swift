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

    /// Invoke a ranked command by its ID — the path both command surfaces take: the
    /// palette (⌘⇧P) and the tab strip's `+` launcher. `nil` means the intent went away
    /// between ranking and clicking (a plugin unloaded mid-session).
    static func send(
        commandID: String,
        host: PluginHost,
        runtime: AppIntentRuntime
    ) async -> IntentResult? {
        guard let presentation = host.intentPresentations.first(
            where: { $0.intentID.rawValue == commandID }
        ) else {
            return nil
        }
        return await send(
            target: KeyBindingTarget(
                pluginID: presentation.pluginID,
                intentID: presentation.intentID
            ),
            host: host,
            runtime: runtime
        )
    }

    /// Invoke a dynamic palette result (or one of its ⌘K actions) by its declared
    /// intent designation. The same production dispatcher path as a static row — the
    /// palette principal, the publishing plugin as provider, a freshly minted gesture —
    /// with the result's bounded input attached. `nil` means the plugin went away
    /// between publication and the click.
    static func send(
        intentID: IntentID,
        input: IntentValue,
        pluginID: PluginID,
        host: PluginHost,
        runtime: AppIntentRuntime
    ) async -> IntentResult? {
        guard host.plugins.first(where: { $0.id == pluginID })?.isLoaded == true,
              let providerID = try? ProviderID(pluginID.rawValue)
        else {
            return nil
        }
        return await runtime.send(
            intentID,
            input: input,
            as: AppIntentRuntime.palettePrincipal,
            target: providerID,
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
