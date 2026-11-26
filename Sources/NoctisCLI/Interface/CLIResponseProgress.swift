// Created by Sébastien DAGUIN

import Darwin
import Foundation
import Noctis

/// A response owns this renderer and joins its animation before returning to the prompt.
final class CLIResponseProgress: @unchecked Sendable {
    enum Phase: Equatable {
        case loading, downloading, waiting

        var title: String {
            switch self {
            case .loading:
                String(localized: "console.progress.loading", defaultValue: "Chargement du modèle…", bundle: .module)
            case .downloading:
                String(localized: "console.progress.downloading", defaultValue: "Téléchargement du modèle…",
                       bundle: .module)
            case .waiting:
                String(localized: "console.progress.waiting", defaultValue: "Préparation de la réponse…",
                       bundle: .module)
            }
        }
    }

    private let lock = NSLock()
    private let animated: Bool
    private let output: @Sendable (String) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var phase: Phase?
    private var started = ContinuousClock.now
    private var frame = 0
    private var finished = false

    init(animated: Bool = CLIResponseProgress.supportsAnimation(),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         output: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) {
        self.animated = animated
        self.now = now
        self.output = output
    }

    static func supportsAnimation(stdoutTTY: Bool = isatty(STDOUT_FILENO) == 1,
                                  stderrTTY: Bool = isatty(STDERR_FILENO) == 1,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        stdoutTTY && stderrTTY && environment["TERM"] != "dumb"
            && environment["CI"] == nil && environment["NO_COLOR"] == nil
    }

    func update(_ next: Phase) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, phase != next else { return }
        phase = next
        started = now()
        if animated { draw() } else { output("… \(next.title)\n") }
    }

    func loading(_ phase: AIModelLoadPhase) {
        switch phase {
        case .loading: update(.loading)
        case .downloading: update(.downloading)
        case .ready: pause()
        }
    }

    /// Shares the animation lock so no late frame can overwrite the next stdout write.
    func pause() {
        lock.lock()
        defer { lock.unlock() }
        clear()
    }

    func tick() {
        lock.lock()
        defer { lock.unlock() }
        draw()
    }

    func track<Value>(_ operation: () async throws -> Value) async throws -> Value {
        let animation = animated ? Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                self.tick()
            }
        } : nil
        do {
            let result = try await operation()
            stop()
            animation?.cancel()
            await animation?.value
            return result
        } catch {
            stop()
            animation?.cancel()
            await animation?.value
            throw error
        }
    }

    private func stop() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        clear()
    }

    private func clear() {
        if animated, phase != nil { output("\r\u{1B}[2K") }
        phase = nil
    }

    private func draw() {
        guard animated, !finished, let phase else { return }
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let elapsed = max(0, started.duration(to: now()).components.seconds)
        var size = winsize()
        let width = ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
        let line = "\(frames[frame % frames.count]) \(phase.title) · \(elapsed)s"
        output("\r\u{1B}[2K" + String(line.prefix(max(1, width - 1))))
        frame += 1
    }
}
