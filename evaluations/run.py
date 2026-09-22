#!/usr/bin/env python3
"""Run a frozen synthetic recommendation evaluation through the worker protocol.

This is a synthetic quality/latency evaluation, not a unit-test target. Jev sends
the synthetic fixtures to TypeSafe; local backends stay offline. It never
reads NSPasteboard, Application Support history, or a real application's context.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import platform
import queue
import statistics
import subprocess
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def load_cases(path: Path, manifest: dict):
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != manifest["sha256"]:
        raise ValueError("Dataset hash differs from the frozen manifest; do not silently relabel it.")
    cases = [json.loads(line) for line in data.splitlines() if line.strip()]
    if len(cases) != manifest["cases"]:
        raise ValueError("Frozen case count differs from manifest.")
    return cases


def request_for(case, protocol, suffix=""):
    if protocol == "legacy":
        context = case["nativeContext"]
        entries = [{key: item[key] for key in ("id", "text", "kind", "sourceApp")}
                   for item in case["entries"]]
    else:
        context = case["projectedContext"]
        entries = [{key: item[key] for key in ("id", "text", "kind", "capabilities", "sourceCategory")}
                   for item in case["entries"]]
    return {"id": case["id"] + suffix, "context": context, "entries": entries}


def warmup_case():
    shared = {"fieldRole": "AXTextField", "fieldLabel": "Message", "selectedText": "",
              "surroundingText": "Share a short acknowledgement that the request was received.",
              "hasAccessibility": True, "isSecure": False}
    native = {"appName": "Messages", "bundleID": "com.apple.MobileSMS", "processID": 12345,
              "windowTitle": "", **shared}
    model = {"applicationCategory": "messaging", "inputSurface": "chat_composer", **shared}
    entries = [
        {"id": "warmup-text", "text": "Thanks, I received your request.", "kind": "text",
         "capabilities": ["text"], "sourceCategory": "unknown", "sourceApp": "Sample Utility"},
        {"id": "warmup-email", "text": "support@example.test", "kind": "email",
         "capabilities": ["text"], "sourceCategory": "unknown", "sourceApp": "Sample Utility"},
    ]
    return {"id": "unscored-warmup", "nativeContext": native, "modelContext": model, "entries": entries}


def project_contexts(cases):
    """Use the production Swift projection, never the dataset's annotated surface."""
    sources = [ROOT.parent / "Sources/PasteWhat/Models.swift",
               ROOT.parent / "Sources/PasteWhat/RecommendationContext.swift",
               ROOT.parent / "Sources/PasteWhat/CandidateProjection.swift",
               ROOT / "ProjectContext.swift"]
    hashes = {}
    with tempfile.TemporaryDirectory(prefix="pastewhat-context-eval-") as directory:
        temporary = Path(directory)
        copies = []
        for source in sources:
            data = source.read_bytes()
            hashes[str(source.relative_to(ROOT.parent))] = hashlib.sha256(data).hexdigest()
            copy = temporary / source.name
            copy.write_bytes(data)
            copies.append(str(copy))
        executable = temporary / "project-context"
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *copies,
                        "-o", str(executable)], check=True, capture_output=True, text=True)
        values = [{"id": case["id"], "nativeContext": case["nativeContext"]} for case in cases]
        result = subprocess.run([str(executable)], input=json.dumps(values, ensure_ascii=False),
                                check=True, capture_output=True, text=True)
        projected = {item["id"]: item["context"] for item in json.loads(result.stdout)}
    if set(projected) != {case["id"] for case in cases}:
        raise ValueError("Production context projection did not preserve all case IDs.")
    for case in cases:
        case["projectedContext"] = projected[case["id"]]
    return {"method": "production-swift", "sourceSHA256": hashes,
            "categoryCounts": dict(collections.Counter(value["applicationCategory"] for value in projected.values())),
            "surfaceCounts": dict(collections.Counter(value["inputSurface"] for value in projected.values()))}


