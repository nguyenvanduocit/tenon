// @domain: workspace-model
import Darwin
import Foundation

/// Serializes a complete file transaction across actors and processes.
///
/// The lock lives at a stable sibling path because an atomic write replaces the data file's
/// inode. Locking the data file itself would therefore stop coordinating readers that opened
/// different generations of that inode.
enum DurableJSONFile {
    enum LockError: Error, Sendable {
        case open(code: Int32)
        case acquire(code: Int32)
    }

    static func withExclusiveLock<Result>(
        for dataURL: URL,
        _ operation: () throws -> Result
    ) throws -> Result {
        let lockURL = dataURL.appendingPathExtension("lock")
        let descriptor: Int32 = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return Int32(-1)
            }
            return Darwin.open(
                path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw LockError.open(code: errno)
        }
        defer {
            _ = Darwin.close(descriptor)
        }

        let applyLock: (Int32, Int32) -> Int32 = flock
        while applyLock(descriptor, LOCK_EX) == -1 {
            guard errno == EINTR else {
                throw LockError.acquire(code: errno)
            }
        }
        defer {
            _ = applyLock(descriptor, LOCK_UN)
        }

        return try operation()
    }

    static func posixDetails(
        for error: any Error
    ) -> (domain: String, code: Int)? {
        switch error {
        case let LockError.open(code), let LockError.acquire(code):
            return (NSPOSIXErrorDomain, Int(code))
        default:
            return nil
        }
    }
}

/// Syntax and duplicate-key validation performed before typed decoding.
///
/// Foundation decoders intentionally collapse duplicate object keys. Persisted state uses
/// fail-closed semantics instead: an ambiguous object is corrupt, including escaped spellings
/// of the same key such as `"a"` and `"\u0061"`.
enum StrictJSONDocument {
    enum ValidationError: Error, Sendable {
        case invalidSyntax
        case duplicateKey
        case maximumDepthExceeded
    }

    static let maximumNestingDepth = 64

    private struct VersionEnvelope: Decodable {
        let version: Int
    }

    static func topLevelVersion(in data: Data) throws -> Int {
        var parser = Parser(
            bytes: Array(data),
            maximumDepth: maximumNestingDepth
        )
        try parser.validate()
        do {
            return try JSONDecoder().decode(VersionEnvelope.self, from: data).version
        } catch {
            throw ValidationError.invalidSyntax
        }
    }
}

private extension StrictJSONDocument {
    struct Parser {
        let bytes: [UInt8]
        let maximumDepth: Int
        var index = 0

        mutating func validate() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else {
                throw ValidationError.invalidSyntax
            }
        }

        mutating func parseValue(depth: Int) throws {
            guard depth <= maximumDepth else {
                throw ValidationError.maximumDepthExceeded
            }
            guard let byte = current else {
                throw ValidationError.invalidSyntax
            }
            switch byte {
            case UInt8(ascii: "{"):
                try parseObject(depth: depth)
            case UInt8(ascii: "["):
                try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                _ = try parseString()
            case UInt8(ascii: "t"):
                try consumeLiteral("true")
            case UInt8(ascii: "f"):
                try consumeLiteral("false")
            case UInt8(ascii: "n"):
                try consumeLiteral("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                try parseNumber()
            default:
                throw ValidationError.invalidSyntax
            }
        }

        mutating func parseObject(depth: Int) throws {
            try consume(UInt8(ascii: "{"))
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "}")) {
                return
            }

            var keys: Set<String> = []
            while true {
                guard current == UInt8(ascii: "\"") else {
                    throw ValidationError.invalidSyntax
                }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw ValidationError.duplicateKey
                }

                skipWhitespace()
                try consume(UInt8(ascii: ":"))
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()

                if consumeIfPresent(UInt8(ascii: "}")) {
                    return
                }
                try consume(UInt8(ascii: ","))
                skipWhitespace()
            }
        }

        mutating func parseArray(depth: Int) throws {
            try consume(UInt8(ascii: "["))
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "]")) {
                return
            }

            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIfPresent(UInt8(ascii: "]")) {
                    return
                }
                try consume(UInt8(ascii: ","))
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            try consume(UInt8(ascii: "\""))

            while let byte = current {
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    let encoded = Data(bytes[start..<index])
                    do {
                        return try JSONDecoder().decode(String.self, from: encoded)
                    } catch {
                        throw ValidationError.invalidSyntax
                    }
                case UInt8(ascii: "\\"):
                    index += 1
                    try parseEscape()
                case 0x00...0x1F:
                    throw ValidationError.invalidSyntax
                default:
                    index += 1
                }
            }
            throw ValidationError.invalidSyntax
        }

        mutating func parseEscape() throws {
            guard let byte = current else {
                throw ValidationError.invalidSyntax
            }
            switch byte {
            case UInt8(ascii: "\""),
                 UInt8(ascii: "\\"),
                 UInt8(ascii: "/"),
                 UInt8(ascii: "b"),
                 UInt8(ascii: "f"),
                 UInt8(ascii: "n"),
                 UInt8(ascii: "r"),
                 UInt8(ascii: "t"):
                index += 1
            case UInt8(ascii: "u"):
                index += 1
                for _ in 0..<4 {
                    guard let hex = current, Self.isHexDigit(hex) else {
                        throw ValidationError.invalidSyntax
                    }
                    index += 1
                }
            default:
                throw ValidationError.invalidSyntax
            }
        }

        mutating func parseNumber() throws {
            _ = consumeIfPresent(UInt8(ascii: "-"))
            guard let first = current else {
                throw ValidationError.invalidSyntax
            }

            if first == UInt8(ascii: "0") {
                index += 1
                if let next = current, Self.isDigit(next) {
                    throw ValidationError.invalidSyntax
                }
            } else {
                guard first >= UInt8(ascii: "1"),
                      first <= UInt8(ascii: "9")
                else {
                    throw ValidationError.invalidSyntax
                }
                index += 1
                consumeDigits()
            }

            if consumeIfPresent(UInt8(ascii: ".")) {
                guard let next = current, Self.isDigit(next) else {
                    throw ValidationError.invalidSyntax
                }
                consumeDigits()
            }

            if consumeIfPresent(UInt8(ascii: "e"))
                || consumeIfPresent(UInt8(ascii: "E"))
            {
                _ = consumeIfPresent(UInt8(ascii: "+"))
                    || consumeIfPresent(UInt8(ascii: "-"))
                guard let next = current, Self.isDigit(next) else {
                    throw ValidationError.invalidSyntax
                }
                consumeDigits()
            }
        }

        mutating func consumeDigits() {
            while let byte = current, Self.isDigit(byte) {
                index += 1
            }
        }

        mutating func consumeLiteral(_ literal: StaticString) throws {
            for byte in literal.withUTF8Buffer({ Array($0) }) {
                try consume(byte)
            }
        }

        mutating func consume(_ expected: UInt8) throws {
            guard current == expected else {
                throw ValidationError.invalidSyntax
            }
            index += 1
        }

        mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
            guard current == expected else {
                return false
            }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while let byte = current {
                switch byte {
                case UInt8(ascii: " "),
                     UInt8(ascii: "\t"),
                     UInt8(ascii: "\n"),
                     UInt8(ascii: "\r"):
                    index += 1
                default:
                    return
                }
            }
        }

        var current: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        static func isHexDigit(_ byte: UInt8) -> Bool {
            isDigit(byte)
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
        }
    }
}
