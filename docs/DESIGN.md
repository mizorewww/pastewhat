# PasteWhat: implementation design

## Product

PasteWhat is a native AppKit menu bar application for Apple silicon Macs (macOS 14+, macOS 15+ for the optional Core ML runtime). It retains the latest 20 distinct clipboard entries. Opening the panel captures the destination app and available focused-field context, recommends an entry, and promotes only that entry. The remaining entries keep their chronological order. Recommendation never overwrites the system clipboard; selecting Copy or Paste does.

The panel has a quiet translucent surface, a clear destination strip, search, a list with a highlighted recommendation, and a full-content preview. Keyboard navigation is a first-class path. The app follows the system appearance. Empty, loading, missing-model, and missing-permission states are explicit.

## Investigation and decisions

The sibling `laya-mlx` and `laya-coreml` repositories implement structured decision models, not text generation. Multilingual supports Chinese and a 1024-token total context. Both packages already provide validated tokenization, input preparation, inference and calibration. Reuse their Python APIs through a persistent subprocess; AppKit owns every UI and macOS integration. Do not port a tokenizer or inference graph speculatively.

Use MLX multilingual by default, with the general Core ML multilingual CPU+GPU export as an optional backend. The published ANE L96 model has only 96 total tokens and is inappropriate for this task. Model files remain outside Git. Load locally; no inference-time model downloads, network API or telemetry.

### Recommendation quality

Exploratory synthetic checks found that a 20-way choice over IDs biased toward a fixed ID, and independent candidate yes/no scores did not yield reliable rankings. Putting complete candidates into the choice labels is also lossy: `head_max_len=256` reduces a 20-way choice to roughly 12 tokens per label. These approaches are rejected.

The implemented approach uses Laya to infer a short distribution over the expected content type. It combines this soft signal with explicit field intent, lexical overlap (including CJK bigrams and URL/path/numeric fragments), content type, source app and a small recency preference. Strong field evidence wins over a contradictory model guess. Four exploratory synthetic cases passed with this approach; that is feasibility evidence, not a quality benchmark. Do not present model probabilities as recommendation accuracy. A model failure yields an honestly labeled local matching fallback.

Requests carry unique IDs and the app discards responses superseded by a newer context/history. Only bounded context and candidate excerpts go to the worker. Original clipboard payloads remain intact for pasting. Never execute clipboard text or treat it as an application command.

## macOS integration

- `NSStatusItem` plus an `NSPanel` created with `.nonactivatingPanel`; retain the destination PID before displaying it. Do not toggle its activation style dynamically.
- Poll `NSPasteboard.changeCount` on a tolerant timer. Deduplicate entries, suppress our own writes, cap payload size, and skip concealed/transient clipboard types and known password-manager sources.
- Preserve supported text, rich text, image and file URL representations, including multiple pasteboard items. Store at most 20 entries in Application Support with atomic replacement and restrictive permissions; allow pausing, deletion, clearing and disabling history persistence.
- Read a bounded snapshot of AX focused field metadata, selection and nearby text only when available. Do not read secure fields. AX permission is optional: app-only recommendations and manual copying still work.
- On macOS 15.4+, account for pasteboard access behavior and show restricted access clearly.
- For Paste, verify AX trust and destination liveness, dismiss the panel, yield activation, wait until the intended PID is active and only then synthesize Command-V. Otherwise leave the item copied with a clear explanation. Never send Enter.
- Register a Carbon hotkey rather than monitoring every global keystroke. Expose a conflict state and shortcut setting. Start-at-login is opt-in via `SMAppService`.

## Components

- `Models`: shared Codable value types and presentation metadata.
- `ClipboardStore`: bounded capture, deduplication, representations and persistence.
- `ContextReader`, `PasteController`, `GlobalHotKey`: operating-system integration.
- `EngineBridge`: a persistent `Process`/`Pipe` JSON-lines connection, timeout/restart and stale-response handling.
- `engine/worker.py`: real Laya loading, type inference and transparent ranking; stdout is protocol only.
- `AppController`: main-actor orchestration, status item, destination ownership and settings.
- AppKit panel/views: list, preview, search, actions and accessibility labels.

Swift Package Manager builds the executable; a script packages a regular `.app` with `LSUIElement`. The local build is ad-hoc signed. Public distribution signing/notarization is a separate release step, not claimed by a successful local build.

## Validation and commits

No TDD and no permanent scaffold test target. After each coherent implementation slice, build and inspect it before an atomic commit. Validate actual model loading and synthetic ranking, 20-item bounds and persistence behavior, JSON protocol failure handling, and the rendered AppKit UI. Any temporary verification scripts are removed after stabilization. Document limitations of OS permission-dependent checks rather than claiming unobserved results.

## Documentation consulted before implementation

Context7 library resolution and documentation queries were run for AppKit, Core ML, MLX Swift, Foundation, Swift Package Manager and GitHub CLI. Platform signatures were cross-checked with the installed Xcode SDK where necessary.

- [AppKit NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [AppKit NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard)
- [AppKit NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [Foundation Process](https://developer.apple.com/documentation/foundation/process)
- [Core ML MLModel](https://developer.apple.com/documentation/coreml/mlmodel)
- [Swift Package Manager](https://github.com/swiftlang/swift-package-manager)
- [GitHub CLI repository creation](https://cli.github.com/manual/gh_repo_create)
- Sibling Laya READMEs, API implementations, tokenizer preparation and published benchmark records. Short-request benchmark numbers do not describe PasteWhat's complete ranking latency.
