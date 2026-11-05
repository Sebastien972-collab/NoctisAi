import Foundation
import os
import SafeURLKit

struct HTTPResponseLimits: Sendable {
    let maximumBytes: Int
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    // Deliberately fixed: enabling redirects requires a transport security review.
    static let maximumRedirects = 0

    init(maximumBytes: Int = 2 * 1_024 * 1_024,
         requestTimeout: TimeInterval = 15,
         resourceTimeout: TimeInterval = 30) throws {
        guard maximumBytes > 0, maximumBytes <= 2 * 1_024 * 1_024,
              requestTimeout.isFinite, requestTimeout > 0,
              resourceTimeout.isFinite, resourceTimeout > 0 else {
            throw WebPageError.invalidConfiguration
        }
        self.maximumBytes = maximumBytes
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }
}

/// Bounded HTTP transport, with optional peer address enforcement to guarantee public destinations.
struct BoundedHTTPClient: Sendable {
    let limits: HTTPResponseLimits
    let enforcePublicPeer: Bool

    init(limits: HTTPResponseLimits, enforcePublicPeer: Bool = false) {
        self.limits = limits
        self.enforcePublicPeer = enforcePublicPeer
    }

    static func isPublicAddress(_ addressString: String) -> Bool {
        var cleanAddress = addressString
        if let percentIndex = cleanAddress.firstIndex(of: "%") {
            cleanAddress = String(cleanAddress[..<percentIndex])
        }
        if cleanAddress.hasPrefix("[") && cleanAddress.contains("]") {
            if let closeBracket = cleanAddress.firstIndex(of: "]") {
                let inside = cleanAddress[cleanAddress.index(after: cleanAddress.startIndex)..<closeBracket]
                cleanAddress = String(inside)
            }
        } else if cleanAddress.filter({ $0 == ":" }).count == 1,
                  let colonIndex = cleanAddress.firstIndex(of: ":") {
            cleanAddress = String(cleanAddress[..<colonIndex])
        }

        if let ipv4 = try? IPv4Address.parse(cleanAddress) {
            return SpecialPurposeAddresses.match(ipv4) == nil
        }

        if let ipv6 = try? IPv6Address.parse(cleanAddress) {
            return SpecialPurposeAddresses.match(ipv6) == nil
        }

        return false
    }

