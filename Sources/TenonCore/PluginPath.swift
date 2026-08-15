// @domain: plugin-host
import Foundation

/// The pure POSIX path vocabulary exposed to plugins.
///
/// This intentionally does not resolve the filesystem. It mirrors the JavaScript bootstrap's
/// string-only normalizer, including its relative `..` handling and root-safe basename/dirname
/// results, so compiled and JavaScript plugins address the same paths.
public enum PluginPath {
    public static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []

        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." {
                continue
            }
            if part == ".." {
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !absolute {
                    parts.append(part)
                }
            } else {
                parts.append(part)
            }
        }

        let joined = parts.joined(separator: "/")
        if absolute {
            return "/\(joined)" == "/" ? "/" : "/\(joined)"
        }
        return joined.isEmpty ? "." : joined
    }

    public static func join(_ parts: String...) -> String {
        normalize(parts.filter { !$0.isEmpty }.joined(separator: "/"))
    }

    public static func basename(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }
        return normalized.split(separator: "/").last.map(String.init) ?? "."
    }

    public static func dirname(_ path: String) -> String {
        let normalized = normalize(path)
        if normalized == "/" { return "/" }

        var parts = normalized.split(separator: "/").map(String.init)
        parts.removeLast()
        if normalized.hasPrefix("/") {
            return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    public static func extname(_ path: String) -> String {
        let name = basename(path)
        guard let index = name.lastIndex(of: ".") else { return "" }
        if index == name.startIndex { return "" }
        return String(name[index...])
    }
}
