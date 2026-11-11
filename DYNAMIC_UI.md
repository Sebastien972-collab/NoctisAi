# Dynamic UI architecture

Noctis keeps inference, presentation data, and terminal rendering separate:

- `Noctis` owns MLX, conversation, Web and workspace capabilities. It does not import SwiftTUI.
- `NoctisPresentation` owns the versioned, renderer-independent UI protocol, validation, component allowlist, typed events and atomic reconciliation.
- `NoctisCLI` owns the SwiftTUI app and maps validated nodes to terminal views.

SwiftTUI is pinned to 0.16.0. This release requires Swift 6.4 and macOS 15 and already provides retained reconciliation, partial cell rendering, Observation, focus, controls, layout, animation and reduced-motion behavior. Noctis does not implement a second cell diff engine. SwiftTerm was removed because the Noctis engine no longer embeds terminals and SwiftTUI has not depended on SwiftTerm since 0.13.

## Protocol

`InterfaceDescription` contains `schemaVersion`, `revision`, a stable interface identifier and a tree of stable node identifiers. `ComponentRegistry` is the allowlist for text, Markdown, headings, lists, tables, cards, progress, status, sources, charts, choices and confirmations. Nodes are data only; they cannot contain Swift, shell commands, host objects or arbitrary component names.

The model may append one trailing `<noctis-ui>…</noctis-ui>` envelope to an otherwise normal response. The stream accumulator preserves conversational streaming and decodes the envelope only after its closing marker. Invalid envelopes are shown as ordinary text, so structured generation cannot erase or interrupt the answer.

Structured output is advisory. The current MLX model has no proven constrained-decoding grammar for this schema, so Noctis uses one generation with an explicit instruction and a strict decoder. It does not launch a second LLM request. Ordinary answers should omit UI entirely.

## Validation and security

Default limits are 256 KiB encoded input, 128 nodes, depth 8, 32 children per node, 8 actions per node and 16 KiB per string. Validation rejects duplicate or malformed identifiers, unknown properties, invalid colors, non-finite numbers, unsupported schema versions and incompatible children. Web or document content remains a string value.

Actions contain only registered identifiers and labels. They produce `InterfaceEvent` values. They cannot change workspace permissions or invoke the shell. Sensitive workspace authorization remains in the existing host-controlled confirmation flow.

## Mutation rules

`InterfaceMutation` supports property updates, append, remove, replace, reorder and dismiss. The reconciler checks the interface identifier, exact base revision, sequential next revision, target existence, operation compatibility and all resource limits. It builds and validates a copy before the observable state swaps, so a rejected mutation preserves the prior interface and interactive identifiers.

## Rendering and performance

`ConversationUIState` is a `@MainActor @Observable` source of truth. SwiftTUI observes only properties read by a view and performs retained tree/cell reconciliation. Streaming appends to the active message, while Dynamic UI changes replace only the validated interface revision. Non-interactive pipes retain the previous deterministic line interface.

The reproducible Swift Testing benchmark applies and validates 1,000 targeted mutations. On the development machine it completed in about 15 ms in a debug test run. A 24-column `RenderOnce` test verifies bounded narrow-terminal output. Full CPU, memory and Instruments measurements should be repeated on release hardware with the production MLX model; loading that model is deliberately excluded from unit tests.

## Current limitations

- Markdown nodes currently use SwiftTUI paragraph layout; rich Markdown token styling remains handled by the legacy non-interactive renderer.
- Chart nodes use composable textual children. No additional chart dependency is included.
- Local-only selection changes are supported by the event boundary, but richer table navigation and persisted selection state remain future renderer work.
- Structured generation is validated and tested with fixtures, but has not been qualified against every configured local MLX model.
