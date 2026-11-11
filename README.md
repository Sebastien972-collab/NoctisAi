<!-- Created by Sébastien DAGUIN -->

# Noctis 🌘

Noctis is a personal command-line AI assistant, developed in Swift for macOS. It uses **Ministral 3 14B Instruct**, in 4-bit quantized MLX format, to generate its responses locally and stream them incrementally to the terminal.

The project includes streaming conversation and a `web_search` tool connected to SearXNG. Persistent memory and a Vapor API are not yet implemented.

The package exposes the `Noctis` library, which can be imported into an application, the `NoctisAgent` library, and the `NoctisCLI` executable for the terminal.

## SwiftPM consumers and releases

`NoctisAgent` is an internal target of this package, using the sources under
`NoctisAgent/Sources/NoctisAgent`; consumers do not need a separate local package.
Its tests are included in the root package test suite. The nested manifest remains
available for testing the standalone agent runtime.

`mlx-swift-lm` is pinned to the stable `3.32.3` release, with its optional
FoundationModels integration disabled. Versioned SwiftPM packages cannot depend
on branch-based or local-path packages. Keep all remote dependencies versioned
when preparing a Noctis release.

The existing `0.1.0` tag still contains the old manifest and is not repaired by
merging this change. Fullmoon currently requests Noctis starting at `0.1.0` with
an up-to-next-major requirement. It will need a newly validated SemVer release
containing this fix, followed by package resolution, to consume the correction.
Do not move `0.1.0`; publish a new tag only after release validation.

## Localization

French is the base language (`defaultLocalization: "fr"`); English is also available. Each target uses a single `Resources/Localizable.xcstrings` and its own `Bundle.module`: errors for `Noctis`, terminal messages for `NoctisCLI`.

Use hierarchical semantic keys in snake_case, never displayed text:
`error.network.timeout`, `console.status.ready`, `console.error.details`.
In this Foundation package, write the literal key with its French default value and a comment:

```swift
String(
    localized: "error.network.timeout",
    defaultValue: "Le délai de la requête Web est dépassé.",
    bundle: .module,
    comment: "La requête Web a dépassé le délai autorisé."
)
```

Keep variables in `defaultValue` using native interpolation, without concatenation.
For quantities, use catalog plural variants; an exit code is not a quantity and does not require pluralization.
Build in Xcode to extract new keys, then check French and English values in the catalogs. Model instructions, technical identifiers, and commands like `exit` are not translated.
The host application must declare the supported languages. SwiftUI previews and Fullmoon visual validation are performed in its host repository.

## Global CLI

Noctis remains a general-purpose personal assistant: conversation, learning, reflection,
questions and local documents. A working directory does not change its identity or turn it
into a programming agent. Its existing system prompt and MLX model are preserved.

### Prerequisites

- macOS 15 or later on Apple Silicon, with enough memory for Ministral 3 14B (4-bit).
- Swift 6.4 or later and the selected Xcode installation, including its Metal Toolchain component.
- Git and network access for initial Swift package resolution. The existing model downloads
  from Hugging Face only if its local cache is incomplete; no other model is selected.
- No Homebrew, Docker, remote inference service or `sudo` is required.

