// Created by Sébastien DAGUIN

import Darwin
import Foundation

/// Session-only history: prompts are never written to disk.
struct ConsoleInput {
    private var history: [String] = []
    static let maximumBytes = 65_536

    mutating func readPrompt() -> String? {
        var lines: [String] = []
        while true {
            guard let line = readLine(prompt: lines.isEmpty ? "  › " : "  · ") else { return nil }
            if line == "\u{03}" { return "" }
            let continues = line.hasSuffix("\\")
            lines.append(continues ? String(line.dropLast()) : line)
            if lines.joined(separator: "\n").utf8.count > Self.maximumBytes {
                print(String(localized: "console.input.too_long", defaultValue: "Message trop long (64 Kio maximum).",
                             bundle: .module))
                return ""
            }
            if !continues { break }
        }
        let message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty, history.last != message {
            history.append(message)
            // Bound history by both count and bytes, including multiline messages.
            while history.count > 100 || history.reduce(0, { $0 + $1.utf8.count }) > 262_144 {
                history.removeFirst()
            }
        }
        return message
    }

    private func readLine(prompt: String) -> String? {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              ProcessInfo.processInfo.environment["TERM"] != "dumb" else {
            // One complete line at a time; do not mix stdio buffering with POSIX reads.
            return Swift.readLine()
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return Swift.readLine() }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return Swift.readLine() }
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        var bytes: [UInt8] = []
        var historyIndex = history.count
        var draft: [UInt8] = []
        print(prompt, terminator: "")
        fflush(stdout)
        while let byte = readByte() {
            switch byte {
            case 3:
                print("^C")
                return "\u{03}"
            case 4:
                if bytes.isEmpty { print(); return nil }
            case 10, 13:
                print()
                return String(bytes: bytes, encoding: .utf8) ?? ""
            default:
                edit(byte, bytes: &bytes, historyIndex: &historyIndex, draft: &draft)
                if String(bytes: bytes, encoding: .utf8) != nil { redraw(prompt: prompt, bytes: bytes) }
            }
        }
        return nil
    }

    private func edit(_ byte: UInt8, bytes: inout [UInt8], historyIndex: inout Int, draft: inout [UInt8]) {
        switch byte {
        case 8, 127:
            if !bytes.isEmpty {
                repeat { bytes.removeLast() } while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil
            }
        case 27:
            recallHistory(bytes: &bytes, index: &historyIndex, draft: &draft)
        case 21: bytes = []
        case 32...255:
            if bytes.count < Self.maximumBytes { bytes.append(byte) }
        default: break
        }
    }

    private func recallHistory(bytes: inout [UInt8], index: inout Int, draft: inout [UInt8]) {
        guard readByte(timeout: 30) == 91, let direction = readByte(timeout: 30) else { return }
        if direction == 65, index > 0 {
            if index == history.count { draft = bytes }
            index -= 1
        } else if direction == 66, index < history.count {
            index += 1
        } else { return }
        bytes = index == history.count ? draft
            : Array(history[index].replacingOccurrences(of: "\n", with: " ").utf8)
    }

    private func redraw(prompt: String, bytes: [UInt8]) {
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        let columns = max(20, Int(size.ws_col))
        let text = String(bytes: bytes, encoding: .utf8) ?? ""
        // Keep the editor on one screen row, including wide Unicode characters.
        var visible = ""
        var width = 0
        for character in text.reversed() {
            let cells = character.unicodeScalars.contains { $0.value >= 0x1100 } ? 2 : 1
            if width + cells > columns - 6 { break }
            visible.insert(character, at: visible.startIndex)
            width += cells
        }
        print("\r\u{1B}[2K" + prompt + visible, terminator: "")
        fflush(stdout)
    }

    private func readByte(timeout: Int32? = nil) -> UInt8? {
        if let timeout {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, timeout) > 0 else { return nil }
        }
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 1 { return byte }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }
}
