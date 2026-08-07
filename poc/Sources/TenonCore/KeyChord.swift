// @domain: command-surface
import Foundation

/// A normalized product keybinding that is independent of AppKit and SwiftUI.
public struct KeyChord: Sendable, Hashable {
    public enum Modifier: Int, CaseIterable, Sendable, Hashable {
        case control
        case option
        case shift
        case command
    }

    public enum Key: Sendable, Hashable {
        case character(Character)
        case function(Int)
    }

    public enum ParseError: Error, Sendable, Hashable {
        case empty
        case modifierOnly
        case multipleKeys([String])
        case duplicateModifier(Modifier)
        case unknownToken(String)
        case barePrintable(String)
        case invalidFunctionKey(String)
    }

    public let modifiers: Set<Modifier>
    public let key: Key

    init(modifiers: Set<Modifier>, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    public init(parsing source: String) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.empty
        }

        let tokens = Self.tokens(in: trimmed)
        var parsedModifiers: Set<Modifier> = []
        var parsedKey: (key: Key, token: String)?

        for token in tokens {
            if let modifier = Self.modifier(for: token) {
                guard parsedModifiers.insert(modifier).inserted else {
                    throw ParseError.duplicateModifier(modifier)
                }
                continue
            }

            let key = try Self.key(for: token)
            if let existing = parsedKey {
                throw ParseError.multipleKeys([existing.token, token.lowercased()])
            }
            parsedKey = (key, token.lowercased())
        }

        guard let parsedKey else {
            throw ParseError.modifierOnly
        }
        if parsedModifiers.isEmpty,
           case let .character(character) = parsedKey.key
        {
            throw ParseError.barePrintable(String(character))
        }

        modifiers = parsedModifiers
        key = parsedKey.key
    }

    public var display: String {
        let prefix = Modifier.allCases.compactMap { modifier in
            modifiers.contains(modifier) ? modifier.glyph : nil
        }.joined()
        return prefix + key.display
    }
}

private extension KeyChord {
    static func tokens(in source: String) -> [String] {
        if source.contains("+") {
            return source
                .split(separator: "+", omittingEmptySubsequences: false)
                .map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
        }

        var tokens: [String] = []
        var remainder = ""
        for character in source {
            if let modifier = modifier(for: String(character)) {
                tokens.append(modifier.glyph)
            } else {
                remainder.append(character)
            }
        }
        if !remainder.isEmpty {
            tokens.append(
                remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return tokens
    }

    static func modifier(for token: String) -> Modifier? {
        switch token.lowercased() {
        case "ctrl", "control", "⌃":
            .control
        case "alt", "opt", "option", "⌥":
            .option
        case "shift", "⇧":
            .shift
        case "cmd", "command", "⌘":
            .command
        default:
            nil
        }
    }

    static func key(for token: String) throws -> Key {
        let normalized = token.lowercased()
        if normalized.hasPrefix("f"),
           normalized.dropFirst().allSatisfy(\.isNumber)
        {
            guard let number = Int(normalized.dropFirst()),
                  (1...35).contains(number)
            else {
                throw ParseError.invalidFunctionKey(normalized)
            }
            return .function(number)
        }

        guard normalized.unicodeScalars.count == 1,
              let scalar = normalized.unicodeScalars.first,
              (33...126).contains(scalar.value),
              scalar.value != 43
        else {
            throw ParseError.unknownToken(normalized)
        }
        return .character(Character(normalized))
    }
}

private extension KeyChord.Modifier {
    var glyph: String {
        switch self {
        case .control:
            "⌃"
        case .option:
            "⌥"
        case .shift:
            "⇧"
        case .command:
            "⌘"
        }
    }
}

private extension KeyChord.Key {
    var display: String {
        switch self {
        case .character(let character):
            String(character).uppercased()
        case .function(let number):
            "F\(number)"
        }
    }
}
