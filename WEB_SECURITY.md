# Web Security Audit and Hardening — November 3, 2026

## A. Initial Audit

Clean initial Git status, HEAD `f50aa58`. No commit created. The files actually present were inspected: SwiftPM manifest and lockfile, services, protocols, models, errors, dispatcher, MLX schema, ChatSession initialization, system instructions, tests, compose, and SearXNG configuration.

The active path is `ChatSession → web_search → WebToolDispatcher → SearXNGService → URLSession`. The page service existed, but no schema or operational `web_open` branch was exposed to the model.

| Criticality | Initial Finding | Impact |
| --- | --- | --- |
| Critical, latent | HTTPWebPageService accepts arbitrary HTTP/HTTPS, with no destination policy and with automatic redirects | Access to local services, cloud metadata, and private networks upon exposure |
| Critical, latent | No verification of the actual connected IP address | DNS rebinding; a pre-flight DNS check would leave a TOCTOU window |
| High | `data(for:)` in both services, without size limit | Unbounded downloads and allocations, compressed responses |
| High | Shared sessions, implicit redirects, and storage | Cookies, credentials, or requests potentially escaping the intended scope |
| High | Requests printed, unfiltered network errors surfaced | Disclosure of queries and network details |
| High | External results without untrusted data envelope | Prompt injection and induced tool calls; system prompt does not constitute a security boundary |
| Moderate | MIME verified via substring, UTF-8 only, no DOM element cap | Content confusion, incompatibilities, CPU exhaustion |
| Moderate | Near-absence of Web tests; real SearXNG test is optional | Unverified security guarantees |
| Residual | MLX pinned to revision on main, SearXNG latest image, and writable configuration mount | Supply chain monitoring and local service auditing required |

## B. Implemented Changes

Paths relative to the repository.

| File | Change, Problem Resolved, and Trade-offs |
| --- | --- |
| `Package.swift` | Adds SafeURLKit pinned to exactly 0.2.0. Centralizes sensitive URL parsing without reimplementing IP variations. New dependency restricted to Foundation. |
| `Package.resolved` | Locks SafeURLKit revision; no other dependency version changed. |
| `Sources/Noctis/Features/Web/Domain/PublicWebURLPolicy.swift` | Validates raw string via strict URLPolicy; normalized errors. HTTPS/443, no userinfo, special domain names, IP literals, non-empty fragments, or ambiguous strings. 2048-byte limit. Rejects public IPs and documentation domain names: deliberate restriction. Does not validate DNS. |
| `Sources/Noctis/Features/Web/Data/BoundedHTTPClient.swift` | Dedicated internal transport, ephemeral session per request, no cookies, cache, credential storage, or configured proxy. Rejects all redirects and any authentication beyond standard TLS evaluation. Checks HTTP status, exact MIME type, final URL, declared content length, and received bytes. Rejects 206 Partial Content. State protected by Mutex, cancellation, and single continuation. No @unchecked Sendable added to Noctis code. |
| `Sources/Noctis/Features/Web/Data/HTTPWebPageService.swift` | `open` rejects any public URL opening following validation, with no DNS query or network connection. Preserves offline extraction protocol: title, URL, Unicode, truncation, and main text. HTML/XHTML only; UTF-8 by default, ASCII and Windows-1252/Latin-1 explicitly declared. Rejects unknown encodings, empty content, and unparseable markup. The session parameter was removed because it allowed unconstrained transport. |
| `Sources/Noctis/Features/Web/Domain/Enum/WebPageError.swift` | Actionable errors without leaking URLs or sensitive diagnostics: size limit, compression, redirection, timeout, configuration, transport, missing content, and disabled page opening. |
| `Sources/Noctis/Features/Web/Domain/Repository/SearXNGService.swift` | Only the configured HTTP 127.0.0.1:port/search endpoint is accepted. Neither DNS, nor host/path/query chosen by the model. The port remains configurable by the program. JSON format required, bounded and properly encoded queries. URLProtocol injection for testing instead of a shared session. A remote instance or redirecting reverse proxy is no longer accepted. |
| `Sources/Noctis/Features/Web/Domain/Tools/WebToolDispatcher.swift` | Verifies exact expected arguments, query capped at 300 characters and 1200 bytes, stripped of control characters. Removes debug logs and masks unknown errors. UNTRUSTED_EXTERNAL_DATA JSON envelope; maximum 5 results returned out of the first 50 examined. Filtered URLs, titles capped at 512 characters/2048 bytes, snippets at 2000 characters/8000 bytes. Large Unicode grapheme clusters do not bypass byte limits. `web_open` validates then rejects, even with an injected service. The legacy `pasgeService` parameter is retained for compatibility. |
| `Sources/Noctis/Core/Enum/NoctisIdentity.swift` | Adds external data handling and privacy guidelines. No changes to the MLX engine or its capabilities. These instructions do not constitute a security boundary. |
| `Tests/NoctisTests/WebSecurityTests.swift` | URL matrix, public blocking and cancellation, redirect rejection, arguments validation, JSON envelope, sanitized errors, and Unicode budget. |
| `Tests/NoctisTests/BoundedHTTPClientTests.swift` | URLProtocol without mutable global state: success, status codes, MIME types, sizes, Content-Length, unexpected final URL, interruption, timeout, cancellation, and SearXNG isolation. No live network requests. |
| `Tests/NoctisTests/WebExtractionTests.swift` | Article extraction, missing title, malformed/empty HTML, missing content, Unicode, Windows-1252 encoding, exact boundary limit, and truncation. |
| `Tests/NoctisTests/WebTransportIntegrationTests.swift` | Network.framework server created by the test on an ephemeral loopback port: normal and oversized chunked encoding, redirects never followed, partial responses, idle timeout, global deadline despite continuous stream, cancellation, and SearXNG JSON parsing. No existing private services contacted. |
| `WEB_SECURITY.md` | This audit report and reactivation criteria. |

