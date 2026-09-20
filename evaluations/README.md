# Recommendation evaluation

This directory contains a reproducible **synthetic quality evaluation**, not a
Swift test target or a TDD scaffold. It never reads the real clipboard, saved
history, accessibility state, or a user's files. The dataset, expected outcomes,
and split were frozen before evaluating the replacement ranking implementation.

**The primary held-out Top-1 guardrail was not met.** The frozen implementation
substantially reduced incorrect promotions, but correctly promoted fewer
answerable held-out tasks than the baseline. The results below describe a
precision/coverage tradeoff, not an across-the-board accuracy improvement.

## Frozen data

`cases.jsonl` contains 120 agent-authored synthetic tasks, with labels written by
the evaluation subagent independently of implementation. They are not human-user
observations or human-validated ground truth. The exact bytes are protected by
`cases.sha256` and `manifest.json`:

```text
0537bde8a33eac2d0aab5dcfb649ecf89acb6b05908ba18a3c628f46476354ea
```

The implementation agent received `dev.jsonl` (40 cases), while the evaluation
agent retained the other 80 cases until production rules were frozen. Labels
must not be changed to fit an observed result. Any future correction or expanded
dataset needs a new version, an explicit explanation, and a fresh hash; it must
not silently replace the evidence here.

| Group | Total | Development | Held out |
|---|---:|---:|---:|
| Explicit fields | 18 | 6 | 12 |
| Entity and URL resolution | 18 | 6 | 12 |
| Content intent | 18 | 6 | 12 |
| App category versus field intent | 12 | 4 | 8 |
| Code and commands | 18 | 6 | 12 |
| Clipboard representation capabilities | 12 | 4 | 8 |
| No answer, ambiguity, or secure input | 18 | 6 | 12 |
| Full 20-entry history | 6 | 2 | 4 |
| **Total** | **120** | **40** | **80** |

There are 97 answerable tasks and 23 tasks that should not promote an item.
Several tasks accept multiple equivalent answers. The history-boundary group
includes five tasks whose correct entry is twentieth and one with twenty
indistinguishable choices. Other candidate orders were shuffled with a fixed
per-case seed before freezing. The tasks vary in intent and structure, rather
than merely substituting different names into one template.

Each line has:

- `id`, `split`, `group`, and descriptive `tags`.
- `nativeContext`: the original protocol's destination metadata and focused-field
  text. Window titles are empty to avoid a hidden source of task evidence.
- `modelContext`: an annotated category/surface interpretation, retained for
  auditing dataset intent. **The current-protocol runner does not use these
  annotations as model input.** Some semantic surfaces cannot be recovered from
  the supplied native AX metadata, so using them would grant extra information.
- `entries`: newest first, with ID, bounded text, display kind, actual representation
  capabilities, and legacy/new source metadata. They contain no binary payloads.
- `expected`: `recommend` or `abstain`, a list of acceptable `correctIDs`, and a
  rationale determined from the supplied task. These labels never reach the worker.

For every current-protocol run, the runner temporarily compiles
`ProjectContext.swift` with the actual production `Models.swift` and
`RecommendationContext.swift`. It projects each frozen `nativeContext` through
`AppContext.modelContext`, exactly as the app does. An unrecognized bundle remains
`unknown`; an annotated shell surface remains ordinary text when the native
metadata cannot establish more. The temporary compiled tool and copied sources
are deleted automatically. Its production source hashes and actual projected
contexts are recorded with the results. This keeps the original frozen data and
labels intact while avoiding an artificial context advantage over the baseline.

Image pixels and file contents are intentionally unavailable. If two anonymous
images or files cannot be distinguished by the supplied evidence, the expected
answer is abstention. A paragraph that merely contains an email address is not
equivalent to a standalone email value. The evaluation assumes whole-entry paste;
it does not grant credit for an unstated content-extraction feature.

The 32-case Core ML subset was selected by group and frozen in `manifest.json`
before any new-worker result: four held-out cases from each of the eight groups.

## Run

The worker uses the documented local Laya runtimes. The sibling projects'
READMEs and implementation were checked before running the evaluation. Use the
general multilingual models, not the 96-token ANE export.

From the repository root, preserve the historical worker in a temporary file:

