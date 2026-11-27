// Created by Sébastien DAGUIN

import Foundation

/// Bounded, deterministic fallback candidates for the provider's request only.
/// The rendered-token guard remains authoritative; these are not token estimates.
enum NoctisContextReduction {
    static let maximumLevel = 3

    /// Level 1 keeps every turn, level 2 keeps the latest two user turns, and
    /// level 3 keeps the latest user turn. Every level retains system messages
    /// and complete call/result batches in the retained turns. The original
    /// transcript, current user request, tool arguments and source URLs are intact.
    /// An unchanged candidate is possible; callers may advance to the next level.
    static func reduce(_ messages: [ChatMessage], level: Int) -> [ChatMessage] {
        guard level > 0 else { return messages }
        let limits = Limits(level: min(level, maximumLevel))
        let retained = retainingRecentTurns(messages, count: limits.turns)
        return retained.map { message in
            guard case let .tool(id, name, content) = message else { return message }
            return .tool(id: id, name: name, content: reducedContent(content, name: name, limits: limits))
        }
    }

    private struct Limits: Sendable {
        let turns: Int?
        let title: Int
        let description: Int
        let page: Int

        init(level: Int) {
            switch level {
            case 1:
                turns = nil
                title = 160
                description = 512
                page = 1_024
            case 2:
                turns = 2
                title = 112
                description = 256
                page = 512
            default:
                turns = 1
                title = 80
                description = 128
                page = 256
            }
        }
    }

    private static func retainingRecentTurns(_ messages: [ChatMessage], count: Int?) -> [ChatMessage] {
        guard let count else { return messages }
        let starts = messages.indices.filter { index in
            switch messages[index] {
            case .user, .userMultimodal: true
            default: false
            }
        }
        guard starts.count > count else { return messages }
        let start = starts[starts.count - count]
        let instructions = messages[..<start].filter { message in
            if case .system = message { return true }
            return false
        }
        // A user boundary in a validated history cannot split a tool-call batch.
        return instructions + Array(messages[start...])
    }

    private static func reducedContent(_ content: String, name: String, limits: Limits) -> String {
        guard name == WebSearchTool.name || name == WebOpenTool.name,
              let data = content.data(using: .utf8),
              var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              payload["trust"] as? String == "UNTRUSTED_EXTERNAL_DATA" else { return content }
        let changed = name == WebSearchTool.name
            ? reduceSearch(&payload, limits: limits) : reducePage(&payload, limits: limits)
        guard changed,
              let reduced = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              reduced.count < data.count,
              let text = String(data: reduced, encoding: .utf8) else { return content }
        return text
    }

    private static func reduceSearch(_ payload: inout [String: Any], limits: Limits) -> Bool {
        guard payload["instructions"] is String,
              var results = payload["results"] as? [[String: Any]] else { return false }
        var changed = false
        for index in results.indices {
            guard let title = results[index]["title"] as? String,
                  results[index]["url"] is String,
                  let description = results[index]["description"] as? String else { return false }
            let shortTitle = bounded(title, characters: limits.title)
            let excerpt = bounded(description, characters: limits.description)
            guard shortTitle != title || excerpt != description else { continue }
            results[index]["title"] = shortTitle
            results[index]["description"] = excerpt
            results[index]["isTruncated"] = true
            changed = true
        }
        guard changed else { return false }
        payload["results"] = results
        payload["isTruncated"] = true
        return true
    }

    private static func reducePage(_ payload: inout [String: Any], limits: Limits) -> Bool {
        guard payload["status"] as? String == "retrieved",
              payload["url"] is String, payload["isTruncated"] is Bool,
              let title = payload["title"] as? String,
              let content = payload["content"] as? String else { return false }
        let shortTitle = bounded(title, characters: limits.title)
        let excerpt = bounded(content, characters: limits.page)
        guard shortTitle != title || excerpt != content else { return false }
        payload["title"] = shortTitle
        payload["content"] = excerpt
        payload["isTruncated"] = true
        return true
    }

    private static func bounded(_ value: String, characters: Int) -> String {
        let bytes = characters * 4
        guard value.utf8.count > bytes || value.count > characters else { return value }
        // Keep complete graphemes, including when one contains many combining scalars.
        // Reserve room for the ellipsis inside both the character and byte budgets.
        var result = ""
        var remaining = bytes - "…".utf8.count
        for character in value.prefix(characters - 1) {
            let size = String(character).utf8.count
            guard size <= remaining else { break }
            result.append(character)
            remaining -= size
        }
        return result + "…"
    }
}