class Worker:
    def __init__(self, command, timeout):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", HF_HUB_OFFLINE="1",
                   TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
        self.stderr = tempfile.TemporaryFile(prefix="pastewhat-worker-stderr-")  # noqa: SIM115 - closed in close().
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, text=True, bufsize=1, env=env)
        self.timeout = timeout
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            for line in self.process.stdout:
                self.lines.put(line)
        finally:
            self.lines.put(None)

    def request(self, value):
        started = time.perf_counter()
        self.process.stdin.write(json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n")
        self.process.stdin.flush()
        try:
            line = self.lines.get(timeout=self.timeout)
        except queue.Empty as error:
            raise TimeoutError("Worker response exceeded the configured evaluation timeout.") from error
        if line is None:
            raise RuntimeError(f"Worker exited before a response (exit {self.process.poll()}).")
        result = json.loads(line)
        if result.get("id") != value["id"]:
            raise ValueError("Worker returned a mismatched request ID.")
        candidate_ids = {item["id"] for item in value["entries"]}
        if result.get("recommendedID") is not None and result["recommendedID"] not in candidate_ids:
            raise ValueError("Worker recommended an ID outside the original full history.")
        return result, (time.perf_counter() - started) * 1000

    def stderr_tail(self, limit=4096):
        size = self.stderr.seek(0, os.SEEK_END)
        self.stderr.seek(max(0, size - limit))
        return self.stderr.read().decode("utf-8", errors="replace")

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        self.stderr.close()


def percentile(values, percentage):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentage / 100
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower), 3)


def ratio(numerator, denominator):
    return round(numerator / denominator, 6) if denominator else None


def metrics(records):
    answerable = [x for x in records if x["correctIDs"]]
    unanswerable = [x for x in records if not x["correctIDs"]]
    promoted = [x for x in records if x["recommendedID"] is not None]
    correct_promotions = [x for x in promoted if x["recommendedID"] in x["correctIDs"]]
    correct_decisions = [x for x in records if x["decisionCorrect"]]
    recalls = [x for x in answerable if x["shortlistRecall"] is not None]
    warm = [x for x in records if not x.get("coldModelLoad", False)]
    result = {
        "cases": len(records), "answerable": len(answerable), "shouldAbstain": len(unanswerable),
        "answerableTop1": ratio(len(correct_promotions), len(answerable)),
        "decisionAccuracy": ratio(len(correct_decisions), len(records)),
        "recommendationPrecision": ratio(len(correct_promotions), len(promoted)),
        "recommendationCoverage": ratio(len(promoted), len(records)),
        "noAnswerFalsePromotionRate": ratio(sum(x["recommendedID"] is not None for x in unanswerable), len(unanswerable)),
        "correctPromotions": len(correct_promotions), "promotions": len(promoted),
        "correctAbstentions": sum(x["recommendedID"] is None for x in unanswerable),
        "missedAnswerable": sum(x["recommendedID"] is None for x in answerable),
        "wrongPromotionsOnAnswerable": sum(x["recommendedID"] is not None and x["recommendedID"] not in x["correctIDs"] for x in answerable),
        "shortlistRecall": ratio(sum(x["shortlistRecall"] for x in recalls), len(recalls)),
        "warmLatencyMS": {"p50": percentile([x["elapsedMS"] for x in warm], 50),
                          "p95": percentile([x["elapsedMS"] for x in warm], 95)},
        "warmEndToEndMS": {"p50": percentile([x["endToEndMS"] for x in warm], 50),
                           "p95": percentile([x["endToEndMS"] for x in warm], 95)},
        "modes": dict(collections.Counter(x["mode"] for x in records)),
        "decisions": dict(collections.Counter(x["decision"] for x in records)),
    }
    counts = [x["inferenceCount"] for x in records if x["inferenceCount"] is not None]
    if counts:
        result["inferenceCount"] = {"total": sum(counts), "mean": round(statistics.mean(counts), 3), "max": max(counts)}
    sizes = [len(x["shortlistedIDs"]) for x in records if x["shortlistedIDs"] is not None]
    if sizes:
        result["shortlistSize"] = {"mean": round(statistics.mean(sizes), 3), "max": max(sizes)}
    return result