```sh
git show 0732b42:engine/worker.py > /tmp/pastewhat-baseline-worker.py
python3 evaluations/run.py \
  --python ../laya-mlx/.venv/bin/python \
  --worker /tmp/pastewhat-baseline-worker.py \
  --model ../laya-mlx/models/hub/laya-multilingual-mlx \
  --backend mlx --protocol legacy --label reproduced-baseline-mlx
```

Evaluate a frozen current implementation:

```sh
python3 evaluations/run.py \
  --python ../laya-mlx/.venv/bin/python \
  --worker engine/worker.py \
  --model ../laya-mlx/models/hub/laya-multilingual-mlx \
  --backend mlx --protocol current --split all \
  --production-commit 474ee4fede577c5d5464eec78ef61d2c81851f87 \
  --label reproduced-final-mlx
```

Use `--split dev` while developing. Run `--split heldout` or the full final run
only after freezing the production rules. To measure the model's contribution,
repeat the exact frozen implementation and dataset with `--no-model` and a
distinct label. This passes the worker's supported `--no-model` flag; it does not
monkey-patch ranking functions or simulate model failure.

For the preselected Core ML subset:

```sh
python3 evaluations/run.py \
  --python ../laya-coreml/.venv/bin/python \
  --worker engine/worker.py \
  --model ../laya-coreml/models/hub/laya-multilingual-coreml \
  --backend coreml --protocol current --subset coreml \
  --production-commit 474ee4fede577c5d5464eec78ef61d2c81851f87 \
  --label reproduced-final-coreml-subset
```

The runner validates the frozen dataset hash, uses one persistent worker,
performs an unscored synthetic warmup, and enforces a per-response timeout. It
records all worker-module hashes, projection source hashes, model configuration
hash, protocol, platform, warmup,
per-case responses, and aggregate results. Existing output labels cannot be
overwritten. An invalid request or unexpected model failure stops the evaluation
and leaves a failure artifact; it cannot earn credit as a correct abstention.
A model run must observe actual `mode=laya` output. No model download or network
inference is performed. Temporary
historical worker copies can be removed after the run.

`--production-commit` records a label; it does not check out that revision. To
reproduce a historical implementation, use a checkout of that commit and the
current evaluation runner, or verify the recorded module and projection hashes.
New runs against changed code must use a new label and its actual revision.

## Metrics

- **Answerable Top-1:** correct promotions divided by tasks with one or more
  acceptable answers. Abstaining on an answerable task counts as a miss.
- **Decision accuracy:** correct promotions plus correct abstentions, divided by
  all tasks.
- **Recommendation precision:** correct promotions divided by all promotions.
- **Recommendation coverage:** promotions divided by all tasks. Always report it
  with precision, so abstaining on every task cannot masquerade as high quality.
- **No-answer false-promotion rate:** tasks that should abstain but promote an
  item, divided by all tasks that should abstain.
- **Shortlist recall:** answerable tasks where at least one acceptable ID remains
  in `shortlistedIDs`, divided by answerable tasks. Equivalent answers need not
  all survive. The legacy worker has no shortlist, so its value is null.
- **Warm latency:** worker-reported and process round-trip p50/p95, excluding
  startup/model warmup. A first scored model load is separately marked and
  excluded if the unscored warmup did not load the model. Percentiles use linear
  interpolation. These measurements are not AppKit/AX capture latency.
- **Inference count:** the new worker's actual forward-pass count, including zero
  for cache hits or deterministic decisions; legacy results leave it unavailable.

Results are grouped by development/held-out split and by task group. `mode=laya`
is checked in the recorded responses so a fallback-only run cannot be presented
as real model inference.

## Frozen production result

The production rules and native context projection were frozen at commit
`474ee4fede577c5d5464eec78ef61d2c81851f87` before opening the held-out results.
The preceding commit `60862ac` contains the context DTO/classification boundary.
No ranking rule, threshold, or dataset label was changed in response to held-out
failures. Short-candidate direct choice was not enabled.

The primary comparison is the 80-case held-out split:

| Metric | Baseline MLX | Frozen MLX | Same code, no model |
|---|---:|---:|---:|
| Answerable Top-1 | **51/63 (80.95%)** | **45/63 (71.43%)** | 45/63 (71.43%) |
| Decision accuracy | 51/80 (63.75%) | 60/80 (75.00%) | 60/80 (75.00%) |
| Recommendation precision | 51/80 (63.75%) | 45/48 (93.75%) | 45/48 (93.75%) |
| Recommendation coverage | 80/80 (100.00%) | 48/80 (60.00%) | 48/80 (60.00%) |
| No-answer false-promotion rate | 17/17 (100.00%) | 2/17 (11.76%) | 2/17 (11.76%) |
| Shortlist recall | — | 63/63 (100.00%) | 63/63 (100.00%) |
| Warm worker p50 / p95 | 9.12 / 12.23 ms | 10.88 / 13.39 ms | 0.17 / 0.29 ms |

