import Foundation
import NoctisPresentation

/// Separates conversational text from one optional trailing UI envelope while preserving streaming.
struct GenerativeUIStreamAccumulator {
    private var pending = ""
    private var payload = ""
    private var readingPayload = false

    mutating func append(_ chunk: String) -> String {
        if readingPayload { payload += chunk; return "" }
        pending += chunk
        if let marker = pending.range(of: GenerativeUIProtocol.openingMarker) {
            let text = String(pending[..<marker.lowerBound])
            payload = String(pending[marker.upperBound...])
            pending = ""
            readingPayload = true
            return text
        }
        let reserve = GenerativeUIProtocol.openingMarker.count - 1
        guard pending.count > reserve else { return "" }
        let boundary = pending.index(pending.endIndex, offsetBy: -reserve)
        let text = String(pending[..<boundary])
        pending = String(pending[boundary...])
        return text
    }

    mutating func finish() -> (text: String, output: GenerativeUIOutput?) {
        guard readingPayload else { defer { pending = "" }; return (pending, nil) }
        guard let end = payload.range(of: GenerativeUIProtocol.closingMarker) else {
            defer { payload = "" }
            return (GenerativeUIProtocol.openingMarker + payload, nil)
        }
        let encoded = String(payload[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return ("", try GenerativeUIProtocol.decode(Data(encoded.utf8)))
        } catch {
            // Invalid structured output remains ordinary visible text; the conversation never disappears.
            return (GenerativeUIProtocol.openingMarker + payload, nil)
        }
    }
}
