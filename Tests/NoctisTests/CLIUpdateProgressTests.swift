// Created by Sébastien DAGUIN

import Foundation
import Testing
@testable import NoctisCLI

private final class UpdateOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.lock(); defer { lock.unlock() }; value += text }
    func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("Update terminal presentation")
struct CLIUpdateProgressTests {
    @Test func animationRequiresAnInteractiveCapableTerminal() {
        #expect(CLIUpdateProgress.supportsAnimation(tty: true, environment: ["TERM": "xterm"]))
        for environment in [["TERM": "dumb"], ["NO_COLOR": ""], ["CI": "true"]] {
            #expect(!CLIUpdateProgress.supportsAnimation(tty: true, environment: environment))
        }
        #expect(!CLIUpdateProgress.supportsAnimation(tty: false, environment: [:]))
    }

    @Test func unknownSizesAndUnvalidatedTransfersNeverClaimCompletion() {
        #expect(!CLIUpdateProgress.downloadDescription(received: 100, total: -1).contains("%"))
        #expect(CLIUpdateProgress.downloadDescription(received: 100, total: 100).contains("99%"))
        #expect(CLIUpdateProgress.downloadDescription(received: 200, total: 100).contains("99%"))
        #expect(CLIUpdateProgress.downloadDescription(received: -1, total: 100).contains("0%"))
    }

    @Test func failedTransfersNeverPrintSuccessAndStopAnimating() async throws {
        let capture = UpdateOutputCapture()
        let progress = CLIUpdateProgress(animated: true, output: { capture.append($0) })
        do {
            try await progress.step("Download") {
                progress.download(received: 100, total: 100)
                throw URLError(.networkConnectionLost)
            }
            Issue.record("Failure was swallowed")
        } catch { }
        let result = capture.read()
        #expect(result.contains("✗ Download"))
        #expect(!result.contains("✓"))
        #expect(!result.contains("100%"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(capture.read() == result)
    }

    @Test func redirectedOutputIsReadableAndCancellationPropagates() async throws {
        let capture = UpdateOutputCapture()
        let progress = CLIUpdateProgress(animated: false, output: { capture.append($0) })
        let result = try await progress.step("Download") {
            progress.download(received: 100, total: 100)
            return 42
        }
        #expect(result == 42)
        #expect(capture.read().contains("✓ Download · 100%"))
        #expect(!capture.read().contains("\u{1B}"))
        await #expect(throws: CancellationError.self) {
            try await progress.step("Compile") { throw CancellationError() }
        }
        #expect(capture.read().contains("✗ Compile"))
    }

    @Test func remoteNotesCannotInjectTerminalControlsOrOverflowTheSummary() {
        let notes = "# Title\n\nFix\u{1B}[2J\u{202E} title\nSecond\nThird\nFourth\nFifth"
        let lines = CLIUpdateProgress.summary(notes)
        #expect(lines.count == 4)
        #expect(!lines.joined().contains("\u{1B}"))
        #expect(!lines.joined().contains("\u{202E}"))
        #expect(!lines.joined().contains("Fifth"))
        #expect(CLIUpdateProgress.summary(String(repeating: "x", count: 200))[0].count == 120)
    }
}
