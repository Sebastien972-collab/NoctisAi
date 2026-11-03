import Foundation
import SafeURLKit

/// Syntax validation only, never permission to connect: DNS is not pinned.
enum PublicWebURLPolicy {
    private static let policy = URLPolicy()

    static func validate(_ raw: String) throws -> URL {
        do { return try policy.validate(raw).url }
        catch { throw WebPageError.invalidURL }
    }
}