### Effective Limits

- Accumulated response body: 2 MiB per request, configurable downward; excess data is rejected before buffering and the task is cancelled.
- Idle/request timeout: 15 seconds; resource timeout: 30 seconds; configurable positive finite values.
- Redirects: **zero**, intentionally fixed. A public redirect, redirect loop, or hop to a private network is rejected on the first hop. No tests claim to allow public redirects.
- Compression: sends `Accept-Encoding: identity`, rejects any Content-Encoding other than identity before buffering the response body. This compatibility constraint avoids introducing a decompressor.
- Extraction: 2 MiB offline input limit, 20,000 Readability elements, 20,000 maximum text characters (configurable downward), 512-character title.
- Network bytes, DOM element count, and emitted characters are distinct boundaries.

SwiftReadability 0.3.3 was inspected in the resolved checkout. `Readability(html:url:options:)`, `parse()`, `ReadabilityResult.textContent`, and `maxElemsToParse` are genuine APIs. Both extensions remain active: `imageCarouselRecovery` transforms detected image galleries into figures; `publisherChromeCleanup` removes editorial clutter. They mutate the DOM and can affect content selection heuristics or remove legitimate text. In the inspected code, they do not load images, execute JavaScript, or issue network requests.

## C. Dependencies and Transport Decisions

SafeURLKit **0.2.0**, revision **e9c4eddcfd3e16669a19f46142f487d9b74fbc14**. Remote tags, Swift 6.2+ manifest, URLPolicy implementation, parsing, reserved names, and redirection delegate were examined. No independent audit of this young library is assumed.

