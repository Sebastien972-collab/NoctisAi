// Created by Sébastien DAGUIN

import Foundation
import MachO

struct SemanticVersion: Equatable, Comparable, Sendable {
    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    let prerelease: [String]

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let metadata = value.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2 else { return nil }
        func identifiers(_ text: Substring) -> [String]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard
                parts.allSatisfy({
                    !$0.isEmpty
                        && $0.utf8.allSatisfy {
                            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                                || $0 == 45
                        }
                })
            else { return nil }
            return parts
        }
        if metadata.count == 2, identifiers(metadata[1]) == nil { return nil }
        let parts = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        let values = numbers.compactMap { number -> UInt64? in
            guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
                number.count == 1 || number.first != "0"
            else { return nil }
            return UInt64(number)
        }
        guard values.count == 3 else { return nil }
        var pre: [String] = []
        if parts.count == 2 {
            guard let parsed = identifiers(parts[1]),
                parsed.allSatisfy({ item in
                    !item.utf8.allSatisfy { (48...57).contains($0) } || item.count == 1 || item.first != "0"
                })
            else { return nil }
            pre = parsed
        }
        major = values[0]
        minor = values[1]
        patch = values[2]
        prerelease = pre
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.utf8.allSatisfy { (48...57).contains($0) }
            let rightNumeric = right.utf8.allSatisfy { (48...57).contains($0) }
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric, left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct CLIBuildIdentity: Codable, Equatable, Sendable {
    let version: String
    let channel: String
    let commit: String

    var display: String {
        let revision = commit.isEmpty ? "" : ", \(commit.prefix(7))"
        return "Noctis \(version) (\(channel)\(revision))"
    }

    static var installed: Self {
        // The release builder embeds metadata in the executable's read-only Mach-O section.
        // A bare `swift build` deliberately reports unknown rather than inventing a release.
        if let header = _dyld_get_image_header(0) {
            var size: UInt = 0
            let machHeader = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            if let bytes = getsectiondata(machHeader, "__TEXT", "__noctis", &size), size <= 4096,
                let identity = try? JSONDecoder().decode(
                    Self.self, from: Data(bytes: bytes, count: Int(size))) {
                return identity
            }
        }
        return Self(version: "unknown", channel: "local", commit: "")
    }
}
