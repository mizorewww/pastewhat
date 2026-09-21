# Jev integration regression

This is a regression on the existing, already exposed 120-case synthetic dataset. It is **not** the new student's final Test set, a human-validated benchmark, or evidence of real-user accuracy. Labels and the original production context projection were preserved. No Jev prompt or threshold tuning was performed after this run.

Production source: `e1663b7`. Requested API model: `jev-latest`; observed model: **`jev-1.13.0`**. One structured Choice selects a prefiltered candidate or abstains. The distribution-derived confidence gate is fixed at `0.5`; it is not calibrated for this product. All native history remains available.

| Metric, all 120 cases | Existing local Laya workflow | Jev |
|---|---:|---:|
| Actual recommended Top-1 on answerable cases | 77/97 (79.38%) | 74/97 (76.29%) |
| Decision accuracy including appropriate abstention | 98/120 (81.67%) | 96/120 (80.00%) |
| Precision among recommendations | 77/80 (96.25%) | 74/75 (98.67%) |
| Recommendation coverage | 80/120 (66.67%) | 75/120 (62.50%) |
| False recommendation on should-abstain cases | 2/23 (8.70%) | 1/23 (4.35%) |
| Shortlist retains an acceptable candidate | 97/97 | 97/97 |
| Warm worker latency p50 / p95 | 10.93 / 13.60 ms | 825.05 / 967.10 ms |

Jev's first integration is more conservative overall: higher recommendation precision, lower coverage, and lower actual answerable Top-1 over all 120 cases. **98.67% is precision among 75 recommendations, not overall accuracy.** Latency includes Jev network transit; neither worker measure includes the native accessibility capture or UI.

On the original 80-case heldout partition, the current local workflow's Top-1 was 45/63 (71.43%); Jev obtained 50/63 (79.37%). Decision accuracy was 66/80 (82.50%), precision 50/51 (98.04%), and coverage 51/80 (63.75%). This partition was exposed in prior work; its historical name must not be interpreted as a fresh heldout evaluation for the new student model.

114 scored API calls completed without service failures. Secure input, empty/insufficient context and incompatible candidates bypass remote inference as applicable. A separate synthetic integration check verified that a repeated request reused the cache, secure/empty requests did not call the API, and malformed response IDs/probabilities were rejected. No temporary scaffold files remain.

Raw evidence: [summary](results/jev-initial.summary.json), [per-case responses](results/jev-initial.responses.jsonl). Source hashes, actual model version, projected contexts and latencies are recorded. The dataset consists entirely of synthetic clipboard content.

Reproduce with a configured local credential or `TYPESAFE_API_KEY` (the key is never a CLI argument):

```bash
PYTHONDONTWRITEBYTECODE=1 python3 evaluations/run.py \
  --python /usr/bin/python3 --worker engine/worker.py \
  --backend jev --protocol current --split all \
  --label jev-reproduction --production-commit e1663b7
```

This command intentionally sends the synthetic fixtures to TypeSafe and consumes API quota. The new ranker's independent benchmark lives in [the model repository](https://github.com/mizorewww/pastewhat-ranker-v1).
