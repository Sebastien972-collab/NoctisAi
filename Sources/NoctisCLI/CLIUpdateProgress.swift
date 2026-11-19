// Created by Sébastien DAGUIN

import Darwin
import Foundation

/// Synchronizes the download delegate and animation task without holding a lock across awaits.
final class CLIUpdateProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let animated: Bool
    private let output: @Sendable (String) -> Void
    private var label = ""
    private var started = Date()
    private var frame = 0
    private var lastDraw = Date.distantPast
    private var bytes: (Int64, Int64)?

    init(animated: Bool = CLIUpdateProgress.supportsAnimation(),
         output: @escaping @Sendable (String) -> Void = {
             FileHandle.standardError.write(Data($0.utf8))
         }) {
        self.animated = animated
        self.output = output
    }

    static func supportsAnimation(tty: Bool = isatty(STDERR_FILENO) != 0,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        tty && environment["TERM"] != "dumb" && environment["CI"] == nil
            && environment["NO_COLOR"] == nil
    }

    static func downloadDescription(received: Int64, total: Int64) -> String {
        let megabytes = String(format: "%.1f", Double(max(0, received)) / 1_048_576)
        guard total > 0 else { return "\(megabytes) MiB" }
        // Reserve 100% for successful completion after HTTP and size validation.
        let fraction = min(0.99, Double(max(0, received)) / Double(total))
        let filled = Int(fraction * 12)
        return "[\(String(repeating: "=", count: filled))\(String(repeating: " ", count: 12 - filled))] "
            + "\(Int(fraction * 100))% \(megabytes) MiB"
    }

    func download(received: Int64, total: Int64) {
        lock.lock()
        defer { lock.unlock() }
        bytes = (received, total)
        draw()
    }

    func tick() {
        lock.lock()
        defer { lock.unlock() }
        draw()
    }

    private func draw() {
        guard animated, !label.isEmpty, Date().timeIntervalSince(lastDraw) >= 0.1 else { return }
        lastDraw = Date()
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let detail = bytes.map { Self.downloadDescription(received: $0.0, total: $0.1) }
            ?? "\(Int(Date().timeIntervalSince(started)))s"
        var size = winsize()
        let width = ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0 ? Int(size.ws_col) : 80
        let line = "\(frames[frame % frames.count]) \(label) · \(detail)"
        output("\r\u{1B}[2K" + String(line.prefix(max(1, width - 1))))
        frame += 1
    }

    func step<Value>(_ title: String, operation: () async throws -> Value) async throws -> Value {
        fflush(stdout)
        begin(title)
        let animation = Task {
            while !Task.isCancelled {
                self.tick()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        do {
            let result = try await operation()
            animation.cancel()
            await animation.value
            finish(success: true)
            return result
        } catch {
            animation.cancel()
            await animation.value
            finish(success: false)
            throw error
        }
    }

    private func begin(_ title: String) {
        lock.lock()
        defer { lock.unlock() }
        label = updateText(title)
        started = Date()
        bytes = nil
        lastDraw = .distantPast
        if !animated { output("… \(label)\n") }
        draw()
    }

    private func finish(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = Int(Date().timeIntervalSince(started))
        let completion = success && (bytes?.1 ?? 0) > 0 ? " · 100%" : ""
        output((animated ? "\r\u{1B}[2K" : "")
            + "\(success ? "✓" : "✗") \(label)\(completion) · \(elapsed)s\n")
        label = ""
        bytes = nil
    }

    static func summary(_ notes: String) -> [String] {
        let bidiControls = CharacterSet(
            charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        return notes.split(whereSeparator: \.isNewline).compactMap { line in
            let clean = String(String(line).unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
                    && !bidiControls.contains($0)
            }).trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, !clean.hasPrefix("#") else { return nil }
            return String(clean.prefix(120))
        }.prefix(4).map { $0 }
    }
}

struct ProgressUpdateRunner: UpdateCommandRunning {
    let base: any UpdateCommandRunning
    let progress: CLIUpdateProgress

    func run(_ executable: URL, _ arguments: [String], directory: URL?) async throws -> String {
        let title: String
        if arguments.contains("fetch") {
            title = "Téléchargement des sources"
        } else if arguments.contains("build"), !arguments.contains("--show-bin-path") {
            title = "Compilation"
        } else {
            return try await base.run(executable, arguments, directory: directory)
        }
        return try await progress.step(title) {
            try await base.run(executable, arguments, directory: directory)
        }
    }
}
