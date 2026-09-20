# Implementation validation

Validation followed implementation. No TDD, permanent test target, fake worker or scaffold test files remain in the repository. Temporary fixtures used synthetic data and were deleted after the checks.

## Environment

- Apple M3 Max / arm64, macOS 27.2.
- Xcode 27.0, Swift 6.4 compiler, Swift 6 language mode, macOS 14 deployment target.
- Local published multilingual MLX and general Core ML model artifacts from the sibling repositories.

## Completed

| Area | Observed result |
|---|---|
| Swift | Debug and Release builds, strict concurrency typechecking, and warnings-as-errors build passed. |
| Packaging | Release `.app` built, ad-hoc signed, passed strict signature verification and launched successfully. |
| App launch | Real AppKit `.app` launched. Windows are initialized after application launch; constructing the panel before assigning the delegate was found and corrected. |
| Clipboard capture | Three distinct synthetic entries copied through TextEdit appeared in the actual app. Source attribution follows the OS frontmost application; background UI automation is not equivalent to normal foreground copying. |
| Storage | Multi-item and representation boundaries, SHA-256 deduplication, 20-entry bounds, 8 MiB limit, raw-byte persistence, atomic replacement and 0600/0700 permissions passed. |
| Shutdown | Initial load plus immediate deletion, saves in flight, concurrent flush, disabling persistence, demo isolation, and preserving a corrupt initial history file passed. |
| Swift/Python connection | Partial JSON reads, FIFO, large stderr, cancellation, bad JSON, wrong IDs, oversized response, EOF, exit, restart, stop and actual 45-second timeout passed. |
| MLX runtime | Real subprocess inference and 17 protocol scenarios passed. |
| Core ML runtime | Same 17 protocol scenarios passed with the general multilingual CPU+GPU model. |
| Offline/fallback | Missing-model fallback, secure-field bypass, empty-history bypass, request validation and recovery after an oversized line passed. |
| Token budgets | 512- and 1024-token limits respected with valid JSON context and cursor-near text. |
| Independent setup | Clean temporary uv environments installed each published runtime and completed real inference using existing model files. Both sibling-reuse paths also passed. |
| Native panel | Actual light/dark rendering, real-model promotion, arrow-key selection, matching preview, source search, no-results state, disabled empty actions and settings layout inspected through Computer Use. |
| IME/responder handling | Review found and corrected interception of marked-text Enter/arrow keys and Command-Delete in the search field. |
| Accessibility context | A separate development process read the expected context from a controlled native target's text field. |
| Cross-process paste | With the controlled target in the foreground, the real PasteController dispatched Command-V and the target text view contained the exact expected inserted text. When another app was foreground, dispatch was refused. |
| Cleanup | Original clipboard contents restored; temporary native applications, verification sources, private snapshots and data directories removed. |

The native paste fixture used a regular AppKit text view with the standard Edit/Paste menu, and the same production ClipboardStore, ContextReader and PasteController files. A dispatched event alone was not accepted as proof: insertion was verified in the destination text view. This establishes the supported path, not compatibility with every third-party app.

## Recommendation quality boundary

The investigation compared multiple strategies on four synthetic fine-grained tasks. The shipped general ranker got email, a specific issue URL, and a staging API URL right. It did not reliably distinguish local-only `git branch` from `git branch -a/-r`. No task-specific Git-command rule was added to make the example pass.

Laya supplies a soft content-type signal. Field evidence and lexical/numeric matching also affect the result. No model probability is presented as the accuracy of the recommended clipboard item. See [ENGINE.md](ENGINE.md) for the measured observations and constraints.

## Not claimed

- A broad real-user recommendation accuracy benchmark.
- Automatic paste compatibility with every browser, editor, terminal or secure field.
- App-level accessibility permission granted for the final Finder-launched build. CLI development permission inheritance differs from the separately installed app; users must authorize the app themselves.
- A fresh network download of all model weights during validation; setup with existing local weights was exercised.
- Login-at-startup behavior after an actual macOS logout/reboot.
- Developer ID notarization, a bundled standalone Python distribution, or Intel Mac inference support.

The delivered `.app` is a locally signed development build. The runtime and models are configured separately. No macOS security settings were changed to obtain these results.
