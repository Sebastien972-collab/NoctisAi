# Public Web Security — Noctis

## Pinned public transport — November 12, 2026

**Current implementation: `web_open` is enabled in Web-only sessions when the TLS context can
initialize. It remains absent from workspace sessions.** The following historical reports describe
the earlier blocked implementation and do not describe this transport.

### Isolation and dependencies

Work is isolated in the managed worktree `noctis-secure-web-transport`, branch
`feat/pinned-public-web-transport`, based on `596ff50`. The original checkout is not edited.
Only transport-required dependencies were added: SwiftNIO **2.105.0**, SwiftNIO SSL **2.37.5**,
and transitive swift-atomics **1.3.1**. Previously locked dependency revisions are retained.
No SDK/deployment target, Docker, remote LLM, telemetry, filesystem permission or generated
application-resource changes are introduced. SwiftNIO's HTTP parser and NIOSSL's TLS implementation
are used; Noctis does not implement TLS, HTTP framing or decompression.

### Actual outbound path

`MLXChatSession` → per-turn `NoctisToolDispatcher` → `WebToolDispatcher` → `HTTPWebPageService`
→ `SecureWebTransport` → bounded DNS worker → `PublicWebDestination` → numeric NIOPosix
socket → NIOSSL → NIOHTTP1 → bounded SwiftSoup/SwiftReadability extraction.

- URL syntax continues to use SafeURLKit: HTTPS/443 only, no userinfo, ambiguous URL forms,
  IP-literal URL hosts, local/reserved names or fragments. Public IP literals in user URLs
  remain deliberately unsupported.
- `getaddrinfo` resolves the original host once with TCP/443 and both address families. Every
  returned address must pass SafeURLKit's public-address policy; empty/over-64 sets and any
  mixed public/private set are rejected before connecting. One numeric address is retained
  from that immutable snapshot, respecting resolver ordering. No fallback, retry or second
  hostname resolution occurs. This closes the application-level validation/connect TOCTOU gap.
- `ClientBootstrap.connect(to: SocketAddress)` opens the numeric socket. The connected peer is
  checked against the selected endpoint before HTTP is written. NIOPosix does not consult
  URLSession, proxy environment variables, PAC, HTTP proxy discovery or a fallback transport.
- Original hostname is passed to NIOSSL for SNI, and to `SecPolicyCreateSSL` for hostname
  verification. TLS 1.2 minimum; HTTP/1.1 ALPN only. `PublicWebTLS` validates the complete chain
  against normal system trust with Security.framework. Its custom verification callback replaces
  library trust evaluation specifically to call `SecTrustSetNetworkFetchAllowed(false)` before
  evaluation, and adds a revocation policy with `kSecRevocationNetworkAccessDisabled`:
  certificate AIA/OCSP/CRL locations cannot cause secondary network fetches.
- Test fixtures can supply their own test root via internal types. Production uses system roots;
  there is no public insecure mode, trust bypass or arbitrary-root option on MLXModelService.
- GET sends only the explicit URL path/query, original Host, fixed Accept/Accept-Encoding,
  User-Agent and Connection headers. No conversation, local file, cookies, credentials or Referer
  are automatically attached. The extraction response retains Content-Type only; Set-Cookie,
  authentication and unrelated server headers never enter the model output.
- All 3xx responses are rejected. Informational/upgrade responses, 206, unsupported MIME,
  duplicate sensitive framing headers, unsupported compression and ambiguous framing are rejected.
  Chunked framing is handled by NIO, not handwritten. Trailers are conservatively rejected.