References:
- [Source of used version](https://github.com/adamtheturtle/SafeURLKit/tree/0.2.0)
- [URLPolicy and DNS limits](https://github.com/adamtheturtle/SafeURLKit/blob/0.2.0/Sources/SafeURLKit/URLPolicy.swift)
- [Studied redirect delegate](https://github.com/adamtheturtle/SafeURLKit/blob/0.2.0/Sources/SafeURLKit/PolicyEnforcingRedirectDelegate.swift)
- [SwiftReadability 0.3.3](https://github.com/wolfyy970/swift-readability/tree/0.3.3)
- [URLSession delegate and redirects](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate)

The SafeURLKit delegate re-validates redirects and strips certain headers when origin changes. It does not verify the actual DNS connection and does not provide our hop budget. It explicitly declares itself `@unchecked Sendable`; Noctis does not instantiate it. Our verified `Sendable` delegate rejects all redirects unconditionally.

A pre-flight DNS resolution followed by `URLSession` would be insufficient. Connection metrics arrive too late to abort a connection attempt. A proper public transport must connect to the validated IP address while preserving Host header, SNI, and TLS certificate validation, supporting all address families, redirects, proxies, and reconnections. Re-architecting these layers on top of Network.framework would not be a reasonably verifiable fix here.

An isolated and audited egress proxy/gateway would provide an alternative solution, provided all bypass paths are eliminated and destinations are re-verified after resolution. No such gateway exists in the repository. No misleading "secure mode" or activation flag was added: blocking is the security mechanism actually delivered.

Existing dependencies remain unchanged: SwiftReadability 0.3.3, SwiftSoup 2.13.6, transitive swift-url 0.4.2, as well as MLX/HuggingFace dependencies and their locked revisions.

## D. Validation Actually Performed

- `swift package resolve`, `swift build`, and `swift test` initiated: initial nested sandbox failure, `sandbox-exec: sandbox_apply: Operation not permitted`.
- `swift package --disable-sandbox resolve`: **succeeded**. Unwritable SwiftPM cache warnings; no existing dependencies updated.
- `swift build --disable-sandbox`: **succeeded**. C++17 warnings in MLX generated Metal code, unrelated to the Web module.
- `swift test --disable-sandbox`: compilation succeeded, but test bundle code signing was rejected due to Finder/FileProvider extended attributes in `.build`. Targeted cleaning of FinderInfo was attempted; rebuilding reintroduces them. **Do not consider this command a success.**
- Xcode BuildProject, including test targets: **succeeded**. No Swift Concurrency errors; warning regarding AppIntents metadata without an associated framework.
- Xcode RunAllTests on final code revision: **100 tests, 99 passed, 0 failed, 1 skipped**.
- The skipped test is the pre-existing test requiring `RUN_SEARXNG_TESTS=1` and a live instance. Client compatibility is verified via URLProtocol and the controlled server; availability of the real Docker instance and its engines is not claimed.
- Diff reviewed and whitespace checks performed. No real secrets identified in changes; credentials present only as mock strings in test cases. No commit created.

Simulated tests do not prove protection against DNS rebinding or peer IP address enforcement. Integration testing uses a controlled HTTP loopback server to verify internal transport guarantees, not a public network or real DNS rebinding attack.

## E. Residual Security Risks

1. **DNS rebinding / TOCTOU**: unresolved for public URLs; neutralized for the tool by disallowing all public connections. Do not connect `BoundedHTTPClient` to `web_open`: it does not constitute a secure anti-SSRF transport.
2. **Prompt injection**: JSON envelope and system instructions reduce confusion without guaranteeing model behavior. Sensitive actions must remain strictly guarded in application code. `web_open` remains blocked regardless of model instructions.
3. **Search query privacy**: only the search query string is transmitted, without automatically injecting context, cookies, or credentials. However, a model may inadvertently echo sensitive user information into a query. No reliable semantic secret detection or per-search user consent mechanism is included in this release. SearXNG and upstream search engines receive queries; their logging and output handling are beyond this client's control.
4. **Resources**: the 2 MiB ceiling applies to the application buffer, not the entire memory footprint of Foundation, the kernel, or the HTML parser. Headers and low-level internal buffers belong to URLSession. Synchronous HTML parsing cannot be interrupted mid-operation; the DOM limit is enforced by Readability after parsing the document. There is no global memory cap across multiple concurrent requests.
5. **Compression**: compressed Content-Encoding headers are rejected; this does not prove a strict memory or CPU ceiling inside CFNetwork internal buffers. No hostile public servers can be reached via the page service.
6. **Encodings**: no heuristic meta tag charset detection, nor universal support for legacy page encodings. Content that cannot be decoded is rejected.
7. **Local service**: the SearXNG instance and host machine are trusted. A malicious local process occupying the configured port could forge search results. The public network policy never inherits this local trust exception.
8. **Supply chain**: SafeURLKit table updates require ongoing monitoring; no independent security audit is assumed. The latest Docker image tag, container network privileges, and writable configuration mount should be separately hardened prior to non-local deployment.

## F. Readiness Assessment

**NOT READY to enable `web_open` on arbitrary URLs generated by Ministral.**

The critical vulnerability is not obscured by superficial syntactic validation: page opening is disabled in both the service and the dispatcher, and its schema is not advertised to MLX. Local search and offline text extraction are preserved and tested.

To lift the restriction: provide a transport or egress proxy enforcing the actual validated IP address, verify behavior against dynamic DNS, IPv4/IPv6, redirects, reconnections, TLS/SNI, and guarantee the proxy cannot be bypassed, then establish an outbound privacy and user consent policy prior to activation. Simply modifying the system prompt, maintaining an allowlist of domain names, or resolving DNS before passing a URL to `URLSession` is insufficient.
