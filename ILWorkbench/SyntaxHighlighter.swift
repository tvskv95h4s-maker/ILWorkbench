import AppKit
import SwiftUI

enum SourceLanguage {
    case csharp
    case il
    case plain
}

/// Colours for the two token sets we render. Light and dark variants follow the system appearance.
struct SyntaxTheme {
    let plain: NSColor
    let keyword: NSColor
    let type: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let preprocessor: NSColor
    let offset: NSColor
    let opcode: NSColor
    let member: NSColor

    static let light = SyntaxTheme(
        plain: NSColor(calibratedWhite: 0.12, alpha: 1),
        keyword: NSColor(calibratedRed: 0.61, green: 0.13, blue: 0.58, alpha: 1),
        type: NSColor(calibratedRed: 0.11, green: 0.29, blue: 0.60, alpha: 1),
        string: NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.13, alpha: 1),
        comment: NSColor(calibratedRed: 0.28, green: 0.44, blue: 0.29, alpha: 1),
        number: NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.66, alpha: 1),
        preprocessor: NSColor(calibratedRed: 0.45, green: 0.33, blue: 0.18, alpha: 1),
        offset: NSColor(calibratedWhite: 0.55, alpha: 1),
        opcode: NSColor(calibratedRed: 0.11, green: 0.29, blue: 0.66, alpha: 1),
        member: NSColor(calibratedRed: 0.13, green: 0.40, blue: 0.34, alpha: 1)
    )

    static let dark = SyntaxTheme(
        plain: NSColor(calibratedWhite: 0.92, alpha: 1),
        keyword: NSColor(calibratedRed: 0.98, green: 0.56, blue: 0.85, alpha: 1),
        type: NSColor(calibratedRed: 0.55, green: 0.81, blue: 1.00, alpha: 1),
        string: NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.47, alpha: 1),
        comment: NSColor(calibratedRed: 0.50, green: 0.70, blue: 0.50, alpha: 1),
        number: NSColor(calibratedRed: 0.72, green: 0.86, blue: 1.00, alpha: 1),
        preprocessor: NSColor(calibratedRed: 0.87, green: 0.76, blue: 0.52, alpha: 1),
        offset: NSColor(calibratedWhite: 0.58, alpha: 1),
        opcode: NSColor(calibratedRed: 0.55, green: 0.81, blue: 1.00, alpha: 1),
        member: NSColor(calibratedRed: 0.55, green: 0.87, blue: 0.76, alpha: 1)
    )

    static func current(for appearance: NSAppearance) -> SyntaxTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    static func forScheme(_ scheme: ColorScheme) -> SyntaxTheme {
        scheme == .dark ? .dark : .light
    }
}

/// A dependency-free tokenizer good enough for decompiler output and IL listings.
/// Ranges are UTF-16 based, so they can be applied to `NSAttributedString` directly.
enum SyntaxHighlighter {
    /// Safety valve only; the tokenizer runs on a background queue for large documents, so even a
    /// multi-megabyte decompiled type gets coloured.
    static let highlightLimit = 8_000_000

    /// Set by the caller to collect timing for diagnostics (nil = no logging).
    nonisolated(unsafe) static var timingLogger: ((String) -> Void)?

