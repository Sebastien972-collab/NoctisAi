// Created by Sébastien DAGUIN

import Foundation
import NIOCore
import NIOSSL
import Security

/// Original-host system trust, without secondary AIA/OCSP network requests.
struct PublicWebTLS: Sendable {
    private static let queue = DispatchQueue(label: "noctis.public-tls", qos: .utility)
    private static let slots = DispatchSemaphore(value: 2)
    let anchors: [Data]

    init(anchors: [Data] = []) { self.anchors = anchors }

    func verify(_ certificates: [NIOSSLCertificate], hostname: String,
                promise: EventLoopPromise<NIOSSLVerificationResult>) {
        guard certificates.count <= 16, Self.slots.wait(timeout: .now()) == .success else {
            promise.succeed(.failed)
            return
        }
        let data = try? certificates.map { Data(try $0.toDERBytes()) }
        Self.queue.async {
            defer { Self.slots.signal() }
            guard let data, let trust = try? makeTrust(certificates: data, hostname: hostname),
                  SecTrustEvaluateWithError(trust, nil) else {
                promise.succeed(.failed)
                return
            }
            promise.succeed(.certificateVerified)
        }
    }

    func makeTrust(certificates: [Data], hostname: String) throws -> SecTrust {
        guard !certificates.isEmpty, certificates.count <= 16 else { throw WebPageError.tlsFailure }
        let chain = certificates.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard chain.count == certificates.count else { throw WebPageError.tlsFailure }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        guard let revocation = SecPolicyCreateRevocation(
            CFOptionFlags(kSecRevocationUseAnyAvailableMethod | kSecRevocationNetworkAccessDisabled)
        ) else { throw WebPageError.tlsFailure }
        let policies = [policy, revocation] as CFArray
        guard SecTrustCreateWithCertificates(chain as CFArray, policies, &trust) == errSecSuccess,
              let trust, SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else {
            throw WebPageError.tlsFailure
        }
        // Controlled tests supply their own root. Production always uses system roots.
        if !anchors.isEmpty {
            let roots = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard roots.count == anchors.count,
                  SecTrustSetAnchorCertificates(trust, roots as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
                throw WebPageError.tlsFailure
            }
        }
        return trust
    }
}
