import Foundation

/// A deliberately tiny YAML reader for the configuration files of Lima, Colima and similar tools.
///
/// It understands exactly what PulseDeck needs and nothing else:
/// - top-level `key: scalar` pairs (`cpus: 4`, `memory: "4GiB"`, `vmType: vz`), with `#` comments,
///   single/double quoted values and `null` / `~` / empty values;
/// - one level of nested mappings (`network:` → `  address: true`), read with `nested(_:_:)`;
/// - everything else (lists, anchors, block scalars, deeper nesting, flow collections) is skipped,
///   never mis-read: such keys have the value `.block`/`.flow`.
///
/// Anything that cannot be understood yields `nil`; callers then show "unknown", never a guess.
public struct SimpleYAML: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        /// A plain or quoted scalar (without quotes).
        case scalar(String)
        /// `null`, `~` or no value at all.
        case null
        /// A nested mapping, sequence or block scalar follows (read nested scalars with `nested`).
        case block
        /// A flow collection on the same line (`[a, b]`, `{}`), kept verbatim.
        case flow(String)
    }

    public private(set) var topLevel: [String: Value] = [:]
    private var nestedScalars: [String: [String: Value]] = [:]

    public init(parsing text: String) {
        var currentParent: String?
        var childIndent: Int?
        var documentsSeen = 0

        // `isNewline` also splits "\r\n", which Swift treats as ONE character.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "---" || trimmed.hasPrefix("--- ") {
                documentsSeen += 1
                // Only the first document is read.
                if documentsSeen > 1 || !topLevel.isEmpty { break }
                continue
            }
            if trimmed == "..." { break }

            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                currentParent = nil
                childIndent = nil
                guard let (key, value) = Self.splitPair(trimmed) else { continue }
                topLevel[key] = value
                if value == .block { currentParent = key }
            } else if let parent = currentParent {
                // Only direct children of the first nested level; list items start with "- ".
                if let expected = childIndent, indent != expected { continue }
                guard !trimmed.hasPrefix("-"), let (key, value) = Self.splitPair(trimmed) else { continue }
                childIndent = indent
                nestedScalars[parent, default: [:]][key] = value
            }
        }
    }

    // MARK: - Typed reads

    public func value(_ key: String) -> Value? { topLevel[key] }

    /// The scalar of a top-level key; `nil` for missing, `null`, nested or flow values.
    public func string(_ key: String) -> String? {
        if case .scalar(let text)? = topLevel[key] { text } else { nil }
    }

    public func int(_ key: String) -> Int? { string(key).flatMap(Self.integer) }
    public func double(_ key: String) -> Double? { string(key).flatMap(Self.number) }
    public func bool(_ key: String) -> Bool? { string(key).flatMap(Self.boolean) }

    /// A scalar one level down: `nested("network", "address")`.
    public func nested(_ parent: String, _ key: String) -> String? {
        if case .scalar(let text)? = nestedScalars[parent]?[key] { text } else { nil }
    }

    public func nestedBool(_ parent: String, _ key: String) -> Bool? { nested(parent, key).flatMap(Self.boolean) }
    public func nestedInt(_ parent: String, _ key: String) -> Int? { nested(parent, key).flatMap(Self.integer) }

    // MARK: - Scalar interpretation

    static func integer(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        // "4.0" is a valid YAML float that a human may still mean as 4.
        if let value = Double(text), value.rounded() == value, abs(value) < 1e15 { return Int(value) }
        return nil
    }

    static func number(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    static func boolean(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "yes", "on": true
        case "false", "no", "off": false
        default: nil
        }
    }

    // MARK: - Line parsing

    /// Splits `key: value # comment` into the key and its interpreted value.
    private static func splitPair(_ trimmed: String) -> (String, Value)? {
        guard let separator = colonIndex(in: trimmed) else { return nil }
        var key = String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
        key = unquote(key)
        guard !key.isEmpty, !key.hasPrefix("-") else { return nil }
        let rest = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        return (key, interpret(stripComment(rest)))
    }

    /// The key/value separator: the first `:` outside quotes that is followed by a space or the end.
    private static func colonIndex(in text: String) -> String.Index? {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " || text[next] == "\t" { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Removes a trailing ` # comment` that is not inside quotes.
    private static func stripComment(_ text: String) -> String {
        splitComment(text).content.trimmingCharacters(in: .whitespaces)
    }

    /// Splits at a ` #` that is not inside quotes: the content before it (untrimmed) and the
    /// comment from the `#` on.
    private static func splitComment(_ text: String) -> (content: String, comment: String?) {
        var quote: Character?
        var previous: Character = " "
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                // A quote only opens a quoted scalar at the start of a token.
                if previous == " " || previous == "[" || previous == "{" || previous == "," { quote = character }
            } else if character == "#", previous == " " || previous == "\t" {
                return (String(text[text.startIndex..<index]), String(text[index...]))
            }
            previous = character
            index = text.index(after: index)
        }
        return (text, nil)
    }

    private static func interpret(_ text: String) -> Value {
        if text.isEmpty { return .block }  // `key:` followed by nested lines — or an empty value
        if text == "~" || text.lowercased() == "null" { return .null }
        if text.hasPrefix("|") || text.hasPrefix(">") { return .block }
        if text.hasPrefix("[") || text.hasPrefix("{") { return .flow(text) }
        if text.hasPrefix("&") || text.hasPrefix("*") || text.hasPrefix("!") { return .block }
        return .scalar(unquote(text))
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" else {
            return text
        }
        let inner = String(text.dropFirst().dropLast())
        // Single quotes escape themselves; double quotes use backslashes (only the two that occur
        // in paths and sizes are handled).
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: - Editing

    /// Sets a top-level scalar in the original text, keeping every other line (comments, nested
    /// blocks) byte-for-byte. A trailing comment on the replaced line is kept. A missing key is
    /// appended. Returns `nil` when `key` exists but is not a plain top-level scalar line (nested
    /// or flow value), because rewriting it blindly could corrupt the file.
    public static func settingTopLevelScalar(_ key: String, to newValue: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"), !line.hasPrefix("-") else { continue }
            guard let separator = colonIndex(in: line) else { continue }
            let lineKey = unquote(String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces))
            guard lineKey == key else { continue }

            let afterColon = String(line[line.index(after: separator)...])
            let withoutComment = stripComment(afterColon.trimmingCharacters(in: .whitespaces))
            switch interpret(withoutComment) {
            case .scalar, .null: break
            case .block where withoutComment.isEmpty:
                // `key:` with nothing after it is null only if no nested lines follow.
                if index + 1 < lines.count, lines[index + 1].hasPrefix(" ") || lines[index + 1].hasPrefix("-") { return nil }
            default: return nil
            }

            var comment = ""
            if let trailing = splitComment(afterColon).comment { comment = " " + trailing }
            lines[index] = "\(line[line.startIndex..<separator]): \(newValue)\(comment)"
            return lines.joined(separator: "\n")
        }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        result += "\(key): \(newValue)\n"
        return result
    }
}