Across **all 120 tasks**, the frozen MLX run correctly promoted 77/97 answerable
tasks (79.38%) and made 98/120 correct decisions (81.67%). It promoted 80 times,
with 77 correct and three incorrect promotions: precision 96.25%, coverage
66.67%. It correctly abstained on 21/23 no-answer tasks. The corresponding
baseline figures were 76/97 answerable tasks, 77/120 correct decisions, 119
promotions, and one correct abstention. Development improvement therefore does
not cancel the held-out Top-1 regression.

The original acceptance goal that held-out answerable Top-1 should not decrease
failed by six correct promotions (9.52 percentage points). Decision accuracy,
false-promotion reduction, shortlist recall, and the maximum-three-forwards
budget met their stated goals on this dataset.

### Where the tradeoff occurs

No answerable case lost every acceptable answer during prefiltering: **0/97
misses overall and 0/63 on held-out data**. Ignoring the decision gate, the first
raw ranking item is acceptable in 87/97 cases overall and 55/63 held-out cases.
However, nine of those 55 held-out raw successes have an exactly tied top score.
The raw first position in a tie is not evidence that the system distinguished
the correct candidate, and it is not the user-visible success rate.

Ten held-out cases put an acceptable answer first in the raw ranking and then
abstained: four `ambiguous`, four `insufficient_context`, and two
`no_compatible_candidate`. Compared with baseline, eleven previously correct
held-out recommendations became abstentions/incorrect decisions, while five
previously incorrect recommendations became correct recommendations. Including
no-answer cases, twenty baseline decisions became correct and eleven regressed,
giving the net nine additional correct decisions.

| Held-out group | Cases | Correct answer / answerable, before → after | Correct decisions, before → after | Answerable abstentions after |
|---|---:|---:|---:|---:|
| Explicit fields | 12 | 10/11 → 11/11 | 10 → 12 | 0 |
| Entity and URL resolution | 12 | 9/12 → 6/12 | 9 → 6 | 6 |
| Content intent | 12 | 11/12 → 8/12 | 11 → 8 | 3 |
| App category versus field intent | 8 | 6/8 → 8/8 | 6 → 8 | 0 |
| Code and commands | 12 | 8/12 → 4/12 | 8 → 4 | 8 |
| Representation capabilities | 8 | 4/5 → 5/5 | 4 → 7 | 0 |
| No answer / ambiguity | 12 | — | 0 → 11 | — |
| Full 20-entry history | 4 | 3/3 → 3/3 | 3 → 4 | 0 |

The three remaining incorrect promotions concern a French translation request
where an English sentence was chosen, a local-file attachment request where a
filename-only text was chosen, and an English-language message request where
only other languages were available. Abstained answerable cases expose gaps in
fine-grained URL distinctions, language/meaning, and command semantics. These
failures remain in the published results; the frozen version was not patched
against them.

### Model contribution, retrieval size, and Core ML

The no-model ablation uses the same frozen production code and context projection.
Adding Laya changed only one final decision across the full dataset: a correct
promotion for development case `PW005` (a Chinese folder-path field) instead of
abstaining. It changed **zero held-out decisions**. The measured gains in this
iteration are primarily from the engineering changes and abstention policy;
this evaluation does not demonstrate additional held-out semantic benefit from
Laya's current type/facet prompts.

The full histories contained 455 candidates in total; the internal shortlists
contained 341, a **25.05% reduction**. The six 20-entry histories shrank from 120
candidates to 50, a **58.33% reduction**; the genuinely ambiguous 20-entry history
kept all 20. The front end still receives the complete history. The scored MLX
requests made 116 actual model forward passes in total, with a maximum of two
per request. Zero-forwards requests include cached contexts and requests that
skip inference. Its overall warm worker p50/p95 was 10.93/13.60 ms.