Primary APIs inspected in the pinned source:
- [Numeric client bootstrap](https://github.com/apple/swift-nio/blob/2.105.0/Sources/NIOPosix/Bootstrap.swift)
- [NIO HTTP decoder and limits](https://github.com/apple/swift-nio/blob/2.105.0/Sources/NIOHTTP1/HTTPDecoder.swift)
- [NIOSSL client hostname/SNI contract](https://github.com/apple/swift-nio-ssl/blob/2.37.5/Sources/NIOSSL/NIOSSLClientHandler.swift)
- [NIOSSL custom verification contract](https://github.com/apple/swift-nio-ssl/blob/2.37.5/Sources/NIOSSL/SSLCallbacks.swift)

### Bounds, efficiency and cancellation

A shared one-thread NIO event loop and reusable TLS context avoid creating a networking runtime
per page. There is no connection pool or content cache in this first implementation. Independent
limits allow two concurrent public requests, two DNS workers and two trust-evaluation jobs. A
cancelled blocking DNS call keeps its worker slot until it actually returns; late DNS results cannot
start a connection. Busy slots reject promptly instead of accumulating an unbounded waiting queue.

Body limit is 2 MiB, with early Content-Length rejection and streaming byte checks. A separate
3-MiB encrypted-wire budget covers TLS handshake/header overhead before feeding the protocol
parsers. Socket reads are bounded to 32 KiB per receive allocation and one message per read cycle.
HTTP field/list/count limits are 8 KiB/32 KiB/100. Request deadline is 15 seconds from connection
setup through response; global network deadline is 30 seconds including DNS. Cancellation, failure,
timeout and success complete once and abort the socket below TLS rather than waiting for a malicious
peer's close_notify. The request slot is held until the actual socket closes.

Extraction runs off the caller/UI executor, at most two jobs simultaneously. SwiftSoup parses once;
its document is passed directly to SwiftReadability. Before parsing, input with over 20,000 '<'
markers is conservatively rejected; after parsing an iterative walk caps all nodes at 20,000 and
DOM depth at 128 before Readability transforms the tree. Existing Readability extensions remain.
Unused extracted HTML serialization is skipped: only title and main text are needed.
The model receives at most 20,000 content characters/64 KiB and 512 title characters/2 KiB, with
an accurate truncation flag. Empty bounded output is rejected. These limits reduce model context
cost and allocation pressure; no claim of a measured speedup or OS-wide memory ceiling is made.

### Model-facing controls and prompts

The effective registry still drives instructions, MLX schemas and dispatch. The registry may suppress
page opening with `allowsWebOpen: false`; enabling that parameter cannot bypass TLS availability
or workspace isolation. Noctis remains a general personal assistant. Its tool guidance describes
reading, summarizing and translating requested pages; it never grants development-agent privileges.

Code, independently of the prompt, admits a page URL only if it appears in the current user message
or is an actual normalized URL field returned by this turn's search. URLs buried in search snippets
or retrieved page text do not expand that set. URL query changes require their own authorization.
The set resets every turn. Page calls are capped at four, within the existing eight total tool calls.
Workspace mode declares neither Web tool and the per-turn dispatcher rejects both.

The page result is JSON with `trust: UNTRUSTED_EXTERNAL_DATA`, `status: retrieved`, verified URL,
title, extracted content and `isTruncated`. Structured encoding prevents structural envelope escape;
this label is not a model-behavior guarantee. Permanent security instructions explicitly reject page
requests to call tools, search secrets, change rules/language, hide information or split secrets across
requests. Reading/translating such instructions treats them as content. Failures are normalized and
do not expose certificate dumps, system paths or private error descriptions.

### Verification of this implementation

Final checks in this worktree:

- Dependency resolution succeeded; `Package.resolved` adds only the three required pins.
- `swift build --disable-sandbox --force-resolved-versions`: succeeded.
- `RUN_PUBLIC_WEB_SMOKE=1 swift test --disable-sandbox --force-resolved-versions`: **133 NoctisTests
  and 14 NoctisAgentTests, zero failures**. Two pre-existing live SearXNG tests are skipped.
- The opted-in public smoke test traverses the actual per-turn registry, dispatcher, production
  system TLS trust, network transport and HTML extraction for `https://www.swift.org/documentation/`.
  Verified status, original URL, nonempty title and extracted text. No model is loaded for this check.
- iOS Simulator arm64 library build via `xcodebuild`, with code signing disabled: **succeeded**
  on the final source version. Physical devices and App Store packaging were not tested.
- CLI `--help`: succeeded without loading the model.
- SwiftLint: succeeded, with the two existing complexity warnings in the extraction and search
  dispatcher functions. No lint configuration or baseline changed.
- `git diff --check`: succeeded.

Controlled tests cover real
TLS over numeric IPv4/IPv6 loopback sockets, original-domain SNI and HTTP Host, a test-root-trusted
chain, untrusted chain, wrong hostname, network-fetch-disabled trust, redirect/private destinations,
HTTP downgrade redirects, malformed/partial framing, compression, MIME, oversized fixed/chunked
bodies and headers, deadlines, cancellation, DNS-worker results, private/public/mixed IPv4/IPv6
address sets and immutable destination snapshots. No offensive third-party tests are used.

Model-facing tests use MLX's actual Ministral tool parser with strict schemas, plus mock services for
provenance, workspace isolation, output quoting/truncation, unknown tools and per-turn budgets.
Adversarial page instructions remain data and cannot authorize an extra URL through code.
These tests do not claim to prove what a real Ministral model will say or summarize.

### Remaining limitations and activation procedure

There is no separate insecure activation flag. In this branch the standard Web-only session includes
the tool if TLS initializes; use `/workspace off`, then provide a public HTTPS URL or request a search
and consult one of that turn's result URLs. Ordinary history resets on changing workspace permissions
are preserved. A URL referenced only in a previous turn must be provided again or rediscovered.

The OS routing table, local trust store and resolver infrastructure remain trusted. Application-level
numeric pinning cannot defend against a compromised OS or administrator-controlled routing/trust.
The DNS rebinding tests verify immutable address validation and numeric dialing composition, not a
hostile Internet DNS deployment. Conservative special-address policy may reject IPv6 transition
networks; a chosen unreachable public address fails without retrying another address.

System trust evaluation cannot fetch missing intermediates or online revocation data. Servers must
present a usable chain; cached system trust information may still be used. This is a compatibility
tradeoff required to exclude certificate-induced network requests. No independent security audit is
claimed. Cookies, authentication, redirects, compression and non-HTML downloads are unsupported.

The 30-second deadline bounds networking, not a preemptible HTML sandbox. SwiftSoup/Readability are
synchronous: cancellation is checked before/after parsing and during the bounded traversal, but cannot
interrupt a single parser operation. Parser/OS/TLS allocations are not a process-wide memory cap.
Prompt rules cannot guarantee resistance to every injection or detect a secret the user supplied in
an ordinary Web query. Provenance limits navigation; they do not infer semantic user intent. Model
inference, live upstream search and physical-device behavior require separate runtime validation.

## Historical prompt-only review — November 12, 2026

**`web_open` remains disabled. No public transport has been implemented or certified.**
The November 3 sections below are historical. This section describes the current change.

### Audit and transport decision

The real sources reviewed include `NoctisIdentity`, `MLXModelService`, `MLXAgentModel`,
`ToolRegistry`, the search schema and dispatcher, `PublicWebURLPolicy`, `HTTPWebPageService`,
`BoundedHTTPClient`, extraction tests, URLProtocol tests and the controlled Network.framework
integration server. The initial checkout was clean on `main`; work uses
`feat/secure-web-prompt-registry`. Dependencies, package configuration and generated files are unchanged.

The public page service and Web dispatcher both rejected opening, but the identity permanently
advertised search and denied local reading. The conversation actually replaces search with three
read-only tools when a workspace is authorized. The separate AgentModel path had the same identity
mismatch. Schema selection alone did not update those instructions after authorization changes.

The resolved SafeURLKit 0.2.0 source offers `validate(resolvedAddresses:)`, including IPv4/IPv6
reserved-address checks. These checks do **not** bind the following URLSession connection to the
checked addresses. BoundedHTTPClient remains an **internal SearXNG transport only**.

Native alternative examined: resolve all A/AAAA candidates, reject the entire set if any is
nonpublic, then create Network.framework connections to numeric endpoints, preserving the
original hostname in TLS SNI, certificate hostname validation and HTTP authority. This would
require a reviewed HTTP implementation above the connection, response framing and header limits,
trust-chain/hostname validation tests, connection/retry ownership, cancellation, deadlines,
and verified exclusion of proxies and alternate routes on all supported OS versions.
Network.framework is a viable building block, not proof that this complete transport exists.
We did not write a custom HTTP/TLS parser or add an unverified secure-looking wrapper.

Primary references examined:
- [Apple: Network.framework connection example](https://developer.apple.com/documentation/network/implementing-netcat-with-network-framework)
- [Apple: TLS server name](https://developer.apple.com/documentation/security/sec_protocol_options_set_tls_server_name(_:_:))
- [Apple: local-network TLS and certificate identity](https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls)
- [Apple: URLSession task metrics](https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics)

An isolated egress gateway would be an alternative, but none is deployed, audited or shipped for
macOS/iOS here. Adding one would introduce a separate service and its lifecycle. Neither architecture
has the controlled DNS/TLS/proxy test fixture required to substantiate the requested guarantees.
This is an implementation and verification gap, not a claim that native secure fetching is impossible.

### Implemented architecture

`NoctisSystemPromptBuilder` assembles, in deterministic order: permanent identity, core reliability,
security, effective tool instructions, dated runtime context, host-selected presentation. Identity
stays at its existing path to avoid an unnecessary move. Its personality, relationship with Sébastien,
critical thinking and guiding principles are retained; platform, tool names and terminal formatting
are no longer permanent identity facts. `NoctisIdentity.systemPrompt` remains an internal compatibility
accessor for the legacy Web-only scope; actual MLX sessions use the scoped builder.

`NoctisToolRegistry` is the capability snapshot consumed by prompt generation, MLX schemas and
`NoctisToolDispatcher`. It adapts the existing read-only `ToolRegistry` rather than replacing its
filesystem enforcement. Search descriptions come from its genuine schema. Workspace descriptions
come from the same schemas the local runtime uses. The ordinary chat dispatcher accepts only names
in that snapshot and allows at most eight calls per user turn (a fresh dispatcher each turn).
Workspace calls retain the existing eight-call/256-KiB cumulative output budget. In a Web turn,
the shared eight-call budget also bounds simultaneous search calls to eight.

The snapshot and date are refreshed before each ordinary response, including after loading/resetting
and authorization/revocation. Existing authorization history clearing, generation exclusion, deferred
model loading and cancellation synchronization remain in place. AgentModel uses its supplied local
schema subset for both instructions and MLX declarations. No new tool, filesystem permission,
telemetry, cloud LLM or automatic local-content transmission has been added.

Presentation is chosen by the host with `NoctisPresentationInstructions`: CLI explicitly uses
`.plainText`; library clients default to `.markdown` for simple text formatting. This is a
presentation capability, independent of macOS versus iOS. The builder takes an injectable date,
time zone and platform and includes no workspace path or secret.

`WebOpenTool` defines the reserved strict one-string `url` contract and shared validation.
Its schema is **never registered**, and the direct Web dispatcher still validates then returns
`publicAccessDisabled`, even with an injected page service. HTTPWebPageService independently blocks
all connections. There is no activation flag. Thus the effective `web_open` request budget is zero,
including concurrent requests; DNS, TLS and HTML fetching cannot be induced by this tool.
No success envelope or retrieval status is fabricated for a fetch that cannot occur.

The existing offline SwiftReadability extraction stays available for tests, now also rejecting
unsupported Content-Encoding. Body and parser limits remain 2 MiB/20,000 elements/20,000 text
characters. Internal HTTP timeouts can now only be tightened below 15 seconds/request and
30 seconds/resource, and redirects remain fixed at zero. Cookies, credentials and private cache
remain disabled. Synchronous DOM parsing still cannot be cancelled mid-parse.

### Validation of this change

- `swift package resolve`: initially blocked by the host compiler-cache permissions, then by nested
  `sandbox-exec`. `CLANG_MODULE_CACHE_PATH=/private/tmp/noctis-clang-cache swift package --disable-sandbox resolve`
  succeeded; cache-write warnings remain. No lockfile change.
- `swift build --disable-sandbox` with the same compiler cache: succeeded. Existing MLX adapter
  warning about an unreachable `default` remains.
- First `swift test --disable-sandbox`: failed with five issues because the restricted environment
  prohibited controlled loopback listeners / embedded mock servers. This failure is not hidden.
- Rerun with local networking allowed: **116 NoctisTests, 14 NoctisAgentTests, zero failures**.
  Two NoctisTests are skipped: opt-in live SearXNG runtime and upstream search smoke tests.
  Controlled HTTP transport, mocked embedded SearXNG lifecycle, workspace, CLI, streaming and
  deferred-loading suites passed. These do not load Ministral or contact live search engines.
- SwiftLint: successful with two complexity warnings in the existing extraction and Web dispatch
  functions. Configuration and baseline unchanged.
- Final rebuild and full test rerun after passing presentation through the AgentModel path:
  succeeded with the same counts; CLI `--help` also succeeded without model loading.
- `git diff --check`: succeeded.
- Physical-device and iOS Simulator compilation were not performed in this validation run.

New tests cover permanent
identity, deterministic order/date/time zone/platform, CLI versus app formatting, permission
changes, schema/prompt correspondence, dispatch for each announced tool, unknown/disabled names,
strict reserved arguments, concurrent call budgets and fail-closed opening. The actual MLX
Ministral tool-call parser accepts every declared tool under strict schema validation and rejects
unknown names and the disabled page-opening name. Existing tests exercise
SSRF URL syntax, controlled internal HTTP, malformed HTML, resource bounds and cancellation.
These tests demonstrate application policy and plumbing, **not actual Ministral inference**.

### Activation requirements and residual risks

No runtime setting enables page opening. Activation requires a reviewed transport enforcing validated
public IPs through every actual connection, standard trusted TLS with original hostname and SNI,
no redirect/proxy bypass, bounded framing/decompression/headers, and concurrency/deadline/cancellation
control. Only after this exists should the registry advertise `web_open` and its dispatcher call
the page service, returning a bounded `UNTRUSTED_EXTERNAL_DATA` envelope with verified URL, title,
main text, truncation and status. Keep the dispatcher and service independent fail-closed checks
until then.

Required but **not executed or proven for a public transport**: successful public HTTPS retrieval,
DNS rebinding, changed resolution between validation and connect, all IPv4/IPv6 connection candidates,
reconnection/proxy bypass, invalid TLS chain, wrong TLS hostname. Existing redirect tests concern
the internal HTTP client, not an enabled pinned public transport. No offensive third-party testing
was performed. Public fetching, reading, summarizing or translating a newly fetched page remains
unavailable; offline extraction and search snippets do not satisfy that functional criterion.

Prompts cannot guarantee injection resistance or detect every secret in a user-generated search
query. Only Swift permission gates enforce access. Host-provided extra system messages remain
trusted configuration. A configured search capability does not guarantee that SearXNG or an upstream
engine is reachable. Real model behavior, physical devices and live upstream engines require
separate runtime validation. Historical risks below still apply where not superseded.

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
