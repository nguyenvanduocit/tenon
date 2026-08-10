// @domain: command-surface
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

    static func prepare(
        commandID: String,
        host: PluginHost
    ) -> PaletteIntentInvocation? {
        guard let presentation = host.intentPresentations.first(
            where: { $0.intentID.rawValue == commandID }
        ) else {
            return nil
        }
        return prepare(
            target: KeyBindingTarget(
                pluginID: presentation.pluginID,
                intentID: presentation.intentID
            ),
            host: host
        )
    }

    /// Invoke a ranked command by its ID against the focused pane. `nil` means the intent
    /// went away between ranking and clicking (a plugin unloaded mid-session).
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
            as: AppIntentRuntime.userPrincipal,
            target: providerID,
            userGestureID: UUID()
        )
    }

    /// Invoke a ranked command against a caller-named scope instead of the focused pane.
    ///
    /// The palette's convenience overload inherits the selected workspace, tab, and
    /// pane. An anchored launcher has stronger placement meaning: the title-bar `+` names its
    /// freshly created tab, while a tab right-click names that tab even when it is not
    /// selected. This is the entry point
    /// `AppIntentRuntime.send(_:input:as:scope:…)` documents: authority visible at the
    /// call site rather than inherited from mutable UI state.
    static func send(
        commandID: String,
        scope: InvocationScope,
        host: PluginHost,
        runtime: AppIntentRuntime
    ) async -> IntentResult? {
        guard let invocation = prepare(commandID: commandID, host: host) else { return nil }
        return await send(invocation, scope: scope, runtime: runtime)
    }

    /// Sends a command that was prepared at the click boundary. Placement helpers use
    /// the same host-minted gesture both to reserve a destination and to dispatch the
    /// intent, so another invocation sharing the pane cannot claim that reservation.
    static func send(
        _ invocation: PaletteIntentInvocation,
        scope: InvocationScope,
        runtime: AppIntentRuntime
    ) async -> IntentResult {
        return await runtime.send(
            invocation.target.intentID,
            as: AppIntentRuntime.userPrincipal,
            scope: InvocationScope(
                workspaceID: scope.workspaceID,
                tabID: scope.tabID,
                paneID: scope.paneID,
                // `prepare` minted this proof at the accepted click boundary, exactly as
                // the unscoped path does — a caller cannot supply one.
                userGestureID: invocation.userGestureID
            ),
            target: invocation.providerID
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
            as: AppIntentRuntime.userPrincipal,
            target: invocation.providerID,
            userGestureID: invocation.userGestureID
        )
    }
}