def evaluation_error(response, request, protocol, no_model, backend="mlx"):
    if response.get("decision") in {"invalid_request", "error", "model_error", "runtime_error", "remote_unavailable"}:
        return "Worker returned an error decision, not a valid recommendation/abstention."
    if protocol == "legacy" and not request["context"].get("isSecure") and not response.get("rankings"):
        return "Legacy worker returned no rankings for a valid nonempty nonsecure request."
    if no_model and (response.get("mode") == "laya" or response.get("inferenceCount", 0) != 0):
        return "Rules-only ablation unexpectedly performed model inference."
    # In this evaluated production protocol, available context plus a nonempty
    # shortlist invokes the model unless --no-model or secure-field handling applies.
    if protocol == "current" and not no_model and not request["context"].get("isSecure"):
        has_context = any(request["context"].get(key, "").strip() for key in
                          ("fieldLabel", "selectedText", "surroundingText"))
        expected_mode = "jev" if backend == "jev" else "laya"
        if has_context and response.get("shortlistedIDs") and response.get("mode") != expected_mode:
            return "Model-requested evaluation unexpectedly fell back for a contextual shortlisted request."
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", required=True, help="Existing environment containing the chosen Laya backend")
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--model", type=Path, help="Local model directory, unnecessary for Jev")
    parser.add_argument("--backend", choices=("mlx", "coreml", "jev"), default="mlx")
    parser.add_argument("--protocol", choices=("legacy", "current"), required=True)
    parser.add_argument("--split", choices=("all", "dev", "heldout"), default="all")
    parser.add_argument("--subset", choices=("full", "coreml"), default="full")
    parser.add_argument("--no-model", action="store_true", help="Pass the production --no-model flag for rules ablation")
    parser.add_argument("--label", required=True)
    parser.add_argument("--production-commit", help="Frozen source commit for provenance (source hashes are also recorded)")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--output", type=Path, default=ROOT / "results")
    args = parser.parse_args()
    if args.backend != "jev" and args.model is None:
        parser.error("Local backends require --model.")
    if args.backend == "jev" and (args.no_model or args.protocol != "current"):
        parser.error("Jev requires the current protocol and cannot use --no-model.")
    expected_mode = "jev" if args.backend == "jev" else "laya"
    if args.no_model and args.protocol != "current":
        parser.error("--no-model is available only for the current protocol.")
    if not args.label or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_." for char in args.label):
        parser.error("Use a simple filename-safe --label.")

    manifest = json.loads((ROOT / "manifest.json").read_text())
    cases = load_cases(ROOT / "cases.jsonl", manifest)
    if args.split != "all":
        cases = [case for case in cases if case["split"] == args.split]
    if args.subset == "coreml":
        selected = set(manifest["coremlSubsetIDs"])
        cases = [case for case in cases if case["id"] in selected]
    if not cases:
        parser.error("No cases match the requested split/subset.")

    args.output.mkdir(parents=True, exist_ok=True)
    response_path = args.output / f"{args.label}.responses.jsonl"
    summary_path = args.output / f"{args.label}.summary.json"
    if response_path.exists() or summary_path.exists():
        parser.error("Evaluation output already exists; choose a new label rather than overwrite evidence.")
    worker_bytes = args.worker.read_bytes()
    worker_sources = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in sorted(args.worker.parent.glob("*.py"))} if args.protocol == "current" else {
                          args.worker.name: hashlib.sha256(worker_bytes).hexdigest()}
    warmup_input = warmup_case()
    projection = None
    worker = None
    records = []
    try:
        projection = project_contexts([*cases, warmup_input]) if args.protocol == "current" else None
        command = [args.python, "-u", str(args.worker.resolve()), "--backend", args.backend]
        if args.model is not None:
            command.extend(["--model", str(args.model.resolve())])
        if args.no_model:
            command.append("--no-model")
        worker = Worker(command, args.timeout)
        warmup_request = request_for(warmup_input, args.protocol)
        warmup, warmup_wall = worker.request(warmup_request)
        warmup_error = evaluation_error(warmup, warmup_request, args.protocol, args.no_model, args.backend)
        if warmup_error:
            raise RuntimeError("Unscored warmup: " + warmup_error)
        model_warmed = args.no_model or warmup.get("mode") == expected_mode
        with response_path.open("x") as output:
            for index, case in enumerate(cases, 1):
                request = request_for(case, args.protocol)
                response, elapsed_wall = worker.request(request)
                error = evaluation_error(response, request, args.protocol, args.no_model, args.backend)
                correct = case["expected"]["correctIDs"]
                recommended = response.get("recommendedID")
                shortlisted = response.get("shortlistedIDs")
                cold = not model_warmed and response.get("mode") == expected_mode
                model_warmed = model_warmed or response.get("mode") == expected_mode
                row = {"caseID": case["id"], "split": case["split"], "group": case["group"],
                       "tags": case["tags"], "correctIDs": correct, "recommendedID": recommended,
                       "decisionCorrect": not error and (recommended in correct if correct else recommended is None),
                       "decision": response.get("decision", "recommended" if recommended else "abstain"),
                       "shortlistedIDs": shortlisted,
                       "shortlistRecall": bool(set(correct) & set(shortlisted)) if correct and shortlisted is not None else None,
                       "inferenceCount": response.get("inferenceCount"), "appliedFacets": response.get("appliedFacets", []),
                       "mode": response.get("mode"), "elapsedMS": response.get("elapsedMS", elapsed_wall),
                       "endToEndMS": round(elapsed_wall, 3), "coldModelLoad": cold,
                       "contextProjection": case.get("projectedContext"), "evaluationError": error, "response": response}
                records.append(row)
                output.write(json.dumps(row, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n")
                output.flush()
                if error:
                    raise RuntimeError(case["id"] + ": " + error)
                if index % 10 == 0 or index == len(cases):
                    print(json.dumps({"completed": index, "total": len(cases), "label": args.label}), flush=True)
        if (not args.no_model and args.protocol != "legacy"
                and not (warmup.get("inferenceCount", 0) or any(row["inferenceCount"] for row in records))):
            raise RuntimeError("No real model inference observed; do not report this as a model evaluation.")
    except Exception as error:
        failure = {"label": args.label, "error": type(error).__name__, "message": str(error),
                   "completedCases": len(records), "workerSourcesSHA256": worker_sources,
                   "contextProjection": projection, "datasetSHA256": manifest["sha256"],
                   "workerStderrTail": worker.stderr_tail() if worker is not None else None}
        (args.output / f"{args.label}.failure.json").write_text(json.dumps(failure, indent=2) + "\n")
        raise
    finally:
        if worker is not None:
            worker.close()

    summary = {"label": args.label, "datasetSHA256": manifest["sha256"],
               "workerSHA256": hashlib.sha256(worker_bytes).hexdigest(),
               "workerSourcesSHA256": worker_sources,
               "baselineCommit": manifest["baselineCommit"] if args.protocol == "legacy" else None,
               "productionCommit": args.production_commit,
               "backend": args.backend, "protocol": args.protocol, "noModel": args.no_model,
               "contextProjection": projection,
               "split": args.split, "subset": args.subset,
               "platform": {"system": platform.system(), "release": platform.release(), "machine": platform.machine()},
               "modelConfigurationSHA256": hashlib.sha256((args.model / "rl_agent_config.json").read_bytes()).hexdigest()
                   if args.model is not None and (args.model / "rl_agent_config.json").is_file() else None,
               "modelVersions": sorted({row["response"].get("modelVersion") for row in records
                                         if row["response"].get("modelVersion")}),
               "warmup": {"elapsedMS": warmup.get("elapsedMS"), "endToEndMS": round(warmup_wall, 3),
                          "mode": warmup.get("mode"), "inferenceCount": warmup.get("inferenceCount")},
               "overall": metrics(records),
               "bySplit": {split: metrics([row for row in records if row["split"] == split])
                           for split in sorted({row["split"] for row in records})},
               "byGroup": {group: metrics([row for row in records if row["group"] == group])
                           for group in sorted({row["group"] for row in records})}}
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"summary": str(summary_path), "overall": summary["overall"]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