    static func highlighted(_ code: String, language: SourceLanguage, theme: SyntaxTheme, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: theme.plain])
        guard language != .plain, !code.isEmpty, code.utf16.count <= highlightLimit else { return result }

        let start = Date()
        let units = Array(code.utf16)
        switch language {
        case .csharp: scanCSharp(units, into: result, theme: theme)
        case .il: scanIl(units, into: result, theme: theme)
        case .plain: break
        }
        timingLogger?(String(format: "highlighted %d chars in %.2fs", units.count, Date().timeIntervalSince(start)))
        return result
    }

    // MARK: - character helpers

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    private static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit >= 128
    }
    private static func isIdentifierBody(_ unit: UInt16) -> Bool { isLetter(unit) || isDigit(unit) }
    private static func isUpper(_ unit: UInt16) -> Bool { unit >= 65 && unit <= 90 }
    private static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 13 || unit == 10 }

    private static let longestKeyword = 12

    private static let csharpKeywords: Set<String> = [
        "abstract", "add", "alias", "as", "ascending", "async", "await", "base", "bool", "break", "by",
        "byte", "case", "catch", "char", "checked", "class", "const", "continue", "decimal", "default",
        "delegate", "descending", "do", "double", "dynamic", "else", "enum", "equals", "event", "explicit",
        "extern", "false", "finally", "fixed", "float", "for", "foreach", "from", "get", "global", "goto",
        "group", "if", "implicit", "in", "init", "int", "interface", "internal", "into", "is", "join", "let",
        "lock", "long", "managed", "nameof", "namespace", "new", "nint", "not", "notnull", "null", "nuint",
        "object", "on", "operator", "or", "orderby", "out", "override", "params", "partial", "private",
        "protected", "public", "readonly", "record", "ref", "remove", "required", "return", "sbyte", "scoped",
        "sealed", "select", "set", "short", "sizeof", "stackalloc", "static", "string", "struct", "switch",
        "this", "throw", "true", "try", "typeof", "uint", "ulong", "unchecked", "unmanaged", "unsafe",
        "ushort", "using", "value", "var", "virtual", "void", "volatile", "when", "where", "while", "with",
        "yield"
    ]

    // MARK: - C#

    private static func scanCSharp(_ units: [UInt16], into result: NSMutableAttributedString, theme: SyntaxTheme) {
        var index = 0
        var lineStart = true

        func paint(_ range: NSRange, _ colour: NSColor) {
            guard range.length > 0 else { return }
            result.addAttribute(.foregroundColor, value: colour, range: range)
        }

        while index < units.count {
            let unit = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0

            // line comment
            if unit == 47, next == 47 {
                var end = index
                while end < units.count, units[end] != 10 { end += 1 }
                paint(NSRange(location: index, length: end - index), theme.comment)
                index = end
                continue
            }

            // block comment
            if unit == 47, next == 42 {
                var end = index + 2
                while end + 1 < units.count, !(units[end] == 42 && units[end + 1] == 47) { end += 1 }
                end = min(end + 2, units.count)
                paint(NSRange(location: index, length: end - index), theme.comment)
                index = end
                lineStart = false
                continue
            }

            // verbatim / interpolated / plain string
            if unit == 64, next == 34 {                                   // @"..."
                var end = index + 2
                while end < units.count {
                    if units[end] == 34 {
                        if end + 1 < units.count, units[end + 1] == 34 { end += 2; continue }
                        end += 1
                        break
                    }
                    end += 1
                }
                paint(NSRange(location: index, length: end - index), theme.string)
                index = end
                lineStart = false
                continue
            }
            if unit == 34 || (unit == 36 && next == 34) {                 // "..." or $"..."
                var end = index + (unit == 36 ? 2 : 1)
                while end < units.count {
                    if units[end] == 92 { end += 2; continue }            // escape
                    if units[end] == 34 { end += 1; break }
                    if units[end] == 10 { break }                         // unterminated
                    end += 1
                }
                paint(NSRange(location: index, length: min(end, units.count) - index), theme.string)
                index = min(end, units.count)
                lineStart = false
                continue
            }

            // char literal
            if unit == 39 {
                var end = index + 1
                while end < units.count {
                    if units[end] == 92 { end += 2; continue }
                    if units[end] == 39 { end += 1; break }
                    end += 1
                }
                paint(NSRange(location: index, length: min(end, units.count) - index), theme.string)
                index = min(end, units.count)
                lineStart = false
                continue
            }

            // preprocessor directive
            if unit == 35, lineStart {
                var end = index
                while end < units.count, units[end] != 10 { end += 1 }
                paint(NSRange(location: index, length: end - index), theme.preprocessor)
                index = end
                continue
            }

            // number
            if isDigit(unit) {
                var end = index
                while end < units.count, isIdentifierBody(units[end]) || units[end] == 46 { end += 1 }
                paint(NSRange(location: index, length: end - index), theme.number)
                index = end
                lineStart = false
                continue
            }

            // identifier
            if isLetter(unit) {
                var end = index
                while end < units.count, isIdentifierBody(units[end]) { end += 1 }
                let length = end - index

                var previous = index - 1
                while previous >= 0, isSpace(units[previous]) { previous -= 1 }
                let followsDot = previous >= 0 && units[previous] == 46

                var afterWord = end
                while afterWord < units.count, isSpace(units[afterWord]) { afterWord += 1 }
                let calledLikeAFunction = afterWord < units.count && units[afterWord] == 40

                // Long identifiers cannot be keywords, so the string is only built for short ones.
                let isKeyword = length <= Self.longestKeyword
                    && csharpKeywords.contains(String(decoding: units[index..<end], as: UTF16.self))

                if isKeyword {
                    paint(NSRange(location: index, length: length), theme.keyword)
                } else if followsDot || calledLikeAFunction {
                    paint(NSRange(location: index, length: length), theme.member)
                } else if isUpper(unit) {
                    paint(NSRange(location: index, length: length), theme.type)
                }
                index = end
                lineStart = false
                continue
            }

            lineStart = unit == 10
            index += 1
        }
    }

    // MARK: - IL

    private static func scanIl(_ units: [UInt16], into result: NSMutableAttributedString, theme: SyntaxTheme) {
        func paint(_ range: NSRange, _ colour: NSColor) {
            guard range.length > 0 else { return }
            result.addAttribute(.foregroundColor, value: colour, range: range)
        }

        var index = 0
        while index < units.count {
            let lineEnd = {
                var end = index
                while end < units.count, units[end] != 10 { end += 1 }
                return end
            }()

            var cursor = index

            // "IL_0000:"
            if units[cursor] == 73, cursor + 2 < lineEnd, units[cursor + 1] == 76, units[cursor + 2] == 95 {
                var end = cursor + 3
                while end < lineEnd, units[end] != 58 { end += 1 }
                if end < lineEnd { end += 1 }
                paint(NSRange(location: cursor, length: end - cursor), theme.offset)
                cursor = end
            }

            while cursor < lineEnd, isSpace(units[cursor]) { cursor += 1 }

            // mnemonic
            let mnemonicStart = cursor
            while cursor < lineEnd, isIdentifierBody(units[cursor]) || units[cursor] == 46 { cursor += 1 }
            paint(NSRange(location: mnemonicStart, length: cursor - mnemonicStart), theme.opcode)

            while cursor < lineEnd, isSpace(units[cursor]) { cursor += 1 }

            // operand (string literal, number, or a member reference)
            if cursor < lineEnd {
                if units[cursor] == 34 {
                    var end = cursor + 1
                    while end < lineEnd {
                        if units[end] == 92 { end += 2; continue }
                        if units[end] == 34 { end += 1; break }
                        end += 1
                    }
                    paint(NSRange(location: cursor, length: end - cursor), theme.string)
                } else if isDigit(units[cursor]) || (units[cursor] == 45 && cursor + 1 < lineEnd && isDigit(units[cursor + 1])) {
                    var end = cursor
                    while end < lineEnd, isIdentifierBody(units[end]) || units[end] == 46 || units[end] == 45 { end += 1 }
                    paint(NSRange(location: cursor, length: end - cursor), theme.number)
                } else {
                    paint(NSRange(location: cursor, length: lineEnd - cursor), theme.member)
                }
            }

            index = lineEnd < units.count ? lineEnd + 1 : units.count
        }
    }
}