    func get(_ url: URL, mimeTypes: Set<String>,
             protocolClasses: [AnyClass]? = nil,
             headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let delegate = BoundedResponseDelegate(
            url: url,
            mimeTypes: mimeTypes,
            limits: limits,
            enforcePublicPeer: enforcePublicPeer,
            hasCustomProtocolClasses: protocolClasses != nil
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limits.requestTimeout
        configuration.timeoutIntervalForResource = limits.resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.protocolClasses = protocolClasses
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = limits.requestTimeout
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(mimeTypes.sorted().joined(separator: ", "), forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// One bounded buffer per request; cancellation and completion resume exactly once.
final class BoundedResponseDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var data = Data()
        var response: HTTPURLResponse?
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
        var finished = false
        var peerAddressDenied = false
        var metrics: URLSessionTaskMetrics?
        var completed = false
    }
    // Keep state synchronized on iOS 17, where Synchronization.Mutex is unavailable.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let url: URL
    private let mimeTypes: Set<String>
    private let limits: HTTPResponseLimits
    private let enforcePublicPeer: Bool
    private let hasCustomProtocolClasses: Bool

    init(url: URL,
         mimeTypes: Set<String>,
         limits: HTTPResponseLimits,
         enforcePublicPeer: Bool = false,
         hasCustomProtocolClasses: Bool = false) {
        self.url = url
        self.mimeTypes = mimeTypes
        self.limits = limits
        self.enforcePublicPeer = enforcePublicPeer
        self.hasCustomProtocolClasses = hasCustomProtocolClasses
    }

    func start(task: URLSessionDataTask,
               continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
        let cancelled = state.withLock { state in
            if state.finished { return true }
            state.task = task
            state.continuation = continuation
            return false
        }
        if cancelled {
            task.cancel()
            continuation.resume(throwing: CancellationError())
        } else {
            task.resume()
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        let completion = state.withLock { state -> (URLSessionDataTask?, CheckedContinuation<(Data, HTTPURLResponse), any Error>?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            let completion = (state.task, state.continuation)
            state.task = nil
            state.continuation = nil
            state.data = Data()
            return completion
        }
        completion.0?.cancel()
        completion.1?.resume(with: result)
    }

    private func evaluateCompletion(state: inout State) -> Result<(Data, HTTPURLResponse), any Error> {
        if state.peerAddressDenied {
            return .failure(WebPageError.invalidURL)
        }
        if enforcePublicPeer && !hasCustomProtocolClasses {
            guard let metrics = state.metrics else {
                return .failure(WebPageError.invalidURL)
            }
            for transaction in metrics.transactionMetrics {
                if transaction.isProxyConnection {
                    return .failure(WebPageError.invalidURL)
                }
                guard let remote = transaction.remoteAddress,
                      BoundedHTTPClient.isPublicAddress(remote) else {
                    return .failure(WebPageError.invalidURL)
                }
            }
        }
        guard let response = state.response else { return .failure(WebPageError.invalidResponse) }
        if let raw = response.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(raw), length != state.data.count {
            return .failure(WebPageError.invalidResponse)
        }
        return .success((state.data, response))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(WebPageError.redirectDenied))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let (shouldFinish, result) = state.withLock { state -> (Bool, Result<(Data, HTTPURLResponse), any Error>?) in
            state.metrics = metrics
            if enforcePublicPeer && !hasCustomProtocolClasses {
                for transaction in metrics.transactionMetrics {
                    if transaction.isProxyConnection {
                        state.peerAddressDenied = true
                        return (true, .failure(WebPageError.invalidURL))
                    }
                    if let remote = transaction.remoteAddress {
                        if !BoundedHTTPClient.isPublicAddress(remote) {
                            state.peerAddressDenied = true
                            return (true, .failure(WebPageError.invalidURL))
                        }
                    } else {
                        state.peerAddressDenied = true
                        return (true, .failure(WebPageError.invalidURL))
                    }
                }
            }
            if state.completed {
                return (true, self.evaluateCompletion(state: &state))
            }
            return (false, nil)
        }
        if shouldFinish, let result {
            finish(result)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, http.url == url else {
                throw WebPageError.invalidResponse
            }
            guard !(300...399).contains(http.statusCode) else { throw WebPageError.redirectDenied }
            guard (200...299).contains(http.statusCode), http.statusCode != 206 else {
                throw WebPageError.invalidResponse
            }
            guard let mime = http.mimeType?.lowercased(), mimeTypes.contains(mime) else {
                throw WebPageError.unsupportedContentType
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == nil || encoding == "identity" else {
                throw WebPageError.unsupportedCompression
            }
            if let raw = http.value(forHTTPHeaderField: "Content-Length") {
                guard let length = Int64(raw), length >= 0 else { throw WebPageError.invalidResponse }
                guard length <= limits.maximumBytes else { throw WebPageError.responseTooLarge }
            }
            state.withLock { $0.response = http }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = state.withLock { state in
            guard !state.finished else { return false }
            guard data.count <= limits.maximumBytes - state.data.count else { return true }
            state.data.append(data)
            return false
        }
        if overflow { finish(.failure(WebPageError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let code = (error as? URLError)?.code
            finish(.failure(code == .timedOut ? WebPageError.timedOut : WebPageError.transportFailure))
            return
        }
        let (shouldFinish, result) = state.withLock { state -> (Bool, Result<(Data, HTTPURLResponse), any Error>?) in
            state.completed = true
            if enforcePublicPeer && !hasCustomProtocolClasses && state.metrics == nil {
                return (false, nil)
            }
            return (true, self.evaluateCompletion(state: &state))
        }
        if shouldFinish, let result {
            finish(result)
        }
    }
}
