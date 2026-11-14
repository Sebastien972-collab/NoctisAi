<!-- Created by Sébastien DAGUIN -->

# Private beta release gates

Source changes alone do not qualify this release. Record the exact source commits, model snapshot,
OS, Xcode/Swift, device model, available RAM, build configuration and artifact checksum for every run.
Never move an existing tag. Publish a new compatible SemVer tag only after all gates pass.

## Automated gates

- SwiftLint 0.65.1, with the existing baseline unchanged. Local exemptions preserve existing multi-argument
  execution contracts, exhaustive wire/event switches and ordered streaming transactions; they do not
  disable the rules globally. Do not expand them to bypass new regressions.
- All root Swift tests, including the standalone NoctisAgent target, without model downloads or public
  network dependencies. Run the existing Fullmoon identity/persistence migration tests separately.
- Build the Noctis library for generic iOS and Fullmoon against the exact candidate revision. Never edit
  or discard unrelated local Fullmoon changes. Use isolated checkouts for qualification.
- Resolve the package in a fresh consumer, verify CLI localization bundles and Metal resources, and run
  `scripts/test-install.sh` against a disposable prefix. Verify help, version and doctor outside the checkout.
- Require the `SwiftLint`, `macOS build and tests` and `iOS library build` checks in GitHub branch rules.
  Workflow files define the jobs; repository administrators must confirm that these checks are required.

## Real model protocol

Use Release builds. Keep the configured Ministral 14B Mac / 3B iOS models. Run the fixed twenty scenarios
in `RealModelQualificationTests`, then thirty sequential short exchanges and three cancel/resume cycles.
Reaching the context limit must be reported clearly; it is not permission to erase the previous history.
Check natural answers and source grounding manually in addition to observing successful tool execution.

The automated Mac suite uses a controlled search service. Separately test real SearXNG startup,
search results, unavailable runtime, offline failure and cancellation. After a complete cached model
installation, restart and converse offline; record how network access was disabled. A cache unit test
is not evidence of a full model's offline restart.

On a physical iPhone, additionally check background/foreground transitions, interrupted downloads,
locked-device interruption, memory pressure, app relaunch, selected conversation, persisted history,
identity context and file security-scoped access if exposed by the host. Never overwrite a user's
installed app or production data for qualification. Use a separate beta identity or internal TestFlight.
A simulator or unsigned device build does not qualify any physical device.

Measure load time (new process with existing cache), first token, generated tokens/second, peak process
memory and cancellation cleanup. Distinguish MLX peak allocation from process RSS. Repeat warm runs.
Record failures and unexecuted scenarios; do not substitute a different model or report estimates as data.

## Distribution and observation

Build artifacts from a precise clean commit. Verify SHA-256, bundled resources, installation, failed
installation recovery and rollback. Stable CLI updating additionally needs an official release artifact
and valid GitHub provenance; local checksum validation does not establish publisher authentication.
Do not call a locally built artifact an attested release.

TestFlight needs a valid Apple signing identity and profiles covering Increased Memory Limit and iCloud.
Do not remove capabilities to get a green build. Upload only a build that passes the previous gates.
Observe the private beta for at least seven days and record start/end dates, tester device matrix,
crashes, recoverability and user-reported failures. No observation period starts before distribution.

Block promotion for any permission escape, reproducible crash, data loss, unrecoverable installation or
failed critical scenario. Rerun the affected validation after a correction. Public distribution adds
CLI signing/notarization and its own iOS distribution review.

## Dependency and model notices

The model cards for the configured [14B](https://huggingface.co/mlx-community/Ministral-3-14B-Instruct-2512-4bit)
and [3B](https://huggingface.co/mlx-community/Ministral-3-3B-Instruct-2512-4bit) conversions declare Apache-2.0.
Record the exact downloaded revision and preserve applicable notices; this declaration alone is not a
complete distribution license audit.

Swift dependencies include MIT, Apache-2.0 with Swift exceptions and BSD notices. Inventory the exact
resolved graph, including transitive C libraries, before distributing binaries. For embedded Python and
SearXNG, include the licenses and notices of the exact packaged runtime and its Python packages, and
review the applicable SearXNG source-availability requirements against its upstream license. The runtime
copied from an existing development installation has not been certified by a fresh packaging audit.
No repository license is selected or invented by this stabilization work.
