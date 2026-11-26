// Created by Sébastien DAGUIN

import Foundation
import Testing
@testable import NoctisCLI

final class ResponseProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private var instant = ContinuousClock.now
    func append(_ text: String) { lock.lock(); defer { lock.unlock() }; value += text }
    func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }
}

@Suite("Response progress without model loading", .timeLimit(.minutes(1)))
struct CLIResponseProgressTests {
    @Test func animationRequiresBothOutputStreamsAndTerminalCapabilities() {
        #expect(CLIResponseProgress.supportsAnimation(stdoutTTY: true, stderrTTY: true,
                                                       environment: ["TERM": "xterm"]))
        for environment in [["TERM": "dumb"], ["NO_COLOR": ""], ["CI": "true"]] {
            #expect(!CLIResponseProgress.supportsAnimation(stdoutTTY: true, stderrTTY: true,
                                                            environment: environment))
        }
        for pair in [(true, false), (false, true), (false, false)] {
            #expect(!CLIResponseProgress.supportsAnimation(stdoutTTY: pair.0, stderrTTY: pair.1, environment: [:]))
        }
    }

    @Test func elapsedTimeUsesTheMonotonicClock() async throws {
        let capture = ResponseProgressCapture()
        let progress = CLIResponseProgress(animated: true, now: { capture.now() }, output: { capture.append($0) })
        try await progress.track {
            progress.update(.waiting)
            #expect(capture.read().contains(" · 0s"))
            capture.advance(.seconds(12))
            progress.tick()
            #expect(capture.read().contains(" · 12s"))
        }
    }

    @Test func delayedTextKeepsWaitingVisibleThenStopsFramesBeforeOutput() async throws {
        let capture = ResponseProgressCapture()
        let progress = CLIResponseProgress(animated: true, output: { capture.append($0) })
        try await progress.track {
            progress.update(.waiting)
            #expect(capture.read().contains(localizedCLI("console.progress.waiting")))
            try await Task.sleep(for: .milliseconds(150))
            progress.pause()
            capture.append("FIRST_VISIBLE_TEXT")
            let paused = capture.read()
            try await Task.sleep(for: .milliseconds(150))
            #expect(capture.read() == paused)
        }
        let completed = capture.read()
        #expect(completed.hasSuffix("FIRST_VISIBLE_TEXT"))
        progress.tick()
        progress.update(.waiting)
        #expect(capture.read() == completed)
    }

    @Test func cancellationJoinsTheAnimationAndRejectsLateCallbacks() async throws {
        let capture = ResponseProgressCapture()
        let progress = CLIResponseProgress(animated: true, output: { capture.append($0) })
        let (started, signal) = AsyncStream<Bool>.makeStream()
        let task = Task {
            try await progress.track {
                progress.update(.waiting)
                signal.yield(true)
                signal.finish()
                try await Task.sleep(for: .seconds(30))
            }
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = capture.read()
        progress.tick()
        progress.loading(.loading)
        try await Task.sleep(for: .milliseconds(150))
        #expect(capture.read() == cancelled)
    }

    @Test func failureClearsProgressBeforeTheCallerPrintsItsError() async throws {
        let capture = ResponseProgressCapture()
        let progress = CLIResponseProgress(animated: true, output: { capture.append($0) })
        await #expect(throws: URLError.self) {
            try await progress.track {
                progress.update(.loading)
                throw URLError(.cannotLoadFromNetwork)
            }
        }
        capture.append("LOAD_FAILED")
        let failed = capture.read()
        progress.tick()
        progress.loading(.downloading)
        try await Task.sleep(for: .milliseconds(150))
        #expect(capture.read() == failed)
        #expect(failed.hasSuffix("\r\u{1B}[2KLOAD_FAILED"))
    }

    @Test func redirectedOutputUsesOneReadableLinePerPhase() async throws {
        let capture = ResponseProgressCapture()
        let progress = CLIResponseProgress(animated: false, output: { capture.append($0) })
        try await progress.track {
            progress.loading(.loading)
            progress.loading(.loading)
            progress.tick()
            progress.loading(.downloading)
            progress.loading(.loading)
            progress.loading(.ready)
            progress.update(.waiting)
            progress.pause()
            progress.tick()
        }
        let text = capture.read()
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\r"))
        #expect(text.split(separator: "\n").count == 4)
        #expect(text.hasSuffix("… \(localizedCLI("console.progress.waiting"))\n"))
    }
}
