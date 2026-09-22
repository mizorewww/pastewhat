# PasteWhat: implementation design

## Product

PasteWhat is a native AppKit menu bar application for Apple silicon Macs (macOS 14+, macOS 15+ for the optional Core ML runtime). It retains the latest 20 distinct clipboard entries. Opening the panel captures the destination app and available focused-field context, recommends an entry, and promotes only that entry. The remaining entries keep their chronological order. Recommendation never overwrites the system clipboard; selecting Copy or Paste does.

The panel has a quiet translucent surface, a clear destination strip, search, a list with a highlighted recommendation, and a full-content preview. Keyboard navigation is a first-class path. The app follows the system appearance. Empty, loading, missing-model, and missing-permission states are explicit.

## Investigation and decisions

The sibling `laya-mlx` and `laya-coreml` repositories implement structured decision models, not text generation. Multilingual supports Chinese and a 1024-token total context. Both packages already provide validated tokenization, input preparation, inference and calibration. Reuse their Python APIs through a persistent subprocess; AppKit owns every UI and macOS integration. Do not port a tokenizer or inference graph speculatively.

Use MLX multilingual by default, with the general Core ML multilingual CPU+GPU export as an optional backend. The published ANE L96 model has only 96 total tokens and is inappropriate for this task. Model files remain outside Git. Local backends never download at inference time. An explicitly selected Jev backend sends projected context and candidate excerpts to TypeSafe; settings disclose this and the UI labels cloud recommendations.

### Recommendation quality

Exploratory synthetic checks found that a 20-way choice over IDs biased toward a fixed ID, and independent candidate yes/no scores did not yield reliable rankings. Putting complete candidates into the choice labels is also lossy: `head_max_len=256` reduces a 20-way choice to roughly 12 tokens per label. These approaches are rejected.

The current approach first projects native `AppContext` into a separate `ModelContext`: application category, focused-field metadata and nearby text. Real app names, bundle IDs, PIDs and raw window titles do not cross this boundary. Known bundle identifiers map locally to stable categories; unrecognized applications remain `unknown`. The category is a weak hint, subordinate to field/task evidence.

The worker extracts actual representation capabilities, whole-value content shapes, typed entities, lexical/CJK terms, flags, negation and code structure. Only the 10 most recent entries are sent for recommendation; the AppKit panel retains and searches every history entry. High-recall retrieval narrows the model-assisted ranking pool, with nominal limits of 6 or 10 candidates depending on available evidence, and exact matches, ties and a small recency reserve allowed to expand the pool up to all sent entries. Laya predicts content type and at most two relevant semantic facets. Newness only breaks tied scores; it cannot establish a recommendation or its margin.

The engine may return no recommendation for missing context, incompatible content or ambiguity. Model probabilities and evidence scores are not correctness probabilities. The independently authored 120-case synthetic evaluation found much lower false promotion and higher decision accuracy, but **answerable holdout Top-1 fell** as more cases were abstained on. The predeclared no-regression target was not met. This is a conservative policy tradeoff, not a claim of universally better semantic selection; see [the full evaluation](../evaluations/README.md).

A development-only experiment with small candidate choices was sensitive to reversing option order. It is recorded and not enabled in the production path. No special mapping from one example command to an answer was added. A model failure yields an honestly labeled local matching fallback.

Requests carry unique IDs and the app discards responses superseded by a newer context/history. Only bounded context and candidate excerpts go to the worker. Original clipboard payloads remain intact for pasting. Never execute clipboard text or treat it as an application command.

## macOS integration

- `NSStatusItem` plus an `NSPanel` created with `.nonactivatingPanel`; retain the destination PID before displaying it. Do not toggle its activation style dynamically.
- Poll `NSPasteboard.changeCount` on a tolerant timer. Deduplicate entries, suppress our own writes, cap payload size, and skip concealed/transient clipboard types and known password-manager sources.
- Preserve supported text, rich text, image and file URL representations, including multiple pasteboard items. Store at most 20 entries in Application Support with atomic replacement and restrictive permissions; allow pausing, deletion, clearing and disabling history persistence.
- Read a bounded snapshot of AX focused field metadata, selection and nearby text only when available. Do not read secure fields. AX permission is optional: history/search/manual copying still work; category alone does not force a recommendation.
- Chromium and Electron apps expose web content to assistive clients only after an opt-in; until then the focused element reads as nil or a window shell and every capture comes back empty. On categories that may host web content, capture best-effort sets `AXManualAccessibility`/`AXEnhancedUserInterface` (current Chrome acknowledges with an error yet still enables its web tree within about two seconds) and polls briefly before falling back. Web pages also nest visible labels one container deep (div → AXGroup → text), unlike flat native layouts, so the bounded sibling scan unwraps one container level without crossing into other fields.
- On macOS 15.4+, account for pasteboard access behavior and show restricted access clearly.
- For Paste, verify AX trust and destination liveness, dismiss the panel, yield activation, wait until the intended PID is active and only then synthesize Command-V. Otherwise leave the item copied with a clear explanation. Never send Enter.
- Register a Carbon hotkey rather than monitoring every global keystroke. Expose a conflict state and shortcut setting. Start-at-login is opt-in via `SMAppService`.

## Components

- `Models`: shared Codable value types and presentation metadata.
- `RecommendationContext`: local category mapping and the explicit inference DTO.
- `ClipboardStore`: bounded capture, deduplication, representations and persistence.
- `ContextReader`, `PasteController`, `GlobalHotKey`: operating-system integration.
- `EngineBridge`: a persistent `Process`/`Pipe` JSON-lines connection, timeout/restart and stale-response handling.
- `engine/worker.py`: real Laya loading, bounded question-specific context and a 24-entry inference cache; stdout is protocol only.
- `engine/ranking.py`: candidate feature extraction, preselection, scoring and abstention.
- `AppController`: main-actor orchestration, status item, destination ownership and settings.
- AppKit panel/views: list, preview, search, actions and accessibility labels.

Swift Package Manager builds the executable; a script packages a regular `.app` with `LSUIElement`. The local build is ad-hoc signed. Public distribution signing/notarization is a separate release step, not claimed by a successful local build.

## Validation and commits

No TDD and no permanent scaffold test target. After each coherent implementation slice, build and inspect it before an atomic commit. Validate actual model loading and synthetic ranking, 20-item bounds and persistence behavior, JSON protocol failure handling, and the rendered AppKit UI. Any temporary verification scripts are removed after stabilization. Document limitations of OS permission-dependent checks rather than claiming unobserved results.

The user-requested accuracy evaluation is retained as a reproducible offline dataset/runner, not a TDD scaffold. It freezes labels before tuning, projects context with actual production Swift code, compares the original worker and the final worker on identical cases, and includes no-model ablation. Evaluation never reads the real clipboard or app context.

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

For the recommendation revision, Context7 searches for Laya and Convai Laya returned unrelated libraries. The actual sibling README, `Agent.prepare`, choice probability outputs and per-question batch behavior were inspected directly before changing inference. No unrelated library documentation was substituted.
