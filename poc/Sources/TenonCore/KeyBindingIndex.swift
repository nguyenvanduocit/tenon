// @domain: command-surface
import Foundation
import TenonIntentCore

public struct KeyBindingTarget: Sendable, Hashable, Comparable {
    public let pluginID: PluginID
    public let intentID: IntentID

    public init(pluginID: PluginID, intentID: IntentID) {
        self.pluginID = pluginID
        self.intentID = intentID
    }

    public static func < (
        lhs: KeyBindingTarget,
        rhs: KeyBindingTarget
    ) -> Bool {
        if lhs.pluginID != rhs.pluginID {
            return lhs.pluginID.rawValue < rhs.pluginID.rawValue
        }
        return lhs.intentID.rawValue < rhs.intentID.rawValue
    }
}

public struct KeyBindingRequest: Sendable, Hashable {
    public let target: KeyBindingTarget
    public let rawKey: String

    public init(target: KeyBindingTarget, rawKey: String) {
        self.target = target
        self.rawKey = rawKey
    }
}

public struct KeyBinding: Sendable, Hashable, Identifiable {
    public let target: KeyBindingTarget
    public let chord: KeyChord

    public init(target: KeyBindingTarget, chord: KeyChord) {
        self.target = target
        self.chord = chord
    }

    public var id: KeyBindingTarget {
        target
    }
}

public enum KeyBindingDiagnostic: Sendable, Hashable {
    case invalid(
        request: KeyBindingRequest,
        error: KeyChord.ParseError
    )
    case reserved(
        request: KeyBindingRequest,
        chord: KeyChord
    )
    case conflict(
        request: KeyBindingRequest,
        winner: KeyBindingTarget,
        chord: KeyChord
    )
}

/// Pure conflict resolution for manifest-contributed product keybindings.
public struct KeyBindingIndex: Sendable, Equatable {
    /// Chords owned by the native application shell rather than product intents.
    ///
    /// Product actions such as tab and pane operations are deliberately absent:
    /// their manifests own those bindings and SwiftUI only projects the winners.
    public static let shellReserved: Set<KeyChord> = [
        KeyChord(
            modifiers: [.command, .shift],
            key: .character("p")
        ),
        KeyChord(modifiers: [.command], key: .character(",")),
        KeyChord(modifiers: [.command], key: .character("q")),
        KeyChord(modifiers: [.command], key: .character("h")),
        KeyChord(
            modifiers: [.option, .command],
            key: .character("h")
        ),
        KeyChord(modifiers: [.command], key: .character("m")),
    ]

    public let bindings: [KeyBinding]
    public let diagnostics: [KeyBindingDiagnostic]

    public init(
        requests: [KeyBindingRequest],
        reserved: Set<KeyChord>
    ) {
        let ordered = requests.sorted {
            if $0.target != $1.target {
                return $0.target < $1.target
            }
            return $0.rawKey < $1.rawKey
        }
        var accepted: [KeyBinding] = []
        var acceptedByChord: [KeyChord: KeyBinding] = [:]
        var rejected: [KeyBindingDiagnostic] = []

        for request in ordered {
            let chord: KeyChord
            do {
                chord = try KeyChord(parsing: request.rawKey)
            } catch let error as KeyChord.ParseError {
                rejected.append(.invalid(request: request, error: error))
                continue
            } catch {
                preconditionFailure("KeyChord exposes only typed parse errors")
            }

            if reserved.contains(chord) {
                rejected.append(.reserved(request: request, chord: chord))
                continue
            }
            if let winner = acceptedByChord[chord] {
                rejected.append(
                    .conflict(
                        request: request,
                        winner: winner.target,
                        chord: chord
                    )
                )
                continue
            }

            let binding = KeyBinding(target: request.target, chord: chord)
            accepted.append(binding)
            acceptedByChord[chord] = binding
        }

        bindings = accepted
        diagnostics = rejected
    }

    public func binding(for chord: KeyChord) -> KeyBinding? {
        bindings.first { $0.chord == chord }
    }

    public func binding(for target: KeyBindingTarget) -> KeyBinding? {
        bindings.first { $0.target == target }
    }
}