Check `swift --version` and `xcode-select -p` before installing. See Apple's documentation
on [additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
if the Metal compiler is unavailable.

### Install and launch

From your trusted checkout:

```sh
scripts/install.sh
```

The script uses the selected Swift/Xcode to build `NoctisCLI` in Release. It copies the
executable **and all SwiftPM resource bundles, including MLX's Metal library**, checks their
SHA-256 checksums, then runs help, version and diagnostics before activation. Build failures
leave the previous installation active. A lock prevents concurrent installation/uninstallation.

The command is installed at `~/.local/bin/noctis`. If needed, add this to `~/.zshrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Open a new terminal, then:

```sh
cd ~/Documents
noctis
```

The current directory is retained as the initial read-only workspace. Opening its directory
descriptor does not enumerate its contents or put documents into the model. No model load
or download happens at the welcome screen; the first actual question loads the configured
model. Later turns reuse its weights, conversation history and system instructions.

```text
✦ Noctis
  Assistant personnel · IA locale

  Bonjour, installe-toi.
  Je suis là. Comment puis-je t’aider ?

›
```

For development, `swift run NoctisCLI` remains available. A fully explicit scope is also supported:

```sh
noctis --workspace /absolute/folder/path
```

### Commands and input

| Command | Behavior |
| --- | --- |
| `noctis --help` | Help, without loading the model |
| `noctis --version` | Installed Git revision/version, without loading the model |
| `noctis doctor` | Architecture and installed resource checks; never runs inference |
| `noctis update` | Install the latest stable release after integrity and provenance verification |
| `noctis update --check` | Check versions and release notes without installing |
| `noctis update --dev` | Build a precise revision of main after interactive confirmation |
| `noctis update --rollback` | Restore the previous verified installation |
| `/help` | Interactive help |
| `/clear` | Reset conversation context and session input history; retain model weights |
| `/model` | Show the configured model ID |
| `/workspace` | Show the authorized directory |
| `/workspace /absolute/path` | Ask for terminal confirmation before changing directory scope |
| `/workspace off` | Revoke local access and restore the existing Web-enabled conversation |
| `/permissions` | Show the effective policy and limitations |
| `/exit`, `exit`, Ctrl+D | Leave the session |

In an interactive terminal, use ↑/↓ for session history, backspace to edit the end of the line,
and Ctrl+U to clear it. Long input scrolls horizontally to fit the terminal. End a line with
`\` to continue the same message on the next line. Ctrl+C discards the current input or cancels
an active model load/generation and permits the next turn. Cancellation joins the existing
MLX cleanup path; an in-progress load/prefill may take time to finish safely.

Input is limited to 64 KiB per message. Input history is in memory only, capped at 100 entries
and 256 KiB; it is discarded on exit or `/clear`. Conversation context stays in the running MLX
session; use `/clear` to release the context of a long conversation. No persistent memory is added.

Responses stream incrementally. Interactive colored terminals render headings, bold, inline
code and fenced code blocks; other Markdown stays readable as text. Lines wrap naturally to the
terminal width. `NO_COLOR`, `TERM=dumb` and redirected output disable styling. Model-generated
terminal controls are filtered. Redirected input accepts newline-separated prompts and the same
backslash continuation convention; it never accepts interactive permission grants.

### Workspace and permissions

The host authorizes the workspace, never the LLM. `AuthorizedWorkspace` pins the root inode and
opens descendants with descriptor-relative `openat` and `O_NOFOLLOW`:

- Absolute descendant paths, traversal, symbolic links, non-regular files and hard links are refused.
- Known sensitive names (`.env*`, private keys, credentials, tokens, `.ssh`, `.aws`, `.codex`, etc.)
  are blocked, including when supplied as the workspace root or an ancestor.
- Text reads are limited to 64 KiB. Listing, recursive search, tool results and tool calls are bounded.
- Tools are available when needed for a user request, without automatic startup exploration.
- A new directory outside the current scope requires an explicit `--workspace` flag or a live
  terminal confirmation. Model output, file contents and piped text cannot approve a scope change.

**Writing, deleting, renaming and system command execution are disabled.** No write/exec tool is
exposed, so there is no autonomous execution mode or unsafe shell interpolation. This deliberately
limits this first CLI version rather than claiming that confirmation alone provides OS isolation.
A future write/exec implementation will need its own validation, preview and confirmation flow.

These descriptor checks are not an operating-system sandbox. Name filtering cannot detect a
secret stored under an ordinary name; authorize only folders you intend Noctis to consult.

The existing engine separates local-file and Web contexts: Web search is unavailable while a
workspace is authorized. `/workspace off` resets history before exposing Web tools, so local file
contents do not carry over into Web-enabled context. Changing scopes also resets conversation
context. This explicit separation remains a limitation of this release.

The optional existing SearXNG runtime starts only when needed. If its configuration is invalid,
a diagnostic is displayed and ordinary conversation remains available. `doctor` describes the
optional Web setup without starting a service, loading a model or probing the network.

### Updates and restoration

Stable versions are Semantic Versioning tags (`0.2.0` or `v0.2.0`); `main` is ongoing
work and can contain untested changes. Stable discovery reads every GitHub tags page, ignores
prereleases, compares numeric versions and never downgrades. A new tag without compatible release
assets is reported, but cannot be installed. There is no source-build fallback on the stable channel.

```sh
noctis --version
noctis update --check
noctis update
noctis update --rollback
```

The binary embeds its version, channel and full source commit in a read-only Mach-O section.
`--version` displays the short commit. Moving or editing `version.txt` does not change it. Bare
`swift build` binaries report `unknown (local)` and require reinstalling with `scripts/install.sh`
to enable stable comparisons. Source installations derive their version from Git tags and mark
tracked local changes as dirty. Updating legacy installations first requires running the new installer
from a trusted checkout.

Stable installation requires **GitHub CLI (`gh`)** in `/opt/homebrew/bin` or `/usr/local/bin`,
with `gh auth login` configured and support for `gh attestation verify --source-ref`. A checksum
alone is insufficient: the updater uses GitHub CLI's Sigstore verifier to require provenance from
`Sebastien972-collab/NoctisAi/.github/workflows/release-cli.yml`, the exact version tag and a
GitHub-hosted runner. Authentication or provenance failures stop before any executable is run.
See the [GitHub verification documentation](https://cli.github.com/manual/gh_attestation_verify).
This trusts the official repository's release workflow and GitHub/Sigstore identities, not a tag
alone. Compromise of the authorized release workflow remains outside this trust boundary.

The distribution includes the CLI, localization bundles and MLX Metal resources. It targets macOS 15+
on Apple Silicon. Archives containing traversal paths, symbolic links, hard links or special files
are rejected. Downloads use HTTPS, bounded request/resource timeouts and private temporary files;
interrupted downloads never reach the installation. `--check` only uses temporary files and makes no
changes to the installation, model caches or preferences.

Installations remain under `~/.local/share/noctis/versions`. The manager validates the executable's
real path, the command symlink, directory ownership and permissions. It never elevates privileges.
`NOCTIS_PREFIX=/absolute/prefix` must match a custom installation. Symlinked prefixes are refused.
A shared install lock prevents concurrent operations. Files are copied and verified on the same
filesystem before an atomic replacement of `current`; post-activation failure restores the old link.
`previous` retains the old working directory. Integrity manifests cover every regular application file
before rollback; the old installer's checksum manifests are also supported. These local checks detect
corruption; they are not publisher authentication. Models, Hugging Face caches, conversations,
workspace permissions, preferences and the SearXNG runtime are never changed.

Cancellation before activation leaves the old version active. Process termination or power loss can
leave `.install-lock` and an unused version directory. After checking that no installation process is
running, remove only the empty lock directory and run `noctis update --rollback` if needed. The
prechecked candidate and previous version remain on disk; no automatic cleanup deletes backups.

For development only:

```sh
noctis update --dev
```

This requires an interactive terminal, Git, Xcode/Swift 6.4+ and the Metal compiler. It fetches `main`
from the fixed official HTTPS repository into a private temporary checkout with Git hooks and URL
rewrites disabled. It prints the exact commit and requires typing `yes` before building that revision.
Building Swift packages can execute dependency plugins; confirmation explicitly grants that trust.
The installed updater's build recipe is used, never a downloaded installer script. It copies and
checks resources and the CLI before activation. It does not pull, reset or modify your working copy.
This channel uses HTTPS source trust, not stable artifact attestations, and requires network access
and sufficient disk space to compile. An update is never exposed as a model tool or triggered at startup.

The existing independently trusted OpenPGP source-update route remains available from a trusted
checkout (`scripts/update.sh --tag vX.Y.Z --revision FULL_40_CHARACTER_COMMIT`). It requires an
annotated tag signed by a locally trusted key. It does not bypass the stable artifact verifier.

### Publishing a stable CLI release

The tag-triggered `.github/workflows/release-cli.yml` validates a stable tag, runs `swift test`,
SwiftLint and the isolated installation checks, builds Release, packages `noctis-macos-arm64.tar`
and its SHA-256 file, creates a GitHub artifact provenance attestation, then verifies that attestation
before publishing with generated release notes. No release is published after a failed check.
Actions are pinned to commit IDs. The workflow uses GitHub-hosted Apple Silicon `macos-26`,
the image’s `/Applications/Xcode.app`, Metal and a pinned Swift 6.4.1 setup action. That action
uses Swiftly with signature verification enabled. Check runner/toolchain availability before the
first publication; setup or compiler failures stop publication. Do not
replace it with a self-hosted runner: the client's provenance policy rejects those attestations.

Before the first release, merge this implementation, check GitHub-hosted runner/toolchain availability,
ensure repository permissions permit `contents: write`, `id-token: write`, `attestations: write`, `artifact-metadata: write` and
verify GitHub CLI supports the required verification flags. Review the release changes, create and
push a new stable tag **only after maintainer approval**, then review the resulting release assets
and test a real update from an earlier installation. Do not retag an existing version. This change
does not create or push tags, publish releases or alter existing ones. On November 11, 2026,
the repository has tags `0.1.0` and `0.2.0` and no GitHub Releases; real publisher-authenticated
stable installation remains unvalidated until the first compatible release exists.

### Uninstall

```sh
scripts/uninstall.sh
```

Only this installer's command link and managed versions are removed. Hugging Face model caches,
SearXNG runtime, personal documents and shell configuration are retained. An unrelated existing
`noctis` executable is never overwritten or removed. `NOCTIS_PREFIX=/absolute/prefix` can be used
consistently with all scripts to install or test under a different prefix.

### CLI validation

```sh
swift build -c release --product NoctisCLI
swift test
scripts/lint.sh
scripts/test-install.sh
python3 scripts/test-terminal.py
```

The installation integration test uses a temporary prefix with spaces, launches from outside the
checkout, exercises install/reinstall/rollback/uninstall, rejects corruption and failed builds,
and checks that unrelated executables are preserved. It never installs into your real PATH or
loads a model. Updater tests mock GitHub downloads and provenance failures, exercise real temporary
installation directories, numeric version ordering, stable tag filtering, archive/path rejection,
backup integrity, post-activation restoration and preservation of user data. Existing conversation,
workspace permissions and model lazy-loading suites remain part of `swift test`.

Validation on November 11, 2026: `swift test` passes **120 tests** (106 engine/CLI tests and
14 agent tests). SwiftLint 0.65.1 passes. Release packaging passes help/version/doctor; the isolated
installation script passes reinstall, real CLI rollback in both directions, noninteractive development
refusal, corruption rejection, failed compilation and uninstall. A live `update --check` finds `0.2.0`
and reports its missing GitHub Release without creating a model cache. Changing `version.txt`
does not change the embedded binary version. Development revision selection/confirmation and
publisher identity failures are tested with mocks; archive extraction and activation use real local files.

Existing engine/toolchain warnings are separate from updater validation: the unreachable `default`
in `MLXAgentModel.swift:196`, SwiftTerm's build helper linking a macOS 12 target against macOS 13+
Swift runtime libraries, and an XCBuild cache warning about the existing MLX bundle's missing creator.
No engine, dependency or SDK versions were changed to suppress these warnings.

A complete authenticated GitHub stable-update round trip requires a published attested release;
source rebuilding of a remote development revision also requires explicit terminal confirmation.
Local fixture and smoke tests do not establish either of those production scenarios.

## Configuration

The current values are defined in [NoctisConfiguration.swift](Sources/Noctis/Core/Configuration/NoctisConfiguration.swift):

| Property | Value | Role |
| --- | --- | --- |
| `modelID` | `mlx-community/Ministral-3-14B-Instruct-2512-4bit` | Model used by the MLX loader |
| `assistantName` | `Noctis` | Name displayed at startup |
| `exitCommand` | `exit` | Command to exit the conversation |

The system prompt is located in [NoctisIdentity.swift](Sources/Noctis/Core/Enum/NoctisIdentity.swift). It defines the identity, tone, current capabilities, and behavioral rules of the assistant. It is passed to `ChatSession` when the model loads.

Modifying these constants or instructions requires recompilation. Dynamic selection of the model or system prompt is not available in the current interface.

## Code Organization

```text
Sources/
├── Noctis/
│   ├── Features/Web/              # Services, tools, and web page reading
│   └── Core/
│       ├── AI/
│       │   ├── AIModelService.swift
│       │   ├── MLXModelService.swift
│       │   └── ModelSessionWorker.swift
│       ├── Configuration/
│       │   └── NoctisConfiguration.swift
│       └── Enum/
│           ├── MLXModelServiceError.swift
│           └── NoctisIdentity.swift
└── NoctisCLI/
    ├── NoctisCLI.swift
    ├── Domain/
    │   └── NoctisApplication.swift
    └── Interface/
        └── ConsoleInterface.swift
Tests/
└── NoctisTests/
    ├── HTTPWebPageServiceTests.swift
    ├── MLXModelServiceTests.swift
    ├── MockAIModelService.swift
    ├── NoctisApplicationTests.swift
    ├── NoctisTests.swift           # ModelConcurrencyTests
    └── SearXNGServiceTests.swift
```

| Element | Actual Responsibility |
| --- | --- |
| `Noctis` | Library containing the AI engine and web tools |
| `NoctisCLI` | Asynchronous entry point; wires the console application to the library engine |
| `NoctisApplication` | Loads the injected engine, reads and filters input, consumes streams, and reports errors |
| `AIModelService` | `Sendable` inference contract: loading, generation, consumption, and cancellation |
| `MLXModelService` | Actor coordinating loading and reserving one generation at a time |
| `ModelSessionWorker` | Creates and uses the mutable session inside its worker task and awaits its cleanup |
| `ConsoleInterface` | Groups console methods; this struct is not yet used by `NoctisApplication` |
| `NoctisConfiguration` | Configuration constants compiled with the application |
| `NoctisIdentity` | System instructions passed to the session |

The `Noctis` and `NoctisCLI` folders constitute **two distinct modules**. The executable target `NoctisCLI` depends on the `Noctis` library and uses it via `import Noctis`. MLX and Web dependencies are declared in the library; the console depends on `Noctis` and the local `NoctisAgent` package.

**There is no `ChatService` in this revision.** Conversation handling is managed directly by `NoctisApplication`. The tests cover this existing code; no extra service or refactoring was added for testing purposes.

## Engine Contract and Conversation Lifecycle

The `AIModelService` protocol exposes:

```swift
func load() async throws
func load(progress: @escaping @Sendable (AIModelLoadPhase) -> Void) async throws
func resetConversation(history: [AIChatMessage]) async throws
func cancelGeneration() async
func withResponse(
    prompt: String,
    consume: @Sendable (AsyncThrowingStream<String, Error>) async throws -> Void
) async throws
func generate(prompt: String) async throws -> AsyncThrowingStream<String, Error>
```

1. `NoctisApplication` receives its engine via constructor injection.
2. `run()` calls `load()` before accepting interactions.
3. `MLXModelService.load()` loads the model and creates a `ChatSession` with the system prompt.
4. Each non-empty message, trimmed of surrounding whitespace, is forwarded to `withResponse(prompt:consume:)`.
5. The application iterates over the stream using `for try await` and immediately prints each chunk.
6. The same engine instance is reused for subsequent messages; the loop does not call `load()` on every interaction.

Two points of failure can occur during generation:

- **Before returning a stream**: the asynchronous request may fail. The MLX implementation throws `MLXModelServiceError.modelNotLoaded` if no session has been loaded and `generationInProgress` if a generation is already reserved.
- **While consuming the stream**: the asynchronous iteration may throw an error after zero or more chunks. Previously printed chunks remain visible.

The application displays these errors and then accepts the next prompt. In contrast, an initial failure in `load()` halts the conversation startup. `run()` prints the error and terminates normally without rethrowing to its caller.

`withResponse` also waits for generation cleanup following consumption, error, or cancellation. Existing concurrency tests verify these transitions using mock sessions.

## Dependencies

The manifest declares the following packages:

| Package | Products directly used by the target |
| --- | --- |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | `MLXLMCommon`, `MLXVLM`, `MLXHuggingFace` |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | `HuggingFace` |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | `Tokenizers` |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | `SwiftSoup`, used to extract text from HTML pages |

`Package.resolved` pins exact revisions, including `mlx-swift-lm` declared on the `main` branch. Keeping this file ensures reproducible revisions across developers.

The presence of `MLXVLM` in the dependencies does not provide an image input interface: the current CLI transmits text prompts only.

### Resetting Without Reloading Weights

`resetConversation(history:)` restores structured messages (`user`, `assistant`, `system`) while retaining the model in memory. The actor reserves this operation, cancels any ongoing generation, and waits for cleanup before forwarding the command to the worker. New generations are rejected during reset. System instructions are combined into the single system message expected by Ministral; other messages retain their role and content.

`load(progress:)` exposes the `downloading`, `loading`, and `ready` phases. `load()` remains available and is idempotent on an already loaded engine. These phases apply strictly to the model, not web requests.

## Tests

The `NoctisTests` target depends on `Noctis` and `NoctisCLI`. Engine tests use `@testable import Noctis`, and console tests also import `NoctisCLI`. The suite exclusively uses **Swift Testing** for test structure and assertions, without extra testing dependencies and without XCTest.

Run the entire suite:

```sh
swift test
```

To use only the revisions from the existing lockfile:

```sh
swift test --disable-automatic-resolution
```

Run a specific suite:

```sh
swift test --filter NoctisApplicationTests
swift test --filter MLXModelServiceTests
```

### Model and Console Isolation

- `MockAIModelService` conforms to the production protocol and provides predefined responses or errors.
- Its calls are recorded using a `Mutex` from the standard `Synchronization` library. It is `Sendable` without `@unchecked Sendable`.
- The mock creates no background tasks. Chunks are yielded into a finite, deterministic stream; no arbitrary delays or sleeps are used.
- `NoctisApplication` scenarios use [Swift Testing isolated processes](https://docs.swift.org/latest/documentation/testing/exit-testing/). Each process receives an in-memory standard input; outputs are captured by Swift Testing. The main test process retains its standard input.
- The console suite enforces a one-minute timeout per test to detect regressions that could hang the input loop.
- `MLXModelServiceTests` verifies that generation is rejected before any load. `ModelConcurrencyTests` injects a simulated session factory to test the actual service without creating a real MLX session.

Reset tests verify structured history, lack of reloading, failure modes, and wait-for-cleanup behavior. Cache tests create a temporary installation and an offline transport: two consecutive clients reuse it without issuing network requests, while an incomplete cache triggers the download path.

**No unit test loads or downloads Ministral.** However, compiling tests for the first time may fetch and compile Swift packages declared by the project, including MLX dependencies: runtime model isolation does not eliminate compile-time dependencies.

### Covered Scenarios

| Suite | Scenarios |
| --- | --- |
| `NoctisApplicationTests` | Simulated load before first prompt; text transmission; chunk order and Unicode rendering |
| `NoctisApplicationTests` | Successive calls without engine reload; response ordering |
| `NoctisApplicationTests` | Empty messages, spaces, and tabs; prompt trimming |
| `NoctisApplicationTests` | `exit` command handling (case-insensitivity, whitespace); EOF on standard input |
| `NoctisApplicationTests` | Loading error: display and absence of generation |
| `NoctisApplicationTests` | Error before stream creation: display and recovery on next prompt |
| `NoctisApplicationTests` | Stream error before any chunk or after partial response: preserved text and recovery |
| `NoctisApplicationTests` | Stream completed without chunks or consisting of empty chunks |
| `MLXModelServiceTests` | `modelNotLoaded` error with regular, empty, or whitespace prompt; localized description |
| `ModelConcurrencyTests` | Concurrent loads and generations, errors, cancellation, cleanup, and recovery with mock sessions |
| `HTTPWebPageServiceTests` | Rejection of URLs using unsupported schemes |

The `SearXNGServiceTests` integration test is disabled by default. With Docker and SearXNG running, it can be executed explicitly with `RUN_SEARXNG_TESTS=1 swift test --filter SearXNGServiceTests`; it executes live network searches.

### Test Suite Limitations

- Model downloading, actual model loading, tokenizer, Metal, and response quality require separate integration validation. They are not exercised by unit tests.
- Tests verify application behavior against simulated errors; they do not prove the network behavior of the MLX loader.
- Simulated streams are finite and pre-populated. Tests verify consumption, ordering, and errors without measuring real latency or MLX concurrent token production.
- Concurrency tests use mock sessions; they do not validate actual GPU execution. CLI interactions remain sequential.
- There is no `ChatService` test since that type does not exist. Adding this service, memory, or the Vapor API in the future will require dedicated contracts and tests.

## Troubleshooting Common Issues

| Symptom | Verification |
| --- | --- |
| Manifest requires a different Swift version | Check `swift --version` and the selected compiler in Xcode or toolchain manager |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Verify Metal component installation in Xcode and selection by the build system |
| Metal is installed but SwiftPM continues using a different launcher | Check Swift and Metal toolchain selection in the command; do not change package versions to mask this environment issue |
| Package resolution fails | Check network access and consistency between `Package.swift` and `Package.resolved` |
| Real launch fails during loading | Check displayed error, model access, and Mac resources; do not use real execution to verify unit tests |

## Planned Enhancements

The current foundation can subsequently accommodate a dedicated conversation service, persistent memory, and a Vapor API. These features are not included in this release. Characterization tests for the console serve as a regression safety net when adding them.

## Local Web Search with SearXNG

Prerequisites: Docker with its engine running (such as Docker Desktop on macOS), Docker Compose, and OpenSSL. The service uses the official `searxng/searxng` image with default settings, and HTML and JSON formats enabled.

From the repository root, create the local configuration without overwriting an existing `.env`:

```sh
cp -n .env.example .env
chmod 600 .env
openssl rand -hex 32
```

Replace `replace_with_random_secret` in `.env` with the generated key. Retain any existing key. `SEARXNG_PORT` defaults to `8888` and can be adjusted in the same file. `.env` and its variants are gitignored; only `.env.example`, containing no secrets, is tracked in version control.

Compose reads `SEARXNG_SECRET_KEY` from `.env` and forwards it as **`SEARXNG_SECRET`**, the variable recognized by the [official SearXNG loader](https://docs.searxng.org/admin/settings/settings_server.html). `SEARXNG_SECRET_KEY` is not a native SearXNG variable. No secrets are stored in `settings.yml`, and Compose rejects a missing or empty key. The `.env` file is for Docker; it is not read by the Swift application.

Validate and start:

```sh
docker compose config --quiet
docker compose up -d
docker compose ps
```

The `--quiet` option validates the configuration without printing the interpolated secret. The instance is accessible solely on `http://127.0.0.1:8888` by default. Persistent configuration is mounted from `infrastructure/searxng`; the limiter and public instance mode are disabled for this private local setup, requiring no additional Valkey service.

Test a real JSON search query (adjust port if necessary):

```sh
curl -fsS -G "http://127.0.0.1:8888/search" \
  --data-urlencode "q=Swift programming language" \
  --data-urlencode "format=json"
```

The response should contain a `results` array with usable titles, URLs, and snippets. SearXNG queries external search engines: internet access is required, and certain engines may be temporarily unavailable.

To stop the service for this project:

```sh
docker compose down
```

In this mode, Docker must be running to enable web searches via the `web_search` tool. Model inference remains local. The Swift client uses `http://127.0.0.1:8888` by default; changing the Docker port requires updating the URL injected into `SearXNGService`.

## Embedded SearXNG on macOS Without Docker

`EmbeddedSearXNGService` implements the same `WebSearchService` protocol and reuses the existing bounded URLSession transport (2 MiB, HTTP timeouts, no redirects, no proxies, cookies, or shared credentials). This code is excluded on iOS.

- No Python process is spawned before the first valid search.
- Single process, single Werkzeug WSGI server without reloader, one search at a time.
  A concurrent request receives `EmbeddedSearXNGError.busy`; the interface may defer it.
  SearXNG maintains its own threads for search engines: this is not a global CPU limitation.
- Ephemeral port bound to `127.0.0.1`, independent of Docker port 8888.
  The parent waits for a private readiness file, followed by an authenticated health response.
- Randomized SearXNG secret and HTTP token regenerated on each startup. Only GET
  `/search` and `/healthz` presenting the token are accepted; requests with `Origin` headers are rejected.
  Forwarded proxy headers are stripped. Another local user/process with equivalent system privileges remains outside this token's isolation boundary.
- Shuts down after **120 s of inactivity**, measured after request completion; never during
  an ongoing search. Startup timeout capped at **45 s**. Both durations are configurable at initialization.
- Cancellation, HTTP error, or crash: drops the worker, then restarts on the next request.
  No automatic request retries, and no silent fallback to Docker upon error.
- `shutdown()` cancels active searches, closes the lifecycle pipe, and terminates the process
  (SIGTERM, then SIGKILL after 500 ms if needed). Python also terminates when the parent pipe closes, including if the application crashes.

Settings and caches are created in a private temporary directory, deleted upon shutdown.
An abrupt crash of the parent process may leave this directory until cleaned up by the operating system. Python stdout/stderr are discarded to avoid logging queries and secrets; errors expose the failure type and exit code without Python tracebacks.
The local Werkzeug server is suitable for this private integration, not for a public instance.

### Development Runtime

For the macOS CLI, install the runtime once from the repository:

```sh
python3 infrastructure/searxng/setup_runtime.py
swift run
```

The script requires Python 3.10+ and Git, downloads the pinned SearXNG revision, and installs its dependencies into `~/Library/Application Support/Noctis/SearXNG/venv`, without a global Python installation. It refuses to overwrite an existing installation. The CLI detects this runtime after checking the explicit environment variable and embedded runtime, announcing the active mode at startup.
This local installation is intended for the CLI; it does not replace signed packaging for Fullmoon.
Runtime-specific errors are retained by the dispatcher to facilitate diagnostics.

Prepare Python **3.10 or newer**, the dependencies for the chosen SearXNG revision, and the `searx` package with its data, translations, templates, and static assets.
macOS does not provide an out-of-the-box SearXNG runtime. The application neither downloads nor installs Python or dependencies during runtime.

Example using an external checkout of SearXNG sources, outside the Noctis repository:

```sh
python3 -m venv /absolute/path/searxng-venv
/absolute/path/searxng-venv/bin/python -m pip install setuptools wheel
/absolute/path/searxng-venv/bin/python -m pip install -r /absolute/path/searxng/requirements.txt
/absolute/path/searxng-venv/bin/python -m pip install --no-build-isolation --no-deps /absolute/path/searxng
NOCTIS_SEARXNG_PYTHON=/absolute/path/searxng-venv/bin/python swift run NoctisCLI
```

The path must be absolute. The environment variable is read only by the CLI; `.env` remains reserved for Docker. Without this variable, an embedded bundle runtime, or a local CLI installation, the legacy service remains selected; the CLI indicates this and displays the installation command.
The CLI `exit` command explicitly invokes `shutdown()`.

### SwiftUI Application and Packaging

The repository contains the package and CLI; the Fullmoon SwiftUI interface resides in a separate repository.
`MLXModelService()` automatically detects the runtime at this location in the main bundle:

```text
Noctis.app/Contents/Resources/SearXNG/python/bin/python3
```

For explicit shutdown in the app, retain the service and inject it:

```swift
let search = try EmbeddedSearXNGService(pythonExecutable: pythonURL)
let model = MLXModelService(webSearchService: search)
// In application termination flow, before confirming quit:
await search.shutdown()
```

On macOS, use AppKit's delayed termination mechanism if shutdown must be awaited.
A SwiftUI view disappearance does not necessarily signify application termination.
The lifecycle pipe also covers process termination without this explicit call.

For distribution, provide a **self-contained, relocatable Python** for each target architecture, with SearXNG and its dependencies pre-installed. A Homebrew venv does not qualify: it often references the developer environment. The repository contains no Python binaries.
The staging script rejects venvs and symlinks pointing outside the runtime, copies the runtime, and verifies Python imports and prefixes after relocation:

```sh
python3 infrastructure/searxng/package_runtime.py /path/to/standalone-python /path/to/Noctis.app
```

The destination application must already exist, and the runtime folder must not be present.
Run this staging **prior to final code signing**. It does not build Python, does not sign the application, and alone does not guarantee the portability of all native libraries.
Pin Python, the SearXNG revision, and dependencies; preserve notices and corresponding SearXNG sources (AGPL-3.0-or-later); then validate on a clean Mac without a development environment.

For a sandboxed application, the parent process must declare `com.apple.security.network.client` and `com.apple.security.network.server`. The child Python binary must be signed to inherit the sandbox with exactly these two App Sandbox entitlement keys:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.inherit</key><true/>
```

Sign executables, frameworks, dylibs, and Python extensions with the appropriate distribution identity from the inside out, then sign the application with Hardened Runtime; verify signature and notarization. Do not systematically add library validation exemptions or ATS global network exceptions. Verify local HTTP connections against the target bundle's ATS policy.
Fullmoon includes a staging and signing build phase for the standalone runtime; see its README for setup instructions. Its sandbox retains client networking and adds server networking.
Archiving and App Store validation must be performed within that separate project.

The script `setup_runtime.py --standalone --destination /path/to/new-runtime` sets up relocatable Python 3.13.13 for the Mac architecture via `uv`, then installs the same SearXNG revision as the CLI runtime. No downloads occur within the app.
`package_runtime.py --sign IDENTITY --entitlements /path/to/helper.entitlements` signs libraries and the interpreter after verifying imports inside the staged bundle.

### iOS Host

Fullmoon provides `IOSWebSearchService`, conforming to `WebSearchService`, and injects it into `MLXModelService(webSearchService:)` exclusively on iOS. Python is embedded directly into the app process via its iOS framework; `EmbeddedSearXNGService` remains restricted to macOS.
`infrastructure/searxng/setup_ios_runtime.py` prepares arm64 native dependencies for iPhone and Simulator without altering Mac runtime files. See the Fullmoon README for setup commands and cancellation behavior.

References: [SearXNG installation](https://docs.searxng.org/admin/installation-searxng.html), [server settings](https://docs.searxng.org/admin/settings/settings_server.html), [Apple sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

### Validation and Performance Boundaries

`EmbeddedSearXNGServiceTests` uses standard Python and a local mock WSGI application, without external search engines or MLX models: lazy validation, reuse, authentication, rejection of unauthorized origins and routes, idle shutdown, cancellations, timeout, parent process exit, concurrency, crash, and recovery. Existing transport tests remain applicable.
Live network testing is explicitly enabled by providing a runtime path:

```sh
swift test
NOCTIS_TEST_SEARXNG_PYTHON=/absolute/path/searxng-venv/bin/python swift test --filter realRuntimeSmoke
```

Validation on November 5, 2026: SearXNG `cccbc9e158b0ac3bb2158e9841a647a5bec57b57`, Python 3.15, and Swift 6.4.1 on Apple Silicon. The final targeted suite passes with **17 tests** across three test suites, including existing transport and real runtime. The two network runs measured approximately **2.47 s then 37.48 s cold**, and **0.90 s then 0.76 s warm**, returning 41 results. These timings encompass initialization and external search engines; they vary considerably depending on network conditions and do not represent a formal benchmark. No measurements of RAM, battery consumption, or impact during MLX inference were conducted. Startup and searches consume system resources; no additional result caching is implemented. Searches require internet connectivity and may return zero results if engines are blocked or unavailable.

Following the fix to CLI runtime discovery, the full build succeeds with available local artifacts. The complete test suite passes; live network tests remain opt-in.
The runtime provisioned by the script returned 41 results through the real URLSession service (approximately 2.26 s cold and 1.14 s warm during that run). Fullmoon bundle signing and end-to-end operation with MLX generation remain to be validated.

## Code Quality and Continuous Integration

Run `./scripts/lint.sh` from macOS. The script uses SwiftLint **0.65.1**, downloading it to a temporary cache if needed and verifying its SHA-256 checksum.
`SWIFTLINT_BIN` can be supplied to use a local installation of the same version.

The `.swiftlint.yml` configuration enables standard rules. The baseline records existing violations to prevent a sweeping reformat; any new violation fails in strict mode. Do not regenerate the baseline to bypass a regression.

GitHub Actions runs these checks on pull requests and pushes to `main`.
Jobs run on the Apple Silicon `xcode-27` runner, with Xcode 27.2 for Swift 6.4 and Metal. No model weights are downloaded during test runs.

The test job uses the `Noctis-Package` Xcode scheme to also build translation catalogs and Metal shaders:

```sh
xcodebuild -scheme Noctis-Package -destination 'platform=macOS' -skipMacroValidation test
```
