# Implementation validation

Validation followed implementation. No TDD, permanent test target, fake worker or scaffold test files remain in the repository. Temporary fixtures used synthetic data and were deleted after the checks. The subsequently requested accuracy dataset and offline evaluation runner are retained under `evaluations/` for reproducibility.

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

The original investigation compared strategies on four synthetic tasks. That feasibility check was replaced by a frozen 120-case evaluation for the category/preselection revision; see [full results](../evaluations/README.md). An evaluation subagent authored 40 development and 80 held-out scenarios before implementation tuning. The runner projects native context with actual production Swift code and measures real MLX, the same rules without a model, and a preselected 32-case Core ML subset.

On the 80 held-out cases, decision accuracy improved from 51/80 to 60/80 and incorrect promotion on no-answer tasks fell from 17/17 to 2/17. However, correct promotion of answerable tasks fell from 51/63 to 45/63 as coverage fell to 60%. **The no-regression target for held-out answerable Top-1 failed.** Precision is conditional on choosing to recommend and must be reported with coverage; 93.75% precision does not mean 93.75% of all tasks succeed.

Preselection retained an acceptable answer in all 97 answerable cases, including answers at the twentieth history position. On held-out data, the model and no-model ablation made identical decisions. The observed benefits primarily came from retrieval/format handling and abstention, not demonstrated additional Laya semantic understanding. The Core ML subset matched MLX recommended IDs and decision categories in 32/32 cases.

The revised Debug/warnings-as-errors and Release builds passed, and the packaged app passed signature verification. The actual Release panel retained all eight isolated demo entries; search still found the Xcode entry excluded from the recommendation shortlist. Native target display continued to show Safari while inference used the browser category. This revision did not change clipboard capture or paste dispatch, whose earlier integration validation is recorded above.

An after-launch signature check caught Python creating `__pycache__` while importing the new ranking module before `main()`. The worker now disables bytecode writes before local imports; the native process also sets the environment flag, and the build script recreates generated engine resources. Importing the packaged worker with that environment variable deliberately unset, then running the actual app with Laya, both left the signature valid and no bytecode inside the bundle.

The final packaged worker then repeated all 120 MLX cases. Recommendation IDs, decision states and shortlisted IDs matched the frozen evaluation in 120/120 cases; ranking and native projection hashes were unchanged. See the `packaged-bce862a-*` artifacts in the evaluation results.

The revised protocol also passed 11 synthetic boundary/recovery checks, including identity-field rejection, invalid capabilities, duplicate records/keys, a secure-field bypass and recovery after an oversized request. Real MLX tokenization passed all three question schemas at both 512- and 1024-token budgets, retained valid JSON and the cursor-near marker, and used zero new forwards for a repeated cached context. These checks used temporary inline fixtures, not stored test targets or real clipboard data.

No model probability is presented as recommendation accuracy. Small-candidate direct choice was additionally probed on development data, found order-sensitive, and not enabled. No task-specific mapping was added for an individual command or a failed held-out example. See [ENGINE.md](ENGINE.md) for the runtime and protocol details.

## Not claimed

- A broad real-user recommendation accuracy benchmark.
- Automatic paste compatibility with every browser, editor, terminal or secure field.
- App-level accessibility permission granted for the final Finder-launched build. CLI development permission inheritance differs from the separately installed app; users must authorize the app themselves.
- A fresh network download of all model weights during validation; setup with existing local weights was exercised.
- Login-at-startup behavior after an actual macOS logout/reboot.
- Developer ID notarization, a bundled standalone Python distribution, or Intel Mac inference support.

The delivered `.app` is a locally signed development build. The runtime and models are configured separately. No macOS security settings were changed to obtain these results.
