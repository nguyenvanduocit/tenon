import SwiftUI
import TenonCore

@MainActor
struct PluginKeyBindingCommands: Commands {
    @Bindable private var host: PluginHost
    private let intentRuntime: AppIntentRuntime

    init(host: PluginHost, intentRuntime: AppIntentRuntime) {
        self.host = host
        self.intentRuntime = intentRuntime
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            ForEach(host.keyBindingIndex.bindings) { binding in
                if let presentation = host.intentPresentation(
                    for: binding.target
                ) {
                    Button(presentation.title) {
                        invoke(binding)
                    }
                    .keyboardShortcut(
                        binding.chord.keyEquivalent,
                        modifiers: binding.chord.eventModifiers
                    )
                }
            }
        }
    }

    private func invoke(_ binding: KeyBinding) {
        Task { @MainActor in
            let result = await PaletteIntentInvoker.send(
                target: binding.target,
                expectedBinding: binding,
                host: host,
                runtime: intentRuntime
            )
            if case .failure(let failure) = result {
                host.appendLog(
                    "keybinding: \(binding.target.intentID.rawValue) failed: "
                        + failure.error.code.rawValue
                )
            }
        }
    }
}

private extension KeyChord {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let character):
            return KeyEquivalent(character)
        case .function(let number):
            let scalar = UnicodeScalar(0xF703 + number)!
            return KeyEquivalent(Character(scalar))
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.control) {
            result.insert(.control)
        }
        if modifiers.contains(.option) {
            result.insert(.option)
        }
        if modifiers.contains(.shift) {
            result.insert(.shift)
        }
        if modifiers.contains(.command) {
            result.insert(.command)
        }
        return result
    }
}