The pre-frozen **32-case Core ML subset** correctly promoted 20/27 answerable
tasks and made 25/32 correct decisions: Top-1 74.07%, decision accuracy 78.13%,
precision 100%, coverage 62.5%, and no incorrect promotion on its five no-answer
tasks. It retained every acceptable answer in its shortlist. Recommended IDs
and decision categories matched the corresponding MLX results in **32/32
cases**. It made 31 scored forward passes, at most one per request, with warm
worker p50/p95 of 14.04/15.85 ms. This is a backend-consistency sample, not a full
Core ML accuracy benchmark or evidence that its smaller sample is easier to ship.

Exact outputs and source hashes are in `final-474ee4f-*.summary.json`, their
matching `.responses.jsonl` files, and `final-analysis.json`.

The subsequent packaging fix `bce862aad20c1fe9962e5f37fc153c7f9d19ec13`
disables Python bytecode writes before local imports, sets the same flag in the
native worker environment and removes stale generated resources during builds.
It changes no ranking rule or context projection. A complete 120-case MLX run
using the worker **inside the signed `.app`** reproduced recommendation IDs,
decision categories and shortlist IDs in **120/120 cases**. Module/projection
hashes and the comparison are retained in `packaged-bce862a-*`. The app signature
remained valid after inference, with no generated bytecode inside the bundle.

## Baseline

The baseline is exactly `engine/worker.py` from commit `0732b42`, run with the
real local MLX multilingual model. Its 120 scored requests contained 119 Laya
responses and one secure-field skip.

| Metric | All 120 | Development 40 | Held out 80 |
|---|---:|---:|---:|
| Answerable Top-1 | 76/97 (78.35%) | 25/34 (73.53%) | 51/63 (80.95%) |
| Decision accuracy | 77/120 (64.17%) | 26/40 (65.00%) | 51/80 (63.75%) |
| Recommendation precision | 63.87% | 64.10% | 63.75% |
| Recommendation coverage | 99.17% | 97.50% | 100.00% |
| No-answer false-promotion rate | 22/23 (95.65%) | 5/6 (83.33%) | 17/17 (100.00%) |
| Warm worker p50 / p95 | 9.04 / 12.24 ms | 8.83 / 12.24 ms | 9.12 / 12.23 ms |

The first replacement-implementation development run used the production Swift
projection. It correctly promoted 28/34 answerable tasks and abstained on all
6 no-answer tasks, for 85% decision accuracy at 70% coverage. Rules alone
correctly promoted 27/34, for 82.5% decision accuracy at 67.5% coverage. Both had
100% shortlist recall on this development split. The six model-run misses were
all abstentions, with no incorrect promotions. These are development observations,
not held-out claims; their exact implementation hashes are preserved in
`dev-v1-projected-*.summary.json`.

One development-only revision added general word-form matching, code-language and
SQL-direction features, and explicit quote/prefix matching. Its model run correctly
promoted 32/34 answerable tasks, abstained on all six no-answer tasks, and made no
incorrect promotions: 95% decision accuracy at 80% coverage. Rules alone reached
31/34 answerable tasks and 92.5% decision accuracy at 77.5% coverage. Both retained
100% shortlist recall. The remaining model-run misses were a cross-language
postal address and interpreting `pwd` from an English task. Their source hashes
are recorded in `dev-v2-projected-*.summary.json`; no task-specific rule was added
for either miss.

An additional development-only probe is preserved as `dev-choice-probe.json`.
It asked Laya to choose short candidate contents plus a `none` option for the
first revision's contextual abstentions, once in each candidate order. One
empty shortlist was skipped. Of the eight evaluated cases, three answerable
cases were correct in both orders, three answerable cases changed selection and
were wrong in one order, and two no-answer cases selected `none` in both orders.
There were 13 correct decisions among the complete run's 16 forward passes.
The initial invocation stopped at the empty shortlist; the complete run retained
the same prompt and labels. Selection probabilities did not resolve the ordering
problem: one unstable answer scored 0.80 in one order, while stable correct
answers were often below 0.55. This small probe does not establish the reliability
of a candidate-choice stage, and it was not used as a substitute for the held-out
evaluation.

The original four feasibility examples are not an accuracy benchmark. This
larger evaluation is still synthetic and small: it does not establish real-user
accuracy, capture reliability across applications, permission behavior, or
semantic understanding of arbitrary commands. Many tasks have short, clean
inputs. Future real-world assessment requires explicitly collected, consented,
independently labeled task data; it must not silently read clipboard history.
