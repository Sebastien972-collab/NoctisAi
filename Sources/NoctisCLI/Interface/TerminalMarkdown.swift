// Created by Sébastien DAGUIN

import Foundation

/// Incremental presentation only: no full-response buffer or screen redraw per token.
struct TerminalMarkdown {
    let styled: Bool
    private var lineStart = true
    private var prefix = ""
    private var fenceHeader = false
    private var inCode = false
    private var bold = false
    private var inlineCode = false
    private var star = false

    mutating func append(_ chunk: String) -> String {
        var output = ""
        for scalar in chunk.unicodeScalars {
            // Untrusted model/tool text must not send escape sequences or terminal controls.
            guard Self.isPrintable(scalar) else { continue }
            let character = String(scalar)
            guard styled else { output += character; continue }
            if consumePrefix(character, output: &output) { continue }
            appendCharacter(character, output: &output)
        }
        return output
    }

    private mutating func appendCharacter(_ character: String, output: inout String) {
    if character == "\n" {
        if star { output += "*"; star = false }
        output += "\u{1B}[0m\n"
        lineStart = true
        bold = false
        inlineCode = false
    } else if inCode {
        output += character
    } else if character == "*", !inlineCode {
        if star {
            bold.toggle()
            output += bold ? "\u{1B}[1m" : "\u{1B}[22m"
            star = false
        } else { star = true }
    } else {
        if star { output += "*"; star = false }
        if character == "`" {
            inlineCode.toggle()
            output += inlineCode ? "\u{1B}[36m" : "\u{1B}[39m"
        } else { output += character }
    }
    }

    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter(isPrintable)))
    }

    private static func isPrintable(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 32 && !(127...159).contains(scalar.value) || scalar == "\n" || scalar == "\t"
    }

    private mutating func consumePrefix(_ character: String, output: inout String) -> Bool {
        if fenceHeader {
            if character == "\n" {
                inCode.toggle()
                output += inCode ? "\u{1B}[2m┌ code\u{1B}[0m\n" : "\u{1B}[2m└\u{1B}[0m\n"
                fenceHeader = false
                lineStart = true
            }
            return true
        }
        guard lineStart else { return false }
        if character == "`", prefix.allSatisfy({ $0 == "`" }), prefix.count < 3 {
            prefix += character
            if prefix == "```" { prefix = ""; fenceHeader = true }
            return true
        }
        if !inCode, character == "#", prefix.allSatisfy({ $0 == "#" }), prefix.count < 6 {
            prefix += character
            return true
        }
        let heading = character == " " && prefix.hasPrefix("#")
        output += heading ? "\u{1B}[1;33m" : prefix
        prefix = ""
        lineStart = false
        return heading
    }

    mutating func finish() -> String {
        let fence = fenceHeader ? (inCode ? "└" : "┌ code") : ""
        let tail = prefix + fence + (star ? "*" : "") + (styled ? "\u{1B}[0m" : "")
        fenceHeader = false
        prefix = ""
        star = false
        return tail
    }
}
