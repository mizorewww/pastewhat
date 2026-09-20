# Local recommendation engine

PasteWhat runs a persistent Python worker with a real Laya model. Its UI and macOS integration are AppKit. MLX multilingual is the default; the general Core ML multilingual model is available with CPU + GPU compute. The short-context ANE exports are not supported for this task.

## Install

On an Apple silicon Mac with [uv](https://docs.astral.sh/uv/getting-started/installation/) installed:

```sh
scripts/setup-engine.sh
```

This creates a Python 3.12 environment at `~/Library/Application Support/PasteWhat/runtime`, installs `laya-mlx==0.1.0`, downloads `aac6fef/laya-multilingual-mlx` into the `Models` subdirectory, and atomically writes `engine.json` with owner-only permissions. Downloading happens during setup. The worker forces offline model loading and has no network inference API or telemetry.

To use Core ML instead:

```sh
scripts/setup-engine.sh --backend coreml
```

This installs `laya-coreml==0.1.0` and downloads `aac6fef/laya-multilingual-coreml`. Core ML requires macOS 15 or later; MLX requires macOS 14 or later. Restart PasteWhat after changing the runtime configuration.

An existing model avoids a weights download:

```sh
scripts/setup-engine.sh --model /absolute/path/to/laya-multilingual-mlx
```

For local development, an existing sibling checkout and virtual environment can be reused without installing into or changing that repository:

```sh
scripts/setup-engine.sh --use-sibling
scripts/setup-engine.sh --backend coreml --use-sibling
```

The sibling shortcut expects `../laya-mlx/.venv/bin/python` or `../laya-coreml/.venv/bin/python`, plus `models/hub/laya-multilingual-mlx` or `models/hub/laya-multilingual-coreml`. Both shortcuts also accept `--model`. `--support-dir` writes setup artifacts somewhere else for development; the app reads its normal Application Support directory.

`engine.json` contains only three strings:

```json
{
  "backend": "mlx",
  "pythonPath": "/absolute/path/to/runtime/bin/python",
  "modelPath": "/absolute/path/to/laya-multilingual-mlx"
}
```

Model weights and Python environments are not committed to the repository. The Laya packages carry their upstream Apache-2.0 attribution and notices.

## Recommendation behavior

Laya predicts a distribution over eight content types: email, URL, code, command, text, phone, path and color. This distribution is a soft ranking signal. Explicit field intent, matching words or CJK bigrams, matching numbers, source app and a small recency preference determine the final order. Strong field evidence can override a contradictory model type guess.

The model sees a bounded snapshot of the destination application and input context. It does not receive all 20 clipboard entries as one choice question. The model's own tokenizer enforces its context budget, with focused-field and cursor context taking priority over the window title. The worker caches only the last context fingerprint and its type probabilities. When only history changes, it can rank again without a new model forward pass.

The full clipboard payload remains in the app; the worker processes excerpts. No clipboard content is executed. A secure-field context skips all model inference and content matching and returns no recommendation. Empty history also skips model loading. A missing model or inference failure returns an explicitly labeled `fallback` response with local matching, so the history remains usable.

Ranking is heuristic and is not a semantic correctness guarantee. For example, word overlap cannot reliably distinguish `git branch` from `git branch -a` when the context asks for local branches. The app never executes a command or sends Return when pasting. Scores are sorting values, not recommendation probabilities.

## Worker protocol

```sh
/path/to/python -u engine/worker.py --backend mlx --model /path/to/local/model
```

The worker lazy-loads the model on its first nonempty, nonsecure request. Each input line produces one JSON response line. It sends no startup or ready message. Its stdout contains protocol JSON only; third-party runtime output is discarded. Diagnostics contain generic failure categories and never include context or clipboard text.

Requests match `RecommendationRequest` in `Sources/PasteWhat/Models.swift`:

```json
{
  "id": "request-1",
  "context": {
    "appName": "Mail",
    "bundleID": "com.apple.mail",
    "processID": 123,
    "windowTitle": "New Message",
    "fieldRole": "AXTextField",
    "fieldLabel": "Recipient",
    "selectedText": "",
    "surroundingText": "",
    "hasAccessibility": true,
    "isSecure": false
  },
  "entries": [
    {"id": "clip-1", "text": "hello@example.com", "kind": "email", "sourceApp": "Contacts"}
  ]
}
```

Responses contain `id`, nullable `recommendedID`, `rankings` (`id`, finite `score`, Chinese `reason`), `mode` (`laya` or `fallback`), `backend`, `elapsedMS` and nullable `message`. Entries arrive newest first. A response preserves their IDs, and ranking ties preserve their input order. The AppKit app promotes only the recommended entry, leaving the rest in chronological order.

The worker rejects more than 20 entries, duplicate entry IDs or JSON keys, invalid scalar types, invalid Unicode, nonfinite JSON numbers and lines over 1 MiB. Oversized lines are drained before processing the next request. Individual raw strings may contain at most 32,768 characters; candidate scoring uses at most 8,192 characters, while the app currently sends at most 2,400. Nearby context preserves the cursor end before token budgeting. Invalid requests return empty rankings and a generic message; a recoverable valid request ID is echoed.

## Validation performed

After implementation, both local MLX and Core ML multilingual weights were exercised through subprocess JSONL, including Chinese recipient matching, a Git-command ambiguity, an exact issue URL and a staging endpoint. Three of the four detailed choices were correct on each backend; the ambiguous Git flags remained a documented limitation. Empty history, a secure field, long context, repeated-context caching, duplicate IDs, too many entries, malformed JSON, nonfinite numbers, invalid Unicode, oversized-line recovery and missing-model fallback were checked. These are synthetic feasibility checks, not a user-task accuracy benchmark. No scaffold test suite is retained.

The installer was also exercised with fresh temporary `uv` environments for both published `0.1.0` packages and existing local weights, followed by real inference through each installed runtime. Sibling reuse, exact configuration fields, `0600` configuration permissions and preservation of an existing configuration when setup fails were checked. Temporary verification environments were removed. The 512- and 1024-token budgeting paths retained valid JSON and the nearby-text cursor end.

The setup script uses the documented [uv virtual environment and package installation](https://docs.astral.sh/uv/pip/environments/) commands and [Hugging Face snapshot downloads](https://huggingface.co/docs/huggingface_hub/guides/download). Those APIs were checked with Context7 before implementation.
