# Recommendation engines

The default Laya path is local. An explicit Jev backend is also available in Settings; it sends bounded input context and preselected candidate excerpts to TypeSafe. The history UI retains all entries. See [Jev evaluation](../evaluations/JEV.md) for measured tradeoffs.

PasteWhat runs a persistent Python worker with a real Laya model. Its UI and macOS integration are AppKit. MLX multilingual is the default; the general Core ML multilingual model is available with CPU + GPU compute. The short-context ANE exports are not supported for this task.

## Install

On an Apple silicon Mac with [uv](https://docs.astral.sh/uv/getting-started/installation/) installed:

```sh
scripts/setup-engine.sh
```

This creates a Python 3.12 environment at `~/Library/Application Support/PasteWhat/runtime`, installs `laya-mlx==0.1.0`, downloads `aac6fef/laya-multilingual-mlx` into the `Models` subdirectory, and atomically writes `engine.json` with owner-only permissions. Downloading happens during setup. Laya forces offline model loading and has no inference telemetry. Jev is a separately selected remote API backend.

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

The Swift app keeps its native `AppContext` for display and safe paste dispatch. A separate `ModelContext` allows only application category, input surface, field role/label, selected text and surrounding text. The worker rejects identity metadata fields such as app names, bundle IDs, process IDs, raw window titles and clipboard source app names. App branding is removed from field metadata on word boundaries, not from user-authored task text: an app name that is part of the actual task is preserved. Unknown applications use `unknown` rather than a guessed type.

Local retrieval runs **before** model-assisted ranking. It considers whole-value content shape, text/image/file/rich-text capabilities, typed entities (so an issue number is not a network port), URL structure, CJK terms, negation and command/code structure. Hard format constraints apply only to recognized input metadata. Soft task mentions cannot indiscriminately discard other formats. Candidate limits adapt to evidence; near ties and weak context can retain all 20. AppKit always keeps the complete history for display, search and manual selection.

Laya predicts nine content types plus `unknown`: email, URL, code, command, text, phone, path, color and image. These are soft signals. When shortlisted entries differ in deployment environment or URL purpose and local context is not explicit, at most two additional structured questions may run. Each question is a real independent forward pass, so requests use at most three. All questions include an unspecified option. The model tokenizer budgets valid JSON context separately for each question and preserves cursor-near text. A bounded cache keeps only 24 hashed context/question keys and probability dictionaries.

Evidence decides whether to promote: missing context, no compatible content and unresolved ambiguity produce `recommendedID: null`. Newness breaks ties but cannot satisfy an evidence threshold or create a margin between candidates. Text-only entries with identical text can be interchangeable; equal image/file summaries do not establish payload equivalence. An inferred type alone cannot establish which of several similar items is correct.

The original payload remains in the app; the worker processes bounded excerpts and capabilities. A secure field skips all model work. Empty history and unusable context also avoid unnecessary loading. Missing Laya models or local inference failures preserve local matching with an explicit fallback status. No clipboard content is executed. Laya stays offline; Jev sends excerpts only when selected and returns no recommendation on API failure.

## Jev

`--backend jev` uses the documented `https://api.typesafe.ai/v1/systemone` endpoint and `jev-latest`. It uses the same local preselection, then one Choice question over candidate descriptions plus `abstain`. Option indices are mapped back to original IDs locally. A `0.5` confidence gate is an uncalibrated ambiguity threshold, not a probability-of-correctness guarantee.

The Python stdlib client bounds response size, rejects redirects, applies a 12-second socket timeout, validates choice membership and finite probability distributions, and never logs response bodies. It caches at most 24 responses by a digest of the complete model request. Cancellation terminates the worker; no stale response can update a later presentation. API errors retain chronological history and show a specific status. Interactive requests do not automatically retry or multiply quota use.

Credentials come from `TYPESAFE_API_KEY` or `~/Library/Application Support/PasteWhat/credentials/jev.key`. The app saves this file by atomic replacement with `0600` permissions in a `0700` directory; the worker rejects symlinks, foreign ownership and permissive file modes. This is a private local file, not encrypted storage. App settings never redisplay the secret and allow removal. No key belongs in `engine.json` or a command-line argument.

Documentation was checked with Context7 (`/browser-use/jev-ultrafast`) and the primary [TypeSafe API reference](https://docs.typesafe.ai/api), [Choice guide](https://docs.typesafe.ai/primitives/choice), and [confidence definition](https://docs.typesafe.ai/confidence). The real integration returned `jev-1.13.0`. Model aliases can change; evaluation records observed versions.

This is a conservative recommendation policy, not a semantic correctness guarantee. The 120-case frozen evaluation improved total decision accuracy and precision, but reduced answerable holdout Top-1 through additional abstention. Laya's measured net gain over rules was small. Read [the full results and limitations](../evaluations/README.md) before interpreting an accuracy number. A small-candidate choice experiment was order-sensitive and remains disabled.

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
    "applicationCategory": "mail",
    "inputSurface": "recipient",
    "fieldRole": "AXTextField",
    "fieldLabel": "Recipient",
    "selectedText": "",
    "surroundingText": "",
    "hasAccessibility": true,
    "isSecure": false
  },
  "entries": [
    {"id": "clip-1", "text": "hello@example.com", "kind": "email", "capabilities": ["text"], "sourceCategory": "unknown"}
  ]
}
```

Responses contain `id`, nullable `recommendedID`, `rankings` (`id`, finite `score`, Chinese `reason`), `mode` (`laya` or `fallback`), `backend`, `elapsedMS`, nullable `message`, `decision`, `shortlistedIDs`, `inferenceCount` and `appliedFacets`. `mode` identifies the runtime path, not a successful recommendation. `decision` is one of `recommended`, `insufficient_context`, `ambiguous`, `no_compatible_candidate`, `secure_field`, `empty_history` or `invalid_request`. Only `recommended` has a non-null ID. Rankings may cover the shortlist rather than all history; the frontend uses only the recommendation ID to reorder its own complete list. Entries arrive newest first. A response preserves their IDs, and ranking ties preserve their input order. The AppKit app promotes only the recommended entry, leaving the rest in chronological order.

The worker rejects more than 20 entries, duplicate entry IDs or JSON keys, invalid scalar types, invalid Unicode, nonfinite JSON numbers and lines over 1 MiB. Oversized lines are drained before processing the next request. Individual raw strings may contain at most 32,768 characters; candidate scoring uses at most 8,192 characters, while the app currently sends at most 2,400. Nearby context preserves the cursor end before token budgeting. Invalid requests return empty rankings and a generic message; a recoverable valid request ID is echoed.

## Validation performed

The original release exercised both runtimes on four exploratory cases and protocol/storage checks. The recommendation revision uses an independently authored and frozen 120-case dataset (40 development / 80 heldout), actual production Swift context projection, real MLX, a no-model ablation and a preselected 32-case Core ML parity subset. All raw responses, hashes, commands, split/group results and the failed holdout Top-1 guardrail are retained under `evaluations/`. Temporary experimental scripts are removed; no unit-test target is added.

To evaluate local matching without loading a model, the worker accepts `--no-model`; the evaluation runner passes this flag for ablation. This is not an alternative production default. The runtime path and inference counts in results make a failed model load visible rather than silently presenting rules as model accuracy.

The installer was also exercised with fresh temporary `uv` environments for both published `0.1.0` packages and existing local weights, followed by real inference through each installed runtime. Sibling reuse, exact configuration fields, `0600` configuration permissions and preservation of an existing configuration when setup fails were checked. Temporary verification environments were removed. The 512- and 1024-token budgeting paths retained valid JSON and the nearby-text cursor end.

The setup script uses the documented [uv virtual environment and package installation](https://docs.astral.sh/uv/pip/environments/) commands and [Hugging Face snapshot downloads](https://huggingface.co/docs/huggingface_hub/guides/download). Those APIs were checked with Context7 before implementation.
