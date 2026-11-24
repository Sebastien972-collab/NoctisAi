# Local inference on iOS

`IOSModelService` is the iOS entry point for selecting an on-device inference provider.
It conforms to the existing `AIModelService` and `WorkspaceAuthorizing` interfaces.
The package continues to support iOS 17. The Foundation Models implementation is compiled
only for iOS and requires iOS 26 or later at runtime.

## Provider selection

| Preference | Apple model available | Apple model unavailable or iOS earlier than 26 |
| --- | --- | --- |
| `.automatic` (default) | On-device Foundation Models | Local MLX Ministral 3B |
| `.foundationModels` | On-device Foundation Models | Explicit availability error |
| `.mlx` | Local MLX Ministral 3B | Local MLX Ministral 3B |

MLX uses `mlx-community/Ministral-3-3B-Instruct-2512-4bit` on iOS. Its existing loader
may download the weights when they are not cached. Choosing Foundation Models does not load
MLX weights. The Apple model must already be available through the system.

Availability distinguishes an unsupported OS, an ineligible device, Apple Intelligence being
disabled, and the system model not being ready. The service exposes its availability and its
selected provider so the host can describe the actual state.

A successful `load()` fixes the provider for that service instance. Generation failures,
refusals, context overflow, and cancellation are propagated to the host. They never trigger a
second inference provider after output or tool execution. To change providers, finish or
cancel the active operation and create a new service with the required preference.

## Integrate the service in an iOS host

```swift
import Noctis

#if os(iOS)
let model = IOSModelService(preference: .automatic)
try await model.load()

try await model.withResponse(prompt: "Bonjour Noctis") { stream in
    for try await delta in stream {
        // Forward the incremental text to the host's existing UI update mechanism.
        print(delta, terminator: "")
    }
}
#endif
```

Hosts with a configured search service should preserve that injection:

```swift
#if os(iOS)
let model = IOSModelService(
    preference: .automatic,
    webSearchService: existingSearchService,
    presentation: .markdown
)
#endif
```

Here `existingSearchService` is the host's existing value conforming to `WebSearchService`,
such as Fullmoon's `IOSWebSearchService`. The search runtime remains owned by the host.
The standalone Noctis repository does not contain Fullmoon's application sources or update
its package pin; the host must adopt this entry point to enable automatic selection.
Constructing `MLXModelService` explicitly continues to request MLX.

`makeNoctisCLIAgent()` exposes structured agent events for a UI that needs tool activity.
`makeLLMClient()` exposes the selected client for hosts that already own an `Agent` loop.
The service and its clients share a generation lease, so they cannot concurrently use the
same provider. Workspace changes invalidate previously issued agents and clients.

Use `withResponse` for scoped consumption: returning early or throwing from the consumer
cancels the producer and waits for cleanup. `resetConversation(history:)` replaces the simple
chat history, while `conversationHistory` retains the structured tool exchanges generated
by the service. Workspace authorization remains an explicit host action.

## Local inference and network tools

Every Apple session explicitly uses `SystemLanguageModel.default`, Apple's on-device model.
There is no Private Cloud Compute provider, entitlement, or fallback in this implementation.
This controls Noctis's inference; it does not change system-wide Apple Intelligence settings.

Web search and page retrieval remain available through the existing authorized tools.
Those tools can use the network, and MLX can download uncached weights. Their network access
is separate from inference. Authorizing a local workspace retains the existing restriction
that removes web tools from that session.

Foundation Models produces proposed structured calls. AgentLoop validates and executes them
through the existing dispatcher. The provider never registers an executable Apple `Tool`.
Partial structured output cannot execute an action. Tool names, argument schemas, correlation
identifiers, and complete output are checked before a call reaches AgentLoop.

## Context and streaming

The Apple on-device model has a smaller context window than Ministral. The iOS Apple path
uses concise instructions, at most 12 recent messages, and tool results bounded to 4,096
characters through AgentLoop's existing truncation logic. Truncation preserves tool/result
groups and marks shortened tool results. These limits do not guarantee that every input fits;
an oversized request produces an explicit context error.

The adapter creates a fresh Apple session for each provider request and supplies the
structured conversation once. Foundation Models' cumulative snapshots are converted to
incremental text. Tool proposals are released only after the complete result is validated.
An error or cancellation is never presented as a successfully completed response.

The Apple path accepts text. Unsupported multimodal requests and provider-specific options
produce explicit errors instead of being silently ignored. For longer research or conversation
workflows, a host can explicitly select `.mlx` when constructing the service.

## Validation

Deterministic tests cover provider selection, structured output validation, incremental
text, and provider-independent AgentLoop behavior. They do not download weights or call a
live Apple model. Existing CI builds the iOS library and runs the macOS package tests.

On an Apple development machine, run the repository lint and package tests from
`CONTRIBUTING.md`, then build the iOS library:

```sh
xcodebuild -scheme Noctis -destination 'generic/platform=iOS' \
  -skipMacroValidation -skipPackagePluginValidation \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

Device qualification should exercise automatic Apple selection, each unavailability reason,
explicit MLX selection, streaming cancellation, and an authorized tool round trip. It should
also verify long-input errors and workspace revocation while an agent is active.
Mock tests and a successful library build do not establish live-model response quality.

## Apple references

- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Model availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.property)
- [Streaming responses](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:options:))
- [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
- [Private Cloud Compute is a separately selected model](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
