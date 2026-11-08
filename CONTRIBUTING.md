<!-- Created by Sébastien DAGUIN -->

# Contributing to NoctisAI

Please propose focused changes that remain consistent with the existing codebase.

## Setting Up the Environment

- Use an Apple Silicon Mac for the currently validated MLX/Metal toolchain.
- Install Xcode and a Swift 6.4 or later toolchain, in accordance with `Package.swift`.
- Install the Xcode Metal component if it is missing: `xcodebuild -downloadComponent MetalToolchain`.
- Ensure you have network access to fetch dependencies and SwiftLint on the first run.

The library source files are located in `Sources/Noctis`, the CLI sources in `Sources/NoctisCLI`, and the tests in `Tests/NoctisTests`.

## Working on a Branch

Create a dedicated branch from an up-to-date `main`, such as `feat/short-name`, `fix/short-name`, or `docs/short-name`. Keep each contribution focused on a single topic.

All contributions must go through a pull request targeting `main`, including minor fixes. Direct pushes, force pushes, and branch deletions on `main` are strictly prohibited. Merging is reserved for **Sébastien DAGUIN (`Sebastien972-collab`)**.

## Style and Scope

Adhere to the existing architecture, naming conventions, and patterns. Favor simple modifications within existing files; avoid unnecessary abstractions and unrelated refactoring. Verify all usages before deleting code.

Limit comments to design decisions or logic that genuinely require explanation. Preserve existing headers and third-party library attributions. Do not sign files with the name of an AI tool.

Changes to architecture, dependencies, SDKs, or build files must fall within the stated scope and be clearly explained in the pull request.

## Validating Before Submitting a Pull Request

From the package root:

```sh
./scripts/lint.sh
xcodebuild -scheme Noctis-Package -destination 'platform=macOS' \
  -skipMacroValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
```

The script uses SwiftLint 0.65.1, downloaded to a temporary cache and verified via SHA-256. Running `SWIFTLINT_BIN=/path/to/swiftlint ./scripts/lint.sh` allows you to use a local installation of the same version.

The baseline `.swiftlint-baseline.json` records violations present when linting was first introduced. New violations are blocking. Do not regenerate the baseline to bypass an error; fix the affected code instead.

Add targeted tests whenever a logic change or regression warrants it. Standard tests do not require downloading model weights. Live SearXNG tests are optional and require an explicitly configured runtime; see [README.md](README.md). Do not claim they have been run if they were not executed.

## Describing Your Contribution

The pull request must describe the problem, the resulting behavior, and the checks performed. State any limitations, unexecuted tests, and potential public API changes. Avoid formatting or dependency changes unrelated to the task.

Do not commit secrets, `.env` files, model weights, caches, Python runtimes, or build artifacts. Comply with the licenses and notices of all dependencies used.
